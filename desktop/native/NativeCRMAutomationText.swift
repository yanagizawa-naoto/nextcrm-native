import Foundation

/// Japanese display mapping of source-owned templates only. Customer/assignee
/// names and all stored identity, instant, status and scope values stay intact.
enum NativeCRMAutomationText {
    static func date(_ date: Date, zone: TimeZone) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "ja_JP"); format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone; format.dateFormat = "yyyy年M月d日（EEE）"; return format.string(from: date)
    }
}
