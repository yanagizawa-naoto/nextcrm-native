import Foundation

/// Administrative editing of the same settings consumed by CRM automation.
struct NativeCRMFunnelSettings {
    struct Field {
        let key: String, column: String, label: String, group: String
        let path: WritableKeyPath<NativeCRMAutomationSettings, Int>
        var range: ClosedRange<Int> { key == "careQuarterCount" ? 0...24 : 1...365 }
        var unit: String { key == "careQuarterCount" ? "回" : key == "cadenceTouch1BusinessDays" ? "営業日" : "日" }
    }
    static let fields: [Field] = [
        .init(key: "killAfterDays", column: "kill_after_days", label: "顧客から返信がない場合に商談を終了するまでの日数", group: "商談の終了・営業対象の再開", path: \.killAfterDays),
        .init(key: "recycleAfterDays", column: "recycle_after_days", label: "営業ステップ終了後に営業対象を再開するまでの日数", group: "商談の終了・営業対象の再開", path: \.recycleAfterDays),
        .init(key: "cadenceTouch1BusinessDays", column: "cadence_touch1_business_days", label: "1回目の連絡：見積もり送付後の営業日数", group: "見積もり送付後の連絡", path: \.cadenceTouch1BusinessDays),
        .init(key: "cadenceTouch2OffsetDays", column: "cadence_touch2_offset_days", label: "2回目の連絡：1回目からの日数", group: "見積もり送付後の連絡", path: \.cadenceTouch2OffsetDays),
        .init(key: "cadenceTouch3OffsetDays", column: "cadence_touch3_offset_days", label: "3回目の連絡：2回目からの日数", group: "見積もり送付後の連絡", path: \.cadenceTouch3OffsetDays),
        .init(key: "cadenceTouch4OffsetDays", column: "cadence_touch4_offset_days", label: "4回目の連絡：3回目からの日数", group: "見積もり送付後の連絡", path: \.cadenceTouch4OffsetDays),
        .init(key: "cadenceTouch5OffsetDays", column: "cadence_touch5_offset_days", label: "5回目（最終）の連絡：3回目からの日数", group: "見積もり送付後の連絡", path: \.cadenceTouch5OffsetDays),
        .init(key: "careCheckinDays", column: "care_checkin_days", label: "フォロー連絡までの日数", group: "顧客フォロー・更新", path: \.careCheckinDays),
        .init(key: "careReferralDays", column: "care_referral_days", label: "紹介依頼までの日数", group: "顧客フォロー・更新", path: \.careReferralDays),
        .init(key: "careQuarterIntervalDays", column: "care_quarter_interval_days", label: "定期フォローの間隔", group: "顧客フォロー・更新", path: \.careQuarterIntervalDays),
        .init(key: "careQuarterCount", column: "care_quarter_count", label: "定期フォローの回数", group: "顧客フォロー・更新", path: \.careQuarterCount),
        .init(key: "renewalWindowDays", column: "renewal_window_days", label: "更新予定を表示するまでの残り日数", group: "顧客フォロー・更新", path: \.renewalWindowDays),
    ]
    struct Snapshot {
        let settings: NativeCRMAutomationSettings
        let record: NativeRecord?
    }
    let service: CRMService

    func requireAdministrator() throws {
        try service.authenticated()
        guard service.identity.role == "admin" else { throw NativeDBError.message("営業フローは管理者が設定してください。") }
    }
    private func firstRecord() throws -> NativeRecord? {
        guard let row = try service.db.mcpPage("crm_FunnelSettings", fields: [], filter: .all, limit: 1,
            offset: 0, order: [], includeDeleted: true, allowEmptyOrder: true).rows.first else { return nil }
        guard let full = try service.db.get("crm_FunnelSettings", key: ["id": row["id"]]) else { throw NativeDBError.conflict }
        return full
    }
    func load() throws -> Snapshot {
        try service.db.transaction {
            try requireAdministrator()
            return Snapshot(settings: try NativeCRMAutomationSettings.load(service.db), record: try firstRecord())
        }
    }
    @discardableResult
    func save(_ settings: NativeCRMAutomationSettings, expected: Snapshot) throws -> Snapshot {
        try service.db.transaction {
            try requireAdministrator()
            var values: [String: SQLValue] = [:]
            for field in Self.fields {
                let value = settings[keyPath: field.path]
                guard field.range.contains(value) else {
                    throw NativeDBError.message("\(field.label)は\(field.range.lowerBound)〜\(field.range.upperBound)の整数で入力してください。")
                }
                values[field.column] = .integer(Int64(value))
            }
            values["updatedBy"] = .text(service.identity.id)
            let current = try firstRecord()
            // The native form must not overwrite another window's newer save.
            guard current?["id"] == expected.record?["id"], current?.revision == expected.record?.revision else {
                throw NativeDBError.conflict
            }
            let saved: NativeRecord
            if let current { saved = try service.db.update(current, changes: values, actor: service.identity.id) }
            else { saved = try service.db.insert("crm_FunnelSettings", values: values, actor: service.identity.id) }
            return Snapshot(settings: settings, record: saved)
        }
    }
}
