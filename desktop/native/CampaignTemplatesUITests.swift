import AppKit

private final class CampaignTemplatesUIPreview:NativeMailHTMLDrainingViewing {
    func close() {}
    func closeAndDrain(_ completion:@escaping ()->Void) {DispatchQueue.main.async(execute:completion)}
}

@main enum CampaignTemplatesUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func views(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(views) }
    static func button(_ name: String, _ w: NSWindow) throws -> NSButton { guard let b = views(w.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == name}) else { throw NativeDBError.message("Missing button "+name) }; return b }
    static func wait(_ label: String, _ condition: () throws -> Bool) throws { let end = Date().addingTimeInterval(10); while Date() < end { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; throw NativeDBError.message("Timed out: "+label) }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignTemplatesUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TemplatesUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity)
        let parent = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:1100,height:850),styleMask:[.titled],backing:.buffered,defer:false)
        var previewHTML:String?
        let editor = try CampaignTemplateEditor(service:service,record:nil,makePreviewViewer:{ document,_ in previewHTML=document.html;return CampaignTemplatesUIPreview() }); parent.beginSheet(editor.window)
        try check(editor.body.string == "\n","new blank editor")
        editor.window.contentView!.layoutSubtreeIfNeeded()
        for b in views(editor.window.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) { let r = b.convert(b.bounds,to:editor.window.contentView); try check(r.minX >= -1 && r.maxX <= editor.window.contentView!.bounds.width+1 && r.minY >= -1 && r.maxY <= editor.window.contentView!.bounds.height+1,"button fits: "+b.title) }
        try check(editor.descriptionField.enclosingScrollView!.bounds.height >= 50 && editor.body.enclosingScrollView!.bounds.height >= 220,"description/body geometry with AI controls")
        editor.name.stringValue = "日本語メール😀"; editor.subject.stringValue = "{{first_name}}様へ"; editor.descriptionField.string = "説明一行目\n二行目"
        editor.window.makeFirstResponder(editor.body); editor.body.setSelectedRange(NSRange(location:0,length:0)); editor.body.insertText("{{first_name}}様\n営業のご案内😀",replacementRange:editor.body.selectedRange())
        let r = (editor.body.string as NSString).range(of:"営業のご案内")
        editor.body.setSelectedRange(r); try button("太字",editor.window).performClick(nil)
        try check(try CampaignRichText.serialize(editor.body.attributedString()).html.contains("<strong>営業のご案内</strong>"),"bold toolbar serialization")
        editor.body.breakUndoCoalescing(); RunLoop.current.run(until:Date().addingTimeInterval(0.02)); editor.body.undoManager?.undo()
        try check(!(try CampaignRichText.serialize(editor.body.attributedString()).html.contains("<strong>")),"toolbar undo")
        editor.body.undoManager?.redo(); try check(try CampaignRichText.serialize(editor.body.attributedString()).html.contains("<strong>"),"toolbar redo")
        let mode = views(editor.window.contentView!).compactMap{$0 as? NSSegmentedControl}.first!
        func switchMode(_ value: Int) { mode.selectedSegment = value; _ = mode.sendAction(mode.action,to:mode.target) }
        switchMode(2); try wait("preview ready") {previewHTML != nil}; try check(previewHTML!.contains("花子様") && previewHTML!.contains("ご案内"),"merged Japanese preview"); try check(previewHTML!.contains("😀") || previewHTML!.contains("&#128512;") || previewHTML!.contains("&#x1F600;"),"preview preserves emoji scalar")
        switchMode(1); try check(editor.htmlEditor.string.contains("<strong>"),"HTML mode")
        editor.htmlEditor.string += "<p><u>追記</u></p>"; editor.htmlEditor.didChangeText(); switchMode(0)
        try check(editor.body.string.contains("追記"),"HTML edit reflected in rich view")
        try button("保存",editor.window).performClick(nil); try wait("saved editor") { parent.attachedSheet == nil }
        let saved = try service.campaignTemplates().rows[0].record; let full = try service.campaignTemplate(saved["id"].string)
        try check(full["description"].string == "説明一行目\n二行目" && full["content_html"].string.contains("<u>追記</u>"),"multiline/body persisted")
        let legacy = try service.saveCampaignTemplate(nil,input:["name":.text("既存HTML"),"subject_default":.text("件名"),"content_html":.text("<table><tr><td>表</td></tr></table>"),"content_json":.text("{ \"original\": true }")])
        let e2 = try CampaignTemplateEditor(service:service,record:legacy); parent.beginSheet(e2.window); e2.name.stringValue = "本文を変えず名称更新"; try button("保存",e2.window).performClick(nil); try wait("metadata saved") { parent.attachedSheet == nil }
        let updated = try service.campaignTemplate(legacy["id"].string)
        try check(updated["content_html"] == legacy["content_html"] && updated["content_json"] == legacy["content_json"],"actual editor retains legacy HTML/JSON exactly")
        let stale = try CampaignTemplateEditor(service:service,record:updated); parent.beginSheet(stale.window); _ = try service.saveCampaignTemplate(updated,input:["name":.text("別の編集")]); stale.name.stringValue = "消えない下書き"; try button("保存",stale.window).performClick(nil)
        try wait("conflict returned") { try button("保存",stale.window).isEnabled }
        try check(parent.attachedSheet === stale.window && stale.name.stringValue == "消えない下書き" && stale.body.isEditable,"conflict retains editable draft")
        parent.endSheet(stale.window)
        let ui = try CRMTemplatesWindow(service:service); ui.window.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        func ready() throws { try wait("list ready") { try button("再読み込み",ui.window).isEnabled } }
        try ready(); let table = views(ui.window.contentView!).compactMap{$0 as? NSTableView}.first!
        try check(table.numberOfRows == 2 && ui.window.title == "メールテンプレート","Japanese list")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); try check(try button("編集…",ui.window).isEnabled,"row action enabled")
        try button("再読み込み",ui.window).performClick(nil); try check(!table.isEnabled && !(try button("編集…",ui.window).isEnabled),"stale row actions disabled while loading"); try ready()
        let search = views(ui.window.contentView!).compactMap{$0 as? NSSearchField}.first!; search.stringValue = "日本語メール"; ui.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search)); try ready(); try check(table.numberOfRows == 1,"Japanese search")
        try service.deleteCampaignTemplate(full); try button("再読み込み",ui.window).performClick(nil); try ready(); try check(table.numberOfRows == 0,"deleted hidden")
        let trash = try button("削除済みを表示",ui.window); trash.performClick(nil); try ready(); try check(table.numberOfRows == 1,"admin trash filter")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); try button("復元",ui.window).performClick(nil); try ready(); try check(table.numberOfRows == 0,"restore removes from trash")
        trash.performClick(nil); try ready(); try check(table.numberOfRows == 1,"restored live row")
        try db.transaction { for n in 0..<101 { _ = try service.saveCampaignTemplate(nil,input:["name":.text("ページ\(n)"),"subject_default":.text("件名")]) } }
        search.stringValue = "ページ"; ui.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search)); try ready(); try check(table.numberOfRows == 100,"UI page bounded")
        try button("次へ",ui.window).performClick(nil); try ready(); try check(table.numberOfRows == 1,"UI tail page")
        let last = try service.campaignTemplates(search:"ページ",offset:100).rows[0].record; try service.deleteCampaignTemplate(last); try button("再読み込み",ui.window).performClick(nil); try ready(); try check(table.numberOfRows == 100 && !(try button("前へ",ui.window).isEnabled),"deleted tail clamps page")
        print("CampaignTemplatesUITests: \(checks) checks passed")
    }
}
