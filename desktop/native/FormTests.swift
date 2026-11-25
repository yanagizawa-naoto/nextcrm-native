import AppKit

@main enum FormTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func views(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap(views) }
    static func settle() { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("FormTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-FormTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
        let products = CRMModule.find("crm_Products")!
        let numbers = try FormDraft(module:products,schema:db.schema.model(products.model),input:db.initialValues(products.model),isNew:true)
        numbers.setText("unit_price","-")
        try check(numbers.values["unit_price"] == .text("-") && numbers.hasChanges,"incomplete numeric edit is retained")
        try check((try? numbers.normalized()) == nil,"invalid number is rejected on save, not lost")
        numbers.setText("unit_price"," 1,250.50 "); try check(try numbers.normalized()["unit_price"] == .text("1250.50"),"numeric normalization after recycling")
        numbers.setText("name"," 日本語の😀商品 "); try check(try numbers.normalized()["name"] == .text("日本語の😀商品"),"Japanese and Unicode text survive normalization")
        let datesModule = CRMModule(model:"crm_Orders",title:"日付",singular:"日付",entity:"order",nameFields:[],columns:[],fields:[EditorField("requestedDeliveryDate","日付",.date),EditorField("note","メモ",.multiline)])
        let now = Date(timeIntervalSince1970:1800000000)
        let dates = try FormDraft(module:datesModule,schema:db.schema.model("crm_Orders"),input:[:],isNew:true,now:now)
        try check(!dates.hasChanges,"unopened optional date starts unchanged")
        dates.set("requestedDeliveryDate",.date(now.addingTimeInterval(86400),false)); try check(!dates.hasChanges,"disabled date does not become a saved date")
        dates.set("requestedDeliveryDate",.date(now.addingTimeInterval(86400),true)); try check(try dates.normalized()["requestedDeliveryDate"] == .text(ISO8601DateFormatter().string(from:now.addingTimeInterval(86400))),"chosen date retained while disabled then enabled")
        dates.setText("note","  日本語\n次の行  "); try check(try dates.normalized()["note"] == .text("  日本語\n次の行  "),"multiline whitespace and newlines retained")
        let listModule = CRMModule(model:"crm_Orders",title:"一覧",singular:"一覧",entity:"order",nameFields:[],columns:[],fields:[EditorField("note","行",.lines),EditorField("status","状態",.choice([("DRAFT","下書き")]))])
        let list = try FormDraft(module:listModule,schema:db.schema.model("crm_Orders"),input:["note":.text("[\"日本\",\"二行目\"]"),"status":.text("FUTURE")],isNew:false)
        try check(list.values["note"] == .text("日本\n二行目"),"JSON lines decode without mounting editor")
        list.setText("note"," 日本\n\n 次の行 "); try check(try list.normalized()["note"] == .text("[\"日本\",\"次の行\"]"),"JSON lines normalized at save")
        try check(try list.normalized()["status"] == .text("FUTURE"),"unknown legacy choice remains available")

        let accountModule = CRMModule.find("crm_Accounts")!; var saved: [String:SQLValue] = [:]
        let form = try CRMEditor(module:accountModule,record:nil,linkedTo:nil,service:service,onSave:{ saved = $0 })
        let content = views(form.window.contentView!).compactMap { $0 as? CRMFormContentView }.first!
        let scroll = content.enclosingScrollView!
        func control(_ key: String) -> NSView? { content.subviews.first { $0.identifier?.rawValue == key } }
        func reveal(_ key: String) throws {
            guard let index = accountModule.fields.firstIndex(where: { $0.key == key }) else { throw NativeDBError.message("missing test field") }
            if let proxy = content.accessibilityChildren()?[index] as? CRMFormAccessibilityField { _ = proxy.accessibilityPerformPress() }
            else if let view = control(key) { content.scrollToVisible(view.frame) }
            settle()
        }
        try check(content.subviews.count < accountModule.fields.count,"offscreen controls not created eagerly")
        try check(!views(content).contains { $0 is NSTextView },"no multiline text engine before use")
        let name = control("name") as! NSTextField; name.stringValue = "仮想化の検証株式会社"
        form.window.makeFirstResponder(nil)
        try reveal("shipping_street"); let street = control("shipping_street") as! NSTextField; street.stringValue = "入力した住所1-2-3"
        form.window.makeFirstResponder(nil); try reveal("description")
        let long = control("description") as! DeferredTextInput
        // AX focus activates a native editor. Preserve it across IME composition and offscreen transitions.
        long.focusEditor(); settle(); let text = long.editor!
        text.setMarkedText("にほん",selectedRange:NSRange(location:3,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        try check(text.hasMarkedText(),"native Japanese composition remains marked")
        scroll.contentView.scroll(to:.zero); scroll.reflectScrolledClipView(scroll.contentView); settle()
        try check(control("description") === long && text.hasMarkedText(),"active composing editor is pinned while offscreen")
        text.insertText("日本語",replacementRange:NSRange(location:NSNotFound,length:0)); text.breakUndoCoalescing(); settle()
        try check(!text.hasMarkedText() && text.string == "日本語","native composition commits once")
        text.insertText("の追記",replacementRange:NSRange(location:NSNotFound,length:0)); text.breakUndoCoalescing(); settle()
        let undo = text.undoManager!; try check(undo.canUndo,"native undo available")
        form.window.makeFirstResponder(nil); try reveal("name"); settle()
        try check(control("description") == nil,"inactive multiline view leaves the visible hierarchy")
        try check((control("name") as? NSTextField)?.stringValue == "仮想化の検証株式会社","text survives removal and re-creation")
        try reveal("description"); let restored = control("description") as! DeferredTextInput
        try check(restored.editor === text && text.string == "日本語の追記","edited multiline reuses native text engine and selection state")
        undo.undo(); settle(); try check(text.string == "日本語","undo survives offscreen removal")
        undo.redo(); settle(); try check(text.string == "日本語の追記","redo survives offscreen removal")
        form.window.makeFirstResponder(nil); try reveal("name")
        for _ in 0..<20 { form.window.selectNextKeyView(nil); settle() }
        try check(scroll.documentVisibleRect.minY > 0,"keyboard navigation reaches fields outside initial viewport")
        let save = views(form.window.contentView!).compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "s" }!
        save.performClick(nil)
        try check(saved["name"] == .text("仮想化の検証株式会社") && saved["shipping_street"] == .text("入力した住所1-2-3") && saved["description"] == .text("日本語の追記"),"save captures mounted and unmounted values together")
        try check(try db.page("crm_Accounts",fields:[]).total == 0,"callback form has not mutated business data")
        print("{\"ok\":true,\"suite\":\"FormDraftAndVirtualUI\",\"checks\":\(checks)}")
    }
}
