import AppKit

@main enum NativeCRMConfigurationUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func field(_ label: String, _ window: NSWindow) throws -> NSTextField {
        guard let control = views(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) else { throw NativeDBError.message("field " + label) }; return control
    }
    static func popup(_ label: String, _ window: NSWindow) throws -> NSPopUpButton {
        guard let control = views(window.contentView!).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == label }) else { throw NativeDBError.message("popup " + label) }; return control
    }
    static func button(_ title: String, _ window: NSWindow) throws -> NSButton {
        guard let control = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeDBError.message("button " + title) }; return control
    }
    static func table(_ window: NSWindow) throws -> NSTableView {
        guard let table = views(window.contentView!).compactMap({ $0 as? NSTableView }).first else { throw NativeDBError.message("table") }; return table
    }
    static func click(_ title: String, _ window: NSWindow) throws { let control = try button(title, window); try check(control.isEnabled, title + " enabled"); control.sendAction(control.action, to: control.target) }
    static func wait(_ label: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if try condition() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        throw NativeDBError.message("UI wait: " + label)
    }
    static func ready(_ window: NSWindow) throws { try wait("main ready") { try button("再読み込み", window).isEnabled } }
    static func editor(_ window: NSWindow) throws -> NSWindow { try wait("sheet") { window.attachedSheet != nil }; return window.attachedSheet! }
    static func dismiss(_ window: NSWindow) throws { try click("キャンセル", window); RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
    static func search(_ text: String, _ window: NSWindow, replacement: Bool = false) throws {
        let control = try field(replacement ? "置き換え先の検索" : "選択肢の検索", window)
        control.stringValue = text; control.sendAction(control.action, to: control.target)
        if replacement { try wait("replacement ready") { try popup("置き換え先", window).isEnabled } } else { try ready(window) }
    }
    static func selectKind(_ kind: NativeCRMConfiguration.Kind, _ window: NSWindow) throws {
        let control = try popup("選択肢の種類", window); control.selectItem(at: NativeCRMConfiguration.Kind.allCases.firstIndex(of: kind)!)
        control.sendAction(control.action, to: control.target); try ready(window)
    }
    static func selectFirst(_ window: NSWindow) throws { let view = try table(window); try check(view.numberOfRows > 0, "row available"); view.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    static func snapshot(_ window: NSWindow, to url: URL) throws {
        window.appearance = NSAppearance(named: .aqua)
        window.contentView!.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for view in views(window.contentView!).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
            let frame = view.convert(view is NSTableView ? view.visibleRect : view.bounds, to: window.contentView)
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.maxX <= window.contentView!.bounds.width + 1 && frame.minY >= -1 && frame.maxY <= window.contentView!.bounds.height + 1, "visible control inside window: " + (view.accessibilityLabel() ?? ""))
        }
        guard let bitmap = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) else { throw NativeDBError.message("snapshot") }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
        }
        // A content-view cache omits the window's opaque background. Composite
        // it onto that background so transparent pixels do not hide black text
        // when the proof image is opened in a dark image viewer.
        guard let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let content = bitmap.cgImage else { throw NativeDBError.message("snapshot background") }
        context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.draw(content, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        guard let composed = context.makeImage(), let data = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { throw NativeDBError.message("png") }
        try data.write(to: url)
    }
    static func main() {
        do { try run(); print("{\"checks\":\(checks),\"exit\":0}") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Configuration-UI-" + UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        var admin = try db.insert("Users", values: ["name": .text("隔離管理者"), "email": .text("configuration-ui@example.invalid"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: "fixture")
        let service = CRMService(db: db, identity: .init(id: admin["id"].string, role: "admin", partnerAccountID: nil)), api = NativeCRMConfiguration(service: service)
        for kind in NativeCRMConfiguration.Kind.allCases {
            _ = try api.create(kind, name: "種類A"); _ = try api.create(kind, name: "種類B")
        }
        for i in 0..<105 { _ = try api.create(.industry, name: String(format: "項目%03d", i)) }
        _ = try api.create(.industry, name: "100%_名称")
        var discard = false, confirmations = 0, changes = 0
        let controller = try NativeCRMConfigurationWindow(service: service, confirmDiscard: { _ in confirmations += 1; return discard })
        controller.onChanged = { changes += 1 }
        let window = controller.window; controller.start(); try ready(window)
        try check(try popup("選択肢の種類", window).numberOfItems == 7 && window.title == "CRMの選択肢設定", "seven Japanese dictionaries")
        try check(try table(window).numberOfRows == 100 && !button("前の100件", window).isEnabled, "bounded first page")
        try snapshot(window, to: resources.appendingPathComponent("build/admin-crm-configuration-main.png"))
        try click("次の100件", window); try ready(window); try check(try table(window).numberOfRows == 8 && !button("次の100件", window).isEnabled, "second page")
        try click("前の100件", window); try ready(window)
        try search("%_", window); try check(try table(window).numberOfRows == 1, "literal wildcard search across whole dictionary")
        try selectFirst(window); try check(try button("削除…", window).isEnabled, "filtered single row is not last dictionary value")
        try search("なし", window); try check(try table(window).numberOfRows == 0 && !button("編集…", window).isEnabled, "empty search")
        for kind in NativeCRMConfiguration.Kind.allCases { try selectKind(kind, window); try check(try table(window).numberOfRows > 0, "kind navigation " + kind.rawValue) }
        try click("追加…", window); var child = try editor(window)
        try check(try !button("再読み込み", window).isEnabled, "parent disabled while child is retained")
        try field("選択肢の名称", child).stringValue = "保存前"
        try dismiss(child); try check(window.attachedSheet === child && confirmations == 1, "unsaved cancel stays open")
        discard = true; try dismiss(child); try wait("discard closes") { window.attachedSheet == nil }; try ready(window)
        try check(changes == 0, "discard no mutation")
        try click("追加…", window); child = try editor(window)
        try field("選択肢の名称", child).stringValue = "新しい段階"
        try popup("自動処理のきっかけ", child).selectItem(at: 5)
        try snapshot(child, to: resources.appendingPathComponent("build/admin-crm-configuration-editor.png"))
        try click("保存", child); try wait("create close") { window.attachedSheet == nil }; try ready(window)
        let created = try api.searchPage(.salesStage, search: "新しい段階").page.values.first!
        try check(created.stageKind == "care" && changes == 1, "create real SQLite stage kind")
        try search("新しい段階", window); try selectFirst(window); try click("編集…", window); child = try editor(window)
        try check(try popup("自動処理のきっかけ", child).indexOfSelectedItem == 5, "edit existing stage")
        try popup("自動処理のきっかけ", child).selectItem(at: 0); try click("保存", child)
        try wait("clear stage") { window.attachedSheet == nil }; try ready(window)
        try check(try api.searchPage(.salesStage, search: "新しい段階").page.values.first?.stageKind == nil, "explicit none clears automation")
        try selectFirst(window); try click("編集…", window); child = try editor(window)
        try field("選択肢の名称", child).stringValue = "古い画面"
        _ = try api.update(.salesStage, id: created.id, name: "別画面で更新")
        try click("保存", child); try wait("conflict shown") { try button("保存", child).isEnabled && field("選択肢編集の操作結果", child).stringValue.contains("別の操作") }
        try check(try db.get("crm_Opportunities_Sales_Stages", key: ["id": .text(created.id)])?["name"] == .text("別画面で更新"), "stale editor cannot overwrite")
        try dismiss(child); try wait("conflict close") { window.attachedSheet == nil }; try ready(window)
        // Four supported kinds use the same bounded replacement picker. A
        // large contact-type dictionary exercises the second page and query.
        for i in 0..<103 { _ = try api.create(.contactType, name: String(format: "候補%03d", i)) }
        let source = try api.searchPage(.contactType, search: "種類A").page.values.first!
        let contact = try db.insert("crm_Contacts", values: ["last_name": .text("置換確認"), "contact_type_id": .text(source.id)], actor: service.identity.id)
        try selectKind(.contactType, window); try search("種類A", window); try selectFirst(window); try click("削除…", window); child = try editor(window)
        try wait("replacement load") { try popup("置き換え先", child).isEnabled }
        try check(try popup("置き換え先", child).numberOfItems == 101 && !button("割り当てを変更して削除", child).isEnabled, "replacement required, page bounded")
        try click("次の候補100件", child); try wait("replacement next") { try popup("置き換え先", child).isEnabled }
        try check(try popup("置き換え先", child).numberOfItems == 5, "replacement second page")
        try click("前の候補100件", child); try wait("replacement previous") { try popup("置き換え先", child).isEnabled }
        for i in 0..<5 {
            let removed = try api.searchPage(.contactType, search: String(format: "候補%03d", i)).page.values.first!
            try api.delete(.contactType, id: removed.id)
        }
        try click("次の候補100件", child); try wait("empty replacement page recovers") { try popup("置き換え先", child).isEnabled }
        try check(try popup("置き換え先", child).numberOfItems == 100 && !button("前の候補100件", child).isEnabled && !button("次の候補100件", child).isEnabled, "external deletions return to last nonempty page")
        try search("候補102", child, replacement: true); try check(try popup("置き換え先", child).numberOfItems == 2, "replacement server-side search")
        let choices = try popup("置き換え先", child); choices.selectItem(at: 1); choices.sendAction(choices.action, to: choices.target)
        try snapshot(child, to: resources.appendingPathComponent("build/admin-crm-configuration-replacement.png"))
        let target = try api.searchPage(.contactType, search: "候補102").page.values.first!
        try click("割り当てを変更して削除", child); try wait("replacement delete close") { window.attachedSheet == nil }; try ready(window)
        try check(try db.get("crm_Contact_Types", key: ["id": .text(source.id)]) == nil && db.get("crm_Contacts", key: ["id": contact["id"]])?["contact_type_id"] == .text(target.id), "GUI reassignment commits real SQLite")
        // The source UI cannot delete used non-reassignable kinds. Native makes
        // its already supported SET NULL result explicit in the confirmation.
        let industry = try api.searchPage(.industry, search: "種類A").page.values.first!
        let account = try db.insert("crm_Accounts", values: ["name": .text("解除確認"), "v": .integer(0), "industry": .text(industry.id)], actor: service.identity.id)
        try selectKind(.industry, window); try search("種類A", window); try selectFirst(window); try click("削除…", window); child = try editor(window)
        try check(try field("削除の説明", child).stringValue.contains("未設定") && !views(child.contentView!).contains(where: { $0.accessibilityLabel() == "置き換え先" }), "unsupported reassignment is clearly explained")
        try click("削除する", child); try wait("set null close") { window.attachedSheet == nil }; try ready(window)
        try check(try db.get("crm_Accounts", key: ["id": account["id"]])?["industry"] == .null, "GUI explicit SET NULL")
        // Last-item and usage-count races are checked again inside the write
        // transaction, not merely through disabled controls.
        let values = try api.page(.opportunityType).values
        try api.deleteFromUI(.opportunityType, value: values[0], replacementID: nil)
        try selectKind(.opportunityType, window); try selectFirst(window)
        try check(try !button("削除…", window).isEnabled, "last option disabled")
        try rejects("last option service guard") { try api.deleteFromUI(.opportunityType, value: values[1], replacementID: nil) }
        let stale = try api.page(.leadType).values[0]
        _ = try db.insert("crm_Leads", values: ["lastName": .text("確認後の追加"), "lead_type_id": .text(stale.id)], actor: service.identity.id)
        try rejects("usage changed during confirmation") { try api.deleteFromUI(.leadType, value: stale, replacementID: nil) }
        try click("追加…", window); child = try editor(window); try field("選択肢の名称", child).stringValue = "権限変更後"
        admin = try db.update(admin, changes: ["role": .text("manager")], actor: service.identity.id)
        try click("保存", child); try wait("fresh role failure") { try button("保存", child).isEnabled && field("選択肢編集の操作結果", child).stringValue.contains("この利用者") }
        try check(try db.mcpPage("crm_Opportunities_Type", fields: [], filter: .equal("name", .text("権限変更後")), limit: 1, offset: 0, order: [("id", false)]).total == 0, "retained form denied after role revoke")
        try dismiss(child); try wait("revoked child closes") { window.attachedSheet == nil }
        try click("再読み込み", window); try ready(window)
        try check(try table(window).numberOfRows == 0 && !button("追加…", window).isEnabled, "revoked directory clears data")
        try rejects("manager cannot create window") { _ = try NativeCRMConfigurationWindow(service: CRMService(db: db, identity: .init(id: admin["id"].string, role: "manager", partnerAccountID: nil))) }
        try check(controller.confirmDiscard(), "no retained child after terminal result")
    }
}
