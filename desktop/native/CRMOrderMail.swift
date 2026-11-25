import Foundation
import CryptoKit

extension CRMService {
    static let orderJobEvents = ["orders.approval_requested","orders.approval_decided"]
    func orderJobs(_ record: NativeRecord, offset: Int = 0) throws -> [NativeJob] {
        let current = try orderAccess(record)
        return try db.jobs(events:Self.orderJobEvents,orderID:current["id"].string,recipientID:identity.elevated ? nil : identity.id,offset:offset)
    }
    func orderJobAccess(_ id: String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id), Self.orderJobEvents.contains(job.event),
              let orderID = job.payload["orderId"], let order = try db.get("crm_Orders",key:["id":.text(orderID)]) else { throw NativeDBError.message("通知または受注が見つかりません。") }
        _ = try orderAccess(order)
        guard identity.elevated || job.payload["recipientId"] == identity.id else { throw NativeDBError.message("この通知を変更する権限がありません。") }
        return job
    }
    func retryOrderJob(_ id: String, now: Date = Date()) throws {
        try db.transaction { _ = try orderJobAccess(id); try db.retryJob(id:id,now:now) }
    }
    func cancelOrderJob(_ id: String) throws {
        try db.transaction {
            _ = try orderJobAccess(id)
            try db.cancelJob(id:id)
            try db.deferTerminalMailBodyCleanup(id:id)
        }
    }
}

/// Notifications describe committed workflow events. Legacy queued events have
/// no actorId; they remain deliverable, with current recipient access checked.
/// No network await holds a database transaction. Frozen bodies and key hashes
/// are shared by retries and reclaimed leases, just like invoice delivery.
actor OrderMailWorker {
    let db: NativeDatabase
    let account: () throws -> InvoiceMailAccount
    let request: ResendMailClient.Request
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, account: @escaping () throws -> InvoiceMailAccount, request: @escaping ResendMailClient.Request = ResendMailClient.request, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.account = account; self.request = request; self.clock = clock
    }
    private var root: URL { db.url.deletingLastPathComponent() }
    private struct Skip: Error { let reason: String }

    private func recipient(_ job: NativeJob) throws -> String {
        guard try db.get("crm_SystemSettings",key:["key":.text("orders_approval_emails")])?["value"] != .text("false") else { throw Skip(reason:"承認メール通知が無効になっています。") }
        guard let orderID = job.payload["orderId"], let recipientID = job.payload["recipientId"],
              let order = try db.get("crm_Orders",key:["id":.text(orderID)]), let user = try db.get("Users",key:["id":.text(recipientID)]) else { throw Skip(reason:"受注または宛先の利用者が見つかりません。") }
        let role = user["role"].string
        let service = CRMService(db:db,identity:CRMIdentity(id:recipientID,role:role,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        do { _ = try service.orderAccess(order) } catch { throw Skip(reason:"宛先の利用者は現在この受注を閲覧できません。") }
        if job.event == "orders.approval_requested" {
            guard ["admin","manager"].contains(role) else { throw Skip(reason:"宛先の利用者に承認権限がありません。") }
            guard order["status"] == .text("PENDING_APPROVAL") else { throw Skip(reason:"この受注は現在、承認待ちではありません。") }
            if let revision = job.payload["requestRevision"], revision != String(order.revision) { throw Skip(reason:"この承認依頼の後に受注が更新されています。") }
            if job.payload["requestedAt"] == nil, let queued = ISO8601DateFormatter().date(from:job.createdAt),
               let requested = ISO8601DateFormatter().date(from:order["approvalRequestedAt"].string), requested > queued { throw Skip(reason:"予約後に新しい承認依頼が作成されています。") }
            if let requested = job.payload["requestedAt"], requested != order["approvalRequestedAt"].string { throw Skip(reason:"この承認依頼は取り下げられ、新しい依頼に置き換わっています。") }
        } else {
            guard ["APPROVED","REJECTED"].contains(job.payload["decision"] ?? "") else { throw NativeDBError.message("承認結果の通知内容が不正です。") }
            guard order["createdBy"] == .text(recipientID), role != "partner" else { throw Skip(reason:"承認結果の宛先が現在の受注作成者と一致しません。") }
        }
        let to = try InvoiceMail.mailbox(user["email"].string)
        if let original = job.payload["recipientEmail"], try InvoiceMail.mailbox(original) != to { throw Skip(reason:"通知予約後に宛先メールアドレスが変更されています。") }
        if let frozen = job.result["to"], frozen != to { throw Skip(reason:"送信準備後に宛先メールアドレスが変更されています。") }
        return to
    }

    private func prepare(_ job: NativeJob, sender: String) throws -> NativeJob {
        try db.transaction {
            var current = try db.requireJobLease(job)
            let to = try recipient(current)
            if current.result["sha256"] != nil { return current }
            guard current.deliveryStartedAt == nil else { throw MailSendError(message:"送信開始済みですが、保存したメールの情報を確認できません。",retryable:false,review:true) }
            let number = current.payload["number"] ?? ""
            guard !number.isEmpty else { throw NativeDBError.message("通知の受注番号がありません。") }
            let subject: String; let message: String
            if current.event == "orders.approval_requested" {
                subject = "受注 \(number) の承認依頼"
                message = "受注 \(number) に価格表を下回る単価が含まれるため、承認が必要です。"
            } else {
                let verb = current.payload["decision"] == "APPROVED" ? "承認" : "却下"
                subject = "受注 \(number) が\(verb)されました"
                let note = current.payload["note"] ?? ""
                message = "受注 \(number) が\(verb)されました。"+(note.isEmpty ? "" : "\n\n担当者のメモ：\n"+note)
            }
            let url = try InvoiceMail.bodyURL(root:root,id:current.id)
            // An interrupted preparation has no committed hash and could never
            // have reached the provider. Its file can be replaced under the lease.
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
            let link = try NativeDeepLink(orderID:current.payload["orderId"] ?? "")
            let body = try InvoiceMail.prepareText(root:root,id:current.id,from:sender,to:to,subject:subject,message:message+"\n\n受注を開く：\n"+link.string+"\n\nリンクが開けない場合は、NextCRMの「ファイル → リンクから開く…」へ貼り付けてください。通知元と同じCRMデータが必要です。\n通知日時："+current.createdAt)
            do {
                var result = current.result
                result.merge(["from":try InvoiceMail.mailbox(sender),"to":to,"subject":subject,"sha256":body.sha256,"bytes":String(body.bytes),"orderLink":link.string]) { _,new in new }
                try db.recordJobResult(current,result:result)
                current = try db.requireJobLease(current); return current
            } catch { try? FileManager.default.removeItem(at:url); throw error }
        }
    }
    private func complete(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let id = current.result["providerID"], UUID(uuidString:id) != nil else { throw NativeDBError.message("送信結果の識別子が不正です。") }
            try db.finishJob(current,result:current.result,now:clock())
        }
        removeBody(job)
    }
    private func removeBody(_ job: NativeJob) {
        if let url = try? InvoiceMail.bodyURL(root:root,id:job.id) { try? FileManager.default.removeItem(at:url) }
    }

    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard var job = try db.claimJob(events:CRMService.orderJobEvents,now:clock()) else { return false }
        var externalAttempt = false
        do {
            // A stored provider receipt is completed locally even if access,
            // settings or credentials changed while the request was in flight.
            if job.result["providerID"] != nil { try complete(job); return true }
            if let start = job.deliveryStartedAt, clock() < start || clock().timeIntervalSince(start) >= 23*3600 {
                throw MailSendError(message:"重複送信の防止期間を超えています。送信サービスで結果を確認してください。",retryable:false,review:true)
            }
            _ = try recipient(job)
            let credentials = try account()
            let key = credentials.apiKey
            guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw NativeDBError.message("送信サービスのAPIキーを設定してください。") }
            let digest = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
            if job.deliveryStartedAt != nil, job.result["credentialSHA256"] != digest {
                throw MailSendError(message:"送信開始後にAPIキーが変更されました。送信サービスで結果を確認してください。",retryable:false,review:true)
            }
            job = try prepare(job,sender:credentials.from)
            let url = try InvoiceMail.bodyURL(root:root,id:job.id)
            guard let hash = job.result["sha256"], let size = job.result["bytes"].flatMap(Int.init) else { throw NativeDBError.message("保存したメールの情報が不正です。") }
            try InvoiceMail.verify(url,sha256:hash,bytes:size)
            job = try db.transaction {
                let current = try db.requireJobLease(job); _ = try recipient(current)
                try db.renewJobLease(current,now:clock())
                try db.recordJobResult(current,result:current.result.merging(["credentialSHA256":digest]) { _,new in new })
                return try db.markJobDeliveryStarted(current,now:clock())
            }
            externalAttempt = true
            let id = try await ResendMailClient.send(body:url,jobID:job.id,apiKey:key,scope:"order",request:request)
            try db.transaction {
                let current = try db.requireJobLease(job)
                try db.recordJobResult(current,result:current.result.merging(["providerID":id,"acceptedAt":ISO8601DateFormatter().string(from:clock()),"outcome":"sent"]) { _,new in new })
            }
            try complete(job)
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if let skip = error as? Skip {
                if current.deliveryStartedAt == nil {
                    try db.finishJob(current,result:current.result.merging(["outcome":"skipped","reason":skip.reason]) { _,new in new },now:clock()); removeBody(current)
                } else { try db.failJob(current,message:skip.reason+" 以前の送信結果を送信サービスで確認してください。",needsReview:true) }
                return true
            }
            let mail = error as? MailSendError
            let conflict: Bool
            if case NativeDBError.conflict = error { conflict = true } else { conflict = false }
            let retryable = mail?.retryable ?? (externalAttempt || current.result["providerID"] != nil || conflict)
            let retry = retryable && current.attempts < 8 && mail?.review != true
            let delay = max(mail?.retryAfter ?? 0,min(300,5*pow(2,Double(min(current.attempts-1,6)))))
            let exhausted = !retry && retryable && current.deliveryStartedAt != nil && current.result["providerID"] == nil
            let message = exhausted ? "再試行の上限に達しました。送信サービスで結果を確認してください。" : mail?.message ?? (externalAttempt ? "送信結果を保存できませんでした。同じ送信IDで確認します。" : error.localizedDescription)
            try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(delay) : nil,needsReview:mail?.review == true || exhausted)
        }
        return true
    }
}
