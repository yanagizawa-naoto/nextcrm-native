import AppKit

@main enum DocumentsUITests {
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
    static func send(_ control: NSControl) { if let action = control.action { NSApp.sendAction(action,to:control.target,from:control) } }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("DocumentsUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DocumentsUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
        let source = root.appendingPathComponent("画面経由の日本語.txt"); try Data("日本語の文書\n二行目😀".utf8).write(to:source)
        let browser = try CRMDocumentsWindow(service:service)
        try check(browser.window.title == "文書","Japanese browser title")
        try wait("initial list",until:{try button("ファイルを取り込む…",in:browser.window).isEnabled})
        try check(table(browser.window).numberOfRows == 0,"empty initial list")
        browser.importFiles([source])
        try check(browser.busy && !browser.confirmDiscard(),"import prevents accidental close")
        try wait("async import",until:{!browser.busy && table(browser.window).numberOfRows == 1})
        try check(text(browser.window).contains("1件を取り込み"),"import completion message")
        var document = try service.documentPage().rows[0]
        try check(try Data(contentsOf:service.documentFile(document["id"].string)) == Data(contentsOf:source),"production UI import persisted exact bytes")
        table(browser.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(try button("詳細・編集…",in:browser.window).isEnabled && button("新しい版を追加…",in:browser.window).isEnabled,"selected document enables editing and versioning")
        let newer = root.appendingPathComponent("更新した内容.txt"); try Data("新しい版".utf8).write(to:newer)
        browser.importFiles([newer],replacing:document)
        try wait("version import",until:{ guard !browser.busy else { return false }; return try service.documentRecord(document["id"].string)["version"] == .integer(2) })
        document = try service.documentRecord(document["id"].string)
        let history = try CRMDocumentsWindow(service:service,versionsOf:document)
        try wait("version list",until:{table(history.window).numberOfRows == 2})
        try check(history.window.title == "文書の版履歴","Japanese history title")
        try check(try button("新しい版を追加…",in:history.window).isHidden && button("文書を削除…",in:history.window).superview!.isHidden,"history is readonly")
        table(history.window).selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try check(try button("プレビュー…",in:history.window).isEnabled && button("書き出す…",in:history.window).isEnabled,"historical files expose preview and export")

        try db.transaction { for i in 0..<100 { _ = try db.insert("Documents",values:["document_name":.text("一覧検証 \(i)"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("unmigrated:test"),"createdBy":.text(identity.id),"document_system_type":.text(i < 50 ? "CONTRACT" : "OTHER"),"size":.integer(10)],actor:identity.id) } }
        browser.reload(); try wait("101 rows first page",until:{table(browser.window).numberOfRows == 100 && text(browser.window).contains("101件")})
        try check(table(browser.window).numberOfRows == 100,"browser bounds visible metadata to100 rows")
        try button("次へ",in:browser.window).performClick(nil); try wait("page2",until:{table(browser.window).numberOfRows == 1 && text(browser.window).contains("101–101")})
        try check(try !button("次へ",in:browser.window).isEnabled,"last page disables next")
        try button("前へ",in:browser.window).performClick(nil); try wait("previous",until:{table(browser.window).numberOfRows == 100})
        table(browser.window).selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        try check(try !button("詳細・編集…",in:browser.window).isEnabled && button("区分を変更…",in:browser.window).isEnabled,"multiple selection exposes bulk actions")
        let search = views(browser.window.contentView!).compactMap {$0 as? NSSearchField}.first!
        search.stringValue = "画面経由"; browser.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        try wait("Japanese search",until:{table(browser.window).numberOfRows == 1 && text(browser.window).contains("／ 1件")})
        try check(try service.documentPage(DocumentQuery(search:"画面経由")).total == 1,"search matches persisted Japanese title")
        search.stringValue = ""; browser.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        let type = views(browser.window.contentView!).compactMap {$0 as? NSPopUpButton}.first { $0.itemTitles.contains("区分すべて") }!
        type.selectItem(withTitle:"契約書"); send(type)
        try wait("type filter",until:{table(browser.window).numberOfRows == 50})
        try check(text(browser.window).contains("／ 50件"),"type filter result count")

        let account = try service.save(CRMModule.find("crm_Accounts")!,original:nil,input:["name":.text("文書の関連先")])
        let related = try CRMDocumentsWindow(service:service,linkedTo:account)
        try wait("related list",until:{try button("ファイルを取り込む…",in:related.window).isEnabled})
        let linkedFile = root.appendingPathComponent("取引先の添付.txt"); try Data("取引先への関連付け".utf8).write(to:linkedFile)
        related.importFiles([linkedFile])
        try wait("related import",until:{!related.busy && table(related.window).numberOfRows == 1})
        try check(try service.documentPage(DocumentQuery(linkedTo:DocumentLink(model:"crm_Accounts",id:account["id"].string))).total == 1,"UI import links its parent atomically")
        try check(try !button("既存の文書を関連付ける…",in:related.window).isHidden,"related browser exposes existing-document attachment")

        let longText = String(repeating:"日本語の本文😀\n",count:6000)+"末尾の目印"
        let longFile = root.appendingPathComponent("本文のページ検証.txt"); try Data(longText.utf8).write(to:longFile)
        let longDoc = try service.commitDocument(service.stageDocument(longFile))
        let worker = DocumentProcessingWorker(db:db); var processingError: Error?
        let runner = InvoiceJobRunner(db:db,events:DocumentProcessingWorker.events,runNext:{try await worker.runNext()})
        runner.onError = { processingError = $0 }; runner.kick()
        try wait("native processing",until:{ if runner.isRunning { return false }; return try service.documentRecord(longDoc["id"].string)["processing_status"] == .text("READY") })
        if let error = processingError { throw error }; runner.stop()
        try check(runner.nextWake == nil,"actual processing scheduler settles without idle polling")
        let readyDocument = try service.documentRecord(document["id"].string)
        try check(readyDocument["processing_status"] == .text("READY"),"native worker processes UI-imported file")
        let body = try CRMDocumentTextWindow(service:service,document:readyDocument)
        let bodyView = views(body.window.contentView!).compactMap {$0 as? NSTextView}.first!
        try check(bodyView.string == "新しい版" && !bodyView.isEditable,"production text reader displays extracted Japanese body readonly")
        let longBody = try CRMDocumentTextWindow(service:service,document:longDoc)
        let longBodyView = views(longBody.window.contentView!).compactMap {$0 as? NSTextView}.first!
        try check(try longBodyView.string.utf8.count <= 32771 && button("次へ",in:longBody.window).isEnabled,"large text is paged in the reader")
        var assembled = longBodyView.string
        while try button("次へ",in:longBody.window).isEnabled { try button("次へ",in:longBody.window).performClick(nil); assembled += longBodyView.string }
        try check(assembled == longText,"reader pages preserve every Japanese character and final marker")
        try button("前へ",in:longBody.window).performClick(nil)
        try check(try !longBodyView.string.isEmpty && button("次へ",in:longBody.window).isEnabled,"text reader can navigate back")
        table(related.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        related.reload(); try wait("ready related browser",until:{try button("再読み込み",in:related.window).isEnabled})
        table(related.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try button("再処理",in:related.window).performClick(nil)
        try wait("UI reprocessing request",until:{!related.busy && text(related.window).contains("再処理を予約")})
        try check(try service.documentPage(DocumentQuery(linkedTo:DocumentLink(model:"crm_Accounts",id:account["id"].string))).rows[0]["processing_status"] == .text("PENDING"),"reprocess button queues a durable pending generation")

        let stranger = try db.insert("Users",values:["name":.text("別の利用者"),"email":.text("stranger@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let other = CRMService(db:db,identity:CRMIdentity(id:stranger["id"].string,role:"user",partnerAccountID:nil))
        let hidden = try CRMDocumentsWindow(service:other)
        try wait("other list",until:{try button("ファイルを取り込む…",in:hidden.window).isEnabled})
        try check(table(hidden.window).numberOfRows == 0,"other user sees no private metadata")
        _ = try db.update(stranger,changes:["banned":.integer(1)],actor:identity.id); hidden.reload()
        try wait("revocation",until:{text(hidden.window).contains("この利用者では操作できません")})
        try check(table(hidden.window).numberOfRows == 0,"revoked user has an empty list")
        try check(try !button("ファイルを取り込む…",in:hidden.window).isEnabled && button("閉じる",in:hidden.window).isEnabled,"revoked access disables mutations while allowing close")
        for window in [browser.window,history.window,related.window] {
            window.contentView!.layoutSubtreeIfNeeded()
            let bounds = window.contentView!.bounds
            let controls = views(window.contentView!).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor && !($0 is NSTableView) }
            try check(controls.allSatisfy { bounds.insetBy(dx:-1,dy:-1).contains($0.convert($0.bounds,to:window.contentView)) },"visible controls fit inside \(window.title)")
            try check(table(window).enclosingScrollView!.frame.height >= 250,"document list keeps usable height in \(window.title)")
        }
        for window in [body.window,longBody.window] {
            window.contentView!.layoutSubtreeIfNeeded()
            try check(try window.contentView!.bounds.insetBy(dx:-1,dy:-1).contains(button("閉じる",in:window).convert(button("閉じる",in:window).bounds,to:window.contentView)),"text reader close button fits the window")
            let bodyView = views(window.contentView!).compactMap {$0 as? NSTextView}.first!
            try check(bodyView.visibleRect.width >= 700 && bodyView.enclosingScrollView!.frame.height >= 350,"text reader has a usable text viewport")
        }
        try check(NSApp.windows.allSatisfy {!$0.isVisible},"all tests keep windows off screen")
        print("Document UI: \(checks) checks passed; offscreen AppKit, temporary files, no preview helper or network")
    }
}
