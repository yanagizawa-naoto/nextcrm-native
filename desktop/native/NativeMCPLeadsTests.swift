import Foundation
import SQLite3

@main enum NativeMCPLeadsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func id(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
    static func values(_ object: [String: Any]) throws -> [String: SQLValue] {
        try object.mapValues { value in
            if value is NSNull { return .null }; if let number = value as? NSNumber { return .integer(number.int64Value) }; if let text = value as? String { return .text(text) }
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
            for (key, item) in object {
                if !(item is NSNull), ["updatedAt", "deletedAt"].contains(key) || isNew && key == "createdAt" {
                    try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid date " + key); object[key] = "<date>"
                } else { object[key] = try normalized(item, generated: generated) }
            }
            return object
        }
        if let items = value as? [Any] { return try items.map { try normalized($0, generated: generated) } }
        if let text = value as? String, text == generated { return "<new>" }; return value
    }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var c: OpaquePointer?; guard sqlite3_open(db.url.path, &c) == SQLITE_OK else { throw Failure.assertion("test SQLite open") }; defer { sqlite3_close(c) }
        guard sqlite3_exec(c, statement, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion(String(cString: sqlite3_errmsg(c))) }
    }
    static func main() async {
        do { try await sourceCases(); try uiSaveCases(); try await mailCases(); print("Native MCP leads: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func sourceCases() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1])); defer { f.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-leads-reference.json"))) as! [String: Any]
        for (model, items) in reference["options"] as! [String: [[String: Any]]] {
            // Bootstrap generates UUIDs for the name-only seed files. Give the
            // isolated oracle and SQLite fixture the same explicit test IDs.
            for old in try f.db.page(model, fields: []).rows { try f.db.remove(old, actor: f.admin.identity.id) }
            for item in items { _ = try f.db.insert(model, values: values(item), actor: f.admin.identity.id) }
        }
        var initial: [String: NativeRecord] = [:]
        for seed in reference["seeds"] as! [[String: Any]] { let row = try f.db.insert("crm_Leads", values: values(seed), actor: f.admin.identity.id); initial[row["id"].string] = row }
        let router = try f.router(handlers: NativeMCPLeads.handlers)
        try check(router.missingTools.count == 116, "seven real lead operations")
        let projection = try f.db.schema.model("crm_Leads").fields.map(\.name), events = ["crm/lead.saved", NativeMCPLeads.assignedEvent]
        for sample in reference["cases"] as! [[String: Any]] {
            try f.db.transaction {
                for row in try f.db.page("crm_Leads", fields: projection, includeDeleted: true).rows {
                    guard let original = initial[row["id"].string] else { try f.db.remove(row, actor: f.admin.identity.id); continue }
                    let changes = original.values.filter { $0.key != "id" && $0.key != "updatedAt" && row[$0.key] != $0.value }
                    if !changes.isEmpty { _ = try f.db.update(row, changes: changes, actor: f.admin.identity.id) }
                }
            }
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String, label = "\(sample["label"]!) \(user) \(input)"
            let oldJobs = Set(try f.db.jobs(events: events).map(\.id))
            let oldAudit = Set(try f.db.page("crm_AuditLog", fields: [], equal: ["entityType": .text("lead")]).rows.map { $0["id"].string })
            let result = try await call(router, tool: tool, arguments: input, header: f.header(user))
            let actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let generated = tool == "crm_create_lead" ? (actual["data"] as? [String: Any])?["id"] as? String : nil, expectedGenerated = tool == "crm_create_lead" && actual["data"] != nil ? id(9999) : nil
            let left = try json(normalized(actual, generated: generated)), right = try json(normalized(expected, generated: expectedGenerated))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            let rows = try f.db.page("crm_Leads", fields: projection, includeDeleted: true).rows
            let stored = try rows.map { try normalized(NativeMCPWire.record($0, schema: f.db.schema), generated: generated) as! [String: Any] }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            let state = try (sample["state"] as! [[String: Any]]).map { try normalized($0, generated: expectedGenerated) as! [String: Any] }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            try check(try json(stored) == json(state), "all persisted lead fields " + label)
            let jobs = try f.db.jobs(events: events).filter { !oldJobs.contains($0.id) }
            let saved = jobs.filter { $0.event == "crm/lead.saved" }
            let expectedEvents = sample["events"] as! [[String: Any]]
            try check(saved.count == expectedEvents.count, "source saved event count " + label)
            if let saved = saved.first {
                let expectedID = (expectedEvents[0]["data"] as! [String: Any])["record_id"] as! String
                try check(saved.payload["record_id"] == (expectedID == expectedGenerated ? generated : expectedID) && saved.payload["actorID"] == user, "saved event record and actor " + label)
            }
            let notices = jobs.filter { $0.event == NativeMCPLeads.assignedEvent }, mails = sample["mails"] as! [[String: Any]]
            try check(notices.count == mails.count, "source assignee notification decision " + label)
            if let notice = notices.first {
                try check(notice.payload["recipientEmail"] == mails[0]["to"] as? String && notice.payload["recipientId"] == input["assigned_to"] as? String && notice.payload["leadId"] == input["id"] as? String && notice.payload["actorID"] == user, "notification identity and exact recipient " + label)
            }
            let audits = try f.db.page("crm_AuditLog", fields: ["entityType", "entityId", "action", "changes", "userId"], equal: ["entityType": .text("lead")]).rows.filter { !oldAudit.contains($0["id"].string) }
            let auditModel = try f.db.schema.model("crm_AuditLog")
            let actualAudit = try audits.map { row in try Dictionary(uniqueKeysWithValues: ["entityType", "entityId", "action", "changes", "userId"].map { ($0, try NativeMCPWire.value(row[$0], field: auditModel.field($0)!)) }) }
            try check(try json(normalized(actualAudit, generated: generated)) == json(normalized(sample["audit"]!, generated: expectedGenerated)), "source domain audit + field differences " + label)
        }
        // Fail after the lead, notification and domain audit have been staged:
        // the session transaction must roll every effect back together.
        let before = try f.db.get("crm_Leads", key: ["id": .text(id(401))])!, oldJobs = try f.db.jobs(events: events).count, oldAudit = try f.db.auditCount("crm_Leads"), oldDomainAudit = try f.db.page("crm_AuditLog", fields: []).total
        try sql(f.db, "CREATE TRIGGER reject_lead_saved BEFORE INSERT ON native_outbox WHEN NEW.event='crm/lead.saved' BEGIN SELECT RAISE(ABORT,'synthetic lead queue failure'); END")
        let failure = try await call(router, tool: "crm_update_lead", arguments: ["id": id(401), "assigned_to": id(2), "lastName": "must-roll-back"], header: f.header(id(1)))
        try check(try payload(failure)["code"] as? String == "INTERNAL_ERROR", "atomic injected failure sanitized")
        try check(try f.db.get("crm_Leads", key: ["id": .text(id(401))])!.values == before.values && f.db.jobs(events: events).count == oldJobs && f.db.auditCount("crm_Leads") == oldAudit, "lead notification event and audit roll back together")
        try check(try f.db.page("crm_AuditLog", fields: []).total == oldDomainAudit, "domain audit also rolls back")
        try sql(f.db, "DROP TRIGGER reject_lead_saved")
        print("Compared \((reference["cases"] as! [Any]).count) original lead/service cases, including audit, notifications and indexing events")
    }
}
