import Foundation

/// Source: lib/crm/funnel-settings.ts + funnel-timers.ts. Values are not clamped
/// to UI ranges: imported settings are data, and source arithmetic accepts them.
struct NativeCRMAutomationSettings: Codable, Equatable {
    var killAfterDays = 45, recycleAfterDays = 90
    var cadenceTouch1BusinessDays = 3, cadenceTouch2OffsetDays = 7
    var cadenceTouch3OffsetDays = 10, cadenceTouch4OffsetDays = 15, cadenceTouch5OffsetDays = 45
    var careCheckinDays = 30, careReferralDays = 90, careQuarterIntervalDays = 90, careQuarterCount = 8
    var renewalWindowDays = 30
    static func load(_ db: NativeDatabase) throws -> Self {
        let fields = ["kill_after_days", "recycle_after_days", "cadence_touch1_business_days", "cadence_touch2_offset_days", "cadence_touch3_offset_days", "cadence_touch4_offset_days", "cadence_touch5_offset_days", "care_checkin_days", "care_referral_days", "care_quarter_interval_days", "care_quarter_count", "renewal_window_days"]
        guard let row = try db.mcpPage("crm_FunnelSettings", fields: fields, filter: .all, limit: 1, offset: 0, order: [], includeDeleted: true, allowEmptyOrder: true).rows.first else { return Self() }
        func number(_ name: String) throws -> Int { guard let n = Int(row[name].string) else { throw NativeDBError.message("商談の自動処理設定を読み取れません。") }; return n }
        return try Self(killAfterDays: number(fields[0]), recycleAfterDays: number(fields[1]), cadenceTouch1BusinessDays: number(fields[2]), cadenceTouch2OffsetDays: number(fields[3]), cadenceTouch3OffsetDays: number(fields[4]), cadenceTouch4OffsetDays: number(fields[5]), cadenceTouch5OffsetDays: number(fields[6]), careCheckinDays: number(fields[7]), careReferralDays: number(fields[8]), careQuarterIntervalDays: number(fields[9]), careQuarterCount: number(fields[10]), renewalWindowDays: number(fields[11]))
    }
}

enum NativeCRMAutomationDates {
    static func stamp(_ date: Date) throws -> String {
        // JavaScript Date supports ±8.64e15 ms. Foundation ISO rendering outside
        // four-digit years is not a source-compatible serializer: fail visibly.
        guard date.timeIntervalSince1970.isFinite else { throw NativeDBError.message("自動処理の日時が不正です。") }
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        let result = f.string(from: date)
        guard result.count == 24 else { throw NativeDBError.message("自動処理の日時が対応範囲を超えています。") }
        return result
    }
    static func parse(_ text: String) throws -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        if let result = f.date(from: text) { return result }
        f.formatOptions.remove(.withFractionalSeconds)
        guard let result = f.date(from: text) else { throw NativeDBError.message("自動処理に必要な日時を読み取れません。") }
        return result
    }
    static func sourceDateString(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone; f.dateFormat = "EEE MMM dd yyyy"; return f.string(from: date)
    }
}
