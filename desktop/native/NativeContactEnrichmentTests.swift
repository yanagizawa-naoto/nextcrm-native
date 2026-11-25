import Foundation
import SQLite3

@main enum NativeContactEnrichmentTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label)
    }
    static let fields = NativeEnrichmentField.contactPresets
    static func result(_ values: [String: String] = ["position": "営業部長", "website": "https://example.invalid"]) -> NativeEnrichmentOutput {
        .init(enrichments: values.reduce(into: [:]) { dict, item in
            dict[item.key] = .init(field: item.key, value: .string(item.value), confidence: 0.8, source: "https://example.invalid/source")
        }, status: .completed)
    }
    final class Fixture {
        let root: URL, db: NativeDatabase, admin: CRMService, alice: CRMService, bob: CRMService
        let store = NativeAIQAServices()
        var now = Date(timeIntervalSince1970: 1_800_000_000), openai: String? = "qa-openai", firecrawl: String? = "qa-firecrawl", calls = 0
        init(_ resources: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ContactEnrichment-" + UUID().uuidString)
            let database = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            db = database
            let administrator = CRMService(db: database, identity: try CRMService.bootstrap(database, resources: resources.appendingPathComponent("../../prisma")))
            admin = administrator
            func user(_ name: String) throws -> CRMService {
                let row = try database.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: administrator.identity.id)
                return CRMService(db: database, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
            }
            alice = try user("alice"); bob = try user("bob")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var env: NativeAIEnvironment { .init(lookup: { [unowned self] in $0 == "OPENAI_API_KEY" ? self.openai : $0 == "FIRECRAWL_API_KEY" ? self.firecrawl : nil }) }
        func api(_ who: CRMService? = nil) -> NativeContactEnrichmentService { .init(service: who ?? alice, store: store, environment: env, clock: { [unowned self] in self.now }) }
        func contact(_ values: [String: SQLValue] = [:], who: CRMService? = nil) throws -> NativeRecord {
            var input: [String: SQLValue] = ["first_name": .text("試験"), "last_name": .text("連絡先"), "email": .text("qa@example.invalid"), "v": .integer(0), "createdBy": .text((who ?? alice).identity.id)]
            input.merge(values) { _, new in new }; return try db.insert("crm_Contacts", values: input, actor: (who ?? alice).identity.id)
        }
        func request(_ row: NativeRecord, mode: NativeContactEnrichment.Mode = .review, fields: [NativeEnrichmentField] = NativeContactEnrichmentTests.fields) throws -> String {
            try api().request(contactIDs: [row["id"].string], fields: fields, mode: mode)[0]
        }
        func job(_ id: String) throws -> NativeJob { guard let row = try db.job(id: id) else { throw NativeDBError.conflict }; return row }
        func history(_ id: String) throws -> NativeRecord { try db.get(NativeContactEnrichment.model, key: ["id": .text(id)])! }
        func row(_ record: NativeRecord) throws -> NativeRecord { try db.get(record.model, key: db.key(for: record))! }
        func worker(timeout: UInt64 = 90_000_000_000, _ generate: NativeContactEnrichmentWorker.Enrich? = nil) -> NativeContactEnrichmentWorker {
            .init(db: db, store: store, environment: env, clock: { [unowned self] in self.now }, timeoutNanoseconds: timeout,
                  enrich: generate ?? { [unowned self] _, _, _, _, _ in self.calls += 1; return result() })
        }
        func sql(_ command: String) throws {
            var connection: OpaquePointer?; guard sqlite3_open(db.url.path, &connection) == SQLITE_OK else { throw NativeDBError.conflict }
            defer { sqlite3_close(connection) }; guard sqlite3_exec(connection, command, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(connection))) }
        }
    }
    static func run(_ worker: NativeContactEnrichmentWorker) async throws { let ran = try await worker.runNext(); try check(ran, "worker claimed a request") }
    static func main() async {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            try await originals(resources); try await review(resources); try await access(resources)
            try await races(resources); try await lifecycle(resources); try await cancellations(resources); try await batches(resources)
            print("Native contact enrichment: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func originals(_ resources: URL) async throws {
        struct Refs: Decodable {
            struct Case: Decodable { let label: String, input: [String: String?], output: NativeEnrichmentOutput, updates: [String: String], historyStatus: String, providerCalls: Int }
            struct Recent: Decodable { let age: Double?, skip: Bool }
            struct Conversion: Decodable { let value: NativeEnrichmentValue, text: String, truthy: Bool }
            struct Skip: Decodable { let email: String, skip: Bool }
            let fields: [NativeEnrichmentField], cases: [Case], recent: [Recent], conversions: [Conversion], skips: [Skip], skipDomains: [String]
        }
        let refs = try JSONDecoder().decode(Refs.self, from: Data(contentsOf: resources.appendingPathComponent("build/native-contact-enrichment-reference.json")))
        try check(Array(refs.fields.prefix(9)).map(\.name) == fields.map(\.name), "original nine supported columns")
        try check(NativeEnrichmentSkipList().domains == Set(refs.skipDomains), "actual original skip-list fallback")
        for item in refs.skips {
            try check((NativeEnrichmentSkipList().reason(item.email) != nil) == item.skip, "original skip domain \(item.email)")
            if item.skip {
                let f = try Fixture(resources), row = try f.contact(["email": .text(item.email)]), id = try f.request(row)
                try await run(f.worker()); try check(try f.history(id)["status"] == .text("SKIPPED") && f.calls == 0, "skip performs no provider request")
                let stored = try NativeContactEnrichment.decode(NativeEnrichmentOutput.self, f.history(id)["result"].string)
                try check(stored.status == .skipped && stored.error != nil, "skip reason retained in history JSON")
            }
        }
        let customSkip = NativeEnrichmentSkipList(contents: " # comment\nEXAMPLE.INVALID\n\u{FEFF}other.invalid　\n")
        try check(customSkip.reason("qa@example.invalid") != nil && customSkip.reason("qa@gmail.com") == nil && customSkip.domains.count == 2, "custom skip list replaces defaults with JS trim")
        for item in refs.conversions { try check(item.value.text == item.text && item.value.truthy == item.truthy, "original JS conversion \(item.text)") }
        for item in refs.cases {
            let f = try Fixture(resources), row = try f.contact(item.input.mapValues { $0.map(SQLValue.text) ?? .null })
            let id = try f.request(row, mode: .bulk, fields: refs.fields)
            try await run(f.worker { email, fields, openai, firecrawl, progress in
                f.calls += 1
                try check(email == "qa@example.invalid" && fields == refs.fields && openai == "qa-openai" && firecrawl == "qa-firecrawl", "exact request \(item.label)")
                try await progress(.init(message: "検索しています", kind: .agent, sourceURL: "https://example.invalid"))
                return item.output
            })
            let current = try f.row(row)
            for name in fields.map(\.name) { try check(current[name] == (item.updates[name].map(SQLValue.text) ?? row[name]), "original bulk \(item.label) \(name)") }
            try check(try f.history(id)["status"].string == item.historyStatus && f.calls == item.providerCalls, "original bulk completion \(item.label)")
            let stored = try NativeContactEnrichment.decode(NativeEnrichmentOutput.self, f.history(id)["result"].string)
            try check(stored == item.output.validated(for: refs.fields), "complete result and provenance retained \(item.label)")
            try check(try f.job(id).result["progressSequence"] == "1", "durable latest progress")
        }
        for item in refs.recent {
            let f = try Fixture(resources), row = try f.contact()
            if let age = item.age { _ = try f.db.insert(NativeContactEnrichment.model, values: ["contactId": row["id"], "status": .text("COMPLETED"), "fields": .text("[]"), "createdAt": .text(NativeContactEnrichment.stamp(f.now.addingTimeInterval(-age / 1000)))], actor: f.alice.identity.id) }
            let id = try f.request(row, mode: .bulk); try await run(f.worker())
            try check(try (f.history(id)["status"] == .text("SKIPPED")) == item.skip && f.calls == (item.skip ? 0 : 1), "original 7-day boundary \(String(describing: item.age))")
            let single = try f.request(row); try await run(f.worker())
            try check(try f.history(single)["status"] == .text("COMPLETED"), "single bypasses recent bulk dedup")
        }
    }
    static func review(_ resources: URL) async throws {
        let f = try Fixture(resources), row = try f.contact(["position": .text("手入力の役職")]), id = try f.request(row)
        try await run(f.worker()); try check(try f.row(row)["website"] == .null && f.row(row)["position"] == row["position"], "single never auto-applies")
        let preview = try f.api().preview(id)
        let selected = try f.api().apply(preview, selected: ["website", "custom", "createdBy"])
        try check(selected == ["website"] && f.row(row)["position"] == row["position"], "only selected supported field applied")
        try check(try f.alice.embeddingJobs().rows.count == 1, "atomic search embedding refresh")
        let fresh = try f.api().preview(id)
        try check(try f.api().apply(fresh, selected: ["position"]) == ["position"], "explicit single selection can replace displayed value")
        let noChange = try f.api().preview(id); try check(try f.api().apply(noChange, selected: ["position"]).isEmpty, "repeated apply is a no-op")
        let old = try f.api().preview(id)
        _ = try f.db.update(f.row(row), changes: ["position": .text("後から手入力")], actor: f.alice.identity.id)
        try rejects("stale selected field") { _ = try f.api().apply(old, selected: ["position"]) }
        let unrelated = try f.api().preview(id)
        _ = try f.db.update(f.row(row), changes: ["last_name": .text("改姓")], actor: f.alice.identity.id)
        try check(try f.api().apply(unrelated, selected: ["position"]) == ["position"], "unrelated edits need not invalidate preview")
        _ = try f.db.update(f.row(row), changes: ["email": .text("different@example.invalid")], actor: f.alice.identity.id)
        try rejects("changed identity cannot apply old result") { _ = try f.api().preview(id) }
        let page = try f.api().history(contactID: row["id"].string)
        try check(page.total == 1 && page.rows.first?["result"] == .null, "history list excludes result body")
    }
    static func access(_ resources: URL) async throws {
        let f = try Fixture(resources), own = try f.contact(), other = try f.contact(who: f.bob)
        try rejects("other owner single") { _ = try f.request(other) }
        try rejects("all-or-nothing mixed bulk") { _ = try f.api().request(contactIDs: [own["id"].string,other["id"].string], fields: fields, mode: .bulk) }
        try check(try f.api().history(contactID: own["id"].string).total == 0, "no partial mixed history")
        let account = try f.db.insert("crm_Accounts", values: ["name": .text("所有会社"), "createdBy": .text(f.alice.identity.id), "v": .integer(0)], actor: f.alice.identity.id)
        let linked = try f.db.update(other, changes: ["accountsIDs": account["id"]], actor: f.bob.identity.id)
        try rejects("linked read access is not single-write access") { _ = try f.request(linked) }
        let linkedID = try f.request(linked, mode: .bulk); try await run(f.worker())
        try check(try f.history(linkedID)["status"] == .text("COMPLETED"), "preserve original linked-account bulk scope")
        let id = try f.request(own), job = try f.job(id)
        try rejects("another user cancels") { try f.api(f.bob).cancel(job) }
        try f.api(f.admin).cancel(job)
        try check(try f.job(id).status == "cancelled", "administrator can cancel another actor request")
        try rejects("stale cancellation") { try f.api(f.admin).cancel(job) }
        f.openai = nil
        try rejects("missing key admission") { _ = try f.request(own) }
        f.openai = "qa-openai"; f.firecrawl = nil
        try rejects("missing firecrawl admission") { _ = try f.request(own) }
        f.firecrawl = "qa-firecrawl"
        let noEmail = try f.contact(["email": .null])
        try rejects("single missing email") { _ = try f.request(noEmail) }
        let skipped = try f.request(noEmail, mode: .bulk); try await run(f.worker())
        try check(try f.history(skipped)["status"] == .text("SKIPPED"), "bulk missing email records skip")
        for role in ["partner", "unknown"] {
            let user = try f.db.insert("Users", values: ["email": .text(role + "@example.invalid"), "role": .text(role == "unknown" ? "user" : role), "userStatus": .text("ACTIVE")], actor: f.admin.identity.id)
            let service = CRMService(db: f.db, identity: .init(id: user["id"].string, role: role, partnerAccountID: nil))
            try rejects("\(role) cannot request") { _ = try f.api(service).request(contactIDs: [own["id"].string], fields: fields, mode: .bulk) }
        }
    }
    static func races(_ resources: URL) async throws {
        for mutation in ["field", "blank", "email", "owner", "delete", "ban", "openai", "firecrawl", "cancel", "lease"] {
            let f = try Fixture(resources), row = try f.contact(), id = try f.request(row, mode: .bulk)
            try await run(f.worker { _, _, _, _, _ in
                switch mutation {
                case "field": _ = try f.db.update(row, changes: ["position": .text("手入力")], actor: f.alice.identity.id)
                case "blank": _ = try f.db.update(row, changes: ["position": .text(" ")], actor: f.alice.identity.id)
                case "email": _ = try f.db.update(row, changes: ["email": .text("new@example.invalid")], actor: f.alice.identity.id)
                case "owner": _ = try f.db.update(row, changes: ["createdBy": .text(f.bob.identity.id)], actor: f.admin.identity.id)
                case "delete": _ = try f.db.setDeleted(row, deleted: true, actor: f.alice.identity.id)
                case "ban": _ = try f.db.update(f.db.get("Users", key: ["id": .text(f.alice.identity.id)])!, changes: ["banned": .integer(1)], actor: f.admin.identity.id)
                case "openai": f.openai = "qa-replacement"
                case "firecrawl": f.firecrawl = "qa-replacement"
                case "cancel": try f.api().cancel(f.job(id))
                default:
                    f.now.addTimeInterval(301)
                    let oldToken = try f.job(id).leaseToken
                    let reclaimed = try f.db.claimJob(events: [NativeContactEnrichment.event], now: f.now)!
                    try check(reclaimed.leaseToken != oldToken, "lease reclaimed")
                }
                return result()
            })
            if ["field", "blank"].contains(mutation) {
                try check(try f.row(row)["position"] == .text(mutation == "field" ? "手入力" : " ") && f.row(row)["website"] != .null, "manual edits preserved \(mutation)")
            } else {
                try check(try f.row(row)["position"] == .null && f.row(row)["website"] == .null, "late response blocked \(mutation)")
                let status = try f.job(id).status
                try check(status == (["openai", "firecrawl"].contains(mutation) ? "retry" : mutation == "cancel" ? "cancelled" : mutation == "lease" ? "running" : "done"), "durable fenced state \(mutation)")
            }
        }
    }
    static func lifecycle(_ resources: URL) async throws {
        let f = try Fixture(resources), row = try f.contact(), id = try f.request(row)
        let failing = f.worker { _, _, _, _, _ in throw NativeAIError(message: "試験用の一時エラー", retryable: true) }
        for attempt in 1...4 { try await run(failing); try check(try f.job(id).attempts == attempt && f.job(id).status == (attempt == 4 ? "failed" : "retry"), "four bounded attempts"); f.now.addTimeInterval(301) }
        try f.api().retry(f.job(id)); try check(try f.job(id).attempts == 0 && f.history(id)["status"] == .text("PENDING"), "manual retry resets same request")
        try await run(f.worker()); try check(try f.history(id)["status"] == .text("COMPLETED"), "manual retry completes")
        let crash = try f.request(row), claimed = try f.db.claimJob(events: [NativeContactEnrichment.event], now: f.now)!
        try check(crash == claimed.id, "crash fixture claim")
        let reopened = try NativeDatabase(url: f.db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let restarted = NativeContactEnrichmentWorker(db: reopened, store: f.store, environment: f.env, clock: { f.now }, enrich: { _, _, _, _, _ in result() })
        let before = try await restarted.runNext(); try check(!before, "live lease excludes second process")
        f.now.addTimeInterval(301); try await run(restarted)
        try check(try f.job(crash).status == "done" && f.job(crash).attempts == 2, "expired lease resumes after database reopen")
        let timeoutID = try f.request(row)
        try await run(f.worker(timeout: 1_000_000) { _, _, _, _, _ in try await Task.sleep(nanoseconds: 5_000_000_000); return result() })
        try check(try f.job(timeoutID).status == "retry", "timeout cancels provider and schedules retry")
        try f.api().cancel(f.job(timeoutID))
        let bad = try f.request(row)
        try await run(f.worker { _, _, _, _, _ in result(["createdBy": "unexpected"]) })
        try check(try f.job(bad).status == "failed" && f.row(row)["createdBy"] == row["createdBy"], "unsolicited provider field rejects entire result")
        let errorID = try f.request(row)
        try await run(f.worker { _, _, _, _, _ in .init(enrichments: [:], status: .error, error: "検索を完了できませんでした。") })
        try check(try f.job(errorID).status == "failed" && f.history(errorID)["status"] == .text("FAILED"), "provider error never masquerades as completed")
        let skipID = try f.request(row)
        try await run(f.worker { _, _, _, _, _ in .init(enrichments: [:], status: .skipped, error: "対象外ドメイン") })
        try check(try f.history(skipID)["status"] == .text("SKIPPED"), "provider skip retained as skip")
        let rollback = try f.request(row, mode: .bulk)
        // Delete previous completed history so the request reaches publication.
        try f.sql("UPDATE crm_Contact_Enrichment SET createdAt='2000-01-01T00:00:00Z' WHERE status='COMPLETED'")
        try f.sql("CREATE TRIGGER reject_enrichment_completion BEFORE UPDATE ON crm_Contact_Enrichment WHEN NEW.status='COMPLETED' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        try await run(f.worker()); try check(try f.row(row)["website"] == .null && f.job(rollback).status == "failed", "contact and history completion roll back atomically")
    }
    static func batches(_ resources: URL) async throws {
        let f = try Fixture(resources)
        var ids: [String] = []
        for _ in 0..<101 { ids.append(try f.contact()["id"].string) }
        try rejects("bulk over 100") { _ = try f.api().request(contactIDs: ids, fields: fields, mode: .bulk) }
        try rejects("duplicate contact IDs") { _ = try f.api().request(contactIDs: [ids[0],ids[0]], fields: fields, mode: .bulk) }
        try rejects("no fields") { _ = try f.api().request(contactIDs: [ids[0]], fields: [], mode: .bulk) }
        try rejects("ambiguous fields") { _ = try f.api().request(contactIDs: [ids[0]], fields: [fields[0],fields[0]], mode: .bulk) }
        try f.sql("CREATE TRIGGER reject_enrichment_batch BEFORE INSERT ON crm_Contact_Enrichment WHEN NEW.contactId='\(ids[1])' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        try rejects("atomic batch publication") { _ = try f.api().request(contactIDs: Array(ids.prefix(3)), fields: fields, mode: .bulk) }
        try check(try f.db.page(NativeContactEnrichment.model, fields: []).total == 0 && f.db.jobs(events: [NativeContactEnrichment.event]).isEmpty, "batch failure leaves no history or jobs")
        try f.sql("DROP TRIGGER reject_enrichment_batch")
        let requests = try f.api().request(contactIDs: Array(ids.prefix(100)), fields: fields, mode: .bulk)
        try check(requests.count == 100 && Set(requests).count == 100, "100 durable independent requests")
        let batch = try f.job(requests[0]).payload["batchID"]
        for id in requests { try check(try f.job(id).payload["batchID"] == batch && f.history(id)["status"] == .text("PENDING"), "atomic batch record and job") }
        try f.api().cancel(f.job(requests[0])); try await run(f.worker())
        try check(try f.job(requests[1]).status == "done" && f.job(requests[0]).status == "cancelled", "cancel one item leaves others runnable")
    }
    actor Signal { var entered = false; func mark() { entered = true } }
    static func cancellations(_ resources: URL) async throws {
        for shutdown in [false, true] {
            let f = try Fixture(resources), row = try f.contact(), id = try f.request(row), signal = Signal()
            let worker = f.worker { _, _, _, _, progress in
                try await progress(.init(message: "応答を待っています", kind: .info))
                await signal.mark(); try await Task.sleep(nanoseconds: 5_000_000_000); return result()
            }
            let task = Task { try await worker.runNext() }
            let deadline = Date().addingTimeInterval(3)
            while !(await signal.entered) && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            let entered = await signal.entered; try check(entered, "provider request reached cancellation boundary")
            let start = Date()
            if shutdown { task.cancel() }
            else { try f.api().cancel(f.job(id)); await worker.cancel(id) }
            let ran = try await task.value
            try check(ran && Date().timeIntervalSince(start) < 2, "provider cancellation returns promptly")
            try check(try f.job(id).status == (shutdown ? "retry" : "cancelled") && f.row(row)["position"] == .null, "shutdown resumes; explicit cancellation stays terminal")
            if shutdown { f.now.addTimeInterval(10); try await run(f.worker()); try check(try f.job(id).status == "done", "shutdown request resumes") }
        }
    }
}
