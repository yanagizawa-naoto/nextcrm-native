import AppKit

/// Uses production controls and an real app delegate with a synthetic marked-workspace startup plan.
/// All database and provider activity is confined to an explicitly marked QA root.
@main enum NativeMCPLeadsUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + name) }; checks += 1
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func text(_ window: NSWindow) -> String { views(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.joined(separator: "\n") }
    static func button(_ name: String, _ window: NSWindow) throws -> NSButton {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == name }) else { throw NativeDBError.message("Missing button: " + name) }; return value
    }
    static func table(_ window: NSWindow) throws -> NSTableView {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSTableView }).first else { throw NativeDBError.message("Missing table") }; return value
    }
    static func click(_ name: String, _ window: NSWindow) throws { try button(name, window).performClick(nil) }
    static func select(_ row: Int, _ window: NSWindow) throws { try table(window).selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    static func wait(_ name: String, seconds: TimeInterval = 12, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !condition() {
            guard Date() < deadline else { throw NativeDBError.message("Timeout: " + name) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        checks += 1
    }
    static func pump(_ seconds: TimeInterval = 0.15) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("NativeMCPLeadsUITests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        guard let path = ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"], ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_MAIL_TEST_MODE"] == "success" else { throw NativeDBError.conflict }
        let root = URL(fileURLWithPath: path), resources = Bundle.main.resourceURL!
        defer { NSApp.windows.forEach { $0.orderOut(nil) } }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db, resources: resources), admin = CRMService(db: db, identity: identity)
        func user(_ name: String) throws -> CRMService {
            let row = try db.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: identity.id)
            return CRMService(db: db, identity: .init(id: row["id"].string, role: "user", partnerAccountID: nil))
        }
        let recipient = try user("担当者"), stranger = try user("別の利用者")
        func lead(_ name: String) throws -> NativeRecord {
            try db.insert("crm_Leads", values: ["firstName": .text(name), "lastName": .text("検証"), "assigned_to": .text(recipient.identity.id), "createdBy": .text(identity.id), "updatedBy": .text(identity.id)], actor: identity.id)
        }
        func notice(_ row: NativeRecord) throws -> String {
            try db.enqueue(NativeMCPLeads.assignedEvent, payload: ["leadId": row["id"].string, "recipientId": recipient.identity.id, "recipientEmail": "担当者@example.invalid", "leadName": row["firstName"].string, "actorID": identity.id])
        }
        if !CommandLine.arguments.contains("--runtime-only") {
        let first = try lead("ページング対象"), other = try lead("別の見込み客")
        var ids: [String] = []
        try db.transaction { for _ in 0..<205 { ids.append(try notice(first)) }; for _ in 0..<3 { ids.append(try notice(other)) } }
        let history = try CRMInvoiceJobsWindow(service: admin, invoice: first)
        try check(history.window.title == "見込み客の担当通知", "Japanese lead history title")
        try check(try table(history.window).accessibilityLabel() == "見込み客の担当通知履歴", "Japanese accessible table label")
        try check(try table(history.window).numberOfRows == 100 && text(history.window).contains("1–100件"), "first page capped at 100")
        try click("次へ", history.window)
        try check(try table(history.window).numberOfRows == 100 && text(history.window).contains("101–200件"), "second page capped at 100")
        try click("次へ", history.window)
        try check(try table(history.window).numberOfRows == 5 && !button("次へ", history.window).isEnabled, "third page excludes other lead jobs")
        let oldest = try admin.leadJobs(leadID: first["id"].string, offset: 200)[0]
        try select(0, history.window)
        try check(try button("予約を取消", history.window).isEnabled && !button("再試行", history.window).isEnabled, "pending controls")
        try click("予約を取消", history.window)
        try check(try db.job(id: oldest.id)?.status == "cancelled" && text(history.window).contains("取消済み"), "cancel persists and refreshes")
        try click("前へ", history.window)
        try check(try table(history.window).numberOfRows == 100, "previous page")
        for id in ids where id != oldest.id { try admin.cancelLeadJob(id) }

        let work = try lead("再試行と送信結果の確認"), retryID = try notice(work)
        let claim = try db.claimJob(events: [NativeMCPLeads.assignedEvent])!
        try check(claim.id == retryID, "isolated retry fixture")
        try db.failJob(claim, message: "検証用の設定エラー")
        let retryHistory = try CRMInvoiceJobsWindow(service: admin, invoice: work)
        try select(0, retryHistory.window)
        try check(try button("再試行", retryHistory.window).isEnabled && text(retryHistory.window).contains("検証用の設定エラー"), "failure offers retry")
        try click("再試行", retryHistory.window)
        try check(try db.job(id: retryID)?.status == "pending" && !button("再試行", retryHistory.window).isEnabled, "retry schedules same job")
        let running = try db.claimJob(events: [NativeMCPLeads.assignedEvent])!
        try db.recordJobResult(running, result: ["to": "担当者@example.invalid", "subject": "見込み客の担当者に設定されました"])
        let started = try db.markJobDeliveryStarted(running)
        try db.failJob(started, message: "検証用の結果不明", needsReview: true)
        retryHistory.start(); try select(0, retryHistory.window)
        try check(try button("確認結果を記録…", retryHistory.window).isEnabled && !button("予約を取消", retryHistory.window).isEnabled, "ambiguous attempt cannot be cancelled")
        try click("確認結果を記録…", retryHistory.window)
        try wait("review sheet") { retryHistory.window.attachedSheet != nil }
        let review = retryHistory.window.attachedSheet!
        try check(text(review).contains("nextcrm/lead/" + retryID), "lead idempotency key in actual review sheet")
        try check(text(review).contains("見込み客の状態は変更しません。"), "lead specific review guidance")
        let outcome = views(review.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        outcome.selectItem(at: 2); NSApp.sendAction(outcome.action!, to: outcome.target, from: outcome)
        views(review.contentView!).compactMap { $0 as? NSTextView }.first!.string = "模擬送信の結果を確認しましたが不明でした。"
        _ = try db.update(db.get("Users", key: ["id": .text(identity.id)])!, changes: ["banned": .integer(1)], actor: identity.id)
        try click("記録して終了", review)
        try check(try db.job(id: retryID)?.status == "needs_review" && text(review).contains("この利用者では操作できません"), "review rechecks current reviewer access")
        _ = try db.update(db.get("Users", key: ["id": .text(identity.id)])!, changes: ["banned": .integer(0)], actor: identity.id)
        try click("記録して終了", review)
        try check(try db.job(id: retryID)?.result["reviewOutcome"] == "unknown", "review save rejected: " + text(review))
        try wait("review closes") { retryHistory.window.attachedSheet == nil }
        try check(try db.job(id: retryID)?.result["reviewOutcome"] == "unknown", "review persists lead result")
        retryHistory.start(); try select(0, retryHistory.window)
        try check(text(retryHistory.window).contains("結果不明・終了") && !(try button("確認結果を記録…", retryHistory.window)).isEnabled, "resolved review immutable")
        try check(try db.get("crm_Leads", key: ["id": work["id"]])?.values == work.values, "review leaves lead unchanged")

        let ownerHistory = try CRMInvoiceJobsWindow(service: recipient, invoice: work)
        try check(try table(ownerHistory.window).numberOfRows == 1, "assignee sees history")
        _ = try db.update(db.get("Users", key: ["id": .text(recipient.identity.id)])!, changes: ["banned": .integer(1)], actor: identity.id)
        ownerHistory.start()
        try check(try table(ownerHistory.window).numberOfRows == 0 && !button("次へ", ownerHistory.window).isEnabled && !button("確認結果を記録…", ownerHistory.window).isEnabled, "revoked access clears rows and controls")
        _ = try db.update(db.get("Users", key: ["id": .text(recipient.identity.id)])!, changes: ["banned": .integer(0)], actor: identity.id)
        do { _ = try CRMInvoiceJobsWindow(service: stranger, invoice: work); throw NativeDBError.message("FAIL: unrelated history visible") } catch NativeDBError.message(let message) where message.hasPrefix("FAIL:") { throw NativeDBError.message(message) } catch { checks += 1 }
        _ = try db.update(work, changes: ["deletedAt": .text("2026-01-01T00:00:00.000Z"), "deletedBy": .text(identity.id)], actor: identity.id)
        retryHistory.start()
        try check(try table(retryHistory.window).numberOfRows == 1, "admin history remains after lead deletion")
        ownerHistory.start()
        try check(try table(ownerHistory.window).numberOfRows == 0, "ordinary assignee loses deleted lead history")

        }

        // Start the actual production delegate. QA mode replaces every external
        // mail/client boundary and uses a distinct, temporary database directory.
        let startup = try admin.save(CRMModule.find("crm_Leads")!, original: nil, input: ["firstName": .text("起動時に復旧する担当通知"), "lastName": .text("検証"), "assigned_to": .text(recipient.identity.id)])
        let startupID = try db.jobs(events: [NativeMCPLeads.assignedEvent]).first { $0.payload["leadId"] == startup["id"].string }!.id
        try check(try db.job(id: startupID)?.payload["actorID"] == identity.id, "production generic editor save creates lead assignment notification")
        // Synthetic ordinary-workspace plan is bound to this marked private fixture.
        // Production's unresolved default initializer remains fail-closed.
        let plan = NativeRestoreApplicationStartupPlan(root:try NativeRestoreActivationControl.root(root),
            selection:nil,mode:.ordinary,permitted:NativeRestoreRuntimeCatalog.ids,held:[],activationID:nil,requiresReview:false)
        let delegate = try NativeCRMApplication(startupPlan:plan,workspaceOpener:{selected,_ in
            guard selected == plan.root else { throw NativeDBError.conflict };return admin
        }); NSApp.delegate = delegate
        let link = try NativeMCPLeadLink(leadID: startup["id"].string)
        delegate.application(NSApp, open: [URL(string: link.string)!])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)); withExtendedLifetime(delegate) {} }
        guard let main = NSApp.windows.first(where: { $0.title.hasPrefix("NextCRM Native —") }) else { throw NativeDBError.message("FAIL: production main window absent") }
        main.orderOut(nil)
        try wait("production startup mail") { try db.job(id: startupID)?.status == "done" }
        let evidence = try JSONSerialization.jsonObject(with: Data(db.metadata("qaMailSend.last")!.utf8)) as! [String: Any]
        try check(evidence["network"] as? Bool == false && evidence["jobID"] as? String == startupID, "startup uses isolated request and real worker")
        try check((evidence["subject"] as? String)?.contains("見込み客の担当者に設定されました") == true, "runtime Japanese subject")
        try wait("cold lead link") { main.attachedSheet?.title == "リードを編集" }
        try click("キャンセル", main.attachedSheet!)
        try wait("editor closed") { main.attachedSheet == nil }
        try wait("lead list loaded") { try table(main).numberOfRows > 0 }
        try select(0, main)
        guard let popup = views(main.contentView!).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("担当通知…") }) else { throw NativeDBError.message("FAIL: notification entry absent") }
        popup.selectItem(withTitle: "担当通知…"); NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        try wait("notification menu opens production history") { main.attachedSheet?.title == "見込み客の担当通知" }
        try click("閉じる", main.attachedSheet!)
        try wait("history closed") { main.attachedSheet == nil }
        delegate.application(NSApp, open: [URL(string: link.string)!])
        try wait("warm lead link") { main.attachedSheet?.title == "リードを編集" }
        // A pending link is checked again after the current sheet closes.
        delegate.application(NSApp, open: [URL(string: link.string)!])
        _ = try db.update(db.get("crm_Leads", key: ["id": startup["id"]])!, changes: ["deletedAt": .text("2026-01-01T00:00:00.000Z"), "deletedBy": .text(identity.id)], actor: identity.id)
        try click("キャンセル", main.attachedSheet!)
        try wait("queued link rechecks access") { main.attachedSheet.map { text($0).contains("操作を完了できませんでした") } == true }
        try check(main.attachedSheet?.title != "リードを編集", "deleted pending link never opens editor")
        main.endSheet(main.attachedSheet!); pump()
        _ = try db.update(db.get("crm_Leads", key: ["id": startup["id"]])!, changes: ["deletedAt": .null, "deletedBy": .null], actor: identity.id)
        let activeID = try notice(startup)
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        try wait("active delegate resumes lead delivery") { try db.job(id: activeID)?.status == "done" }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        let stoppedID = try notice(startup); pump(0.3)
        try check(try db.job(id: stoppedID)?.status == "pending", "termination stops lead runner")
        try admin.cancelLeadJob(stoppedID)
        let scope = CommandLine.arguments.contains("--runtime-only") ? "real delegate startup/resume/stop and cold/warm/deferred links" : "real delegate startup/resume/stop, cold/warm/deferred links, Japanese history/review, paging/privacy/retry/cancel"
        print("Native MCP leads UI/runtime: \(checks) checks passed; \(scope); external network=false")
    }
}
