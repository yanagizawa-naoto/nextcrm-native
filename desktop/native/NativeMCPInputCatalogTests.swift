import Foundation

@main enum NativeMCPInputCatalogTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure.assertion(label) }; checks += 1
    }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    actor Calls {
        var names: [String] = [], inputs: [[String: Any]] = []
        func append(_ name: String, _ input: [String: Any]) { names.append(name); inputs.append(input) }
        var count: Int { names.count }
        var last: [String: Any]? { inputs.last }
    }
    static func main() async {
        do { try await run(); print("Native MCP input rules: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let catalog = try NativeMCPInputCatalog(data: bytes)
        try check(catalog.tools.count == 123, "all original123 tools present")
        try check(catalog.ruleCount == 162 && catalog.regularExpressionCount == 3, "shared rule graph and regexes")
        try check(catalog.tools.allSatisfy { $0["schema"] == nil }, "internal rules never exposed in tool metadata")
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        var compared = 0
        for tool in reference["validation"] as! [[String: Any]] {
            let name = tool["name"] as! String
            for (index, sample) in (tool["cases"] as! [[String: Any]]).enumerated() {
                let label = "\(name) #\(index) \(sample["label"]!)"
                let outcome = try catalog.evaluate(tool: name, input: sample["input"]!)
                if let expected = sample["data"] {
                    try check(outcome.isValid, "\(label) unexpected rejection: \(outcome.message)")
                    try check(try json(outcome.value!) == json(expected), "\(label) normalized value mismatch")
                } else {
                    try check(!outcome.isValid && !outcome.truncated, "\(label) expected complete validation failure")
                    let actual = try json(outcome.issues.map(\.json)), expected = try json(sample["issues"]!)
                    try check(actual == expected, "\(label) issues differ: actual \(String(decoding: actual, as: UTF8.self)); expected \(String(decoding: expected, as: UTF8.self))")
                    try check(outcome.message == sample["message"] as? String, "\(label) SDK error formatting")
                }
                compared += 1
            }
        }
        try check(compared >= 8000, "expanded original-source fixture coverage")
        for sample in reference["rawNumbers"] as! [[String: Any]] {
            let name = sample["name"] as! String
            let input = try JSONSerialization.jsonObject(with: Data((sample["raw"] as! String).utf8))
            let outcome = try catalog.evaluate(tool: name, input: input)
            if let expected = sample["data"] {
                try check(outcome.isValid, "raw JSON numeric input accepted " + name)
                try check(try json(outcome.value!) == json(expected), "raw JSON binary64 normalization " + name)
            } else {
                try check(!outcome.isValid, "raw JSON numeric rejection " + name)
                try check(try json(outcome.issues.map(\.json)) == json(sample["issues"]!), "raw JSON numeric issues " + name)
            }
        }
        let calls = Calls()
        let effect: NativeMCPProtocol.Call = { name, input, _ in
            await calls.append(name, input)
            return ["content": [["type": "text", "text": String(decoding: try json(input), as: UTF8.self)]]]
        }
        let valid = try await catalog.dispatch(tool: "crm_list_accounts", arguments: ["__unknown": "remove"], id: 1, perform: effect)
        let normalized = await calls.last
        try check(await calls.count == 1, "valid input dispatched once")
        try check(normalized?["limit"] as? Int == 20 && normalized?["offset"] as? Int == 0 && normalized?["__unknown"] == nil, "defaulted and stripped arguments reach effect")
        try check(valid["isError"] == nil, "successful effect returned")
        let invalid = try await catalog.dispatch(tool: "crm_list_accounts", arguments: ["limit": 0], id: 2, perform: effect)
        let message = (invalid["content"] as? [[String: Any]])?.first?["text"] as? String
        try check(invalid["isError"] as? Bool == true && message == "MCP error -32602: Input validation error: Invalid arguments for tool crm_list_accounts: Too small: expected number to be >=1 at limit", "wire-compatible validation failure")
        try check(await calls.count == 1, "invalid input cannot perform effect")
        let unknown = try await catalog.dispatch(tool: "missing_tool", arguments: [:], id: 3, perform: effect)
        try check(unknown["isError"] as? Bool == true, "unknown tool rejected")
        try check(await calls.count == 1, "unknown tool cannot perform effect")
        let protocolLayer = try NativeMCPProtocol(tools: catalog.tools) { name, arguments, id in
            try await catalog.dispatch(tool: name, arguments: arguments, id: id, perform: effect)
        }
        let response = await protocolLayer.handle(.init(method: "POST", path: "/api/mcp/mcp", headers: ["accept": "application/json, text/event-stream", "content-type": "application/json"], body: try json([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "crm_list_accounts", "arguments": ["offset": -1]],
        ])))
        let buffer = Buffer(); try await response.writeBody { await buffer.append($0) }
        let text = String(decoding: await buffer.bytes, as: UTF8.self)
        try check(text.contains("MCP error -32602") && text.contains("at offset"), "protocol streams actual catalog validation error")
        try check(await calls.count == 1, "protocol validation failure has no effect")
        let bounded = try NativeMCPInputCatalog(data: bytes, maximumIssues: 8)
        let many = try bounded.evaluate(tool: "crm_add_to_target_list", input: ["target_list_id": "bad", "target_ids": Array(repeating: "bad", count: 10000)])
        try check(!many.isValid && many.truncated && many.issues.count == 8, "bounded diagnostics for adversarial array")
        try check(many.message.utf8.count < 1500, "diagnostic output does not grow with input count")
        var document = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var changed = document["nodes"] as! [[String: Any]]
        let original = changed
        changed[0]["unexpected"] = true; document["nodes"] = changed
        try invalidCatalog(document, "unsupported rule field")
        changed = original; changed[0] = ["type": "optional", "inner": 0]; document["nodes"] = changed
        try invalidCatalog(document, "cyclic node reference")
        changed = original; changed[0] = ["type": "execute-code"]; document["nodes"] = changed
        try invalidCatalog(document, "unsupported rule kind")
        changed = original; changed[0]["checks"] = [["kind": "unknown-check"]]; document["nodes"] = changed
        try invalidCatalog(document, "unsupported check")
        document["nodes"] = original
        var tools = document["tools"] as! [[String: Any]]; tools.append(tools[0]); document["tools"] = tools
        try invalidCatalog(document, "duplicate tool name")
        // Cancellation must stop before entering the real handler.
        let gate = Gate()
        let operation = Task { await gate.wait(); return try await catalog.dispatch(tool: "crm_list_accounts", arguments: [:], id: 5, perform: effect) }
        operation.cancel(); await gate.open()
        do { _ = try await operation.value; throw Failure.assertion("canceled dispatch succeeded") }
        catch is CancellationError { try check(await calls.count == 1, "cancellation fence before effect") }
        print("Compared \(compared) original-source cases across123 tools;162 shared nodes/3 regexes")
    }
    static func invalidCatalog(_ value: [String: Any], _ label: String) throws {
        do { _ = try NativeMCPInputCatalog(data: json(value)); throw Failure.assertion("accepted " + label) }
        catch NativeMCPInputCatalogError.invalidCatalog { try check(true, label) }
    }
    actor Buffer { var bytes = Data(); func append(_ value: Data) { bytes.append(value) } }
    actor Gate {
        var waiting: CheckedContinuation<Void, Never>?, opened = false
        func wait() async { if opened { return }; await withCheckedContinuation { waiting = $0 } }
        func open() { opened = true; waiting?.resume(); waiting = nil }
    }
}
