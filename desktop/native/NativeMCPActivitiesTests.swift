import Foundation
import SQLite3

@main enum NativeMCPActivitiesTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ label: String) throws { guard condition else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try Dictionary(uniqueKeysWithValues: object.map { key, value in
            let stored: SQLValue
            if value is NSNull { stored = .null }
            else if model.field(key)?.type == "Decimal", let text = value as? String, var decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) { stored = .text(NSDecimalString(&decimal, Locale(identifier: "en_US_POSIX"))) }
            else if let number = value as? NSNumber { stored = model.field(key)?.type == "Decimal" ? .text(number.stringValue) : .integer(number.int64Value) }
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
        do { try await run(); print("Native MCP activities: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var c: OpaquePointer?; guard sqlite3_open(db.url.path, &c) == SQLITE_OK else { throw Failure.assertion("test SQLite open") }; defer { sqlite3_close(c) }
        guard sqlite3_exec(c, statement, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion(String(cString: sqlite3_errmsg(c))) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-activities-reference.json"))) as! [String: Any]
        for (model, seeds) in reference["parents"] as! [String: [[String: Any]]] {
            for seed in seeds { _ = try fixture.db.insert(model, values: values(seed, model: fixture.db.schema.model(model)), actor: fixture.admin.identity.id) }
        }
        let router = try fixture.router(handlers: NativeMCPActivities.handlers)
        try check(NativeMCPActivities.names == Set(reference["tools"] as! [String]), "five original tools implemented")
        try check(router.missingTools.count == 118, "partial registry retains full-scope gate")
        for sample in reference["cases"] as! [[String: Any]] {
            try fixture.db.transaction {
                for model in ["crm_ActivityLinks", "crm_Activities"] { for row in try all(model, db: fixture.db) { try fixture.db.remove(row, actor: fixture.admin.identity.id) } }
                for (key, model) in [("seeds", "crm_Activities"), ("linkSeeds", "crm_ActivityLinks")] {
                    for seed in reference[key] as! [[String: Any]] { _ = try fixture.db.insert(model, values: values(seed, model: fixture.db.schema.model(model)), actor: fixture.admin.identity.id) }
                }
            }
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(input)"
            let activityAudit = try fixture.db.auditCount("crm_Activities"), linkAudit = try fixture.db.auditCount("crm_ActivityLinks")
            let previousJobs = Set(try fixture.db.jobs(events: ["calendar/outbound"]).map(\.id))
            if sample["rejectEvents"] as? Bool == true { try sql(fixture.db, "CREATE TRIGGER reject_activity_outbound BEFORE INSERT ON native_outbox WHEN NEW.event='calendar/outbound' BEGIN SELECT RAISE(ABORT,'synthetic event outage'); END") }
            let result = try await call(router, tool: tool, input: input, header: fixture.header(user)), actual = try payload(result)
            if sample["rejectEvents"] as? Bool == true { try sql(fixture.db, "DROP TRIGGER reject_activity_outbound") }
            let expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            var mapping: [String: String] = [:], generated = Set<String>()
            if tool == "crm_create_activity", let row = actual["data"] as? [String: Any], let expectedRow = expected["data"] as? [String: Any] {
                try check(UUID(uuidString: row["id"] as! String) != nil, "generated activity UUID")
                mapping[row["id"] as! String] = expectedRow["id"] as? String
                let related = row["links"] as! [[String: Any]], expectedRelated = expectedRow["links"] as! [[String: Any]]
                try check(related.count == expectedRelated.count, "complete link count")
                for (link, expectedLink) in zip(related, expectedRelated) {
                    try check(UUID(uuidString: link["id"] as! String) != nil, "generated link UUID")
                    mapping[link["id"] as! String] = expectedLink["id"] as? String
                }
                generated = Set(mapping.values)
            }
            func normalized(_ value: Any, actual: Bool) throws -> Any { try normalize(value, map: actual ? mapping : [:], generated: generated, implicitStart: false) }
            let left = try json(normalized(actual, actual: true)), right = try json(normalized(expected, actual: false))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "error flag " + label)
            for (key, model) in [("activities", "crm_Activities"), ("links", "crm_ActivityLinks")] {
                let actualRows = try all(model, db: fixture.db).map { try NativeMCPWire.record($0, schema: fixture.db.schema) }
                let actualState = try (normalized(actualRows, actual: true) as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
                let expectedState = try (normalized(sample[key]!, actual: false) as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) }
                try check(try json(actualState) == json(expectedState), "all persisted \(key) fields / rollback " + label)
            }
            let jobs = try fixture.db.jobs(events: ["calendar/outbound"]).filter { !previousJobs.contains($0.id) }
            let actualEvents: [[String: Any]] = jobs.map { ["name": "crm/calendar.outbound-sync", "data": ["activityId": mapping[$0.payload["activity_id"]!] ?? $0.payload["activity_id"]!, "action": $0.payload["operation"]!]] }
            try check(try json(actualEvents) == json(sample["events"]!), "original calendar event mapped to native worker " + label)
            let writes = ["crm_create_activity", "crm_update_activity", "crm_delete_activity"].contains(tool) && result["isError"] as? Bool != true
            try check(try fixture.db.auditCount("crm_Activities") == activityAudit + (writes ? 1 : 0), "activity audit atomicity " + label)
            let createdLinks = writes && tool == "crm_create_activity" ? (input["links"] as? [Any])?.count ?? 0 : 0
            try check(try fixture.db.auditCount("crm_ActivityLinks") == linkAudit + createdLinks, "link audit atomicity " + label)
            if writes {
                let id = tool == "crm_create_activity" ? (actual["data"] as! [String: Any])["id"] as! String : input["id"] as! String
                let row = try fixture.db.get("crm_Activities", key: ["id": .text(id)])!
                try check(try fixture.db.history(row).first?["actor"] == .text(user), "audit attributed to current token actor")
            }
        }
        let actor = "00000000-0000-4000-8000-000000000001"
        let session = try NativeAPITokens.prepareSession(fixture.credentials[actor]!.raw, db: fixture.db, clock: { fixture.now })
        let beforeRows = try all("crm_Activities", db: fixture.db).count, beforeLinks = try all("crm_ActivityLinks", db: fixture.db).count, beforeJobs = try fixture.db.jobs(events: ["calendar/outbound"]).count, beforeAudit = try fixture.db.auditCount("crm_Activities")
        let arguments: [String: Any] = ["type": "meeting", "title": "rollback", "date": "2026-11-01T00:00:00Z", "status": "scheduled", "links": [["entityType": "account", "entityId": "00000000-0000-4000-8000-000000000101"]]]
        let cancelled = Task {
            try session.withAccess { service in
                _ = try NativeMCPActivities.run("crm_create_activity", arguments: arguments, service: service)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await cancelled.value; throw Failure.assertion("cancelled mutation committed") } catch is CancellationError { checks += 1 }
        try check(try all("crm_Activities", db: fixture.db).count == beforeRows && all("crm_ActivityLinks", db: fixture.db).count == beforeLinks && fixture.db.jobs(events: ["calendar/outbound"]).count == beforeJobs && fixture.db.auditCount("crm_Activities") == beforeAudit, "cancellation rolls back activity, links, jobs and audit together")
        print("Compared \((reference["cases"] as! [Any]).count) original activity cases, full scalar/link state, ownership, dates, native calendar events and cancellation rollback")
    }
}
