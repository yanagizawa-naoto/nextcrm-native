import Foundation

struct CampaignStepInput {
    var order: Int64
    var templateID: String
    var subject: String
    var delayDays: Int64 = 0
    var sendTo = "all"
    var values: [String:SQLValue] { ["order":.integer(order),"template_id":.text(templateID),"subject":.text(subject),"delay_days":.integer(delayDays),"send_to":.text(sendTo)] }
    func validate() throws {
        guard order >= 0, delayDays >= 0, delayDays <= 365_000, !subject.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              UUID(uuidString:templateID) != nil, ["all","non_openers"].contains(sendTo) else { throw NativeDBError.message("配信手順の順番・件名・日数・テンプレートを確認してください。") }
    }
}

enum CampaignWorkflow {
    static let states = ["draft","scheduled","sending","sent","paused"]
    static let scheduleEvent = "campaigns/schedule"
    static let sendEvent = "campaigns/send-now"
    static let followUpEvent = "campaigns/follow-up"
    static let sendStepEvent = "campaigns/send-step"
    static let events = [scheduleEvent,sendEvent,followUpEvent,sendStepEvent]
    static let dispatchEvents = [scheduleEvent,sendEvent,followUpEvent]
    static func label(_ value: String) -> String { ["draft":"下書き","scheduled":"予約済み","sending":"配信中","sent":"初回配信処理済み","paused":"一時停止","deleted":"削除済み"][value] ?? (value.isEmpty ? "未設定" : value) }
    static func stamp(_ date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= -62_135_596_800, date.timeIntervalSince1970 < 253_402_300_800 else { throw NativeDBError.message("配信日時が範囲外です。") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds); return formatter.string(from:date)
    }
    static func date(_ value: SQLValue) -> Date? { let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f.date(from:value.string) ?? ISO8601DateFormatter().date(from:value.string) }
    static func followUpDate(_ base: Date, days: Int64) throws -> Date { let result = base.addingTimeInterval(Double(days)*86_400); _ = try stamp(result); return result }
    static func runKey(_ id: String) -> String { "campaign.run."+id }
    static func dispatchDoneKey(_ id: String) -> String { "campaign.dispatch.done."+id }
    static func followUpEligible(status: String, opened: Bool, unsubscribed: Bool, suppressed: Bool, sendTo: String) -> Bool {
        ["sent","delivered"].contains(status) && !unsubscribed && !suppressed && (sendTo != "non_openers" || !opened)
    }
    static func sendSkipReason(status: String, unsubscribed: Bool, suppressed: Bool) -> String? {
        if !["queued","failed"].contains(status) { return "already "+status }
        if unsubscribed { return "recipient unsubscribed" }
        if suppressed { return "recipient globally suppressed" }
        return nil
    }
    static func validateHeader(_ input: [String:SQLValue], current: NativeRecord?) throws {
        guard input.keys.allSatisfy({["name","description","from_name","reply_to","template_id"].contains($0)}) else { throw NativeDBError.message("キャンペーンの変更項目が不正です。") }
        let name = input["name"] ?? current?["name"] ?? .null
        guard !name.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeDBError.message("キャンペーン名を入力してください。") }
        if let from = input["from_name"], from.string.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) { throw NativeDBError.message("差出人名に改行や制御文字は使えません。") }
        if let reply = input["reply_to"], reply != .null, !reply.string.isEmpty {
            guard reply.string.range(of:#"^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$"#,options:.regularExpression) != nil else { throw NativeDBError.message("返信先メールアドレスを確認してください。") }
        }
    }
}
