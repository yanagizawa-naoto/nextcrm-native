import Foundation

@main enum NativeCRMAutomationJobsTests {
    static var checks = 0
    struct Rollback: Error {}
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("accepted: " + label)
    }
    static func main() {
        do { try run(); print("{\"checks\":\(checks),\"exit\":0}") }
        catch { fputs("After \(checks): \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let native = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AutomationMonitor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func open() throws -> NativeDatabase {
            try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: native.appendingPathComponent("schema.json"), sqlURL: native.appendingPathComponent("schema.sql"))
        }
        let db = try open()
        let adminID = UUID().uuidString.lowercased()
        var admin = try db.insert("Users", values: ["id": .text(adminID), "name": .text("隔離管理者"), "email": .text("automation@example.invalid"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: "fixture")
        let service = CRMService(db: db, identity: .init(id: adminID, role: "admin", partnerAccountID: nil))
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        func queued(_ event: String, _ offset: Double = 0) throws -> NativeJob {
            let id = try db.enqueue(event, payload: ["fixture": "monitor"], now: epoch.addingTimeInterval(offset))
            return try db.job(id: id)!
        }
        try check(Set(NativeCRMAutomationJobs.events).count == 10, "ten unique monitored events")
        for event in NativeCRMAutomationJobs.localEvents {
            try check(NativeCRMAutomationJobs.title(event) != "不明な処理", "Japanese title")
            let seed = try queued(event)
            for attempt in 1...5 {
                let running = try db.claimJob(events: [event], now: epoch)!
                try check(running.id == seed.id && running.attempts == attempt, "five automatic attempts")
                try db.failJob(running, message: "検証用の失敗")
                if attempt < 5 { try db.retryJob(id: seed.id, now: epoch) }
            }
            let exhausted = try db.job(id: seed.id)!
            try service.retryCRMAutomationJob(exhausted)
            let reset = try db.job(id: seed.id)!
            try check(reset.status == "pending" && reset.attempts == 0, "manual retry renews local five-attempt budget")
            try check(reset.payload == exhausted.payload && reset.firstAttemptAt == exhausted.firstAttemptAt && reset.result == exhausted.result, "retry preserves identity and payload history")
            try rejects("stale retry CAS") { try service.retryCRMAutomationJob(exhausted) }
            let running = try db.claimJob(events: [event], now: epoch)!
            try check(running.attempts == 1, "retry reaches new first attempt")
            try rejects("cannot cancel in-flight atomic effect") { try service.cancelCRMAutomationJob(running) }
            try db.finishJob(running, result: ["outcome": "fixture"])
            try rejects("completed effect cannot be retried") { try service.retryCRMAutomationJob(try db.job(id: seed.id)!) }
            let cancel = try queued(event, 1)
            do { try db.transaction { try service.cancelCRMAutomationJob(cancel); throw Rollback() } } catch is Rollback {}
            try check(try db.job(id: cancel.id) == cancel, "cancel participates in outer rollback")
            try service.cancelCRMAutomationJob(cancel)
            let cancelled = try db.job(id: cancel.id)!
            try check(cancelled.status == "cancelled" && cancelled.result["cancelledBy"] == adminID, "cancel attribution")
            try check(try db.claimJob(events: [event], now: epoch) == nil, "cancelled work never claimed")
        }
        for event in NativeCRMAutomationJobs.mailEvents + ["crm.task_assigned", "other.event"] {
            let mail = try queued(event)
            try rejects("mail or foreign job cannot enter local cancel") { try service.cancelCRMAutomationJob(mail) }
            let claim = try db.claimJob(events: [event], now: epoch)!
            _ = try db.markJobDeliveryStarted(claim, now: epoch)
            try db.failJob(claim, message: "送信結果未確認")
            let before = try db.job(id: mail.id)!
            try rejects("mail history cannot be reset") { try service.retryCRMAutomationJob(before) }
            try check(try db.job(id: mail.id) == before, "mail fields retained")
        }
        for i in 0..<205 { _ = try queued(NativeCRMAutomationJobs.localEvents[0], Double(i + 20)) }
        let first = try service.crmAutomationJobs(), second = try service.crmAutomationJobs(offset: 100)
        try check(first.count == 100 && second.count == 100, "bounded hundred-row pages")
        try check(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))), "stable disjoint pages")
        try check(try service.crmAutomationJobs(offset: -20) == first, "negative offset clamped")
        try check(first.allSatisfy { NativeCRMAutomationJobs.events.contains($0.event) }, "foreign events excluded")
        let stale = first[0], competitor = try open()
        try competitor.cancelJob(id: stale.id)
        try rejects("second connection changed selected row") { try service.cancelCRMAutomationJob(stale) }
        let retrySeed = try queued(NativeCRMAutomationJobs.localEvents[1], 500)
        let running = try db.claimJob(events: [retrySeed.event], now: epoch.addingTimeInterval(1000))!
        try db.failJob(running, message: "一時失敗")
        let failed = try db.job(id: retrySeed.id)!
        do { try db.transaction { try service.retryCRMAutomationJob(failed); throw Rollback() } } catch is Rollback {}
        try check(try db.job(id: retrySeed.id) == failed, "retry participates in outer rollback")
        for role in ["user", "manager", "partner"] {
            admin = try db.update(admin, changes: ["role": .text(role)], actor: adminID)
            let changed = CRMService(db: db, identity: .init(id: adminID, role: role, partnerAccountID: nil))
            try rejects("role list denied " + role) { _ = try changed.crmAutomationJobs() }
            try rejects("role retry denied " + role) { try changed.retryCRMAutomationJob(failed) }
            try rejects("stale admin denied " + role) { _ = try service.crmAutomationJobs() }
        }
        admin = try db.update(admin, changes: ["role": .text("admin"), "banned": .integer(1)], actor: adminID)
        try rejects("banned admin denied") { _ = try service.crmAutomationJobs() }
        admin = try db.update(admin, changes: ["banned": .integer(0), "userStatus": .text("INACTIVE")], actor: adminID)
        try rejects("inactive admin denied") { try service.retryCRMAutomationJob(failed) }
        _ = try db.update(admin, changes: ["userStatus": .text("ACTIVE")], actor: adminID)
        try check(try service.crmAutomationJobs().count == 100, "fresh restored permission works")
    }
}
