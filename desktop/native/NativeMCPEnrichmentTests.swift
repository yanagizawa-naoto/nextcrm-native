import Foundation
import SQLite3

@main enum NativeMCPEnrichmentTests {
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
    static func normalize(_ value: Any, map: [String: String], key: String = "") throws -> Any {
        if ["fields", "enrichments"].contains(key) { return value }
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<internal>" }
            return try object.mapValues { $0 }.reduce(into: [String: Any]()) { result, item in
                result[item.key] = try normalize(item.value, map: map, key: item.key)
            }
        }
        if let array = value as? [Any] { return try array.map { try normalize($0, map: map, key: key) } }
        if let text = value as? String {
            if ["createdAt", "updatedAt", "created_on", "deletedAt", "enrichedAt"].contains(key) { try check(NativeAPITokens.date(.text(text)) != nil, "date parse"); return "<date>" }
            return ["id", "contactId", "targetId", "enrichmentId", "contactIds", "targetIds"].contains(key) ? map[text] ?? text : text
        }; return value
    }
    static func rows(_ model: String, db: NativeDatabase) throws -> [NativeRecord] {
        let fields = try db.schema.model(model).fields.map(\.name); var result: [NativeRecord] = [], offset = 0
        while true { let page = try db.page(model, fields: fields, includeDeleted: true, offset: offset, insertionOrderForTies: true); result += page.rows; if page.rows.count < 100 { return result }; offset += page.rows.count }
    }
    static func sql(_ command: String, fixture: NativeMCPAccountsFixture) throws {
        var handle: OpaquePointer?; guard sqlite3_open(fixture.root.appendingPathComponent("crm.sqlite").path, &handle) == SQLITE_OK else { throw Failure.assertion("fixture SQL open") }; defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion("fixture SQL " + String(cString: sqlite3_errmsg(handle))) }
    }
    final class Probe {
        let store = NativeAIQAServices()
        var environment: [String: String] = [:], events: [NativeMCPEnrichment.Event] = [], failure = false, calls = 0
        var env: NativeAIEnvironment { .init(lookup: { [unowned self] in self.environment[$0] }) }
        func emit(_ event: NativeMCPEnrichment.Event, service: CRMService, store: NativeAISecretStore, environment: NativeAIEnvironment, now: Date) throws {
            events.append(event); try NativeMCPEnrichment.persist(event, service: service, store: store, environment: environment, now: now)
            if failure { throw NativeMCPFailure.internalError }
        }
    }
    static let allKeys = ["FIRECRAWL_API_KEY": "fixture-firecrawl", "OPENAI_API_KEY": "fixture-openai", "ANTHROPIC_API_KEY": "fixture-anthropic", "E2B_API_KEY": "fixture-e2b"]
    static let models = ["crm_Contacts", "crm_Targets", "crm_Contact_Enrichment", "crm_Target_Enrichment", "crm_Target_Contact"]
    static func uid(_ number: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", number) }
    static func service(_ fixture: NativeMCPAccountsFixture, id: String = uid(1)) throws -> CRMService {
        let user = try fixture.db.get("Users", key: ["id": .text(id)])!
        return .init(db: fixture.db, identity: .init(id: id, role: user["role"].string, partnerAccountID: nil))
    }
    static func main() async { do { try await run(); print("Native MCP enrichment: \(checks) checks passed; fake transport only") } catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-enrichment-reference.json"))) as! [String: Any]
        let seeds = reference["seeds"] as! [String: [[String: Any]]], db = f.db, actor = f.admin.identity.id, probe = Probe()
        let handlers = NativeMCPEnrichment.handlers(store: { _ in probe.store }, environment: probe.env, events: probe.emit, clock: { f.now }), router = try f.router(handlers: handlers)
        try check(Set(handlers.keys) == Set(reference["tools"] as! [String]), "all four original API tools")
        let start = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 0
        for (index, sample) in (reference["cases"] as! [[String: Any]]).enumerated() where index >= start {
            try sql("DELETE FROM native_outbox WHERE event LIKE 'enrich/%' OR event = 'crm/contact.saved';", fixture: f)
            try db.transaction {
                for model in models.reversed() { for row in try rows(model, db: db) { try db.remove(row, actor: actor) } }
                for model in models { for seed in seeds[model]! { _ = try db.insert(model, values: values(seed, model: db.schema.model(model)), actor: actor) } }
                for (model, extra) in sample["extraSeeds"] as? [String: [[String: Any]]] ?? [:] { for seed in extra { _ = try db.insert(model, values: values(seed, model: db.schema.model(model)), actor: actor) } }
                for (model, changes) in sample["seedChanges"] as? [String: [[String: Any]]] ?? [:] { for change in changes { try f.change(model, id: change["id"] as! String, values: values(change.filter { $0.key != "id" }, model: db.schema.model(model))) } }
                if let age = sample["age"] as? NSNumber {
                    let target = (sample["tool"] as! String).contains("target"), input = sample["input"] as! [String: Any], key = target ? "targetId" : "contactId"
                    let id = input[key] as? String ?? (input[key + "s"] as! [String])[0]
                    _ = try db.insert(target ? NativeTargetEnrichment.model : NativeContactEnrichment.model, values: ["id": .text(uid(8000)), key: .text(id), "status": .text("COMPLETED"), "fields": .text(target ? "[\"title\"]" : "[]"), "triggeredBy": .text(sample["user"] as! String), "createdAt": .text(NativeContactEnrichment.stamp(f.now.addingTimeInterval(-age.doubleValue / 1000)))], actor: actor)
                }
            }
            probe.environment = sample["environment"] as! [String: String]; probe.events = []; probe.failure = sample["eventFailure"] as? Bool == true; probe.calls = 0
            let label = "case \(index) \(sample["label"]!)", input = sample["input"] as! [String: Any], tool = sample["tool"] as! String, user = sample["user"] as! String
            let auditBefore = try Dictionary(uniqueKeysWithValues: models.map { ($0, try db.auditCount($0)) })
            let result = try await call(router, tool: tool, input: input, header: f.header(user)), actual = try payload(result), expectedResult = sample["result"] as! [String: Any], expected = try payload(expectedResult)
            var mapping: [String: String] = [:]
            if let id = (actual["data"] as? [String: Any])?["enrichmentId"] as? String, let expectedID = (expected["data"] as? [String: Any])?["enrichmentId"] as? String { mapping[id] = expectedID }
            try check(try json(normalize(actual, map: mapping)) == json(normalize(expected, map: [:])), "response \(label): \(actual) != \(expected)")
            try check((result["isError"] as? Bool ?? false) == (expectedResult["isError"] as? Bool ?? false), "error flag " + label)
            if probe.failure, let id = probe.events.first?.data.enrichmentId,
               let sourceID = ((sample["apiEvents"] as! [[String: Any]]).first?["data"] as? [String: Any])?["enrichmentId"] as? String {
                try check(UUID(uuidString: id) != nil, "rolled back generated event UUID"); mapping[id] = sourceID
            }
            let apiEvents = try JSONSerialization.jsonObject(with: JSONEncoder().encode(probe.events))
            try check(try json(normalize(apiEvents, map: mapping)) == json(sample["apiEvents"]!), "original logical event " + label)
            let initialJobs = try db.jobs(events: NativeContactEnrichment.events + NativeTargetEnrichment.events)
            try check(initialJobs.count == ((result["isError"] as? Bool ?? false) ? 0 : 1), "one durable intent or rollback " + label)
            if let job = initialJobs.first {
                try check(job.payload["actorID"] == user && job.status == "pending", "actor and persisted pending state")
                let rawFields = try JSONSerialization.jsonObject(with: Data(job.payload["mcpFields"]!.utf8))
                try check(try json(rawFields) == json((sample["apiEvents"] as! [[String: Any]])[0]["data"].flatMap { ($0 as? [String: Any])?["fields"] }!), "raw names/descriptions retained")
                try check(!job.payload.values.contains(where: { allKeys.values.contains($0) }), "no provider credential in outbox")
            }
            if sample["worker"] as? Bool == true, result["isError"] as? Bool != true {
                if tool.contains("contact") {
                    let throwing = (sample["providerOutput"] as? [String: Any])?["throwError"] as? Bool == true
                    let output = throwing ? NativeEnrichmentOutput(enrichments: [:], status: .error) : try JSONDecoder().decode(NativeEnrichmentOutput.self, from: json(sample["providerOutput"]!))
                    let worker = NativeContactEnrichmentWorker(db: db, store: probe.store, environment: probe.env, clock: { f.now }, enrich: { _, fields, openai, firecrawl, report in
                        probe.calls += 1; if throwing { throw NativeAIError(message: "Synthetic provider failure") }; try check(fields.allSatisfy { $0.mcpRequested == true }, "MCP-only field policy reaches provider")
                        try check(openai == allKeys["OPENAI_API_KEY"] && firecrawl == allKeys["FIRECRAWL_API_KEY"], "contact current keys")
                        try await report(.init(message: "isolated progress", kind: .info)); return output
                    })
                    while try await worker.runNext() {}
                } else {
                    let output = try JSONDecoder().decode(NativeTargetAgentOutput.self, from: json(sample["providerOutput"]!))
                    let worker = NativeTargetEnrichmentWorker(db: db, store: probe.store, environment: probe.env, clock: { f.now }, review: { _, _, _, _ in throw Failure.assertion("MCP target used review provider") }, agent: { context, anthropic, e2b, report in
                        probe.calls += 1; try check(context.fields.map(\.name) == NativeTargetEnrichment.automaticNames, "fixed eight target fields despite free input")
                        try check(anthropic == allKeys["ANTHROPIC_API_KEY"] && e2b.key == allKeys["E2B_API_KEY"], "target current keys")
                        try await report(.init(message: "isolated progress", kind: .info)); return output
                    })
                    while try await worker.runNext() {}
                }
                try check(probe.calls == sample["providerCalls"] as! Int, "original provider call count " + label)
            }
            let expectedState = sample[probe.failure ? "nativeRollbackState" : "state"] as! [String: [[String: Any]]]
            for model in [NativeContactEnrichment.model, NativeTargetEnrichment.model, NativeTargetEnrichment.contactModel] {
                let old = Set(seeds[model]!.compactMap { $0["id"] as? String } + [uid(8000)])
                let native = try rows(model, db: db).filter { !old.contains($0["id"].string) }
                let source = expectedState[model]!.filter { !old.contains($0["id"] as! String) }
                if native.count == source.count { for (a, b) in zip(native, source) { mapping[a["id"].string] = b["id"] as? String } }
            }
            for model in models {
                let current = try rows(model, db: db).map { try NativeMCPWire.record($0, schema: db.schema) }
                func sorted(_ value: Any) -> [[String: Any]] { (value as! [[String: Any]]).sorted { ($0["id"] as! String) < ($1["id"] as! String) } }
                let left = try json(sorted(normalize(current, map: mapping))), right = try json(sorted(normalize(expectedState[model]!, map: [:])))
                if left != right { try left.write(to: resources.appendingPathComponent("build/mcp-enrichment-actual-state.json")); try right.write(to: resources.appendingPathComponent("build/mcp-enrichment-expected-state.json")) }
                try check(left == right, "full persisted state " + model + " " + label)
                if result["isError"] as? Bool == true { try check(try db.auditCount(model) == auditBefore[model], "error/audit rollback " + label) }
            }
        }
        try keys(reference["keyCases"] as! [[String: Any]], resources: resources)
        try await fences(resources)
        print("Compared \((reference["cases"] as! [Any]).count - start) source API/worker cases, \((reference["keyCases"] as! [Any]).count) key precedence cases")
    }
    static func keys(_ cases: [[String: Any]], resources: URL) throws {
        for sample in cases {
            let f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
            let store = NativeAIQAServices(), input = sample["input"] as! [String: String], provider = NativeAIProvider(rawValue: sample["provider"] as! String)!, alice = try service(f)
            let empty = NativeAIEnvironment(lookup: { _ in nil })
            for (name, crm, scope) in [("user", alice, NativeAIKeyScope.user), ("system", f.admin, .system)] {
                guard let key = input[name] else { continue }
                let api = NativeAIKeys(service: crm, store: store, environment: empty, clock: { f.now })
                try api.save(api.setting(provider, scope: scope), key: key == "CORRUPT" ? "system-key" : key)
                if key == "CORRUPT", let id = try api.setting(provider, scope: scope).rows.first?.credentialID { try store.remove(id: id) }
            }
            let env = NativeAIEnvironment(lookup: { $0 == provider.rawValue + "_API_KEY" ? input["environment"] : nil })
            do {
                let resolved = try NativeAIKeys(service: alice, store: store, environment: env, clock: { f.now }).resolve(provider)
                try check(sample["error"] == nil, "corrupt system credential blocks user fallback")
                try check(resolved?.key == sample["value"] as? String, "source ENV/system/user priority")
            } catch { if sample["error"] != nil { checks += 1 } else { throw error } }
        }
    }
    static func fences(_ resources: URL) async throws {
        let f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let probe = Probe(); probe.environment = allKeys; let crm = try service(f), db = f.db
        let router = try f.router(handlers: NativeMCPEnrichment.handlers(store: { _ in probe.store }, environment: probe.env, clock: { f.now }))
        func add(_ id: Int, target: Bool = false) throws -> NativeRecord {
            try db.insert(target ? "crm_Targets" : "crm_Contacts", values: ["id": .text(uid(id)), "last_name": .text("隔離"), "email": .text("qa@example.invalid"), target ? "created_by" : "createdBy": .text(crm.identity.id)], actor: crm.identity.id)
        }
        func dispatch(_ id: Int, target: Bool = false, bulk: Bool = false, fields: [[String: Any]] = [["name": "description"]]) async throws -> [String: Any] {
            let kind = target ? "target" : "contact"
            return try await payload(call(router, tool: "crm_enrich_" + kind + (bulk ? "_bulk" : ""), input: [kind + (bulk ? "Ids" : "Id"): bulk ? [uid(id)] as Any : uid(id), "fields": fields], header: f.header(crm.identity.id)))
        }
        for (offset, target) in [false, true].enumerated() {
            let id = 6000 + offset; _ = try add(id, target: target); _ = try await dispatch(id, target: target)
            let event = target ? NativeTargetEnrichment.event : NativeContactEnrichment.event, job = try db.jobs(events: [event]).first!
            if target { try NativeTargetEnrichmentService(service: crm, store: probe.store, environment: probe.env, clock: { f.now }).cancel(job) }
            else { try NativeContactEnrichmentService(service: crm, store: probe.store, environment: probe.env, clock: { f.now }).cancel(job) }
            try check(try db.job(id: job.id)?.status == "cancelled", "MCP job uses existing cancellation")
            let history = try db.get(target ? NativeTargetEnrichment.model : NativeContactEnrichment.model, key: ["id": .text(job.id)])!
            try check(history["status"] == .text("FAILED"), "cancellation history and audit")
        }
        _ = try add(6010)
        _ = try await dispatch(6010)
        let w = NativeContactEnrichmentWorker(db: db, store: probe.store, environment: probe.env, clock: { f.now }, enrich: { _, _, _, _, _ in
            try f.change("crm_Contacts", id: uid(6010), values: ["description": .text("手入力")])
            return .init(enrichments: ["description": .init(field: "description", value: .string("外部取得"), confidence: 0.8)], status: .completed)
        })
        _ = try await w.runNext(); try check(try db.get("crm_Contacts", key: ["id": .text(uid(6010))])!["description"] == .text("手入力"), "manual edit during await wins")
        for (index, mutation) in ["role", "key", "cancel"].enumerated() {
            let id = 6020 + index; _ = try add(id); let data = try await dispatch(id), historyID = (data["data"] as! [String: Any])["enrichmentId"] as! String
            let worker = NativeContactEnrichmentWorker(db: db, store: probe.store, environment: probe.env, clock: { f.now }, enrich: { _, _, _, _, _ in
                if mutation == "role" { try f.change("Users", id: crm.identity.id, values: ["userStatus": .text("INACTIVE")]) }
                if mutation == "key" { probe.environment["OPENAI_API_KEY"] = "changed-key" }
                if mutation == "cancel" { try NativeContactEnrichmentService(service: crm, store: probe.store, environment: probe.env, clock: { f.now }).cancel(db.job(id: historyID)!) }
                return .init(enrichments: ["description": .init(field: "description", value: .string("外部取得"), confidence: 0.8)], status: .completed)
            })
            _ = try await worker.runNext()
            try check(try db.get("crm_Contacts", key: ["id": .text(uid(id))])!["description"] == .null, "await " + mutation + " prevents apply")
            try f.change("Users", id: crm.identity.id, values: ["userStatus": .text("ACTIVE")]); probe.environment = allKeys
            if let job = try db.job(id: historyID), job.status == "pending" { try NativeContactEnrichmentService(service: crm, store: probe.store, environment: probe.env, clock: { f.now }).cancel(job) }
        }
        _ = try add(6030)
        let audits = try db.auditCount(NativeContactEnrichment.model)
        try sql("CREATE TRIGGER fail_enrichment_outbox BEFORE INSERT ON native_outbox WHEN NEW.event LIKE 'enrich/%' BEGIN SELECT RAISE(ABORT, 'fixture queue unavailable'); END;", fixture: f)
        let denied = try await dispatch(6030)
        try check(try denied["code"] as? String == "INTERNAL_ERROR" && db.auditCount(NativeContactEnrichment.model) == audits, "outbox failure rolls back history/audit")
        try sql("DROP TRIGGER fail_enrichment_outbox;", fixture: f)
        _ = try add(6040, target: true)
        try f.change("crm_Targets", id: uid(6040), values: ["deletedAt": .text(NativeContactEnrichment.stamp(f.now))])
        _ = try await dispatch(6040, target: true, fields: [["name": "free"], ["name": "free"]])
        let targetWorker = NativeTargetEnrichmentWorker(db: db, store: probe.store, environment: probe.env, clock: { f.now }, review: { _, _, _, _ in throw Failure.assertion("review provider") }, agent: { context, _, _, _ in
            if context.mode == .contact { return .init(target: [:], contacts: [.init(name: "担当", email: "person@example.invalid", title: "部長", linkedinUrl: "https://linkedin.invalid/person", phone: nil, source: nil)], confidence: [:]) }
            return .init(target: ["description": "固定8列の取得", "country": "変更しない"], contacts: [.init(name: "担当", email: "person@example.invalid", title: nil, linkedinUrl: nil, phone: nil, source: nil)], confidence: [:])
        })
        _ = try await targetWorker.runNext()
        let child = try db.jobs(events: [NativeTargetEnrichment.contactEvent]).first!
        try check(child.payload["mcpOrigin"] == "single" && child.status == "pending", "MCP deleted parent propagates origin to discovered contact")
        _ = try await targetWorker.runNext()
        let person = try db.get(NativeTargetEnrichment.contactModel, key: ["id": .text(child.payload["contactId"]!)])!
        try check(person["title"] == .text("部長") && person["enrichStatus"] == .text("COMPLETED"), "MCP target contact fanout reaches existing agent worker")
        let target = try db.get("crm_Targets", key: ["id": .text(uid(6040))])!
        try check(target["description"] == .text("固定8列の取得") && target["country"] == .null, "free requested fields do not change fixed target map")
        _ = try add(6050)
        _ = try await dispatch(6050, bulk: true)
        let reopened = try NativeDatabase(url: db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let restarted = NativeContactEnrichmentWorker(db: reopened, store: probe.store, environment: probe.env, clock: { f.now }, enrich: { _, _, _, _, _ in .init(enrichments: [:], status: .completed) })
        _ = try await restarted.runNext(); _ = try await restarted.runNext()
        let restartedHistory = try reopened.page(NativeContactEnrichment.model, fields: ["status"], equal: ["contactId": .text(uid(6050))]).rows
        try check(restartedHistory.count == 1 && restartedHistory[0]["status"] == .text("COMPLETED"), "MCP bulk survives database reopen and fanout")
        _ = try add(6060, target: true)
        probe.environment.removeValue(forKey: "E2B_API_KEY")
        let e2b = NativeE2BSettings(service: f.admin, store: probe.store, environment: probe.env, clock: { f.now })
        try e2b.save(e2b.setting(), key: "shared-keychain-e2b", template: NativeE2BSettings.defaultTemplate)
        let keychainResult = try await dispatch(6060, target: true)
        try check((keychainResult["data"] as? [String: Any])?["status"] as? String == "RUNNING", "Mac Keychain shared E2B setting is usable by MCP")
        let targetKeys = try NativeTargetEnrichmentService(service: crm, store: probe.store, environment: probe.env, clock: { f.now }).credentials(.automatic)
        if case let .agent(_, connection) = targetKeys { try check(connection.key == "shared-keychain-e2b", "worker resolves same opaque E2B setting") } else { throw Failure.assertion("missing E2B Keychain credentials") }
        probe.environment = allKeys
        _ = try add(6070)
        let auditBeforeFailure = try db.auditCount(NativeContactEnrichment.model)
        try sql("CREATE TRIGGER fail_enrichment_audit BEFORE INSERT ON native_audit WHEN NEW.model = 'crm_Contact_Enrichment' BEGIN SELECT RAISE(ABORT, 'fixture audit unavailable'); END;", fixture: f)
        let auditDenied = try await dispatch(6070)
        try check(try auditDenied["code"] as? String == "INTERNAL_ERROR" && db.auditCount(NativeContactEnrichment.model) == auditBeforeFailure, "mandatory audit failure rolls back history and queue")
        try sql("DROP TRIGGER fail_enrichment_audit;", fixture: f)
        let loose = NativeMCPEnrichment.fields([.init(name: "", description: nil), .init(name: "", description: "duplicate")])
        try NativeEnrichmentField.validate(loose)
        do { try NativeEnrichmentField.validate([.init(name: "", displayName: "", description: "")]); throw Failure.assertion("UI validation weakened") } catch is NativeAIError { checks += 1 }
        let schema = NativeEnrichmentOpenAI.schema(loose, corroborated: false)
        try check((schema["required"] as! [String]).count == 6, "MCP duplicate names retain source request schema")
        var requests = 0
        let ai = NativeEnrichmentOpenAI(apiKey: "fixture-openai", request: { request in
            requests += 1
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try check((body["model"] as? String) == NativeEnrichmentOpenAI.defaultModel, "real OpenAI adapter with injected transport")
            let content = String(decoding: try json(["": "自由な値", "_confidence": 0.9, "_sources": NSNull()]), as: UTF8.self)
            let reply: [String: Any] = ["object": "chat.completion", "model": NativeEnrichmentOpenAI.defaultModel, "choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": content]]]]
            return (try json(reply), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let found = try await ai.extract(content: "isolated content", pages: [], fields: loose, context: [:], corroborated: false, report: { _ in })
        try check(requests == 1 && found[""]?.value == .string("自由な値"), "free/duplicate MCP fields reach real provider transport")
        let collisions = [NativeEnrichmentField(name: "x", displayName: "x", description: ""), NativeEnrichmentField(name: "x_confidence", displayName: "x_confidence", description: "")]
        do { _ = try await ai.extract(content: "x", pages: [], fields: collisions, context: [:], corroborated: false, report: { _ in }); throw Failure.assertion("UI schema collision accepted") } catch is NativeAIError { checks += 1 }
        try check(requests == 1, "UI schema collision rejected before transport")
    }
}
