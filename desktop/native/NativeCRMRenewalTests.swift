import Foundation
import SQLite3
import CoreFoundation

@main enum NativeCRMRenewalTests {
    static var checks = 0
    enum Failure: Error { case assertion(String), injected }
    final class Pause {
        private let state = NSCondition()
        private var waiting = false, released = false
        func stopHere() { state.lock(); waiting = true; state.broadcast(); while !released { state.wait() }; state.unlock() }
        func hasEntered() -> Bool { state.lock(); defer { state.unlock() }; return waiting }
        func release() { state.lock(); released = true; state.broadcast(); state.unlock() }
    }
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws { guard try ok() else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any], model: NativeSchema.Model) throws -> [String: SQLValue] {
        try object.mapValues { value -> SQLValue in
            if value is NSNull { return .null }
            if let text = value as? String { return .text(text) }
            if let n = value as? NSNumber { return .integer(n.int64Value) }
            return .text(String(decoding: try json(value), as: UTF8.self))
        }
    }
    static func seed(_ fixture: [String: Any], db: NativeDatabase, models: [String]) throws {
        try db.transaction {
            for name in models { for row in (fixture[name] as? [[String: Any]] ?? []) { _ = try db.insert(name, values: values(row, model: db.schema.model(name)), actor: "system") } }
        }
    }
    static func records(_ model: String, db: NativeDatabase) throws -> [NativeRecord] {
        var result: [NativeRecord] = [], after: String?
        while true { let rows = try db.keysetPage(model, fields: db.schema.model(model).fields.map(\.name), after: after, includeDeleted: true); if rows.isEmpty { return result }; result += rows; after = rows.last?["id"].string }
    }
    static func jobs(_ db: NativeDatabase, events: [String]) throws -> [NativeJob] {
        var result: [NativeJob] = [], offset = 0
        while true { let rows = try db.jobs(events: events, offset: offset); result += rows; if rows.count < 100 { return result }; offset += rows.count }
    }
    static func canonicalTasks(_ rows: [[String: Any]], fields: [String]) throws -> [String] {
        try rows.map { row in
            var selected = Dictionary(uniqueKeysWithValues: fields.map { ($0, row[$0] ?? NSNull()) })
            if let date = selected["dueDateAt"] as? String { selected["dueDateAt"] = try NativeCRMAutomationDates.stamp(NativeCRMAutomationDates.parse(date)) }
            return String(decoding: try json(selected), as: UTF8.self)
        }.sorted()
    }
    static func drain(_ db: NativeDatabase, env: NativeCRMRenewalJobs.Environment, now: Date) async throws {
        var runs = 0
        while try NativeCRMRenewalJobs.runNext(db: db, environment: env, clock: { now }) { runs += 1; if runs % 16 == 0 { await Task.yield() }; try check(runs < 10_000, "bounded test drain") }
    }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var c: OpaquePointer?; guard sqlite3_open(db.url.path, &c) == SQLITE_OK else { throw Failure.injected }; defer { sqlite3_close(c) }
        guard sqlite3_exec(c, statement, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(c))) }
    }
    static func main() async {
        do { try await run(); print("CRM renewal formal: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let native = URL(fileURLWithPath: CommandLine.arguments[1]), fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
        let ref = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("reference.json"))) as! [String: Any]
        let now = try NativeCRMAutomationDates.parse(ref["epoch"] as! String), models = ref["models"] as! [String], fields = ref["taskFields"] as! [String]
        let samples = ref["cases"] as! [[String: Any]]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RenewalCandidate-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func open(_ name: String) throws -> NativeDatabase { try NativeDatabase(url: root.appendingPathComponent(name + ".sqlite"), schemaURL: native.appendingPathComponent("schema.json"), sqlURL: native.appendingPathComponent("schema.sql")) }
        for (index, sample) in samples.enumerated() {
            let label = sample["label"] as! String, db = try open("source-\(index)")
            try seed(sample["seeds"] as! [String: Any], db: db, models: models)
            let env = NativeCRMRenewalJobs.Environment(appURL: sample["appURL"] as? String, timeZone: TimeZone(identifier: sample["zone"] as! String)!)
            let scan = try db.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
            try await drain(db, env: env, now: now)
            let actualRows = try records("crm_Accounts_Tasks", db: db).map { $0.values.mapValues(\.json) }
            try check(canonicalTasks(actualRows, fields: fields) == canonicalTasks(sample["tasks"] as! [[String: Any]], fields: fields), "source task scalars " + label)
            let taskJobs = try jobs(db, events: [NativeCRMRenewalJobs.taskEvent]), notices = try jobs(db, events: ["crm.task_assigned"])
            let sourceResult = sample["result"] as! [String: Any]
            try check(taskJobs.filter { $0.result["status"] == "created" }.count == sourceResult["created"] as! Int, "source created count " + label)
            try check(taskJobs.allSatisfy { $0.status == "done" }, "no hidden child failure " + label)
            try check(try db.job(id: scan)?.status == "done", "snapshot finished " + label)
            let expectedNotices = sample["notices"] as! [[String: Any]]
            try check(notices.count == expectedNotices.count, "source notification recipients " + label)
            var projected: [String] = []
            for notice in notices {
                try check(notice.payload["automationKind"] == NativeCRMAutomationTasks.notificationKind, "explicit automation template")
                let object: [String: Any] = ["recipient": notice.payload["recipientEmail"]!, "title": notice.payload["taskTitle"]!, "content": notice.payload["taskContent"]!, "due": notice.payload["taskDueAt"]!]
                try check(!notice.payload["taskContent"]!.contains("undefined/crm"), "no broken web URL generated")
                projected.append(String(decoding: try json(object), as: UTF8.self))
            }
            try check(projected.sorted() == expectedNotices.map { String(decoding: try json($0), as: UTF8.self) }.sorted(), "explicit Japanese notice mapping " + label)
            // Durable restart/replay must preserve completed-task dedup as well.
            let reopened = try open("source-\(index)")
            _ = try reopened.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
            try await drain(reopened, env: env, now: now)
            try check(records("crm_Accounts_Tasks", db: reopened).count == actualRows.count, "reopen replay task dedup " + label)
            try check(jobs(reopened, events: ["crm.task_assigned"]).count == notices.count, "reopen replay notice dedup " + label)
        }
        try await edgeCases(open: open, samples: samples, models: models, now: now)
    }
    static func edgeCases(open: (String) throws -> NativeDatabase, samples: [[String: Any]], models: [String], now: Date) async throws {
        let env = NativeCRMRenewalJobs.Environment(appURL: "https://crm.example.invalid", timeZone: TimeZone(secondsFromGMT: 0)!)
        let base = samples[0]["seeds"] as! [String: Any]
        let db = try open("edges"); try seed(base, db: db, models: models)
        let monday = try NativeCRMAutomationDates.parse("2026-03-02T07:00:00.000Z")
        try check(NativeCRMRenewalJobs.nextScheduledDate(after: monday.addingTimeInterval(-1)) == monday, "cron before Monday due")
        try check(NativeCRMRenewalJobs.nextScheduledDate(after: monday) == monday.addingTimeInterval(7 * 86_400), "cron exact boundary advances")
        _ = try NativeCRMRenewalJobs.enqueueDue(db: db, now: monday.addingTimeInterval(-1))
        try check(jobs(db, events: [NativeCRMRenewalJobs.scanEvent]).isEmpty, "initial schedule no retroactive run")
        _ = try NativeCRMRenewalJobs.enqueueDue(db: db, now: now)
        _ = try NativeCRMRenewalJobs.enqueueDue(db: db, now: now)
        try check(jobs(db, events: [NativeCRMRenewalJobs.scanEvent]).count == 1, "same due reservation once")
        _ = try NativeCRMRenewalJobs.enqueueDue(db: db, now: now.addingTimeInterval(50 * 86_400))
        try check(jobs(db, events: [NativeCRMRenewalJobs.scanEvent]).count == 2, "offline weeks coalesced to one current scan")
        // Required name fields cannot be null in valid schema rows. An orphan
        // imported product exercises the same source nullish fallback branch.
        for missing in [false, true] {
            let fallback = try open(missing ? "missing-product" : "literal-product")
            try seed(base, db: fallback, models: models)
            try sql(fallback, missing ? "DELETE FROM crm_Products" : "UPDATE crm_Products SET name='product'")
            _ = try fallback.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
            try await drain(fallback, env: env, now: now)
            let productTask = try records("crm_Accounts_Tasks", db: fallback).first { $0["title"].string.hasPrefix("利用契約の更新") }!
            try check(productTask["title"].string.contains(missing ? "商品 /" : "product /"), "fallback is Japanese but real product name is preserved")
            try check(productTask["content"].string.contains(missing ? "「商品」" : "「product」"), "fallback task content localized")
            if missing {
                let child = try jobs(fallback, events: [NativeCRMRenewalJobs.taskEvent]).first { $0.payload["sourceModel"] == "crm_AccountProducts" }!
                let input = try JSONDecoder().decode(NativeCRMAutomationTaskInput.self, from: Data(child.payload["input"]!.utf8))
                try check(input.canonicalTitle!.contains(": product @"), "source English fallback alias preserved")
                try fallback.update(productTask, changes: ["title": .text(input.canonicalTitle!)], actor: "system")
                _ = try fallback.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
                try await drain(fallback, env: env, now: now)
                try check(records("crm_Accounts_Tasks", db: fallback).count == 2 && jobs(fallback, events: ["crm.task_assigned"]).count == 2, "migrated English fallback task deduplicates")
            }
        }
        // Transaction cancellation after crossing a page boundary leaves no children.
        let large = samples.first { $0["label"] as? String == "page-205" }!
        let cancelled = try open("cancel"); try seed(large["seeds"] as! [String: Any], db: cancelled, models: models)
        let cancelID = try cancelled.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        do { _ = try NativeCRMRenewalJobs.runNext(db: cancelled, environment: env, clock: { now }, checkpoint: { phase, n in if phase == "snapshot" && n == 120 { throw CancellationError() } }); throw Failure.assertion("cancel not thrown") } catch is CancellationError { checks += 1 }
        try check(jobs(cancelled, events: [NativeCRMRenewalJobs.taskEvent]).isEmpty, "cancelled snapshot complete rollback")
        try check(try cancelled.job(id: cancelID)?.status == "retry", "cancelled snapshot remains resumable")
        try await drain(cancelled, env: env, now: now)
        try check(records("crm_Accounts_Tasks", db: cancelled).count == 205, "cancel retry all pages exactly once")
        // Actual SQLite failure while recording a notice rolls back its task too.
        let failed = try open("failure"); try seed(base, db: failed, models: models)
        _ = try failed.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        _ = try NativeCRMRenewalJobs.runNext(db: failed, environment: env, clock: { now })
        try sql(failed, "CREATE TRIGGER fail_notice BEFORE INSERT ON native_outbox WHEN NEW.event='crm.task_assigned' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        _ = try NativeCRMRenewalJobs.runNext(db: failed, environment: env, clock: { now })
        try check(records("crm_Accounts_Tasks", db: failed).isEmpty, "notice failure rolls back paired task")
        try sql(failed, "DROP TRIGGER fail_notice")
        try await drain(failed, env: env, now: now.addingTimeInterval(31))
        try check(records("crm_Accounts_Tasks", db: failed).count == 2, "atomic item retry recovers task and notice")
        try check(jobs(failed, events: ["crm.task_assigned"]).count == 2, "notice retry no duplicates")
        // Independent connections/process-style writer serialization closes the
        // source findFirst/create race without introducing a new lock or table.
        let a = try open("concurrent"), b = try open("concurrent"); try seed(base, db: a, models: models)
        let input = NativeCRMAutomationTaskInput(title: "Concurrent", content: "body", accountID: "c0000000-0000-4000-8000-000000000002", opportunityID: nil, assigneeID: "c0000000-0000-4000-8000-000000000001", due: try NativeCRMAutomationDates.stamp(now), dedupAnyStatus: true)
        let first = Task.detached { try NativeCRMAutomationTasks.create(input, db: a, now: now) }
        let second = Task.detached { try NativeCRMAutomationTasks.create(input, db: b, now: now) }
        let ids = try await [first.value, second.value]
        try check(ids.compactMap { $0 }.count == 1, "two connections one task")
        try check(jobs(a, events: ["crm.task_assigned"]).count == 1, "two connections one notice")
        // Core failure before commit, including callback cancellation, cannot
        // leave an orphan task or publish a queue wake for committed work.
        var visits = 0
        do { _ = try NativeCRMAutomationTasks.create(.init(title: "Rollback", content: "body", accountID: input.accountID, opportunityID: nil, assigneeID: input.assigneeID, due: input.due, dedupAnyStatus: true), db: a, now: now, validate: { visits += 1; if visits == 2 { throw Failure.injected } }); throw Failure.assertion("injected guard not thrown") } catch Failure.injected { checks += 1 }
        try check(records("crm_Accounts_Tasks", db: a).count == 1 && jobs(a, events: ["crm.task_assigned"]).count == 1, "post-create guard rollback")
        let english = "Renewal 2026-03-02: contract \"Existing\"", japanese = "契約更新（2026-03-02）：Existing"
        let old = try a.insert("crm_Accounts_Tasks", values: ["v": .integer(0), "title": .text(japanese), "priority": .text("low"), "taskStatus": .text("COMPLETE"), "account": .text(input.accountID!), "user": .text(input.assigneeID!)], actor: "system")
        let aliasInput = NativeCRMAutomationTaskInput(title: japanese, content: "日本語本文", accountID: input.accountID, opportunityID: nil, assigneeID: input.assigneeID, due: input.due, dedupAnyStatus: true, canonicalTitle: english)
        try check(try NativeCRMAutomationTasks.create(aliasInput, db: a, now: now) == nil, "completed Japanese alias dedup")
        try a.update(old, changes: ["title": .text(english)], actor: "system")
        try check(try NativeCRMAutomationTasks.create(aliasInput, db: a, now: now) == nil, "completed migrated English alias dedup")
        // A real cancelled Swift Task, not just a synthetic thrown error, rolls
        // back a partially materialized scan and finishes without any delivery.
        let actualCancel = try open("actual-cancel"); try seed(base, db: actualCancel, models: models)
        let actualID = try actualCancel.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        let pause = Pause()
        let task = Task.detached { try NativeCRMRenewalJobs.runNext(db: actualCancel, environment: env, clock: { now }, checkpoint: { phase, count in if phase == "snapshot" && count == 1 { pause.stopHere() } }) }
        defer { task.cancel(); pause.release() }
        for _ in 0..<300 { if pause.hasEntered() { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(pause.hasEntered(), "actual cancellation cut point reached")
        task.cancel(); pause.release()
        do { _ = try await task.value; throw Failure.assertion("cancelled Task returned success") } catch is CancellationError { checks += 1 }
        try check(jobs(actualCancel, events: [NativeCRMRenewalJobs.taskEvent, "crm.task_assigned"]).isEmpty, "actual Task cancel leaves no children or notices")
        try check(try actualCancel.job(id: actualID)?.status == "retry", "actual Task cancel releases to resumable retry")
        // Inngest persists step query results: once the native snapshot has
        // committed, subsequent settings/title/due/assignee edits do not rewrite
        // the already reserved input. A new weekly scan will use the new values.
        let frozen = try open("frozen"); try seed(base, db: frozen, models: models)
        _ = try frozen.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        _ = try NativeCRMRenewalJobs.runNext(db: frozen, environment: env, clock: { now })
        let prior = try jobs(frozen, events: [NativeCRMRenewalJobs.taskEvent]).map(\.payload)
        let contract = try records("crm_Contracts", db: frozen)[0]
        try frozen.update(contract, changes: ["title": .text("new title"), "assigned_to": .null, "renewalReminderDate": .text("2040-01-01T00:00:00.000Z")], actor: "system")
        _ = try frozen.insert("crm_FunnelSettings", values: ["renewal_window_days": .integer(1)], actor: "system")
        try await drain(frozen, env: env, now: now)
        try check(jobs(frozen, events: [NativeCRMRenewalJobs.taskEvent]).map(\.payload) == prior, "committed step snapshots immutable")
        let frozenTasks = try records("crm_Accounts_Tasks", db: frozen)
        try check(frozenTasks.count == 2 && frozenTasks.allSatisfy { $0["user"].string == input.assigneeID! && !$0["title"].string.contains("new title") }, "reserved task keeps original assignee/title/date")
        // Deliberately malformed durable input is visible failure, never marked
        // complete and never converted into a blank task/notification.
        let malformed = try frozen.enqueue(NativeCRMRenewalJobs.taskEvent, payload: ["input": "{}"], now: now)
        for step in 0..<5 { _ = try NativeCRMRenewalJobs.runNext(db: frozen, environment: env, clock: { now.addingTimeInterval(Double(step) * 31) }) }
        try check(try frozen.job(id: malformed)?.status == "failed", "bounded attempts expose corrupt item")
        try check(records("crm_Accounts_Tasks", db: frozen).count == 2, "corrupt item never creates blank task")
    }
}
