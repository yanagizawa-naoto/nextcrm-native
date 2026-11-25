import Foundation

extension CRMService {
    func crmSweepNoticeAccess(_ id: String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id),NativeCRMSweepJobs.mailEvents.contains(job.event),
              identity.role == "admin" || (job.event == NativeCRMSweepJobs.killNotice && job.payload["recipientId"] == identity.id) else {
            throw NativeDBError.message("営業自動処理の通知が見つからないか、操作する権限がありません。")
        }
        return job
    }
    func crmSweepNotices(offset: Int = 0) throws -> [NativeJob] {
        try db.transaction {
            try authenticated()
            return try db.jobs(events:identity.role == "admin" ? NativeCRMSweepJobs.mailEvents:[NativeCRMSweepJobs.killNotice],recipientID:identity.role == "admin" ? nil:identity.id,offset:offset)
        }
    }
    func retryCRMSweepNotice(_ expected: NativeJob,now: Date = Date()) throws {
        try db.transaction {
            guard try crmSweepNoticeAccess(expected.id) == expected else { throw NativeDBError.conflict }
            try db.retryCRMAutomationNotice(expected,actor:identity.id,now:now)
        }
    }
    func cancelCRMSweepNotice(_ expected: NativeJob) throws {
        try db.transaction {
            guard try crmSweepNoticeAccess(expected.id) == expected else { throw NativeDBError.conflict }
            try db.cancelJob(id:expected.id,result:expected.result.merging(["cancelledBy":identity.id]){_,new in new})
            try db.deferTerminalMailBodyCleanup(id:expected.id)
        }
    }
    /// Source notifications were best-effort. This native review is the existing
    /// mail outbox recovery contract; it never resends or changes business rows.
    func reviewCRMSweepNotice(_ expected: NativeJob,outcome: MailReviewOutcome,providerID: String,note: String,now: Date = Date()) throws {
        let memo = note.trimmingCharacters(in:.whitespacesAndNewlines),raw = providerID.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !memo.isEmpty,memo.count <= 2000,memo.utf8.count <= 8000 else { throw NativeDBError.message("確認した内容を2,000文字以内で記入してください。") }
        let receipt: String?
        if outcome == .accepted {
            guard let value = UUID(uuidString:raw),value.uuidString.lowercased() == raw.lowercased() else { throw NativeDBError.message("送信サービスで確認した受付IDを入力してください。") }
            receipt = value.uuidString.lowercased()
        } else { guard raw.isEmpty else { throw NativeDBError.message("受付IDがある場合は「送信サービスの受付を確認」を選択してください。") };receipt = nil }
        try db.transaction {
            let current = try crmSweepNoticeAccess(expected.id)
            guard current == expected else { throw NativeDBError.conflict }
            guard current.canReviewMail else { throw NativeDBError.message("この通知は確認結果を記録できません。実行中の処理は完了を待ってください。") }
            if let known = current.result["providerID"],receipt != known.lowercased() { throw NativeDBError.message("保存済みの受付IDと矛盾する結果は記録できません。") }
            var result = current.result
            result["reviewOutcome"] = outcome.rawValue;result["reviewedBy"] = identity.id
            result["reviewerName"] = try db.get("Users",key:["id":.text(identity.id)])?["name"].string
            result["reviewedAt"] = try NativeCRMAutomationDates.stamp(now);result["reviewNote"] = memo
            result["reviewPreviousStatus"] = current.status;result["reviewPreviousError"] = current.lastError
            if let receipt { result["providerID"] = receipt;result["outcome"] = "sent" }
            else { result["outcome"] = outcome == .notSent ? "not_sent":"unconfirmed" }
            try db.completeReviewedMail(current,result:result,now:now)
            try db.deferTerminalMailBodyCleanup(id:current.id)
        }
        NotificationCenter.default.post(name:NativeDatabase.jobsDidChange,object:db,userInfo:["database":db.url.path])
    }
}
