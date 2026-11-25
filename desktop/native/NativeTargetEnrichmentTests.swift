import Foundation
import SQLite3

@main enum NativeTargetEnrichmentTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func rejects(_ label: String, _ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label) }
    static let fields = NativeTargetEnrichment.fields(NativeTargetEnrichment.automaticNames)
    static func agentResult() -> NativeTargetAgentOutput { .init(target: ["industry": "情報通信", "company_website": "https://company.example.invalid", "city": "東京"], contacts: [], confidence: ["industry": 0.8, "city": 0.59]) }
    static func reviewResult() -> NativeEnrichmentOutput { .init(enrichments: ["industry": .init(field: "industry", value: .string("情報通信"), confidence: 0.8)], status: .completed) }
    final class Fixture {
        let root: URL, db: NativeDatabase, admin: CRMService, alice: CRMService, bob: CRMService
        let store = NativeAIQAServices()
        var now = Date(timeIntervalSince1970: 1_800_000_000), calls = 0
        var secrets: [String: String] = ["OPENAI_API_KEY": "qa-openai", "FIRECRAWL_API_KEY": "qa-firecrawl", "ANTHROPIC_API_KEY": "qa-anthropic", "E2B_API_KEY": "qa-e2b"]
        init(_ resources: URL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TargetEnrichment-" + UUID().uuidString)
            db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            admin = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
            func user(_ name: String, db: NativeDatabase, actor: String) throws -> CRMService {
                let row = try db.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: actor)
                return .init(db: db, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
            }
            alice = try user("alice", db: db, actor: admin.identity.id); bob = try user("bob", db: db, actor: admin.identity.id)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var env: NativeAIEnvironment { .init(lookup: { [unowned self] in self.secrets[$0] }) }
        func api(_ who: CRMService? = nil) -> NativeTargetEnrichmentService { .init(service: who ?? alice, store: store, environment: env, clock: { [unowned self] in self.now }) }
        func target(_ input: [String: SQLValue] = [:], who: CRMService? = nil) throws -> NativeRecord {
            var values: [String: SQLValue] = ["last_name": .text("営業対象"), "first_name": .text("試験"), "company": .text("試験株式会社"), "email": .text("qa@example.invalid"), "created_by": .text((who ?? alice).identity.id)]
            values.merge(input) { _, new in new }; return try db.insert("crm_Targets", values: values, actor: (who ?? alice).identity.id)
        }
        func person(_ parent: NativeRecord, values: [String: SQLValue] = [:]) throws -> NativeRecord {
            try db.insert(NativeTargetEnrichment.contactModel, values: ["targetId": parent["id"], "name": .text("山田 太郎"), "email": .text("yamada@example.invalid")].merging(values) { _, new in new }, actor: alice.identity.id)
        }
        func request(_ target: NativeRecord, mode: NativeTargetEnrichment.Mode = .automatic, force: Bool = false, fields: [NativeEnrichmentField] = NativeTargetEnrichmentTests.fields) throws -> String { try api().request(targetIDs: [target["id"].string], fields: fields, mode: mode, force: force)[0] }
        func row(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model, key: db.key(for: row))! }
        func history(_ id: String) throws -> NativeRecord { try db.get(NativeTargetEnrichment.model, key: ["id": .text(id)])! }
        func job(_ id: String) throws -> NativeJob { try db.job(id: id)! }
        func worker(timeout: UInt64 = 300_000_000_000, review: NativeTargetEnrichmentWorker.Review? = nil, agent: NativeTargetEnrichmentWorker.Agent? = nil) -> NativeTargetEnrichmentWorker {
            .init(db: db, store: store, environment: env, clock: { [unowned self] in self.now }, reviewTimeout: timeout, agentTimeout: timeout,
                  review: review ?? { [unowned self] _, _, _, _ in self.calls += 1; return reviewResult() },
                  agent: agent ?? { [unowned self] _, _, _, _ in self.calls += 1; return agentResult() })
        }
        func sql(_ command: String) throws {
            var connection: OpaquePointer?; guard sqlite3_open(db.url.path, &connection) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(connection) }
            guard sqlite3_exec(connection, command, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(connection))) }
        }
    }
    static func run(_ worker: NativeTargetEnrichmentWorker) async throws { let claimed = try await worker.runNext(); try check(claimed, "claimed target job") }
    static func main() async {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            try await originals(resources); try await review(resources); try await access(resources); try await contacts(resources)
            try await races(resources); try await lifecycle(resources); try await atomicity(resources); try await matching(resources)
            try await snapshotAndCollisions(resources); try await cancellationAndLease(resources); try await contactHistoryAndIdentity(resources)
            print("Native target enrichment: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func originals(_ resources: URL) async throws {
        struct Refs: Decodable {
            struct Case: Decodable { let label: String, input: [String: String?], updates: [String: String], historyStatus: String, fanoutCount: Int, killed: Int }
            struct Domain: Decodable { let companyWebsite: String?, email: String?, expected: String? }
            struct Recent: Decodable { let age: Double?, skip: Bool }
            let output: NativeTargetAgentOutput, cases: [Case], domains: [Domain], recent: [Recent], columns: [String], personalNames: [String], companyNames: [String], personalDefaults: [String], companyDefaults: [String]
        }
        let refs = try JSONDecoder().decode(Refs.self, from: Data(contentsOf: resources.appendingPathComponent("build/native-target-enrichment-reference.json")))
        try check(Set(refs.columns) == NativeTargetEnrichment.columns && refs.columns.count == 18, "all 18 original writable fields")
        try check(refs.personalNames == NativeTargetEnrichment.personalNames && refs.companyNames == NativeTargetEnrichment.companyNames, "original scenario presets")
        try check(refs.personalDefaults == NativeTargetEnrichment.personalDefaults && refs.companyDefaults == NativeTargetEnrichment.companyDefaults, "original defaults")
        let personalPresets = NativeTargetEnrichment.fields(NativeTargetEnrichment.personalNames, scenario: .personal)
        let companyPresets = NativeTargetEnrichment.fields(NativeTargetEnrichment.companyNames, scenario: .company)
        try check(personalPresets.first { $0.name == "social_linkedin" }?.subject == .person && companyPresets.first { $0.name == "social_linkedin" }?.subject == .company, "personal and company LinkedIn have distinct subjects")
        try check(personalPresets.first { $0.name == "company" }?.subject == .person && personalPresets.first { $0.name == "company_website" }?.subject == .company, "personal employer lookup precedes company website")
        try check(NativeTargetEnrichment.fields(NativeTargetEnrichment.automaticNames).allSatisfy { $0.subject == .company }, "automatic company defaults retain company social scope")
        try check(companyPresets.allSatisfy { $0.subject == .company } && !personalPresets.contains { $0.description.contains("本人または会社") }, "preset descriptions specify intended entity")
        for item in refs.domains { try check(NativeTargetEnrichment.domain(website: item.companyWebsite, email: item.email) == item.expected, "original company domain") }
        for item in refs.cases {
            let f = try Fixture(resources), target = try f.target(item.input.mapValues { $0.map(SQLValue.text) ?? .null }), id = try f.request(target)
            try await run(f.worker(agent: { context, anthropic, connection, report in
                let e2b = connection.key, template = connection.template
                try check(context.company == "試験株式会社" && context.fields == fields && anthropic == "qa-anthropic" && e2b == "qa-e2b" && template == "nextcrm-enrichment", "exact agent inputs")
                try await report(.init(message: "企業情報を取得しています", kind: .agent)); return refs.output
            }))
            for field in fields { try check(try f.row(target)[field.name] == (item.updates[field.name].map(SQLValue.text) ?? target[field.name]), "source blank/confidence \(item.label) \(field.name)") }
            try check(try f.history(id)["status"].string == item.historyStatus && f.job(id).result["contactsQueued"] == String(item.fanoutCount), "original completion/fanout")
            try check(try f.db.page(NativeTargetEnrichment.contactModel, fields: [], equal: ["targetId": target["id"]]).total == 2, "unidentified candidate not inserted")
            try check(try NativeContactEnrichment.decode(NativeTargetAgentOutput.self, f.history(id)["result"].string) == refs.output, "full automatic result retained")
        }
        for item in refs.recent {
            let f = try Fixture(resources), row = try f.target()
            if let age = item.age { _ = try f.db.insert(NativeTargetEnrichment.model, values: ["targetId": row["id"], "status": .text("COMPLETED"), "fields": .text("[]"), "createdAt": .text(NativeContactEnrichment.stamp(f.now.addingTimeInterval(-age / 1000)))], actor: f.alice.identity.id) }
            let id = try f.request(row); try await run(f.worker())
            try check(try (f.history(id)["status"] == .text("SKIPPED")) == item.skip && f.calls == (item.skip ? 0 : 1), "original seven-day boundary")
            let forced = try f.request(f.row(row), force: true); try await run(f.worker())
            try check(try f.history(forced)["status"] == .text("COMPLETED"), "force bypasses completed history")
        }
    }
    static func review(_ resources: URL) async throws {
        let f = try Fixture(resources), row = try f.target(["email": .null]), id = try f.request(row, mode: .review)
        try await run(f.worker(review: { context, openai, firecrawl, _ in
            try check(context.email == nil && context.company == "試験株式会社" && openai == "qa-openai" && firecrawl == "qa-firecrawl", "company-only review inputs")
            return reviewResult()
        }))
        try check(try f.row(row)["industry"] == .null, "review awaits explicit apply")
        let preview = try f.api().preview(id)
        try check(try f.api().apply(preview, selected: ["industry", "created_by"]) == ["industry"], "selected supported apply")
        try check(try f.row(row)["created_by"] == row["created_by"], "identity ownership protected")
        try rejects("stale selected field") { _ = try f.api().apply(preview, selected: ["industry"]) }
        let changed = try f.request(f.row(row), mode: .review); try await run(f.worker())
        _ = try f.db.update(f.row(row), changes: ["company": .text("別の会社")], actor: f.alice.identity.id)
        try rejects("changed company identity") { _ = try f.api().preview(changed) }
        let personal = try f.target(["email": .text("qa@gmail.com")]), personalID = try f.request(personal, mode: .review)
        try await run(f.worker()); try check(try f.history(personalID)["status"] == .text("COMPLETED"), "personal email with supplied company is researched")
        let noCompany = try f.target(["email": .text("qa@gmail.com"), "company": .null]), skipped = try f.request(noCompany, mode: .review)
        try await run(f.worker()); try check(try f.history(skipped)["status"] == .text("SKIPPED"), "free email alone cannot supply company fields")
        let namedID = try f.request(noCompany, mode: .review, fields: NativeTargetEnrichment.fields(["position"], scenario: .personal))
        var namedCalls = 0
        try await run(f.worker(review: { context, _, _, _ in
            namedCalls += 1
            try check(context.name == "試験 営業対象" && context.fields.first?.subject == .person, "person identity and persisted subject reach review provider")
            return .init(enrichments: [:], status: .completed)
        }))
        try check(try f.history(namedID)["status"] == .text("COMPLETED") && namedCalls == 1, "personal email can research named person")
        let bad = try f.target(), badID = try f.request(bad, mode: .review)
        try await run(f.worker(review: { _, _, _, _ in .init(enrichments: [:], status: .error, error: "取得できません") }))
        try check(try f.history(badID)["status"] == .text("FAILED") && f.job(badID).status == "failed", "error result never marked complete")
        let typed = try f.target(), typedFields: [NativeEnrichmentField] = [
            .init(name: "employees", displayName: "従業員数", description: "人数", type: .number),
            .init(name: "country", displayName: "国・地域", description: "確認値", type: .boolean)]
        let typedID = try f.request(typed, mode: .review, fields: typedFields)
        try await run(f.worker(review: { _, _, _, _ in .init(enrichments: [
            "employees": .init(field: "employees", value: .number(150), confidence: 0.8),
            "country": .init(field: "country", value: .boolean(false), confidence: 0.8)], status: .completed) }))
        try check(try f.api().apply(f.api().preview(typedID), selected: ["employees", "country"]) == ["employees"] && f.row(typed)["employees"] == .text("150"), "original typed request and truthy string conversion preserved")
    }
    static func access(_ resources: URL) async throws {
        let f = try Fixture(resources), own = try f.target(), other = try f.target(who: f.bob)
        try rejects("foreign target request") { _ = try f.request(other) }
        try rejects("mixed batch atomic authorization") { _ = try f.api().request(targetIDs: [own["id"].string, other["id"].string], fields: fields, mode: .bulk) }
        try check(try f.db.page(NativeTargetEnrichment.model, fields: []).total == 0, "unauthorized batch created no history")
        try rejects("duplicate IDs") { _ = try f.api().request(targetIDs: [own["id"].string, own["id"].string], fields: fields, mode: .bulk) }
        try rejects("unsupported original email option") { _ = try f.request(own, fields: [.init(name: "email", displayName: "メール", description: "メール")]) }
        try rejects("empty fields") { _ = try f.request(own, fields: []) }
        for name in ["ANTHROPIC_API_KEY", "E2B_API_KEY"] {
            let old = f.secrets.removeValue(forKey: name)
            try rejects("missing \(name)") { _ = try f.request(own) }; f.secrets[name] = old
        }
        let id = try f.request(own)
        try check(try !NativeContactEnrichment.json(f.job(id).payload).contains("qa-anthropic") && !NativeContactEnrichment.json(f.job(id).payload).contains("qa-e2b"), "no credentials persisted")
        try rejects("foreign history") { _ = try f.api(f.bob).history(targetID: own["id"].string) }
        try rejects("foreign cancellation") { try f.api(f.bob).cancel(f.job(id)) }
        try f.api(f.admin).cancel(f.job(id)); try check(try f.job(id).status == "cancelled", "administrator cancellation")
        let person = try f.person(own)
        try rejects("wrong contact parent") { _ = try f.api(f.admin).requestContact(person["id"].string, targetID: other["id"].string) }
        let users = try f.db.get("Users", key: ["id": .text(f.alice.identity.id)])!
        let next = try f.request(own); _ = try f.db.update(users, changes: ["banned": .integer(1)], actor: f.admin.identity.id)
        try await run(f.worker()); try check(try f.history(next)["status"] == .text("SKIPPED") && f.calls == 0, "revoked actor cannot call provider")
    }
    static func contacts(_ resources: URL) async throws {
        let f = try Fixture(resources), row = try f.target(), existing = try f.person(row, values: ["title": .text("旧役職"), "phone": .text("保持する電話")])
        let newPerson = NativeTargetAgentOutput.Contact(name: "山田 太郎", email: "yamada@example.invalid", title: "新役職", linkedinUrl: "https://linkedin.com/in/yamada", phone: "更新しない電話")
        let id = try f.request(row)
        try await run(f.worker(agent: { _, _, _, _ in .init(target: [:], contacts: [newPerson], confidence: [:]) }))
        try check(try f.row(existing)["title"] == .text("新役職") && f.row(existing)["phone"] == .text("保持する電話"), "original upsert updates title but preserves existing phone")
        try check(try f.row(existing)["source"] == .text("manual") && f.row(existing)["enrichStatus"] == .text("COMPLETED"), "upsert preserves source and completes")
        try check(try f.job(id).result["contactsQueued"] == "0", "complete candidate no followup")
        let incomplete = try f.person(row, values: ["email": .text("other@example.invalid"), "title": .text("保持する役職")])
        let contactID = try f.api().requestContact(incomplete["id"].string, targetID: row["id"].string)
        try await run(f.worker(agent: { context, _, _, _ in
            try check(context.email == "other@example.invalid" && context.name == "山田 太郎" && context.mode == .contact, "contact context and command timeout mode")
            return .init(target: [:], contacts: [.init(name: "山田 太郎", email: "other@example.invalid", title: "新役職", linkedinUrl: "https://linkedin.com/in/other", phone: "03-0000-0000")], confidence: [:])
        }))
        try check(try f.row(incomplete)["title"] == .text("保持する役職") && f.row(incomplete)["phone"] == .text("03-0000-0000"), "contact worker blank-only")
        try check(try f.job(contactID).result["matchedContact"] == "true" && f.history(contactID)["status"] == .text("COMPLETED"), "contact result/history retained")
        let completeID = try f.api().requestContact(existing["id"].string, targetID: row["id"].string)
        f.secrets.removeValue(forKey: "ANTHROPIC_API_KEY"); try await run(f.worker())
        try check(try f.history(completeID)["status"] == .text("COMPLETED") && f.calls == 0, "already complete contact skips key/provider")
        f.secrets["ANTHROPIC_API_KEY"] = "qa-anthropic"
        let emailNull = try f.person(row, values: ["email": .null, "name": .text("名前だけ")])
        _ = try f.api().requestContact(emailNull["id"].string, targetID: row["id"].string)
        try await run(f.worker(agent: { context, _, _, _ in try check(context.email == "qa@example.invalid", "contact null email falls back to parent"); return .init(target: [:], contacts: [], confidence: [:]) }))
    }
    static func races(_ resources: URL) async throws {
        for change in ["field", "identity", "key", "template", "owner", "cancel"] {
            let f = try Fixture(resources), row = try f.target(), person = try f.person(row), id = try f.request(row)
            try await run(f.worker(agent: { _, _, _, report in
                switch change {
                case "field": _ = try f.db.update(f.row(row), changes: ["industry": .text("手入力")], actor: f.alice.identity.id)
                    _ = try f.db.update(f.row(person), changes: ["title": .text("担当者の手入力")], actor: f.alice.identity.id)
                case "identity": _ = try f.db.update(f.row(row), changes: ["company": .text("別会社")], actor: f.alice.identity.id)
                case "key": f.secrets["E2B_API_KEY"] = "qa-replaced"
                case "template": f.secrets["E2B_ENRICHMENT_TEMPLATE"] = "changed-template"
                case "owner": _ = try f.db.update(f.row(row), changes: ["created_by": .text(f.bob.identity.id)], actor: f.admin.identity.id)
                default: try f.api().cancel(f.job(id))
                }
                if change != "field" { try await report(.init(message: "取得中", kind: .agent)) }
                return .init(target: ["industry": "取得値"], contacts: [.init(name: "山田 太郎", email: "yamada@example.invalid", title: "取得した役職")], confidence: [:])
            }))
            if change == "field" {
                try check(try f.row(row)["industry"] == .text("手入力") && f.row(person)["title"] == .text("担当者の手入力"), "manual edits win for parent and existing contact")
                try check(try f.job(id).result["contactsSkipped"] == "1", "edited contact recorded as skipped")
            } else {
                try check(try f.row(row)["industry"] == .null && f.row(person)["title"] == .null, "no publication after \(change)")
                try check(try f.job(id).status == (change == "key" || change == "template" ? "retry" : change == "cancel" ? "cancelled" : "done"), "terminal state \(change)")
            }
        }
        let f = try Fixture(resources), row = try f.target(), person = try f.person(row)
        let first = try f.api().requestContact(person["id"].string, targetID: row["id"].string)
        let second = try f.api().requestContact(person["id"].string, targetID: row["id"].string)
        try await run(f.worker()); try check(try f.history(first)["status"] == .text("SKIPPED") && f.calls == 0, "new request supersedes queued contact job")
        try await run(f.worker()); try check(try f.history(second)["status"] == .text("COMPLETED"), "latest contact request runs")
    }
    static func lifecycle(_ resources: URL) async throws {
        for contact in [false, true] {
            let f = try Fixture(resources), row = try f.target()
            let id = try contact ? f.api().requestContact(f.person(row)["id"].string, targetID: row["id"].string) : f.request(row)
            let worker = f.worker(agent: { _, _, _, _ in throw NativeAIError(message: "一時的な接続エラー", retryable: true) })
            let count = contact ? 3 : 4
            for attempt in 1...count { try await run(worker); try check(try f.job(id).status == (attempt == count ? "failed" : "retry"), "retry bound \(contact) \(attempt)"); f.now.addTimeInterval(400) }
            try rejects("manager cannot retry as original actor") { try f.api(f.admin).retry(f.job(id)) }
            try f.api().retry(f.job(id)); try check(try f.job(id).attempts == 0 && f.history(id)["result"] == .null, "explicit retry resets attempt and stale result")
            try await run(f.worker()); try check(try f.job(id).status == "done", "manual retry succeeds")
        }
        let f = try Fixture(resources), row = try f.target(), id = try f.request(row)
        _ = try f.db.claimJob(events: NativeTargetEnrichment.events, now: f.now, leaseSeconds: 1)
        f.now.addTimeInterval(2); try await run(f.worker()); try check(try f.job(id).attempts == 2 && f.job(id).status == "done", "abandoned lease reclaimed")
        let timeoutRow = try f.target(), timeoutID = try f.request(timeoutRow)
        try await run(f.worker(timeout: 1_000_000, agent: { _, _, _, _ in try await Task.sleep(nanoseconds: 1_000_000_000); return agentResult() }))
        try check(try f.job(timeoutID).status == "retry", "bounded timeout cancels provider")
    }
    static func atomicity(_ resources: URL) async throws {
        let f = try Fixture(resources), rows = try (0..<100).map { try f.target(["last_name": .text("営業対象\($0)")]) }
        let ids = try f.api().request(targetIDs: rows.map { $0["id"].string }, fields: fields, mode: .bulk)
        try check(ids.count == 100 && Set(ids).count == 100, "atomic 100-target queue")
        try rejects("101-target batch") { _ = try f.api().request(targetIDs: rows.map { $0["id"].string } + [f.target()["id"].string], fields: fields, mode: .bulk) }
        let g = try Fixture(resources), row = try g.target(), id = try g.request(row)
        try g.sql("CREATE TRIGGER fail_target_completion BEFORE UPDATE OF status ON crm_Target_Enrichment WHEN NEW.status='COMPLETED' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        try await run(g.worker(agent: { _, _, _, _ in .init(target: ["industry": "取得値"], contacts: [.init(name: "候補", email: "new@example.invalid")], confidence: [:]) }))
        try check(try g.row(row)["industry"] == .null && g.db.page(NativeTargetEnrichment.contactModel, fields: []).total == 0, "failed completion rolls back fields and contacts")
        try check(try g.db.page(NativeTargetEnrichment.model, fields: []).total == 1 && g.job(id).status == "failed", "failed transaction leaves no fanout histories")
        let h = try Fixture(resources), target = try h.target()
        let selected = NativeTargetEnrichment.fields(["position"]), selectedID = try h.request(target, mode: .bulk, fields: selected)
        try await run(h.worker(agent: { context, _, _, _ in try check(context.fields == selected, "bulk selected fields reach provider"); return .init(target: ["position": "営業部長", "industry": "未選択"], contacts: [], confidence: [:]) }))
        try check(try h.row(target)["position"] == .text("営業部長") && h.row(target)["industry"] == .null && h.job(selectedID).status == "done", "selected bulk fields respected beyond original eight")
    }
    static func matching(_ resources: URL) async throws {
        let f = try Fixture(resources), target = try f.target(), row = try f.person(target)
        let correct = NativeTargetAgentOutput.Contact(name: "山田　太郎", email: "yamada@example.invalid", title: "代表")
        let wrong = NativeTargetAgentOutput.Contact(name: "山田 次郎", email: "wrong@example.invalid", title: "別人")
        try check(NativeTargetAgentOutput(target: [:], contacts: [wrong, correct], confidence: [:]).matchingContact(row) == correct, "Japanese name and exact email beat first token")
        let noEmail = try f.person(target, values: ["email": .null, "name": .text("Alice Smith")])
        try check(NativeTargetAgentOutput(target: [:], contacts: [.init(name: "Alice Jones"), .init(name: "Alice Brown")], confidence: [:]).matchingContact(noEmail) == nil, "ambiguous first name not applied")
        try check(NativeTargetAgentOutput(target: [:], contacts: [.init(name: "Ａｌｉｃｅ　Ｓｍｉｔｈ", title: "役職")], confidence: [:]).matchingContact(noEmail)?.title == "役職", "full-width name normalization")
        try rejects("invalid confidence") { _ = try NativeTargetAgentOutput(target: [:], contacts: [], confidence: ["industry": 1.1]).validated() }
        try rejects("oversized value") { _ = try NativeTargetAgentOutput(target: ["description": String(repeating: "あ", count: 23000)], contacts: [], confidence: [:]).validated() }
        try check(try NativeContactEnrichment.decode(NativeTargetAgentOutput.self, "{\"target\":{},\"confidence\":{}}").contacts.isEmpty, "original absent contacts default")
        try check(NativeTargetEnrichment.domain(website: "javascript:alert(1)", email: "qa@example.invalid") == "example.invalid", "non-web website not used as company domain")
    }
    static func snapshotAndCollisions(_ resources: URL) async throws {
        let f = try Fixture(resources), target = try f.target()
        var late: NativeRecord?
        try f.db.transaction { for index in 0..<205 { late = try f.person(target, values: ["email": .text("person\(index)@example.invalid")]) } }
        let snapshot = try f.db.snapshotTargetContacts(target["id"].string), record = late!
        try check(try f.db.targetContactSnapshotRevision(record["id"].string, snapshot: snapshot) == record.revision, "snapshot covers contact beyond 100-row page")
        let otherDB = try NativeDatabase(url: f.db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        _ = try otherDB.update(record, changes: ["title": .text("別接続から手入力")], actor: f.alice.identity.id)
        try check(try f.db.targetContactSnapshotRevision(record["id"].string, snapshot: snapshot) != f.row(record).revision, "snapshot detects separate connection edit")
        try f.db.discardTargetContactSnapshot(snapshot)
        try check(try f.db.targetContactSnapshotRevision(record["id"].string, snapshot: snapshot) == nil, "temporary snapshot released")
        let id = try f.request(target)
        try await run(f.worker(agent: { _, _, _, _ in
            _ = try otherDB.update(f.row(record), changes: ["title": .text("取得中の別接続編集")], actor: f.alice.identity.id)
            _ = try f.person(target, values: ["email": .text("created-during-request@example.invalid"), "title": .text("取得中に作成")])
            _ = try f.db.update(f.row(target), changes: ["industry": .text("")], actor: f.alice.identity.id)
            return .init(target: ["industry": "取得値"], contacts: [.init(email: record["email"].string, title: "上書きしない"), .init(email: "created-during-request@example.invalid", title: "上書きしない")], confidence: [:])
        }))
        try check(try f.row(record)["title"] == .text("取得中の別接続編集") && f.row(target)["industry"] == .text(""), "separate connection and deliberately cleared field win")
        try check(try f.job(id).result["contactsSkipped"] == "2" && f.job(id).result["contactsQueued"] == "0", "created-during-request contact protected")
        let g = try Fixture(resources), parent = try g.target()
        let a = try g.person(parent, values: ["email": .text("a@example.invalid"), "linkedinUrl": .text("https://linkedin.com/in/a")])
        let b = try g.person(parent, values: ["email": .text("b@example.invalid"), "linkedinUrl": .text("https://linkedin.com/in/b")])
        let collisionID = try g.request(parent)
        try await run(g.worker(agent: { _, _, _, _ in .init(target: ["industry": "情報通信"], contacts: [.init(email: "a@example.invalid", title: "衝突", linkedinUrl: "https://linkedin.com/in/b")], confidence: [:]) }))
        try check(try g.row(a)["title"] == .null && g.row(b)["title"] == .null && g.row(parent)["industry"] == .text("情報通信"), "colliding identifiers never merge different contacts")
        try check(try g.job(collisionID).result["contactsSkipped"] == "1", "collision recorded without losing unrelated company result")
        let h = try Fixture(resources), p = try h.target(), link = "https://linkedin.com/in/link-only"
        let linked = try h.person(p, values: ["email": .null, "linkedinUrl": .text(link)]), linkedID = try h.request(p)
        try await run(h.worker(agent: { _, _, _, _ in .init(target: [:], contacts: [.init(name: "候補1", title: "初回", linkedinUrl: link), .init(name: "候補2", title: "最終", linkedinUrl: link)], confidence: [:]) }))
        try check(try h.row(linked)["title"] == .text("最終") && h.row(linked)["name"] == .text("候補2") && h.job(linkedID).result["contactsSaved"] == "2", "original repeated LinkedIn upsert uses latest incoming values")
    }
    actor Gate {
        var ready = false; var waiter: CheckedContinuation<Void, Never>?
        func signal() { ready = true; waiter?.resume(); waiter = nil }
        func wait() async { if !ready { await withCheckedContinuation { waiter = $0 } } }
    }
    static func cancellationAndLease(_ resources: URL) async throws {
        for explicit in [false, true] {
            let f = try Fixture(resources), row = try f.target(), person = try f.person(row), gate = Gate()
            let id = try f.api().requestContact(person["id"].string, targetID: row["id"].string)
            let worker = f.worker(agent: { _, _, _, _ in await gate.signal(); try await Task.sleep(nanoseconds: 30_000_000_000); return agentResult() })
            let task = Task { try await worker.runNext() }; await gate.wait()
            if explicit { try f.api().cancel(f.job(id)); await worker.cancel(id) } else { task.cancel() }
            let claimed = try await task.value; try check(claimed, "cancelled running contact request")
            try check(try f.job(id).status == (explicit ? "cancelled" : "retry") && f.history(id)["result"] == .null, "cancellation retains correct durable outcome")
            try check(try f.row(person)["enrichStatus"] == .text(explicit ? "FAILED" : "PENDING"), "contact state follows cancellation/shutdown")
        }
        let f = try Fixture(resources), row = try f.target(), id = try f.request(row)
        var replacement: NativeJob?
        try await run(f.worker(agent: { _, _, _, _ in
            f.now.addTimeInterval(361); replacement = try f.db.claimJob(events: NativeTargetEnrichment.events, now: f.now, leaseSeconds: 1)
            return agentResult()
        }))
        try check(replacement?.id == id, "new attempt owns expired lease")
        try check(try f.row(row)["industry"] == .null && f.job(id).leaseToken == replacement?.leaseToken && f.job(id).status == "running", "late result cannot publish or overwrite new lease")
        f.now.addTimeInterval(2); try await run(f.worker()); try check(try f.job(id).status == "done", "subsequent owner completes after expired replacement")
    }
    static func contactHistoryAndIdentity(_ resources: URL) async throws {
        let f = try Fixture(resources), target = try f.target(), person = try f.person(target)
        let personID = try f.api().requestContact(person["id"].string, targetID: target["id"].string)
        try await run(f.worker()); try check(try f.history(personID)["status"] == .text("COMPLETED"), "contact-only history completed")
        let companyID = try f.request(target); try await run(f.worker())
        try check(try f.history(companyID)["status"] == .text("COMPLETED"), "contact-only history never suppresses company enrichment")
        let g = try Fixture(resources), parent = try g.target(), p = try g.person(parent), id = try g.api().requestContact(p["id"].string, targetID: parent["id"].string)
        try await run(g.worker(agent: { _, _, _, _ in
            _ = try g.db.update(g.row(p), changes: ["email": .text("different@example.invalid")], actor: g.alice.identity.id)
            return .init(target: [:], contacts: [.init(name: "山田 太郎", email: "yamada@example.invalid", title: "反映しない")], confidence: [:])
        }))
        try check(try g.row(p)["title"] == .null && g.history(id)["status"] == .text("SKIPPED"), "contact identity checked after provider even without progress")
        let blank = try g.person(parent, values: ["email": .text("")])
        _ = try g.api().requestContact(blank["id"].string, targetID: parent["id"].string)
        try await run(g.worker(agent: { context, _, _, _ in try check(context.email == "", "empty contact email preserves original nullish fallback semantics"); return .init(target: [:], contacts: [], confidence: [:]) }))
        let h = try Fixture(resources), row = try h.target(["email": .null, "company": .null]), missingID = try h.request(row)
        try await run(h.worker()); try check(try h.history(missingID)["status"] == .text("SKIPPED") && h.calls == 0, "missing company and email skip before network")
    }
}
