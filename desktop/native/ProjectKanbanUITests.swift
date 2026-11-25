import AppKit

@main enum ProjectKanbanUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func views(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(views) }
    static func button(_ name: String, _ w: NSWindow) throws -> NSButton { guard let b = views(w.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == name}) else { throw NativeDBError.message("Missing button "+name) }; return b }
    static func wait(_ label: String, _ condition: () throws -> Bool) throws { let end = Date().addingTimeInterval(10); while Date() < end { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; throw NativeDBError.message("Timed out: "+label) }
    static func ready(_ ui: CRMProjectKanbanWindow) throws { try wait("ready") { try button("再読み込み",ui.window).isEnabled } }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("ProjectKanbanUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-KanbanUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity)
        let project = try service.saveProject(original:nil,input:["title":.text("日本語カンバン検証"),"description":.text("テスト"),"visibility":.text("private")]); let id = project["id"].string
        var sections = try service.projectSections(id).rows
        for title in ["進行中","完了","次回"] { sections.append(try service.saveProjectSection(boardID:id,original:nil,title:title)) }
        try db.transaction { for i in 0..<105 { _ = try service.saveProjectTask(sectionID:sections[0]["id"].string,original:nil,input:["title":.text("日本語カード\(i)"),"content":.text("本文😀"),"dueDateAt":.null]) }; for i in 0..<3 { _ = try service.saveProjectTask(sectionID:sections[1]["id"].string,original:nil,input:["title":.text("進行\(i)"),"dueDateAt":.null]) } }
        let ui = CRMProjectKanbanWindow(project:project,service:service); ui.window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); try ready(ui)
        try check(ui.window.title == "プロジェクトのカンバン" && ui.columns.count == 3,"Japanese native board")
        try check(ui.columns[0].table.numberOfRows == 100 && ui.columns[1].table.numberOfRows == 3 && ui.columns[2].table.numberOfRows == 0,"three bounded table columns")
        ui.window.contentView!.layoutSubtreeIfNeeded()
        for c in ui.columns { try check(c.view.bounds.width > 300 && c.table.enclosingScrollView!.bounds.height >= 350,"readable column layout") }
        for b in views(ui.window.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) { let r = b.convert(b.bounds,to:ui.window.contentView); try check(r.minX >= -1 && r.maxX <= 1161 && r.minY >= -1 && r.maxY <= 761,"button inside panel: "+b.title) }
        let source = ui.columns[0], dest = ui.columns[1]
        let cell = source.table.view(atColumn:0,row:0,makeIfNecessary:true) as! CRMKanbanCard
        try check(cell.accessibilityLabel()!.contains("日本語カード104") && cell.accessibilityLabel()!.contains("期限：未設定"),"accessible card text")
        try check(cell.accessibilityPerformPress() && source.table.selectedRow == 0,"accessible card selection")
        let item = source.tableView(source.table,pasteboardWriterForRow:0) as! NSPasteboardItem
        let payload = item.data(forType:CRMKanbanColumn.pasteboardType)!
        try check(!ui.canDrop(Data("bad".utf8),in:dest,row:0) && !ui.canDrop(payload,in:dest,row:-1) && !ui.canDrop(payload,in:dest,row:99),"invalid drops denied")
        try check(ui.drop(payload,in:dest,row:1),"production cross-column drop")
        try ready(ui)
        try check(dest.data!.rows.map{$0.record["title"].string} == ["進行2","日本語カード104","進行1","進行0"],"drop saved exact insertion")
        try check(!ui.canDrop(payload,in:dest,row:0),"old drag payload invalidated")
        let same = dest.tableView(dest.table,pasteboardWriterForRow:3) as! NSPasteboardItem
        try check(ui.drop(same.data(forType:CRMKanbanColumn.pasteboardType)!,in:dest,row:0),"same-column drop")
        try ready(ui); try check(dest.data!.rows[0].record["title"] == .text("進行0"),"same-column saved order")
        let boundary = source.tableView(source.table,pasteboardWriterForRow:0) as! NSPasteboardItem
        let moved = source.data!.rows[0].record["id"], following = source.data!.following!["id"]
        try check(ui.drop(boundary.data(forType:CRMKanbanColumn.pasteboardType)!,in:source,row:100),"drop at page boundary")
        try ready(ui); try check(source.data!.rows[99].record["id"] == moved && source.data!.following!["id"] == following,"boundary respects hidden following row")
        source.next.performClick(nil); try ready(ui); try check(source.data!.offset == 100 && source.table.numberOfRows == 4,"next task page")
        source.previous.performClick(nil); try ready(ui); try check(source.table.numberOfRows == 100,"previous task page")
        try button("次の3列",ui.window).performClick(nil); try ready(ui)
        try check(ui.columns[0].heading.stringValue == "次回" && ui.columns[1].view.isHidden && ui.columns[2].view.isHidden,"last section page")
        try button("前の3列",ui.window).performClick(nil); try ready(ui)
        dest.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try button("上へ",ui.window).performClick(nil); try ready(ui)
        try check(dest.data!.rows[0].record["title"] == .text("進行2"),"keyboard alternative up button")
        try button("下へ",ui.window).performClick(nil); try ready(ui)
        try check(dest.data!.rows[1].record["title"] == .text("進行2"),"keyboard alternative down button")
        try button("完了にする",ui.window).performClick(nil); try ready(ui)
        try check(dest.data!.rows[1].record["taskStatus"] == .text("COMPLETE"),"card complete action")
        try button("未完了に戻す",ui.window).performClick(nil); try ready(ui)
        try check(dest.data!.rows[1].record["taskStatus"] == .text("ACTIVE"),"card reopen action")
        try button("保留にする",ui.window).performClick(nil); try ready(ui)
        try check(dest.data!.rows[1].record["taskStatus"] == .text("PENDING"),"card hold action")
        try button("表示・編集…",ui.window).performClick(nil); try wait("editor") { ui.window.attachedSheet != nil }
        let editor = ui.window.attachedSheet!
        let title = views(editor.contentView!).compactMap{$0 as? NSTextField}.first{$0.isEditable && $0.accessibilityLabel() == "タスク名"}!
        title.stringValue = "カンバンから編集😀"; try button("保存",editor).performClick(nil); try wait("saved editor") { ui.window.attachedSheet == nil }; try ready(ui)
        try check(dest.data!.rows[1].record["title"] == .text("カンバンから編集😀"),"actual Japanese editor")
        try button("コメント…",ui.window).performClick(nil); try wait("comment sheet") { ui.window.attachedSheet != nil }
        try check(ui.window.attachedSheet!.title == "タスクのコメント","comment entry point"); try button("閉じる",ui.window.attachedSheet!).performClick(nil); try wait("comments closed") { ui.window.attachedSheet == nil }; try ready(ui)
        try button("文書…",ui.window).performClick(nil); try wait("document sheet") { ui.window.attachedSheet != nil }
        try check(ui.window.attachedSheet!.title.contains("文書"),"document entry point"); try button("閉じる",ui.window.attachedSheet!).performClick(nil); try wait("documents closed") { ui.window.attachedSheet == nil }; try ready(ui)
        source.details.performClick(nil); try wait("create task") { ui.window.attachedSheet != nil }
        let creator = ui.window.attachedSheet!, newTitle = views(creator.contentView!).compactMap{$0 as? NSTextField}.first{$0.isEditable && $0.accessibilityLabel() == "タスク名"}!
        newTitle.stringValue = "カンバンから新規"; try button("保存",creator).performClick(nil); try wait("created") { ui.window.attachedSheet == nil }; try ready(ui)
        try check(source.data!.rows[0].record["title"] == .text("カンバンから新規"),"add task in correct column")
        source.rename.performClick(nil); try wait("rename column") { ui.window.attachedSheet != nil }
        let rename = ui.window.attachedSheet!, columnName = views(rename.contentView!).compactMap{$0 as? NSTextField}.first{$0.isEditable}!
        columnName.stringValue = "受付済み"; try button("保存",rename).performClick(nil); try wait("renamed") { ui.window.attachedSheet == nil }; try ready(ui)
        try check(source.heading.stringValue == "受付済み","rename section")
        let parent = CRMProjectWindow(project:try db.get("Boards",key:["id":project["id"]])!,service:service); parent.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        try button("カンバン…",parent.window).performClick(nil); try wait("parent opens kanban") { parent.window.attachedSheet != nil }
        try check(parent.window.attachedSheet!.title == "プロジェクトのカンバン","project integration")
        try wait("integrated ready") { try button("再読み込み",parent.window.attachedSheet!).isEnabled }; try button("閉じる",parent.window.attachedSheet!).performClick(nil); try wait("integrated close") { parent.window.attachedSheet == nil }
        let user = try db.insert("Users",values:["name":.text("閲覧者"),"email":.text("reader@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        _ = try service.setProjectShared(try db.get("Boards",key:["id":project["id"]])!,userID:user["id"].string,shared:true)
        let reader = CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil)), readUI = CRMProjectKanbanWindow(project:project,service:CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil)))
        readUI.window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); try ready(readUI); readUI.columns[0].table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try check(!readUI.columns[0].add.isEnabled && !(try button("移動…",readUI.window).isEnabled) && (try button("表示・編集…",readUI.window).isEnabled),"read-only controls")
        try check(readUI.columns[0].tableView(readUI.columns[0].table,pasteboardWriterForRow:0) == nil,"read-only drag denied")
        try button("表示・編集…",readUI.window).performClick(nil); try wait("read-only editor") { readUI.window.attachedSheet != nil }
        try check(views(readUI.window.attachedSheet!.contentView!).compactMap{$0 as? NSTextField}.filter{$0.accessibilityLabel() == "タスク名"}.allSatisfy{!$0.isEnabled},"read-only task editor")
        try button("閉じる",readUI.window.attachedSheet!).performClick(nil); try wait("read editor closed") { readUI.window.attachedSheet == nil }; try ready(readUI)
        _ = try service.setProjectShared(try db.get("Boards",key:["id":project["id"]])!,userID:reader.identity.id,shared:false)
        try button("再読み込み",readUI.window).performClick(nil); try ready(readUI)
        try check(readUI.columns.allSatisfy{$0.data == nil && $0.table.numberOfRows == 0},"revoked access clears all cards")
        let reopened = CRMProjectKanbanWindow(project:project,service:service); reopened.window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); try ready(reopened)
        try check(reopened.columns[0].heading.stringValue == "受付済み" && reopened.columns[1].data!.rows[1].record["title"] == .text("カンバンから編集😀"),"reopened board preserves order and edits")
        try check(try db.integrityCheck(),"database integrity")
        print("Native kanban UI: \(checks) checks passed; native cards, drag payload/drop persistence, paging, Japanese editing and access revocation; no network")
    }
}
