import Foundation
import SQLite3

@main enum NativeMCPOrdersTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any]) throws -> [String: SQLValue] {
        try object.mapValues { if $0 is NSNull { return .null }; if let number = $0 as? NSNumber { return .integer(number.int64Value) }; if let text = $0 as? String { return .text(text) }; return .text(String(decoding: try json($0), as: UTF8.self)) }
    }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var handle: OpaquePointer?; guard sqlite3_open(db.url.path, &handle) == SQLITE_OK else { throw Failure.assertion("temporary SQLite open") }; defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion(String(cString: sqlite3_errmsg(handle))) }
    }
    actor Buffer { var bytes = Data(); func append(_ value: Data) { bytes.append(value) } }
    static func call(_ router: NativeMCPRequestRouter, _ tool: String, _ arguments: [String: Any], _ header: String) async throws -> [String: Any] {
        let body = try json(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        let response = await router.handle(NativeMCPHTTPRequest(method: "POST", path: "/api/mcp/mcp", headers: ["accept": "application/json, text/event-stream", "content-type": "application/json", "authorization": header], body: body)), buffer = Buffer()
        try await response.writeBody { await buffer.append($0) }
        let line = String(decoding: await buffer.bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!
        return (try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any])["result"] as! [String: Any]
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(((result["content"] as! [[String: Any]])[0]["text"] as! String).utf8)) as! [String: Any] }
    static func normalize(_ value: Any, ids: [String: String]) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<sanitized>" }
            for (key, item) in object {
                if ["updatedAt", "createdAt"].contains(key), !(item is NSNull) { try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid timestamp"); object[key] = "<date>" }
                else { object[key] = try normalize(item, ids: ids) }
            }
            return object
        }
        if let array = value as? [Any] { return try array.map { try normalize($0, ids: ids) } }
        if let text = value as? String { return ids[text] ?? text }; return value
    }
    static let tracked = ["crm_Orders", "crm_OrderLines", "NumberSeries"]
    static func snapshot(_ db: NativeDatabase) throws -> [String: [[String: Any]]] {
        try Dictionary(uniqueKeysWithValues: tracked.map { model in
            let filter: RecordFilter = model == "NumberSeries" ? .equal("scope", .text("order")) : .all
            return (model, try NativeMCPCatalogValues.rows(model, db: db, filter: filter).map { try NativeMCPWire.record($0, schema: db.schema) })
        })
    }
    static func newIDs(_ after: [String: [[String: Any]]], before: [String: [[String: Any]]]) -> [String: String] {
        var result: [String: String] = [:]
        for model in ["crm_Orders", "crm_OrderLines"] {
            let old = Set(before[model]!.map { $0["id"] as! String })
            let rows = after[model, default: []].filter { !old.contains($0["id"] as! String) }.sorted {
                if model == "crm_OrderLines" { return ($0["position"] as! NSNumber).intValue < ($1["position"] as! NSNumber).intValue }
                return ($0["id"] as! String) < ($1["id"] as! String)
            }
            for (i, row) in rows.enumerated() { result[row["id"] as! String] = "<\(model)-\(i)>" }
        }
        return result
    }
    static func differences(_ after: [String: [[String: Any]]], before: [String: [[String: Any]]], ids: [String: String]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for model in tracked {
            let old = try Dictionary(uniqueKeysWithValues: before[model]!.map { ($0["id"] as! String, try json(normalize($0, ids: ids))) })
            let rows = after[model]!, current = Set(rows.map { $0["id"] as! String })
            let changed = try rows.filter { try old[$0["id"] as! String] != json(normalize($0, ids: ids)) }
            result[model] = ["upsert": changed, "deleted": old.keys.filter { !current.contains($0) }.sorted()]
        }
        return result
    }
    static func effect(_ value: [String: Any], ids: [String: String]) throws -> [String: Any] {
        var output: [String: Any] = [:]
        for model in tracked {
            let raw = value[model] as! [String: Any], normalized = try normalize(raw, ids: ids) as! [String: Any]
            output[model] = ["upsert": (normalized["upsert"] as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }, "deleted": (normalized["deleted"] as! [String]).sorted()]
        }
        return output
    }
    static func main() async {
        do { try await run(); print("Native MCP orders: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-orders-reference.json"))) as! [String: Any]
        let seeds = reference["seeds"] as! [String: [[String: Any]]], actor = f.admin.identity.id
        let epoch = NativeAPITokens.date(.text(reference["epoch"] as! String))!
        // The bootstrap administrator is fixture infrastructure, not a source
        // recipient. Source users 1...6 retain their real API-token identities.
        _ = try f.db.update(f.db.get("Users", key: ["id": .text(actor)])!, changes: ["userStatus": .text("INACTIVE")], actor: actor)
        let setupModels = ["Currency", "crm_ProductCategories", "crm_PriceLists", "crm_Products", "crm_PriceListRules", "ExchangeRate", "crm_SystemSettings", "crm_Accounts", "crm_Contacts"]
        func reset() throws {
            try sql(f.db, "DELETE FROM crm_OrderLines; DELETE FROM crm_Orders; DELETE FROM NumberSeries WHERE scope='order'; DELETE FROM crm_AuditLog WHERE entityType='order'; DELETE FROM native_outbox WHERE event IN ('orders.approval_requested','orders.approval_decided');")
            try f.db.transaction {
                for model in setupModels {
                    let key = model == "Currency" ? "code" : model == "crm_SystemSettings" ? "key" : "id"
                    for seed in seeds[model]! {
                        let data = try values(seed), id = data[key]!
                        if let row = try f.db.get(model, key: [key: id]) {
                            let changes = data.filter { $0.key != key && $0.key != "updatedAt" && row[$0.key] != $0.value }
                            if !changes.isEmpty { _ = try f.db.update(row, changes: changes, actor: actor) }
                        } else { _ = try f.db.insert(model, values: data, actor: actor) }
                    }
                }
                for model in ["NumberSeries", "crm_Orders", "crm_OrderLines"] { for seed in seeds[model]! { _ = try f.db.insert(model, values: values(seed), actor: actor) } }
            }
        }
        let router = try f.router(handlers: NativeMCPOrders.makeHandlers(clock: { epoch })), events = ["orders.approval_requested", "orders.approval_decided"]
        try check(router.missingTools.count == 115, "eight real order handlers")
        for sample in reference["cases"] as! [[String: Any]] {
            try reset()
            for setup in sample["setup"] as! [[String: Any]] {
                let model = setup["model"] as! String, key = model == "crm_SystemSettings" ? "key" : "id"
                let row = try f.db.get(model, key: [key: .text(setup["key"] as! String)])!
                _ = try f.db.update(row, changes: values(setup["values"] as! [String: Any]), actor: actor)
            }
            let before = try snapshot(f.db), tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(input)"
            let result = try await call(router, tool, input, f.header(user)), actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let after = try snapshot(f.db), expectedEffects = sample["effects"] as! [String: Any]
            let expectedAfter = Dictionary(uniqueKeysWithValues: tracked.map { ($0, (expectedEffects[$0] as! [String: Any])["upsert"] as! [[String: Any]]) })
            let actualIDs = newIDs(after, before: before), sourceIDs = newIDs(expectedAfter, before: before)
            let left = try json(normalize(actual, ids: actualIDs)), right = try json(normalize(expected, ids: sourceIDs))
            try check(left == right, "response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "error flag " + label)
            let effects = try differences(after, before: before, ids: actualIDs), actualEffects = try json(effect(effects, ids: actualIDs)), sourceEffects = try json(effect(expectedEffects, ids: sourceIDs))
            try check(actualEffects == sourceEffects, "stored order/lines/numbering \(label): \(String(decoding: actualEffects, as: UTF8.self)) != \(String(decoding: sourceEffects, as: UTF8.self))")
            let auditKeys = ["entityType", "entityId", "action", "changes", "userId"]
            let audits = try NativeMCPCatalogValues.rows("crm_AuditLog", db: f.db, equal: ["entityType": .text("order")]).map { row in try Dictionary(uniqueKeysWithValues: auditKeys.map { ($0, try NativeMCPWire.value(row[$0], field: f.db.schema.model("crm_AuditLog").field($0)!)) }) }
            let sourceAudit = (sample["audit"] as! [[String: Any]]).map { row in Dictionary(uniqueKeysWithValues: auditKeys.map { ($0, row[$0] ?? NSNull()) }) }
            try check(try json(normalize(audits, ids: actualIDs)) == json(normalize(sourceAudit, ids: sourceIDs)), "domain audit " + label)
            let notices = try f.db.jobs(events: events), mails = sample["mails"] as! [[String: Any]]
            try check(notices.count == mails.count, "notification count " + label)
            try check(notices.compactMap { $0.payload["recipientEmail"] }.sorted() == mails.map { ($0["to"] as! [String])[0] }.sorted(), "exact notification recipients " + label)
            for notice in notices {
                try check(notice.payload["orderId"] == input["id"] as? String && notice.payload["actorId"] == user, "notification context " + label)
                let current = try f.db.get("crm_Orders", key: ["id": .text(notice.payload["orderId"]!)])!
                try check(notice.payload["number"] == current["number"].string && notice.payload["requestRevision"] == String(current.revision), "current notice revision " + label)
            }
            if let sourceFollowup = sample["followup"] as? [String: Any] {
                let id = (actual["data"] as! [String: Any])["id"] as! String
                let response = try await call(router, "crm_get_order", ["id": id], f.header(user))
                try check(try json(normalize(payload(response), ids: actualIDs)) == json(normalize(payload(sourceFollowup), ids: sourceIDs)), "207-line original read round trip")
            }
        }
        try reset()
        let before = try snapshot(f.db)
        try sql(f.db, "CREATE TRIGGER fail_order_line BEFORE INSERT ON crm_OrderLines BEGIN SELECT RAISE(ABORT,'isolated line failure'); END")
        let failed = try await call(router, "crm_create_order", ["accountId": "00000000-0000-4000-8000-000000000101", "lines": [["productId": "00000000-0000-4000-8000-000000000600", "quantity": 2]]], f.header("00000000-0000-4000-8000-000000000001"))
        try check(try payload(failed)["code"] as? String == "INTERNAL_ERROR", "line failure sanitized")
        try check(try json(normalize(snapshot(f.db), ids: [:])) == json(normalize(before, ids: [:])), "number/order/line rollback together")
        try sql(f.db, "DROP TRIGGER fail_order_line")
        print("Compared \((reference["cases"] as! [Any]).count) original order/service/workflow cases, including monetary snapshots, audit, notifications and 207-line pagination")
    }
}
