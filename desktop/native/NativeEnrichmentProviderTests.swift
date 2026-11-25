import Foundation

@main enum NativeEnrichmentProviderTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + name) }; checks += 1
    }
    static func rejects(_ name: String, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + name)
    }
    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T { try JSONDecoder().decode(type, from: data(value)) }
    static func json(_ value: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: value) as! [String: Any] }
    static func same(_ a: Any, _ b: Any) throws -> Bool { try data(a) == data(b) }
    static let none: NativeContactEnrichmentWorker.Report = { _ in }
    static let count = NativeEnrichmentField(name: "employeeCount", displayName: "従業員数", description: "人数", type: .number)
    static let url = "https://acme.invalid/about"
    static func response(_ request: URLRequest, _ value: Any, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        (try data(value), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    static func chat(_ object: Any, finish: String = "stop", model: String = NativeEnrichmentOpenAI.defaultModel, refusal: String? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": String(decoding: try data(object), as: UTF8.self)]
        if let refusal { message["refusal"] = refusal }
        return ["object": "chat.completion", "model": model, "choices": [["index": 0, "message": message, "finish_reason": finish]]]
    }
    static func evidence(value: Any = 150, quote: String = "Our company employs 150 people in its Tokyo office.", source: String = url, consensus: Any? = nil) -> [String: Any] {
        ["employeeCount": ["evidence": [["value": value, "source_url": source, "exact_text": quote, "confidence": 0.8]], "consensus_value": consensus ?? value, "consensus_confidence": 0.9, "sources_agree": true]]
    }
    static func main() async {
        do {
            let reference = try json(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            try await originals(reference); try await firecrawl(reference); try await ai(); try await transport()
            print("Native enrichment providers: \(checks) checks passed")
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
    static func originals(_ reference: [String: Any]) async throws {
        let fields = try decode([NativeEnrichmentField].self, reference["fields"]!)
        let client = NativeEnrichmentOpenAI(apiKey: "qa-unused")
        for item in reference["flat"] as! [[String: Any]] {
            let result = try client.flat(data(item["input"]!), fields: fields)
            try check(result == decode([String: NativeEnrichmentResult].self, item["result"]!), "original flat " + (item["label"] as! String))
        }
        for item in reference["corroborated"] as! [[String: Any]] {
            let result = try client.corroboration(data(item["input"]!), fields: [count], pages: decode([NativeEnrichmentPage].self, item["pages"]!), context: [:])
            try check(result == decode([String: NativeEnrichmentResult].self, item["result"]!), "original corroboration " + (item["label"] as! String))
        }
        // Compare JSON-schema validation semantics, ignoring Zod's root metadata,
        // property/required ordering and its equivalent nullable type shorthand.
        func canonical(_ object: Any, key: String = "") -> Any {
            if var object = object as? [String: Any] {
                object.removeValue(forKey: "$schema"); object.removeValue(forKey: "name")
                if let types = object["type"] as? [String] {
                    var base = object; base.removeValue(forKey: "type")
                    let variants = types.map { type -> [String: Any] in var part = type == "null" ? [:] : base; part["type"] = type; return part }
                    return canonical(["anyOf": variants])
                }
                return object.mapValues { canonical($0) }
            }
            if let values = object as? [Any] {
                return values.map { canonical($0) }.sorted { (try! data($0)).lexicographicallyPrecedes(try! data($1)) }
            }
            return object
        }
        for (name, corroborated, requested) in [("flatRequest", false, fields), ("corroboratedRequest", true, [count])] {
            let request = reference[name] as! [String: Any], format = request["response_format"] as! [String: Any], schema = format["json_schema"] as! [String: Any]
            try check(same(canonical(schema["schema"]!), canonical(NativeEnrichmentOpenAI.schema(requested, corroborated: corroborated))), "original typed JSON schema " + name)
            let system = (request["messages"] as! [[String: String]]).first!["content"]!
            try check(system == (corroborated ? NativeEnrichmentPrompts.corroborated : NativeEnrichmentPrompts.original), "original full system prompt " + name)
        }
        for item in reference["sites"] as! [[String: Any]] {
            let page = try decode(NativeEnrichmentPage.self, item["page"]!)
            try check(NativeEnrichmentText.validCompany(page) == (item["valid"] as! Bool), "original company validation")
            try check(NativeEnrichmentText.companyName(page) == (item["name"] as? String), "original company identity")
            try check(NativeEnrichmentText.description(page) == (item["description"] as? String), "original company description")
        }
        for item in reference["contents"] as! [[String: Any]] {
            try check(NativeEnrichmentText.content(decode([NativeEnrichmentPage].self, item["pages"]!), maximumUnits: item["limit"] as! Int) == (item["expected"] as! String), "original proportional source trimming")
        }
        let jp = NativeEnrichmentPage(url: url, markdown: String(repeating: "会社概要。弊社は日本国内で業務ソフトウェアとサービスを提供しています。", count: 10))
        try check(NativeEnrichmentText.validCompany(jp), "Japanese company page accepted")
        for (title, expected) in [("日本商事株式会社｜公式サイト", "日本商事株式会社"), ("会社概要 | 株式会社 日本商事", "株式会社 日本商事"), ("合同会社みらい — 公式ホームページ", "合同会社みらい"), ("株式会社K-ファクトリー 公式サイト", "株式会社K-ファクトリー")] {
            var page = jp; page.url = "https://nihon.invalid"; page.metadata = .init(title: title, description: nil)
            try check(NativeEnrichmentText.companyName(page) == expected, "Japanese legal name independent of Latin domain")
        }
        var branded = jp; branded.metadata = .init(title: "業務をもっと便利に", description: nil, ogSiteName: "みらいサービス")
        try check(NativeEnrichmentText.companyName(branded) == "みらいサービス", "Japanese Open Graph brand name")
        var parked = jp; parked.markdown = String(repeating: "このドメインは販売中です。お問い合わせはこちら。", count: 20)
        try check(!NativeEnrichmentText.validCompany(parked) && NativeEnrichmentText.companyName(parked) == nil, "Japanese parked domain rejected")
        let tech = NativeEnrichmentText.technologies("<script src='https://cdn.jsdelivr.net/react.min.js'></script><script>__NEXT_DATA__</script><meta name='generator' content='WordPress'><link href='tailwind.css'>")
        for name in ["React", "Next.js", "WordPress", "jsDelivr CDN", "Tailwind CSS"] { try check(tech.contains(name), "HTML technology " + name) }
        try check(tech.count == Set(tech).count, "technology deduplication")
        try check(NativeEnrichmentText.containsValue("Our staff count is 1,500 today.", value: .number(1500)), "formatted number evidence fixed")
        try check(!NativeEnrichmentText.snippet("Our staff count is 1,500 today.", value: .number(1500)).isEmpty, "formatted number snippet fixed")
        for text in ["従業員数は150人です。", "Our staff count is 150.", "Count: 150"] {
            try check(NativeEnrichmentText.containsValue(text, value: .number(150)), "numeric evidence boundary " + text)
            try check(!NativeEnrichmentText.snippet(text, value: .number(150)).isEmpty, "numeric snippet boundary " + text)
        }
        for text in ["There are 1500 people.", "Amount: 150.5", "Amount: -150", "Amount: −150", "Amount: 150,000", "Code: AB150"] {
            try check(!NativeEnrichmentText.containsValue(text, value: .number(150)), "reject different embedded number " + text)
        }
        try check(NativeEnrichmentText.containsValue("Staff: 1.5k people.", value: .number(1500)), "decimal abbreviated staff count")
        try check(NativeEnrichmentText.containsValue("Balance: -150 yen.", value: .number(-150)), "signed exact number")
        let unique = NativeEnrichmentText.unique([.init(url: "a", title: "old"), .init(url: "b"), .init(url: "a", title: "new")])
        try check(unique.map(\.url) == ["a", "b"] && unique[0].title == "new", "original stable Map dedup")
    }
    static func firecrawl(_ reference: [String: Any]) async throws {
        var requests: [URLRequest] = []
        let client = NativeFirecrawlClient(apiKey: "qa-firecrawl", request: { req in
            requests.append(req)
            return try response(req, ["success": true, "data": req.url == NativeEnrichmentHTTP.search ? ["web": [["url": url, "title": "Acme", "markdown": "body"], "https://acme.invalid/url-only"]] : ["markdown": "site body", "html": "<p>site</p>"]])
        })
        let search = try await client.search("Acme company", limit: 3), scrape = try await client.scrape("acme.invalid")
        try check(search == decode([NativeEnrichmentPage].self, reference["search"]!), "locked SDK URL-only and full results")
        try check(scrape.markdown == "site body" && scrape.html == "<p>site</p>" && scrape.url == "https://acme.invalid", "scrape page and request URL")
        for (index, wire) in (reference["wire"] as! [[String: Any]]).enumerated() {
            let req = requests[index]
            try check(req.url?.path == wire["endpoint"] as? String, "locked SDK endpoint")
            try check(same(json(req.httpBody!), wire["body"]!), "locked SDK request body")
            try check(req.value(forHTTPHeaderField: "Authorization") == "Bearer qa-firecrawl", "bearer credential")
            try check(req.httpMethod == "POST" && req.value(forHTTPHeaderField: "Content-Type") == "application/json", "POST JSON")
        }
        for scrape in [false, true] {
            var statuses = [503, 429, 200], sleeps: [UInt64] = []
            let client = NativeFirecrawlClient(apiKey: "qa", request: { req in
                let status = statuses.removeFirst(); return try response(req, ["success": status == 200, "data": scrape ? ["markdown": "ok"] : ["web": []]], status: status)
            }, sleep: { sleeps.append($0) })
            if scrape { _ = try await client.scrape(url) } else { _ = try await client.search("x") }
            try check(statuses.isEmpty && sleeps == [1_000_000_000, 2_000_000_000], "bounded retry/backoff \(scrape)")
        }
        var calls = 0
        let exhausted = NativeFirecrawlClient(apiKey: "qa", request: { req in calls += 1; return try response(req, ["success": false], status: 503) }, sleep: { _ in })
        let noPages = try await exhausted.search("x"); try check(noPages.isEmpty && calls == 3, "original search unavailable fallback")
        for status in [401, 402, 403] {
            calls = 0
            let denied = NativeFirecrawlClient(apiKey: "qa", request: { req in calls += 1; return try response(req, ["success": false, "error": "sensitive-provider-message"], status: status) }, sleep: { _ in throw NativeDBError.conflict })
            do { _ = try await denied.search("x"); throw NativeDBError.message("accepted denied credential") }
            catch let error as NativeAIError { try check(error.status == status && !error.retryable && !error.message.contains("sensitive"), "visible sanitized credential/credit failure") }
            try check(calls == 1, "authorization failure not retried or hidden")
        }
        var bodies: [[String: Any]] = []
        let tls = NativeFirecrawlClient(apiKey: "qa", request: { req in
            bodies.append(try json(req.httpBody!)); return try response(req, bodies.count == 1 ? ["success": false, "error": "SSL error"] : ["success": true, "data": ["markdown": "ok"]], status: bodies.count == 1 ? 500 : 200)
        })
        _ = try await tls.scrape(url)
        try check(bodies.count == 2 && bodies[0]["skipTlsVerification"] == nil && bodies[1]["skipTlsVerification"] as? Bool == true, "original website TLS fallback only")
        let cancelled = NativeFirecrawlClient(apiKey: "qa", request: { _ in throw CancellationError() }, sleep: { _ in throw NativeDBError.conflict })
        do { _ = try await cancelled.search("x"); throw NativeDBError.conflict } catch is CancellationError { checks += 1 }
        do {
            let malformed = NativeFirecrawlClient(apiKey: "qa\nInjected: value", request: { _ in throw NativeDBError.conflict })
            try await rejects("header injection") { _ = try await malformed.search("x") }
        }
    }
    static func ai() async throws {
        let quote = "当社の従業員数は150人です。東京本社で事業を運営しています。", pages = [NativeEnrichmentPage(url: url, markdown: "会社概要\n" + quote)]
        var requests: [URLRequest] = [], progress: [NativeContactEnrichmentWorker.Progress] = []
        let client = NativeEnrichmentOpenAI(apiKey: "qa-ai", request: { req in requests.append(req); return try response(req, chat(evidence(quote: quote))) })
        let found = try await client.extract(content: NativeEnrichmentText.content(pages), pages: pages, fields: [count], context: ["targetDomain": "acme.invalid"], corroborated: true, report: { progress.append($0) })
        try check(found[count.name]?.value == .number(150), "Japanese sentence evidence")
        try check(client.corroboration(data(evidence(quote: quote)), fields: [count], pages: [.init(url: url, markdown: "A different excerpt from the same URL.")] + pages, context: [:])[count.name]?.value == .number(150), "same URL can supply multiple valid excerpts")
        try check(progress.count == 1 && progress[0].sourceURL == url, "evidence report keeps actual URL")
        let body = try json(requests[0].httpBody!), messages = body["messages"] as! [[String: String]]
        try check((body["model"] as? String) == NativeEnrichmentOpenAI.defaultModel && body["temperature"] == nil, "configurable replacement model with compatible parameters")
        try check(messages[0]["content"]!.contains("日本語") && messages[1]["content"]!.contains("Company Domain: acme.invalid"), "Japanese instruction and entity context")
        for (name, content, source) in [("invented URL", quote, "https://invented.invalid"), ("invented quote", "Our company employs 150 people in Kyoto.", url), ("other page quote", quote, "https://acme.invalid/other")] {
            let result = try client.corroboration(data(evidence(quote: content, source: source)), fields: [count], pages: pages + [.init(url: "https://acme.invalid/other", markdown: "Other text")], context: [:])
            try check(result.isEmpty, "reject " + name)
        }
        try await rejects("mismatched field type") { _ = try client.flat(data(["employeeCount": "150", "employeeCount_confidence": 0.9]), fields: [count]) }
        try await rejects("boolean confidence") { _ = try client.flat(data(["employeeCount": 150, "employeeCount_confidence": true]), fields: [count]) }
        try await rejects("mismatched evidence type") { _ = try client.corroboration(data(evidence(value: "150", quote: quote)), fields: [count], pages: pages, context: [:]) }
        let tech = NativeEnrichmentField(name: "techStack", displayName: "利用技術", description: "技術", type: .array), github = "https://github.com/acme/tool", sentence = "当社では楽楽精算とSwiftを使用しています。"
        let techData: [String: Any] = ["techStack": ["evidence": [["value": ["楽楽精算", "Swift"], "source_url": github, "exact_text": sentence, "confidence": 0.8]], "consensus_value": ["website", "a", "楽楽精算", "Swift"], "consensus_confidence": 0.9, "sources_agree": true]]
        let techPages = [NativeEnrichmentPage(url: github, markdown: sentence)]
        let allowed = try client.corroboration(data(techData), fields: [tech], pages: techPages, context: ["validGithubUrls": github])
        try check(allowed[tech.name]?.value == .array(["楽楽精算", "Swift"]), "Japanese technology names and CSV GitHub validation")
        try check(client.corroboration(data(techData), fields: [tech], pages: techPages, context: [:]).isEmpty, "unsearched GitHub evidence rejected")
        var calls = 0
        let fallback = NativeEnrichmentOpenAI(apiKey: "qa", request: { req in
            calls += 1
            let payload: [String: Any] = calls == 1 ? ["bad": "format"] : ["employeeCount": 150, "employeeCount_confidence": 0.8]
            return try response(req, chat(payload))
        })
        let fallbackResult = try await fallback.extract(content: quote, pages: pages, fields: [count], context: [:], corroborated: true, report: none)
        try check(calls == 2 && fallbackResult[count.name]?.value == .number(150), "malformed corroboration uses original extraction fallback")
        for status in [401, 403, 404, 429, 500] {
            calls = 0
            let failed = NativeEnrichmentOpenAI(apiKey: "qa", request: { req in calls += 1; return try response(req, ["error": ["message": "secret"]], status: status) })
            do { _ = try await failed.extract(content: "x", pages: [], fields: [count], context: [:], corroborated: true, report: none); throw NativeDBError.conflict }
            catch let error as NativeAIError { try check(error.status == status && error.retryable == (status == 429 || status == 500) && !error.message.contains("secret"), "typed AI error \(status)") }
            try check(calls == 1, "no fallback on auth or transient failure")
        }
        for kind in ["length", "refusal", "model", "role", "multi"] {
            let failed = NativeEnrichmentOpenAI(apiKey: "qa", request: { req in
                var object = try chat(["employeeCount": 150, "employeeCount_confidence": 0.8], finish: kind == "length" ? "length" : "stop", model: kind == "model" ? "unexpected" : NativeEnrichmentOpenAI.defaultModel, refusal: kind == "refusal" ? "No" : nil)
                if kind == "role" { object["choices"] = [["index": 0, "message": ["role": "user", "content": "{}"], "finish_reason": "stop"]] }
                if kind == "multi" { object["choices"] = (object["choices"] as! [Any]) + (object["choices"] as! [Any]) }
                return try response(req, object)
            })
            try await rejects("incomplete/misrouted AI response " + kind) { _ = try await failed.extract(content: "x", pages: [], fields: [count], context: [:], corroborated: false, report: none) }
        }
        calls = 0
        let guarded = NativeEnrichmentOpenAI(apiKey: "qa", request: { req in calls += 1; return try response(req, chat(evidence(quote: quote))) })
        do { _ = try await guarded.extract(content: quote, pages: pages, fields: [count], context: [:], corroborated: true, report: { _ in throw NativeDBError.conflict }); throw NativeDBError.message("accepted revoked progress") }
        catch NativeDBError.conflict { checks += 1 }
        try check(calls == 1, "progress authority failure is not mistaken for parse fallback")
        let collision = NativeEnrichmentField(name: "employeeCount_confidence", displayName: "重複", description: "x")
        try await rejects("flat schema name collision") { _ = try await guarded.extract(content: "x", pages: [], fields: [count, collision], context: [:], corroborated: false, report: none) }
        try check(calls == 1, "schema collision rejected before sending")
        let configured = NativeEnrichmentOpenAI(apiKey: "qa", model: "qa-compatible-model", request: { req in
            let body = try json(req.httpBody!), messages = body["messages"] as! [[String: String]], user = messages[1]["content"]!
            try check(body["model"] as? String == "qa-compatible-model", "configured model sent")
            try check(user.contains("Content truncated due to length") && !user.contains("END-OF-LARGE-SOURCE"), "source limit applied before request")
            try check(user.utf16.count < 401_000, "request source buffer bounded")
            return try response(req, chat(["employeeCount": 150, "employeeCount_confidence": 0.8], model: "qa-compatible-model-2026-11-18"))
        })
        let configuredResult = try await configured.extract(content: String(repeating: "日本語😀", count: 100_000) + "END-OF-LARGE-SOURCE", pages: [], fields: [count], context: [:], corroborated: false, report: none)
        try check(configuredResult[count.name]?.value == .number(150), "configured model snapshot accepted")
    }
    final class ProtocolStub: URLProtocol, @unchecked Sendable {
        struct Plan { var bytes = Data("ok".utf8); var headers: [String: String] = [:]; var hang = false }
        static let lock = NSLock()
        static var plan = Plan(), starts = 0, stops = 0
        static func reset(_ value: Plan) { lock.lock(); defer { lock.unlock() }; plan = value; starts = 0; stops = 0 }
        static func counts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (starts, stops) }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); let plan = Self.plan; Self.starts += 1; Self.lock.unlock()
            guard !plan.hang else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: plan.headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.bytes); client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
    }
    static func transport() async throws {
        func configuration() -> URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [ProtocolStub.self]; return c }
        let request = try NativeEnrichmentHTTP.request(NativeEnrichmentHTTP.chat, key: "qa", body: [:])
        ProtocolStub.reset(.init())
        let (bytes, _) = try await NativeEnrichmentHTTP.transport(request, configuration: configuration())
        try check(bytes == Data("ok".utf8) && ProtocolStub.counts().0 == 1, "real URLSession byte stream with isolated protocol")
        ProtocolStub.reset(.init(headers: ["Content-Length": String(NativeEnrichmentHTTP.maximumAIBytes + 1)]))
        try await rejects("declared oversized response before buffering") { _ = try await NativeEnrichmentHTTP.transport(request, configuration: configuration()) }
        ProtocolStub.reset(.init(bytes: Data(repeating: 97, count: NativeEnrichmentHTTP.maximumAIBytes + 1)))
        try await rejects("streamed oversized response without content-length") { _ = try await NativeEnrichmentHTTP.transport(request, configuration: configuration()) }
        ProtocolStub.reset(.init())
        try await rejects("foreign credential destination") { _ = try await NativeEnrichmentHTTP.transport(URLRequest(url: URL(string: "https://foreign.invalid")!), configuration: configuration()) }
        try check(ProtocolStub.counts().0 == 0, "foreign URL never requested")
        try await rejects("injected foreign response") { try NativeEnrichmentHTTP.validate(Data(), HTTPURLResponse(url: URL(string: "https://foreign.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, endpoint: NativeEnrichmentHTTP.chat) }
        ProtocolStub.reset(.init(hang: true))
        let work = Task { try await NativeEnrichmentHTTP.transport(request, configuration: configuration()) }
        for _ in 0..<100 where ProtocolStub.counts().0 == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(ProtocolStub.counts().0 == 1, "pending request began")
        work.cancel()
        do { _ = try await work.value; throw NativeDBError.conflict } catch is CancellationError { checks += 1 }
        for _ in 0..<100 where ProtocolStub.counts().1 == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(ProtocolStub.counts().1 >= 1, "cancelled request stopped transport")
    }
}
