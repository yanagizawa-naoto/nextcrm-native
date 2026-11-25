import Foundation

@main enum NativeCRMStageLeaseTests {
    static var checks = 0
    enum Failure: Error { case assertion(String), injected }
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws { guard try value() else { throw Failure.assertion(name) }; checks += 1 }
    static func main() throws {
        let n = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-StageLease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: n.appendingPathComponent("schema.json"), sqlURL: n.appendingPathComponent("schema.sql")) }
        let a = try open(), b = try open(), now = Date(timeIntervalSince1970: 1_800_000_000.123)
        let user = try a.insert("Users", values: ["email": .text("lease@example.invalid"), "role": .text("admin")], actor: "system")
        let first = try a.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("見積"), "stage_kind": .text("qualified")], actor: "system")
        let next = try a.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("導入後"), "stage_kind": .text("care")], actor: "system")
        let opp = try a.insert("crm_Opportunities", values: ["name": .text("世代検証"), "sales_stage": first["id"], "assigned_to": user["id"]], actor: "system")
        _ = try a.enqueueOpportunityStageChange(recordID: opp["id"].string, toStage: first["id"].string, now: now)
        _ = try NativeCRMStageJobs.runNext(db: a, clock: { now })
        let pending = try a.jobs(events: [NativeCRMStageJobs.touchEvent])[0]
        let due = try NativeCRMAutomationDates.parse(pending.nextRunAt!), running = try a.claimJob(events: [NativeCRMStageJobs.touchEvent], now: due)!
        try check(running.status == "running" && running.leaseToken != nil, "actual old touch lease claimed")
        let latest = try b.transaction { () -> String in
            try b.update(b.get(opp.model, key: ["id": opp["id"]])!, changes: ["sales_stage": next["id"]], actor: "system")
            return try b.enqueueOpportunityStageChange(recordID: opp["id"].string, toStage: next["id"].string, now: due)
        }
        let cancelled = try a.job(id: running.id)!
        try check(cancelled.status == "cancelled" && cancelled.leaseToken == nil && cancelled.nextRunAt == nil, "independent connection cancels running lease atomically")
        do { _ = try a.requireJobLease(running); throw Failure.assertion("stale lease accepted") } catch NativeDBError.conflict { checks += 1 }
        let input = NativeCRMAutomationTaskInput(title: "古い予定", content: "保存されない本文", accountID: nil, opportunityID: opp["id"].string, assigneeID: user["id"].string, due: try NativeCRMAutomationDates.stamp(due), dedupAnyStatus: false)
        do { _ = try NativeCRMAutomationTasks.create(input, db: a, now: due, validate: { _ = try a.requireJobLease(running) }); throw Failure.assertion("stale task committed") } catch NativeDBError.conflict { checks += 1 }
        try check(a.keysetPage("crm_Accounts_Tasks", fields: []).isEmpty && a.jobs(events: ["crm.task_assigned"]).isEmpty, "stale callback cannot create task or notice")
        let c = try open()
        try check(try c.opportunityStageEventHead(recordID: opp["id"].string) == latest, "new head survives fresh connection")
        let before = try c.get(opp.model, key: ["id": opp["id"]])!
        do { try b.transaction { try b.update(before, changes: ["sales_stage": first["id"]], actor: "system"); _ = try b.enqueueOpportunityStageChange(recordID: opp["id"].string, toStage: first["id"].string, now: due); throw Failure.injected } } catch Failure.injected { checks += 1 }
        try check(try c.opportunityStageEventHead(recordID: opp["id"].string) == latest && c.get(opp.model, key: ["id": opp["id"]])?.values == before.values, "competing rollback cannot replace live head")
        _ = try NativeCRMStageJobs.runNext(db: c, clock: { due })
        let current = try c.jobs(events: [NativeCRMStageJobs.touchEvent]).filter { $0.status == "pending" }
        try check(current.count == 1 && current[0].payload["stageEventID"] == latest, "new consumer reserves only current generation")
        print("CRM stage lease: \(checks) checks passed")
    }
}
