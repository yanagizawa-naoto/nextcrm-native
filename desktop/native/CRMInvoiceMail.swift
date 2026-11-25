import Foundation
import CoreGraphics
import CryptoKit

extension InvoiceJobRunner {
    convenience init(db: NativeDatabase,worker: InvoiceJobWorker) {
        self.init(db:db,events:CRMService.invoiceJobEvents,runNext:{ try await worker.runNext() })
    }
}

extension CRMService {
    static let invoiceJobEvents = ["invoice.pdf_requested","invoice.email_requested"]

    func invoiceEmailDefaults(_ record: NativeRecord) throws -> (to:String,subject:String,message:String) {
        let invoice = try invoiceAccess(record,action:"email")
        let account = try db.get("crm_Accounts",key:["id":invoice["accountId"]])
        let name = account?["name"].string ?? "お客様"
        return (account?["email"].string ?? "","請求書 \(invoice["number"].string) のご案内",name+" 御中\n\nいつもお世話になっております。\n請求書を添付いたします。内容をご確認くださいますようお願いいたします。")
    }

    @discardableResult
    func queueInvoiceEmail(_ record: NativeRecord, from: String, to: String, subject: String, message: String, now: Date = Date()) throws -> String {
        let invoice = try invoiceAccess(record,action:"email")
        guard invoice["number"] != .null else { throw NativeDBError.message("発行済みの請求書を選択してください。") }
        let pdf = try invoicePDFURL(invoice)
        let id = UUID().uuidString.lowercased()
        let sender = try InvoiceMail.mailbox(from); let recipient = try InvoiceMail.mailbox(to)
        let body = try InvoiceMail.prepare(root:db.url.deletingLastPathComponent(),id:id,from:sender,to:recipient,subject:subject,message:message,number:invoice["number"].string,pdf:pdf)
        do {
            return try db.transaction {
                _ = try invoiceAccess(invoice,action:"email")
                return try db.enqueue("invoice.email_requested",payload:["invoiceId":invoice["id"].string,"actorId":identity.id,"from":sender,"to":recipient,"subject":subject,"sha256":body.sha256,"bytes":String(body.bytes)],id:id,now:now)
            }
        } catch { try? FileManager.default.removeItem(at:body.url); throw error }
    }

    func invoiceJobs(_ record: NativeRecord, offset: Int = 0) throws -> [NativeJob] {
        let current = try invoiceAccess(record)
        guard invoiceCan(current,"read") else { throw NativeDBError.message("この請求書の送信履歴を表示する権限がありません。") }
        return try db.jobs(events:Self.invoiceJobEvents,invoiceID:current["id"].string,offset:offset)
    }

    func invoiceJobAccess(_ id: String, reviewing: Bool = false) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id), Self.invoiceJobEvents.contains(job.event), let invoiceID = job.payload["invoiceId"],
              let invoice = try db.get("Invoices",key:["id":.text(invoiceID)]) else { throw NativeDBError.message("処理が見つかりません。") }
        _ = try invoiceAccess(invoice,action:reviewing ? "read" : job.event == "invoice.pdf_requested" ? "pdf" : "email")
        // A retry must run with the original actor. Only that actor or an elevated
        // user may manage its lifecycle; revoked permissions are rechecked by the worker.
        guard identity.elevated || job.payload["actorId"] == identity.id else { throw NativeDBError.message("この処理を変更する権限がありません。") }
        return job
    }
    func retryInvoiceJob(_ id: String, now: Date = Date()) throws {
        try db.transaction { _ = try invoiceJobAccess(id); try db.retryJob(id:id,now:now) }
    }
    func cancelInvoiceJob(_ id: String) throws {
        try db.transaction {
            let job = try invoiceJobAccess(id)
            try db.cancelJob(id:id)
            if job.event == "invoice.email_requested" { try db.deferTerminalMailBodyCleanup(id:id) }
        }
    }
}

/// One active task per worker; database leases also fence separate processes.
/// No database transaction spans a network await. The provider key and immutable
/// body are stable across retries, including after process termination.
actor InvoiceJobWorker {
    let db: NativeDatabase
    let apiKey: () throws -> String
    let request: ResendMailClient.Request
    let clock: () -> Date
    private var active = false
    private let terminalBodyRecovery: NativeTerminalMailBodyRecovery
    private var recoveryPassComplete = false
    init(db: NativeDatabase, apiKey: @escaping () throws -> String, request: @escaping ResendMailClient.Request = ResendMailClient.request, clock: @escaping () -> Date = Date.init, terminalBodyRecovery: NativeTerminalMailBodyRecovery? = nil) {
        self.db = db; self.apiKey = apiKey; self.request = request; self.clock = clock
        self.terminalBodyRecovery = terminalBodyRecovery ?? NativeTerminalMailBodyRecovery(db:db)
    }
    private func actorService(_ job: NativeJob) throws -> (CRMService,NativeRecord) {
        guard let actor = job.payload["actorId"], let invoiceID = job.payload["invoiceId"],
              let user = try db.get("Users",key:["id":.text(actor)]), let invoice = try db.get("Invoices",key:["id":.text(invoiceID)]) else { throw NativeDBError.message("請求書または実行する利用者が見つかりません。") }
        let service = CRMService(db:db,identity:CRMIdentity(id:actor,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        _ = try service.invoiceAccess(invoice,action:job.event == "invoice.pdf_requested" ? "pdf" : "email")
        return (service,invoice)
    }
    private func completeAccepted(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let providerID = current.result["providerID"], UUID(uuidString:providerID) != nil, let actor = current.payload["actorId"], let invoiceID = current.payload["invoiceId"] else { throw NativeDBError.message("送信結果の記録が不正です。") }
            if var invoice = try db.get("Invoices",key:["id":.text(invoiceID)]) {
                let issued = invoice["status"] == .text("ISSUED")
                if issued { invoice = try db.update(invoice,changes:["status":.text("SENT")],actor:actor,action:"invoice_email") }
                let metadata = ["to":current.payload["to"] ?? "","subject":current.payload["subject"] ?? "","providerID":providerID,"jobID":job.id]
                let json = String(decoding:try JSONEncoder().encode(metadata),as:UTF8.self)
                // This records an already accepted send, even if the actor was
                // deactivated during the request. It grants no new send permission.
                _ = try db.insert("Invoice_Activity",values:["invoiceId":invoice["id"],"actorId":.text(actor),"action":.text(issued ? "SENT" : "EMAIL_SENT"),"meta":.text(json)],actor:actor)
            }
            try db.finishJob(current,result:current.result,now:clock())
        }
        if let url = try? InvoiceMail.bodyURL(root:db.url.deletingLastPathComponent(),id:job.id) { try? FileManager.default.removeItem(at:url) }
    }

    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        try Task.checkCancellation()
        // One bounded pass per runner drain/wake. Cursor persists between pages;
        // retained legacy files cannot prevent later eligible names being seen.
        if !recoveryPassComplete {
            do {recoveryPassComplete = try terminalBodyRecovery.step().finished}
            catch is CancellationError {terminalBodyRecovery.reset();recoveryPassComplete=false;throw CancellationError()}
            catch {terminalBodyRecovery.reset();recoveryPassComplete=true} // Defer inaccessible cleanup; ordinary PDF/mail jobs keep their existing path.
            await Task.yield();try Task.checkCancellation()
        }
        guard let claimed = try db.claimJob(events:CRMService.invoiceJobEvents,now:clock()) else {
            let more = !recoveryPassComplete
            if !more {recoveryPassComplete=false}
            return more
        }
        var job = claimed; var externalAttempt = false
        do {
            if job.event == "invoice.email_requested", job.result["providerID"] != nil { try completeAccepted(job); return true }
            let (service,invoice) = try actorService(job)
            if job.event == "invoice.pdf_requested" {
                let url = try? service.invoicePDFURL(invoice)
                // Generated PDFs are atomically published only after successful rendering.
                if url.flatMap({ CGPDFDocument($0 as CFURL) })?.numberOfPages ?? 0 == 0 { _ = try service.generateInvoicePDF(invoice) }
                try db.finishJob(job,now:clock()); return true
            }
            let now = clock()
            if let start = job.deliveryStartedAt, now < start || now.timeIntervalSince(start) >= 23*3600 {
                throw MailSendError(message:"重複送信の防止期間を超えています。送信サービスで結果を確認してください。",retryable:false,review:true)
            }
            let url = try InvoiceMail.bodyURL(root:db.url.deletingLastPathComponent(),id:job.id)
            guard let digest = job.payload["sha256"], let size = job.payload["bytes"].flatMap(Int.init) else { throw NativeDBError.message("保存したメールの情報が不正です。") }
            try InvoiceMail.verify(url,sha256:digest,bytes:size)
            let key = try apiKey()
            guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw NativeDBError.message("送信サービスのAPIキーを設定してください。") }
            let credentialHash = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
            if job.deliveryStartedAt != nil, job.result["credentialSHA256"] != credentialHash {
                throw MailSendError(message:"送信開始後にAPIキーが変更されました。重複送信を避けるため、送信サービスで結果を確認してください。",retryable:false,review:true)
            }
            job = try db.transaction {
                _ = try actorService(job)
                try db.renewJobLease(job,now:clock())
                try db.recordJobResult(job,result:["credentialSHA256":credentialHash])
                return try db.markJobDeliveryStarted(job,now:clock())
            }
            externalAttempt = true
            let providerID = try await ResendMailClient.send(body:url,jobID:job.id,apiKey:key,request:request)
            try db.recordJobResult(job,result:["providerID":providerID,"acceptedAt":ISO8601DateFormatter().string(from:clock())])
            try completeAccepted(job)
        } catch {
            // A reclaimed worker owns this job now. Never overwrite its outcome.
            guard let current = try? db.requireJobLease(job) else { return true }
            let mail = error as? MailSendError
            let conflict: Bool
            if case NativeDBError.conflict = error { conflict = true } else { conflict = false }
            let retryable = mail?.retryable ?? (externalAttempt || current.result["providerID"] != nil || conflict)
            let retry = retryable && current.attempts < 8 && mail?.review != true
            let delay = max(mail?.retryAfter ?? 0,min(300,5*pow(2,Double(min(current.attempts-1,6)))))
            let exhausted = !retry && retryable && current.deliveryStartedAt != nil && current.result["providerID"] == nil
            let message = exhausted ? "再試行の上限に達しました。送信サービスで結果を確認してください。" : mail?.message ?? (externalAttempt ? "送信結果の保存が完了しませんでした。同じ送信IDで確認します。" : error.localizedDescription)
            try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(delay) : nil,needsReview:mail?.review == true || exhausted)
        }
        return true
    }
}
