import AppKit

@main enum CRMAccountTasksUITests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws { guard try condition() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    static func button(_ title: String, in window: NSWindow) throws -> NSButton {
        guard let result = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title}) else { throw NativeDBError.message("Missing button: "+title) }; return result
    }
    static func table(_ window: NSWindow) -> NSTableView { views(window.contentView!).compactMap {$0 as? NSTableView}.first! }
    static func text(_ window: NSWindow) -> String { views(window.contentView!).compactMap {($0 as? NSTextField)?.stringValue}.joined(separator:"\n") }
    static func wait(_ label: String, until condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        throw NativeDBError.message("Timed out: "+label)
    }
    static func click(_ title: String, in window: NSWindow) throws {
        try wait("enabled button: "+title,until:{try button(title,in:window).isEnabled})
        try button(title,in:window).performClick(nil)
    }
    static func selectFirst(in window: NSWindow) throws {
        try wait("enabled task table",until:{table(window).isEnabled})
        table(window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
    }
    static func send(_ control: NSControl) { if let action = control.action { NSApp.sendAction(action,to:control.target,from:control) } }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CRMAccountTasksUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CRMTaskUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
        try Data("NextCRM isolated mail QA\n".utf8).write(to:root.appendingPathComponent(".native-mail-test"))
        setenv("NEXTCRM_NATIVE_DATA_DIR",root.path,1); setenv("NEXTCRM_NATIVE_MAIL_TEST_MODE","success",1)
        defer { unsetenv("NEXTCRM_NATIVE_DATA_DIR"); unsetenv("NEXTCRM_NATIVE_MAIL_TEST_MODE") }
        let notifyUser = try db.insert("Users",values:["name":.text("通知担当者"),"email":.text("notify@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let account = try service.save(CRMModule.find("crm_Accounts")!,original:nil,input:["name":.text("タスク検証株式会社")])
        let parent = CRMTaskParent(model:account.model,id:account["id"].string)
        let browser = try CRMAccountTasksWindow(service:service,parent:account); browser.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        try check(browser.window.title == "CRMタスク" && text(browser.window).contains("タスク検証株式会社のタスク"),"Japanese parent heading")
        try wait("empty list",until:{text(browser.window).contains("／ 0件")})
        try click("新規タスク…",in:browser.window)
        try wait("create editor",until:{browser.window.attachedSheet != nil})
        let editor = browser.window.attachedSheet!
        try check(editor.title == "CRMタスクを登録","actual create editor")
        let title = views(editor.contentView!).compactMap{$0 as? NSTextField}.first{$0.isEditable && $0.accessibilityLabel() == "タスク名"}!
        let body = views(editor.contentView!).compactMap{$0 as? DeferredTextInput}.first{$0.label == "内容"}!
        let assignee = views(editor.contentView!).compactMap{$0 as? CRMReferenceControl}.first!
        try check(assignee.selected == .text(identity.id),"new task defaults to self")
        let date = views(editor.contentView!).compactMap{$0 as? CRMDateControl}.first!
        try check(date.value == .null,"new task has optional unset deadline")
        assignee.setRecord(notifyUser)
        title.stringValue = "画面から日本語タスク"; body.string = "担当者へ確認を依頼します。😀"
        let priority = views(editor.contentView!).compactMap{$0 as? NSPopUpButton}.first{$0.itemTitles.contains("緊急")}!; priority.selectItem(withTitle:"緊急")
        try click("作成",in:editor)
        try wait("saved create",until:{browser.window.attachedSheet == nil && table(browser.window).numberOfRows == 1})
        var task = try service.crmTaskPage(CRMTaskQuery(parent:parent)).rows[0].record
        try check(try service.crmTaskAccess(task["id"].string).task["content"] == .text("担当者へ確認を依頼します。😀") && task["priority"] == .text("critical"),"actual editor persisted Japanese body and priority")
        let runtime = try InvoiceMailRuntime(db:db)
        let runner = InvoiceJobRunner(db:db,events:CRMService.crmTaskJobEvents,runNext:{try await runtime.crmTaskWorker.runNext()})
        runner.kick()
        try wait("actual fake runtime delivery",until:{try service.crmTaskJobs(taskID:task["id"].string).first?.status == "done" && !runner.isRunning})
        let notice = try service.crmTaskJobs(taskID:task["id"].string)[0]
        try check(runtime.isQA && (try db.metadata("qaMailSend."+notice.id)) == "1", "production runtime used fake transport exactly once")
        try check(runner.nextWake == nil,"CRM scheduler settles without idle polling"); runner.stop()
        try selectFirst(in:browser.window)
        try check(try button("完了にする",in:browser.window).isEnabled && button("削除…",in:browser.window).isEnabled,"selected editable task actions")
        try click("再読み込み",in:browser.window)
        try check(!(try button("未完了に戻す",in:browser.window).isEnabled) && !table(browser.window).isEnabled,"stale row actions disabled during reload")
        try check(views(browser.window.contentView!).compactMap{$0 as? NSSearchField}.first!.isEnabled,"type-ahead remains available during reload")
        try wait("fresh rows before status action",until:{try button("再読み込み",in:browser.window).isEnabled})
        try selectFirst(in:browser.window)
        try click("完了にする",in:browser.window)
        try wait("completed",until:{try service.crmTaskAccess(task["id"].string).task["taskStatus"] == .text("COMPLETE") && button("再読み込み",in:browser.window).isEnabled})
        try check(try service.crmTaskAccess(task["id"].string).task["taskStatus"] == .text("COMPLETE"),"actual complete button")
        try wait("completion list selection",until:{table(browser.window).selectedRow == 0 && (try? button("未完了に戻す",in:browser.window).isEnabled) == true})
        try click("未完了に戻す",in:browser.window)
        try wait("active",until:{try service.crmTaskAccess(task["id"].string).task["taskStatus"] == .text("ACTIVE") && button("再読み込み",in:browser.window).isEnabled})
        try wait("active selection",until:{table(browser.window).selectedRow == 0})
        try click("詳細・編集…",in:browser.window)
        try wait("edit sheet",until:{browser.window.attachedSheet != nil})
        let edit = browser.window.attachedSheet!
        let name = views(edit.contentView!).compactMap{$0 as? NSTextField}.first{$0.isEditable && $0.accessibilityLabel() == "タスク名"}!
        name.stringValue = "画面から更新したタスク"
        try click("保存",in:edit)
        try wait("editor update",until:{browser.window.attachedSheet == nil && (try? service.crmTaskAccess(task["id"].string).task["title"]) == .text("画面から更新したタスク")})
        try check(try service.crmTaskAccess(task["id"].string).task["title"] == .text("画面から更新したタスク"),"actual editing persistence")
        try wait("list ready after editor",until:{table(browser.window).numberOfRows == 1}); try selectFirst(in:browser.window)
        try click("コメント…",in:browser.window)
        try wait("comment sheet",until:{browser.window.attachedSheet != nil})
        let comments = browser.window.attachedSheet!
        try wait("comment write permission",until:{try button("コメントを追加…",in:comments).isEnabled})
        try click("コメントを追加…",in:comments)
        try wait("comment editor",until:{comments.attachedSheet != nil})
        let ce = comments.attachedSheet!; let input = views(ce.contentView!).compactMap{$0 as? DeferredTextInput}.first!
        input.string = "お客様への確認が完了しました。"
        try click("投稿",in:ce)
        try wait("comment saved",until:{comments.attachedSheet == nil && table(comments).numberOfRows == 1})
        try check(try service.crmTaskComments(taskID:task["id"].string).rows[0]["comment"] == .text("お客様への確認が完了しました。"),"production comments window uses CRM FK")
        try check(views(comments.contentView!).compactMap{$0 as? NSTextView}.first!.string == "お客様への確認が完了しました。","comment body displayed")
        try click("閉じる",in:comments); try wait("comments closed",until:{browser.window.attachedSheet == nil})
        try selectFirst(in:browser.window)
        try click("文書…",in:browser.window)
        try wait("document sheet",until:{browser.window.attachedSheet != nil})
        let documents = browser.window.attachedSheet!
        try check(try !button("既存の文書を関連付ける…",in:documents).isHidden,"CRM task opens scoped documents browser")
        try click("閉じる",in:documents); try wait("documents closed",until:{browser.window.attachedSheet == nil})
        try selectFirst(in:browser.window)
        try click("通知状況…",in:browser.window)
        try wait("notification sheet",until:{browser.window.attachedSheet != nil})
        let notification = browser.window.attachedSheet!
        try wait("notification row",until:{table(notification).numberOfRows == 1})
        try check(notification.title == "タスクの通知状況","CRM task delivery history in Japanese")
        try click("閉じる",in:notification); try wait("notifications closed",until:{browser.window.attachedSheet == nil})
        let reviewID = try db.enqueue("crm.task_assigned",payload:notice.payload)
        let leased = try db.claimJob(events:CRMService.crmTaskJobEvents,now:Date())!
        let started = try db.markJobDeliveryStarted(leased,now:Date())
        try db.failJob(started,message:"架空の送信結果不明",needsReview:true)
        let reviewPanel = CRMJobReviewWindow(service:service,job:try db.job(id:reviewID)!)
        try check(text(reviewPanel.window).contains("nextcrm/crm-task/"+reviewID),"review displays exact CRM idempotency namespace")
        try check(text(reviewPanel.window).contains("タスクの状態は変更しません。"),"review describes CRM task outcome")
        let outcome = views(reviewPanel.window.contentView!).compactMap{$0 as? NSPopUpButton}.first!
        outcome.selectItem(withTitle:"結果不明のまま処理を終了"); send(outcome)
        views(reviewPanel.window.contentView!).compactMap{$0 as? NSTextView}.first!.string = "架空の送信について結果不明を記録しました。"
        try click("記録して終了",in:reviewPanel.window)
        try check((try db.job(id:reviewID))?.result["reviewOutcome"] == "unknown" && (try db.job(id:reviewID))?.status == "done","actual CRM review form commits without resend")
        try check((try db.metadata("qaMailSend."+reviewID)) == nil,"review adds no fake transport attempt")
        // Bound list buffers and exercise real filter controls with more than100 tasks.
        try db.transaction { for i in 0..<104 { _ = try service.saveCRMTask(parent:parent,original:nil,input:["title":.text("大量確認 \(i)"),"content":.text("本文"),"priority":.text(i<50 ? "high" : "low")]) } }
        try click("再読み込み",in:browser.window)
        try wait("first page",until:{table(browser.window).numberOfRows == 100 && text(browser.window).contains("105件")})
        try check(table(browser.window).numberOfRows == 100,"UI page bounded100")
        try click("次へ",in:browser.window)
        try wait("second page",until:{table(browser.window).numberOfRows == 5 && text(browser.window).contains("101–105")})
        try check(try !button("次へ",in:browser.window).isEnabled,"last page bounds")
        let search = views(browser.window.contentView!).compactMap{$0 as? NSSearchField}.first!
        search.stringValue = "画面から更新"; browser.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        try wait("Japanese search resets page",until:{table(browser.window).numberOfRows == 1 && text(browser.window).contains("1–1 ／ 1件")})
        try check(table(browser.window).numberOfRows == 1,"Japanese search")
        search.stringValue = ""; browser.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        let filter = views(browser.window.contentView!).compactMap{$0 as? NSPopUpButton}.first{$0.itemTitles.contains("優先度すべて")}!
        filter.selectItem(withTitle:"高"); send(filter)
        try wait("priority filter",until:{table(browser.window).numberOfRows == 50})
        try check(text(browser.window).contains("50件"),"priority filter50")
        let mine = try button("自分の担当のみ",in:browser.window); mine.state = .on; send(mine)
        try wait("mine filter",until:{table(browser.window).numberOfRows == 50})
        try check(try service.crmTaskPage(CRMTaskQuery(parent:parent,assigneeID:identity.id,priority:"high")).total == 50,"assigned filter")
        // An account reader can view a task but cannot edit it or comment.
        let user = try db.insert("Users",values:["name":.text("参照担当者"),"email":.text("reader@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        _ = try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":user["id"]],actor:identity.id)
        let reader = CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil))
        let readonly = try CRMAccountTasksWindow(service:reader,parent:account); readonly.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        try wait("reader page",until:{table(readonly.window).numberOfRows == 100})
        try selectFirst(in:readonly.window)
        try check(try !button("完了にする",in:readonly.window).isEnabled && !button("削除…",in:readonly.window).isEnabled && button("詳細・編集…",in:readonly.window).isEnabled,"readonly action permissions")
        try click("詳細・編集…",in:readonly.window); try wait("readonly editor",until:{readonly.window.attachedSheet != nil})
        try check(readonly.window.attachedSheet!.title == "CRMタスクを表示" && views(readonly.window.attachedSheet!.contentView!).compactMap{$0 as? NSTextField}.filter{$0.accessibilityLabel() == "タスク名"}.allSatisfy{!$0.isEnabled} && views(readonly.window.attachedSheet!.contentView!).compactMap{$0 as? DeferredTextInput}.allSatisfy{$0.readOnly},"readonly fields")
        try click("閉じる",in:readonly.window.attachedSheet!); try wait("readonly closed",until:{readonly.window.attachedSheet == nil})
        // Compare actual layout geometry, including the long Japanese action row.
        for window in [browser.window,readonly.window] {
            window.contentView!.layoutSubtreeIfNeeded()
            let bounds = window.contentView!.bounds
            for control in views(window.contentView!).compactMap({$0 as? NSButton}) where !control.isHiddenOrHasHiddenAncestor {
                let frame = control.convert(control.bounds,to:window.contentView!)
                try check(bounds.insetBy(dx:-1,dy:-1).contains(frame),"visible button inside panel: "+control.title)
            }
            try check(table(window).enclosingScrollView!.frame.height >= 300,"usable table viewport")
        }
        // Stale open windows cannot retain rows after fresh access fails.
        _ = try db.update(user,changes:["banned":.integer(1)],actor:identity.id)
        try click("再読み込み",in:readonly.window)
        try wait("revoked page clears",until:{table(readonly.window).numberOfRows == 0})
        try check(try !button("詳細・編集…",in:readonly.window).isEnabled,"revoked rows and actions cleared")
        task = try service.crmTaskAccess(task["id"].string).task
        try check(task["title"] == .text("画面から更新したタスク"),"final persisted task")
        NSApp.windows.forEach{$0.orderOut(nil)}
        try check(NSApp.windows.allSatisfy{!$0.isVisible},"no visible windows left")
        print("CRM task UI: \(checks) checks passed; production controls, offscreen panels, isolated database, no network")
    }
}
