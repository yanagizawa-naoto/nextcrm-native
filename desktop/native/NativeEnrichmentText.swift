import Foundation

enum NativeEnrichmentText {
    static func prefix(_ text: String, _ units: Int) -> String { NativeDocumentAIText.prefix(text, units: max(0, units)) }
    static func replace(_ text: String, _ pattern: String, _ replacement: String = "", options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    static func captures(_ text: String, _ pattern: String, group: Int = 1, options: NSRegularExpression.Options = []) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }; return String(text[range])
        }
    }
    static func matches(_ text: String, _ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func words(_ text: String) -> [String] { text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty } }
    static func normalized(_ text: String) -> String { NativeAIEnvironment.trim(replace(text, #"\s+"#, " ")) }
    static func unique(_ pages: [NativeEnrichmentPage]) -> [NativeEnrichmentPage] {
        var result: [NativeEnrichmentPage] = [], positions: [String: Int] = [:]
        for page in pages {
            if let position = positions[page.url] { result[position] = page }
            else { positions[page.url] = result.count; result.append(page) }
        }
        return result
    }
    static func content(_ pages: [NativeEnrichmentPage], maximumUnits: Int = 300_000) -> String {
        let total = pages.reduce(0) { $0 + ($1.originalMarkdownUnits ?? $1.markdown?.utf16.count ?? 0) }
        let each = max(1000, maximumUnits / max(1, pages.count))
        return pages.map { page in
            let body = page.markdown ?? ""
            let text = total > maximumUnits && (page.originalMarkdownUnits ?? body.utf16.count) > each ? prefix(body, each) + "\n[... content trimmed ...]" : body
            return "URL: \(page.url)\n[PAGE TITLE - NOT CONTENT]: \(page.title.isEmpty ? "No title" : page.title)\n\n=== ACTUAL CONTENT BELOW ===\n\(text)"
        }.joined(separator: "\n\n---\n\n")
    }
    static func allowedSource(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return true }
        return !["linkedin.com", "facebook.com", "twitter.com", "instagram.com"].contains { host.contains($0) }
    }
    static func github(_ url: String) -> Bool {
        guard let host = URL(string: url.contains("://") ? url : "https://" + url)?.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }
    private static func numberPatterns(_ number: Double) -> [String] {
        let format = NumberFormatter(); format.locale = Locale(identifier: "en_US"); format.numberStyle = .decimal; format.maximumFractionDigits = 16
        let variants = [NativeEnrichmentValue.number(number).text, format.string(from: NSNumber(value: number)),
                        abs(number) >= 1000 ? NativeEnrichmentValue.number(number / 1000).text + "k" : nil,
                        abs(number) >= 1_000_000 ? NativeEnrichmentValue.number(number / 1_000_000).text + "m" : nil].compactMap { $0 }
        // Do not accept 150 inside 1500, -150 or 150.5. Japanese units such as
        // 人 are valid boundaries, unlike the original ASCII word-boundary use.
        return variants.map { #"(?<![A-Za-z0-9.,+−\-])"# + NSRegularExpression.escapedPattern(for: $0) + #"(?![A-Za-z0-9]|[.,][0-9])"# }
    }
    static func containsValue(_ text: String, value: NativeEnrichmentValue) -> Bool {
        guard !text.isEmpty, value != .null else { return false }
        let lower = text.lowercased()
        switch value {
        case .null: return false
        case let .array(values): return values.contains { $0.utf16.count > 2 && lower.contains($0.lowercased()) }
        case .boolean: return lower.contains(value.text)
        case let .number(number):
            return numberPatterns(number).contains { matches(text, $0, options: .caseInsensitive) }
        case let .string(raw):
            let value = raw.lowercased()
            if value.utf16.count <= 20 { return lower.contains(value) }
            let significant = words(value).filter { $0.utf16.count > 3 }
            return significant.filter { lower.contains($0) }.count >= Int(ceil(Double(significant.count) * 0.5))
        }
    }
    static func snippet(_ content: String, value: NativeEnrichmentValue) -> String {
        guard !content.isEmpty, value.truthy else { return "" }
        if case .array = value { return "" }; if case .boolean = value { return "" }
        let lower = content.lowercased(), search = value.text.lowercased()
        var found: NSRange?
        if case let .number(number) = value {
            for pattern in numberPatterns(number) {
                let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                if let match = regex?.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) { found = match.range; break }
            }
        } else {
            if let range = lower.range(of: search) { found = NSRange(range, in: lower) }
            if found == nil, search.utf16.count > 20 {
                for word in words(search) where word.utf16.count > 3 {
                    if let range = lower.range(of: word) { found = NSRange(range, in: lower); break }
                }
            }
        }
        guard let found else { return "" }
        let start = max(0, found.location - 200), end = min(content.utf16.count, found.location + search.utf16.count + 200)
        let slice = String(decoding: content.utf16.dropFirst(start).prefix(max(0, end - start)), as: UTF16.self)
        return normalized((start > 0 ? "..." : "") + slice + (end < content.utf16.count ? "..." : ""))
    }
    static let knownCompanies = ["onetrust":"OneTrust", "sideguide":"Sideguide", "frontapp":"Front", "shippo":"Shippo", "lattice":"Lattice", "pilot":"Pilot", "fundera":"Fundera", "flexport":"Flexport", "triplebyte":"Triplebyte", "zola":"Zola", "pinterest":"Pinterest", "brex":"Brex", "deel":"Deel", "scale":"Scale AI", "wiz":"Wiz", "firecrawl":"Firecrawl"]
    static func capitalizedDomain(_ domain: String, underscores: Bool = false) -> String {
        let base = domain.components(separatedBy: ".")[0].lowercased()
        if let known = knownCompanies[base] { return known }
        let input = underscores ? base.replacingOccurrences(of: "_", with: "-") : base
        return input.components(separatedBy: "-").map { String($0.prefix(1)).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
    static func validCompany(_ page: NativeEnrichmentPage) -> Bool {
        let markdown = (page.markdown ?? "").lowercased(), title = (page.metadata?.title ?? "").lowercased()
        let invalid = ["domain for sale", "domain is for sale", "buy this domain", "purchase this domain", "make an offer", "domain parking", "parked domain", "under construction", "coming soon", "website is under construction", "this site is currently unavailable", "account suspended", "default web page", "test page", "apache2 ubuntu default", "welcome to nginx", "it works!", "index of /", "domain name registration", "get your domain", "register domain", "godaddy", "namecheap", "domain.com", "404 not found", "403 forbidden", "access denied"]
        let japaneseUnavailable = ["このドメインは販売", "ドメイン販売中", "ドメイン売却", "サイト準備中", "ただいま準備中"]
        guard markdown.utf16.count >= 200, !(invalid + japaneseUnavailable).contains(where: { markdown.contains($0) || title.contains($0) }) else { return false }
        return ["about", "product", "service", "contact", "team", "company", "we ", "our ", "会社概要", "事業内容", "サービス", "お問い合わせ", "製品", "企業情報"].contains { markdown.contains($0) }
    }
    static func companyName(_ page: NativeEnrichmentPage) -> String? {
        guard validCompany(page) else { return nil }
        if let name = japaneseCompanyName(page.metadata) { return name }
        let domain = replace(page.url, #"^https?://"#).components(separatedBy: "/")[0].lowercased()
        let base = replace(domain, #"^www\."#).components(separatedBy: ".")[0]
        if let known = knownCompanies[base] { return known }
        let markdown = page.markdown ?? ""
        if let name = captures(markdown, #"property="og:site_name"\s+content="([^"]+)""#, options: .caseInsensitive).first.map(NativeAIEnvironment.trim), name.utf16.count > 2 { return name }
        let patterns = [#"(?:Welcome to|About)\s+([A-Z][A-Za-z0-9\s&.]+?)(?:\s*[\||-]|\s*$)"#, #"^([A-Z][A-Za-z0-9\s&.]+?)\s*(?:is|offers|provides|builds)"#, #"©\s*\d{4}\s+([A-Z][A-Za-z0-9\s&.]+?)(?:\s|$)"#]
        func matchingDomain(_ name: String) -> Bool { let lower = replace(name.lowercased(), #"\s+"#); return lower.contains(base) || base.contains(prefix(lower, 4)) }
        for (i, pattern) in patterns.enumerated() {
            if let name = captures(markdown, pattern, options: i == 1 ? [.caseInsensitive, .anchorsMatchLines] : .caseInsensitive).first.map(NativeAIEnvironment.trim), matchingDomain(name) { return name }
        }
        var title = page.metadata?.title ?? ""
        for pattern in [#"\s*[\||-]\s*(?:Official\s*)?(?:Website|Site|Home|Page)?\s*$"#, #"\s*[\||-]\s*[^|]+$"#, #"\s*:\s*[^:]+$"#, #"\s*-\s*[^-]+$"#, #"\.com.*$"#, #"is for sale.*$"#] { title = replace(title, pattern, options: .caseInsensitive) }
        title = NativeAIEnvironment.trim(title)
        if title.utf16.count > 2, matchingDomain(title) { return title }
        return capitalizedDomain(base)
    }
    private static func japaneseCompanyName(_ metadata: NativeEnrichmentPage.Metadata?) -> String? {
        let generic = ["会社概要", "会社案内", "企業情報", "公式サイト", "公式ホームページ", "ホーム", "トップページ", "お問い合わせ"]
        if let raw = metadata?.ogSiteName {
            let value = normalized(raw)
            if (2...100).contains(value.utf16.count), matches(value, #"[\p{Han}\p{Hiragana}\p{Katakana}]"#), !generic.contains(value) { return value }
        }
        let parts = replace(metadata?.title ?? "", #"\s+[—–-]\s+|[|｜:：]"#, "\n").components(separatedBy: "\n")
        for part in parts {
            var value = normalized(part)
            value = replace(value, #"^(?:会社概要|会社案内|企業情報)\s+"#)
            value = replace(value, #"\s*(?:公式(?:ウェブ)?サイト|公式ホームページ|コーポレートサイト|会社概要|会社案内)$"#)
            value = normalized(value)
            if (4...100).contains(value.utf16.count), matches(value, #"[\p{Han}\p{Hiragana}\p{Katakana}]"#),
               ["株式会社", "有限会社", "合同会社", "合資会社", "合名会社"].contains(where: value.contains),
               !["ニュース", "お知らせ", "インタビュー", "新製品", "について"].contains(where: value.contains) { return value }
        }
        return nil
    }
    static func description(_ page: NativeEnrichmentPage) -> String? {
        guard validCompany(page) else { return nil }
        if let description = page.metadata?.description, description.utf16.count > 20 { return description }
        return captures(page.markdown ?? "", #"(?:About|Mission|What\s+We\s+Do)[\s:]+([^\n]+(?:\n[^\n]+){0,2})"#, options: .caseInsensitive).first.map { replace(NativeAIEnvironment.trim($0), #"\n+"#, " ") }
    }
    static func technologies(_ html: String) -> [String] {
        var values: [String] = [], seen = Set<String>()
        func add(_ value: String) { if !value.isEmpty, seen.insert(value).inserted { values.append(value) } }
        for pattern in [#"<meta\s+name=["']generator["']\s+content=["']([^"']+)["']"#, #"<meta\s+content=["']([^"']+)["']\s+name=["']generator["']"#, #"<meta\s+name=["']application-name["']\s+content=["']([^"']+)["']"#, #"<meta\s+content=["']([^"']+)["']\s+name=["']application-name["']"#] { for value in captures(html, pattern, options: .caseInsensitive) { add(value) } }
        for (markers, value) in [(["ng-app","ng-controller"],"AngularJS"),(["v-for","v-if","v-model"],"Vue.js"),(["data-react","__NEXT_DATA__"],"React"),(["__NEXT_DATA__"],"Next.js"),(["__NUXT__"],"Nuxt.js"),(["gatsby-"],"Gatsby")] where markers.contains(where: html.contains) { add(value) }
        let patterns = [(#"react(?:\.min)?\.js|react-dom(?:\.min)?\.js"#,"React"),(#"angular(?:\.min)?\.js|zone\.js"#,"Angular"),(#"vue(?:\.min)?\.js"#,"Vue.js"),(#"jquery(?:-\d+\.\d+\.\d+)?(?:\.min)?\.js"#,"jQuery"),(#"google-analytics\.com|googletagmanager\.com"#,"Google Analytics"),(#"segment\.com|segment\.io"#,"Segment"),(#"hotjar\.com"#,"Hotjar"),(#"mixpanel\.com"#,"Mixpanel"),(#"bootstrap(?:\.min)?\.(?:js|css)"#,"Bootstrap"),(#"tailwind(?:css)?"#,"Tailwind CSS"),(#"material(?:ize)?(?:\.min)?\.(?:js|css)"#,"Material Design"),(#"webpack|bundle\.\w+\.js"#,"Webpack"),(#"_next/static"#,"Next.js"),(#"gatsby"#,"Gatsby")]
        for src in captures(html, #"<script[^>]+src=["']([^"']+)["']"#, options: .caseInsensitive) {
            for (pattern, name) in patterns where matches(src, pattern, options: .caseInsensitive) { add(name) }
            for (marker, name) in [("react","React"),("angular","Angular"),("vue","Vue.js"),("jquery","jQuery"),("bootstrap","Bootstrap"),("tailwind","Tailwind CSS"),("wordpress","WordPress"),("shopify","Shopify"),("squarespace","Squarespace"),("wix","Wix"),("webflow","Webflow"),("stripe","Stripe"),("cloudflare","Cloudflare")] where src.contains(marker) { add(name) }
            let host = URL(string: src, relativeTo: URL(string: "https://placeholder.invalid")!)?.absoluteURL.host?.lowercased()
            for (hostname, name) in [("cdn.jsdelivr.net","jsDelivr CDN"),("unpkg.com","unpkg CDN"),("cdnjs.cloudflare.com","cdnjs")] where host == hostname { add(name) }
        }
        for href in captures(html, #"<link[^>]+href=["']([^"']+)["']"#, options: .caseInsensitive) {
            for (marker, name) in [("bootstrap","Bootstrap"),("tailwind","Tailwind CSS"),("material","Material Design"),("bulma","Bulma"),("foundation","Foundation"),("semantic","Semantic UI")] where href.contains(marker) { add(name) }
        }
        for comment in captures(html, #"<!--\s*([\s\S]+?)\s*-->"#) {
            for name in ["WordPress","Drupal","Joomla","Magento","Shopify"] where comment.lowercased().contains(name.lowercased()) { add(name) }
        }
        for (marker, name) in [("mui-","Material-UI"),("ant-","Ant Design"),("chakra-","Chakra UI")] where matches(html, #"class=["'][^"']*\b"# + marker + #"[^"'\s]+"#) { add(name) }
        if html.contains("property=\"og:") { add("Open Graph Protocol") }; if html.contains("name=\"twitter:") { add("Twitter Cards") }
        if html.contains("manifest.json") || html.contains("service-worker") { add("Progressive Web App (PWA)") }; return values
    }
}
