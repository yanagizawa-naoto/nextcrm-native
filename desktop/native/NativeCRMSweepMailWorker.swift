import Foundation
import CryptoKit

/// Existing immutable-body/Resend idempotency contract, with a paged snapshot
/// of all digest recipients. The common host supplies its existing sender gate.
actor NativeCRMSweepMailWorker {
    let db: NativeDatabase, account: () throws -> InvoiceMailAccount, request: ResendMailClient.Request, clock: () -> Date
    private var active = false
    init(db: NativeDatabase, account: @escaping () throws -> InvoiceMailAccount,
         request: @escaping ResendMailClient.Request = ResendMailClient.request, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.account = account; self.request = request; self.clock = clock
    }
    private struct ChangedRecipient: LocalizedError { var errorDescription: String? { "通知予約後に宛先が削除・変更されています。" } }
    private var root: URL { db.url.deletingLastPathComponent() }
    private func recipients(_ job: NativeJob, visit: (String) throws -> Void = { _ in }) throws -> Int {
        var count = 0
        func one(_ id: String, _ email: String, administrator: Bool) throws {
            guard let user = try db.keysetPage("Users",fields:["email","role","userStatus"],filter:.equal("id",.text(id)),includeDeleted:true,limit:1).first,
                  user["email"].string == email, !administrator || (user["role"] == .text("admin") && user["userStatus"] == .text("ACTIVE")) else { throw ChangedRecipient() }
            // Preserve the original selection semantics: rep status and admin
            // banned flag were not filters. No identity or access is issued here.
            try visit(InvoiceMail.mailbox(email)); count += 1
        }
        if job.event == NativeCRMSweepJobs.killNotice {
            guard let id = job.payload["recipientId"],let email = job.payload["recipientEmail"] else { throw NativeDBError.conflict }
            try one(id,email,administrator:false)
        } else if job.event == NativeCRMSweepJobs.recycleNotice {
            var after: String?
            while true {
                try Task.checkCancellation();_ = try db.requireJobLease(job)
                let rows = try db.crmAutomationSnapshotPage(ownerID:job.id,kind:"recipient",after:after)
                for row in rows { let value = try JSONDecoder().decode(NativeCRMSweepJobs.Recipient.self,from:Data(row.value.utf8));try one(value.id,value.email,administrator:true) }
                if rows.count < 100 { break };after = rows.last!.key
            }
            guard count > 0,count == job.payload["recipientCount"].flatMap(Int.init) else { throw NativeDBError.conflict }
        } else { throw NativeDBError.conflict }
        return count
    }
    private func prepare(_ job: NativeJob, sender: String) throws -> NativeJob {
        try db.transaction {
            let current = try db.requireJobLease(job);_ = try recipients(current)
            if current.result["sha256"] != nil { return current }
            guard current.deliveryStartedAt == nil,let subject = current.payload["subject"],let message = current.payload["message"] else {
                throw MailSendError(message:"営業通知の保存内容を確認できません。",retryable:false,review:current.deliveryStartedAt != nil)
            }
            let url = try InvoiceMail.bodyURL(root:root,id:current.id)
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
            let body = try InvoiceMail.prepareTextRecipients(root:root,id:current.id,from:sender,subject:subject,message:message) { emit in _ = try recipients(current,visit:emit) }
            do {
                try db.recordJobResult(current,result:current.result.merging(["from":try InvoiceMail.mailbox(sender),"sha256":body.sha256,"bytes":String(body.bytes)]) { _,new in new })
                return try db.requireJobLease(current)
            } catch { try? FileManager.default.removeItem(at:url);throw error }
        }
    }
    private func complete(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let id = current.result["providerID"],UUID(uuidString:id) != nil else { throw NativeDBError.conflict }
            try db.finishJob(current,result:current.result,now:clock());try db.deferTerminalMailBodyCleanup(id:current.id)
        }
    }
    private func attemptsInBudget(_ job: NativeJob) throws -> Int {
        guard let raw = job.result["manualRetryAttemptBase"] else { return job.attempts }
        guard let base = Int(raw),raw == String(base),base >= 0,base <= job.attempts else {
            throw MailSendError(message:"手動再試行の記録が不正です。通知の履歴を確認してください。",retryable:false,review:job.deliveryStartedAt != nil)
        }
        return max(1,job.attempts-base)
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false };active = true;defer { active = false }
        try Task.checkCancellation()
        guard var job = try db.claimJob(events:NativeCRMSweepJobs.mailEvents,now:clock()) else { return false }
        var externalAttempt = false
        do {
            if job.result["providerID"] != nil { try complete(job);return true }
            if let begun = job.deliveryStartedAt,clock() < begun || clock().timeIntervalSince(begun) >= 23*3600 {
                throw MailSendError(message:"重複防止期間を超えています。送信サービスで営業通知の結果を確認してください。",retryable:false,review:true)
            }
            _ = try attemptsInBudget(job)
            _ = try db.transaction { try recipients(job) }
            let credentials = try account(),key = credentials.apiKey
            guard !key.isEmpty,!key.contains("\r"),!key.contains("\n") else { throw NativeDBError.message("通知メールの送信設定を確認してください。") }
            let digest = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
            if job.deliveryStartedAt != nil,job.result["credentialSHA256"] != digest {
                throw MailSendError(message:"営業通知の送信開始後にAPIキーが変わりました。送信結果を確認してください。",retryable:false,review:true)
            }
            job = try prepare(job,sender:credentials.from)
            let file = try InvoiceMail.bodyURL(root:root,id:job.id)
            guard let hash = job.result["sha256"],let size = job.result["bytes"].flatMap(Int.init) else { throw NativeDBError.conflict }
            try InvoiceMail.verify(file,sha256:hash,bytes:size)
            job = try db.transaction {
                try Task.checkCancellation();let current = try db.requireJobLease(job);_ = try recipients(current)
                try db.renewJobLease(current,now:clock())
                try db.recordJobResult(current,result:current.result.merging(["credentialSHA256":digest]) { _,new in new })
                return try db.markJobDeliveryStarted(current,now:clock())
            }
            externalAttempt = true
            let receipt = try await ResendMailClient.send(body:file,jobID:job.id,apiKey:key,scope:"crm-automation",request:request)
            try db.transaction {
                let current = try db.requireJobLease(job)
                try db.recordJobResult(current,result:current.result.merging(["providerID":receipt,"acceptedAt":try NativeCRMAutomationDates.stamp(clock()),"outcome":"sent"]) { _,new in new })
            }
            try complete(job)
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if error is ChangedRecipient {
                if current.deliveryStartedAt == nil { try db.transaction { try db.finishJob(current,result:current.result.merging(["outcome":"skipped","reason":error.localizedDescription]) { _,new in new },now:clock());try db.deferTerminalMailBodyCleanup(id:current.id) } }
                else { try db.failJob(current,message:error.localizedDescription+" 以前の送信結果を確認してください。",needsReview:true) }
                return true
            }
            let mail = error as? MailSendError
            let retryable = mail?.retryable ?? (externalAttempt || current.result["providerID"] != nil || error is CancellationError || { if case NativeDBError.conflict = error { return true };return false }())
            let used = try? attemptsInBudget(current)
            let retry = retryable && used.map { $0 < 8 } == true && mail?.review != true
            let exhausted = !retry && retryable && current.deliveryStartedAt != nil && current.result["providerID"] == nil
            let delay = error is CancellationError ? 0 : max(mail?.retryAfter ?? 0,min(300,5*pow(2,Double(min(current.attempts-1,6)))))
            try db.failJob(current,message:exhausted ? "再試行の上限に達しました。営業通知の送信結果を確認してください。":mail?.message ?? error.localizedDescription,retryAt:retry ? clock().addingTimeInterval(delay):nil,needsReview:mail?.review == true || exhausted)
        }
        return true
    }
}
