import Foundation

struct NativeEnrichmentOrchestrator {
    typealias Results = [String: NativeEnrichmentResult]
    typealias Search = (String, Int) async throws -> [NativeEnrichmentPage]
    typealias Scrape = (String) async throws -> NativeEnrichmentPage
    struct Extraction {
        let content: String, pages: [NativeEnrichmentPage], fields: [NativeEnrichmentField], context: [String: String], corroborated: Bool
    }
    typealias Extract = (Extraction, @escaping NativeContactEnrichmentWorker.Report) async throws -> Results
    private let search: Search, scrape: Scrape, extract: Extract, year: () -> Int
    init(search: @escaping Search, scrape: @escaping Scrape, extract: @escaping Extract,
         year: @escaping () -> Int = { Calendar.current.component(.year, from: Date()) }) {
        self.search = search; self.scrape = scrape; self.extract = extract; self.year = year
    }
    init(openaiKey: String, firecrawlKey: String, model: String = NativeEnrichmentOpenAI.defaultModel,
         request: @escaping NativeEnrichmentHTTP.Request = NativeEnrichmentHTTP.network) {
        let web = NativeFirecrawlClient(apiKey: firecrawlKey, request: request), ai = NativeEnrichmentOpenAI(apiKey: openaiKey, model: model, request: request)
        self.init(search: { try await web.search($0, limit: $1) }, scrape: web.scrape,
                  extract: { value, report in try await ai.extract(content: value.content, pages: value.pages, fields: value.fields, context: value.context, corroborated: value.corroborated, report: report) })
    }
    static func contactProvider(email: String, fields: [NativeEnrichmentField], openai: String, firecrawl: String,
                                report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeEnrichmentOutput {
        try await Self(openaiKey: openai, firecrawlKey: firecrawl).run(email: email, fields: fields, report: report)
    }
    private struct ProgressFailure: Error { let underlying: Error }
    func run(email: String?, companyName: String? = nil, website: String? = nil, personName: String? = nil, fields: [NativeEnrichmentField],
             report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeEnrichmentOutput {
        try Task.checkCancellation(); try NativeEnrichmentField.validate(fields)
        var identity = try NativeEnrichmentIdentity(email: email, companyName: companyName, website: website, personName: personName)
        let guarded: NativeContactEnrichmentWorker.Report = { value in
            try Task.checkCancellation()
            do { try await report(value) } catch { throw ProgressFailure(underlying: error) }
            try Task.checkCancellation()
        }
        do {
            var results: Results = [:]
            let personal = fields.filter(NativeEnrichmentRouting.person)
            if !personal.isEmpty {
                try await guarded(.init(message: "本人の情報を調べています：\(personal.map(\.displayName).joined(separator: "、"))", kind: .agent))
                results = try await person(identity, fields: personal, report: guarded)
                results = try NativeEnrichmentOutput(enrichments: results, status: .completed).validated(for: personal).enrichments
                if let field = personal.first(where: NativeEnrichmentRouting.companyName),
                   let value = results[field.name]?.value, value.truthy {
                    if NativeEnrichmentText.normalized(identity.name ?? "").lowercased() != NativeEnrichmentText.normalized(value.text).lowercased() {
                        identity.companyDomain = nil; identity.domain = ""
                    }
                    identity.companyName = value.text
                }
                try await guarded(.init(message: "本人の情報：\(results.count)項目の情報を取得しました。", kind: results.isEmpty ? .warning : .success))
            }
            let companyFields = fields.filter { !NativeEnrichmentRouting.person($0) }
            if !companyFields.isEmpty, identity.companyDomain == nil, let name = identity.name, !name.isEmpty {
                let pages = try await searchPages("\"\(name)\" official website", limit: 5, budget: 100_000, report: guarded)
                let blocked = ["linkedin.com", "facebook.com", "twitter.com", "instagram.com", "crunchbase.com", "glassdoor.com", "wikipedia.org", "bloomberg.com", "youtube.com"]
                if let host = pages.compactMap({ NativeEnrichmentIdentity.websiteDomain($0.url) }).first(where: { host in !blocked.contains { host.hasSuffix($0) } }) {
                    identity.companyDomain = host; if identity.domain.isEmpty { identity.domain = host }
                    try await guarded(.init(message: "会社のドメインを確認しました：\(host)", kind: .success))
                }
            }
            for phase in NativeEnrichmentPhase.allCases {
                let selected = companyFields.filter { NativeEnrichmentRouting.phase($0) == phase }; guard !selected.isEmpty else { continue }
                try await guarded(.init(message: "\(phase.title)を調べています：\(selected.map(\.displayName).joined(separator: "、"))", kind: .agent))
                let found: Results
                switch phase {
                case .discovery:
                    found = try await discover(identity, fields: selected, report: guarded)
                    if let field = selected.first(where: { NativeEnrichmentRouting.companyName($0) && found[$0.name]?.value.truthy == true }), let value = found[field.name]?.value { identity.companyName = value.text }
                    if identity.companyDomain == nil, let field = selected.first(where: { NativeEnrichmentRouting.website($0) && !$0.name.contains("personal") }),
                       let value = found[field.name]?.value, let host = NativeEnrichmentIdentity.websiteDomain(value.text) {
                        identity.companyDomain = host; if identity.domain.isEmpty { identity.domain = host }
                    }
                case .profile, .metrics, .funding: found = try await companyPhase(phase, identity: identity, fields: selected, report: guarded)
                case .techStack: found = try await technology(identity, fields: selected, report: guarded)
                case .other: found = try await general(identity, fields: selected, report: guarded)
                }
                let validated = try NativeEnrichmentOutput(enrichments: found, status: .completed).validated(for: selected)
                results.merge(validated.enrichments) { _, new in new }
                try await guarded(.init(message: "\(phase.title)：\(validated.enrichments.count)項目の情報を取得しました。", kind: found.isEmpty ? .warning : .success))
            }
            try await guarded(.init(message: "情報の調査が完了しました（\(results.count)／\(fields.count)項目）。", kind: .success))
            return try NativeEnrichmentOutput(enrichments: results, status: .completed).validated(for: fields)
        } catch let failure as ProgressFailure { throw failure.underlying }
    }
    private func searchPages(_ query: String, limit: Int, budget: Int, report: @escaping NativeContactEnrichmentWorker.Report) async throws -> [NativeEnrichmentPage] {
        try await report(.init(message: "検索しています：\(NativeEnrichmentText.prefix(query, 140))", kind: .info))
        let pages = try await search(query, limit).map { $0.projected(maximumUnits: budget) }
        try await report(.init(message: "\(pages.count)件の検索結果を確認しました。", kind: pages.isEmpty ? .warning : .info))
        return pages
    }
    private func optionalScrape(_ url: String, report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeEnrichmentPage? {
        try await report(.init(message: "ウェブサイトを確認しています。", kind: .info, sourceURL: url))
        let page: NativeEnrichmentPage
        do { page = try await scrape(url) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NativeAIError {
            try Task.checkCancellation()
            if [401, 402, 403].contains(error.status ?? 0) || error.retryable { throw error }
            try await report(.init(message: "このページを取得できなかったため、別の情報源を確認します。", kind: .warning, sourceURL: url)); return nil
        }
        try await report(.init(message: "ウェブサイトを取得しました。", kind: .info, sourceURL: url)); return page
    }
    private func extraction(_ pages: [NativeEnrichmentPage], fields: [NativeEnrichmentField], context: [String: String],
                            budget: Int, prefix: String = "", corroborated: Bool = true, observations: [NativeEnrichmentPage] = [], report: @escaping NativeContactEnrichmentWorker.Report) async throws -> Results {
        try await report(.init(message: "取得した情報と出典を照合しています。", kind: .info))
        let observed = observations.isEmpty ? "" : "\n\n---\n\n" + NativeEnrichmentText.content(observations, maximumUnits: budget)
        let result = try await extract(.init(content: prefix + NativeEnrichmentText.content(pages, maximumUnits: budget) + observed, pages: pages + observations, fields: fields, context: context, corroborated: corroborated), report)
        try await report(.init(message: "情報の解析が完了しました。", kind: .info)); return result
    }
    private func discover(_ identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField], report: @escaping NativeContactEnrichmentWorker.Report) async throws -> Results {
        var results: Results = [:]
        if let domain = identity.companyDomain {
            let url = "https://" + domain
            if var page = try await optionalScrape(url, report: report), NativeEnrichmentText.validCompany(page) {
                page.url = url
                func put(_ f: NativeEnrichmentField, _ value: String, _ confidence: Double, _ snippet: String) {
                    results[f.name] = .init(field: f.name, value: .string(value), confidence: confidence, source: url, sourceContext: [.init(url: url, snippet: snippet)])
                }
                if let field = fields.first(where: NativeEnrichmentRouting.companyName), let name = NativeEnrichmentText.companyName(page) { put(field, name, 0.9, "会社の公式ウェブサイトで確認") }
                if let field = fields.first(where: NativeEnrichmentRouting.website) { put(field, url, 1, "実際にアクセスした会社のドメイン") }
                if let field = fields.first(where: NativeEnrichmentRouting.description), let description = NativeEnrichmentText.description(page) {
                    put(field, description, 0.85, NativeEnrichmentText.prefix(description, 200) + (description.utf16.count > 200 ? "..." : ""))
                }
            }
        }
        let missing = fields.filter { results[$0.name] == nil }; guard !missing.isEmpty else { return results }
        var queries: [String] = []
        if let domain = identity.companyDomain { queries += ["\"\(domain)\" company official website", "site:\(domain) about"] }
        if let name = identity.companyNameGuess, !name.isEmpty { queries.append("\"\(name)\" company official website") }
        if let domain = identity.companyDomain { queries.append("\"\(domain.components(separatedBy: ".")[0])\" company website about") }
        if !identity.domain.isEmpty { queries.append("email domain \(identity.domain) company information") }
        var pages: [NativeEnrichmentPage] = [], rawCount = 0
        for query in queries {
            if rawCount >= 5 { break }
            let next = try await searchPages(query, limit: 3, budget: 100_000, report: report); rawCount += next.count
            pages = NativeEnrichmentText.unique(pages + next)
        }
        if pages.isEmpty {
            results.merge(Self.inferred(identity, fields: missing)) { _, new in new }; return results
        }
        let parking = ["domain for sale", "buy this domain", "make an offer", "domain parking", "checkout the full domain details"]
        let valid = pages.filter { page in (page.markdown?.utf16.count ?? 0) >= 100 && !parking.contains { (page.markdown ?? "").lowercased().contains($0) || page.title.lowercased().contains($0) } }
        guard !valid.isEmpty else { return results }
        let prefix = """
        Looking for information about a company with:
        - Email domain: \(identity.domain)
        - Possible company domain: \(identity.companyDomain ?? "Unknown")
        - Possible company name: \(identity.companyNameGuess ?? "Unknown")

        Extract the following information ONLY for this specific company:
        \(missing.map { "- \($0.displayName): \($0.description)" }.joined(separator: "\n"))

        IMPORTANT: Only extract information that is clearly about the company associated with the email domain \(identity.domain).
        """ + "\n\n---\n\n"
        var found = try await extraction(Array(valid.prefix(5)), fields: missing, context: ["email": identity.email, "emailContext": "[object Object]", "discoveredData": "[object Object]"], budget: 100_000, prefix: prefix, corroborated: false, report: report)
        for key in found.keys where found[key]!.value.truthy {
            found[key]!.source = valid.prefix(2).map(\.url).joined(separator: ", ")
            found[key]!.sourceContext = valid.prefix(2).map { .init(url: $0.url, snippet: $0.title) }
        }
        results.merge(found) { _, new in new }; return results
    }
    static func inferred(_ identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField]) -> Results {
        guard let domain = identity.companyDomain else { return [:] }
        let name = NativeEnrichmentText.capitalizedDomain(domain, underscores: true), url = "https://" + domain
        var result: Results = [:]
        for field in fields {
            if NativeEnrichmentRouting.person(field) { continue }
            let value: String, confidence: Double, snippet: String
            if NativeEnrichmentRouting.companyName(field) { value = name; confidence = 0.3; snippet = "メールのドメインから推定：" + domain }
            else if NativeEnrichmentRouting.website(field) { value = url; confidence = 0.7; snippet = "メールアドレスのドメインから推定" }
            else if NativeEnrichmentRouting.description(field) { value = "\(name)は、\(domain)のドメインを使用する会社と推定されます。"; confidence = 0.2; snippet = "会社の説明が見つからなかったため、ドメインから推定" }
            else { continue }
            result[field.name] = .init(field: field.name, value: .string(value), confidence: confidence, source: "ドメインから推定", sourceContext: [.init(url: url, snippet: snippet)])
        }
        return result
    }
    private func companyPhase(_ phase: NativeEnrichmentPhase, identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField], report: @escaping NativeContactEnrichmentWorker.Report) async throws -> Results {
        guard let name = identity.name else { return [:] }
        let prefix = identity.companyDomain.map { "site:\($0) OR " } ?? "", query: String
        switch phase {
        case .profile: query = "\(prefix)\"\(name)\" headquarters industry \"founded in\" \"year founded\" location \"based in\" about"
        case .metrics: query = "\(prefix)\"\(name)\" employees \"team size\" revenue \"annual revenue\" ARR MRR \(year()) \(year() - 1)"
        case .funding: query = "\(prefix)\"\(name)\" funding \"raised\" \"series\" investment \"total funding\" valuation investors"
        default: return [:]
        }
        let pages = try await searchPages(query, limit: 5, budget: 250_000, report: report)
        var context = ["companyName": name]; if let domain = identity.companyDomain { context["targetDomain"] = domain }
        let notice = phase == .profile ? "\n\n[IMPORTANT: You are looking for information about \"\(name)\" ONLY. Ignore information about other companies.]\n\n" : ""
        let result = try await extraction(pages, fields: fields, context: context, budget: 250_000, prefix: notice, report: report)
        return Self.sources(result, pages: pages, repair: true)
    }
    static func sources(_ input: Results, pages: [NativeEnrichmentPage], repair: Bool) -> Results {
        var output = input; let allowed = pages.filter { NativeEnrichmentText.allowedSource($0.url) }
        for key in output.keys where output[key]!.value.truthy {
            var value = output[key]!
            if value.source?.isEmpty != false { value.source = allowed.prefix(2).map(\.url).joined(separator: ", ") }
            if repair {
                if let context = value.sourceContext, !context.isEmpty {
                    if !context.contains(where: { !$0.url.isEmpty && $0.url != "extracted" }), let quote = context.first?.snippet, !quote.isEmpty {
                        if let page = allowed.first(where: { ($0.markdown ?? "").lowercased().contains(NativeEnrichmentText.prefix(quote.lowercased(), 50)) }) { value.sourceContext = [.init(url: page.url, snippet: quote)] }
                        else { value.sourceContext = allowed.prefix(1).map { .init(url: $0.url, snippet: quote) } }
                    }
                } else {
                    value.sourceContext = Array(allowed.compactMap { page in
                        let snippet = NativeEnrichmentText.snippet(page.markdown ?? "", value: value.value)
                        return snippet.isEmpty ? nil : NativeEnrichmentResult.Source(url: page.url, snippet: snippet)
                    }.prefix(5))
                }
            }
            output[key] = value
        }
        return output
    }
    private func technology(_ identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField], report: @escaping NativeContactEnrichmentWorker.Report) async throws -> Results {
        let name = identity.name, domain = identity.companyDomain; guard name != nil || domain != nil else { return [:] }
        let query = name.map { "site:github.com \"\($0)\" OR \"\(NativeEnrichmentText.replace($0.lowercased(), #"\s+"#, "-"))\"" }
            ?? "site:github.com \"\((domain ?? "").replacingOccurrences(of: ".com", with: "").replacingOccurrences(of: ".io", with: "").replacingOccurrences(of: ".ai", with: ""))\""
        let github = try await searchPages(query, limit: 3, budget: 200_000, report: report).filter { URL(string: $0.url)?.host == "github.com" && URL(string: $0.url)?.path.contains("/") == true }
        var technologies: [String] = []
        if let domain, let page = try await optionalScrape("https://" + domain, report: report), let html = page.html { technologies = NativeEnrichmentText.technologies(html) }
        let tech = try await searchPages("\"\(name ?? domain ?? "")\" \"tech stack\" \"built with\" \"powered by\" technologies framework", limit: 3, budget: 200_000, report: report)
        guard !technologies.isEmpty || (github + tech).contains(where: { ($0.markdown?.utf16.count ?? 0) > 100 }) else { return [:] }
        let pages = github + tech, detected = technologies.joined(separator: ", "), urls = github.map(\.url).joined(separator: ", ")
        var context: [String: String] = [:]; if let name { context["companyName"] = name }; if let domain { context["companyDomain"] = domain; context["targetDomain"] = domain }
        context["instruction"] = """
        CRITICAL: Only extract technology information that is EXPLICITLY mentioned in the provided content.

        DO NOT hallucinate or infer technologies.
        DO NOT make up GitHub URLs - only use URLs that actually appear in the search results.

        For tech stack fields:
        - Only include technologies that are explicitly mentioned
        - If HTML analysis detected technologies, you can include those
        - Do not guess based on company type or industry
        - If no tech stack information is found, return null

        Detected technologies from HTML (if any): \(detected.isEmpty ? "None" : detected)

        Valid GitHub URLs found (if any): \(urls.isEmpty ? "None" : urls)
        """
        if !detected.isEmpty { context["detectedTechnologies"] = detected }; if !urls.isEmpty { context["validGithubUrls"] = urls }
        let prefix = detected.isEmpty ? "" : "DETECTED TECHNOLOGIES FROM HTML ANALYSIS:\n\(detected)\n\n---\n\n"
        // Retain the original detected-technology input and identify the actual
        // site that supplied the HTML. Label these as computed observations,
        // not verbatim website prose, so strict evidence validation can retain
        // HTML-only findings even when public search has no usable results.
        let observations: [NativeEnrichmentPage] = detected.isEmpty || domain == nil ? [] : [
            .init(url: "https://" + domain!, title: "HTML解析による技術の検出", markdown: "HTML解析による検出結果：" + detected + "。")
        ]
        var result = Self.sources(try await extraction(pages, fields: fields, context: context, budget: 200_000, prefix: prefix, observations: observations, report: report), pages: pages + observations, repair: false)
        let validURLs = Set(github.map(\.url))
        for field in fields {
            guard var value = result[field.name], value.value.truthy else { continue }
            value.sourceContext = value.sourceContext.map { $0.filter { !$0.url.isEmpty && (!NativeEnrichmentText.github($0.url) || validURLs.contains($0.url)) } }
            if field.type == .array, case let .array(items) = value.value {
                let filtered = items.filter { !["website", "web", "internet", "computer", "software", "technology", "platform"].contains($0.lowercased()) && $0.utf16.count > 1 }
                value = .init(field: value.field, value: .array(filtered), confidence: value.confidence, source: value.source, sourceContext: value.sourceContext, sourceCount: value.sourceCount, corroboration: value.corroboration)
            }
            result[field.name] = value
        }
        return result
    }
    private func general(_ identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField], report: @escaping NativeContactEnrichmentWorker.Report) async throws -> Results {
        guard identity.name != nil || identity.companyDomain != nil else { return [:] }
        var pages: [NativeEnrichmentPage] = []
        for query in NativeEnrichmentRouting.generalQueries(fields, name: identity.name, domain: identity.companyDomain) {
            pages = NativeEnrichmentText.unique(pages + (try await searchPages(query, limit: 3, budget: 200_000, report: report)))
        }
        if fields.contains(where: NativeEnrichmentRouting.executive), let domain = identity.companyDomain {
            for path in ["about", "team", "leadership", "about-us", "our-team"] {
                let url = "https://" + domain + "/" + path
                if let page = try await optionalScrape(url, report: report), let markdown = page.markdown, !markdown.isEmpty {
                    pages = NativeEnrichmentText.unique(pages + [.init(url: url, title: "Company Leadership Page", markdown: markdown).projected(maximumUnits: 200_000)]); break
                }
            }
        }
        guard !pages.isEmpty else { return [:] }
        var context: [String: String] = [:]; if let name = identity.name { context["companyName"] = name }; if let domain = identity.companyDomain { context["companyDomain"] = domain; context["targetDomain"] = domain }
        context["instruction"] = """
        Extract the requested information about \(identity.name ?? identity.companyDomain ?? "").

        For executive names (CEO, CTO, CFO, etc.):
        - Look for mentions like "CEO", "Chief Executive Officer", "founder and CEO", etc.
        - Extract the person's full name
        - Be careful to match the title exactly as requested

        For other custom fields:
        - Extract exactly what is asked for
        - Only include information that is explicitly stated
        - Do not make assumptions or inferences
        """
        return Self.sources(try await extraction(pages, fields: fields, context: context, budget: 200_000, report: report), pages: pages, repair: false)
    }
    private func person(_ identity: NativeEnrichmentIdentity, fields: [NativeEnrichmentField], report: @escaping NativeContactEnrichmentWorker.Report) async throws -> Results {
        guard identity.personalName?.isEmpty == false || !identity.email.isEmpty else {
            try await report(.init(message: "本人の氏名またはメールアドレスがないため、個人情報を特定できません。", kind: .warning)); return [:]
        }
        var context = ["email": identity.email, "subject": "person"]
        if let name = identity.personalName { context["name"] = name }
        if let name = identity.name { context["companyName"] = name }
        if let domain = identity.companyDomain { context["companyDomain"] = domain }
        context["instruction"] = """
        調査対象は上記の本人です。会社や同僚、同姓同名の別人の情報に置き換えないでください。
        氏名・メールアドレス・勤務先を照合し、本人との関係が明記された情報だけを抽出してください。
        各出典には、本人の氏名またはメールと取得する値を一緒に含む原文を引用してください。
        役職は本人の役職です。個人サイトと個人SNSに会社のトップページや会社のSNSを使わないでください。
        個人メール・携帯番号を会社の代表窓口から推測しないでください。特定できない項目はnullにしてください。
        """
        var results: Results = [:]
        // At most four fields × two identities × three results are resident.
        // Extract each batch before releasing it; do not discard later fields'
        // sources just because earlier searches filled a global page cap.
        for start in stride(from: 0, to: fields.count, by: 4) {
            let selected = Array(fields[start..<min(start + 4, fields.count)])
            var pages: [NativeEnrichmentPage] = []
            for query in NativeEnrichmentPerson.queries(identity, fields: selected) {
                let found = try await searchPages(query, limit: 3, budget: 20_000, report: report)
                pages = NativeEnrichmentText.unique(pages + found.prefix(3).filter { NativeEnrichmentPerson.matches($0, identity: identity) })
            }
            guard !pages.isEmpty else { continue }
            let raw = try await extraction(pages, fields: selected, context: context, budget: 200_000, report: report)
            let found = try NativeEnrichmentOutput(enrichments: raw, status: .completed).validated(for: selected).enrichments
            results.merge(NativeEnrichmentPerson.validated(found, identity: identity, pages: pages)) { _, new in new }
        }
        return results
    }
}

extension NativeContactEnrichmentWorker {
    static func production(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(),
                           clock: @escaping () -> Date = Date.init, model: String = NativeEnrichmentOpenAI.defaultModel,
                           request: @escaping NativeEnrichmentHTTP.Request = NativeEnrichmentHTTP.network) -> NativeContactEnrichmentWorker {
        .init(db: db, store: store, environment: environment, clock: clock, enrich: { email, fields, openai, firecrawl, report in
            try await NativeEnrichmentOrchestrator(openaiKey: openai, firecrawlKey: firecrawl, model: model, request: request).run(email: email, fields: fields, report: report)
        })
    }
}
