import Foundation

@main enum NativeMCPProtocolTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw TestError.failure(label) }; checks += 1
    }
    enum TestError: Error { case failure(String), secretFailure }
    actor Buffer {
        var bytes = Data()
        func append(_ value: Data) { bytes.append(value) }
    }
    actor Gate {
        var opened = false, waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async { if opened { return }; await withCheckedContinuation { waiting.append($0) } }
        func open() { opened = true; let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
    }
    actor Metrics {
        var calls = 0, frames = 0, bytes = 0, maximum = 0
        var snapshot: (calls: Int, frames: Int, bytes: Int, maximum: Int) { (calls, frames, bytes, maximum) }
        func called() { calls += 1 }
        func received(_ count: Int) -> Bool { frames += 1; bytes += count; maximum = max(maximum, count); return frames == 1 }
    }
    // Collection exists only in the reference comparison, never the transport.
    static func materialize(_ response: NativeMCPHTTPResponse) async throws -> NativeMCPHTTPResponse {
        let buffer = Buffer(); try await response.writeBody { await buffer.append($0) }
        var copy = response; copy.body = await buffer.bytes; copy.stream = nil; return copy
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func messages(_ response: NativeMCPHTTPResponse) throws -> [Any] {
        if response.headers["content-type"] == "text/event-stream" {
            return try String(decoding: response.body, as: UTF8.self).components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }.map { try JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) }
        }
        return response.body.isEmpty ? [] : [try JSONSerialization.jsonObject(with: response.body)]
    }
    static func main() async {
        do { try await run(); print("Native MCP protocol: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        let cases = reference["cases"] as! [[String: Any]], listed = cases.first { $0["label"] as? String == "list-without-session" }!
        let catalog = ((listed["messages"] as! [[String: Any]])[0]["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let protocolLayer = try NativeMCPProtocol(tools: catalog, name: "NextCRM native reference", version: "0") { name, args, _ in
            guard let text = args["text"] as? String else {
                return NativeMCPProtocol.toolError("MCP error -32602: Input validation error: Invalid arguments for tool fixture_echo: Invalid input: expected string, received number at text")
            }
            return ["content": [["type": "text", "text": String(decoding: try json(["text": text]), as: UTF8.self)]]]
        }
        for item in cases {
            let input = item["request"] as! [String: Any], label = item["label"] as! String
            let request = NativeMCPHTTPRequest(method: input["method"] as! String, path: "/api/mcp/mcp", headers: input["headers"] as! [String: String], body: Data((input["body"] as? String ?? "").utf8))
            let response = try await materialize(await protocolLayer.handle(request))
            try check(response.status == item["status"] as? Int, "SDK status: " + label)
            try check(response.headers["content-type"] == item["contentType"] as? String, "SDK content type: " + label)
            try check(try json(messages(response)) == json(item["messages"]!), "SDK JSON-RPC result: " + label)
            try check(response.headers["mcp-session-id"] == nil, "stateless response: " + label)
            if label == "get-stateless" { try check(response.keepOpen, "GET retains standalone SSE stream") }
        }
        let headers = ["accept": "application/json, text/event-stream", "content-type": "application/json"]
        func request(_ body: Any, method: String = "POST", path: String = "/api/mcp/mcp") throws -> NativeMCPHTTPRequest {
            .init(method: method, path: path, headers: headers, body: try json(body))
        }
        for id: Any in [true, NSNull(), ["id": 1], [1]] {
            let response = await protocolLayer.handle(try request(["jsonrpc": "2.0", "id": id, "method": "ping"]))
            try check(response.status == 400, "reject non-string/number IDs")
        }
        for params: Any in [true, NSNull(), [], ["_meta": "wrong"], ["_meta": ["progressToken": false]]] {
            let response = await protocolLayer.handle(try request(["jsonrpc": "2.0", "id": 1, "method": "ping", "params": params]))
            try check(response.status == 400, "reject malformed params")
        }
        let invalidBatch = await protocolLayer.handle(try request([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["bad": true]]))
        try check(invalidBatch.status == 400, "batch rejected as a whole on malformed envelope")
        let patch = await protocolLayer.handle(try request([:], method: "PATCH"))
        try check(patch.status == 405 && patch.headers["allow"] == "GET, POST, DELETE", "allowed HTTP methods")
        try check(await protocolLayer.handle(try request([:], path: "/elsewhere")).status == 404, "unknown path")
        try check(await protocolLayer.handle(try request([:], path: "/api/mcp/sse")).status == 501, "default original legacy SSE unavailable")
        let limited = try NativeMCPProtocol(tools: catalog, maximumBodyBytes: 64, maximumBatchSize: 1) { _, _, _ in throw TestError.secretFailure }
        let tooLarge = NativeMCPHTTPRequest(method: "POST", path: "/api/mcp/mcp", headers: headers, body: Data(repeating: 0x20, count: 65))
        try check(await limited.handle(tooLarge).status == 413, "body bounded before parsing")
        let batchLimited = try NativeMCPProtocol(tools: catalog, maximumBatchSize: 1) { _, _, _ in throw TestError.secretFailure }
        let batch = try request([["jsonrpc": "2.0", "id": 1, "method": "ping"], ["jsonrpc": "2.0", "id": 2, "method": "ping"]])
        try check(await batchLimited.handle(batch).status == 413, "batch count bounded")
        let failing = try NativeMCPProtocol(tools: catalog) { _, _, _ in throw TestError.secretFailure }
        let failure = try await materialize(await failing.handle(try request(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "fixture_echo", "arguments": ["text": "x"]]])))
        let text = String(decoding: failure.body, as: UTF8.self)
        try check(text.contains("Internal tool error") && !text.contains("secretFailure"), "internal errors do not disclose exception data")
        do { _ = try NativeMCPProtocol(tools: catalog + catalog) { _, _, _ in [:] }; throw TestError.failure("duplicate tools accepted") }
        catch NativeMCPProtocolError.invalidCatalog { checks += 1 }
        let metrics = Metrics(), arrived = Gate(), release = Gate()
        let streaming = try NativeMCPProtocol(tools: catalog) { _, _, _ in
            await metrics.called()
            return ["content": [["type": "text", "text": String(repeating: "x", count: 1_048_576)]]]
        }
        let calls = (1...20).map { ["jsonrpc": "2.0", "id": $0, "method": "tools/call", "params": ["name": "fixture_echo"]] as [String: Any] }
        let prepared = await streaming.handle(try request(calls))
        let before = await metrics.calls
        try check(prepared.body.isEmpty && prepared.stream != nil && before == 0, "stream preparation retains no output and runs no effects")
        let writing = Task {
            try await prepared.writeBody { data in
                if await metrics.received(data.count) { await arrived.open(); await release.wait() }
            }
        }
        await arrived.wait()
        try check(await metrics.calls == 1, "backpressure prevents next handler from running")
        await release.open(); try await writing.value
        let after = await metrics.snapshot
        try check(after.frames == 20 && after.calls == 20, "all responses streamed in order")
        try check(after.bytes > 20 * 1_048_576 && after.maximum < 1_100_000, "20MiB total emitted with at most one approximately1MiB event per send")
        do { try await prepared.writeBody { _ in }; throw TestError.failure("stream consumed twice") }
        catch NativeMCPProtocolError.streamAlreadyConsumed { checks += 1 }
        try check(await metrics.calls == 20, "duplicate consumer cannot repeat effects")
        let disconnected = Metrics()
        let failingSink = try NativeMCPProtocol(tools: catalog) { _, _, _ in await disconnected.called(); return ["content": []] }
        let pending = await failingSink.handle(try request(calls))
        do { try await pending.writeBody { _ in throw TestError.secretFailure }; throw TestError.failure("disconnect ignored") }
        catch TestError.secretFailure { checks += 1 }
        try check(await disconnected.calls == 1, "disconnect stops remaining batch effects")
        let entered = Gate(), cancelledMetrics = Metrics()
        let cancellable = try NativeMCPProtocol(tools: catalog) { _, _, _ in
            await entered.open(); try await Task.sleep(nanoseconds: 10_000_000_000); return ["content": []]
        }
        let cancelResponse = await cancellable.handle(try request(calls))
        let active = Task { try await cancelResponse.writeBody { data in _ = await cancelledMetrics.received(data.count) } }
        await entered.wait(); active.cancel()
        do { try await active.value; throw TestError.failure("in-flight cancellation ignored") }
        catch is CancellationError { checks += 1 }
        try check(await cancelledMetrics.frames == 0, "cancelled producer sends no partial event")
    }
}
