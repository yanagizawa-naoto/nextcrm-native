import Foundation

enum NativeEnrichmentPhase: String, CaseIterable, Codable {
    case discovery, profile, metrics, funding, techStack, other
    var title: String {
        switch self { case .discovery: return "会社の確認"; case .profile: return "会社概要"; case .metrics: return "従業員数・売上"
        case .funding: return "資金調達"; case .techStack: return "利用技術"; case .other: return "その他の項目" }
    }
}

/// Personal findings need an identified person in the source body and in the
/// quoted evidence. A company domain alone cannot establish a person's details.
enum NativeEnrichmentPerson {
    private static func normalized(_ text: String) -> String {
        NativeEnrichmentText.normalized(text.precomposedStringWithCompatibilityMapping).lowercased()
    }
    private static func email(_ text: String, identity: NativeEnrichmentIdentity) -> Bool {
        guard !identity.email.isEmpty else { return false }
        return NativeEnrichmentText.matches(normalized(text), #"(?<![A-Za-z0-9_.+\-])"# + NSRegularExpression.escapedPattern(for: normalized(identity.email)) + #"(?![A-Za-z0-9_.\-])"#)
    }
    static func identifies(_ text: String, identity: NativeEnrichmentIdentity) -> Bool {
        if email(text, identity: identity) { return true }
        guard let name = identity.personalName, !name.isEmpty else { return false }
        let words = NativeEnrichmentText.words(normalized(name))
        if NativeEnrichmentText.matches(name, #"[\p{Han}\p{Hiragana}\p{Katakana}]"#) {
            let compact = normalized(text).filter { !$0.isWhitespace }
            if compact.contains(words.joined()) { return true }
            // Japanese data may store given/family names in Western field order.
            return words.count == 2 && words.allSatisfy { NativeEnrichmentText.matches($0, #"^[\p{Han}\p{Hiragana}\p{Katakana}]+$"#) } && compact.contains(words.reversed().joined())
        }
        let pattern = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"\s+"#)
        return !pattern.isEmpty && NativeEnrichmentText.matches(normalized(text), #"(?<![\p{L}\p{N}])"# + pattern + #"(?![\p{L}\p{N}])"#)
    }
    static func matches(_ page: NativeEnrichmentPage, identity: NativeEnrichmentIdentity) -> Bool {
        guard let body = page.markdown, !body.isEmpty, NativeEnrichmentIdentity.websiteDomain(page.url) != nil else { return false }
        if email(body, identity: identity) { return true }
        guard identifies(body, identity: identity) else { return false }
        if let domain = identity.companyDomain, let host = NativeEnrichmentIdentity.websiteDomain(page.url), host == domain.lowercased() || host.hasSuffix("." + domain.lowercased()) { return true }
        if let name = identity.name, !name.isEmpty, normalized(body).contains(normalized(name)) { return true }
        // Without a known employer, email is the available disambiguator. Do
        // not pick the first person with a matching name from public search.
        return identity.email.isEmpty && identity.name == nil && identity.companyDomain == nil
    }
    static func queries(_ identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField]) -> [String] {
        func quoted(_ value: String) -> String { "\"" + NativeEnrichmentText.replace(value, #"[\"\r\n]"#, " ") + "\"" }
        var anchors: [String] = []
        if let name = identity.personalName, !name.isEmpty {
            anchors.append(quoted(name) + (identity.name.map { " " + quoted($0) } ?? ""))
        }
        if !identity.email.isEmpty { anchors.append(quoted(identity.email)) }
        var result: [String] = []
        for field in fields {
            for anchor in anchors {
                let query = anchor + " " + NativeEnrichmentRouting.terms(field)
                if !result.contains(query) { result.append(query) }
            }
        }
        return result
    }
    static func validated(_ input: [String: NativeEnrichmentResult], identity: NativeEnrichmentIdentity, pages: [NativeEnrichmentPage]) -> [String: NativeEnrichmentResult] {
        var result: [String: NativeEnrichmentResult] = [:]
        for (name, value) in input where value.value.truthy {
            if name == "personal_website", let url = URL(string: value.value.text),
               let company = identity.companyDomain, NativeEnrichmentIdentity.websiteDomain(url.absoluteString) == company.lowercased(),
               url.path.isEmpty || url.path == "/" { continue }
            if name == "social_linkedin", let url = URL(string: value.value.text),
               let host = url.host?.lowercased(), host == "linkedin.com" || host.hasSuffix(".linkedin.com"),
               url.path.lowercased().hasPrefix("/company/") || url.path.lowercased().hasPrefix("/school/") { continue }
            let evidence = (value.sourceContext ?? []).filter { source in
                identifies(source.snippet, identity: identity) && NativeEnrichmentText.containsValue(source.snippet, value: value.value) &&
                pages.contains { $0.url == source.url && matches($0, identity: identity) &&
                    normalized($0.markdown ?? "").contains(normalized(source.snippet)) }
            }
            guard !evidence.isEmpty else { continue }
            var safe = value; safe.sourceContext = evidence; safe.source = Array(Set(evidence.map(\.url))).sorted().joined(separator: ", ")
            safe.sourceCount = Set(evidence.map(\.url)).count
            if let corroboration = value.corroboration {
                safe.corroboration = .init(evidence: corroboration.evidence.filter { item in evidence.contains { $0.url == item.source_url && $0.snippet == item.exact_text } }, sources_agree: corroboration.sources_agree)
            }
            result[name] = safe
        }
        return result
    }
}

struct NativeEnrichmentIdentity: Equatable {
    var email: String, domain: String, companyDomain: String?, personalName: String?, companyNameGuess: String?
    var isPersonalEmail: Bool
    var companyName: String? = nil
    var name: String? { companyName.flatMap { $0.isEmpty ? nil : $0 } ?? companyNameGuess.flatMap { $0.isEmpty ? nil : $0 } }
    static func websiteDomain(_ website: String?) -> String? {
        guard let website, let url = URL(string: website), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { return nil }
        return NativeEnrichmentText.replace(host.lowercased(), #"^www\."#)
    }
    init(email: String?, companyName: String? = nil, website: String? = nil, personName: String? = nil) throws {
        let email = NativeAIEnvironment.trim(email ?? ""), explicit = NativeAIEnvironment.trim(companyName ?? "")
        guard !email.isEmpty || !explicit.isEmpty else { throw NativeAIError(message: "メールアドレスまたは会社名を指定してください。") }
        self.email = email; domain = ""; isPersonalEmail = false
        if !email.isEmpty {
            let parts = email.components(separatedBy: "@")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw NativeAIError(message: "調査するメールアドレスの形式を確認してください。") }
            domain = parts[1]; isPersonalEmail = ["gmail.com", "yahoo.com", "yahoo.co.jp", "outlook.com", "hotmail.com", "icloud.com", "aol.com", "protonmail.com", "me.com"].contains(domain.lowercased())
            if !isPersonalEmail { companyDomain = domain }
            if !isPersonalEmail, domain.contains(".") { companyNameGuess = NativeEnrichmentText.capitalizedDomain(domain) }
            let names = parts[0].components(separatedBy: CharacterSet(charactersIn: "._-"))
            if names.count >= 2, let first = names.first, let last = names.last, !first.isEmpty, !last.isEmpty { personalName = first + " " + last }
            else if let first = NativeEnrichmentText.captures(parts[0], #"^([a-z]+)([A-Z][a-z]+)$"#).first,
                    let last = NativeEnrichmentText.captures(parts[0], #"^([a-z]+)([A-Z][a-z]+)$"#, group: 2).first { personalName = first + " " + last.lowercased() }
        }
        if let supplied = Self.websiteDomain(website) { companyDomain = supplied }
        if domain.isEmpty { domain = companyDomain ?? "" }
        // A personal email provider is not the target's company. Honour an
        // explicitly supplied company name instead of searching for "Gmail".
        if !explicit.isEmpty { companyNameGuess = explicit }
        let person = NativeEnrichmentText.normalized(personName ?? "")
        if !person.isEmpty { personalName = person }
    }
}

enum NativeEnrichmentRouting {
    static func person(_ f: NativeEnrichmentField) -> Bool {
        f.subject == .person || ["personal_website", "personal_email"].contains(f.name.lowercased())
    }
    static func companyName(_ f: NativeEnrichmentField) -> Bool {
        let name = f.name.lowercased()
        return name == "company" || name.contains("company") && name.contains("name") || ["会社名", "企業名", "社名"].contains { f.name.contains($0) || f.displayName.contains($0) }
    }
    static func website(_ f: NativeEnrichmentField) -> Bool {
        !person(f) && (f.name.lowercased().contains("website") || ["ウェブサイト", "ホームページ", "公式サイト"].contains { f.name.contains($0) || f.displayName.contains($0) })
    }
    static func description(_ f: NativeEnrichmentField) -> Bool {
        f.name.lowercased().contains("description") || f.description.lowercased().contains("description") || ["事業内容", "会社説明", "会社の説明", "企業概要"].contains { f.name.contains($0) || f.displayName.contains($0) }
    }
    static func phase(_ f: NativeEnrichmentField) -> NativeEnrichmentPhase {
        if person(f) { return .other }
        let name = f.name.lowercased(), desc = f.description.lowercased(), japanese = f.name + " " + f.displayName + " " + f.description
        func has(_ terms: [String]) -> Bool { terms.contains { japanese.contains($0) } }
        if companyName(f) || website(f) || name.contains("description") && name.contains("company") || desc.contains("company name") || desc.contains("company description") || has(["会社の事業内容", "会社説明", "会社の説明", "企業概要"]) { return .discovery }
        if ["industry", "location", "headquarter", "founded"].contains(where: name.contains) || has(["業種", "所在地", "本社", "設立", "創業"]) { return .profile }
        if ["employee", "revenue", "size"].contains(where: name.contains) || has(["従業員", "社員数", "売上", "年商", "企業規模"]) { return .metrics }
        if ["fund", "invest", "valuation"].contains(where: name.contains) || has(["資金調達", "投資家", "調達額", "企業価値"]) { return .funding }
        if name.contains("tech") && name.contains("stack") || ["technolog", "framework", "language", "github"].contains(where: name.contains) || ["tech stack", "programming", "technology"].contains(where: desc.contains) || has(["技術スタック", "利用技術", "フレームワーク", "開発言語", "プログラミング言語"]) { return .techStack }
        return .other
    }
    static func executive(_ f: NativeEnrichmentField) -> Bool {
        let text = (f.name + " " + f.description + " " + f.displayName).lowercased()
        return ["ceo", "cto", "cfo", "coo", "cmo", "cpo", "chief", "founder", "president", "director", "代表取締役", "社長", "創業者", "最高経営責任者", "最高技術責任者", "最高財務責任者", "取締役"].contains(where: text.contains)
    }
    static func title(_ f: NativeEnrichmentField) -> String {
        let name = f.name.lowercased(), desc = f.description.lowercased(), all = f.name + " " + f.description + " " + f.displayName
        for (short, full, jp) in [("ceo", "chief executive", ["最高経営責任者", "代表取締役", "社長"]), ("cto", "chief technology", ["最高技術責任者"]), ("cfo", "chief financial", ["最高財務責任者"]), ("coo", "chief operating", ["最高執行責任者"]), ("cmo", "chief marketing", ["最高マーケティング責任者"]), ("cpo", "chief product", ["最高製品責任者"])] {
            if name.contains(short) || desc.contains(full) || jp.contains(where: all.contains) { return short.uppercased() }
        }
        if name.contains("founder") || all.contains("創業者") { return "founder" }; if name.contains("president") { return "president" }
        return f.name
    }
    static func terms(_ f: NativeEnrichmentField) -> String {
        let words = NativeEnrichmentText.words(NativeEnrichmentText.replace(f.description.lowercased(), #"[^\w\s]"#, " "))
        // ICU's Unicode word matching retains Japanese search terms; the source
        // JavaScript expression stripped them out entirely.
        let selected = words.filter { $0.utf16.count > 3 && !["this", "that", "what", "when", "where", "which"].contains($0) }
        return ([f.name] + selected.prefix(3)).joined(separator: " ")
    }
    static func generalQueries(_ fields: [NativeEnrichmentField], name: String?, domain: String?) -> [String] {
        var result: [String] = []; let executives = fields.filter(executive)
        if !executives.isEmpty {
            if let name, !name.isEmpty { result += ["\"\(name)\" leadership team executives \(executives.map(title).joined(separator: " "))", "\"\(name)\" CEO CTO CFO founders management"] }
            if let domain, !domain.isEmpty { result.append("site:\(domain) team leadership about executives") }
        }
        for field in fields where !executive(field) {
            if let name, !name.isEmpty { result.append("\"\(name)\" \(terms(field))") }
            if let domain, !domain.isEmpty { result.append("site:\(domain) \(terms(field))") }
        }
        return result
    }
}
