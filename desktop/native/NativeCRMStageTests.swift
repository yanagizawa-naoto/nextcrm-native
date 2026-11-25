import Foundation
import SQLite3

@main enum NativeCRMStageTests {
    static var checks = 0
    enum Failure: Error { case assertion(String), injected }
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws { guard try ok() else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any]) throws -> [String: SQLValue] {
        try object.mapValues { value in
            if value is NSNull { return .null }; if let string = value as? String { return .text(string) }; if let n = value as? NSNumber { return .integer(n.int64Value) }
            return .text(String(decoding: try json(value), as: UTF8.self))
        }
    }
    static func seed(_ fixture: [String: Any], db: NativeDatabase, models: [String]) throws {
        try db.transaction { for model in models { for row in fixture[model] as! [[String: Any]] { _ = try db.insert(model, values: values(row), actor: "system") } } }
    }
    static func rows(_ model: String, db: NativeDatabase) throws -> [NativeRecord] {
        var all: [NativeRecord] = [], after: String?
        while true { let page = try db.keysetPage(model, fields: db.schema.model(model).fields.map(\.name), after: after, includeDeleted: true); if page.isEmpty { return all }; all += page; after = page.last?["id"].string }
    }
    static func jobs(_ db: NativeDatabase, events: [String]) throws -> [NativeJob] {
        var all: [NativeJob] = [], offset = 0
        while true { let page = try db.jobs(events: events, offset: offset); all += page; if page.count < 100 { return all }; offset += page.count }
    }
    static func canonical(_ objects: [[String: Any]], fields: [String]) throws -> [String] {
        try objects.map { row in
            var object = Dictionary(uniqueKeysWithValues: fields.map { ($0, row[$0] ?? NSNull()) })
            if let value = object["dueDateAt"] as? String { object["dueDateAt"] = try NativeCRMAutomationDates.stamp(NativeCRMAutomationDates.parse(value)) }
            return String(decoding: try json(object), as: UTF8.self)
        }.sorted()
    }
    static func sql(_ db: NativeDatabase, _ body: (OpaquePointer) throws -> Void) throws {
        var connection: OpaquePointer?; guard sqlite3_open(db.url.path, &connection) == SQLITE_OK, let connection else { throw Failure.injected }; defer { sqlite3_close(connection) }; try body(connection)
    }
    static func execute(_ db: NativeDatabase, _ text: String) throws {
        try sql(db) { c in guard sqlite3_exec(c, text, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(c))) } }
    }
    static func uid(_ n: Int) -> String { "a0000000-0000-4000-8000-" + String(format: "%012d", n) }
    static func main() async {
        do { try await run(); print("CRM stage formal: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let n = URL(fileURLWithPath: CommandLine.arguments[1]), fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("reference.json"))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-StageCandidate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func open(_ name: String) throws -> NativeDatabase { try NativeDatabase(url: root.appendingPathComponent(name + ".sqlite"), schemaURL: n.appendingPathComponent("schema.json"), sqlURL: n.appendingPathComponent("schema.sql")) }
        let models = reference["models"] as! [String], fields = reference["taskFields"] as! [String]
        for sample in reference["pure"] as! [[String: Any]] {
            let settings = try JSONDecoder().decode(NativeCRMAutomationSettings.self, from: json(sample["settings"]!)), entry = try NativeCRMAutomationDates.parse(sample["entry"] as! String)
            for (i, expected) in (sample["result"] as! [[String: Any]]).enumerated() {
                let touch = try NativeCRMStageSchedule.touch(kind: "qualified", index: i, entry: entry, settings: settings)!
                try check(try JSONEncoder().encode(touch).isEmpty == false, "schedule Codable")
                try check(touch.title == expected["title"] as! String && touch.content == expected["content"] as! String && touch.due == expected["due"] as! String, "actual source business-day schedule")
            }
        }
        let samples = reference["cases"] as! [[String: Any]]
        for (i, sample) in samples.enumerated() {
            let db = try open("source-\(i)"), label = sample["label"] as! String
            try seed(sample["seeds"] as! [String: Any], db: db, models: models)
            var now = try NativeCRMAutomationDates.parse(sample["entry"] as! String)
            let parent = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: sample["toStage"] as! String, now: now)
            try check(try NativeCRMStageJobs.runNext(db: db, clock: { now }), "transition consumed " + label)
            try check(try db.job(id: parent)?.status == "done", "transition not silently failed " + label)
            let actions = sample["actions"] as! [[String: Any]]
            for sleep in sample["sleeps"] as! [[String: Any]] {
                let index = sleep["index"] as! Int
                now = try NativeCRMAutomationDates.parse(sleep["executedAt"] as! String)
                let pending = try jobs(db, events: [NativeCRMStageJobs.touchEvent]).filter { $0.status == "pending" }
                try check(pending.count == 1, "one sequential reservation " + label)
                if let due = pending.first?.nextRunAt { try check(try NativeCRMAutomationDates.parse(due) <= now, "due respects sequential sleepUntil " + label) }
                var cancelled = false
                for action in actions where action["at"] as? Int == index {
                    if action["cancel"] as? Bool == true {
                        _ = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(12), now: now)
                        cancelled = true
                    }
                    if action["remove"] as? Bool == true { try db.remove(db.get("crm_Opportunities", key: ["id": .text(uid(30))])!, actor: "system") }
                    if let changes = action["values"] as? [String: Any] { try db.update(db.get("crm_Opportunities", key: ["id": .text(uid(30))])!, changes: values(changes), actor: "system") }
                    if let settings = action["settings"] as? [String: Any] {
                        if let row = try rows("crm_FunnelSettings", db: db).first { try db.update(row, changes: values(settings), actor: "system") }
                        else { _ = try db.insert("crm_FunnelSettings", values: values(settings), actor: "system") }
                    }
                }
                try check(try NativeCRMStageJobs.runNext(db: db, clock: { now }), "due step or cancellation consumed " + label)
                if cancelled { break }
            }
            let actual = try rows("crm_Accounts_Tasks", db: db)
            try check(canonical(actual.map { $0.values.mapValues(\.json) }, fields: fields) == canonical(sample["tasks"] as! [[String: Any]], fields: fields), "source + Japanese task mapping " + label)
            let notices = try jobs(db, events: ["crm.task_assigned"])
            try check(notices.compactMap { $0.payload["recipientEmail"] }.sorted() == sample["recipients"] as! [String], "source recipient intents " + label)
            try check(notices.count == sample["created"] as! Int, "source created count " + label)
            for notice in notices {
                let task = actual.first { $0["id"].string == notice.payload["taskId"] }!
                try check(notice.payload["taskTitle"] == task["title"].string && notice.payload["taskContent"] == task["content"].string, "Japanese notification gets exact generated content")
                try check(try NativeCRMAutomationDates.parse(notice.payload["taskDueAt"]!) == NativeCRMAutomationDates.parse(task["dueDateAt"].string), "notification preserves source due instant")
            }
            try check(jobs(db, events: NativeCRMStageJobs.events).allSatisfy { ["done", "cancelled"].contains($0.status) }, "no orphan failed/future steps " + label)
        }
        try corruptSettings(open: open, seeds: samples[0]["seeds"] as! [String: Any], models: models)
        try await generations(open: open, seeds: samples[0]["seeds"] as! [String: Any], models: models)
        #if STAGE_PRODUCER_TESTS
        try await producerChecks(native: n, open: open)
        #endif
    }
    static func corruptSettings(open: (String) throws -> NativeDatabase, seeds: [String: Any], models: [String]) throws {
        let defaults = NativeCRMAutomationSettings()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as! [String: Any]
        try check(object.count == 12, "all twelve durable settings covered")
        for field in object.keys.sorted() {
            for invalid in [Int(Int32.max) + 1, Int(Int32.min) - 1, Int.max] {
                var changed = object; changed[field] = invalid
                let settings = try JSONDecoder().decode(NativeCRMAutomationSettings.self, from: json(changed))
                var rejected = false
                do { _ = try NativeCRMStageSchedule.count(kind: "care", settings: settings) } catch { rejected = true }
                try check(rejected, "corrupt durable setting rejected before arithmetic: " + field)
            }
        }
        var extreme = defaults; extreme.careQuarterCount = Int(Int32.max)
        try check(try NativeCRMStageSchedule.count(kind: "care", settings: extreme) == Int(Int32.max) + 2, "valid imported Int32 count is not clamped to UI24")
        extreme.careQuarterCount = Int(Int32.min)
        try check(try NativeCRMStageSchedule.count(kind: "care", settings: extreme) == 2, "source negative imported count yields no quarters")
        let now = try NativeCRMAutomationDates.parse("2026-03-06T07:00:00.123Z")
        for count in [Int.max, Int(Int32.max)] {
            var rejected = false
            do { _ = try NativeCRMStageSchedule.addBusinessDays(now, count: count) } catch { rejected = true }
            try check(rejected, "extreme date fails visibly without trapping")
        }
        let db = try open("corrupt-settings"); try seed(seeds, db: db, models: models)
        let head = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(10), now: now)
        _ = try NativeCRMStageJobs.runNext(db: db, clock: { now })
        // A corrupt persisted payload is a different boundary from validated DB
        // fields. It must exhaust ordinary bounded retries, not terminate Swift.
        var bad = object; bad["careQuarterCount"] = Int.max
        let state: [String: Any] = ["recordID": uid(30), "stageEventID": head, "kind": "care", "entry": try NativeCRMAutomationDates.stamp(now), "settings": bad, "index": 2]
        let job = try db.enqueue(NativeCRMStageJobs.touchEvent, payload: ["record_id": uid(30), "stageEventID": head, "state": String(decoding: try json(state), as: UTF8.self)], now: now)
        for attempt in 0..<5 { try check(try NativeCRMStageJobs.runNext(db: db, clock: { now.addingTimeInterval(Double(attempt) * 31) }), "corrupt state retry consumed") }
        try check(try db.job(id: job)?.status == "failed" && db.job(id: job)?.attempts == 5, "bad state reaches visible failed status")
        try check(rows("crm_Accounts_Tasks", db: db).isEmpty && jobs(db, events: ["crm.task_assigned"]).isEmpty, "bad state creates no effects")
    }
    static func generations(open: (String) throws -> NativeDatabase, seeds: [String: Any], models: [String]) async throws {
        let db = try open("generation"), now = try NativeCRMAutomationDates.parse("2026-03-06T07:00:00.123Z")
        try seed(seeds, db: db, models: models)
        let first = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(10), now: now)
        _ = try NativeCRMStageJobs.runNext(db: db, clock: { now })
        let old = try jobs(db, events: [NativeCRMStageJobs.touchEvent])[0]
        let second = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(11), now: now)
        let third = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(10), now: now)
        try check(first != second && second != third && db.opportunityStageEventHead(recordID: uid(30)) == third, "same-millisecond A-B-A durable head")
        try check(try db.opportunityStageEventTimestamp(recordID: uid(30), eventID: first) == nil, "superseded timestamp is not accepted")
        try check(try db.job(id: old.id)?.status == "cancelled", "producer atomically cancels obsolete reservation")
        while try NativeCRMStageJobs.runNext(db: db, clock: { now }) {}
        let live = try jobs(db, events: [NativeCRMStageJobs.touchEvent]).filter { $0.status == "pending" }
        try check(live.count == 1 && live[0].payload["stageEventID"] == third, "only newest generation reserves")
        try check(try db.job(id: second)?.result["status"] == "superseded", "older queued source event cannot overwrite head")
        // Old outbox retention does not erase the current durable generation.
        try execute(db, "DELETE FROM native_outbox WHERE event='crm/opportunity.stage-changed'")
        try check(try db.opportunityStageEventHead(recordID: uid(30)) == third, "head survives source receipt retention")
        try check(try db.opportunityStageEventTimestamp(recordID: uid(30), eventID: third) == NativeCRMAutomationDates.stamp(now), "private timestamp survives source receipt retention")
        let due = try NativeCRMAutomationDates.parse(live[0].nextRunAt!)
        _ = try NativeCRMStageJobs.runNext(db: db, clock: { due })
        try check(rows("crm_Accounts_Tasks", db: db).count == 1, "touch works after old event rows removed")
        let headBefore = try db.opportunityStageEventHead(recordID: uid(30)), countBefore = try jobs(db, events: NativeCRMStageJobs.events).count
        do { try db.transaction { _ = try db.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(11), now: due); throw Failure.injected } } catch Failure.injected { checks += 1 }
        try check(try db.opportunityStageEventHead(recordID: uid(30)) == headBefore && jobs(db, events: NativeCRMStageJobs.events).count == countBefore, "outer rollback restores event/head/cancellation")
        // Existing unconsumed event migration chooses insertion order, including
        // identical creation timestamps, and subsequently needs no outbox scan.
        let legacy = try open("legacy"); try seed(seeds, db: legacy, models: models)
        try legacy.transaction {
            for i in 0..<500 { _ = try legacy.enqueue("crm/opportunity.stage-changed", payload: ["record_id": uid(1000 + i), "to_stage": uid(10)], now: now) }
        }
        _ = try legacy.enqueue("crm/opportunity.stage-changed", payload: ["record_id": uid(30), "to_stage": uid(11)], now: now)
        let newest = try legacy.enqueue("crm/opportunity.stage-changed", payload: ["record_id": uid(30), "to_stage": uid(10)], now: now)
        try check(try legacy.opportunityStageEventHead(recordID: uid(30).uppercased()) == newest, "legacy same-second latest head and typed UUID casing")
        try check(try legacy.opportunityStageEventTimestamp(recordID: uid(30), eventID: newest) == legacy.job(id: newest)?.createdAt, "legacy created_at precision is retained")
        try sql(legacy) { c in
            var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
            let query = "SELECT id FROM native_outbox WHERE event='crm/opportunity.stage-changed' AND lower(CASE WHEN json_valid(payload) THEN json_extract(payload,'$.record_id') END)=lower(?) ORDER BY rowid DESC LIMIT 1"
            try check(sqlite3_prepare_v2(c, query, -1, &statement, nil) == SQLITE_OK, "legacy indexed query prepares")
            _ = uid(30).withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            try check(sqlite3_step(statement) == SQLITE_ROW, "legacy indexed row exists")
            try check(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0) == 0, "legacy migration query no table scan after index")
            try check(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_SORT, 0) == 0, "legacy migration query no sort materialization")
        }
        // Real cancellation after task insertion must also roll back the next
        // sequential reservation, retaining exactly one retryable owned item.
        let cancel = try open("cancel"); try seed(seeds, db: cancel, models: models)
        _ = try cancel.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(10), now: now)
        _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { now })
        let item = try jobs(cancel, events: [NativeCRMStageJobs.touchEvent])[0], when = try NativeCRMAutomationDates.parse(item.nextRunAt!)
        do { _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { when }, checkpoint: { if $0 == "commit" { throw CancellationError() } }); throw Failure.assertion("no cancellation") } catch is CancellationError { checks += 1 }
        try check(rows("crm_Accounts_Tasks", db: cancel).isEmpty && jobs(cancel, events: ["crm.task_assigned"]).isEmpty, "cancel rolls back task/notice")
        try check(jobs(cancel, events: [NativeCRMStageJobs.touchEvent]).count == 1 && cancel.job(id: item.id)?.status == "retry", "cancel rolls back successor")
        _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { when })
        try check(rows("crm_Accounts_Tasks", db: cancel).count == 1, "cancel retry exactly one task")
        // Re-entry with a completed original-language title creates a new task;
        // an open Japanese title deduplicates within the same opportunity.
        let created = try rows("crm_Accounts_Tasks", db: cancel)[0]
        try cancel.update(created, changes: ["taskStatus": .text("COMPLETE")], actor: "system")
        _ = try cancel.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(10), now: now)
        _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { now })
        _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { when })
        try check(rows("crm_Accounts_Tasks", db: cancel).count == 2, "completed task allows new entry")
        _ = try cancel.enqueueOpportunityStageChange(recordID: uid(30), toStage: uid(10), now: now)
        _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { now }); _ = try NativeCRMStageJobs.runNext(db: cancel, clock: { when })
        try check(rows("crm_Accounts_Tasks", db: cancel).count == 2, "open Japanese task suppresses duplicate entry")
        await runtimeChecks(db: cancel, now: when)
    }
    @MainActor static func runtimeChecks(db: NativeDatabase, now: Date) async {
        let owner = NativeCRMAutomationRuntime(db: db, environment: .init(appURL: nil), clock: { now })
        owner.stop(); owner.resume(); await owner.stopAndDrain(); await owner.stopAndDrain()
        if owner.isStopped && !owner.isRunning { checks += 1 }
        else { fatalError("terminal stage runtime restarted") }
    }
}
