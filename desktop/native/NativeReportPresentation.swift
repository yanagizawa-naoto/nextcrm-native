import Foundation

enum NativeReportPresentation {
    static func label(_ name: String, section: String) -> String {
        if section == "usersByRole" { return ["Admin":"管理者","Manager":"マネージャー","User":"利用者","Partner":"パートナー"][name] ?? name }
        if section == "activitiesByType" { return ["call":"電話","meeting":"会議","note":"メモ","email":"メール","visit":"訪問"][name] ?? name }
        if section == "performance" { return ["Sent":"送信","Opened":"開封","Clicked":"クリック"][name] ?? name }
        if ["bySize","byIndustry","leadSources"].contains(section), name == "Unknown" { return "不明" }
        if ["oppsByStage","contactsByAccount","tasksByAssignee"].contains(section), name == "Unassigned" { return "未設定" }
        return name
    }
    static func number(_ raw: String) -> String {
        guard let number = Decimal(string:raw,locale:Locale(identifier:"en_US_POSIX")) else { return raw }
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier:"ja_JP"); formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8; formatter.minimumFractionDigits = 0
        return formatter.string(from:NSDecimalNumber(decimal:number)) ?? raw
    }
}

