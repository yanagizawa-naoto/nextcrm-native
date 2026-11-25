import Foundation

@main enum NativeCRMAutomationMailTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws { guard try ok() else { throw Failure.assertion(label) }; checks += 1 }
    static func main() async {
        do { try await run(); print("CRM automation mail/runtime formal: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let native = URL(fileURLWithPath: CommandLine.arguments[1]), fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("reference.json"))) as! [String: Any]
        let base = (reference["cases"] as! [[String: Any]])[0]["seeds"] as! [String: [[String: Any]]]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AutomationMail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: native.appendingPathComponent("schema.json"), sqlURL: native.appendingPathComponent("schema.sql")) }
        let db = try open()
        for name in reference["models"] as! [String] { for row in base[name] ?? [] {
            let values = try row.mapValues { item -> SQLValue in
                if item is NSNull { return .null }; if let text = item as? String { return .text(text) }; if let n = item as? NSNumber { return .integer(n.int64Value) }
                return .text(String(decoding: try JSONSerialization.data(withJSONObject: item), as: UTF8.self))
            }
            _ = try db.insert(name, values: values, actor: "system")
        } }
        let user = "c0000000-0000-4000-8000-000000000001", account = "c0000000-0000-4000-8000-000000000002"
        var now = try NativeCRMAutomationDates.parse(reference["epoch"] as! String), status = 200, calls = 0
        var bodies: [Data] = [], keys: [String] = []
        let provider = "e0000000-0000-4000-8000-000000000001"
        let request: ResendMailClient.Request = { query, file in
            calls += 1; bodies.append(try Data(contentsOf: file)); keys.append(query.value(forHTTPHeaderField: "Idempotency-Key")!)
            return (try JSONSerialization.data(withJSONObject: status == 200 ? ["id": provider] : ["name": "synthetic_error"]), HTTPURLResponse(url: query.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func worker(_ database: NativeDatabase = db) -> CRMTaskMailWorker { .init(db: database, account: { .init(from: "crm@example.invalid", apiKey: "synthetic-not-a-key") }, request: request, clock: { now }) }
        func create(_ title: String, _ content: String = "契約の更新条件を確認してください。\n二行目と絵文字🌸") throws -> String {
            try NativeCRMAutomationTasks.create(.init(title: title, content: content, accountID: account, opportunityID: nil, assigneeID: user, due: NativeCRMAutomationDates.stamp(now), dedupAnyStatus: true), db: db, now: now)!
        }
        func job(_ task: String) throws -> NativeJob { try db.jobs(events: ["crm.task_assigned"], taskID: task)[0] }
        func body() throws -> [String: Any] { try JSONSerialization.jsonObject(with: bodies.last!) as! [String: Any] }
        let id = try create("契約更新の確認"), first = try job(id)
        try check(first.payload["actorId"] == first.payload["recipientId"], "source self-assignee notification is not suppressed")
        let consumed = try await worker().runNext(); try check(consumed, "actual production worker consumed notice")
        let message = try body(), text = message["text"] as! String
        try check(message["subject"] as? String == "新しいCRMタスク：契約更新の確認", "Japanese notification subject")
        try check(text.contains("営業フローにより") && text.contains(first.payload["taskContent"]!), "original body present without manual-creator claim")
        try check(text.contains("期限：2026年3月2日") && text.contains("次回") == false, "due date retained in readable Japanese")
        try check(text.contains(try NativeCRMTaskLink(taskID: id).string), "native record link retained")
        try check(try db.job(id: first.id)?.status == "done", "provider receipt completed")
        try check(!FileManager.default.fileExists(atPath: try InvoiceMail.bodyURL(root: root, id: first.id).path), "terminal body cleanup preserved")
        // A retry uses the frozen intended body/due even if the task changes.
        let retryTask = try create("再試行時の本文"), retry = try job(retryTask); status = 500
        _ = try await worker().runNext(); let frozen = bodies.last!, key = keys.last!
        try check(try db.job(id: retry.id)?.status == "retry", "retry recorded by existing worker")
        try db.update(db.get("crm_Accounts_Tasks", key: ["id": .text(retryTask)])!, changes: ["content": .text("後から変えた本文"), "dueDateAt": .text("2040-01-01T00:00:00.000Z")], actor: user)
        now = now.addingTimeInterval(120); status = 200
        _ = try await worker(try open()).runNext()
        try check(bodies.last == frozen && keys.last == key, "restart frozen body and idempotency key")
        // Existing fresh recipient/access checks still guard automated notices.
        let staleTask = try create("宛先変更"), stale = try job(staleTask), before = calls
        try db.update(db.get("Users", key: ["id": .text(user)])!, changes: ["email": .text("changed@example.invalid")], actor: user)
        _ = try await worker().runNext()
        try check(calls == before && db.job(id: stale.id)?.result["outcome"] == "skipped", "changed recipient not sent")
        try db.update(db.get("Users", key: ["id": .text(user)])!, changes: ["email": .text("owner@example.invalid")], actor: user)
        // Manual creation follows the exact old template; only explicit known
        // automation jobs can include body/due in a message.
        let manual = try db.insert("crm_Accounts_Tasks", values: ["v": .integer(0), "title": .text("手動"), "content": .text("手動本文は複製しない"), "priority": .text("medium"), "account": .text(account), "user": .text(user), "createdBy": .text(user)], actor: user)
        let manualID = try db.enqueue("crm.task_assigned", payload: ["taskId": manual["id"].string, "accountId": account, "opportunityId": "", "recipientId": user, "recipientEmail": "owner@example.invalid", "actorName": "手動作成者", "taskTitle": "手動"], now: now)
        _ = try await worker().runNext()
        let manualText = try body()["text"] as! String
        try check(manualText.contains("手動作成者さん") && !manualText.contains("手動本文は複製しない") && !manualText.contains("期限："), "manual template unchanged")
        try check(try db.job(id: manualID)?.status == "done", "manual delivery still completes")
        // No permissive fallback when a malformed internal payload claims the
        // automation template; fail before any external request.
        let bad = try db.enqueue("crm.task_assigned", payload: first.payload.merging(["taskDueAt": "invalid"]) { _, new in new }, now: now)
        let beforeBad = calls; _ = try await worker().runNext()
        try check(calls == beforeBad && db.job(id: bad)?.status == "failed", "invalid due fails locally")
        try await runtimeChecks(db: db, now: now)
    }
    @MainActor static func runtimeChecks(db: NativeDatabase, now: Date) async throws {
        let environment = NativeCRMRenewalJobs.Environment(appURL: "https://crm.example.invalid", timeZone: TimeZone(secondsFromGMT: 0)!)
        let stopped = NativeCRMAutomationRuntime(db: db, environment: environment, clock: { now })
        stopped.stop(); stopped.resume(); await stopped.stopAndDrain(); await stopped.stopAndDrain()
        try check(stopped.isStopped && !stopped.isRunning && !stopped.isScanning && stopped.nextScan == nil, "terminal stopped runtime does not restart")
        let live = NativeCRMAutomationRuntime(db: db, environment: environment, clock: { now })
        let scan = try db.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        live.resume()
        for _ in 0..<300 {
            if try db.job(id: scan)?.status == "done", !live.isRunning, !live.isScanning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(try db.job(id: scan)?.status == "done", "retained actual runtime consumes startup jobs")
        try check(live.nextScan != nil, "next real cron wake retained")
        await live.stopAndDrain()
        try check(live.isStopped && !live.isRunning && !live.isScanning && live.nextScan == nil, "stop joins own scan/runner and cancels timer")
        let later = try db.enqueue(NativeCRMRenewalJobs.scanEvent, payload: [:], now: now)
        live.resume(); try await Task.sleep(nanoseconds: 30_000_000)
        try check(try db.job(id: later)?.status == "pending", "queued DB notification cannot resume terminal owner")
    }
}
