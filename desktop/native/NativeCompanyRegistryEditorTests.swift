import AppKit

@main enum NativeCompanyRegistryEditorTests {
    static var checks = 0
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("{\"checks\":\(checks),\"exit\":0}"); exit(0) }
            catch { print(try! NativePluginJSON.text(["checks": checks, "error": error.localizedDescription])); exit(1) }
        }
        app.run()
    }
    @MainActor static func check(_ value: Bool, _ name: String) throws { checks += 1; if !value { throw NativePluginError(message: name) } }
    @MainActor static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    @MainActor static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeRegistryEditor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")), service = CRMService(db: db, identity: identity)
        let module = CRMModule.find("crm_Accounts")!
        var saved: [String: SQLValue] = [:]
        let editor = try CRMEditor(module: module, record: nil, linkedTo: nil, service: service, onSave: { saved = $0 })
        try editor.applyTextValues(["name": "元の会社", "company_id": "19", "billing_street": "既存住所", "vat": "CZ19"])
        let registry = NativeCompanyRegistry(authenticate: { try service.authenticated() }, providers: {
            [.init(countries: ["CZ"], lookup: { _, _ in ["name": "照会した会社", "registrationNumber": "00000019", "country": "CZ", "city": "Praha", "postalCode": "17000"] }, validateVat: { _ in true })]
        })
        try editor.attachCompanyRegistry(registry, allowLookup: true)
        let all = views(editor.window.contentView!), accessory = all.compactMap { $0 as? NativeCompanyRegistryControls }.first!
        let lookup = views(accessory).compactMap { $0 as? NSButton }.first { $0.title == "登録情報から入力" }!
        lookup.performClick(nil)
        let deadline = Date().addingTimeInterval(5)
        while !lookup.isEnabled && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(lookup.isEnabled, "lookup completes in actual editor")
        let draft = editor.textValues()
        try check(draft["name"] == "照会した会社" && draft["company_id"] == "00000019", "lookup updates mounted fields")
        try check(draft["billing_city"] == "Praha" && draft["billing_postal_code"] == "17000", "lookup updates offscreen draft")
        try check(draft["billing_street"] == "既存住所", "lookup preserves missing address fields")
        try check(draft["billing_country"] == "チェコ", "Japanese country display reaches form")
        try check(try db.page("crm_Accounts", fields: []).total == 0, "lookup does not commit CRM data")
        let content = all.compactMap { $0 as? CRMFormContentView }.first!
        try check(content.subviews.count < module.fields.count, "registry keeps form virtualization")
        let formWindow = editor.window as! CRMFormWindow
        let picker = views(accessory).compactMap { $0 as? NSPopUpButton }.first!
        try check(formWindow.moveFocus?(picker, 1) == true, "keyboard moves from country to lookup")
        try check(editor.window.firstResponder === lookup, "lookup participates in keyboard navigation")
        let information = NSPopUpButton(); information.addItems(withTitles: ["連携情報", "担当保護"])
        var informationStopped = false
        editor.installAccessory(information, onClose: { informationStopped = true })
        let combined = views(editor.window.contentView!)
        try check(combined.contains { $0 === accessory } && combined.contains { $0 === information }, "information and registry accessories coexist")
        try check(editor.textValues() == draft, "adding information controls preserves the unsaved draft")
        try check(formWindow.moveFocus?(information, 1) == true, "combined accessory participates in keyboard focus")
        let save = all.compactMap { $0 as? NSButton }.first { $0.keyEquivalent == "s" }!
        save.performClick(nil)
        try check(informationStopped, "saving stops the additional accessory")
        try check(saved["name"] == .text("照会した会社") && saved["billing_city"] == .text("Praha"), "save captures registry draft")
        try check(saved["billing_street"] == .text("既存住所"), "save preserves pre-existing address")
        try check(try db.page("crm_Accounts", fields: []).total == 0, "callback mode still avoids persistence")
        let readOnly = try CRMEditor(module: module, record: nil, linkedTo: nil, service: service, readOnly: true)
        try readOnly.attachCompanyRegistry(registry, allowLookup: true)
        try check(!views(readOnly.window.contentView!).contains { $0 is NativeCompanyRegistryControls }, "read-only form has no mutation controls")
        let readonlyInformation = NSPopUpButton(); readonlyInformation.addItem(withTitle: "連携情報")
        readOnly.installAccessory(readonlyInformation, readOnlyAllowed: true, onClose: {})
        try check(views(readOnly.window.contentView!).contains { $0 === readonlyInformation }, "read-only form allows an explicitly informational accessory")
        let forbidden = NSButton(title: "変更", target: nil, action: nil)
        readOnly.installAccessory(forbidden, onClose: {})
        try check(!views(readOnly.window.contentView!).contains { $0 === forbidden }, "read-only form still rejects ordinary accessories")
        let before = readOnly.textValues()
        try readOnly.applyTextValues(["name": "変更禁止"])
        try check(readOnly.textValues() == before, "read-only draft refuses external mutation")
    }
}
