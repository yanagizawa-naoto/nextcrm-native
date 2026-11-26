import Foundation
import CryptoKit

struct NativeMailDraft {
    var to:[String], cc:[String] = [], bcc:[String] = []
    var subject: String, body: String
    var inReplyTo: String? = nil, references:[String] = []
}
struct NativeMailSendSummary: Codable {
    let endpoint: NativeMailEndpoint
    let from: String, to:[String], cc:[String], bcc:[String], subject: String, messageID: String
    let date: Date
    // Optional to preserve queued payloads created before names were retained.
    var toAddresses:[NativeMailAddress]? = nil, ccAddresses:[NativeMailAddress]? = nil, bccAddresses:[NativeMailAddress]? = nil
}
struct NativeMailSendPreview {
    let subject:String, from:String, to:[String], recipientCount:Int
    var recipientsText:String { to.joined(separator:", ")+(recipientCount > to.count ? " ほか\(recipientCount-to.count)件" : "") }
}
enum NativeMailDelivery {
    static let event = "native.mail.send"
    static func digest(summary: String,mime: Data) -> String {
        var hash = SHA256(); hash.update(data:Data(summary.utf8)); hash.update(data:Data([0])); hash.update(data:mime)
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func payload(db: NativeDatabase,job: NativeJob) throws -> (NativeMailSendSummary,Data) {
        guard let saved = try db.mailSendPayload(job.id), let raw = saved["summary"]?.string, let summary = try? JSONDecoder().decode(NativeMailSendSummary.self,from:Data(raw.utf8)),
              case .blob(let mime) = saved["mime"], !mime.isEmpty,
              saved["actor_id"]?.string == job.payload["actorID"], saved["account_id"]?.string == job.payload["accountID"],
              saved["message_id"]?.string == summary.messageID, summary.messageID == job.payload["messageID"],
              digest(summary:raw,mime:mime) == job.payload["digest"] else { throw NativeDBError.message("保存した送信内容を確認できません。送信内容を開き直してください。") }
        return (summary,mime)
    }
    /// Reconcile an already accepted external side effect. This never grants
    /// permission to send again, including after the owner is deactivated.
    static func recordAccepted(db: NativeDatabase,job: NativeJob,now: Date) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            let result = try recordLocalCopy(db:db,current:current,now:now)
            try db.finishJob(current,result:result,now:now)
            try db.releaseMailSendPayload(current.id)
        }
    }
    /// Shared local-only reconciliation. Callers must already own the worker
    /// lease OR the exact restored SMTP review transaction. Never sends mail.
    static func recordLocalCopy(db:NativeDatabase,current:NativeJob,now:Date)throws->[String:String] {
            guard current.result["smtpAccepted"] == "true", let accountID = current.payload["accountID"], let actorID = current.payload["actorID"] else { throw NativeDBError.conflict }
            var result = current.result
            if let account = try db.get("EmailAccount",key:["id":.text(accountID)]) {
                guard account["userId"] == .text(actorID) else { throw NativeDBError.conflict }
                let (summary,mime) = try payload(db:db,job:current)
                let text = try NativeMailMIME.body(mime).text ?? ""
                let existing = try db.page("Email",fields:[],equal:["emailAccountId":.text(accountID),"rfcMessageId":.text(summary.messageID)],limit:1).rows.first
                let row: NativeRecord
                if let existing {
                    let full = try db.get("Email",key:["id":existing["id"]])!
                    guard full["userId"] == .text(actorID) else { throw NativeDBError.conflict }
                    row = full["bodyText"] == .null && full["bodyHtml"] == .null ? try db.update(full,changes:["bodyText":.text(text)],actor:actorID,action:"mail-send-recorded") : full
                } else {
                    func addresses(_ values:[String],_ named:[NativeMailAddress]?) throws -> SQLValue { .text(String(decoding:try JSONEncoder().encode(named ?? values.map{NativeMailAddress(email:$0)}),as:UTF8.self)) }
                    row = try db.insert("Email",values:["emailAccountId":.text(accountID),"userId":.text(actorID),"rfcMessageId":.text(summary.messageID),"folder":.text("SENT"),"subject":.text(summary.subject),"fromEmail":.text(summary.from),"toRecipients":try addresses(summary.to,summary.toAddresses),"ccRecipients":try addresses(summary.cc,summary.ccAddresses),"bccRecipients":try addresses(summary.bcc,summary.bccAddresses),"bodyText":.text(text),"sentAt":.text(current.result["acceptedAt"] ?? ISO8601DateFormatter().string(from:now)),"isRead":.integer(1)],actor:actorID)
                    _ = try db.enqueue(NativeMailJobs.link,payload:["actorID":actorID,"accountID":accountID,"emailID":row["id"].string],now:now)
                }
                try db.setMetadata("mail.bodyLoaded."+row["id"].string,value:"1"); result["emailID"] = row["id"].string
            } else { result["skippedLocalCopy"] = "account-deleted" }
            return result
    }

}

extension CRMService {
    @discardableResult func queueMailSend(account expected: NativeRecord,draft: NativeMailDraft,now: Date = Date()) throws -> String {
        let account = try mailAccount(expected["id"].string)
        guard account.revision == expected.revision else { throw NativeDBError.conflict }
        let settings = try mailSettings(account), messageID = "<"+UUID().uuidString.lowercased()+"@nextcrm.local>"
        let to = try NativeMailAddress.list(draft.to), cc = try NativeMailAddress.list(draft.cc), bcc = try NativeMailAddress.list(draft.bcc)
        let summary = NativeMailSendSummary(endpoint:settings.smtp,from:try NativeMailAddress.checked(settings.username).transportAddress,to:try to.map{try $0.transportAddress},cc:try cc.map{try $0.transportAddress},bcc:try bcc.map{try $0.transportAddress},subject:draft.subject,messageID:messageID,date:now,toAddresses:to,ccAddresses:cc,bccAddresses:bcc)
        let mime = try NativeMailMIME.outgoing(from:summary.from,to:draft.to,cc:draft.cc,bcc:draft.bcc,subject:draft.subject,body:draft.body,messageID:messageID,inReplyTo:draft.inReplyTo,references:draft.references,date:now)
        let encoded = String(decoding:try JSONEncoder().encode(summary),as:UTF8.self), digest = NativeMailDelivery.digest(summary:encoded,mime:mime)
        return try db.transaction {
            let fresh = try mailAccount(account["id"].string); guard fresh.revision == account.revision else { throw NativeDBError.conflict }
            let id = try db.enqueue(NativeMailDelivery.event,payload:["actorID":identity.id,"accountID":account["id"].string,"messageID":messageID,"digest":digest],now:now)
            try db.storeMailSend(jobID:id,accountID:account["id"].string,actorID:identity.id,messageID:messageID,summary:encoded,mime:mime)
            return id
        }
    }
    func mailSendJob(_ id:String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id), job.event == NativeMailDelivery.event, job.payload["actorID"] == identity.id, let accountID = job.payload["accountID"] else { throw NativeDBError.message("送信処理が見つかりません。") }
        _ = try mailAccount(accountID); return job
    }
    func mailSendJobs(_ accountID:String,offset:Int = 0) throws -> [NativeJob] {
        _ = try mailAccount(accountID); return try db.mailSendJobs(accountID:accountID,actorID:identity.id,offset:offset)
    }
    func mailSendSummary(_ expected:NativeJob) throws -> NativeMailSendSummary {
        let current = try mailSendJob(expected.id); guard current == expected, let saved = try db.mailSendPayload(current.id,includeMIME:false), let json = saved["summary"]?.string else { throw NativeDBError.conflict }
        return try JSONDecoder().decode(NativeMailSendSummary.self,from:Data(json.utf8))
    }
    func mailSendPreview(_ expected:NativeJob) throws -> NativeMailSendPreview {
        let current = try mailSendJob(expected.id)
        guard current == expected,let saved = try db.mailSendPreview(current.id),case let .integer(count) = saved["recipient_count"],count >= 0,count <= Int64(Int.max) else { throw NativeDBError.conflict }
        return .init(subject:saved["subject"]?.string ?? "",from:saved["sender"]?.string ?? "",to:(0..<3).compactMap { saved["recipient\($0)"] == .null ? nil : saved["recipient\($0)"]?.string },recipientCount:Int(count))
    }
    func retryMailSend(_ expected:NativeJob) throws {
        try db.transaction { let current = try mailSendJob(expected.id); guard current == expected else { throw NativeDBError.conflict }; _ = try mailAccount(current.payload["accountID"]!); try db.retryMailSend(current) }
    }
    /// Load one selected body's text. List/history queries never retain MIME.
    func mailSendBody(_ expected:NativeJob) throws -> String? {
        try db.transaction {
            let current = try mailSendJob(expected.id); guard current == expected else { throw NativeDBError.conflict }
            if let stored = try db.mailSendPayload(current.id), case .blob(let mime) = stored["mime"], !mime.isEmpty { return try NativeMailMIME.body(mime).text }
            if let id = current.result["emailID"], let row = try? mailMessage(id), row["emailAccountId"].string == current.payload["accountID"] { return row["bodyText"] == .null ? nil : row["bodyText"].string }
            return nil
        }
    }
    func cancelMailSend(_ expected:NativeJob) throws {
        try db.transaction { let current = try mailSendJob(expected.id); guard current == expected else { throw NativeDBError.conflict }; try db.cancelJob(id:current.id); try db.releaseMailSendPayload(current.id) }
    }
    func reviewMailSend(_ expected:NativeJob,sent: Bool,now:Date = Date()) throws {
        try db.transaction { let current = try mailSendJob(expected.id); guard current == expected else { throw NativeDBError.conflict }; try db.reviewMailSend(current,sent:sent,now:now) }
    }
}

actor NativeMailSendWorker {
    typealias Send = (NativeMailWireRequest) async throws -> Void
    let db: NativeDatabase, store: NativeMailSecretStore, send: Send, clock: () -> Date
    private var active = false
    let oauthRequest:GoogleMailOAuth.Request
    init(db:NativeDatabase,store:NativeMailSecretStore,send:@escaping Send = { request in
        let reply = try await NativeMailWire.perform(request)
        guard reply.serverCode == 250 else { throw NativeMailFailure.transport(code:56,uploaded:true) }
    },clock:@escaping () -> Date = Date.init,oauthRequest:@escaping GoogleMailOAuth.Request = GoogleMailOAuth.network) { self.db = db; self.store = store; self.send = send; self.clock = clock; self.oauthRequest = oauthRequest }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let claimed = try db.claimJob(events:[NativeMailDelivery.event],now:clock()) else { return false }
        var job = claimed, invoked = false
        var credentialAccount:NativeRecord?, owner:CRMService?
        do {
            if job.result["smtpAccepted"] == "true" { try NativeMailDelivery.recordAccepted(db:db,job:job,now:clock()); return true }
            if job.deliveryStartedAt != nil {
                try db.failJob(job,message:"前回の送信結果を確認できません。送信済みフォルダを確認して、結果を指定してください。",needsReview:true); return true
            }
            guard let actorID = job.payload["actorID"], let accountID = job.payload["accountID"], let user = try db.get("Users",key:["id":.text(actorID)]) else { throw NativeDBError.conflict }
            let service = CRMService(db:db,identity:.init(id:actorID,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
            owner = service
            var account = try service.mailAccount(accountID); credentialAccount = account
            let settings = try service.mailSettings(account)
            let (summary,mime) = try NativeMailDelivery.payload(db:db,job:job)
            guard summary.endpoint == settings.smtp, (try NativeMailAddress.checked(summary.from).transportAddress) == (try NativeMailAddress.checked(settings.username).transportAddress) else { throw NativeMailFailure.invalid("送信待ちのメールを作成した後に送信元が変更されました。内容を確認して作成し直してください。") }
            let prepared = try await service.readyMailCredential(account,store:store,request:oauthRequest,now:clock(),validate:{ try Task.checkCancellation(); _ = try self.db.requireJobLease(job) })
            account = prepared.account; credentialAccount = account
            let credential = prepared.credential
            var request = NativeMailWireRequest(endpoint:summary.endpoint,username:settings.username,password:credential.password,sender:summary.from,recipients:summary.to+summary.cc+summary.bcc,upload:mime,oauthBearer:credential.oauthBearer)
            // SMTP responses contain only short protocol lines.
            request.maximumResponse = 262_144
            job = try db.transaction {
                try Task.checkCancellation(); let fresh = try service.mailAccount(accountID)
                guard fresh.revision == account.revision else { throw NativeDBError.conflict }
                try db.renewJobLease(job,now:clock()); return try db.markJobDeliveryStarted(job,now:clock())
            }
            invoked = true; try await send(request)
            try db.recordJobResult(job,result:["smtpAccepted":"true","acceptedAt":ISO8601DateFormatter().string(from:clock()),"messageID":summary.messageID])
            try NativeMailDelivery.recordAccepted(db:db,job:job,now:clock())
        } catch {
            guard var current = try? db.requireJobLease(job) else { return true }
            let accepted = current.result["smtpAccepted"] == "true"
            var uncertain = invoked && !accepted
            if let mail = error as? NativeMailFailure {
                switch mail {
                case .transport(_,let uploaded): if !uploaded { uncertain = false }
                case .cancelled:uncertain = false // C only reports this before upload.
                default:break
                }
            }
            let googleRetry = credentialAccount.map { owner?.noteGoogleMailAuthenticationFailure($0,error:error) ?? false } ?? false
            try db.transaction {
                _ = try db.requireJobLease(current)
                if invoked && !uncertain && !accepted { try db.clearMailDeliveryStarted(current); current = try db.requireJobLease(current) }
                let retry = !uncertain && (accepted || googleRetry || NativeMailJobs.retryable(error)) && current.attempts < 4
                let message = accepted ? "送信は受け付けられました。送信済みへの保存を再試行します。" : uncertain ? "送信結果を確認できません。送信済みフォルダを確認して、結果を指定してください。" : googleRetry ? GoogleMailFailure.reconnect.localizedDescription : NativeMailJobs.message(error)
                try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(min(300,5*pow(2,Double(current.attempts-1)))) : nil,needsReview:uncertain)
            }
        }
        return true
    }
}
