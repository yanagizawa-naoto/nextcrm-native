import AppKit

@main enum NativeCurrencyAdministrationUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func button(_ title: String, _ window: NSWindow) throws -> NSButton {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeDBError.message("button " + title) }; return value
    }
    static func field(_ label: String, _ window: NSWindow) throws -> NSTextField {
        guard let value = views(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) else { throw NativeDBError.message("field " + label) }; return value
    }
    static func table(_ window: NSWindow) -> NSTableView { views(window.contentView!).compactMap { $0 as? NSTableView }.first! }
    static func popup(_ window: NSWindow) -> NSPopUpButton { views(window.contentView!).compactMap { $0 as? NSPopUpButton }.first! }
    static func click(_ title: String, _ window: NSWindow) throws { let value = try button(title, window); try check(value.isEnabled, title + " enabled"); value.sendAction(value.action, to: value.target) }
    static func wait(_ label: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if try condition() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        throw NativeDBError.message("UI timeout: " + label)
    }
    static func ready(_ window: NSWindow) throws { try wait("main ready") { try button("再読み込み", window).isEnabled } }
    static func child(_ window: NSWindow) throws -> NSWindow { try wait("sheet") { window.attachedSheet != nil }; return window.attachedSheet! }
    static func search(_ text: String, _ window: NSWindow) throws { let input = try field("通貨設定の検索", window); input.stringValue = text; input.sendAction(input.action, to: input.target); try ready(window) }
    static func select(_ window: NSWindow) throws { try check(table(window).numberOfRows > 0, "row exists"); table(window).selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    static func mode(_ rates: Bool, _ window: NSWindow) throws { let value = popup(window); value.selectItem(at: rates ? 1 : 0); value.sendAction(value.action, to: value.target); try ready(window) }
    static func columnsFit(_ window: NSWindow) throws {
        let list = table(window); window.contentView!.layoutSubtreeIfNeeded()
        try check(list.rect(ofColumn: list.tableColumns.count - 1).maxX <= list.visibleRect.maxX + 1, "initial columns remain inside viewport after mode switch: right=\(list.rect(ofColumn: list.tableColumns.count - 1).maxX), visible=\(list.visibleRect), frame=\(list.frame), widths=\(list.tableColumns.map(\.width))")
        try check(list.tableColumns.allSatisfy { $0.width >= $0.minWidth } && list.columnAutoresizingStyle == .noColumnAutoresizing, "explicit column minimums and no intermediate auto expansion")
        try check(list.enclosingScrollView?.hasHorizontalScroller == true, "expanded user columns remain horizontally accessible")
    }
    static func snapshot(_ window: NSWindow, _ url: URL) throws {
        window.appearance = NSAppearance(named: .aqua); let view = window.contentView!; view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for control in views(view).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
            let frame = control.convert(control is NSTableView ? control.visibleRect : control.bounds, to: view)
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.maxX <= view.bounds.width + 1 && frame.minY >= -1 && frame.maxY <= view.bounds.height + 1, "control inside bounds: \(type(of: control)) \((control as? NSButton)?.title ?? control.accessibilityLabel() ?? "") \(frame)")
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NativeDBError.message("snapshot") }
        window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        guard let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let content = bitmap.cgImage else { throw NativeDBError.message("bitmap") }
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)); context.draw(content, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw NativeDBError.message("png") }; try data.write(to: url)
    }
    static func main() {
        do { try run(); print("{\"checks\":\(checks),\"exit\":0}") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CurrencyUI-" + UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        var admin = try db.insert("Users", values: ["name": .text("通貨管理者"), "email": .text("currency-ui@example.invalid"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: "fixture")
        let service = CRMService(db: db, identity: .init(id: admin["id"].string, role: "admin", partnerAccountID: nil)), api = NativeCurrencyAdministration(service: service)
        _ = try api.create(code: "EUR", name: "ユーロ", symbol: "€"); _ = try api.create(code: "JPY", name: "日本円", symbol: "¥"); _ = try api.create(code: "USD", name: "米ドル", symbol: "$")
        for i in 0..<100 { _ = try api.create(code: String(format: "A%02d", i), name: "検証通貨\(i)", symbol: "A") }
        try api.setDefault(code: "JPY")
        var discard = false, confirmations = 0, changes = 0
        let controller = try NativeCurrencyAdministrationWindow(service: service, confirmDiscard: { _ in confirmations += 1; return discard }); controller.onChanged = { changes += 1 }
        let window = controller.window; controller.start(); try ready(window)
        try check(window.title == "通貨と為替レートの設定" && table(window).numberOfRows == 100, "Japanese bounded currency table")
        try columnsFit(window)
        try snapshot(window, resources.appendingPathComponent("build/admin-currency-main.png"))
        try click("次の100件", window); try ready(window); try check(table(window).numberOfRows == 3, "second currency page")
        try search("JPY", window); try select(window)
        try check(try !button("有効・無効を切替", window).isEnabled && !button("既定の通貨に設定", window).isEnabled, "default cannot be disabled in UI")
        try search("USD", window); try select(window); try click("有効・無効を切替", window); try ready(window)
        try check(try db.get("Currency", key: ["code": .text("USD")])?["isEnabled"] == .integer(0), "disabled persisted")
        try select(window); try click("既定の通貨に設定", window); try ready(window)
        try check(try db.get("Currency", key: ["code": .text("USD")])?["isDefault"] == .integer(1) && db.get("Currency", key: ["code": .text("USD")])?["isEnabled"] == .integer(1), "default change enables currency")
        try click("追加…", window); var sheet = try child(window)
        try field("通貨コード（3文字）", sheet).stringValue = "cad"; try field("通貨の名称", sheet).stringValue = "カナダドル"; try field("通貨記号", sheet).stringValue = "C$"
        try click("キャンセル", sheet); try check(window.attachedSheet === sheet && confirmations == 1, "unsaved cancellation retained")
        discard = true; try click("キャンセル", sheet); try wait("discard") { window.attachedSheet == nil }; try ready(window)
        try click("追加…", window); sheet = try child(window)
        try field("通貨コード（3文字）", sheet).stringValue = "cad"; try field("通貨の名称", sheet).stringValue = "カナダドル"; try field("通貨記号", sheet).stringValue = "C$"
        try snapshot(sheet, resources.appendingPathComponent("build/admin-currency-editor.png"))
        try click("保存", sheet); try wait("created") { window.attachedSheet == nil }; try ready(window)
        try check(try db.get("Currency", key: ["code": .text("CAD")])?["name"] == .text("カナダドル"), "create uppercases source code")
        try mode(true, window); try check(table(window).tableColumns.first?.title == "元通貨", "rate columns describe currencies, not dates")
        for _ in 0..<3 { try columnsFit(window); try mode(false, window); try columnsFit(window); try mode(true, window) }
        try columnsFit(window)
        try check(table(window).tableColumns.suffix(2).allSatisfy { $0.width >= 180 }, "both rate timestamps retain readable width")
        let firstColumn = table(window).tableColumns[0], originalWidth = table(window).tableColumns[0].width
        firstColumn.width += 400; table(window).tile()
        try check(table(window).rect(ofColumn: 5).maxX > table(window).visibleRect.maxX && table(window).enclosingScrollView?.hasHorizontalScroller == true, "user column enlargement has a horizontal scrolling path")
        firstColumn.width = originalWidth; try mode(false, window); try mode(true, window); try columnsFit(window)
        try click("追加…", window); sheet = try child(window)
        try field("元通貨のコード", sheet).stringValue = "USD"; try field("換算先のコード", sheet).stringValue = "JPY"; try field("元通貨1単位の換算額", sheet).stringValue = "150.123456789"
        try click("保存", sheet); try wait("rate created") { window.attachedSheet == nil }; try ready(window)
        try check(try NativeCurrencyAdministration.rate(from: "USD", to: "JPY", db: db)?["rate"] == .text("150.12345679"), "manual rate rounds at numeric18,8 boundary")
        try select(window); try click("レートを編集…", window); sheet = try child(window)
        try check(try !field("元通貨のコード", sheet).isEnabled && !field("換算先のコード", sheet).isEnabled, "existing pair immutable")
        try field("元通貨1単位の換算額", sheet).stringValue = "152"
        _ = try api.saveRate(from: "USD", to: "JPY", input: "151")
        try click("保存", sheet); try wait("conflict") { try button("保存", sheet).isEnabled && field("通貨編集の操作結果", sheet).stringValue.contains("別の操作") }
        try check(try NativeCurrencyAdministration.rate(from: "USD", to: "JPY", db: db)?["rate"] == .text("151"), "stale rate editor refused")
        try click("キャンセル", sheet); try wait("conflict closed") { window.attachedSheet == nil }; try ready(window)
        _ = try NativeCurrencyAdministration.upsertRate(from: "EUR", to: "USD", value: 1.25, source: "ECB", db: db, actor: "fixture", at: Date())
        try click("再読み込み", window); try ready(window)
        let toggle = try button("ECBの為替レートを自動更新する（平日17時・UTC）", window); toggle.state = .on; toggle.sendAction(toggle.action, to: toggle.target); try ready(window)
        try check(try api.settings().enabled, "ECB toggle persisted")
        try search("EUR", window); try select(window); try check(try !button("レートを編集…", window).isEnabled, "automatic ECB edit disabled")
        try snapshot(window, resources.appendingPathComponent("build/admin-currency-rates.png"))
        try click("今すぐECB更新", window); try ready(window)
        try check(try api.updateJobs().first?.status == "pending", "UI queues without performing transport")
        try click("更新をキャンセル", window); try ready(window); try check(try api.updateJobs().first?.status == "cancelled", "UI cancellation persisted")
        toggle.state = .off; toggle.sendAction(toggle.action, to: toggle.target); try ready(window); try select(window)
        try check(try button("レートを編集…", window).isEnabled && !button("今すぐECB更新", window).isEnabled, "disabled automation permits manual editing")
        try click("レートを編集…", window); sheet = try child(window); try field("元通貨1単位の換算額", sheet).stringValue = "2"
        admin = try db.update(admin, changes: ["banned": .integer(1)], actor: service.identity.id)
        try click("保存", sheet); try wait("current authority") { try button("保存", sheet).isEnabled && field("通貨編集の操作結果", sheet).stringValue.contains("この利用者") }
        try check(try NativeCurrencyAdministration.rate(from: "EUR", to: "USD", db: db)?["rate"] == .text("1.25"), "banned admin cannot publish retained form")
        try click("キャンセル", sheet); try wait("revoked child closes") { window.attachedSheet == nil }; try click("再読み込み", window); try ready(window)
        try check(table(window).numberOfRows == 0 && !(try button("追加…", window).isEnabled), "revoked directory cleared")
        try check(changes >= 7 && controller.confirmDiscard(), "callbacks and child cleanup")
    }
}
