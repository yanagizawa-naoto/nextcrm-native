import Foundation
import SQLite3

@main enum NativeMCPCampaignsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ label: String) throws { guard condition else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try Dictionary(uniqueKeysWithValues: object.map { key, value in
            let stored: SQLValue
            if model.field(key)?.type == "Json" { stored = .text(String(decoding: try json(value), as: UTF8.self)) }
            else if value is NSNull { stored = .null }
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
    static func normalize(_ value: Any, map: [String: String], generated: Set<String>, scheduled: String?) throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<internal>" }
            let id = (object["id"] as? String).map { map[$0] ?? $0 }
            for (key, item) in object {
                if key == "content_json" { continue }
                if ["updatedAt", "deletedAt"].contains(key) || key == "created_on" && id.map(generated.contains) == true || key == "scheduled_at" && id == scheduled && scheduled != nil {
                    if !(item is NSNull) { try check((item as? String).flatMap { NativeAPITokens.date(.text($0)) } != nil, "valid dynamic date"); object[key] = "<date>" }
                } else { object[key] = try normalize(item, map: map, generated: generated, scheduled: scheduled) }
            }; return object
        }
        if let array = value as? [Any] { return try array.map { try normalize($0, map: map, generated: generated, scheduled: scheduled) } }
        if let text = value as? String { return map[text] ?? text }; return value
    }
    static func rows(_ model: String, db: NativeDatabase) throws -> [NativeRecord] {
        let fields = try db.schema.model(model).fields.map(\.name); var result: [NativeRecord] = [], offset = 0
        while true { let page = try db.page(model, fields: fields, includeDeleted: true, offset: offset, insertionOrderForTies: true); result += page.rows; if page.rows.count < 100 { return result }; offset += page.rows.count }
    }
    static func sql(_ command: String, fixture: NativeMCPAccountsFixture) throws {
        var handle: OpaquePointer?; guard sqlite3_open(fixture.root.appendingPathComponent("crm.sqlite").path, &handle) == SQLITE_OK else { throw Failure.assertion("fixture SQL open") }; defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion("fixture SQL " + String(cString: sqlite3_errmsg(handle))) }
    }
    final class EventProbe {
        let lock = NSLock(); var values: [NativeMCPCampaigns.Event] = []; var failure = false
        func reset(failure: Bool) { lock.lock(); defer { lock.unlock() }; self.failure = failure; values = [] }
        func emit(_ event: NativeMCPCampaigns.Event, service: CRMService, now: Date) throws {
            lock.lock(); values.append(event); let fail = failure; lock.unlock()
            try NativeMCPCampaigns.persist(event, service: service, now: now)
            if fail { throw NativeMCPFailure.internalError }
        }
    }
    static func main() async { do { try await run(); print("Native MCP campaigns: \(checks) checks passed; fake transport only") } catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1])); defer { fixture.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-campaigns-reference.json"))) as! [String: Any], seeds = reference["seeds"] as! [String: [[String: Any]]]
        let db = fixture.db, actor = fixture.admin.identity.id, probe = EventProbe()
        let registry = NativeMCPCampaigns.handlers(events: probe.emit, clock: { fixture.now }), router = try fixture.router(handlers: registry)
        try check(Set(registry.keys) == Set(reference["tools"] as! [String]), "all nineteen original campaign tools")
        let models = ["crm_campaign_templates", "crm_campaigns", "crm_TargetLists", "crm_Targets", "crm_campaign_steps", "CampaignToTargetLists", "crm_campaign_sends"]
        func insert(_ model: String, _ seed: [String: Any]) throws { _ = try db.insert(model, values: values(seed, model: db.schema.model(model)), actor: actor) }
        let startCase = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 0
        for (index, sample) in (reference["cases"] as! [[String: Any]]).enumerated() where index >= startCase {
            try sql("DELETE FROM native_outbox WHERE event LIKE 'campaigns/%'; DELETE FROM native_metadata WHERE key LIKE 'campaign.run.%';", fixture: fixture)
            try db.transaction {
                for model in models.reversed() { for row in try rows(model, db: db) { try db.remove(row, actor: actor) } }
                for model in models { for seed in seeds[model]! { try insert(model, seed) } }
                for (model, extra) in sample["extraSeeds"] as? [String: [[String: Any]]] ?? [:] { for seed in extra { try insert(model, seed) } }
                for (model, changes) in sample["seedChanges"] as? [String: [[String: Any]]] ?? [:] { for change in changes { try fixture.change(model, id: change["id"] as! String, values: values(change.filter { $0.key != "id" }, model: db.schema.model(model))) } }
            }
            let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String, failing = sample["eventFailure"] as? Bool == true, label = "case\(index) \(sample["label"]!) \(user) \(input)"
            let before = try Dictionary(uniqueKeysWithValues: models.map { ($0, try db.auditCount($0)) }); probe.reset(failure: failing)
            let result = try await call(router, tool: tool, input: input, rawInputJSON: sample["rawInputJSON"] as? String, header: fixture.header(user)), actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            var mapping: [String: String] = [:]
            if let row = actual["data"] as? [String: Any], let expectedRow = expected["data"] as? [String: Any], let id = row["id"] as? String, let wanted = expectedRow["id"] as? String, id != wanted { try check(UUID(uuidString: id) != nil, "generated UUID"); mapping[id] = wanted }
            let generated = Set(mapping.values), scheduled = tool == "campaigns_send" ? input["id"] as? String : nil
            func normalized(_ value: Any, actual: Bool) throws -> Any { try normalize(value, map: actual ? mapping : [:], generated: generated, scheduled: scheduled) }
            let left = try json(normalized(actual, actual: true)), right = try json(normalized(expected, actual: false))
            try check(left == right, "source response \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "source error flag " + label)
            let expectedState = sample[failing ? "nativeRollbackState" : "state"] as! [String: [[String: Any]]]
            for model in models {
                let actualRows = try rows(model, db: db).map { try NativeMCPWire.record($0, schema: db.schema) }
                func sort(_ input: [[String: Any]]) -> [[String: Any]] { input.sorted { (($0["id"] ?? $0["campaign_id"]) as! String, ($0["target_list_id"] as? String) ?? "") < (($1["id"] ?? $1["campaign_id"]) as! String, ($1["target_list_id"] as? String) ?? "") } }
                let actualState = try json(sort(normalized(actualRows, actual: true) as! [[String: Any]])), expectedStateJSON = try json(sort(normalized(expectedState[model]!, actual: false) as! [[String: Any]]))
                if actualState != expectedStateJSON { try actualState.write(to: resources.appendingPathComponent("build/mcp-campaigns-actual-state.json")); try expectedStateJSON.write(to: resources.appendingPathComponent("build/mcp-campaigns-expected-state.json")) }
                try check(actualState == expectedStateJSON, "persisted full state / rollback \(model) " + label)
                if result["isError"] as? Bool == true || tool.contains("list") && !tool.contains("target_list") || ["campaigns_get", "campaigns_get_template", "campaigns_get_stats"].contains(tool) { try check(try db.auditCount(model) == before[model], "read/error no audit effects " + label) }
            }
            let actualEvents = probe.values.map { ["name": $0.name, "data": ["campaignId": $0.campaignID]] as [String: Any] }, expectedEvents = sample["events"] as! [[String: Any]]
            try check(try json(actualEvents) == json(expectedEvents), "logical original event intents " + label)
            let jobs = try db.jobs(events: [CampaignWorkflow.sendEvent])
            try check(jobs.count == (!failing && expectedEvents.contains { $0["name"] as? String == CampaignWorkflow.sendEvent } ? 1 : 0), "one durable send intent / rollback " + label)
            if let event = probe.values.first {
                let token = try db.metadata(CampaignWorkflow.runKey(event.campaignID))
                try check(failing ? token == nil : token.flatMap(UUID.init(uuidString:)) != nil, "cancellation generation atomicity " + label)
                if let job = jobs.first { try check(job.payload["actorId"] == user && job.payload["campaignId"] == event.campaignID && job.payload["runToken"] == token && job.status == "pending", "existing dispatch worker-compatible queue payload") }
            }
        }
        try await delivery(resources)
        print("Compared \((reference["cases"] as! [Any]).count - startCase) original campaign cases / 19 tools, complete SQLite state and native queue/mail integration")
    }
    static func delivery(_ resources: URL) async throws {
        let f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let user = "00000000-0000-4000-8000-000000000003", db = f.db, router = try f.router(handlers: NativeMCPCampaigns.handlers(events: NativeMCPCampaigns.persist, clock: { f.now }))
        func put(_ model: String, _ values: [String: SQLValue]) throws -> NativeRecord { try db.insert(model, values: values, actor: user) }
        let template = try put("crm_campaign_templates", ["name": .text("日本語本文"), "content_html": .text("<p>{{first_name}}様、日本語のご案内です。</p>"), "content_json": .text("null"), "created_by": .text(user)])
        let campaign = try put("crm_campaigns", ["v": .integer(0), "name": .text("MCP配信"), "status": .text("draft"), "created_by": .text(user)])
        _ = try put("crm_campaign_steps", ["campaign_id": campaign["id"], "order": .integer(0), "template_id": template["id"], "subject": .text("{{first_name}}様へ")])
        let target = try put("crm_Targets", ["last_name": .text("検証"), "first_name": .text("山田"), "email": .text("recipient@example.invalid"), "created_by": .text(user)])
        let list = try put("crm_TargetLists", ["name": .text("検証対象"), "created_by": .text(user)])
        _ = try put("TargetsToTargetLists", ["target_id": target["id"], "target_list_id": list["id"]])
        let linked = try await call(router, tool: "campaigns_assign_target_list", input: ["campaign_id": campaign["id"].string, "target_list_id": list["id"].string], header: f.header(user))
        try check(linked["isError"] as? Bool != true, "MCP audience linked")
        // Two callers must not publish two starts. The same SQLite transaction
        // protects the status transition, generation and outbox enqueue.
        async let first = call(router, tool: "campaigns_send", input: ["id": campaign["id"].string], header: f.header(user))
        async let second = call(router, tool: "campaigns_send", input: ["id": campaign["id"].string], header: f.header(user))
        let starts = try await [first, second]
        try check(starts.filter { $0["isError"] as? Bool != true }.count == 1, "concurrent sends have one winner")
        try check(try db.jobs(events: [CampaignWorkflow.sendEvent]).count == 1, "concurrent sends have one durable fanout")
        let dispatch = CampaignDispatchWorker(db: db, clock: { f.now })
        try check(try await dispatch.runNext(), "existing dispatch consumes MCP queue")
        let send = try rows("crm_campaign_sends", db: db).first!
        try check(send["target_id"] == target["id"] && send["status"] == .text("queued"), "existing fanout materializes intended recipient")
        let pause = try await call(router, tool: "campaigns_pause", input: ["id": campaign["id"].string], header: f.header(user))
        try check(pause["isError"] as? Bool != true, "MCP pauses started fanout")
        final class Transport { var bodies: [Data] = []; var keys: [String] = []; var preflights = 0 }
        let transport = Transport(), provider = UUID().uuidString.lowercased()
        let worker = CampaignMailWorker(db: db, account: { InvoiceMailAccount(from: "sender@example.invalid", apiKey: "isolated-fake") }, configuration: { try CampaignMailConfiguration(publicURL: "https://crm.example.invalid") }, endpointReady: { _, _ in transport.preflights += 1 }, request: { request, url in
            transport.bodies.append(try Data(contentsOf: url)); transport.keys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            return (try json(["id": provider]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { f.now })
        try check(try await worker.runNext(), "paused recipient job acknowledged")
        try check(transport.bodies.isEmpty, "pause fence prevents provider request")
        let resumed = try await call(router, tool: "campaigns_resume", input: ["id": campaign["id"].string], header: f.header(user))
        try check(resumed["isError"] as? Bool != true, "MCP resumes with a new generation")
        try check(try await dispatch.runNext(), "resume fanout consumed")
        try check(try await worker.runNext(), "real mail worker reaches fake transport")
        try check(transport.bodies.count == 1 && transport.keys == ["campaign-send/" + send["id"].string], "stable recipient idempotency key across pause/resume")
        let body = try JSONSerialization.jsonObject(with: transport.bodies[0]) as! [String: Any]
        try check(body["subject"] as? String == "山田様へ" && (body["html"] as? String)?.contains("日本語") == true && (body["headers"] as? [String: String])?["List-Unsubscribe"]?.contains("/api/campaigns/unsubscribe") == true, "merge fields / HTML / unsubscribe preserved through API queue")
        try check(try db.get("crm_campaign_sends", key: ["id": send["id"]])?["resend_message_id"] == .text(provider), "provider receipt persisted")
        try check(try db.get("crm_campaigns", key: ["id": campaign["id"]])?["status"] == .text("sent"), "initial campaign completes through existing worker")
        let stats = try payload(await call(router, tool: "campaigns_get_stats", input: ["id": campaign["id"].string], header: f.header(user)))["data"] as! [String: Any]
        try check(stats["total"] as? Int == 1 && stats["sent"] as? Int == 1, "MCP stats observe real worker state")
        let fresh = try put("crm_campaigns", ["v": .integer(0), "name": .text("Atomic start"), "status": .text("draft"), "created_by": .text(user)])
        _ = try put("crm_campaign_steps", ["campaign_id": fresh["id"], "order": .integer(0), "template_id": template["id"], "subject": .text("atomic")])
        let audit = try db.auditCount("crm_campaigns")
        try sql("CREATE TRIGGER mcp_campaign_queue_failure BEFORE INSERT ON native_outbox WHEN NEW.event='campaigns/send-now' BEGIN SELECT RAISE(ABORT,'synthetic queue failure'); END", fixture: f)
        let failed = try await call(router, tool: "campaigns_send", input: ["id": fresh["id"].string], header: f.header(user))
        try sql("DROP TRIGGER mcp_campaign_queue_failure", fixture: f)
        try check(try payload(failed)["code"] as? String == "INTERNAL_ERROR", "queue failure returned")
        try check(try db.get("crm_campaigns", key: ["id": fresh["id"]])?.values == fresh.values && db.auditCount("crm_campaigns") == audit && db.metadata(CampaignWorkflow.runKey(fresh["id"].string)) == nil, "failed enqueue rolls back state, required audit and generation")
    }
}
