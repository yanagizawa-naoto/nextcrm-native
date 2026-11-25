import AppKit
import SQLite3

@main enum NativeCRMAutomationJobsUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func text(_ window: NSWindow) -> String {
        views(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.joined(separator: "\n")
    }
    static func button(_ title: String, _ window: NSWindow) throws -> NSButton {
        guard let b = views(window.contentView!).compactMap({$0 as? NSButton}).first(where: {$0.title == title}) else { throw NativeDBError.message("Missing button " + title) }; return b
    }
    static func table(_ window: NSWindow) -> NSTableView { views(window.contentView!).compactMap {$0 as? NSTableView}.first! }
    static func click(_ title: String, _ window: NSWindow) throws { try button(title, window).performClick(nil) }
    static func select(_ row: Int, _ window: NSWindow) { table(window).selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var c: OpaquePointer?; guard sqlite3_open(db.url.path, &c) == SQLITE_OK else { throw NativeDBError.message("test open") }; defer { sqlite3_close(c) }
        guard sqlite3_exec(c, statement, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(c))) }
    }
    static func main() {
        do { try run() } catch { fputs("After \(checks): \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named: .aqua)
        let n = URL(fileURLWithPath: CommandLine.arguments[1]), root = URL(fileURLWithPath: CommandLine.arguments[2]), out = URL(fileURLWithPath: CommandLine.arguments[3])
        defer { NSApp.windows.forEach { $0.orderOut(nil) } }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: n.appendingPathComponent("schema.json"), sqlURL: n.appendingPathComponent("schema.sql"))
        var user = try db.insert("Users", values: ["name":.text("隔離管理者"),"email":.text("monitor@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")], actor:"test")
        let aid = user["id"].string, service = CRMService(db: db, identity: .init(id: aid, role:"admin", partnerAccountID:nil))
        let epoch = Date().addingTimeInterval(-3600)
        let local = NativeCRMAutomationJobs.localEvents[0]
        var offset: Double = 0
        func job(_ event: String, _ payload: [String:String] = [:]) throws -> NativeJob {
            offset += 1
            let id = try db.enqueue(event, payload:payload, now:epoch.addingTimeInterval(offset))
            return try db.job(id:id)!
        }
        try db.transaction { for _ in 0..<205 { _ = try job(local) } }
        _ = try job("unrelated.event")
        let ui = try NativeCRMAutomationJobsWindow(service:service), window = ui.window
        window.setFrameOrigin(NSPoint(x:-20000,y:-20000))
        try check(!window.isVisible,"window stays offscreen")
        try check(table(window).numberOfRows == 100 && text(window).contains("1–100件"),"first 100-row page")
        try check(try button("次へ",window).isEnabled && !button("前へ",window).isEnabled,"first page controls")
        let p1 = try service.crmAutomationJobs().map(\.id)
        try click("次へ",window)
        try check(table(window).numberOfRows == 100 && text(window).contains("101–200件"),"second hundred-row page")
        try check(Set(p1).isDisjoint(with: Set(try service.crmAutomationJobs(offset:100).map(\.id))),"disjoint actual query pages")
        try click("次へ",window)
        try check(table(window).numberOfRows == 5 && text(window).contains("201–205件"),"last page exact count")
        try check(try !button("次へ",window).isEnabled && button("前へ",window).isEnabled,"last page controls")
        try click("前へ",window); try click("前へ",window)
        select(0,window); let first = try service.crmAutomationJobs()[0]
        try check(try button("予約を取消",window).isEnabled && !button("再試行",window).isEnabled,"pending enables only cancel")
        try click("予約を取消",window)
        try check(try db.job(id:first.id)?.status == "cancelled","cancel control commits")
        try check(text(window).contains("取消済み") && !button("予約を取消",window).isEnabled,"cancel selection refresh")

        let retry = try job(NativeCRMAutomationJobs.localEvents[1])
        try sql(db,"UPDATE native_outbox SET status='failed',attempts=5,last_error='検証用の一時エラー' WHERE id='"+retry.id+"'")
        try click("再読み込み",window); select(0,window)
        try check(text(window).contains("検証用の一時エラー") && button("再試行",window).isEnabled,"failed item visible")
        try click("再試行",window)
        let reset = try db.job(id:retry.id)!
        try check(reset.status == "pending" && reset.attempts == 0,"retry renews five-attempt budget")
        try check(reset.id == retry.id && reset.payload == retry.payload,"retry preserves job identity")
        let claimed = try db.claimJob(events:[retry.event])!
        try check(claimed.id == retry.id && claimed.attempts == 1,"next claim starts at one")
        try db.finishJob(claimed,result:["outcome":"fixture"])

        let stale = try job(NativeCRMAutomationJobs.localEvents[2])
        try click("再読み込み",window); select(0,window)
        // Second connection deliberately emits no notification, preserving selected snapshot.
        try sql(db,"UPDATE native_outbox SET result='{\"concurrent\":\"change\"}' WHERE id='"+stale.id+"'")
        let changed = try db.job(id:stale.id)!
        try click("予約を取消",window)
        try check(try db.job(id:stale.id) == changed,"stale selected cancel rejected by CAS")
        try check(text(window).contains(NativeDBError.conflict.localizedDescription),"CAS conflict presented")
        try click("再読み込み",window); select(0,window)
        user = try db.update(user,changes:["role":.text("user")],actor:aid)
        try click("予約を取消",window)
        try check(try db.job(id:stale.id) == changed,"fresh revoked role prevents cancel")
        try click("再読み込み",window)
        try check(table(window).numberOfRows == 0 && !button("再試行",window).isEnabled && !button("予約を取消",window).isEnabled,"revocation clears rows and controls")
        user = try db.update(user,changes:["role":.text("admin")],actor:aid)

        let digest = try job(NativeCRMSweepJobs.recycleNotice,["recipientCount":"250","count":"1250","subject":"1,250件の営業対象を再開対象に追加しました"])
        let mail = try db.claimJob(events:[digest.event])!
        let delivered = try db.markJobDeliveryStarted(mail)
        try db.failJob(delivered,message:"送信サービスの結果を確認してください。",needsReview:true)
        try click("再読み込み",window); select(0,window)
        try check(text(window).contains("宛先：250人"),"digest count shown without recipient snapshot")
        try check(try button("確認結果を記録…",window).isEnabled && !button("予約を取消",window).isEnabled,"unknown delivery review enabled cancel disabled")
        try check(!FileManager.default.fileExists(atPath:root.appendingPathComponent("crm-mail").path),"no notice body load required")
        window.contentView!.layoutSubtreeIfNeeded(); window.contentView!.displayIfNeeded()
        let content = window.contentView!
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) else { throw NativeDBError.message("capture unavailable") }
        content.cacheDisplay(in:content.bounds,to:bitmap)
        // The content-view cache omits the window background. Composite only
        // that standard background; control pixels remain the real AppKit output.
        let cg = CGContext(data:nil,width:bitmap.pixelsWide,height:bitmap.pixelsHigh,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(gray:0.94,alpha:1)); cg.fill(CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh))
        cg.draw(bitmap.cgImage!,in:CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh))
        try NSBitmapImageRep(cgImage:cg.makeImage()!).representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("automation-monitor.png"))
        for control in views(content).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor}) {
            let frame = control.convert(control is NSTableView ? control.visibleRect : control.bounds,to:content)
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.minY >= -1 && frame.maxX <= content.bounds.width+1 && frame.maxY <= content.bounds.height+1,"control in layout bounds")
        }
        let frames = views(content).filter {$0 is NSButton || $0 is NSScrollView || $0 is NSTextField}.map { view in
            ["kind":String(describing:type(of:view)),"label":(view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue ?? view.accessibilityLabel() ?? "", "frame":NSStringFromRect(view.convert(view.bounds,to:content))]
        }
        try JSONSerialization.data(withJSONObject:frames,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("layout.json"))

        try click("確認結果を記録…",window); pump()
        guard let review = window.attachedSheet else { throw NativeDBError.message("nested sheet missing") }
        try check(text(review).contains("nextcrm/crm-automation/"+digest.id),"actual nested review namespace")
        try check(text(review).contains("宛先：250人"),"actual nested digest sheet recipient count")
        try check(text(review).contains("商談・営業先リストの状態は変更しません。"),"notice hint")
        let beforeReview = try db.job(id:digest.id)!
        try click("記録して終了",review)
        try check(try db.job(id:digest.id) == beforeReview && window.attachedSheet === review,"invalid blank review remains open")
        let receipt = views(review.contentView!).compactMap {$0 as? NSTextField}.first {$0.accessibilityLabel() == "送信サービスの受付ID"}!
        let note = views(review.contentView!).compactMap {$0 as? NSTextView}.first {$0.accessibilityLabel() == "確認した内容"}!
        receipt.stringValue = "f1000000-0000-4000-8000-000000000001"; note.string = "送信サービスで処理ID・宛先人数・件名の一致と受付を確認しました。"
        user = try db.update(user,changes:["role":.text("user")],actor:aid)
        try click("記録して終了",review)
        try check(try db.job(id:digest.id) == beforeReview && window.attachedSheet === review,"nested notice save rechecks revoked authority")
        user = try db.update(user,changes:["role":.text("admin")],actor:aid)
        try click("記録して終了",review); pump()
        let reviewed = try db.job(id:digest.id)!
        try check(reviewed.status == "done" && reviewed.result["reviewOutcome"] == "accepted","nested injected closure commits actual notice")
        try check(reviewed.result["reviewedBy"] == aid && reviewed.result["reviewNote"] == note.string,"notice review attribution and note")
        try check(reviewed.result["providerID"] == receipt.stringValue,"notice receipt preserved")
        try check(window.attachedSheet == nil && text(window).contains("受付確認済み"),"sheet completion refreshes parent")
        try check(!button("確認結果を記録…",window).isEnabled,"terminal notice cannot review again")

        let pendingNotice = try job(NativeCRMSweepJobs.killNotice,["recipientId":aid,"recipientEmail":"recipient@example.invalid"])
        try click("再読み込み",window); select(0,window); try click("予約を取消",window)
        try check(try db.job(id:pendingNotice.id)?.status == "cancelled","notice cancel routes to actual notice service")
        let retryNotice = try job(NativeCRMSweepJobs.killNotice,["recipientId":aid,"recipientEmail":"recipient@example.invalid"])
        let mailClaim = try db.claimJob(events:[retryNotice.event])!
        let mailStarted = try db.markJobDeliveryStarted(mailClaim)
        try db.failJob(mailStarted,message:"一時的な送信エラー")
        try click("再読み込み",window); select(0,window)
        try check(button("再試行",window).isEnabled && !button("予約を取消",window).isEnabled,"failed delivery keeps retry but blocks cancellation")
        try click("再試行",window)
        let mailRetry = try db.job(id:retryNotice.id)!
        try check(mailRetry.status == "pending" && mailRetry.attempts == 1 && mailRetry.deliveryStartedAt == mailStarted.deliveryStartedAt,"notice retry preserves dedupe clocks and attempt history")

        // The unchanged default (no injected closure) still saves a normal CRM task mail.
        let ordinary = try job("crm.task_assigned",["taskId":UUID().uuidString.lowercased(),"recipientId":aid,"recipientEmail":"recipient@example.invalid","subject":"通常のタスク通知","recipientCount":"999"])
        let ordinaryClaim = try db.claimJob(events:[ordinary.event])!
        let started = try db.markJobDeliveryStarted(ordinaryClaim)
        try db.failJob(started,message:"通常通知の確認待ち",needsReview:true)
        let normal = CRMJobReviewWindow(service:service,job:try db.job(id:ordinary.id)!)
        normal.window.setFrameOrigin(NSPoint(x:-20000,y:-20000))
        try check(text(normal.window).contains("nextcrm/crm-task/"+ordinary.id),"normal default namespace unchanged")
        try check(text(normal.window).contains("宛先：recipient@example.invalid") && !text(normal.window).contains("宛先：999人"),"normal recipientEmail remains prior to count fallback")
        try check(text(normal.window).contains("タスクの状態は変更しません。"),"normal default hint unchanged")
        let popup = views(normal.window.contentView!).compactMap {$0 as? NSPopUpButton}.first!
        popup.selectItem(at:2); NSApp.sendAction(popup.action!,to:popup.target,from:popup)
        let ordinaryNote = views(normal.window.contentView!).compactMap {$0 as? NSTextView}.first!
        ordinaryNote.string = "通常通知の結果を確認できなかったため終了します。"
        try click("記録して終了",normal.window)
        let normalDone = try db.job(id:ordinary.id)!
        try check(normalDone.status == "done" && normalDone.result["reviewOutcome"] == "unknown","default real review service still commits")
        try check(normalDone.result["reviewNote"] == ordinaryNote.string && normalDone.result["reviewedBy"] == aid,"normal default attribution")
        try check(normal.confirmDiscard(),"saved ordinary review does not ask discard")
        try check(ui.confirmDiscard(),"closed notice sheet does not ask discard")
        normal.window.orderOut(nil); window.orderOut(nil)
        try check(NSApp.windows.allSatisfy {!$0.isVisible},"all windows remain hidden at end")
        print("{\"checks\":\(checks),\"exit\":0,\"externalRequests\":0,\"keychainCalls\":0,\"offscreen\":true}")
    }
}
