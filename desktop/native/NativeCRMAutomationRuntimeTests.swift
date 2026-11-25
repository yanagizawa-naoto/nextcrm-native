import Foundation
import SQLite3

@main enum NativeCRMAutomationRuntimeTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    final class Pause {
        private let condition = NSCondition(); private var waiting = false, released = false
        func block() { condition.lock(); waiting = true; condition.broadcast(); while !released { condition.wait() }; condition.unlock() }
        var entered: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws { guard try ok() else { throw Failure.assertion(label) }; checks += 1 }
    static func main() async {
        do { try await run(); print("All-five CRM automation runtime: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let n = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AllAutomation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: n.appendingPathComponent("schema.json"), sqlURL: n.appendingPathComponent("schema.sql")), now = Date()
        let user = try db.insert("Users", values: ["name": .text("管理担当者"), "email": .text("automation@example.invalid"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: "system")
        let account = try db.insert("crm_Accounts", values: ["v": .integer(0), "name": .text("自動処理の取引先"), "assigned_to": user["id"]], actor: "system")
        let qualified = try db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("見積"), "stage_kind": .text("qualified")], actor: "system")
        let care = try db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("導入後"), "stage_kind": .text("care")], actor: "system")
        func opportunity(_ name: String, stage: NativeRecord, days: Double, event: Bool) throws -> NativeRecord {
            let entry = now.addingTimeInterval(-days * 86_400)
            return try db.transaction {
                let record = try db.insert("crm_Opportunities", values: ["name": .text(name), "status": .text("ACTIVE"), "approval_status": .text("APPROVED"), "account": account["id"], "sales_stage": stage["id"], "assigned_to": user["id"], "stage_entered_at": .text(NativeCRMAutomationDates.stamp(entry))], actor: "system")
                if event { _ = try db.enqueueOpportunityStageChange(recordID: record["id"].string, toStage: stage["id"].string, now: entry) }
                return record
            }
        }
        let follow = try opportunity("見積後の案件", stage: qualified, days: 7, event: true)
        let cared = try opportunity("導入後の案件", stage: care, days: 35, event: true)
        let inactive = try opportunity("返信待ちの案件", stage: qualified, days: 46, event: false)
        let contract = try db.insert("crm_Contracts", values: ["v": .integer(0), "title": .text("保守契約"), "value": .text("100"), "account": account["id"], "assigned_to": user["id"], "renewalReminderDate": .text(NativeCRMAutomationDates.stamp(now.addingTimeInterval(2 * 86_400)))], actor: "system")
        let template = try db.insert("crm_campaign_templates", values: ["name": .text("過去の案内"), "content_html": .text("<p>案内</p>"), "content_json": .text("{}")], actor: "system")
        let campaign = try db.insert("crm_campaigns", values: ["v": .integer(0), "name": .text("過去のキャンペーン")], actor: "system")
        let step = try db.insert("crm_campaign_steps", values: ["campaign_id": campaign["id"], "order": .integer(1), "template_id": template["id"], "subject": .text("最終案内")], actor: "system")
        let target = try db.insert("crm_Targets", values: ["last_name": .text("再開する対象"), "email": .text("target@example.invalid"), "tags": .text("[]"), "notes": .text("[]")], actor: "system")
        _ = try db.insert("crm_campaign_sends", values: ["campaign_id": campaign["id"], "step_id": step["id"], "target_id": target["id"], "email": target["email"], "status": .text("sent"), "sent_at": .text(NativeCRMAutomationDates.stamp(now.addingTimeInterval(-100 * 86_400)))], actor: "system")
        for event in [NativeCRMRenewalJobs.scanEvent, NativeCRMSweepJobs.killScan, NativeCRMSweepJobs.recycleScan] { _ = try db.enqueue(event, payload: [:], now: now) }
        let owner = NativeCRMAutomationRuntime(db: db, environment: .init(appURL: nil, timeZone: TimeZone(secondsFromGMT: 0)!), clock: { now })
        var errors: [String] = []; owner.onError = { errors.append($0.localizedDescription) }; owner.resume()
        for _ in 0..<1000 {
            if try db.keysetPage("crm_Accounts_Tasks", fields: []).count == 3,
               try db.get("crm_Opportunities", key: ["id": inactive["id"]])?["status"] == .text("CLOSED"),
               try db.page("TargetsToTargetLists", fields: [], equal: ["target_id": target["id"]]).total == 1,
               !owner.isRunning, !owner.isScanning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(errors.isEmpty, "no runtime scheduler errors")
        try check(db.keysetPage("crm_Accounts_Tasks", fields: []).count == 3, "renewal plus qualified and care all consumed")
        try check(db.get("crm_Opportunities", key: ["id": inactive["id"]])?["status"] == .text("CLOSED"), "kill sweep actually closes inactive opportunity")
        try check(db.page("TargetsToTargetLists", fields: [], equal: ["target_id": target["id"]]).total == 1, "recycle sweep actually adds membership")
        let membership = try db.page("TargetsToTargetLists", fields: ["target_list_id"], equal: ["target_id": target["id"]]).rows[0]
        try check(db.get("crm_TargetLists", key: ["id": membership["target_list_id"]])?["name"] == .text("再開対象"), "new system recycle list is Japanese")
        try check(db.get("crm_Opportunities", key: ["id": follow["id"]])?["status"] == .text("ACTIVE") && db.get("crm_Opportunities", key: ["id": cared["id"]])?["status"] == .text("ACTIVE"), "recent stage work not killed")
        let tasks = try db.keysetPage("crm_Accounts_Tasks", fields: ["title", "content", "dueDateAt"])
        try check(tasks.allSatisfy { !$0["title"].string.hasPrefix("Care:") && !$0["title"].string.hasPrefix("Cadence") && !$0["title"].string.hasPrefix("Renewal") }, "all source-owned task titles Japanese")
        let link = try NativeCRMContractLink(contractID: contract["id"].string).string
        try check(tasks.contains { $0["content"].string.contains(link) }, "renewal has actual typed native contract link")
        try check(tasks.allSatisfy { !$0["content"].string.contains("undefined/") }, "native body has no undefined public URL")
        let localEvents = NativeCRMStageJobs.events + NativeCRMRenewalJobs.events + NativeCRMSweepJobs.events
        let beforeMail = try db.jobs(events: ["crm.task_assigned"] + NativeCRMSweepJobs.mailEvents)
        try check(beforeMail.count == 5 && beforeMail.allSatisfy { $0.status == "pending" && $0.deliveryStartedAt == nil }, "all five notices queued without external delivery")
        try check(owner.nextScan != nil, "next daily/weekly scheduler wake retained")
        await owner.stopAndDrain(); await owner.stopAndDrain()
        try check(owner.isStopped && !owner.isRunning && !owner.isScanning && owner.nextScan == nil, "all local consumers and scheduler fully drained")
        // Separate delivery boundary: fake actual workers consume the intents
        // only after explicit admission here. No credentials are read externally.
        var bodies: [String] = []
        let request: ResendMailClient.Request = { query, file in
            let data = try Data(contentsOf: file), json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            bodies.append(json["text"] as! String)
            return (try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString.lowercased()]), HTTPURLResponse(url: query.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let accountClosure: () throws -> InvoiceMailAccount = { .init(from: "crm@example.invalid", apiKey: "synthetic-not-a-key") }
        let taskWorker = CRMTaskMailWorker(db: db, account: accountClosure, request: request, clock: { now })
        let sweepWorker = NativeCRMSweepMailWorker(db: db, account: accountClosure, request: request, clock: { now })
        while try await taskWorker.runNext() {}
        while try await sweepWorker.runNext() {}
        try check(bodies.count == 5, "actual mail workers deliver all five fake messages")
        try check(db.jobs(events: ["crm.task_assigned"] + NativeCRMSweepJobs.mailEvents).allSatisfy { $0.status == "done" }, "all fake receipt outcomes persisted")
        let late = try db.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        owner.resume(); try await Task.sleep(nanoseconds: 30_000_000)
        try check(db.job(id: late)?.status == "pending", "late commit notification cannot restart stopped owner")
        try check(!localEvents.contains(where: NativeCRMSweepJobs.mailEvents.contains), "generation and external-delivery event sets disjoint")
        // More than one metadata page advances through the existing timer;
        // unknown owners remain held and do not cause an endless immediate pass.
        let recipient = try db.jobs(events: [NativeCRMSweepJobs.recycleNotice])[0]
        let recipientKey = NativeCRMSweepJobs.snapshotKey(recipient.id, "recipient", 0)
        try check(try db.metadata(recipientKey) != nil, "pending/just-completed notice snapshot remains until bounded cleanup")
        let unknown = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        try db.transaction { for i in 0..<150 { try db.setMetadata(NativeCRMSweepJobs.snapshotKey(unknown, "recipient", i), value: "synthetic-held") } }
        let cleanupOwner = NativeCRMAutomationRuntime(db: db, environment: .init(appURL: nil), clock: { now })
        var cleanupErrors: [String] = []; cleanupOwner.onError = { cleanupErrors.append($0.localizedDescription) }; cleanupOwner.resume()
        for _ in 0..<200 { if !cleanupOwner.isScanning { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(try db.crmAutomationSnapshotRetentionCursor() != nil, "first100page keeps a durable cursor")
        try check(cleanupOwner.nextScan != nil && cleanupOwner.nextScan! <= now.addingTimeInterval(1), "remaining page uses short existing scheduler wake")
        for _ in 0..<300 {
            if try db.crmAutomationSnapshotRetentionCursor() == nil, !cleanupOwner.isScanning,
               let due = cleanupOwner.nextScan, due > now.addingTimeInterval(1) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(cleanupErrors.isEmpty && db.crmAutomationSnapshotRetentionCursor() == nil, "timer drains finite pass without repeated errors")
        try check(cleanupOwner.nextScan != nil && cleanupOwner.nextScan! > now.addingTimeInterval(1), "held-only end returns to normal daily/weekly due")
        try check(try db.metadata(recipientKey) == nil && db.job(id: recipient.id) == recipient, "finished recipient snapshot released while exact receipt stays")
        var held = 0, after: String?
        while true { let page = try db.crmAutomationSnapshotPage(ownerID: unknown, kind: "recipient", after: after); held += page.count; if page.count < 100 { break }; after = page.last!.key }
        try check(held == 150, "unknown snapshot rows remain preserved across all pages")
        await cleanupOwner.stopAndDrain()
        try check(!cleanupOwner.isScanning && !cleanupOwner.isRunning && cleanupOwner.nextScan == nil, "cleanup wake shares normal owner join")
        // A scan/consumer blocked behind accepted DB work is still owned. Both
        // concurrent drains (including a cancelled caller) wait for real join.
        let blockedDB = try NativeDatabase(url: root.appendingPathComponent("blocked.sqlite"), schemaURL: n.appendingPathComponent("schema.json"), sqlURL: n.appendingPathComponent("schema.sql"))
        let pause = Pause(), holder = Task.detached { try blockedDB.transaction { pause.block() } }
        defer { pause.release(); holder.cancel() }
        for _ in 0..<200 { if pause.entered { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try check(pause.entered, "owned concurrent writer entered")
        let blocked = NativeCRMAutomationRuntime(db: blockedDB, environment: .init(appURL: nil), clock: { now })
        blocked.resume(); blocked.resume(); try check(blocked.isScanning, "resume coalesces an owned scan")
        var joined = 0
        let drainA = Task { @MainActor in await blocked.stopAndDrain(); joined += 1 }
        let drainB = Task { @MainActor in await blocked.stopAndDrain(); joined += 1 }
        drainA.cancel()
        try await Task.sleep(nanoseconds: 15_000_000)
        try check(joined == 0 && blocked.isStopped, "cancelled caller cannot abandon in-flight work")
        pause.release(); try await holder.value; await drainA.value; await drainB.value
        try check(joined == 2 && !blocked.isScanning && !blocked.isRunning, "both drains join exact work")
        try check(try blockedDB.metadata(NativeCRMRenewalJobs.cursorKey) == nil, "cancelled scheduler transaction did not commit cursor")
        blocked.resume(); try await Task.sleep(nanoseconds: 5_000_000)
        try check(blocked.nextScan == nil && !blocked.isScanning, "terminal stop rejects later resume")
        // Error callbacks may synchronously stop/resume their owner. No late
        // scheduler completion or another runner may re-open admission.
        func sealedURL() throws -> URL {
            let destination = root.appendingPathComponent("sealed.sqlite")
            var input: OpaquePointer?, output: OpaquePointer?
            defer { sqlite3_close(input); sqlite3_close(output) }
            guard sqlite3_open_v2(blockedDB.url.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  sqlite3_open(destination.path, &output) == SQLITE_OK,
                  let backup = sqlite3_backup_init(output, "main", input, "main") else { throw Failure.assertion("sealed fixture open") }
            let code = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
            guard code == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.assertion("sealed fixture backup") }
            let closedInput = sqlite3_close(input), closedOutput = sqlite3_close(output); input = nil; output = nil
            guard closedInput == SQLITE_OK, closedOutput == SQLITE_OK else { throw Failure.assertion("sealed fixture close") }
            // Same fresh SQLite backup/close path as CredentialReadOnlyTests;
            // no live-file copy, manual sidecar removal or guard relaxation.
            return destination
        }
        let sealed = try sealedURL()
        for suffix in ["-wal", "-shm", "-journal"] {
            var st = stat(); let rc = lstat(sealed.path + suffix, &st), err = errno
            try check(rc != 0 && err == ENOENT, "readonly fixture excludes SQLite sidecars")
        }
        let readonly = try NativeDatabase(readOnlyURL: sealed, schemaURL: n.appendingPathComponent("schema.json"))
        let reentrant = NativeCRMAutomationRuntime(db: readonly, environment: .init(appURL: nil))
        var errorsSeen = 0
        reentrant.onError = { _ in errorsSeen += 1; reentrant.stop(); reentrant.resume() }
        reentrant.resume()
        for _ in 0..<200 { if reentrant.isStopped { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        await reentrant.stopAndDrain()
        try check(errorsSeen == 1 && reentrant.isStopped, "one error callback can close all owner admission")
        try check(reentrant.nextScan == nil && !reentrant.isScanning && !reentrant.isRunning, "reentrant error cannot leave timer or unfinished runner")
        reentrant.onError = nil

    }
}
