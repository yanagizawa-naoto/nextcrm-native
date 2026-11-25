import Foundation
import SQLite3

private final class FakeMailSender {
    var requests:[NativeMailWireRequest] = []
    var error: Error?, afterSend:(() throws -> Void)?
    func send(_ request: NativeMailWireRequest) async throws { requests.append(request); if let error { throw error }; try afterSend?() }
}
enum NativeMailSendTests {
    static func run(resources: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool,_ name: String) throws { guard condition else { throw NativeDBError.message("NativeMailSendTests: "+name) }; checks += 1 }
        func rejects(_ name: String,_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }; throw NativeDBError.message("NativeMailSendTests accepted: "+name)
        }
        let draft = NativeMailDraft(to:["customer@example.test"],cc:["copy@example.test"],bcc:["private@example.test"],subject:"日本語の返信",body:"こんにちは\n本文です",inReplyTo:"<parent@fixture.test>",references:["<first@fixture.test>","<parent@fixture.test>"])
        func queue(_ f:MailSyncFixture) throws -> String { try f.service.queueMailSend(account:f.account(),draft:draft,now:f.now) }
        func worker(_ f:MailSyncFixture,_ sender:FakeMailSender,second:Bool = false) -> NativeMailSendWorker { NativeMailSendWorker(db:second ? f.second : f.db,store:f.secrets,send:sender.send,clock:{f.now}) }
        func sql(_ f:MailSyncFixture,_ sql:String) throws {
            var handle:OpaquePointer?; guard sqlite3_open(f.db.url.path,&handle) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle,sql,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(handle))) }
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f), before = try f.service.mailSendJob(id)
            try check(before.status == "pending" && !before.payload.values.contains(where:{$0.contains("こんにちは") || $0.contains("synthetic-only") || $0.contains("private@example.test")}),"outbox carries identifiers, not body or credentials")
            _ = try await worker(f,sender).runNext()
            let done = try f.service.mailSendJob(id), email = try f.service.mailMessage(done.result["emailID"]!)
            try check(sender.requests.count == 1 && done.status == "done" && done.result["smtpAccepted"] == "true","accepted SMTP recorded once")
            try check(email["folder"] == .text("SENT") && email["isRead"] == .integer(1) && email["bodyText"] == .text("こんにちは\r\n本文です"),"Japanese sent copy immediately available")
            try check(email["bccRecipients"].string.contains("private@example.test") && !String(decoding:sender.requests[0].upload,as:UTF8.self).contains("private@example.test") && sender.requests[0].recipients.contains("private@example.test"),"BCC stays envelope-only remotely and owner-only locally")
            let headers = try NativeMailMIME.headers(Data(sender.requests[0].upload.prefix(through:sender.requests[0].upload.range(of:Data("\r\n\r\n".utf8))!.upperBound-1)))
            try check(headers["in-reply-to"] == "<parent@fixture.test>" && headers["references"].contains("<first@fixture.test>"),"reply threading frozen in prepared MIME")
            try check(try f.db.mailSendPayload(id)?["mime"] == .null && f.linkJobs() == 1,"accepted payload released and CRM follow-up queued atomically")
            let admin = CRMService(db:f.db,identity:.init(id:f.stranger["id"].string,role:"admin",partnerAccountID:nil))
            try rejects("administrator cannot inspect other sender's job") { _ = try admin.mailSendJob(id) }
            try rejects("administrator cannot list other sender's history") { _ = try admin.mailSendJobs(f.accountID) }
            try check(try f.service.mailSendSummary(done).subject == "日本語の返信","history summary survives MIME cleanup")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.error = NativeMailFailure.transport(code:28,uploaded:false); _ = try await worker(f,sender).runNext()
            let failed = try f.db.job(id:id)!
            try check(failed.status == "retry" && failed.deliveryStartedAt == nil,"confirmed pre-DATA failure can retry")
            sender.error = nil; f.now.addTimeInterval(6); _ = try await worker(f,sender,second:true).runNext()
            try check(try sender.requests.count == 2 && sender.requests[0].upload == sender.requests[1].upload && f.rows() == 1,"retry after restart uses immutable MIME and Message-ID")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.error = NativeMailFailure.transport(code:56,uploaded:true); _ = try await worker(f,sender).runNext()
            let uncertain = try f.service.mailSendJob(id)
            try check(uncertain.status == "needs_review" && uncertain.deliveryStartedAt != nil,"lost result is held for review")
            f.now.addTimeInterval(86400); let ran = try await worker(f,sender).runNext()
            try check(!ran && sender.requests.count == 1,"uncertain SMTP never automatically resends")
            try rejects("ordinary retry cannot bypass review") { try f.service.retryMailSend(uncertain) }
            try f.service.reviewMailSend(uncertain,sent:false,now:f.now)
            let reviewed = try f.service.mailSendJob(id); let ranAgain = try await worker(f,sender).runNext()
            try check(reviewed.status == "failed" && reviewed.deliveryStartedAt == nil && !ranAgain,"not-sent decision still requires explicit retry")
            try rejects("stale review cannot overwrite newer decision") { try f.service.reviewMailSend(uncertain,sent:true,now:f.now) }
            try f.service.retryMailSend(reviewed); sender.error = nil; _ = try await worker(f,sender).runNext()
            try check(try sender.requests.count == 2 && f.db.job(id:id)?.status == "done","explicit retry after not-sent review")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.error = NativeMailFailure.transport(code:56,uploaded:true); _ = try await worker(f,sender).runNext()
            try f.service.reviewMailSend(f.service.mailSendJob(id),sent:true,now:f.now)
            _ = try await worker(f,sender,second:true).runNext()
            try check(try sender.requests.count == 1 && f.rows() == 1 && f.db.job(id:id)?.status == "done","sent review records locally without another SMTP call")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            let claimed = try f.db.claimJob(events:[NativeMailDelivery.event],now:f.now)!
            _ = try f.db.markJobDeliveryStarted(claimed,now:f.now)
            f.now.addTimeInterval(301); _ = try await worker(f,sender,second:true).runNext()
            try check(try sender.requests.isEmpty && f.db.job(id:id)?.status == "needs_review","crash after persisted send-start never causes retransmission")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            let claimed = try f.db.claimJob(events:[NativeMailDelivery.event],now:f.now)!
            _ = try f.db.markJobDeliveryStarted(claimed,now:f.now)
            try f.db.recordJobResult(claimed,result:["smtpAccepted":"true","acceptedAt":ISO8601DateFormatter().string(from:f.now)])
            f.now.addTimeInterval(301); _ = try await worker(f,sender,second:true).runNext()
            try check(try sender.requests.isEmpty && f.rows() == 1 && f.db.job(id:id)?.status == "done","persisted acceptance recovers sent copy without network")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            try sql(f,"CREATE TRIGGER fail_sent BEFORE INSERT ON Email BEGIN SELECT RAISE(ABORT,'synthetic local write failure'); END")
            _ = try await worker(f,sender).runNext()
            let retry = try f.db.job(id:id)!
            try check(try retry.status == "retry" && retry.result["smtpAccepted"] == "true" && f.rows() == 0,"local write failure preserves acceptance and rolls back sent copy")
            try sql(f,"DROP TRIGGER fail_sent"); f.now.addTimeInterval(6); _ = try await worker(f,sender,second:true).runNext()
            try check(try sender.requests.count == 1 && f.rows() == 1 && f.linkJobs() == 1,"accepted recovery retries storage only")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.afterSend = { _ = try f.second.claimJob(events:[NativeMailDelivery.event],now:f.now.addingTimeInterval(301)); sender.afterSend = nil }
            _ = try await worker(f,sender).runNext(); f.now.addTimeInterval(602); _ = try await worker(f,sender,second:true).runNext()
            try check(try sender.requests.count == 1 && f.db.job(id:id)?.status == "needs_review" && f.rows() == 0,"lost lease cannot record acceptance or cause successor resend")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.afterSend = { try f.service.deleteMailAccount(f.account(),store:f.secrets); sender.afterSend = nil }
            _ = try await worker(f,sender).runNext()
            try check(try f.rows() == 0 && f.db.job(id:id)?.status == "done" && f.db.job(id:id)?.result["skippedLocalCopy"] == "account-deleted","account removed during accepted send is not resurrected")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.afterSend = { _ = try f.second.update(f.second.get("Users",key:["id":f.owner["id"]])!,changes:["userStatus":.text("INACTIVE")],actor:"test"); sender.afterSend = nil }
            _ = try await worker(f,sender).runNext()
            try check(try f.rows() == 1 && f.db.job(id:id)?.status == "done","already accepted send remains recorded after actor deactivation")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            _ = try f.second.update(f.owner,changes:["userStatus":.text("INACTIVE")],actor:"test")
            _ = try await worker(f,sender).runNext()
            try check(try sender.requests.isEmpty && f.db.job(id:id)?.deliveryStartedAt == nil,"revoked sender cannot start delivery")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            _ = try f.service.replaceMailPassword(f.account(),password:"synthetic-new",store:f.secrets)
            _ = try await worker(f,sender).runNext()
            try check(try sender.requests.first?.password == "synthetic-new" && f.db.job(id:id)?.status == "done","queued unsent mail uses current password")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            _ = try f.db.update(f.account(),changes:["smtpHost":.text("other.example.test")],actor:"test"); _ = try await worker(f,sender).runNext()
            try check(try sender.requests.isEmpty && f.db.job(id:id)?.status == "failed","changed SMTP source requires recomposition")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            try sql(f,"UPDATE native_mail_sends SET mime=X'6162'"); _ = try await worker(f,sender).runNext()
            try check(try sender.requests.isEmpty && f.db.job(id:id)?.status == "failed","tampered frozen body rejected before network")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            try f.service.cancelMailSend(f.service.mailSendJob(id)); _ = try await worker(f,sender).runNext()
            try check(try sender.requests.isEmpty && f.db.job(id:id)?.status == "cancelled" && f.db.mailSendPayload(id)?["mime"] == .null,"cancel before send releases payload")
            for _ in 0..<51 { _ = try queue(f) }
            try check(try f.service.mailSendJobs(f.accountID).count == 50 && f.service.mailSendJobs(f.accountID,offset:50).count == 2,"history reads fifty summaries at a time")
            var invalid = draft; invalid.body = "bad\0body"
            try rejects("NUL body cannot fail only after remote acceptance") { _ = try f.service.queueMailSend(account:f.account(),draft:invalid) }
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender()
            let addressed = NativeMailDraft(to:[#""営業部, 東京" <担当者@例え.テスト>, "a b"@example.test"#],cc:["経理 <copy@example.test>"],bcc:["非公開 <private@example.test>"],subject:"表示名の保存",body:"本文")
            let id = try f.service.queueMailSend(account:f.account(),draft:addressed,now:f.now), job = try f.service.mailSendJob(id), summary = try f.service.mailSendSummary(job)
            try check(summary.to == ["担当者@xn--r8jz45g.xn--zckzah",#""a b"@example.test"#] && summary.toAddresses?.first?.name == "営業部, 東京","immutable summary retains names and normalized envelope")
            _ = try await worker(f,sender).runNext()
            let sent = try f.service.mailMessages(accountID:f.accountID,folder:.sent).rows.first!, full = try f.service.mailMessage(sent["id"].string)
            let stored = try JSONDecoder().decode([NativeMailAddress].self,from:Data(full["toRecipients"].string.utf8))
            try check(stored.first == .init(email:"担当者@例え.テスト",name:"営業部, 東京") && stored.count == 2,"accepted local SENT retains display spelling and name")
            try check(sender.requests.first?.recipients == summary.to+summary.cc+summary.bcc,"SMTP envelope contains only actual mailboxes")
            let bytes = String(decoding:sender.requests.first!.upload,as:UTF8.self)
            try check(!bytes.contains("private@example.test") && !bytes.contains("非公開"),"BCC display name remains private on wire")
            let encoded = try JSONEncoder().encode(summary); var legacy = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
            for key in ["toAddresses","ccAddresses","bccAddresses"] { legacy.removeValue(forKey:key) }
            let decoded = try JSONDecoder().decode(NativeMailSendSummary.self,from:JSONSerialization.data(withJSONObject:legacy))
            try check(decoded.to == summary.to && decoded.toAddresses == nil,"older queued summaries remain decodable")
            var malformed = addressed; malformed.cc = ["ok@example.test, invalid"]
            let before = try f.service.mailSendJobs(f.accountID).count
            try rejects("mixed valid/invalid recipient never queues partial mail") { _ = try f.service.queueMailSend(account:f.account(),draft:malformed) }
            try check(try f.service.mailSendJobs(f.accountID).count == before,"invalid recipient leaves outbox unchanged")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), id = try queue(f)
            sender.error = NativeMailFailure.transport(code:-6,uploaded:false)
            _ = try await worker(f,sender).runNext()
            let stopped = try f.service.mailSendJob(id)
            try check(stopped.status == "failed" && stopped.deliveryStartedAt == nil,"unsupported SMTPUTF8 is a definite unsent failure, not an uncertain send")
            f.now.addTimeInterval(86400); let retried = try await worker(f,sender).runNext()
            try check(!retried && sender.requests.count == 1,"unsupported SMTPUTF8 does not automatically retry")
        }
        do {
            let f = try MailSyncFixture(resources:resources), sender = FakeMailSender(), addresses = (0..<1501).map{"person\($0)@example.test"}
            let large = NativeMailDraft(to:addresses,subject:"多数の宛先の保存",body:String(repeating:"日本語の本文です。\r\n",count:10_000))
            let id = try f.service.queueMailSend(account:f.account(),draft:large,now:f.now)
            _ = try await worker(f,sender).runNext()
            try check(try sender.requests.first?.recipients == addresses && f.service.mailSendJob(id).status == "done","all1501 recipients reach worker and durable success")
            let row = try f.service.mailMessages(accountID:f.accountID,folder:.sent).rows.first!, full = try f.service.mailMessage(row["id"].string)
            let stored = try JSONDecoder().decode([NativeMailAddress].self,from:Data(full["toRecipients"].string.utf8))
            try check(stored.map(\.email) == addresses && full["bodyText"].string == large.body,"SENT preserves every recipient and larger Japanese body")
        }
        print("NativeMailSendTests: \(checks) checks passed; durable SMTP intents, immutable MIME, uncertainty review, accepted recovery and privacy")
        return checks
    }
}
