import AppKit

@main enum NativeCRMFunnelSettingsTests {
    static var checks = 0
    struct Rollback: Error {}
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("accepted: " + label)
    }
    static func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
    static func input(_ key: String, _ window: NSWindow) -> NSTextField { allViews(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == key }! }
    static func button(_ title: String, _ window: NSWindow) -> NSButton { allViews(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }! }
    static func click(_ title: String, _ window: NSWindow) throws { let b = button(title, window); try check(b.isEnabled, title + " enabled"); b.performClick(nil) }
    static func wait(_ label: String, _ body: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(10)
        while Date() < end { if try body() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        throw NativeDBError.message("timeout: " + label)
    }
    static func status(_ window: NSWindow) -> String { allViews(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "営業フロー設定の操作結果" }!.stringValue }
    static func main() {
        do { try run(); print("{\"checks\":\(checks),\"exit\":0}") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let native = URL(fileURLWithPath: CommandLine.arguments[1]), candidate = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-FunnelSettings-" + UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: native.appendingPathComponent("schema.json"), sqlURL: native.appendingPathComponent("schema.sql"))
        let adminID = "00000000-0000-4000-8000-000000000001"
        var admin = try db.insert("Users", values: ["id": .text(adminID), "name": .text("隔離管理者"), "email": .text("funnel@example.invalid"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: "fixture")
        let service = CRMService(db: db, identity: .init(id: adminID, role: "admin", partnerAccountID: nil)), api = NativeCRMFunnelSettings(service: service)
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent("reference.json"))) as! [String: Any]
        let cases = reference["cases"] as! [[String: Any]]
        for test in cases {
            do {
                try db.transaction {
                    let expected = test["expected"] as! [String: Any], values = test["values"] as! [String: Int], name = test["name"] as! String
                    let role = test["role"] as? String ?? "admin"
                    _ = try db.update(admin, changes: ["role": .text(role), "userStatus": .text((test["active"] as? Bool) == false ? "INACTIVE" : "ACTIVE"), "banned": .integer((test["banned"] as? Bool) == true ? 1 : 0)], actor: adminID)
                    let local = NativeCRMFunnelSettings(service: CRMService(db: db, identity: .init(id: adminID, role: role, partnerAccountID: nil)))
                    var seed: [String: SQLValue] = [:]
                    for field in NativeCRMFunnelSettings.fields { seed[field.column] = .integer(Int64(NativeCRMAutomationSettings()[keyPath: field.path])) }
                    if test["existing"] as? Bool == true { _ = try db.insert("crm_FunnelSettings", values: seed, actor: adminID) }
                    let before = try NativeCRMAutomationSettings.load(db)
                    var input = NativeCRMAutomationSettings()
                    for field in NativeCRMFunnelSettings.fields { input[keyPath: field.path] = values[field.key]! }
                    var saved: NativeCRMFunnelSettings.Snapshot?
                    do { saved = try local.save(input, expected: local.load()) } catch {}
                    try check((saved != nil) == (expected["success"] as! Bool), "source result " + name)
                    if let saved {
                        let data = expected["data"] as! [String: Any]
                        for field in NativeCRMFunnelSettings.fields { try check(saved.record![field.column] == .integer(Int64(data[field.column] as! Int)), "source field " + name + "/" + field.key) }
                        try check(saved.record!["updatedBy"] == .text(adminID), "source updater")
                        try check(try NativeCRMAutomationSettings.load(db) == input, "worker consumes saved fields")
                    } else { try check(try NativeCRMAutomationSettings.load(db) == before, "rejection leaves data " + name) }
                    throw Rollback()
                }
            } catch is Rollback {}
        }
        try check(try api.load().record == nil, "load never creates singleton; fixture rollbacks complete")
        let first = try api.load(), competing = try api.load()
        let saved = try api.save(first.settings, expected: first)
        try rejects("another window created singleton") { _ = try api.save(competing.settings, expected: competing) }
        try rejects("outer transaction rolls back settings") {
            try db.transaction { var changed = saved.settings; changed.renewalWindowDays = 180; _ = try api.save(changed, expected: saved); throw Rollback() }
        }
        try check(try api.load().settings.renewalWindowDays == 30, "outer rollback retained settings")
        var newer = saved.settings; newer.killAfterDays = 120
        _ = try api.save(newer, expected: api.load())
        try rejects("stale existing revision") { _ = try api.save(saved.settings, expected: saved) }
        // Import fidelity: read exact stored values without clamping, validate at edit/save.
        let row = try api.load().record!
        _ = try db.update(row, changes: ["renewal_window_days": .integer(999)], actor: adminID)
        let imported = try api.load(); try check(imported.settings.renewalWindowDays == 999, "imported value preserved")
        try rejects("invalid imported value cannot resave") { _ = try api.save(imported.settings, expected: imported) }
        var repaired = imported.settings; repaired.renewalWindowDays = 30; _ = try api.save(repaired, expected: imported)
        var discard = false, confirmations = 0, changed = 0
        let controller = try NativeCRMFunnelSettingsWindow(service: service, confirmDiscard: { _ in confirmations += 1; return discard })
        controller.onChanged = { changed += 1 }; let window = controller.window; controller.start()
        try wait("loaded") { button("再読み込み", window).isEnabled }
        try check(NativeCRMFunnelSettings.fields.allSatisfy { input($0.key, window).isEnabled }, "all12 native inputs")
        try check(input("careQuarterCount", window).stringValue == "8", "default quarterly count")
        input("careQuarterCount", window).stringValue = "0"; input("renewalWindowDays", window).stringValue = "7"
        try click("設定を保存", window); try wait("saved") { button("設定を保存", window).isEnabled }
        try check(try api.load().settings.renewalWindowDays == 7 && api.load().settings.careQuarterCount == 0 && changed == 1, "UI persists all values and zero-count")
        input("renewalWindowDays", window).stringValue = "1.5"; try click("設定を保存", window)
        try check(status(window).contains("整数") && (try api.load()).settings.renewalWindowDays == 7, "fraction rejected without save")
        input("renewalWindowDays", window).stringValue = "9"; try click("閉じる", window)
        try check(confirmations == 1 && input("renewalWindowDays", window).stringValue == "9", "cancel discard keeps edit")
        var changedElsewhere = try api.load().settings; changedElsewhere.renewalWindowDays = 45
        _ = try api.save(changedElsewhere, expected: api.load()); try click("設定を保存", window)
        try wait("conflict") { button("設定を保存", window).isEnabled }
        try check(status(window).contains("別の操作") && (try api.load()).settings.renewalWindowDays == 45, "retained form cannot overwrite")
        discard = true; try click("再読み込み", window); try wait("reload") { button("再読み込み", window).isEnabled }
        try check(input("renewalWindowDays", window).stringValue == "45", "confirmed reload shows current value")
        window.appearance = NSAppearance(named: .aqua); window.contentView!.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        for spec in NativeCRMFunnelSettings.fields {
            let field = input(spec.key, window), frame = field.convert(field.bounds, to: window.contentView)
            try check(frame.width >= 70 && frame.height > 0 && window.contentView!.bounds.contains(frame), "field fits " + spec.key)
        }
        if let bitmap = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds) {
            window.effectiveAppearance.performAsCurrentDrawingAppearance { window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap) }
            guard let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let content = bitmap.cgImage else { throw NativeDBError.message("snapshot background") }
            context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            context.draw(content, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            guard let composed = context.makeImage(), let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { throw NativeDBError.message("snapshot PNG") }
            try png.write(to: candidate.appendingPathComponent("funnel-settings-ui.png"))
        }
        input("renewalWindowDays", window).stringValue = "33"
        admin = try db.update(admin, changes: ["banned": .integer(1)], actor: adminID)
        try click("設定を保存", window); try wait("revoked save") { button("設定を保存", window).isEnabled }
        try check(status(window).contains("この利用者") && (try NativeCRMAutomationSettings.load(db)).renewalWindowDays == 45, "fresh authority on save")
        try click("再読み込み", window); try wait("revoked reload") { button("再読み込み", window).isEnabled }
        try check(!button("設定を保存", window).isEnabled && NativeCRMFunnelSettings.fields.allSatisfy { input($0.key, window).stringValue.isEmpty }, "revoked load clears fields")
        try check(controller.confirmDiscard(), "failed load has no phantom unsaved state")
        try click("閉じる", window)
        try rejects("revoked user cannot reopen settings") { _ = try NativeCRMFunnelSettingsWindow(service: service) }
        try check(NSApp.windows.allSatisfy { !$0.isVisible }, "offscreen controls only")
    }
}
