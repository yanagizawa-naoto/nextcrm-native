import Foundation

/// Only these local jobs may have their retry count reset. Mail keeps its
/// immutable body, original delivery time and provider idempotency history.
enum NativeCRMAutomationJobs {
    static let localEvents = [
        "crm/opportunity.stage-changed", "crm.automation.stage.touch",
        "crm.automation.renewals.scan", "crm.automation.renewals.task",
        "crm.automation.kill.scan", "crm.automation.kill.check",
        "crm.automation.recycle.scan", "crm.automation.recycle.apply",
    ]
    static let mailEvents = ["crm.automation.kill.notice", "crm.automation.recycle.notice"]
    static let events = localEvents + mailEvents
    static func title(_ event: String) -> String {
        switch event {
        case "crm/opportunity.stage-changed": return "商談ステージの確認"
        case "crm.automation.stage.touch": return "商談のフォロータスク"
        case "crm.automation.renewals.scan": return "契約更新の対象確認"
        case "crm.automation.renewals.task": return "契約更新のタスク"
        case "crm.automation.kill.scan": return "休眠商談の対象確認"
        case "crm.automation.kill.check": return "休眠商談の終了"
        case "crm.automation.recycle.scan": return "再開対象の抽出"
        case "crm.automation.recycle.apply": return "再開対象リストへの登録"
        case "crm.automation.kill.notice": return "商談終了の通知"
        case "crm.automation.recycle.notice": return "再開対象の通知"
        default: return "不明な処理"
        }
    }
    static func status(_ job: NativeJob) -> String {
        switch job.status {
        case "pending": return "待機中"
        case "running": return "実行中"
        case "retry": return "再試行待ち"
        case "failed": return "失敗"
        case "needs_review": return "送信結果の確認待ち"
        case "cancelled": return "取消済み"
        case "done":
            switch job.result["reviewOutcome"] {
            case "accepted": return "受付確認済み"
            case "notSent": return "未送信確認済み"
            case "unknown": return "結果不明・終了"
            default: return job.result["outcome"] == "skipped" ? "対象外" : "完了"
            }
        default: return "状態の確認が必要"
        }
    }
    static func canRetry(_ job: NativeJob) -> Bool {
        localEvents.contains(job.event) && ["failed", "retry"].contains(job.status) && job.deliveryStartedAt == nil
    }
    static func canCancel(_ job: NativeJob) -> Bool {
        localEvents.contains(job.event) && ["pending", "retry", "failed"].contains(job.status) && job.deliveryStartedAt == nil
    }
}

extension CRMService {
    private func requireAutomationAdministrator() throws {
        try authenticated()
        guard identity.role == "admin" else { throw NativeDBError.message("営業の自動処理を管理する権限がありません。") }
    }
    func crmAutomationJobs(offset: Int = 0) throws -> [NativeJob] {
        try db.transaction {
            try requireAutomationAdministrator()
            return try db.jobs(events: NativeCRMAutomationJobs.events, offset: offset)
        }
    }
    private func currentLocalAutomationJob(_ expected: NativeJob) throws -> NativeJob {
        try requireAutomationAdministrator()
        guard NativeCRMAutomationJobs.localEvents.contains(expected.event),
              let current = try db.job(id: expected.id), current == expected else { throw NativeDBError.conflict }
        return current
    }
    func retryCRMAutomationJob(_ expected: NativeJob) throws {
        try db.transaction {
            let current = try currentLocalAutomationJob(expected)
            guard NativeCRMAutomationJobs.canRetry(current) else { throw NativeDBError.message("この処理は再試行できません。") }
            // This existing DB primitive is independent of AI: exact-row CAS,
            // no external delivery, attempts=0, and a queue wake notification.
            try db.retryAIJob(current, events: NativeCRMAutomationJobs.localEvents)
        }
    }
    func cancelCRMAutomationJob(_ expected: NativeJob) throws {
        try db.transaction {
            let current = try currentLocalAutomationJob(expected)
            guard NativeCRMAutomationJobs.canCancel(current) else { throw NativeDBError.message("実行前の処理だけを取り消せます。") }
            var result = current.result
            result["outcome"] = "cancelled"; result["cancelledBy"] = identity.id
            try db.cancelJob(id: current.id, result: result)
        }
    }
}
