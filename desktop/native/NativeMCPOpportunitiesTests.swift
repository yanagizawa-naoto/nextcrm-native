import Foundation

@main enum NativeMCPOpportunitiesTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func id(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", value) }
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
            for (key, item) in object {
                let dynamic = ["updatedAt", "deletedAt"].contains(key) || isNew && ["createdAt", "created_on"].contains(key) || key == "stage_entered_at" && item as? String != "2000-01-01T00:00:00.000Z"
                if !(item is NSNull), dynamic {
                    try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid date " + key); object[key] = "<date>"
                } else { object[key] = try normalized(item, generated: generated) }
            }
            return object
        }
        if let array = value as? [Any] { return try array.map { try normalized($0, generated: generated) } }
        if let text = value as? String, text == generated { return "<new>" }
        return value
    }
    static func main() async {
        do { try await run(); print("Native MCP opportunities: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-opportunities-reference.json"))) as! [String: Any]
        for (key, model) in [("stages", "crm_Opportunities_Sales_Stages"), ("types", "crm_Opportunities_Type"), ("contacts", "crm_Contacts")] {
            while true {
                let old = try fixture.db.page(model, fields: [], includeDeleted: true).rows
                if old.isEmpty { break }; for row in old { try fixture.db.remove(row, actor: fixture.admin.identity.id) }
            }
            for seed in reference[key] as! [[String: Any]] { _ = try fixture.db.insert(model, values: values(seed), actor: fixture.admin.identity.id) }
        }
        var initial: [String: NativeRecord] = [:]
        for seed in reference["seeds"] as! [[String: Any]] {
            let row = try fixture.db.insert("crm_Opportunities", values: values(seed), actor: fixture.admin.identity.id); initial[row["id"].string] = row
        }
        let router = try fixture.router(handlers: NativeMCPOpportunities.handlers)
        try check(NativeMCPOpportunities.names.count == 7 && router.missingTools.count == 116, "seven real opportunity operations")
        let model = "crm_Opportunities", fields = try fixture.db.schema.model(model).fields.map(\.name)
        let businessFields = ["entityType", "entityId", "action", "changes", "userId"]
        let eventNames = ["crm/opportunity.stage-changed", "crm/opportunity.saved"]
        func businessRows() throws -> [NativeRecord] { try fixture.db.page("crm_AuditLog", fields: businessFields, sort: "createdAt", descending: true).rows }
        for sample in reference["cases"] as! [[String: Any]] {
            try fixture.db.transaction {
                for row in try fixture.db.page(model, fields: fields, includeDeleted: true).rows {
                    guard let original = initial[row["id"].string] else { try fixture.db.remove(row, actor: fixture.admin.identity.id); continue }
                    let changes = original.values.filter { $0.key != "id" && $0.key != "updatedAt" && row[$0.key] != $0.value }
                    if !changes.isEmpty { _ = try fixture.db.update(row, changes: changes, actor: fixture.admin.identity.id) }
                }
            }
            let beforeBusiness = Set(try businessRows().map { $0["id"].string }), beforeJobs = Set(try fixture.db.jobs(events: eventNames).map(\.id))
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
            let label = "\(sample["label"]!) \(user) \(input)"
            let result = try await call(router, tool: tool, arguments: input, header: fixture.header(user))
            let actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            let generated = tool == "crm_create_opportunity" ? (actual["data"] as? [String: Any])?["id"] as? String : nil
            let expectedGenerated = generated == nil ? nil : id(9999)
            let left = try json(normalized(actual, generated: generated)), right = try json(normalized(expected, generated: expectedGenerated))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            if tool == "crm_list_opportunity_options" {
                let data = actual["data"] as! [String: Any]; try check((data["stages"] as! [Any]).count == 108, "all options beyond100 rows")
            }
            let rows = try fixture.db.page(model, fields: fields, includeDeleted: true).rows
            let stored = try rows.map { try normalized(NativeMCPWire.record($0, schema: fixture.db.schema), generated: generated) as! [String: Any] }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            let state = try (sample["state"] as! [[String: Any]]).map { try normalized($0, generated: expectedGenerated) as! [String: Any] }.sorted { ($0["id"] as! String) < ($1["id"] as! String) }
            try check(try json(stored) == json(state), "all persisted opportunity fields " + label)
            let schema = try fixture.db.schema.model("crm_AuditLog")
            let business = try businessRows().filter { !beforeBusiness.contains($0["id"].string) }.map { row in
                try Dictionary(uniqueKeysWithValues: businessFields.map { ($0, try NativeMCPWire.value(row[$0], field: schema.field($0)!)) })
            }
            try check(try json(normalized(business, generated: generated)) == json(normalized(sample["audits"]!, generated: expectedGenerated)), "original business audit projection and changes " + label)
            let jobs = try fixture.db.jobs(events: eventNames).filter { !beforeJobs.contains($0.id) }.reversed()
            let events: [[String: Any]] = jobs.map { job in ["name": job.event, "data": job.payload.filter { $0.key != "actorID" }] }
            try check(try json(normalized(events, generated: generated)) == json(normalized(sample["events"]!, generated: expectedGenerated)), "exact stage/saved event sequence " + label)
            for job in jobs where job.event == "crm/opportunity.saved" { try check(job.payload["actorID"] == user, "native worker retains token actor") }
        }
        let auditCount = try fixture.db.auditCount("crm_AuditLog"), opportunityAuditCount = try fixture.db.auditCount(model), jobs = Set(try fixture.db.jobs(events: eventNames).map(\.id))
        var cancelHandlers = NativeMCPOpportunities.handlers
        cancelHandlers["crm_create_opportunity"] = { session, arguments in
            try session.withAccess { service in
                let result = try NativeMCPOpportunities.run("crm_create_opportunity", arguments: arguments, service: service)
                withUnsafeCurrentTask { $0?.cancel() }; return result
            }
        }
        let canceledRouter = try fixture.router(handlers: cancelHandlers)
        let canceled = Task { try await call(canceledRouter, tool: "crm_create_opportunity", arguments: ["name": "must-roll-back", "sales_stage_id": id(501)], header: fixture.header(id(1))) }
        do { _ = try await canceled.value; throw Failure.assertion("canceled workflow committed") }
        catch is CancellationError { try check(true, "workflow cancellation propagates") }
        try check(try fixture.db.page(model, fields: [], equal: ["name": .text("must-roll-back")]).total == 0, "canceled opportunity rolled back")
        try check(try fixture.db.auditCount("crm_AuditLog") == auditCount && fixture.db.auditCount(model) == opportunityAuditCount, "both audit histories rolled back")
        try check(try Set(fixture.db.jobs(events: eventNames).map(\.id)) == jobs, "stage and saved outbox effects rolled back")
        print("Compared \((reference["cases"] as! [Any]).count) original opportunity cases, including stage gate, return snapshot, stored state, business audit and outbox events")
    }
}
