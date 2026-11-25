import AppKit

@main enum NativeSearchUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func wait(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while try !condition() { guard Date() < deadline else { throw NativeDBError.message("UI wait timed out") }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    static func button(_ title: String, _ window: NSWindow) throws -> NSButton {
        guard let control = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeDBError.message("Missing button " + title) }; return control
    }
    static func field(_ label: String, _ window: NSWindow) throws -> NSTextField {
        guard let control = views(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) else { throw NativeDBError.message("Missing field " + label) }; return control
    }
    static func table(_ window: NSWindow) throws -> NSTableView { guard let value = views(window.contentView!).compactMap({ $0 as? NSTableView }).first else { throw NativeDBError.conflict }; return value }
    static func click(_ title: String, _ window: NSWindow) throws { let value = try button(title, window); try check(value.isEnabled, "enabled: " + title); value.performClick(nil) }
    static func layout(_ window: NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        for item in views(window.contentView!) where item is NSControl && !item.isHiddenOrHasHiddenAncestor {
            let bounds = window.contentView!.bounds, frame = item.convert(item is NSTableView ? item.visibleRect : item.bounds, to: window.contentView)
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.minY >= -1 && frame.maxX <= bounds.width + 1 && frame.maxY <= bounds.height + 1, "control in bounds " + (item.accessibilityLabel() ?? ""))
        }
    }
    static func setQuery(_ value: String, _ controller: NativeSearchWindow) throws {
        let field = try field(controller.window.title == "文書を検索" ? "文書検索の検索語" : "横断検索の検索語", controller.window); field.stringValue = value
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    static func main() {
        do { try run(); print("Native global search UI: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-SearchUI-" + UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        var accounts: [NativeRecord] = []
        for i in 0..<15 { accounts.append(try service.save(CRMModule.find("crm_Accounts")!, original: nil, input: ["name": .text("東京営業 \(i)"), "description": .text("日本語の概要")])) }
        var values = [Float](repeating: 0, count: 1536); values[0] = 1
        // Keyword results use stable ID order and retain ten of these fifteen
        // accounts. Choose a guaranteed keyword hit for the hybrid assertion.
        let hybridAccount = accounts.min { $0["id"].string < $1["id"].string }!
        _ = try NativeEmbeddingIndex(db: db).save(.account, source: hybridAccount, vector: NativeEmbeddingVector(values), contentHash: NativeEmbeddingVector.hash("東京"), actor: service.identity.id)
        let project = try service.saveProject(original: nil, input: ["title": .text("東京のプロジェクト"), "description": .text("東京のプロジェクトの説明"), "visibility": .text("private")])
        _ = try service.createProjectTaskInBoard(project["id"].string, input: ["title": .text("東京のタスク"), "user": .text(service.identity.id), "priority": .text("low")])
        _ = try db.insert("Users", values: ["name": .text("東京の担当者"), "email": .text("tokyo@example.invalid"), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: service.identity.id)
        let document = try db.insert("Documents", values: ["document_name": .text("東京の文書"), "document_file_url": .text("local"), "document_file_mimeType": .text("text/plain"), "createdBy": .text(service.identity.id), "date_created": .text("2000-01-01T00:00:00Z")], actor: service.identity.id)
        let keys = NativeAIKeys(service: service, store: NativeAIQAServices(), environment: NativeAIEnvironment(lookup: { _ in "qa-search-ui" })); var calls = 0
        let controller = try NativeSearchWindow(engine: NativeSearchEngine(keys: keys, generate: { text, key in calls += 1; try check(text == "東京", "UI trims query before provider"); return try await NativeAIQAServices.generate(text, key) }))
        let window = controller.window, results = try table(window)
        try check(window.title == "横断検索" && results.numberOfRows == 0, "Japanese empty search screen")
        try setQuery("東", controller); try click("検索", window)
        try check(try field("横断検索の状態", window).stringValue.contains("2文字") && calls == 0, "short query validated before API")
        try setQuery(" 東京 ", controller); try click("検索", window)
        try wait { try !button("検索を中止", window).isEnabled && results.numberOfRows == 14 }
        try check(calls == 1 && field("横断検索の状態", window).stringValue.contains("文字と意味"), "one explicit search yields all expected facets")
        try layout(window)
        guard let filter = views(window.contentView!).compactMap({ $0 as? NSPopUpButton }).first else { throw NativeDBError.conflict }
        filter.selectItem(at: 1); filter.sendAction(filter.action, to: filter.target)
        try check(results.numberOfRows == 10 && calls == 1, "local kind filter does not call provider")
        results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try check(try button("選択した結果を開く", window).isEnabled && field("検索結果の詳細", window).stringValue.contains("文字・意味"), "selected hybrid hit has Japanese match details")
        try click("選択した結果を開く", window)
        try check(controller.selectedResult?.kind == .accounts && controller.selectedResult?.id == hybridAccount["id"].string, "selected target handed to app navigation")
        filter.selectItem(at: 8); filter.sendAction(filter.action, to: filter.target)
        try check(results.numberOfRows == 1, "documents facet remains available")
        try setQuery("別の検索", controller)
        try check(results.numberOfRows == 0 && !button("選択した結果を開く", window).isEnabled && calls == 1, "editing query clears stale results without automatic paid call")

        // A highlighted document remains reachable beyond the normal first page.
        try db.transaction {
            for i in 0..<101 { _ = try db.insert("Documents", values: ["document_name": .text("別の文書 \(i)"), "document_file_url": .text("local"), "document_file_mimeType": .text("text/plain"), "createdBy": .text(service.identity.id), "date_created": .text("2026-01-01T00:00:00Z")], actor: service.identity.id) }
        }
        let documents = try CRMDocumentsWindow(service: service, focusedDocumentID: document["id"].string), documentsTable = try table(documents.window)
        try wait { try documentsTable.numberOfRows == 1 && button("詳細・編集…", documents.window).isEnabled }
        try check(documentsTable.selectedRow == 0, "search destination highlights exact document outside first normal page")
        try click("すべての文書", documents.window); try wait { documentsTable.numberOfRows == 100 }
        try check(try button("すべての文書", documents.window).isHidden && button("次へ", documents.window).isEnabled, "highlight can return to full paginated document browser")
        try layout(documents.window)

        var entered = false, cancelled = false
        let slow = try NativeSearchWindow(engine: NativeSearchEngine(keys: keys, generate: { text, key in
            if text == "遅い検索" { entered = true; do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { cancelled = true; throw error } }
            return try await NativeAIQAServices.generate(text, key)
        }))
        try setQuery("遅い検索", slow); try click("検索", slow.window); try wait { entered }
        try click("検索を中止", slow.window); try wait { cancelled }
        try check(try table(slow.window).numberOfRows == 0 && field("横断検索の状態", slow.window).stringValue.contains("中止"), "cancel stops pending provider without stale results")
        entered = false; cancelled = false
        try setQuery("遅い検索", slow); try click("検索", slow.window); try wait { entered }
        try setQuery("東京", slow); try click("検索", slow.window)
        try wait { try cancelled && !button("検索を中止", slow.window).isEnabled && table(slow.window).numberOfRows > 0 }
        try check(try field("横断検索の状態", slow.window).stringValue.contains("文字と意味"), "new search replaces cancelled older request")
        let currentDocument = try db.get("Documents",key:["id":document["id"]])!
        _ = try db.update(currentDocument,changes:["summary":.text("東京の検索結果の要約"),"document_system_type":.text("CONTRACT")],actor:service.identity.id)
        _ = try db.insert("DocumentsToAccounts",values:["document_id":document["id"],"account_id":hybridAccount["id"]],actor:service.identity.id)
        let documentSearch = try NativeSearchWindow(engine:NativeSearchEngine(keys:keys,generate:NativeAIQAServices.generate,documentCandidates:true))
        try setQuery("東京",documentSearch); try click("検索",documentSearch.window)
        try wait { try table(documentSearch.window).numberOfRows == 1 && !button("検索を中止",documentSearch.window).isEnabled }
        try table(documentSearch.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(try field("検索結果の詳細",documentSearch.window).stringValue.contains("契約書") && field("検索結果の詳細",documentSearch.window).stringValue.contains("取引先："+hybridAccount["name"].string), "document candidate shows Japanese category and linked account")
        try layout(documentSearch.window)
        try click("選択した結果を開く",documentSearch.window)
        try check(documentSearch.selectedResult?.id == document["id"].string, "document candidate returns exact focus destination")

        try db.transaction {
            for i in 0..<107 { _ = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text(String(format:"選択対象 %03d",i)),"createdBy":.text(service.identity.id)],actor:service.identity.id) }
        }
        let longAccount = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text(String(repeating:"長",count:700)+"末尾識別"),"createdBy":.text(service.identity.id)],actor:service.identity.id)
        var picked:NativeRecord?
        let picker = CRMReferencePicker(model:"crm_Accounts",service:service) { picked = $0 }; picker.start()
        let pickerTable = try table(picker.window), pickerQuery = try field("関連先を検索",picker.window)
        try wait { pickerTable.numberOfRows == 100 }
        pickerQuery.stringValue = "選択対象"; picker.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:pickerQuery))
        try check(pickerTable.numberOfRows == 0 && !button("選択",picker.window).isEnabled, "new account scan clears stale selectable rows immediately")
        try wait { try pickerTable.numberOfRows == 100 && button("次へ",picker.window).isEnabled }
        try click("次へ",picker.window); try wait { pickerTable.numberOfRows == 7 }
        try check(try button("前へ",picker.window).isEnabled && !button("次へ",picker.window).isEnabled, "account picker reaches last partial page")
        pickerQuery.stringValue = "末尾識別"; picker.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:pickerQuery))
        try wait { pickerTable.numberOfRows == 1 }
        pickerTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); try click("選択",picker.window)
        try check(picked?["id"] == longAccount["id"], "late-in-name search chooses correct account identity")
        try layout(picker.window)
        var stalePicked = false
        let stalePicker = CRMReferencePicker(model:"crm_Accounts",service:service) { if $0 != nil { stalePicked = true } }; stalePicker.start()
        try wait { try table(stalePicker.window).numberOfRows == 100 }
        try table(stalePicker.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let admin = try db.get("Users", key: ["id": .text(service.identity.id)])!
        _ = try db.update(admin, changes: ["userStatus": .text("INACTIVE")], actor: service.identity.id)
        try click("選択",stalePicker.window)
        try check(try !stalePicked && table(stalePicker.window).numberOfRows == 0 && !button("選択",stalePicker.window).isEnabled, "revoked actor cannot select cached account reference")
        let slowFilter = views(slow.window.contentView!).compactMap({ $0 as? NSPopUpButton }).first!
        slowFilter.sendAction(slowFilter.action, to: slowFilter.target)
        try check(try table(slow.window).numberOfRows == 0 && !button("選択した結果を開く", slow.window).isEnabled, "revoked authentication clears cached result display")
    }
}
