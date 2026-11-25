import Foundation
import SQLite3

extension NativeEmbeddingKind: Decodable {}

@main enum NativeEmbeddingWorkerTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func vector(_ value: Float = 1) throws -> NativeEmbeddingVector {
        var values = [Float](repeating: 0, count: 1536); values[0] = value; return try NativeEmbeddingVector(values)
    }
    final class Fixture {
        let root: URL, resources: URL, db: NativeDatabase, admin: CRMService, alice: CRMService, bob: CRMService
        let store = NativeAIQAServices()
        var now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), key: String? = "qa-original", calls = 0
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AIWorker-" + UUID().uuidString)
            let database = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            let administrator = CRMService(db: database, identity: try CRMService.bootstrap(database, resources: resources.appendingPathComponent("../../prisma")))
            db = database; admin = administrator
            func user(_ name: String) throws -> CRMService {
                let row = try database.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: administrator.identity.id)
                return CRMService(db: database, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
            }
            alice = try user("alice"); bob = try user("bob")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var env: NativeAIEnvironment { NativeAIEnvironment(lookup: { [unowned self] name in name == "OPENAI_API_KEY" ? self.key : nil }) }
        var index: NativeEmbeddingIndex { NativeEmbeddingIndex(db: db) }
        func worker(_ custom: NativeEmbeddingWorker.Generate? = nil, environment: NativeAIEnvironment? = nil) -> NativeEmbeddingWorker {
            NativeEmbeddingWorker(db: db, store: store, environment: environment ?? env, clock: { [unowned self] in self.now }, generate: custom ?? { [unowned self] _, _ in self.calls += 1; return try vector() })
        }
        func keys(_ who: CRMService? = nil) -> NativeAIKeys { NativeAIKeys(service: who ?? alice, store: store, environment: env, clock: { [unowned self] in self.now }) }
        func record(_ kind: NativeEmbeddingKind = .account, _ input: [String: SQLValue] = ["name": .text("日本の取引先")], who: CRMService? = nil) throws -> NativeRecord {
            let owner = who ?? alice; var values = input
            values["createdBy"] = .text(owner.identity.id); values["v"] = .integer(0)
            return try db.insert(kind.parent, values: values, actor: owner.identity.id)
        }
        func mail(_ input: [String: SQLValue] = ["subject": .text("日本語のメール"), "bodyText": .text("本文"), "fromEmail": .text("qa@example.invalid")], linked: Bool = true) throws -> NativeRecord {
            let account = try db.insert("EmailAccount", values: ["userId": .text(alice.identity.id), "label": .text("検証"), "imapHost": .text("example.invalid"), "imapPort": .integer(993), "smtpHost": .text("example.invalid"), "smtpPort": .integer(465), "username": .text("test"), "passwordEncrypted": .text("unused")], actor: alice.identity.id)
            var values = input; values["emailAccountId"] = account["id"]; values["userId"] = .text(alice.identity.id); values["rfcMessageId"] = .text(UUID().uuidString); values["folder"] = .text("INBOX")
            let row = try db.insert("Email", values: values, actor: alice.identity.id)
            if linked { let parent = try record(); _ = try db.insert("EmailsToAccounts", values: ["emailId": row["id"], "accountId": parent["id"]], actor: alice.identity.id) }
            return row
        }
        func enqueue(_ row: NativeRecord, kind: NativeEmbeddingKind = .account, extra: [String: String] = [:], actor: String? = nil) throws -> String {
            var payload = ["actorID": actor ?? alice.identity.id]
            if kind == .email { payload["emailID"] = row["id"].string; payload["accountID"] = row["emailAccountId"].string; payload["rebuild"] = "true" }
            else { payload["record_id"] = row["id"].string }
            payload.merge(extra) { _, new in new }; return try db.enqueue(NativeEmbeddingJobs.event(kind), payload: payload, now: now)
        }
        func job(_ id: String) throws -> NativeJob { guard let job = try db.job(id: id) else { throw NativeDBError.conflict }; return job }
        func sql(_ command: String) throws {
            var connection: OpaquePointer?; guard sqlite3_open(db.url.path, &connection) == SQLITE_OK else { throw NativeDBError.conflict }
            defer { sqlite3_close(connection) }; guard sqlite3_exec(connection, command, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(connection))) }
        }
    }
    static func main() async {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            try await references(resources); try await caching(resources); try await mutation(resources)
            try await permissions(resources); try await retries(resources); try await backfill(resources)
            print("Native embedding workers: \(checks) checks passed")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run(_ worker: NativeEmbeddingWorker) async throws { let ran = try await worker.runNext(); try check(ran, "queued job claimed") }
    static func references(_ resources: URL) async throws {
        struct Reference: Decodable { struct Case: Decodable { let kind: NativeEmbeddingKind; let input: [String: String?]; let text: String; let hash: String }; let cases: [Case] }
        let refs = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/native-embedding-worker-reference.json")))
        for item in refs.cases {
            let f = try Fixture(resources); var input = item.input.mapValues { $0.map(SQLValue.text) ?? .null }
            if item.kind == .opportunity {
                let stage = try f.db.insert("crm_Opportunities_Sales_Stages", values: ["name": input.removeValue(forKey: "stage")!], actor: f.alice.identity.id); input["sales_stage"] = stage["id"]
            }
            let row = try item.kind == .email ? f.mail(input) : f.record(item.kind, input)
            let source = try f.alice.embeddingInput(item.kind, id: row["id"].string)!
            try check(Data(source.text.utf8) == Data(item.text.utf8), "original \(item.kind) worker exact UTF8 text")
            try check(source.hash == item.hash, "original \(item.kind) worker content hash")
            let id = try f.enqueue(row, kind: item.kind, extra: item.kind == .email ? ["contentHash": source.legacyMailHash!] : [:])
            let worker = f.worker { text, key in
                try check(text == item.text && key == "qa-original", "provider receives current text and credential"); return try vector()
            }
            try await run(worker)
            try check(try f.job(id).result["outcome"] == "embedded", "original worker fixture persisted")
            try check(try f.index.existing(item.kind, parentID: row["id"].string)?[item.kind.hashField].string == item.hash, "original hash stored")
        }
    }
    static func caching(_ resources: URL) async throws {
        let f = try Fixture(resources), row = try f.record(), w = f.worker()
        _ = try f.enqueue(row); try await run(w); f.key = nil
        let duplicate = try f.enqueue(row); try await run(w)
        try check(try f.job(duplicate).result["outcome"] == "unchanged" && f.calls == 1, "unchanged content needs no credential or provider")
        let old = try f.index.existing(.account, parentID: row["id"].string)!
        _ = try f.db.update(old, changes: ["embedding": .blob(Data([0]))], actor: f.alice.identity.id); f.key = "qa-original"
        _ = try f.enqueue(row); try await run(w); try check(f.calls == 2, "corrupt cached vector regenerated")
        let empty = try f.db.update(row, changes: ["name": .text("　\u{FEFF}")], actor: f.alice.identity.id)
        let noText = try f.enqueue(empty); f.key = nil; try await run(w)
        try check(try f.job(noText).result["outcome"] == "empty" && f.index.existing(.account, parentID: row["id"].string) == nil && f.calls == 2, "empty source removes obsolete vector without API")
        let legacy = try f.db.enqueue("crm/account.saved", payload: ["record_id": row["id"].string], now: f.now)
        try await run(w); try check(try f.job(legacy).status == "failed" && f.job(legacy).lastError!.contains("実行者"), "legacy job never guesses actor or credential")
        let saved = try f.alice.save(CRMModule.find("crm_Accounts")!, original: nil, input: ["name": .text("通常の保存")])
        try check(try f.alice.embeddingJobs().rows.contains { $0.payload["record_id"] == saved["id"].string && $0.payload["actorID"] == f.alice.identity.id }, "ordinary CRM save emits actor-bound embedding event")
    }
    static func mutation(_ resources: URL) async throws {
        for change in ["text", "key", "stage"] {
            let f = try Fixture(resources)
            let stage = try f.db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("提案")], actor: f.alice.identity.id)
            let kind: NativeEmbeddingKind = change == "stage" ? .opportunity : .account
            let row = try f.record(kind, change == "stage" ? ["name": .text("商談"), "sales_stage": stage["id"]] : ["name": .text("変更前")])
            let id = try f.enqueue(row, kind: kind)
            let worker = f.worker { _, _ in
                if change == "key" { f.key = "qa-replacement" }
                else if change == "stage" { _ = try f.db.update(stage, changes: ["name": .text("受注")], actor: f.alice.identity.id) }
                else { _ = try f.db.update(row, changes: ["name": .text("変更後")], actor: f.alice.identity.id) }
                return try vector()
            }
            try await run(worker)
            try check(try f.job(id).status == "retry" && f.index.existing(kind, parentID: row["id"].string) == nil, "\(change) change rejects late vector")
            f.now.addTimeInterval(10); try await run(f.worker())
            try check(try f.job(id).status == "done", "\(change) change regenerates current source")
        }
        let f = try Fixture(resources), mail = try f.mail(), source = try f.alice.embeddingInput(.email, id: mail["id"].string)!
        let id = try f.enqueue(mail, kind: .email, extra: ["contentHash": source.legacyMailHash!])
        try await run(f.worker { _, _ in _ = try f.db.update(mail, changes: ["isRead": .integer(1)], actor: f.alice.identity.id); return try vector() })
        try check(try f.job(id).status == "done", "mail flags do not invalidate identical content")
        let stale = try f.enqueue(mail, kind: .email, extra: ["contentHash": "old"]); try await run(f.worker())
        try check(try f.job(stale).result["outcome"] == "skipped" && f.calls == 0, "stale mail handoff makes no provider call")
        let k = try Fixture(resources); k.key = nil
        try k.keys().save(k.keys().setting(.openai, scope: .user), key: "qa-keychain-first")
        let a = try k.record(), queued = try k.enqueue(a)
        try await run(k.worker { _, _ in try k.keys().save(k.keys().setting(.openai, scope: .user), key: "qa-keychain-second"); return try vector() })
        try check(try k.job(queued).status == "retry" && k.index.existing(.account, parentID: a["id"].string) == nil, "Keychain pointer replacement fences awaited provider response")
    }
    static func permissions(_ resources: URL) async throws {
        for change in ["delete", "owner", "ban"] {
            let f = try Fixture(resources), row = try f.record(), id = try f.enqueue(row)
            try await run(f.worker { _, _ in
                if change == "delete" { _ = try f.db.setDeleted(row, deleted: true, actor: f.alice.identity.id) }
                else if change == "owner" { _ = try f.db.update(row, changes: ["createdBy": .text(f.bob.identity.id)], actor: f.admin.identity.id) }
                else { let user = try f.db.get("Users", key: ["id": .text(f.alice.identity.id)])!; _ = try f.db.update(user, changes: ["userStatus": .text("INACTIVE")], actor: f.admin.identity.id) }
                return try vector()
            })
            try check(try f.job(id).result["outcome"] != "embedded" && f.index.existing(.account, parentID: row["id"].string) == nil, "\(change) revocation prevents persistence")
        }
        let f = try Fixture(resources), other = try f.record(who: f.bob)
        let denied = try f.enqueue(other); try await run(f.worker())
        try check(try f.job(denied).result["outcome"] == "skipped" && f.calls == 0, "private CRM source never sent")
        let mail = try f.mail(linked: false), unlinked = try f.enqueue(mail, kind: .email)
        try await run(f.worker()); try check(try f.job(unlinked).result["outcome"] == "skipped" && f.calls == 0, "unlinked mail never sent")
        let linked = try f.mail(), account = try f.db.get("EmailAccount", key: ["id": linked["emailAccountId"]])!
        _ = try f.db.update(account, changes: ["userId": .text(f.bob.identity.id)], actor: f.admin.identity.id)
        let mismatch = try f.enqueue(linked, kind: .email); try await run(f.worker())
        try check(try f.job(mismatch).result["outcome"] == "skipped" && f.calls == 0, "mailbox owner checked before API")
    }
    static func retries(_ resources: URL) async throws {
        let f = try Fixture(resources), row = try f.record(); f.key = nil
        let id = try f.enqueue(row); try await run(f.worker())
        try check(try f.job(id).status == "failed" && f.calls == 0, "missing credential stops without retry loop")
        let failed = try f.job(id)
        try rejects("another actor retry") { try f.bob.retryEmbeddingJob(failed) }
        try rejects("another actor cancellation") { try f.bob.cancelEmbeddingJob(failed) }
        try check(try f.bob.embeddingJobs().total == 0, "job list owner isolation")
        try f.alice.retryEmbeddingJob(failed)
        try rejects("stale UI retry snapshot") { try f.alice.retryEmbeddingJob(failed) }
        try check(try f.job(id).attempts == 0, "manual retry resets exhausted attempts")
        f.key = "qa-original"
        let transient = f.worker { _, _ in throw NativeAIError(message: "一時的な混雑", retryable: true) }
        for attempt in 1...4 {
            try await run(transient); let job = try f.job(id)
            try check(job.attempts == attempt && job.status == (attempt < 4 ? "retry" : "failed"), "bounded transient retry \(attempt)")
            if attempt < 4 {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
                guard let stamp = job.nextRunAt, let due = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { throw NativeDBError.message("retry due date missing or malformed") }
                try check(abs(due.timeIntervalSince(f.now) - 5 * pow(2, Double(attempt - 1))) < 0.01, "exponential backoff")
                f.now = due.addingTimeInterval(1)
            }
        }
        try f.alice.retryEmbeddingJob(f.job(id))
        try await run(f.worker { _, _ in throw NativeDBError.message("provider-secret-must-never-appear") })
        try check(try !f.job(id).lastError!.contains("provider-secret"), "untrusted provider errors redacted")
        try f.alice.retryEmbeddingJob(f.job(id))
        let task = Task { try await f.worker { _, _ in withUnsafeCurrentTask { $0?.cancel() }; return try vector() }.runNext() }
        _ = try await task.value
        try check(try f.job(id).status == "retry" && f.index.existing(.account, parentID: row["id"].string) == nil, "cancellation retains durable retry and no vector")
        try f.alice.cancelEmbeddingJob(f.job(id)); try check(try f.job(id).status == "cancelled", "queued retry cancellation")

        let l = try Fixture(resources), source = try l.record(), leaseID = try l.enqueue(source)
        var successor: NativeJob?
        try await run(l.worker { _, _ in
            let other = try NativeDatabase(url: l.db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            l.now.addTimeInterval(301); successor = try other.claimJob(events: NativeEmbeddingJobs.events, now: l.now); return try vector()
        })
        try check(try successor != nil && l.job(leaseID) == successor && l.index.existing(.account, parentID: source["id"].string) == nil, "expired lease reclaimed by another connection fences old attempt")
        let r = try Fixture(resources), original = try r.record(), rollback = try r.enqueue(original)
        try r.sql("CREATE TRIGGER fail_embedding_finish BEFORE UPDATE ON native_outbox WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END")
        try await run(r.worker())
        try check(try r.job(rollback).status == "failed" && r.index.existing(.account, parentID: original["id"].string) == nil, "embedding and completion transaction rolls back together")
        try r.sql("DROP TRIGGER fail_embedding_finish"); try r.alice.retryEmbeddingJob(r.job(rollback)); try await run(r.worker())
        try check(try r.job(rollback).status == "done", "storage failure recovers by explicit retry")
    }
    static func backfill(_ resources: URL) async throws {
        let f = try Fixture(resources)
        for i in 0..<205 { _ = try f.record(.account, ["name": .text("一括 \(i)"), "id": .text(String(format: "10000000-0000-0000-0000-%012d", i))]) }
        _ = try f.record(who: f.bob); let deleted = try f.record(); _ = try f.db.setDeleted(deleted, deleted: true, actor: f.alice.identity.id)
        let id = try f.alice.requestEmbeddingBackfill(now: f.now)
        try check(try f.alice.requestEmbeddingBackfill(now: f.now) == id, "active backfill reservation deduplicated")
        var change = true
        let env = NativeAIEnvironment(lookup: { _ in
            if change, (try? f.job(id).result["dispatched"]) == "100" { return "qa-changed" }; return "qa-original"
        })
        try await run(f.worker(environment: env))
        try check(try f.job(id).status == "retry" && f.job(id).result["dispatched"] == "100", "backfill durable cursor after one bounded page")
        try check(try f.alice.embeddingJobs().total == 101, "first page dispatch committed with cursor")
        change = false; f.now.addTimeInterval(10); try await run(f.worker(environment: env))
        try check(try f.job(id).result["dispatched"] == "205" && f.job(id).status == "done", "interrupted backfill resumes through last partial page")
        var all: [NativeJob] = []
        for offset in stride(from: 0, to: 206, by: 100) { all += try f.alice.embeddingJobs(offset: offset).rows }
        let children = all.filter { $0.event != NativeEmbeddingJobs.backfill }
        try check(children.count == 205 && Set(children.compactMap { $0.payload["record_id"] }).count == 205, "resume produces no duplicates and excludes private/deleted rows")
        try check(children.allSatisfy { $0.payload["backfillID"] == id && $0.payload["actorID"] == f.alice.identity.id }, "fanout preserves cancellation and actor binding")

        let c = try Fixture(resources), row = try c.record(), parent = try c.alice.requestEmbeddingBackfill(now: c.now)
        let child = try c.enqueue(row, extra: ["backfillID": parent])
        try c.alice.cancelEmbeddingJob(c.job(parent)); try await run(c.worker())
        try check(try c.job(child).result["outcome"] == "skipped" && c.calls == 0, "cancelled parent suppresses already queued child")

        let a = try Fixture(resources)
        for i in 0..<110 { _ = try a.record(.account, ["name": .text("原子性 \(i)")]) }
        let batch = try a.alice.requestEmbeddingBackfill(now: a.now)
        try a.sql("CREATE TRIGGER fail_fanout BEFORE INSERT ON native_outbox WHEN NEW.event='crm/account.saved' AND (SELECT COUNT(*) FROM native_outbox WHERE event='crm/account.saved')=50 BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END")
        try await run(a.worker())
        try check(try a.job(batch).status == "failed" && a.job(batch).result.isEmpty && a.alice.embeddingJobs().total == 1, "partial fanout and cursor roll back atomically")
        try a.sql("DROP TRIGGER fail_fanout"); try a.alice.retryEmbeddingJob(a.job(batch)); try await run(a.worker())
        try check(try a.job(batch).result["dispatched"] == "110" && a.alice.embeddingJobs().total == 111, "fanout retry recovers without skipped records")
    }
}
