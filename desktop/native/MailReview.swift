import Foundation

/// Reviewing an ambiguous send never schedules another external request. A new
/// mail must be composed separately; its operator can see the recorded outcome.
enum MailReviewOutcome: String, CaseIterable {
    case accepted, notSent, unknown
    var label: String {
        switch self {
        case .accepted: return "送信サービスの受付を確認"
        case .notSent: return "送信されていないことを確認"
        case .unknown: return "結果不明のまま処理を終了"
        }
    }
}

extension NativeJob {
    var canReviewMail: Bool {
        ["invoice.email_requested","orders.approval_requested","orders.approval_decided","projects.task_assigned","projects.task_updated","projects.task_commented","crm.task_assigned","crm.task_watched","crm.lead_assigned","campaigns/send-step","reports.scheduled","crm.automation.kill.notice","crm.automation.recycle.notice"].contains(event) &&
        (deliveryStartedAt != nil || (event == "campaigns/send-step" && status == "needs_review")) && ["needs_review","failed","retry"].contains(status)
    }
}

