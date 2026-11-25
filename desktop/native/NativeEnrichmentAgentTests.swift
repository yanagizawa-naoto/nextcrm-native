import Foundation
import CryptoKit

@main enum NativeEnrichmentAgentTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + name) }; checks += 1
    }
    static func rejects(_ name: String, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + name)
    }
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: data(value)) }
    static func json(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(NativeEnrichmentText.normalized(value).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func same(_ a: Any, _ b: Any) throws -> Bool { try data(a) == data(b) }
    static let none: NativeContactEnrichmentWorker.Report = { _ in }
    static let custom = NativeEnrichmentField(name: "custom", displayName: "独自項目", description: "Custom information")
    static let site = NativeEnrichmentPage(url: "https://acme.invalid", markdown: String(repeating: "Our company provides products and services to customers in Japan. ", count: 8), metadata: .init(title: "Acme | Home", description: "Our company provides products and services."))
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]), reference = try json(Data(contentsOf: root.appendingPathComponent("build/native-enrichment-agent-reference.json")))
            try await personalWebsiteRegression(); try await personalReview()
            try await original(reference); try await japanese(); try await boundaries(); try await htmlOnly(); try await worker(root); try await runtime(root)
            print("Native enrichment agents: \(checks) checks passed")
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
    static func personalWebsiteRegression() async throws {
        let field = NativeEnrichmentField(name: "personal_website", displayName: "個人のウェブサイト", description: "本人のウェブサイトURL")
        let agent = NativeEnrichmentOrchestrator(search: { _, _ in [] }, scrape: { _ in site }, extract: { _, _ in [:] })
        let result = try await agent.run(email: "taro.yamada@acme.invalid", companyName: "Acme", website: site.url, fields: [field], report: none)
        try check(result.enrichments[field.name] == nil, "company homepage must never be substituted for a personal website")
    }
    static func personalReview() async throws {
        let identity = try NativeEnrichmentIdentity(email: "alias@old.invalid", companyName: "日本商事", website: "https://www.nihon.invalid/about", personName: "太郎　山田")
        try check(identity.name == "日本商事" && identity.companyDomain == "nihon.invalid" && identity.personalName == "太郎 山田", "supplied Japanese person/company/site override email guesses")
        let quote = "日本商事の山田 太郎は営業部長です。本人のサイトはhttps://taro.invalidで、LinkedInはhttps://www.linkedin.com/in/taroです。"
        let personPage = NativeEnrichmentPage(url: "https://nihon.invalid/team/taro", markdown: quote)
        try check(NativeEnrichmentPerson.matches(personPage, identity: identity), "Japanese family/given order and whitespace match")
        try check(!NativeEnrichmentPerson.matches(.init(url: "https://unrelated.invalid", title: "山田 太郎 日本商事", markdown: "別会社の山田 太郎は開発担当です。"), identity: identity), "same name at unrelated employer rejected; title is not evidence")
        try check(!NativeEnrichmentPerson.matches(.init(url: personPage.url, markdown: "日本商事の山田 次郎は営業担当です。"), identity: identity), "colleague cannot establish person identity")
        try check(!NativeEnrichmentPerson.matches(.init(url: personPage.url, markdown: "otheralias@old.invalid"), identity: identity), "email substring is not an identity match")
        let fields: [NativeEnrichmentField] = [
            .init(name: "position", displayName: "役職", description: "本人の勤務先での役職", subject: .person),
            .init(name: "personal_website", displayName: "個人のサイト", description: "本人のウェブサイト", subject: .person),
            .init(name: "social_linkedin", displayName: "本人のLinkedIn", description: "本人のLinkedInプロフィール", subject: .person),
            .init(name: "company_website", displayName: "会社のサイト", description: "会社の公式ウェブサイト", subject: .company)
        ]
        var queries: [String] = [], scrapes: [String] = [], extractions = 0
        let agent = NativeEnrichmentOrchestrator(search: { query, _ in queries.append(query); return [personPage] }, scrape: { url in scrapes.append(url); return site }, extract: { extraction, _ in
            extractions += 1
            try check(extraction.context["name"] == "太郎 山田" && extraction.context["email"] == "alias@old.invalid" && extraction.context["companyName"] == "日本商事", "person extraction receives full explicit identity")
            try check(extraction.context["subject"] == "person" && extraction.context["instruction"]!.contains("同姓同名"), "person-specific instructions")
            try check(extraction.fields.allSatisfy { $0.subject == .person }, "company fields excluded from person extraction")
            return Dictionary(uniqueKeysWithValues: [("position", "営業部長"), ("personal_website", "https://taro.invalid"), ("social_linkedin", "https://www.linkedin.com/in/taro")].map { name, value in
                (name, .init(field: name, value: .string(value), confidence: 0.85, sourceContext: [.init(url: personPage.url, snippet: quote)]))
            })
        })
        let output = try await agent.run(email: identity.email, companyName: "日本商事", website: "https://nihon.invalid", personName: "太郎 山田", fields: fields, report: none)
        try check(output.enrichments.count == 4 && output.enrichments["position"]?.value == .string("営業部長"), "person and company findings coexist")
        try check(output.enrichments["personal_website"]?.value == .string("https://taro.invalid") && output.enrichments["company_website"]?.value == .string("https://nihon.invalid"), "personal/company sites remain distinct")
        try check(extractions == 1 && scrapes == ["https://nihon.invalid"], "person source is extracted separately from company discovery")
        try check(queries.count == 6 && queries.allSatisfy { $0.contains("太郎 山田") || $0.contains("alias@old.invalid") }, "every personal query anchors name or email")
        func finding(_ name: String, _ value: String, _ snippet: String, url: String = "https://nihon.invalid/team/taro") -> NativeEnrichmentResult {
            .init(field: name, value: .string(value), confidence: 0.9, sourceContext: [.init(url: url, snippet: snippet)])
        }
        for (label, result, body) in [
            ("wrong person's quote", finding("position", "開発部長", "山田 次郎は開発部長です。"), quote + "山田 次郎は開発部長です。"),
            ("fabricated quote", finding("position", "社長", "日本商事の山田 太郎は社長です。"), quote),
            ("unsupported source", finding("position", "営業部長", quote, url: "https://unseen.invalid"), quote),
            ("company root personal website", finding("personal_website", "https://nihon.invalid", "山田 太郎の勤務先は日本商事で、会社サイトはhttps://nihon.invalidです。"), "山田 太郎の勤務先は日本商事で、会社サイトはhttps://nihon.invalidです。"),
            ("company LinkedIn page", finding("social_linkedin", "https://linkedin.com/company/nihon", "日本商事の山田 太郎です。会社のLinkedInはhttps://linkedin.com/company/nihonです。"), "日本商事の山田 太郎です。会社のLinkedInはhttps://linkedin.com/company/nihonです。")
        ] {
            let filtered = NativeEnrichmentPerson.validated([result.field: result], identity: identity, pages: [.init(url: personPage.url, markdown: body)])
            try check(filtered.isEmpty, "reject " + label)
        }
        let free = try NativeEnrichmentIdentity(email: "taro@gmail.com", personName: "山田 太郎")
        try check(free.name == nil && free.companyDomain == nil, "free provider is not guessed as company")
        try check(!NativeEnrichmentPerson.matches(personPage, identity: free), "unknown employer does not identify common name alone")
        let emailQuote = "山田 太郎のメールはtaro@gmail.comで、勤務先は日本商事です。"
        let employer = NativeEnrichmentField(name: "company", displayName: "勤務先", description: "本人の勤務先の会社名", subject: .person)
        var employerQueries: [String] = []
        let employerAgent = NativeEnrichmentOrchestrator(search: { query, _ in
            employerQueries.append(query)
            return [.init(url: "https://nihon.invalid/team/taro", markdown: emailQuote)]
        }, scrape: { _ in site }, extract: { _, _ in
            ["company": finding("company", "日本商事", emailQuote)]
        })
        let employerResult = try await employerAgent.run(email: free.email, personName: "山田 太郎", fields: [employer, fields[3]], report: none)
        try check(employerResult.enrichments["company"]?.value == .string("日本商事") && employerResult.enrichments["company_website"]?.value == .string("https://nihon.invalid"), "verified personal employer enables company site discovery")
        try check(employerQueries.contains("\"日本商事\" official website") && !employerQueries.contains { $0.contains("\"Gmail\"") }, "discovery uses extracted employer instead of free provider")
        var noIdentityCalls = 0
        let noIdentity = NativeEnrichmentOrchestrator(search: { _, _ in noIdentityCalls += 1; return [] }, scrape: { _ in site }, extract: { _, _ in [:] })
        let missing = try await noIdentity.run(email: nil, companyName: "日本商事", fields: [fields[0]], report: none)
        try check(noIdentityCalls == 0 && missing.enrichments.isEmpty, "company alone cannot identify the person's role")
        for domain in ["gmail.com", "icloud.com", "yahoo.co.jp", "protonmail.com", "me.com"] {
            let id = try NativeEnrichmentIdentity(email: "taro@" + domain, companyName: "日本商事")
            try check(id.isPersonalEmail && id.name == "日本商事" && id.companyDomain == nil, "personal provider \(domain) preserves supplied employer")
        }
        let english = try NativeEnrichmentIdentity(email: "ann@acme.invalid", personName: "Ann Smith")
        try check(NativeEnrichmentPerson.identifies("ANN SMITH is the director.", identity: english) && !NativeEnrichmentPerson.identifies("Ann Smithsonian is the director.", identity: english), "English full name requires boundaries")
        let legacy = try decode(NativeEnrichmentField.self, ["name": "position", "displayName": "役職", "description": "本人の役職", "type": "string", "required": false])
        try check(legacy.subject == nil, "old queued fields decode without subject")
        try check(try JSONDecoder().decode([NativeEnrichmentField].self, from: JSONEncoder().encode(fields)) == fields, "person/company subjects survive persistence")
        var batchSizes: [Int] = [], searchNumber = 0
        let manyFields = (0..<11).map { NativeEnrichmentField(name: "personal_\($0)", displayName: "個人の項目\($0)", description: "本人の項目\($0)", subject: .person) }
        let many = NativeEnrichmentOrchestrator(search: { _, _ in
            searchNumber += 1
            return (0..<3).map { .init(url: "https://nihon.invalid/source/\(searchNumber)/\($0)", markdown: quote) }
        }, scrape: { _ in site }, extract: { input, _ in
            batchSizes.append(input.fields.count)
            try check(input.pages.count == input.fields.count * 6 && input.pages.count <= 24, "all selected search sources retained within batch memory bound")
            return Dictionary(uniqueKeysWithValues: input.fields.map { field in
                (field.name, finding(field.name, "営業部長", quote, url: input.pages.last!.url))
            })
        })
        let manyResult = try await many.run(email: identity.email, companyName: "日本商事", personName: "太郎 山田", fields: manyFields, report: none)
        try check(batchSizes == [4, 4, 3] && manyResult.enrichments.count == 11, "later requested personal fields are researched instead of dropped at page cap")
        for stop in 1...6 {
            var reports = 0
            do {
                _ = try await agent.run(email: identity.email, companyName: "日本商事", personName: "太郎 山田", fields: [fields[0]], report: { _ in reports += 1; if reports == stop { throw NativeDBError.conflict } })
                throw NativeDBError.message("FAIL: person report fence ignored")
            } catch NativeDBError.conflict { try check(reports == stop, "person report fence \(stop)") }
        }
    }
    final class Replay {
        let label: String, trace: [[String: Any]]
        var index = 0, progress: [String] = []
        init(_ item: [String: Any]) { label = item["label"] as! String; trace = item["trace"] as! [[String: Any]] }
        func next(_ op: String) throws -> [String: Any] {
            try check(index < trace.count, label + " extra " + op)
            let item = trace[index]; index += 1
            try check(item["op"] as? String == op, "\(label) operation \(index): expected \(item["op"]!), got \(op)"); return item
        }
        func agent(year: Int) -> NativeEnrichmentOrchestrator {
            .init(search: { [self] query, limit in
                let item = try next("search")
                try check(item["query"] as? String == query, "\(label) query expected \(item["query"]!), got \(query)")
                try check(item["limit"] as? Int == limit, label + " search limit")
                return try decode([NativeEnrichmentPage].self, item["reply"]!)
            }, scrape: { [self] url in
                let item = try next("scrape"); try check(item["url"] as? String == url, label + " scrape URL")
                if let status = item["failure"] as? Int { throw NativeAIError(message: "ページを取得できません。", status: status) }
                return try decode(NativeEnrichmentPage.self, item["reply"]!)
            }, extract: { [self] value, _ in
                let item = try next("extract")
                try check(value.fields.map(\.name) == item["fields"] as! [String], label + " extraction fields")
                try check(value.corroborated == item["corroborated"] as! Bool, label + " extraction method")
                try check(same(value.context.mapValues(NativeEnrichmentText.normalized), item["context"]!), label + " extraction context")
                var originalContent = value.content
                if let detected = value.context["detectedTechnologies"], let domain = value.context["targetDomain"] {
                    let observation = NativeEnrichmentPage(url: "https://" + domain, title: "HTML解析による技術の検出", markdown: "HTML解析による検出結果：" + detected + "。")
                    let suffix = "\n\n---\n\n" + NativeEnrichmentText.content([observation], maximumUnits: 200_000)
                    try check(originalContent.hasSuffix(suffix) && value.pages.last == observation, label + " explicitly labeled HTML observation with actual website URL")
                    originalContent.removeLast(suffix.count)
                }
                try check(hash(originalContent) == item["contentHash"] as! String, label + " complete original extraction content")
                try check(value.pages.allSatisfy { $0.html == nil && $0.links == nil }, label + " unused response buffers discarded")
                return try decode([String: NativeEnrichmentResult].self, item["reply"]!)
            }, year: { year })
        }
    }
    static func translated(_ result: NativeEnrichmentOutput, email: String?) -> NativeEnrichmentOutput {
        var result = result
        let domain = email?.components(separatedBy: "@").last ?? ""
        for key in result.enrichments.keys {
            var value = result.enrichments[key]!
            if value.source == "Inferred from domain" {
                value.source = "ドメインから推定"
                if key.lowercased().contains("description") {
                    value = .init(field: key, value: .string("\(NativeEnrichmentText.capitalizedDomain(domain, underscores: true))は、\(domain)のドメインを使用する会社と推定されます。"), confidence: value.confidence, source: value.source, sourceContext: value.sourceContext)
                }
            }
            value.sourceContext = value.sourceContext?.map { source in
                let text: String
                switch source.snippet {
                case "Found on company website": text = "会社の公式ウェブサイトで確認"
                case "Primary domain from direct access": text = "実際にアクセスした会社のドメイン"
                case "Primary domain from email address": text = "メールアドレスのドメインから推定"
                case "No company description found - generic inference from domain": text = "会社の説明が見つからなかったため、ドメインから推定"
                default: text = source.snippet.replacingOccurrences(of: "Inferred from email domain: ", with: "メールのドメインから推定：")
                }
                return .init(url: source.url, snippet: text)
            }
            result.enrichments[key] = value
        }
        return result
    }
    static func original(_ reference: [String: Any]) async throws {
        for item in reference["cases"] as! [[String: Any]] {
            let replay = Replay(item), fields = try decode([NativeEnrichmentField].self, item["fields"]!)
            let output = try await replay.agent(year: reference["year"] as! Int).run(email: item["email"] as? String, companyName: item["companyName"] as? String, website: item["website"] as? String, fields: fields, report: { replay.progress.append($0.message) })
            try check(replay.index == replay.trace.count, replay.label + " all original calls consumed")
            let expected = translated(try decode(NativeEnrichmentOutput.self, item["result"]!), email: item["email"] as? String)
            try check(output == expected, replay.label + " full results/confidence/provenance")
            try check(!replay.progress.isEmpty && replay.progress.allSatisfy { NativeEnrichmentText.matches($0, "[一-龠ぁ-ゔァ-ヴ]") }, replay.label + " Japanese progress")
        }
        let fields = try decode([NativeEnrichmentField].self, reference["routingFields"]!), expected = reference["categories"] as! [String: [String]]
        for phase in NativeEnrichmentPhase.allCases { try check(fields.filter { NativeEnrichmentRouting.phase($0) == phase }.map(\.name) == expected[phase.rawValue], "original field routing " + phase.rawValue) }
        for item in reference["identities"] as! [[String: Any]] {
            let actual = try NativeEnrichmentIdentity(email: item["email"] as? String), expected = item["expected"] as! [String: Any]
            try check(actual.email == expected["email"] as! String && actual.domain == expected["domain"] as! String, "original email identity")
            try check(actual.companyDomain == expected["companyDomain"] as? String && actual.personalName == expected["personalName"] as? String, "original parsed domain/person")
            let guess = actual.isPersonalEmail ? nil : expected["companyNameGuess"] as? String
            try check(actual.companyNameGuess == guess && actual.isPersonalEmail == expected["isPersonalEmail"] as! Bool, "company guess preserves original except free provider is never an employer")
        }
    }
    static func japanese() async throws {
        for (name, phase) in [("会社名", NativeEnrichmentPhase.discovery), ("公式サイト", .discovery), ("会社の説明", .discovery), ("業種", .profile), ("設立年", .profile), ("従業員数", .metrics), ("年商", .metrics), ("資金調達額", .funding), ("利用技術", .techStack), ("最高技術責任者", .other)] {
            let field = NativeEnrichmentField(name: name, displayName: name, description: name)
            try check(NativeEnrichmentRouting.phase(field) == phase, "Japanese field " + name)
        }
        let executive = NativeEnrichmentField(name: "代表取締役", displayName: "代表取締役", description: "現在の代表取締役の氏名")
        try check(NativeEnrichmentRouting.executive(executive) && NativeEnrichmentRouting.title(executive) == "CEO", "Japanese executive search")
        let queries = NativeEnrichmentRouting.generalQueries([.init(name: "独自項目", displayName: "独自項目", description: "主要な販売商品とサービス")], name: "日本商事", domain: "nihon.invalid")
        try check(queries.count == 2 && queries.allSatisfy { $0.contains("主要な販売商品とサービス") }, "Japanese search terms survive")
        let identity = try NativeEnrichmentIdentity(email: "person@gmail.com", companyName: "日本商事", website: "https://www.nihon.invalid/company")
        try check(identity.name == "日本商事" && identity.companyDomain == "nihon.invalid", "personal email uses explicit target company")
        var searches: [String] = []
        let agent = NativeEnrichmentOrchestrator(search: { query, _ in searches.append(query); return [] }, scrape: { _ in throw NativeAIError(message: "取得不可", status: 404) }, extract: { _, _ in [:] })
        let output = try await agent.run(email: "person@gmail.com", companyName: "日本商事", website: "https://nihon.invalid", fields: [.init(name: "会社名", displayName: "会社名", description: "会社名")], report: none)
        try check(searches.allSatisfy { !$0.contains("Gmail") && !$0.contains("gmail.com") || $0.hasPrefix("email domain") }, "company identity used during personal-email search")
        try check(output.enrichments["会社名"]?.source == "ドメインから推定" && output.enrichments["会社名"]?.confidence == 0.3, "Japanese inferred field retains uncertainty")
    }
    actor Signal { var entered = false; func mark() { entered = true } }
    static func boundaries() async throws {
        let large = String(repeating: "a", count: 600_000), pages = [NativeEnrichmentPage(url: "https://one.invalid", markdown: large, html: large, links: ["unused"]), .init(url: "https://two.invalid", markdown: String(repeating: "b", count: 100_000))]
        for budget in [100_000, 200_000, 250_000] {
            let projected = pages.map { $0.projected(maximumUnits: budget) }
            try check(projected[0].markdown!.utf16.count == budget && projected[0].originalMarkdownUnits == 600_000, "bounded phase source keeps original length")
            try check(NativeEnrichmentText.content(projected, maximumUnits: budget) == NativeEnrichmentText.content(pages, maximumUnits: budget), "projection preserves exact proportional prompt")
            try check(projected.allSatisfy { $0.html == nil && $0.links == nil && $0.metadata == nil }, "unused source structures released")
        }
        for invalid in [nil, "", "invalid", "a@@b", "@x", "x@"] as [String?] { try await rejects("missing/invalid identity") { _ = try NativeEnrichmentIdentity(email: invalid) } }
        let basic = NativeEnrichmentOrchestrator(search: { _, _ in [site] }, scrape: { _ in site }, extract: { _, _ in [:] })
        try await rejects("empty field list") { _ = try await basic.run(email: "qa@acme.invalid", fields: [], report: none) }
        for failAt in 1...8 {
            var reports = 0, revoked = false
            do {
                _ = try await basic.run(email: "qa@acme.invalid", fields: [custom], report: { _ in
                    reports += 1; if reports == failAt { revoked = true; throw NativeDBError.conflict }
                })
                throw NativeDBError.message("progress cancellation ignored")
            } catch NativeDBError.conflict { try check(revoked && reports == failAt, "report authority failure propagated at boundary \(failAt)") }
        }
        let signal = Signal()
        let cancellable = NativeEnrichmentOrchestrator(search: { _, _ in await signal.mark(); try await Task.sleep(nanoseconds: 10_000_000_000); return [] }, scrape: { _ in site }, extract: { _, _ in [:] })
        let work = Task { try await cancellable.run(email: "qa@acme.invalid", fields: [custom], report: none) }
        for _ in 0..<100 { if await signal.entered { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let entered = await signal.entered; try check(entered, "cancellable search entered"); work.cancel()
        do { _ = try await work.value; throw NativeDBError.conflict } catch is CancellationError { checks += 1 }
        let website = NativeEnrichmentField(name: "website", displayName: "ウェブサイト", description: "Company website")
        for status in [401, 402, 403, 429, 500] {
            var searches = 0
            let failing = NativeEnrichmentOrchestrator(search: { _, _ in searches += 1; return [] }, scrape: { _ in throw NativeAIError(message: "認証または通信失敗", retryable: status >= 429, status: status) }, extract: { _, _ in [:] })
            do { _ = try await failing.run(email: "qa@acme.invalid", fields: [website], report: none); throw NativeDBError.conflict }
            catch let error as NativeAIError { try check(error.status == status && searches == 0, "provider failure cannot become inferred success \(status)") }
        }
        let malicious = NativeEnrichmentOrchestrator(search: { _, _ in [site] }, scrape: { _ in site }, extract: { _, _ in ["unrequested": .init(field: "unrequested", value: .string("unexpected"), confidence: 1)] })
        try await rejects("unsolicited provider field") { _ = try await malicious.run(email: "qa@acme.invalid", fields: [custom], report: none) }
        let numeric = NativeEnrichmentResult(field: "employeeCount", value: .number(1500), confidence: 0.8)
        let repaired = NativeEnrichmentOrchestrator.sources(["employeeCount": numeric], pages: [.init(url: "https://linkedin.com/a", markdown: "1,500 employees"), .init(url: "https://acme.invalid/news", markdown: "Our staff consists of 1,500 employees.")], repair: true)
        try check(repaired["employeeCount"]?.source == "https://acme.invalid/news" && repaired["employeeCount"]?.sourceContext?.count == 1, "numeric source repair excludes blocked fallback pages")
    }
    static func worker(_ resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-EnrichmentAgent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let crm = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        let row = try db.insert("crm_Contacts", values: ["first_name": .text("試験"), "last_name": .text("連絡先"), "email": .text("qa@acme.invalid"), "createdBy": .text(crm.identity.id), "v": .integer(0)], actor: crm.identity.id)
        let store = NativeAIQAServices(), env = NativeAIEnvironment(lookup: { $0 == "OPENAI_API_KEY" ? "qa-openai" : $0 == "FIRECRAWL_API_KEY" ? "qa-firecrawl" : nil })
        let service = NativeContactEnrichmentService(service: crm, store: store, environment: env)
        let fields = NativeEnrichmentField.contactPresets.filter { ["position", "website"].contains($0.name) }
        let id = try service.request(contactIDs: [row["id"].string], fields: fields, mode: .review)[0]
        let url = "https://acme.invalid/team", quote = "この連絡先は現在、営業部長として会社の営業部門を統括しています。"
        var requests: [String] = []
        let request: NativeEnrichmentHTTP.Request = { req in
            requests.append(req.url!.path)
            let payload: [String: Any]
            if req.url == NativeEnrichmentHTTP.search {
                try check(req.value(forHTTPHeaderField: "Authorization") == "Bearer qa-firecrawl", "worker resolves Firecrawl key")
                payload = ["success": true, "data": ["web": [["url": url, "title": "会社の役職", "markdown": quote]]]]
            } else if req.url == NativeEnrichmentHTTP.scrape { payload = ["success": true, "data": try json(JSONEncoder().encode(site))] }
            else {
                try check(req.url == NativeEnrichmentHTTP.chat && req.value(forHTTPHeaderField: "Authorization") == "Bearer qa-openai", "worker resolves OpenAI key")
                let result: [String: Any] = ["position": ["evidence": [["value": "営業部長", "source_url": url, "exact_text": quote, "confidence": 0.9]], "consensus_value": "営業部長", "consensus_confidence": 0.9, "sources_agree": true]]
                payload = ["object": "chat.completion", "model": NativeEnrichmentOpenAI.defaultModel, "choices": [["index": 0, "message": ["role": "assistant", "content": String(decoding: try data(result), as: UTF8.self)], "finish_reason": "stop"]]]
            }
            return (try data(payload), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let worker = NativeContactEnrichmentWorker.production(db: db, store: store, environment: env, request: request)
        let ran = try await worker.runNext(); try check(ran && db.job(id: id)?.status == "done", "production worker completes real native pipeline")
        try check(requests == ["/v2/scrape", "/v2/search", "/v2/search", "/v1/chat/completions"], "production pipeline calls both real clients with injected transport")
        let current = try db.get("crm_Contacts", key: ["id": row["id"]])!
        try check(current["position"] == .null && current["website"] == .null, "review does not overwrite contact")
        let preview = try service.preview(id), applied = try service.apply(preview, selected: ["position", "website"])
        let saved = try db.get("crm_Contacts", key: ["id": row["id"]])!
        try check(Set(applied) == Set(["position", "website"]) && saved["position"] == .text("営業部長") && saved["website"] == .text("https://acme.invalid"), "full review/apply preserves native client result")
    }
    static func htmlOnly() async throws {
        let quote = "HTML解析による検出結果：React, Next.js。", url = "https://acme.invalid"
        for repeatedURL in [false, true] {
        var paths: [String] = []
        let request: NativeEnrichmentHTTP.Request = { req in
            paths.append(req.url!.path)
            let body: [String: Any]
            if req.url == NativeEnrichmentHTTP.search { body = ["success": true, "data": ["web": repeatedURL ? [["url": url, "markdown": "Company homepage without technology names."]] : []]] }
            else if req.url == NativeEnrichmentHTTP.scrape { body = ["success": true, "data": ["html": "<script>__NEXT_DATA__</script>", "markdown": "Company site"]] }
            else {
                let payload = try json(req.httpBody!), messages = payload["messages"] as! [[String: String]]
                try check(messages[1]["content"]!.contains("URL: " + url) && messages[1]["content"]!.contains(quote), "HTML-only evidence transmitted with source and computed label")
                let result: [String: Any] = ["techStack": ["evidence": [["value": ["React", "Next.js"], "source_url": url, "exact_text": quote, "confidence": 0.8]], "consensus_value": ["React", "Next.js"], "consensus_confidence": 0.8, "sources_agree": true]]
                body = ["object": "chat.completion", "model": NativeEnrichmentOpenAI.defaultModel, "choices": [["index": 0, "message": ["role": "assistant", "content": String(decoding: try data(result), as: UTF8.self)], "finish_reason": "stop"]]]
            }
            return (try data(body), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let agent = NativeEnrichmentOrchestrator(openaiKey: "qa", firecrawlKey: "qa", request: request)
        let field = NativeEnrichmentField(name: "techStack", displayName: "利用技術", description: "Technology stack", type: .array)
        let result = try await agent.run(email: "qa@acme.invalid", fields: [field], report: none)
        try check(result.enrichments["techStack"]?.value == .array(["React", "Next.js"]), "HTML-only detections survive real native evidence validation")
        try check(result.enrichments["techStack"]?.sourceContext == [.init(url: url, snippet: quote)], "computed HTML provenance remains explicit")
        try check(paths == ["/v2/search", "/v2/scrape", "/v2/search", "/v1/chat/completions"], "HTML-only production phase order")
        }
    }
    @MainActor static func runtime(_ resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-EnrichmentAgent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let crm = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        let store = NativeAIQAServices(), env = NativeAIEnvironment(lookup: { $0 == "OPENAI_API_KEY" || $0 == "FIRECRAWL_API_KEY" ? "qa-runtime" : nil })
        let service = NativeContactEnrichmentService(service: crm, store: store, environment: env)
        let row = try db.insert("crm_Contacts", values: ["first_name": .text("検証"), "last_name": .text("対象"), "email": .text("qa@acme.invalid"), "createdBy": .text(crm.identity.id), "v": .integer(0)], actor: crm.identity.id)
        let signal = Signal()
        var calls = 0, active = 0, maximum = 0, slow = false, errors = 0
        let runtime = NativeContactEnrichmentRuntime(db: db, store: store, environment: env, enrich: { _, _, _, _, report in
            calls += 1; active += 1; maximum = max(maximum, active); defer { active -= 1 }
            try await report(.init(message: "検証用の処理中", kind: .info))
            if slow { await signal.mark(); try await Task.sleep(nanoseconds: 10_000_000_000) }
            else { try await Task.sleep(nanoseconds: 5_000_000) }
            return .init(enrichments: ["custom": .init(field: "custom", value: .string("取得値"), confidence: 0.8)], status: .completed)
        })
        runtime.onError = { _ in errors += 1 }
        defer { runtime.stop() }
        func settle(_ condition: @escaping () throws -> Bool) async throws {
            for _ in 0..<300 { if try condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
            throw NativeDBError.message("Runtime did not settle")
        }
        runtime.resume(); try await settle { !runtime.isRunning }
        try check(runtime.nextWake == nil && calls == 0, "empty runtime has no timer/provider calls")
        let first = try service.request(contactIDs: [row["id"].string], fields: [custom], mode: .review)[0]
        let second = try service.request(contactIDs: [row["id"].string], fields: [custom], mode: .review)[0]
        try await settle { try db.job(id: first)?.status == "done" && db.job(id: second)?.status == "done" && !runtime.isRunning }
        try check(calls == 2 && maximum == 1, "new-job notifications run contacts serially")
        try check(runtime.nextWake == nil && errors == 0, "completed queue returns to timer-free rest")
        slow = true
        let pending = try service.request(contactIDs: [row["id"].string], fields: [custom], mode: .review)[0]
        for _ in 0..<300 { if await signal.entered { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        let entered = await signal.entered; try check(entered && runtime.isRunning, "pending runtime provider entered")
        NotificationCenter.default.post(name: NativeDatabase.aiProgress, object: nil, userInfo: ["database": root.appendingPathComponent("other.sqlite").path, "cancelledJob": pending])
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(runtime.isRunning && db.job(id: pending)?.status == "running", "foreign database notification ignored")
        try service.cancel(db.job(id: pending)!)
        try await settle { !runtime.isRunning }
        try check(db.job(id: pending)?.status == "cancelled" && runtime.nextWake == nil && active == 0, "user cancellation stops active provider without retry")
        slow = false
        let stopped = try service.request(contactIDs: [row["id"].string], fields: [custom], mode: .review)[0]
        runtime.stop(); try await settle { !runtime.isRunning }
        try check(runtime.nextWake == nil && db.job(id: stopped)?.status == "pending", "shutdown prevents new execution and leaves durable pending job")
        let qa = try await NativeAIQAServices.enrich("qa@acme.invalid", NativeEnrichmentField.contactPresets, "qa", "qa", none)
        try check(qa.enrichments.count == 9 && qa.enrichments.values.allSatisfy { $0.source == "検証用データ" }, "isolated QA provider supplies original nine fields without network")
    }
}
