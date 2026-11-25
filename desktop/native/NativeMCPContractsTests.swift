import Foundation

@main enum NativeMCPContractsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ label: String) throws { guard condition else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try Dictionary(uniqueKeysWithValues: object.map { key, value in
            let stored: SQLValue
            if value is NSNull { stored = .null }
            else if model.field(key)?.type == "Decimal", let text = value as? String, var decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) { stored = .text(NSDecimalString(&decimal, Locale(identifier: "en_US_POSIX"))) }
            else if let number = value as? NSNumber { stored = .integer(number.int64Value) }
            else if let text = value as? String { stored = .text(text) }
            else { stored = .text(String(decoding: try json(value), as: UTF8.self)) }
            return (key, stored)
        })
    }
    actor Buffer { var bytes = Data(); func append(_ bytes: Data) { self.bytes.append(bytes) } }
    static func call(_ router: NativeMCPRequestRouter, tool: String, input: [String: Any], rawInputJSON: String? = nil, header: String) async throws -> [String: Any] {
        let body: Data
        if let rawInputJSON {
            body = Data(("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":" + String(decoding: try json(tool), as: UTF8.self) + ",\"arguments\":" + rawInputJSON + "}}").utf8)
        } else { body = try json(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": input]]) }
        let request = NativeMCPHTTPRequest(method: "POST", path: "/api/mcp/mcp", headers: ["accept": "application/json, text/event-stream", "content-type": "application/json", "authorization": header], body: body)
        let buffer = Buffer(), response = await router.handle(request)
        try await response.writeBody { await buffer.append($0) }
        let line = String(decoding: await buffer.bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!
        return (try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any])["result"] as! [String: Any]
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] {
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static func normalize(_ value: Any, map: [String: String], generated: Set<String>, implicitStart: Bool) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<internal>" }
            let id = (object["id"] as? String).map { map[$0] ?? $0 }
            for (key, item) in object {
                let dynamic = ["updatedAt", "deletedAt"].contains(key) || id.map { generated.contains($0) && key == "createdAt" || $0.hasSuffix("009000") && implicitStart && key == "startDate" } == true
                if dynamic && !(item is NSNull) {
                    try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid timestamp " + key); object[key] = "<date>"
                } else { object[key] = try normalize(item, map: map, generated: generated, implicitStart: implicitStart) }
            }
            return object
        }
        if let array = value as? [Any] { return try array.map { try normalize($0, map: map, generated: generated, implicitStart: implicitStart) } }
        if let text = value as? String, let mapped = map[text] { return mapped }
        return value
    }
    static func all(_ model: String, db: NativeDatabase) throws -> [NativeRecord] {
        let fields = try db.schema.model(model).fields.map(\.name)
        var result: [NativeRecord] = [], offset = 0
        while true {
            let rows = try db.page(model, fields: fields, includeDeleted: true, offset: offset, insertionOrderForTies: true).rows
            result += rows; if rows.count < 100 { return result }; offset += rows.count
        }
    }
    static func main() async {
        do { try await run(); print("Native MCP contracts: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-contracts-reference.json"))) as! [String: Any]
        for seed in reference["products"] as! [[String: Any]] {
            _ = try fixture.db.insert("crm_Products", values: values(seed, model: fixture.db.schema.model("crm_Products")), actor: fixture.admin.identity.id)
        }
        let registry = NativeMCPAccounts.handlers.merging(NativeMCPContracts.handlers) { _, _ in fatalError("duplicate tool") }, router = try fixture.router(handlers: registry)
        try check(NativeMCPContracts.names == Set(reference["tools"] as! [String]), "all five original registered tools implemented")
        try check(router.missingTools.count == 112, "partial registry explicitly rejected for full runtime")
        for sample in reference["cases"] as! [[String: Any]] {
            try fixture.db.transaction {
                for model in ["crm_ContractLineItems", "crm_Contracts"] { for row in try all(model, db: fixture.db) { try fixture.db.remove(row, actor: fixture.admin.identity.id) } }
                for (key, model) in [("seeds", "crm_Contracts"), ("lineSeeds", "crm_ContractLineItems")] {
                    for seed in reference[key] as! [[String: Any]] { _ = try fixture.db.insert(model, values: values(seed, model: fixture.db.schema.model(model)), actor: fixture.admin.identity.id) }
                }
            }
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(input)"
            let contractAudit = try fixture.db.auditCount("crm_Contracts"), lineAudit = try fixture.db.auditCount("crm_ContractLineItems")
            let result = try await call(router, tool: tool, input: input, rawInputJSON: sample["rawInputJSON"] as? String, header: fixture.header(user)), actual = try payload(result)
            let expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            var mapping: [String: String] = [:], generated = Set<String>()
            if tool == "crm_create_contract", let row = actual["data"] as? [String: Any], let expectedRow = expected["data"] as? [String: Any] {
                try check(UUID(uuidString: row["id"] as! String) != nil, "generated contract UUID")
                mapping[row["id"] as! String] = expectedRow["id"] as? String
                let items = row["lineItems"] as! [[String: Any]], expectedItems = expectedRow["lineItems"] as! [[String: Any]]
                try check(items.count == expectedItems.count, "complete nested item count")
                for (item, expectedItem) in zip(items, expectedItems) {
                    try check(UUID(uuidString: item["id"] as! String) != nil, "generated line UUID")
                    mapping[item["id"] as! String] = expectedItem["id"] as? String
                }
                generated = Set(mapping.values)
            }
            func normalized(_ value: Any, actual: Bool) throws -> Any { try normalize(value, map: actual ? mapping : [:], generated: generated, implicitStart: input["startDate"] == nil) }
            let left = try json(normalized(actual, actual: true)), right = try json(normalized(expected, actual: false))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "error flag " + label)
            for (key, model) in [("contracts", "crm_Contracts"), ("lines", "crm_ContractLineItems")] {
                let actualRows = try all(model, db: fixture.db).map { try NativeMCPWire.record($0, schema: fixture.db.schema) }
                let actualState = try (normalized(actualRows, actual: true) as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
                let expectedState = try (normalized(sample[key]!, actual: false) as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
                try check(try json(actualState) == json(expectedState), "all persisted \(key) fields / rollback " + label)
            }
            let writes = ["crm_create_contract", "crm_update_contract", "crm_delete_contract"].contains(tool) && result["isError"] as? Bool != true
            try check(try fixture.db.auditCount("crm_Contracts") == contractAudit + (writes ? 1 : 0), "contract audit atomicity " + label)
            let createdLines = writes && tool == "crm_create_contract" ? (input["lineItems"] as? [Any])?.count ?? 0 : 0
            try check(try fixture.db.auditCount("crm_ContractLineItems") == lineAudit + createdLines, "nested line audit atomicity " + label)
            if writes {
                let id = tool == "crm_create_contract" ? (actual["data"] as! [String: Any])["id"] as! String : input["id"] as! String
                let row = try fixture.db.get("crm_Contracts", key: ["id": .text(id)])!
                try check(try fixture.db.history(row).first?["actor"] == .text(user), "audit attributed to token actor")
            }
        }
        print("Compared \((reference["cases"] as! [Any]).count) original contract cases, nested lines, Decimal/date/projection semantics and atomic SQLite effects")
    }
}
