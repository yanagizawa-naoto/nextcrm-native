import Foundation

/// Direct scalar form of funnel-timers.ts. Unlike its arrays, care entries are
/// generated one at a time, so imported counts do not allocate a huge schedule.
enum NativeCRMStageSchedule {
    struct Touch: Codable, Equatable { let title: String, content: String, due: String }
    static func validate(_ s: NativeCRMAutomationSettings) throws {
        let numbers = [s.killAfterDays, s.recycleAfterDays, s.cadenceTouch1BusinessDays, s.cadenceTouch2OffsetDays, s.cadenceTouch3OffsetDays, s.cadenceTouch4OffsetDays, s.cadenceTouch5OffsetDays, s.careCheckinDays, s.careReferralDays, s.careQuarterIntervalDays, s.careQuarterCount, s.renewalWindowDays]
        guard numbers.allSatisfy({ Int32(exactly: $0) != nil }) else { throw NativeDBError.message("保存された営業フォロー設定が整数の対応範囲を超えています。") }
    }
    private static func checkedDate(_ date: Date) throws -> Date {
        // Same explicit four-digit-year candidate boundary as the shared date
        // serializer, checked before asking Foundation to calculate a weekday.
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, seconds >= -62_167_219_200, seconds < 253_402_300_800 else { throw NativeDBError.message("営業フォローの予定日が対応範囲を超えています。") }
        return date
    }
    static func addBusinessDays(_ start: Date, count: Int) throws -> Date {
        _ = try checkedDate(start)
        guard Int32(exactly: count) != nil else { throw NativeDBError.message("営業日数が整数の対応範囲を超えています。") }
        guard count > 0 else { return start }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = start, remaining = count
        if [1, 7].contains(calendar.component(.weekday, from: date)) {
            repeat { date = try checkedDate(date.addingTimeInterval(86_400)) } while [1, 7].contains(calendar.component(.weekday, from: date))
            remaining -= 1
        }
        date = try checkedDate(date.addingTimeInterval(Double(remaining / 5) * 7 * 86_400)); remaining %= 5
        while remaining > 0 {
            date = try checkedDate(date.addingTimeInterval(86_400))
            if ![1, 7].contains(calendar.component(.weekday, from: date)) { remaining -= 1 }
        }
        return date
    }
    static func count(kind: String, settings: NativeCRMAutomationSettings) throws -> Int {
        try validate(settings)
        if kind == "qualified" { return 5 }; if kind != "care" { return 0 }
        let (result, overflow) = max(0, settings.careQuarterCount).addingReportingOverflow(2)
        guard !overflow else { throw NativeDBError.message("営業フォローの予約件数が対応範囲を超えています。") }
        return result
    }
    static func touch(kind: String, index: Int, entry: Date, settings s: NativeCRMAutomationSettings) throws -> Touch? {
        let total = try count(kind: kind, settings: s)
        guard index >= 0, index < total else { return nil }
        _ = try checkedDate(entry)
        let title: String, content: String, date: Date
        if kind == "qualified" {
            let t1 = try addBusinessDays(entry, count: s.cadenceTouch1BusinessDays)
            let t2 = t1.addingTimeInterval(Double(s.cadenceTouch2OffsetDays) * 86_400)
            let t3 = t2.addingTimeInterval(Double(s.cadenceTouch3OffsetDays) * 86_400)
            date = [t1, t2, t3, t3.addingTimeInterval(Double(s.cadenceTouch4OffsetDays) * 86_400), t3.addingTimeInterval(Double(s.cadenceTouch5OffsetDays) * 86_400)][index]
            title = ["Cadence 1/5: Call — confirm quote receipt", "Cadence 2/5: Email check-in", "Cadence 3/5: Email or call", "Cadence 4/5: Call (day 15 of retention window)", "Cadence 5/5: Final reminder — offer 15-day quote extension"][index]
            content = ["Call the client: confirm they received the quote/SOW and ask for questions.", "Send a short check-in email about the outstanding quote.", "Reach out (email or call) — surface objections, offer a walkthrough.", "Call the client — the quote has been out ~5 weeks; probe timeline and blockers.", "Send the final reminder email; offer to extend the quote validity by 15 days if they need more time."][index]
        } else {
            let days: Double
            if index == 0 {
                days = Double(s.careCheckinDays); title = "Care: \(s.careCheckinDays)-day check-in"
                content = "Check in with the client — satisfaction, issues, quick wins since deployment."
            } else if index == 1 {
                days = Double(s.careReferralDays); title = "Care: referral ask"
                content = "Results should be measurable by now — ask for a referral and probe upsell openings."
            } else {
                days = Double(s.careReferralDays) + Double(index - 1) * Double(s.careQuarterIntervalDays)
                title = "Care: quarterly check-in (Q\(index - 1))"
                content = "Quarterly relationship check-in — satisfaction, renewals, expansion opportunities."
            }
            date = entry.addingTimeInterval(days * 86_400)
        }
        return try .init(title: title, content: content, due: NativeCRMAutomationDates.stamp(checkedDate(date)))
    }
}
