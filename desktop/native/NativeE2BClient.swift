import Foundation

struct NativeE2BClient {
    struct Sandbox: Decodable {
        let sandboxID: String, envdVersion: String, envdAccessToken: String?
        let domain: String?
        func version(atLeast target: (Int, Int, Int)) throws -> Bool {
            let components = envdVersion.split(separator: "-", maxSplits: 1)
            guard let release = components.first else { throw NativeE2BHTTP.invalid() }
            let segments = release.split(separator: ".", omittingEmptySubsequences: false)
            let numbers = segments.compactMap { Int($0.split(separator: "+", maxSplits: 1).first ?? "") }
            guard segments.count == 3, numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { throw NativeE2BHTTP.invalid() }
            let value = (numbers[0], numbers[1], numbers[2]); return value > target || value == target && components.count == 1
        }
    }
    static let api = URL(string: "https://api.e2b.app")!, scriptPath = "/home/user/agent.mjs"
    private let key: String, transport: NativeE2BHTTP.Transport, configuration: NativeE2BConfiguration
    init(apiKey: String, configuration: NativeE2BConfiguration = .standard, transport: NativeE2BHTTP.Transport? = nil) {
        key = apiKey; self.configuration = configuration; self.transport = transport ?? NativeE2BHTTP.configured(configuration)
    }
    private func token(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 16_384, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw NativeAIError(message: "E2Bの接続設定を確認してください。") }; return value
    }
    private func request(_ url: URL, method: String = "POST", sandbox: Sandbox? = nil, timeout: TimeInterval = 60) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout); request.httpMethod = method
        request.setValue("NextCRM-Native", forHTTPHeaderField: "User-Agent")
        if let sandbox {
            request.setValue(sandbox.sandboxID, forHTTPHeaderField: "E2b-Sandbox-Id"); request.setValue("49983", forHTTPHeaderField: "E2b-Sandbox-Port")
            if let access = sandbox.envdAccessToken, !access.isEmpty { request.setValue(try token(access), forHTTPHeaderField: "X-Access-Token") }
        } else {
            request.setValue(try token(key), forHTTPHeaderField: "X-API-KEY")
            if let access = configuration.accessToken { request.setValue("Bearer " + (try token(access)), forHTTPHeaderField: "Authorization") }
        }
        return request
    }
    private func sandboxID(_ value: String) throws -> String {
        if configuration.debug && value == "debug_sandbox_id" { return value }
        guard !value.isEmpty, value.utf8.count <= 128, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw NativeE2BHTTP.invalid() }; return value
    }
    private func base(_ sandbox: Sandbox) throws -> URL {
        try configuration.sandboxBase(id: sandboxID(sandbox.sandboxID), responseDomain: sandbox.domain)
    }
    private func control(_ request: URLRequest, limit: Int = 65_536, success: Set<Int> = [200,201,204]) async throws -> Data {
        var data = Data(), received = false
        try await transport(request, limit, { response in
            guard response.url == request.url, response.expectedContentLength <= limit else { throw NativeE2BHTTP.invalid() }
            guard success.contains(response.statusCode) else { throw NativeE2BHTTP.httpError(response.statusCode) }; received = true
        }, { chunk in guard received, data.count <= limit - chunk.count else { throw NativeE2BHTTP.oversized() }; data.append(chunk) })
        guard received else { throw NativeE2BHTTP.invalid() }; return data
    }
    func create(template: String) async throws -> Sandbox {
        guard !template.isEmpty, template.utf8.count <= 512 else { throw NativeE2BHTTP.invalid() }
        if configuration.debug { return .init(sandboxID: "debug_sandbox_id", envdVersion: "99.99.99", envdAccessToken: nil, domain: nil) }
        var request = try request(configuration.apiURL.appendingPathComponent("sandboxes")); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["templateID": template, "timeout": 300, "secure": true, "allow_internet_access": true, "autoPause": false], options: .sortedKeys)
        let data = try await control(request)
        guard let sandbox = try? JSONDecoder().decode(Sandbox.self, from: data) else {
            // A malformed metadata response may still identify a created
            // sandbox. Clean it up before rejecting the response.
            struct Identity: Decodable { let sandboxID: String }
            if let identity = try? JSONDecoder().decode(Identity.self, from: data), (try? sandboxID(identity.sandboxID)) != nil {
                _ = await cleanup(.init(sandboxID: identity.sandboxID, envdVersion: "", envdAccessToken: nil, domain: nil))
            }
            throw NativeE2BHTTP.invalid()
        }
        _ = try sandboxID(sandbox.sandboxID); return sandbox
    }
    func write(_ script: String, sandbox: Sandbox) async throws {
        guard script.utf8.count <= 256 * 1024, try sandbox.version(atLeast: (0,1,0)) else { throw NativeAIError(message: "E2Bの取得用テンプレートを更新してください。") }
        var parts = URLComponents(url: try base(sandbox).appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "path", value: Self.scriptPath)]
        if try !sandbox.version(atLeast: (0,4,0)) { parts.queryItems!.append(.init(name: "username", value: "user")) }
        let boundary = "NextCRM-" + UUID().uuidString
        var request = try request(parts.url!, sandbox: sandbox)
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"blob\"\r\nContent-Type: application/octet-stream\r\n\r\n" + script + "\r\n--\(boundary)--\r\n").utf8)
        let body = try await control(request)
        guard let files = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]], files.count == 1, files[0]["path"] as? String == Self.scriptPath else { throw NativeE2BHTTP.invalid() }
    }
    func run(sandbox: Sandbox, context: NativeTargetEnrichmentContext, anthropic: String, report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeTargetAgentOutput {
        var request = try request(base(sandbox).appendingPathComponent("process.Process/Start"), sandbox: sandbox, timeout: context.mode == .contact ? 70 : 320)
        request.setValue("application/connect+json", forHTTPHeaderField: "Content-Type"); request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("50", forHTTPHeaderField: "Keepalive-Ping-Interval")
        if try !sandbox.version(atLeast: (0,4,0)) { request.setValue("Basic dXNlcjo=", forHTTPHeaderField: "Authorization") }
        if context.mode == .contact { request.setValue("60000", forHTTPHeaderField: "Connect-Timeout-Ms") }
        let envs = ["ANTHROPIC_API_KEY": try token(anthropic), "COMPANY_NAME": context.company ?? "", "COMPANY_WEBSITE": context.website ?? "",
                    "TARGET_EMAIL": context.email ?? "", "TARGET_NAME": context.name ?? "", "KNOWN_DOMAIN": context.knownDomain ?? "", "NEXTCRM_ENRICHMENT_FIELDS": try NativeContactEnrichment.json(context.fields)]
        let body = try JSONSerialization.data(withJSONObject: ["process": ["cmd": "/bin/bash", "args": ["-l", "-c", "node " + Self.scriptPath], "envs": envs], "stdin": false], options: .sortedKeys)
        request.httpBody = NativeE2BHTTP.frame(body)
        let result = NativeE2BCommandResult(report: report); var received = false
        try await transport(request, NativeE2BStream.maximumWire, { response in
            guard response.url == request.url, response.expectedContentLength <= NativeE2BStream.maximumWire else { throw NativeE2BHTTP.invalid() }
            guard response.statusCode == 200 else { throw NativeE2BHTTP.httpError(response.statusCode) }
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
            let encoding = response.value(forHTTPHeaderField: "Connect-Content-Encoding")?.lowercased() ?? "identity"
            guard type == "application/connect+json", encoding == "identity" else { throw NativeE2BHTTP.invalid() }; received = true
        }, { data in guard received else { throw NativeE2BHTTP.invalid() }; try Task.checkCancellation(); try await result.append(data) })
        guard received else { throw NativeE2BHTTP.invalid() }; try Task.checkCancellation(); return try await result.output()
    }
    func kill(_ sandbox: Sandbox) async throws {
        if configuration.debug { return }
        let id = try sandboxID(sandbox.sandboxID)
        _ = try await control(request(configuration.apiURL.appendingPathComponent("sandboxes").appendingPathComponent(id), method: "DELETE", timeout: 10), limit: 4096, success: [200,204,404])
    }
    private func cleanup(_ sandbox: Sandbox) async -> Bool {
        await Task.detached { () -> Bool in do { try await self.kill(sandbox); return true } catch { return false } }.value
    }
    func enrich(context: NativeTargetEnrichmentContext, anthropic: String, template: String, script: String, report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeTargetAgentOutput {
        guard !script.isEmpty, script.utf8.count <= 256 * 1024 else { throw NativeE2BHTTP.invalid() }
        try Task.checkCancellation(); try await report(.init(message: configuration.debug ? "開発用の実行環境へ接続しています。" : "取得用の一時環境を準備しています。", kind: .agent))
        let sandbox = try await create(template: template)
        let result: Result<NativeTargetAgentOutput, Error>
        do {
            try Task.checkCancellation(); try await report(.init(message: "情報取得の準備を進めています。", kind: .agent))
            try await write(script, sandbox: sandbox)
            try Task.checkCancellation(); try await report(.init(message: "企業・担当者の情報を調べています。", kind: .agent))
            result = .success(try await run(sandbox: sandbox, context: context, anthropic: anthropic, report: report))
        } catch { result = .failure(error) }
        // Cleanup must survive cancellation of the parent request. The server
        // also has the original 300-second lifetime if the connection is lost.
        let cleaned = await cleanup(sandbox)
        let output = try result.get(); try Task.checkCancellation()
        if !cleaned { try await report(.init(message: "取得用の一時環境の終了を確認できませんでした。終了期限は5分に設定されています。", kind: .warning)) }
        try await report(.init(message: "企業・担当者の情報取得が完了しました。", kind: .success)); return output
    }
}
