import AppKit

@main enum CampaignDeliveryUITests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("CampaignDeliveryUI FAIL: "+label) }; checks += 1 }
    static func views(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(views) }
    static func button(_ title: String,_ w: NSWindow) throws -> NSButton { guard let b = views(w.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title && !$0.isHiddenOrHasHiddenAncestor}) else { throw NativeDBError.message("Missing button: "+title) }; return b }
    static func click(_ title: String,_ w: NSWindow) throws { let b = try button(title,w); _ = b.sendAction(b.action,to:b.target) }
    static func table(_ w: NSWindow) -> NSTableView { views(w.contentView!).compactMap{$0 as? NSTableView}.first! }
    static func wait(_ label: String,_ condition: () throws -> Bool) throws { let deadline = Date().addingTimeInterval(10); while Date() < deadline { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }; throw NativeDBError.message("UI timed out: "+label) }
    static func ready(_ w: NSWindow) throws { try wait("loaded: "+w.title){try button("再読み込み",w).isEnabled} }
    final class AsyncResult {
        let lock = NSLock(); private var result: Result<Bool,Error>?
        func set(_ value: Result<Bool,Error>) { lock.lock(); defer { lock.unlock() }; result = value }
        func get() -> Result<Bool,Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }
    /// Keep the UI harness outside a main-queue task. A nested RunLoop cannot
    /// drain DispatchQueue.main while its current serial task is still running.
    static func worker(_ operation: @escaping () async throws -> Bool) throws {
        let result = AsyncResult()
        Task.detached { do { result.set(.success(try await operation())) } catch { result.set(.failure(error)) } }
        try wait("async fixture worker"){result.get() != nil}; _ = try result.get()!.get()
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignDeliveryUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        try check(Thread.isMainThread,"native UI harness runs on main thread")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignDeliveryUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity)
        let template = try service.saveCampaignTemplate(nil,input:["name":.text("案内"),"subject_default":.text("ご案内"),"content_html":.text("<p>日本語のご案内</p>")])
        var externalRequests = 0
        func create(_ name: String) throws -> (NativeRecord,String) {
            let target = try db.insert("crm_Targets",values:["last_name":.text(name),"email":.text("ui-\(name)@example.invalid"),"created_by":.text(identity.id)],actor:identity.id)
            let list = try db.insert("crm_TargetLists",values:["name":.text(name),"created_by":.text(identity.id)],actor:identity.id)
            _ = try db.insert("TargetsToTargetLists",values:["target_id":target["id"],"target_list_id":list["id"]],actor:identity.id)
            let draft = try service.createCampaign(input:["name":.text("日本語の履歴 "+name)],targetListIDs:[list["id"].string],steps:[.init(order:0,templateID:template["id"].string,subject:"日本語😀のご案内")])
            let campaign = try service.sendCampaignNow(draft)
            try worker { try await CampaignDispatchWorker(db:db).runNext() }
            return (campaign,try db.page("crm_campaign_sends",fields:[],equal:["campaign_id":campaign["id"]]).rows[0]["id"].string)
        }
        for outcome in MailReviewOutcome.allCases {
            let (campaign,id) = try create(outcome.rawValue), provider = UUID().uuidString.lowercased()
            let mail = CampaignMailWorker(db:db,account:{.init(from:"sender@example.invalid",apiKey:"fake-key")},configuration:{try .init(publicURL:"https://example.invalid")},endpointReady:{_,_ in throw CampaignRelayReceiptConflict(sendID:id,providerID:provider,instanceID:UUID().uuidString.lowercased())},request:{_,_ in externalRequests += 1; throw NativeDBError.conflict})
            try worker { try await mail.runNext() }
            let parent = try CRMCampaignWindow(campaign:campaign,service:service); parent.window.setFrameOrigin(.init(x:-10000,y:-10000)); try ready(parent.window)
            try click("送信履歴…",parent.window); try wait("history sheet"){parent.window.attachedSheet != nil}; let history = parent.window.attachedSheet!; try ready(history)
            try check(table(history).numberOfRows == 1 && history.title == "キャンペーンの送信履歴", "detail opens scoped Japanese history")
            table(history).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
            try check(try button("送信結果を確認…",history).isEnabled && !button("選択したメールを再試行",history).isEnabled && !button("送信を取り消す…",history).isEnabled, "uncertain remote receipt only permits review")
            history.contentView!.layoutSubtreeIfNeeded()
            for b in views(history.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) { let rect = b.convert(b.bounds,to:history.contentView); try check(rect.minX >= -1 && rect.maxX <= history.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= history.contentView!.bounds.height+1,"history control fits: "+b.title) }
            try click("送信結果を確認…",history); try wait("review sheet"){history.attachedSheet != nil}; let review = history.attachedSheet!
            let texts = views(review.contentView!).compactMap{$0 as? NSTextField}
            try check(texts.contains{$0.stringValue.contains("campaign-send/"+id) && $0.stringValue.contains(provider)}, "review exposes exact provider request ID and separate hint")
            let receipt = texts.first{$0.accessibilityLabel() == "送信サービスの受付ID"}!
            try check(receipt.stringValue.isEmpty, "hint never prefilled as confirmed receipt")
            review.contentView!.layoutSubtreeIfNeeded()
            for control in views(review.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor}) {
                let rect = control.convert(control.bounds,to:review.contentView)
                try check(rect.minX >= -1 && rect.maxX <= review.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= review.contentView!.bounds.height+1,"review control stays inside panel")
            }
            let popup = views(review.contentView!).compactMap{$0 as? NSPopUpButton}.first!
            popup.selectItem(at:MailReviewOutcome.allCases.firstIndex(of:outcome)!); _ = popup.sendAction(popup.action,to:popup.target)
            try check(receipt.isEnabled == (outcome == .accepted), "receipt input follows selected outcome")
            let notes = views(review.contentView!).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel() == "確認した内容"}!
            try click("記録して終了",review)
            try check(history.attachedSheet === review && (try db.job(id:id)?.status) == "needs_review", "empty review cannot change persisted state")
            notes.string = "管理画面で宛先と件名を確認しました。"; if outcome == .accepted { receipt.stringValue = provider }
            try click("記録して終了",review); try wait("review closes"){history.attachedSheet == nil}; try ready(history)
            try check(try db.job(id:id)?.result["reviewOutcome"] == outcome.rawValue && db.job(id:id)?.status == "done", "UI commits selected terminal review")
            try check(try !button("送信結果を確認…",history).isEnabled && !button("選択したメールを再試行",history).isEnabled, "reviewed record cannot resend")
            let details = views(history.contentView!).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel() == "選択したメールの送信記録"}!
            // AppKit may detach the sheet before invoking its completion, which
            // starts the asynchronous refresh. Wait for the rendered result.
            try wait("saved memo rendered"){details.string.contains("管理画面で宛先と件名を確認しました。")}
            try check(details.string.contains("管理画面で宛先と件名を確認しました。"), "history displays saved Japanese memo")
            try click("閉じる",history); try wait("history closes"){parent.window.attachedSheet == nil}; parent.window.orderOut(nil)
        }
        let (retryCampaign,retryID) = try create("retry")
        let prepare = CampaignMailWorker(db:db,account:{.init(from:"sender@example.invalid",apiKey:"fake-key")},configuration:{try .init(publicURL:"https://example.invalid")},endpointReady:{_,_ in throw CampaignRelayError(message:"テスト用の一時停止",retryable:true)},request:{_,_ in externalRequests += 1; throw NativeDBError.conflict})
        try worker { try await prepare.runNext() }
        let beforeRetry = try db.job(id:retryID)!, retryUI = try CRMCampaignDeliveryWindow(service:service,campaignID:retryCampaign["id"].string)
        try ready(retryUI.window); table(retryUI.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(try button("選択したメールを再試行",retryUI.window).isEnabled,"transient failure exposes retry action")
        try click("選択したメールを再試行",retryUI.window)
        try wait("retry enqueued"){try db.job(id:retryID)?.status == "pending"}; try ready(retryUI.window)
        try check(try db.job(id:retryID)?.result["sha256"] == beforeRetry.result["sha256"] && db.job(id:retryID)?.id == beforeRetry.id,"UI retry preserves original ID and frozen body")
        // No runtime runner is installed in this UI harness. Explicitly cancel
        // the queued fixture before creating the next recipient.
        try service.cancelCampaignMailJob(db.job(id:retryID)!); retryUI.window.orderOut(nil)
        let (campaign,id) = try create("cancel")
        let history = try CRMCampaignDeliveryWindow(service:service,campaignID:campaign["id"].string); try ready(history.window); table(history.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(try button("送信を取り消す…",history.window).isEnabled, "pending recipient can cancel")
        try click("送信を取り消す…",history.window); try wait("cancel confirmation"){history.window.attachedSheet != nil}
        let confirmation = history.window.attachedSheet!; try click("送信を取り消す",confirmation); try wait("cancel commits"){try db.job(id:id)?.status == "cancelled"}; try ready(history.window)
        try check(try db.job(id:id)?.result["cancelledBy"] == identity.id && !button("選択したメールを再試行",history.window).isEnabled, "UI cancellation is terminal")
        let search = views(history.window.contentView!).compactMap{$0 as? NSSearchField}.first!; search.stringValue = "nonexistent"; history.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search)); try ready(history.window)
        try check(table(history.window).numberOfRows == 0, "history search excludes unmatched recipients")
        search.stringValue = "cancel"; history.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search)); try ready(history.window)
        try check(table(history.window).numberOfRows == 1, "history search restores matching recipient")
        let original = try db.get("crm_campaign_sends",key:["id":.text(id)])!
        try db.transaction {
            for index in 0..<104 {
                let target = try db.insert("crm_Targets",values:["last_name":.text("過去\(index)"),"email":.text("past\(index)@example.invalid"),"created_by":.text(identity.id)],actor:identity.id)
                _ = try db.insert("crm_campaign_sends",values:["campaign_id":campaign["id"],"step_id":original["step_id"],"target_id":target["id"],"email":target["email"],"status":.text("delivered")],actor:identity.id)
            }
        }
        search.stringValue = ""; history.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search)); try ready(history.window)
        try check(table(history.window).numberOfRows == 100 && (try button("次へ",history.window).isEnabled), "history first page bounded to100")
        try click("次へ",history.window); try ready(history.window)
        try check(table(history.window).numberOfRows == 5 && (try button("前へ",history.window).isEnabled) && !(try button("次へ",history.window).isEnabled), "history final page controls")
        let filter = views(history.window.contentView!).compactMap{$0 as? NSPopUpButton}.first!; filter.selectItem(at:4); _ = filter.sendAction(filter.action,to:filter.target); try ready(history.window)
        try check(table(history.window).numberOfRows == 100, "status filter returns first page of delivered history")
        table(history.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(try !button("送信結果を確認…",history.window).isEnabled && !button("選択したメールを再試行",history.window).isEnabled, "legacy recipient without outgoing job cannot create a send")
        let user = try db.get("Users",key:["id":.text(identity.id)])!; _ = try db.update(user,changes:["banned":.integer(1)],actor:identity.id)
        try click("再読み込み",history.window); try ready(history.window)
        try check(table(history.window).numberOfRows == 0 && !(try button("送信を取り消す…",history.window).isEnabled), "revoked identity clears history and mutation controls")
        try check(externalRequests == 0, "review and cancellation never call outgoing transport")
        try CampaignOperationsUITests.run(resources)
        print("CampaignDeliveryUITests: \(checks) checks passed; actual Japanese AppKit controls, fake transport, isolated SQLite")
    }
}
