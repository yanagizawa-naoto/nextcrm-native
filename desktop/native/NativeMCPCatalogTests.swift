import Foundation
import SQLite3

@main enum NativeMCPCatalogTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ label: String) throws { guard condition else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try Dictionary(uniqueKeysWithValues: object.map { key, value in
            let stored: SQLValue
            if value is NSNull { stored = .null }
            else if model.field(key)?.type == "Decimal", let text = (value as? String) ?? (value as? NSNumber)?.stringValue, var decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) { stored = .text(NSDecimalString(&decimal, Locale(identifier: "en_US_POSIX"))) }
            else if model.field(key)?.type == "DateTime", let text = value as? String, let canonical = NativeMCPPriceDate.parse(text) { stored = .text(canonical) }
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
    static func normalize(_ value: Any, map: [String: String], generated: Set<String>) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<internal>" }
            let id = (object["id"] as? String).map { map[$0] ?? $0 }
            for (key, item) in object {
                if ["updatedAt", "deletedAt"].contains(key) || key == "createdAt" && id.map(generated.contains) == true {
                    if !(item is NSNull) { try check((item as? String).flatMap(NativeMCPPriceDate.parse) != nil, "valid dynamic timestamp"); object[key] = "<date>" }
                } else { object[key] = try normalize(item, map: map, generated: generated) }
            }; return object
        }
        if let array = value as? [Any] { return try array.map { try normalize($0, map: map, generated: generated) } }
        if let text = value as? String { return map[text] ?? text }; return value
    }
    static func sql(_ text: String, fixture: NativeMCPAccountsFixture) throws {
        var handle: OpaquePointer?; guard sqlite3_open(fixture.root.appendingPathComponent("crm.sqlite").path, &handle) == SQLITE_OK else { throw Failure.assertion("fixture SQL open") }; defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion("fixture SQL: " + String(cString: sqlite3_errmsg(handle))) }
    }
    static func main() async { do { try await run(); print("Native MCP catalog: \(checks) checks passed") } catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1])); defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-catalog-reference.json"))) as! [String: Any], seeds = reference["seeds"] as! [String: [[String: Any]]]
        try check(TimeZone.current.identifier == reference["timeZone"] as! String, "source and native timezone")
        for sample in reference["dateCases"] as! [[String: Any]] {
            let raw = sample["text"] as! String, actual: Any = NativeMCPPriceDate.parse(raw) as Any? ?? NSNull()
            try check(try json(actual) == json(sample["iso"]!), "JS Date compatibility \(raw): \(actual) != \(sample["iso"]!)")
        }
        let db = fixture.db, actor = fixture.admin.identity.id
        func rows(_ model: String) throws -> [NativeRecord] { try NativeMCPCatalogValues.rows(model, db: db) }
        func insert(_ model: String, _ seed: [String: Any]) throws { _ = try db.insert(model, values: values(seed, model: db.schema.model(model)), actor: actor) }
        for model in ["Currency", "crm_ProductCategories", "ExchangeRate", "crm_SystemSettings"] {
            for seed in seeds[model]! {
                let key = model == "Currency" ? "code" : model == "crm_SystemSettings" ? "key" : "id"
                if let existing = try db.get(model, key: [key: .text(seed[key] as! String)]) {
                    _ = try db.update(existing, changes: values(seed.filter { $0.key != key && $0.key != "createdAt" }, model: db.schema.model(model)), actor: actor)
                } else { try insert(model, seed) }
            }
        }
        let registry = NativeMCPProducts.handlers.merging(NativeMCPPriceLists.handlers) { _, _ in fatalError("duplicate") }, router = try fixture.router(handlers: registry)
        try check(Set(registry.keys) == Set(reference["tools"] as! [String]), "all thirteen original tools")
        let stateModels = ["crm_Products", "crm_PriceLists", "crm_PriceListRules", "crm_AuditLog"]
        let startCase = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 0
        for (index, sample) in (reference["cases"] as! [[String: Any]]).enumerated() where index >= startCase {
            try db.transaction {
                for account in try rows("crm_Accounts") where account["pricelist_id"] != .null { _ = try db.update(account, changes: ["pricelist_id": .null], actor: actor) }
                for model in ["crm_AuditLog", "crm_PriceListRules", "crm_PriceLists", "crm_Products"] { for row in try rows(model) { try db.remove(row, actor: actor) } }
                for seed in seeds["ExchangeRate"]! { try fixture.change("ExchangeRate", id: seed["id"] as! String, values: values(seed.filter { $0.key != "id" && $0.key != "createdAt" }, model: db.schema.model("ExchangeRate"))) }
                for model in ["crm_Products", "crm_PriceLists", "crm_PriceListRules"] { for seed in seeds[model]! { try insert(model, seed) } }
                for (model, changes) in sample["seedChanges"] as? [String: [[String: Any]]] ?? [:] {
                    for change in changes { try fixture.change(model, id: change["id"] as! String, values: values(change.filter { $0.key != "id" }, model: db.schema.model(model))) }
                }
                for seed in sample["extraRules"] as? [[String: Any]] ?? [] { try insert("crm_PriceListRules", seed) }
                for seed in seeds["crm_Accounts"]! where !(seed["pricelist_id"] is NSNull) { try fixture.change("crm_Accounts", id: seed["id"] as! String, values: ["pricelist_id": .text(seed["pricelist_id"] as! String)]) }
            }
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String, label = "case\(index) \(sample["label"]!) \(input)"
            let before = try Dictionary(uniqueKeysWithValues: stateModels.map { ($0, try db.auditCount($0)) })
            if sample["auditFailure"] as? Bool == true { try sql("CREATE TRIGGER catalog_audit_failure BEFORE INSERT ON crm_AuditLog BEGIN SELECT RAISE(ABORT,'synthetic'); END", fixture: fixture) }
            let result = try await call(router, tool: tool, input: input, rawInputJSON: sample["rawInputJSON"] as? String, header: fixture.header(user)), actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            if sample["auditFailure"] as? Bool == true { try sql("DROP TRIGGER catalog_audit_failure", fixture: fixture) }
            var mapping: [String: String] = [:]
            if let row = actual["data"] as? [String: Any], let expectedRow = expected["data"] as? [String: Any], let id = row["id"] as? String, let wanted = expectedRow["id"] as? String, id != wanted { try check(UUID(uuidString: id) != nil, "generated UUID"); mapping[id] = wanted }
            let expectedState = sample["state"] as! [String: [[String: Any]]], actualAudits = try rows("crm_AuditLog")
            for (actualAudit, expectedAudit) in zip(actualAudits, expectedState["crm_AuditLog"]!) { mapping[actualAudit["id"].string] = expectedAudit["id"] as? String }
            let generated = Set(mapping.values)
            func normalized(_ value: Any, actual: Bool) throws -> Any { try normalize(value, map: actual ? mapping : [:], generated: generated) }
            let left = try json(normalized(actual, actual: true)), right = try json(normalized(expected, actual: false))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "error flag " + label)
            for model in stateModels {
                let actualRows = try rows(model).map { try NativeMCPWire.record($0, schema: db.schema) }
                let actualState = try (normalized(actualRows, actual: true) as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }, wanted = try (normalized(expectedState[model]!, actual: false) as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
                let actualJSON = try json(actualState), expectedJSON = try json(wanted)
                if actualJSON != expectedJSON {
                    try actualJSON.write(to: resources.appendingPathComponent("build/mcp-catalog-actual-state.json")); try expectedJSON.write(to: resources.appendingPathComponent("build/mcp-catalog-expected-state.json"))
                }
                try check(actualJSON == expectedJSON, "all persisted fields / rollback \(model) " + label)
                let change = tool.contains("create_") || tool.contains("update_") || tool.contains("delete_") || tool.contains("archive_") || tool.contains("upsert_")
                if result["isError"] as? Bool == true || !change { try check(try db.auditCount(model) == before[model], "no write audit on read/rejection " + label) }
                else if try db.auditCount(model) > before[model]! {
                    let target = actualRows.first { row in (row["id"] as? String) == (actual["data"] as? [String: Any])?["id"] as? String }
                    if let id = target?["id"] as? String, let row = try db.get(model, key: ["id": .text(id)]) { try check(try db.history(row).first?["actor"] == .text(user), "native audit actor") }
                }
            }
        }
        let manager = "00000000-0000-4000-8000-000000000003"
        let beforeRows = try json(rows("crm_Products").map { try NativeMCPWire.record($0, schema: db.schema) }), beforeAudit = try db.auditCount("crm_Products")
        try sql("CREATE TRIGGER catalog_native_audit_failure BEFORE INSERT ON native_audit WHEN NEW.model='crm_Products' BEGIN SELECT RAISE(ABORT,'synthetic required audit failure'); END", fixture: fixture)
        let failed = try await call(router, tool: "crm_create_product", input: ["name": "Required audit rollback", "type": "PRODUCT", "unit_price": 1, "currency": "JPY"], header: fixture.header(manager))
        try sql("DROP TRIGGER catalog_native_audit_failure", fixture: fixture)
        try check(try payload(failed)["code"] as? String == "INTERNAL_ERROR", "required audit failure maps to internal error")
        try check(try json(rows("crm_Products").map { try NativeMCPWire.record($0, schema: db.schema) }) == beforeRows, "required audit failure rolls back all product fields")
        try check(try db.auditCount("crm_Products") == beforeAudit, "required audit failure leaves no partial history")
        print("Compared \((reference["cases"] as! [Any]).count - startCase) original catalog cases / 13 tools, pricing, dates, rules, permissions, and SQLite state")
    }
}
