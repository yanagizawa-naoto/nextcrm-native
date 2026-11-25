import Foundation

@main enum NativeMCPPeopleTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any]) throws -> [String: SQLValue] {
        try object.mapValues { value in
            if value is NSNull { return .null }
            if let number = value as? NSNumber { return .integer(number.int64Value) }
            if let text = value as? String { return .text(text) }
            return .text(String(decoding: try json(value), as: UTF8.self))
        }
    }
    actor Buffer { var bytes = Data(); func append(_ data: Data) { bytes.append(data) } }
    static func call(_ router: NativeMCPRequestRouter, tool: String, arguments: [String: Any], header: String) async throws -> [String: Any] {
        let request = NativeMCPHTTPRequest(method: "POST", path: "/api/mcp/mcp", headers: ["accept": "application/json, text/event-stream", "content-type": "application/json", "authorization": header], body: try json(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]))
        let response = await router.handle(request), buffer = Buffer()
        try await response.writeBody { await buffer.append($0) }
        let line = String(decoding: await buffer.bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!
        return (try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any])["result"] as! [String: Any]
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] {
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static func normalized(_ value: Any, generated: String?) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<sanitized>" }
            let isNew = generated != nil && object["id"] as? String == generated
            for (key, item) in object {
                if !(item is NSNull), ["updatedAt", "deletedAt"].contains(key) || isNew && ["created_on", "cratedAt", "last_activity"].contains(key) {
                    try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid date " + key)
                    object[key] = "<date>"
                } else { object[key] = try normalized(item, generated: generated) }
            }
            return object
        }
        if let items = value as? [Any] { return try items.map { try normalized($0, generated: generated) } }
        if let text = value as? String, text == generated { return "<new>" }
        return value
    }
    static func main() async {
        do { try await run(); print("Native MCP people: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-people-reference.json"))) as! [String: Any]
        for sample in reference["decimalCases"] as! [[String: String]] {
            try check(try NativeMCPWire.decimal(sample["input"]!) == sample["output"]!, "original Decimal.toJSON " + sample["input"]!)
        }
        for sample in reference["utcCases"] as! [[String: String]] {
            try check(NativeMCPWire.canonicalUTC(sample["input"]!) == sample["output"]!, "original Date.toISOString " + sample["input"]!)
        }
        for invalid in ["1900-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00Z\n"] {
            try check(NativeMCPWire.canonicalUTC(invalid) == nil, "invalid UTC component rejected")
        }
        // Match the source oracle's entire user table, including inactive,
        // banned and unnamed records; remove only this fixture's bootstrap user.
        try fixture.db.remove(fixture.db.get("Users", key: ["id": .text(fixture.admin.identity.id)])!, actor: fixture.admin.identity.id)
        for user in reference["users"] as! [[String: Any]] {
            let data = try values(user), id = data["id"]!
            if let existing = try fixture.db.get("Users", key: ["id": id]) { _ = try fixture.db.update(existing, changes: data.filter { $0.key != "id" }, actor: fixture.admin.identity.id) }
            else { _ = try fixture.db.insert("Users", values: data, actor: fixture.admin.identity.id) }
        }
        var initial: [String: NativeRecord] = [:]
        for seed in reference["seeds"] as! [[String: Any]] {
            let row = try fixture.db.insert("crm_Contacts", values: values(seed), actor: fixture.admin.identity.id); initial[row["id"].string] = row
        }
        for account in reference["emailAccounts"] as! [[String: Any]] { _ = try fixture.db.insert("EmailAccount", values: values(account), actor: fixture.admin.identity.id) }
        let handlers = NativeMCPAccounts.handlers.merging(NativeMCPContacts.handlers) { _, _ in fatalError("duplicate tool") }.merging(NativeMCPUsers.handlers) { _, _ in fatalError("duplicate tool") }.merging(NativeMCPEmailAccounts.handlers) { _, _ in fatalError("duplicate tool") }
        let router = try fixture.router(handlers: handlers)
        try check(router.missingTools.count == 109 && handlers.count == 14, "fourteen real tools; remaining109 explicitly tracked")
        let fields = try fixture.db.schema.model("crm_Contacts").fields.map(\.name)
        for sample in reference["cases"] as! [[String: Any]] {
            try fixture.db.transaction {
                for row in try fixture.db.page("crm_Contacts", fields: fields, includeDeleted: true).rows {
                    guard let original = initial[row["id"].string] else { try fixture.db.remove(row, actor: fixture.admin.identity.id); continue }
                    let changes = original.values.filter { $0.key != "id" && $0.key != "updatedAt" && row[$0.key] != $0.value }
                    if !changes.isEmpty { _ = try fixture.db.update(row, changes: changes, actor: fixture.admin.identity.id) }
                }
            }
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(input)", auditBefore = try fixture.db.auditCount("crm_Contacts")
            let result = try await call(router, tool: tool, arguments: input, header: fixture.header(user))
            let actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let generated = tool == "crm_create_contact" ? (actual["data"] as? [String: Any])?["id"] as? String : nil
            let expectedGenerated = generated == nil ? nil : "00000000-0000-4000-8000-000000009999"
            let left = try json(normalized(actual, generated: generated)), right = try json(normalized(expected, generated: expectedGenerated))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            let rows = try fixture.db.page("crm_Contacts", fields: fields, includeDeleted: true).rows.sorted { $0["id"].string < $1["id"].string }
            var stored: [[String: Any]] = try rows.map { try NativeMCPWire.record($0, schema: fixture.db.schema) }
            stored = try stored.map { try normalized($0, generated: generated) as! [String: Any] }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            let state = try (sample["state"] as! [[String: Any]]).map { try normalized($0, generated: expectedGenerated) as! [String: Any] }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            try check(try json(stored) == json(state), "all persisted contact fields " + label)
            let writes = ["crm_create_contact", "crm_update_contact", "crm_delete_contact"].contains(tool) && result["isError"] as? Bool != true
            try check(try fixture.db.auditCount("crm_Contacts") == auditBefore + (writes ? 1 : 0), "only successful mutations audited " + label)
            if writes {
                let id = generated ?? input["id"] as! String, row = try fixture.db.get("crm_Contacts", key: ["id": .text(id)])!
                try check(try fixture.db.history(row).first?["actor"] == .text(user), "correct token actor " + label)
            }
            if tool == "crm_list_users", let users = actual["data"] as? [[String: Any]] {
                for row in users { try check(row["password"] == nil && row["banReason"] == nil && row["emailVerified"] == nil, "private identity fields excluded") }
            }
            if tool == "crm_list_email_accounts", let accounts = actual["data"] as? [[String: Any]] {
                for row in accounts { try check(row["passwordEncrypted"] == nil && row["userId"] == nil, "mail credentials and nonprojected owner excluded") }
            }
        }
        print("Compared \((reference["cases"] as! [Any]).count) original contact/user cases with SQLite state and permission checks")
    }
}
