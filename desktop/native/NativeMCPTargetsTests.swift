import Foundation

@main enum NativeMCPTargetsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func id(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", value) }
    static func key(_ row: [String: Any]) -> String { row["id"] as? String ?? (row["target_list_id"] as! String) + ":" + (row["target_id"] as! String) }
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
        let response = await router.handle(request), buffer = Buffer(); try await response.writeBody { await buffer.append($0) }
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
            for (field, item) in object {
                if !(item is NSNull), ["updatedAt", "deletedAt"].contains(field) || isNew && field == "created_on" {
                    try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid date " + field); object[field] = "<date>"
                } else { object[field] = try normalized(item, generated: generated) }
            }
            return object
        }
        if let array = value as? [Any] { return try array.map { try normalized($0, generated: generated) } }
        if let text = value as? String, text == generated { return "<new>" }
        return value
    }
    static func main() async {
        do { try await run(); print("Native MCP targets/lists: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-targets-reference.json"))) as! [String: Any]
        let seeds = reference["seeds"] as! [String: [[String: Any]]]
        let groups = [("targets", "crm_Targets"), ("lists", "crm_TargetLists"), ("links", "TargetsToTargetLists")]
        var initial: [String: [String: NativeRecord]] = [:]
        for (group, model) in groups {
            initial[model] = [:]
            for seed in seeds[group]! {
                let row = try fixture.db.insert(model, values: values(seed), actor: fixture.admin.identity.id)
                initial[model]![key(seed)] = row
            }
        }
        func rows(_ model: String) throws -> [NativeRecord] {
            var result: [NativeRecord] = [], offset = 0
            let fields = try fixture.db.schema.model(model).fields.map(\.name)
            while true {
                let page = try fixture.db.page(model, fields: fields, includeDeleted: true, offset: offset, sort: model == "TargetsToTargetLists" ? "target_id" : "id")
                result += page.rows; if page.rows.count < 100 { return result }; offset += page.rows.count
            }
        }
        func recordKey(_ row: NativeRecord) -> String { row.model == "TargetsToTargetLists" ? row["target_list_id"].string + ":" + row["target_id"].string : row["id"].string }
        func reset() throws {
            try fixture.db.transaction {
                for (_, model) in groups {
                    let current = try rows(model), found = Set(current.map(recordKey))
                    for row in current {
                        guard let original = initial[model]![recordKey(row)] else { try fixture.db.remove(row, actor: fixture.admin.identity.id); continue }
                        let immutable = try fixture.db.schema.model(model).primaryKey + ["updatedAt"]
                        let changes = original.values.filter { !immutable.contains($0.key) && row[$0.key] != $0.value }
                        if !changes.isEmpty { _ = try fixture.db.update(row, changes: changes, actor: fixture.admin.identity.id) }
                    }
                    for (key, row) in initial[model]! where !found.contains(key) { _ = try fixture.db.insert(model, values: row.values, actor: fixture.admin.identity.id) }
                }
            }
        }
        let handlers = NativeMCPTargets.handlers.merging(NativeMCPTargetLists.handlers) { _, _ in fatalError("duplicate tool") }
        let router = try fixture.router(handlers: handlers)
        try check(handlers.count == 13 && router.missingTools.count == 110, "thirteen real target/list operations")
        for sample in reference["cases"] as! [[String: Any]] {
            try reset()
            let auditBefore = try Dictionary(uniqueKeysWithValues: groups.map { (_, model) in (model, try fixture.db.auditCount(model)) })
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(input)"
            let result = try await call(router, tool: tool, arguments: input, header: fixture.header(user))
            let actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let generated = ["crm_create_target", "crm_create_target_list"].contains(tool) ? (actual["data"] as? [String: Any])?["id"] as? String : nil
            let expectedGenerated = generated == nil ? nil : id(9999)
            let left = try json(normalized(actual, generated: generated)), right = try json(normalized(expected, generated: expectedGenerated))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            let expectedState = sample["state"] as! [String: [String: Any]], writes = sample["writes"] as! [[String: String]]
            for (group, model) in groups {
                let delta = expectedState[group]!
                var wanted = Dictionary(uniqueKeysWithValues: seeds[group]!.map { (key($0), $0) })
                for row in delta["changed"] as! [[String: Any]] { wanted[key(row)] = row }
                for key in delta["removed"] as! [String] { wanted.removeValue(forKey: key) }
                let stored = try rows(model)
                try check(stored.count == delta["total"] as! Int, "exact stored row count \(model) " + label)
                let actualRows = try stored.map { try normalized(NativeMCPWire.record($0, schema: fixture.db.schema), generated: generated) as! [String: Any] }.sorted { key($0) < key($1) }
                let expectedRows = try wanted.values.map { try normalized($0, generated: expectedGenerated) as! [String: Any] }.sorted { key($0) < key($1) }
                try check(try json(actualRows) == json(expectedRows), "all scalar fields and membership \(model) " + label)
                let expectedWrites = writes.filter { $0["model"] == model }
                try check(try fixture.db.auditCount(model) == auditBefore[model]! + expectedWrites.count, "only actual writes audited \(model) " + label)
                for change in expectedWrites {
                    var rawKey = change["key"]!; if rawKey == id(9999), let generated { rawKey = generated }
                    let identity: [String: SQLValue]
                    if model == "TargetsToTargetLists" { let parts = rawKey.split(separator: ":"); identity = ["target_list_id": .text(String(parts[0])), "target_id": .text(String(parts[1]))] }
                    else { identity = ["id": .text(rawKey)] }
                    let row = NativeRecord(model: model, values: identity, revision: 0)
                    try check(try fixture.db.history(row).first?["actor"] == .text(user), "audit actor matches token " + label)
                }
            }
        }
        try reset()
        let before = try fixture.db.auditCount("TargetsToTargetLists")
        var canceledHandlers = handlers
        canceledHandlers["crm_add_to_target_list"] = { session, arguments in
            try session.withAccess { service in
                let result = try NativeMCPTargetLists.run("crm_add_to_target_list", arguments: arguments, service: service)
                withUnsafeCurrentTask { $0?.cancel() }; return result
            }
        }
        let canceledRouter = try fixture.router(handlers: canceledHandlers)
        let canceled = Task { try await call(canceledRouter, tool: "crm_add_to_target_list", arguments: ["target_list_id": id(304), "target_ids": (1100..<1200).map(id)], header: fixture.header(id(4))) }
        do { _ = try await canceled.value; throw Failure.assertion("canceled batch committed") }
        catch is CancellationError { try check(true, "batch cancellation propagates") }
        try check(try fixture.db.page("TargetsToTargetLists", fields: [], equal: ["target_list_id": .text(id(304))]).total == 0, "all100 membership writes rolled back")
        try check(try fixture.db.auditCount("TargetsToTargetLists") == before, "all100 membership audits rolled back")
        try check(try fixture.db.jobs(events: ["crm/target.saved", "crm/target-list.saved"]).isEmpty, "no extra save jobs beyond source contract")
        print("Compared \((reference["cases"] as! [Any]).count) original target/list cases including complete stored state, counts, memberships and token audit actors")
    }
}
