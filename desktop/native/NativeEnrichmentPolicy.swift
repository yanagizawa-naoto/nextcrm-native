import Foundation

/// AgentEnrichmentStrategy's original skip-list rules. This checkout does not
/// ship app/fire-enrich/skip-list.txt, so the original seven-domain fallback is
/// the default. A supplied list replaces that fallback, as in the source loader.
struct NativeEnrichmentSkipList {
    let domains: Set<String>
    init(contents: String? = nil) {
        if let contents {
            domains = Set(contents.components(separatedBy: "\n").map { NativeAIEnvironment.trim($0).lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
        } else { domains = ["gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "aol.com", "icloud.com", "protonmail.com"] }
    }
    func reason(_ email: String) -> String? {
        let parts = email.components(separatedBy: "@")
        guard parts.count > 1, !parts[1].isEmpty else { return nil }
        let domain = parts[1].lowercased()
        if domains.contains(domain) {
            if ["gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "aol.com", "icloud.com"].contains(domain) { return "一般向けメールサービスのため、会社情報の補完を省略しました。" }
            return domain.contains("mail") ? "一時利用・無料メールサービスのため、情報補完を省略しました。" : "情報補完の対象外ドメインです。"
        }
        if domain.hasSuffix(".edu") || domain.hasSuffix(".ac.uk") { return "教育機関のメールドメインのため、会社情報の補完を省略しました。" }
        return nil
    }
}
