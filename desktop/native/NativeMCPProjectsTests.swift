import Foundation

@main enum NativeMCPProjectsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func id(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", value) }
    static func key(_ row: [String: Any]) -> String { row["id"] as? String ?? row.keys.filter { $0.hasSuffix("_id") }.sorted().map { row[$0] as! String }.joined(separator: ":") }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try object.reduce(into: [:]) { result, pair in
            let (field, value) = pair
            if value is NSNull { result[field] = .null }
            else if model.field(field)?.type == "BigInt", let text = value as? String { result[field] = .integer(Int64(text)!) }
            else if let number = value as? NSNumber { result[field] = .integer(number.int64Value) }
            else if let text = value as? String { result[field] = .text(text) }
            else { result[field] = .text(String(decoding: try json(value), as: UTF8.self)) }
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
    static func normalized(_ value: Any, generated: String?, defaultDue: Bool) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<sanitized>" }
            let isNew = generated != nil && object["id"] as? String == generated
            for (field, item) in object {
                let variable = ["updatedAt", "deletedAt", "lastEditedAt"].contains(field) || isNew && (field == "createdAt" || field == "dueDateAt" && defaultDue)
                if !(item is NSNull), variable {
                    try check((item as? String).flatMap(NativeMCPWire.canonicalUTC) != nil, "valid variable date " + field); object[field] = "<date>"
                } else {
                    let parsed = try normalized(item, generated: generated, defaultDue: defaultDue)
                    if ["documents", "watchers"].contains(field), let array = parsed as? [[String: Any]] { object[field] = array.sorted { key($0) < key($1) } }
                    else { object[field] = parsed }
                }
            }
            return object
        }
        if let array = value as? [Any] { return try array.map { try normalized($0, generated: generated, defaultDue: defaultDue) } }
        if let text = value as? String, text == generated { return "<new>" }
        return value
    }
    static func main() async {
        do { try await run(); print("Native MCP projects: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-projects-reference.json"))) as! [String: Any]
        let seeds = reference["seeds"] as! [String: [[String: Any]]]
        let groups = ["Boards", "Sections", "Tasks", "tasksComments", "crm_Leads", "crm_Contacts", "crm_Opportunities", "Documents", "DocumentsToAccounts", "DocumentsToLeads", "DocumentsToContacts", "DocumentsToOpportunities", "DocumentsToTasks", "BoardWatchers"]
        var initial: [String: [String: NativeRecord]] = [:]
        for model in groups {
            initial[model] = [:]
            for seed in seeds[model]! {
                let row = try fixture.db.insert(model, values: values(seed, model: fixture.db.schema.model(model)), actor: fixture.admin.identity.id)
                initial[model]![key(seed)] = row
            }
        }
        func rows(_ model: String) throws -> [NativeRecord] {
            var result: [NativeRecord] = [], offset = 0
            let schema = try fixture.db.schema.model(model)
            while true {
                let page = try fixture.db.page(model, fields: schema.fields.map(\.name), includeDeleted: true, offset: offset, sort: schema.primaryKey[0])
                result += page.rows; if page.rows.count < 100 { return result }; offset += page.rows.count
            }
        }
        func recordKey(_ row: NativeRecord) -> String {
            if row.values["id"] != nil { return row["id"].string }
            return row.values.keys.filter { $0.hasSuffix("_id") }.sorted().map { row[$0].string }.joined(separator: ":")
        }
        func reset() throws {
            try fixture.db.transaction {
                for model in groups {
                    let current = try rows(model), found = Set(current.map(recordKey)), schema = try fixture.db.schema.model(model)
                    for row in current {
                        guard let original = initial[model]![recordKey(row)] else { try fixture.db.remove(row, actor: fixture.admin.identity.id); continue }
                        let immutable = schema.primaryKey + schema.fields.filter { $0.attributes.contains("@updatedAt") }.map(\.name)
                        let changes = original.values.filter { !immutable.contains($0.key) && row[$0.key] != $0.value }
                        if !changes.isEmpty { _ = try fixture.db.update(row, changes: changes, actor: fixture.admin.identity.id) }
                    }
                    for (key, row) in initial[model]! where !found.contains(key) { _ = try fixture.db.insert(model, values: row.values, actor: fixture.admin.identity.id) }
                }
            }
        }
        let handlers = NativeMCPProjects.handlers, router = try fixture.router(handlers: handlers)
        try check(handlers.count == 18 && router.missingTools.count == 105, "eighteen original project operations")
        for sample in reference["cases"] as! [[String: Any]] {
            try reset()
            let auditBefore = try Dictionary(uniqueKeysWithValues: groups.map { ($0, try fixture.db.auditCount($0)) })
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(tool) \(input)"
            let result = try await call(router, tool: tool, arguments: input, header: fixture.header(user))
            let actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let created = ["projects_create_board", "projects_create_section", "projects_create_task", "projects_add_comment"].contains(tool)
            let generated = created ? (actual["data"] as? [String: Any])?["id"] as? String : nil, expectedGenerated = generated == nil ? nil : id(9999), defaultDue = input["dueDateAt"] == nil
            let left = try json(normalized(actual, generated: generated, defaultDue: defaultDue)), right = try json(normalized(expected, generated: expectedGenerated, defaultDue: defaultDue))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            let expectedState = sample["state"] as! [String: [String: Any]], writes = sample["writes"] as! [[String: String]]
            for model in groups {
                let delta = expectedState[model]!
                var wanted = Dictionary(uniqueKeysWithValues: seeds[model]!.map { (key($0), $0) })
                for row in delta["changed"] as! [[String: Any]] { wanted[key(row)] = row }
                for key in delta["removed"] as! [String] { wanted.removeValue(forKey: key) }
                let stored = try rows(model)
                try check(stored.count == delta["total"] as! Int, "exact row count \(model) " + label)
                let actualRows = try stored.map { try normalized(NativeMCPWire.record($0, schema: fixture.db.schema), generated: generated, defaultDue: defaultDue) as! [String: Any] }.sorted { key($0) < key($1) }
                let expectedRows = try wanted.values.map { try normalized($0, generated: expectedGenerated, defaultDue: defaultDue) as! [String: Any] }.sorted { key($0) < key($1) }
                let a = try json(actualRows), b = try json(expectedRows)
                if a != b {
                    let first = zip(actualRows, expectedRows).first { (try? json($0.0)) != (try? json($0.1)) }
                    throw Failure.assertion("complete state \(model) \(label); first difference \(String(describing: first))")
                }
                try check(true, "all scalar fields and relations " + model)
                let expectedWrites = writes.filter { $0["model"] == model }
                try check(try fixture.db.auditCount(model) == auditBefore[model]! + expectedWrites.count, "only source writes audited \(model) " + label)
                for change in expectedWrites {
                    var rawKey = change["key"]!; if rawKey == id(9999), let generated { rawKey = generated }
                    let schema = try fixture.db.schema.model(model), parts = rawKey.components(separatedBy: ":")
                    let identity = Dictionary(uniqueKeysWithValues: zip(schema.primaryKey.sorted(), parts).map { ($0, SQLValue.text($1)) })
                    let row = NativeRecord(model: model, values: identity, revision: 0)
                    try check(try fixture.db.history(row).first?["actor"] == .text(user), "audit actor matches token " + label)
                }
            }
        }
        try reset()
        // Removing the only watcher must revoke the very next board read.
        _ = try await call(router, tool: "projects_watch_board", arguments: ["board_id": id(305), "watch": false], header: fixture.header(id(1)))
        let afterUnwatch = try payload(await call(router, tool: "projects_get_board", arguments: ["id": id(305)], header: fixture.header(id(1))))
        try check(afterUnwatch["code"] as? String == "NOT_FOUND", "unwatch revokes watcher-only access")
        try reset()
        let auditBefore = try Dictionary(uniqueKeysWithValues: groups.map { ($0, try fixture.db.auditCount($0)) })
        var canceledHandlers = handlers
        canceledHandlers["projects_delete_task"] = { session, arguments in
            try session.withAccess { service in
                let result = try NativeMCPProjects.run("projects_delete_task", arguments: arguments, service: service)
                withUnsafeCurrentTask { $0?.cancel() }; return result
            }
        }
        let canceledRouter = try fixture.router(handlers: canceledHandlers)
        let canceled = Task { try await call(canceledRouter, tool: "projects_delete_task", arguments: ["id": id(501)], header: fixture.header(id(1))) }
        do { _ = try await canceled.value; throw Failure.assertion("canceled cascade committed") }
        catch is CancellationError { try check(true, "cascade cancellation propagates") }
        for model in groups {
            try check(try rows(model).count == seeds[model]!.count, "cascade rollback all model counts " + model)
            try check(try fixture.db.auditCount(model) == auditBefore[model]!, "cascade rollback audit " + model)
        }
        try check(try fixture.db.jobs(events: ["projects.task_assigned", "projects.task_updated", "projects.task_commented"]).isEmpty, "no extra native UI project notification jobs")
        print("Compared \((reference["cases"] as! [Any]).count) original project cases including complete SQLite state, cascades, board/task/document scopes, ordering and token audit actors")
    }
}
