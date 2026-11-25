import Foundation

@main enum NativeE2BTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + message) }; checks += 1 }
    static func rejects(_ message: String, _ body: () async throws -> Void) async throws { do { try await body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + message) }
    static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: .sortedKeys) }
    static func json(_ bytes: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
    static func frame(_ object: Any, flags: UInt8 = 0) throws -> Data { NativeE2BHTTP.frame(try data(object), flags: flags) }
    static let context = NativeTargetEnrichmentContext(email: "qa@example.invalid", company: "試験株式会社", website: "https://example.invalid", name: "山田 太郎", fields: [])
    static let output = NativeTargetAgentOutput(target: ["industry": "情報通信"], contacts: [], confidence: ["industry": 0.8])
    static func stream(output: Data? = nil, status: Int = 0, stderr: Data? = nil) throws -> Data {
        var body = try frame(["event": ["start": ["pid": 123]]])
        if let stderr { body.append(try frame(["event": ["data": ["stderr": stderr.base64EncodedString()]]])) }
        let content = try output ?? JSONEncoder().encode(Self.output)
        body.append(try frame(["event": ["data": ["stdout": content.base64EncodedString()]]]))
        body.append(try frame(["event": ["end": ["exitCode": status]]]))
        body.append(try frame([:], flags: 2)); return body
    }
    final class Wire {
        var requests: [URLRequest] = [], version = "0.3.0", status = 200, body: Data = Data(), split = 7, failWrite = false, failKill = false, createBody: Data?
        var didStart: (() -> Void)?, blockCommand = false
        func send(_ request: URLRequest, _ maximumBytes: Int, _ headers: @escaping NativeE2BHTTP.Headers, _ chunk: @escaping NativeE2BHTTP.Chunk) async throws {
            requests.append(request); let path = request.url!.path
            let reply: Data, code: Int, type: String
            if request.httpMethod == "DELETE" { if failKill { throw URLError(.networkConnectionLost) }; code = 204; reply = Data(); type = "application/json" }
            else if path.hasSuffix("/sandboxes") { reply = try createBody ?? NativeE2BTests.data(["sandboxID": "qa-sandbox", "envdVersion": version, "envdAccessToken": "qa-envd", "domain": "e2b.app"]); code = 201; type = "application/json" }
            else if path.hasSuffix("/files") { if failWrite { throw NativeAIError(message: "検証用の転送失敗") }; reply = try NativeE2BTests.data([["path": NativeE2BClient.scriptPath]]); code = 200; type = "application/json" }
            else { didStart?(); if blockCommand { try await Task.sleep(nanoseconds: 30_000_000_000) }; reply = body; code = status; type = "application/connect+json" }
            try headers(HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": type])!)
            for offset in stride(from: 0, to: reply.count, by: split) { try await chunk(reply.subdata(in: offset..<min(reply.count, offset + split))) }
        }
    }
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            try await reference(root); try await configuration(); try await frames(); try await failures(); try await cancellation(); try await transport(); try await runtime(root); try await targetReview(root)
            print("Native E2B: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func targetReview(_ resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TargetReview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        let crm = CRMService(db: db, identity: identity), store = NativeAIQAServices()
        let env = NativeAIEnvironment(lookup: { ["OPENAI_API_KEY": "qa-openai", "FIRECRAWL_API_KEY": "qa-firecrawl"][$0] })
        let service = NativeTargetEnrichmentService(service: crm, store: store, environment: env)
        let target = try db.insert("crm_Targets", values: ["first_name": .text("太郎"), "last_name": .text("山田"), "email": .text("alias@gmail.com"), "company": .text("日本商事"), "company_website": .text("https://nihon.invalid"), "created_by": .text(identity.id)], actor: identity.id)
        let source = "https://nihon.invalid/team/taro", quote = "日本商事の山田 太郎は営業部長です。個人サイトはhttps://taro.invalidです。"
        var searches = 0, completions = 0, flatFallback = false
        let review = NativeTargetEnrichmentProvider.makeReview(request: { req in
            let payload = try json(req.httpBody!), body: [String: Any]
            if req.url == NativeEnrichmentHTTP.search {
                searches += 1
                let query = payload["query"] as! String
                try check(query.contains("太郎 山田") || query.contains("alias@gmail.com"), "production target review query preserves named identity")
                body = ["success": true, "data": ["web": [["url": source, "markdown": quote]]]]
            } else {
                try check(req.url == NativeEnrichmentHTTP.chat, "personal fields never scrape company root")
                completions += 1
                let messages = payload["messages"] as! [[String: String]], prompt = messages[1]["content"]!
                try check(prompt.contains("Person Name: 太郎 山田") && prompt.contains("email: alias@gmail.com") && prompt.contains("同姓同名"), "production OpenAI prompt includes named identity and person constraints")
                let format = payload["response_format"] as! [String: Any], schema = format["json_schema"] as! [String: Any]
                let isFlat = schema["name"] as? String == "enrichment_data"
                var result: [String: Any] = [:]
                for (name, value) in [("position", "営業部長"), ("personal_website", "https://taro.invalid")] {
                    if isFlat { result[name] = value; result[name + "_confidence"] = 0.85; result[name + "_sources"] = [["url": source, "quote": quote]] }
                    else { result[name] = ["evidence": [["value": value, "source_url": source, "exact_text": quote, "confidence": 0.85]], "consensus_value": value, "consensus_confidence": 0.85, "sources_agree": true] }
                }
                let content = flatFallback && !isFlat ? "malformed" : String(decoding: try data(result), as: UTF8.self)
                body = ["object": "chat.completion", "model": NativeEnrichmentOpenAI.defaultModel, "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]]
            }
            return (try data(body), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        for fallback in [false, true] {
            flatFallback = fallback
            let fields = NativeTargetEnrichment.fields(["position", "personal_website"], scenario: .personal)
            let id = try service.request(targetIDs: [target["id"].string], fields: fields, mode: .review)[0]
            let worker = NativeTargetEnrichmentWorker(db: db, store: store, environment: env, review: review, agent: { _, _, _, _ in throw NativeDBError.conflict })
            let ran = try await worker.runNext(); try check(ran, "production review worker claimed persisted request")
            let preview = try service.preview(id)
            try check(preview.result.enrichments["position"]?.value == .string("営業部長") && preview.result.enrichments["personal_website"]?.value == .string("https://taro.invalid"), "actual provider response survives persistence and review")
            try check(preview.result.enrichments["position"]?.sourceContext?.first?.snippet == quote, "person evidence retained in review history")
            let applied = try service.apply(preview, selected: ["position", "personal_website"])
            try check(fallback ? applied.isEmpty : applied.count == 2, "selected apply respects already applied values")
        }
        let saved = try db.get("crm_Targets", key: ["id": target["id"]])!
        try check(saved["personal_website"] == .text("https://taro.invalid") && saved["company_website"] == .text("https://nihon.invalid"), "production worker and review apply preserve distinct sites")
        try check(searches == 8 && completions == 3, "normal and flat fallback paths verified through production provider")
    }
    static func reference(_ root: URL) async throws {
        let fixture = try json(Data(contentsOf: root.appendingPathComponent("build/native-e2b-reference.json")))
        for item in fixture["cases"] as! [[String: Any]] {
            let wire = Wire(); wire.version = item["version"] as! String; wire.body = Data(base64Encoded: fixture["streamBase64"] as! String)!
            let environment = item["environment"] as! [String: String], options = try NativeE2BConfiguration(environment: .init(lookup: { environment[$0] }))
            wire.createBody = try data(item["sandbox"]!)
            let client = NativeE2BClient(apiKey: "qa-e2b", configuration: options, transport: wire.send)
            var context = self.context; context.mode = NativeTargetEnrichment.Mode(rawValue: item["mode"] as! String)!
            var progress: [String] = []
            let result = try await client.enrich(context: context, anthropic: "qa-anthropic", template: "nextcrm-enrichment", script: "// 日本語の検証用スクリプト\n", report: { progress.append($0.message) })
            try check(result == output && wire.requests.count == (item["requests"] as! [Any]).count, "complete SDK flow " + (item["name"] as! String))
            for (actual, expected) in zip(wire.requests, item["requests"] as! [[String: Any]]) {
                let url = URL(string: expected["url"] as! String)!, components = URLComponents(url: actual.url!, resolvingAgainstBaseURL: false)!, original = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                try check(actual.httpMethod == expected["method"] as? String && actual.url!.scheme == url.scheme && actual.url!.host == url.host && actual.url!.port == url.port && actual.url!.path == url.path && components.queryItems == original.queryItems, "SDK scheme/host/port/path/method/query")
                let headers = expected["headers"] as! [String: String]
                for name in ["x-api-key", "x-access-token", "authorization", "e2b-sandbox-id", "e2b-sandbox-port", "connect-protocol-version", "connect-timeout-ms", "keepalive-ping-interval"] {
                    try check(actual.value(forHTTPHeaderField: name) == headers[name], "SDK header \(name)")
                }
                if let expectedBody = expected["json"] as? [String: Any] {
                    let body = try json(actual.url!.path.hasSuffix("/Start") ? Data(actual.httpBody!.dropFirst(5)) : actual.httpBody!)
                    var normalized = body
                    if var process = body["process"] as? [String: Any], var envs = process["envs"] as? [String: String] {
                        try check(envs.removeValue(forKey: "NEXTCRM_ENRICHMENT_FIELDS") == "[]", "requested fields passed as environment data")
                        process["envs"] = envs; normalized["process"] = process
                    }
                    try check(NSDictionary(dictionary: normalized).isEqual(to: expectedBody), "original SDK JSON payload")
                }
                if let file = expected["file"] as? [String: Any] { try check(String(data: actual.httpBody!, encoding: .utf8)!.contains(file["text"] as! String) && actual.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="), "original script uploaded as multipart file") }
            }
            try check(progress.first?.contains(options.debug ? "開発用" : "一時環境") == true && progress.last?.contains("完了") == true, "Japanese lifecycle progress")
        }
    }
    static func configuration() async throws {
        for environment in [
            ["E2B_API_URL": "file:///tmp/agent"], ["E2B_API_URL": "https://user:secret@example.invalid"],
            ["E2B_API_URL": "https://example.invalid?secret=value"], ["E2B_SANDBOX_URL": "https://example.invalid/#fragment"],
            ["E2B_API_URL": "http://localhost:65536"], ["E2B_API_URL": "https://example.invalid\n"],
            ["E2B_DOMAIN": "bad.invalid/path"], ["E2B_DOMAIN": "user@bad.invalid"], ["E2B_DOMAIN": "bad..invalid"],
            ["E2B_DOMAIN": "bad.invalid%2Fpath"], ["E2B_ACCESS_TOKEN": "key\nsecret"]
        ] { try await rejects("invalid explicit connection settings") { _ = try NativeE2BConfiguration(environment: .init(lookup: { environment[$0] })) } }
        let defaults = NativeE2BConfiguration.standard
        try check(defaults.apiURL == NativeE2BClient.api && !defaults.debug && defaults.insecureOrigins.isEmpty, "standard cloud preserves HTTPS")
        let debug = try NativeE2BConfiguration(environment: .init(lookup: { $0 == "E2B_DEBUG" ? "TRUE" : nil }))
        try check(debug.apiURL.absoluteString == "http://localhost:3000" && debug.insecureOrigins == ["http://localhost:3000", "http://localhost:49983"], "debug opts into only its two local HTTP origins")
        let domain = try NativeE2BConfiguration(environment: .init(lookup: { $0 == "E2B_DOMAIN" ? "corp.invalid:8443" : nil }))
        try check(try domain.sandboxBase(id: "sandbox", responseDomain: "").absoluteString == "https://49983-sandbox.corp.invalid:8443", "empty response domain falls back to configured port/domain")
    }
    static func frames() async throws {
        let complete = try stream()
        for split in [1,2,4,5,7,31,complete.count] {
            let result = NativeE2BCommandResult(report: { _ in })
            for i in stride(from: 0, to: complete.count, by: split) { try await result.append(complete.subdata(in: i..<min(complete.count, i+split))) }
            let output = try await result.output(); try check(output == self.output, "HTTP boundary split \(split)")
        }
        let raw = try JSONEncoder().encode(output), firstJapanese = raw.firstIndex(where: { $0 >= 128 })!
        var fragments = try frame(["event": ["start": ["pid": 1]]])
        for part in [Data(raw.prefix(firstJapanese + 1)),Data(raw.dropFirst(firstJapanese + 1))] { fragments.append(try frame(["event": ["data": ["stdout": part.base64EncodedString()]]])) }
        fragments.append(try frame(["event": ["end": [:]]])) ; fragments.append(try frame([:], flags: 2))
        let result = NativeE2BCommandResult(report: { _ in }); try await result.append(fragments)
        let decoded = try await result.output(); try check(decoded == output, "Japanese UTF-8 spans stdout events")
        for corrupt in [Data(complete.dropLast()),Data(complete.dropLast(7)),try frame([:],flags:1),try frame(["event":["data":["stdout":"?"]]]),Data([0,0,128,0,0])] {
            try await rejects("truncated/compressed/invalid/oversized frame") { let result=NativeE2BCommandResult(report:{_ in}); try await result.append(corrupt); _ = try await result.output() }
        }
        let rpcFailure = try frame(["error":["code":"unavailable","message":"secret"]],flags:2)
        do { var decoder=NativeE2BStream(); _ = try decoder.append(rpcFailure); throw NativeDBError.conflict }
        catch let error as NativeAIError { try check(error.retryable && !error.message.contains("secret"), "Connect error sanitized and retryable") }
        let excessive = try stream(output: Data(repeating:65,count:NativeE2BStream.maximumOutput+1))
        try await rejects("stdout cap") { let result=NativeE2BCommandResult(report:{_ in}); try await result.append(excessive); _ = try await result.output() }
        var messages: [String] = [], urls: [String?] = []
        let progress = Data(("@@NEXTCRM_PROGRESS@@{\"message\":\"日本語の進捗\",\"sourceURL\":\"javascript:bad\"}\n").utf8)
        let tracked=NativeE2BCommandResult(report:{ messages.append($0.message); urls.append($0.sourceURL) }); try await tracked.append(stream(stderr:progress)); _ = try await tracked.output()
        try check(messages.contains("日本語の進捗") && urls.last! == nil, "structured progress and safe source link")
    }
    static func failures() async throws {
        for failure in ["write","version","badVersion","status","result","progress","exit","rpc","metadata"] {
            let wire=Wire(); wire.body=try stream()
            if failure == "write" { wire.failWrite=true }
            if failure == "version" { wire.version="0.0.9" }; if failure == "badVersion" { wire.version="" }
            if failure == "status" { wire.status=401 }
            if failure == "result" { wire.body=try stream(output:Data("not json".utf8)) }
            if failure == "exit" { wire.body=try stream(status:1,stderr:Data("@@NEXTCRM_ERROR@@{\"status\":401}\nsecret-value\n".utf8)) }
            if failure == "rpc" { wire.body=try frame(["error":["code":"unavailable"]],flags:2) }
            if failure == "metadata" { wire.createBody=try data(["sandboxID":"qa-sandbox"]) }
            let client=NativeE2BClient(apiKey:"qa-e2b",transport:wire.send)
            try await rejects("cleanup after \(failure)") { _ = try await client.enrich(context:context,anthropic:"qa-anthropic",template:"nextcrm-enrichment",script:"// script",report:{ item in if failure == "progress" && item.message.contains("準備を進め") { throw NativeDBError.conflict } }) }
            try check(wire.requests.last?.httpMethod == "DELETE", "sandbox cleanup on \(failure)")
        }
        let wire=Wire(); wire.body=try stream(); wire.failKill=true; var warning=false
        let result=try await NativeE2BClient(apiKey:"qa-e2b",transport:wire.send).enrich(context:context,anthropic:"qa-anthropic",template:"nextcrm-enrichment",script:"// script",report:{if $0.kind == .warning { warning=true }})
        try check(result == output && warning, "cleanup failure retains result and reports configured expiry")
        let bad=NativeE2BClient(apiKey:"key\ninvalid",transport:wire.send), count=wire.requests.count
        try await rejects("invalid API key") { _ = try await bad.create(template:"template") }; try check(wire.requests.count == count, "invalid key never transmitted")
        let decoder=NativeE2BCommandResult(report:{_ in}); try await decoder.append(stream(status:1,stderr:Data("@@NEXTCRM_ERROR@@{\"status\":401}\nsecret\n".utf8)))
        do { _ = try await decoder.output(); throw NativeDBError.conflict } catch let error as NativeAIError { try check(!error.retryable && !error.message.contains("secret"), "Anthropic rejection is sanitized without automatic retry") }
    }
    actor Gate { var ready=false; var waiter:CheckedContinuation<Void,Never>?; func signal(){ready=true;waiter?.resume();waiter=nil};func wait()async{if !ready{await withCheckedContinuation{waiter=$0}}} }
    static func cancellation() async throws {
        let gate=Gate(), wire=Wire(); wire.blockCommand=true; wire.didStart={Task{await gate.signal()}}
        let client=NativeE2BClient(apiKey:"qa-e2b",transport:wire.send)
        let task=Task { try await client.enrich(context:context,anthropic:"qa-anthropic",template:"nextcrm-enrichment",script:"// script",report:{_ in}) }
        await gate.wait(); task.cancel()
        do { _ = try await task.value; throw NativeDBError.conflict } catch is CancellationError { try check(wire.requests.last?.httpMethod == "DELETE", "cancelled task still sends cleanup") }
    }
    final class ProtocolStub: URLProtocol, @unchecked Sendable {
        static var response: ((ProtocolStub) -> Void)?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.response?(self) }
        override func stopLoading() {}
    }
    static func transport() async throws {
        let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[ProtocolStub.self]
        let first=try frame(["event":["start":["pid":123]]]), rest=try stream().dropFirst(first.count)
        var release:(()->Void)?, early=false, result=NativeE2BCommandResult(report:{_ in})
        ProtocolStub.response={ stub in
            release={stub.client?.urlProtocol(stub,didLoad:Data(rest));stub.client?.urlProtocolDidFinishLoading(stub)}
            stub.client?.urlProtocol(stub,didReceive:HTTPURLResponse(url:stub.request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/connect+json"])!,cacheStoragePolicy:.notAllowed)
            stub.client?.urlProtocol(stub,didLoad:first)
        }
        let request=URLRequest(url:URL(string:"https://qa.example.invalid/process.Process/Start")!,timeoutInterval:2)
        try await NativeE2BHTTP.transport(request,maximumBytes:NativeE2BStream.maximumWire,configuration:config,headers:{_ in},chunk:{ data in
            try await result.append(data)
            if let action=release { release=nil;early=true;action() }
        })
        let value=try await result.output(); try check(early && value == output, "small streaming frame delivered before EOF")
        ProtocolStub.response={ stub in stub.client?.urlProtocol(stub,didReceive:HTTPURLResponse(url:stub.request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Length":"9999999"])!,cacheStoragePolicy:.notAllowed);stub.client?.urlProtocolDidFinishLoading(stub) }
        try await rejects("oversized Content-Length") { try await NativeE2BHTTP.transport(request,maximumBytes:20,configuration:config,headers:{_ in},chunk:{_ in}) }
        var requests = 0
        ProtocolStub.response = { stub in
            requests += 1
            stub.client?.urlProtocol(stub, didReceive: HTTPURLResponse(url: stub.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: Data("ok".utf8)); stub.client?.urlProtocolDidFinishLoading(stub)
        }
        let http = URLRequest(url: URL(string: "http://localhost:49983/files")!)
        try await rejects("HTTP denied without explicit SDK configuration") { try await NativeE2BHTTP.transport(http, maximumBytes: 10, configuration: config, headers: { _ in }, chunk: { _ in }) }
        try check(requests == 0, "default HTTP rejection happens before sending")
        let debug = try NativeE2BConfiguration(environment: .init(lookup: { $0 == "E2B_DEBUG" ? "true" : nil }))
        var received = Data()
        try await NativeE2BHTTP.transport(http, maximumBytes: 10, configuration: config, insecureOrigins: debug.insecureOrigins, headers: { _ in }, chunk: { received.append($0) })
        try check(received == Data("ok".utf8) && requests == 1, "explicit debug HTTP reaches native URLSession transport")
        let other = URLRequest(url: URL(string: "http://localhost:49984/files")!)
        try await rejects("HTTP port outside configured origins") { try await NativeE2BHTTP.transport(other, maximumBytes: 10, configuration: config, insecureOrigins: debug.insecureOrigins, headers: { _ in }, chunk: { _ in }) }
        try check(requests == 1, "unexpected HTTP origin never contacted")
        ProtocolStub.response = { stub in
            stub.client?.urlProtocol(stub, didReceive: HTTPURLResponse(url: URL(string: "http://outside.invalid/files")!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
        try await rejects("response origin cannot change") { try await NativeE2BHTTP.transport(http, maximumBytes: 10, configuration: config, insecureOrigins: debug.insecureOrigins, headers: { _ in }, chunk: { _ in }) }
        ProtocolStub.response=nil
    }
    static func runtime(_ resources: URL) async throws {
        let wire=Wire(); wire.body=try stream()
        let agent=NativeTargetEnrichmentProvider.makeAgent(resources:resources.appendingPathComponent("build"),transport:wire.send)
        let connection = NativeE2BConnection(choice: .init(source: .environment, credentialID: nil, environmentHash: nil, template: "nextcrm-enrichment"), key: "qa-e2b")
        let result=try await agent(context,"qa-anthropic",connection,{_ in})
        try check(result == output && wire.requests.count == 4, "production agent adapter loads actual bundled script")
        let upload=String(data:wire.requests[1].httpBody!,encoding:.utf8)!
        try check(upload.contains("nativeFieldsInstruction") && upload.contains("execFileSync"), "adapted original script uploaded")
        let missing=NativeTargetEnrichmentProvider.makeAgent(resources:nil,transport:wire.send), before=wire.requests.count
        try await rejects("missing bundled agent") { _ = try await missing(context,"qa-anthropic",connection,{_ in}) }
        try check(wire.requests.count == before, "missing resource creates no remote sandbox")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-E2BRuntime-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), crm=CRMService(db:db,identity:identity), store=NativeAIQAServices()
        var environment = ["ANTHROPIC_API_KEY":"qa-anthropic","E2B_API_KEY":"qa-e2b"]
        let env=NativeAIEnvironment(lookup:{environment[$0]})
        let service=NativeTargetEnrichmentService(service:crm,store:store,environment:env)
        let target=try db.insert("crm_Targets",values:["last_name":.text("検証用"),"company":.text("試験株式会社"),"email":.text("qa@example.invalid"),"created_by":.text(identity.id)],actor:identity.id)
        let runtime=await MainActor.run { NativeTargetEnrichmentRuntime(db:db,store:store,environment:env,review:{_,_,_,_ in .init(enrichments:[:],status:.completed)},agent:agent) }
        let id=try service.request(targetIDs:[target["id"].string],fields:NativeTargetEnrichment.fields(["industry"]),mode:.automatic)[0]
        await MainActor.run { runtime.resume() }
        func idle() async throws {
            for _ in 0..<500 { if await MainActor.run(body:{!runtime.isRunning && runtime.nextWake == nil}) { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw NativeDBError.message("FAIL: runtime did not become idle")
        }
        try await idle()
        try check(try db.job(id:id)?.status == "done" && db.get("crm_Targets",key:["id":target["id"]])?["industry"] == .text("情報通信"), "runtime processes persisted job through production E2B adapter")
        let progress=try db.job(id:id)!.result
        try check((Int(progress["progressSequence"] ?? "0") ?? 0) >= 4, "runtime publishes durable provider progress")
        let gate=Gate(); wire.blockCommand=true; wire.didStart={Task{await gate.signal()}}
        let next=try service.request(targetIDs:[target["id"].string],fields:NativeTargetEnrichment.fields(["industry"]),mode:.automatic,force:true)[0]
        await MainActor.run { runtime.resume() }; await gate.wait()
        try service.cancel(db.job(id:next)!); try await idle()
        try check(try db.job(id:next)?.status == "cancelled" && wire.requests.last?.httpMethod == "DELETE", "real cancellation notification stops provider and cleans up")
        try check(try db.get(NativeTargetEnrichment.model,key:["id":.text(next)])?["result"] == .null, "late cancellation cannot publish a result")
        await MainActor.run { runtime.stop() }
        environment["E2B_API_URL"] = "https://control.initial.invalid/v1"
        environment["E2B_SANDBOX_URL"] = "https://worker.initial.invalid/v1"
        environment["E2B_ACCESS_TOKEN"] = "initial-access-token"
        wire.blockCommand = false; wire.requests = []
        wire.didStart = {
            environment["E2B_API_URL"] = "https://control.changed.invalid"
            environment["E2B_ACCESS_TOKEN"] = "changed-access-token"
        }
        let changed = try service.request(targetIDs: [target["id"].string], fields: NativeTargetEnrichment.fields(["industry"]), mode: .automatic, force: true)[0]
        // The runner deliberately retries conflicts with fresh credentials.
        // Observe one real worker attempt before that permitted retry so a
        // later successful attempt cannot hide the original fencing behavior.
        let worker = NativeTargetEnrichmentWorker(db: db, store: store, environment: env, review: { _, _, _, _ in throw NativeDBError.conflict }, agent: agent)
        _ = try await worker.runNext()
        try check(try db.job(id: changed)?.status == "retry" && db.get(NativeTargetEnrichment.model, key: ["id": .text(changed)])?["result"] == .null, "configuration change prevents result publication in durable worker attempt")
        try check(wire.requests.first?.url?.absoluteString == "https://control.initial.invalid/v1/sandboxes" && wire.requests.last?.url?.absoluteString == "https://control.initial.invalid/v1/sandboxes/qa-sandbox" && wire.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer initial-access-token", "cleanup retains original endpoint and credential after config changes")
        try check(!wire.requests.contains { $0.url?.host == "control.changed.invalid" || $0.value(forHTTPHeaderField: "Authorization") == "Bearer changed-access-token" }, "old job never mixes a new destination or access token")
        await MainActor.run { runtime.stop() }
        let stopped=await MainActor.run { runtime.nextWake == nil }; try check(stopped, "stopped runtime has no wake timer")
    }
}
