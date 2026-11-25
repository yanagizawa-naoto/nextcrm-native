import AppKit

private final class AdminSecrets {
    private let lock = NSLock()
    private var values: [String: NativePluginRecord] = [:]
    private var count = 0
    var store: NativePluginSecretStore {
        .init(read: { reference in
            self.lock.lock(); defer { self.lock.unlock() }
            guard let value = self.values[reference] else { throw NativePluginError(message: "missing fake secret") }; return value
        }, write: { _, value in
            self.lock.lock(); defer { self.lock.unlock() }; self.count += 1
            let reference = "isolated-secret-\(self.count)"; self.values[reference] = value; return reference
        }, remove: { reference in self.lock.lock(); defer { self.lock.unlock() }; self.values.removeValue(forKey: reference) })
    }
    var references: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

private final class AdminMailCredentials: InvoiceMailCredentialStore {
    var account: InvoiceMailAccount?
    func load(interactive: Bool) throws -> InvoiceMailAccount? { account }
    func save(_ account: InvoiceMailAccount) throws { self.account = account }
    func remove() throws { account = nil }
}

@main enum NativePluginsAdminTests {
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
    @MainActor static func button(_ window: NSWindow, _ title: String) throws -> NSButton {
        guard let found = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativePluginError(message: "Missing button " + title) }; return found
    }
    @MainActor static func field(_ window: NSWindow, _ label: String) throws -> NSTextField {
        guard let found = views(window.contentView!).compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) else { throw NativePluginError(message: "Missing input " + label) }; return found
    }
    @MainActor static func settle(_ window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(try button(window, "再読み込み").isEnabled) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(try button(window, "再読み込み").isEnabled, "UI operation completes")
    }
    @MainActor static func refused(_ label: String, _ body: () async throws -> Void) async throws {
        var failed = false; do { try await body() } catch { failed = true }; try check(failed, label)
    }
    @MainActor static func snapshot(_ window: NSWindow, name: String) throws {
        window.appearance = NSAppearance(named: .aqua)
        let view = window.contentView!; view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NativePluginError(message: "Cannot render settings") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("build/" + name + ".png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    @MainActor static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativePluginsAdmin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")), service = CRMService(db: db, identity: identity)
        let secret = "synthetic-only-api-key", secretStore = AdminSecrets(), id = "ui-check"
        var requestHook: (() throws -> Void)?
        var definition = NativePluginDefinition(id: id, name: "検証用の連携", version: "0.1.0", sdk: "^0.2.0", description: "日本語の設定・保存・権限を検証します。", permissions: ["accounts:read", "http", "notify"], settings: .connector(oxo: false), secrets: .connectorSecrets(oxo: false))
        definition.slots = [.init(kind: .adminAction, id: "test", title: "接続テスト", roles: ["admin"])]
        definition.actions["test"] = { _, _ in "接続を確認しました。" }
        definition.actions["guarded"] = { _, ctx in
            _ = try await ctx.http(URLRequest(url: URL(string: "https://example.invalid")!))
            try ctx.store.set("must-not-be-written", true); return "完了"
        }
        let host = try NativePluginHost(db: db, definitions: [definition], secretStore: secretStore.store, translate: { _, key, _, _ in key }, sendNotification: { _, _, _ in throw NativePluginError(message: "unexpected mail") }, transport: { _, request in
            guard let hook = requestHook else { throw NativePluginError(message: "unexpected HTTP") }
            try hook(); return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        })
        host.attach()
        let admin = NativePluginsAdmin(service: service, host: host), actor = NativePluginActor(type: .user, userId: identity.id, role: identity.role)
        let empty = try admin.detail(id)
        try check(!empty.installed && empty.secretFlags.isEmpty, "initial detail has no saved credentials")
        try check(NativePluginJSON.number(empty.settings["syncMinutes"]) == 15, "source settings defaults")
        try await refused("permission acknowledgement required") { try await admin.save(empty, settings: [:], secrets: [:], granted: false) }

        var allowDiscard = false, confirmations = 0
        let controller = NativePluginsSettingsWindow(admin: admin, confirm: { _, _ in confirmations += 1; return allowDiscard })
        controller.start(); try await settle(controller.window)
        try Self.snapshot(controller.window, name: "plugins-admin-settings-top")
        let formScroll = views(controller.window.contentView!).compactMap { $0 as? NSScrollView }.first { !($0.documentView is NSTableView) }!
        formScroll.documentView!.scroll(NSPoint(x: 0, y: formScroll.documentView!.bounds.height))
        try Self.snapshot(controller.window, name: "plugins-admin-settings-bottom")
        formScroll.documentView!.scroll(.zero)
        try check(controller.window.title == "連携・プラグインの設定", "Japanese window title")
        try check(!(try button(controller.window, "導入する").isEnabled), "install disabled until permission acknowledgement")
        let grant = try button(controller.window, "権限を確認して、この連携を有効にする")
        grant.performClick(nil)
        try check(try button(controller.window, "導入する").isEnabled, "explicit permission acknowledgement enables install")
        try field(controller.window, "接続先URL ＊").stringValue = "invalid"
        try field(controller.window, "データベース名 ＊").stringValue = "qa-db"
        let secretInput = try field(controller.window, "APIキー")
        try check(secretInput is NSSecureTextField, "secret uses actual secure text input")
        secretInput.stringValue = secret
        try button(controller.window, "導入する").performClick(nil); try await settle(controller.window)
        try check(try host.state(id) == nil, "invalid settings not installed")
        try check(try field(controller.window, "APIキー").stringValue == secret, "failed save preserves secret draft")
        try check(try field(controller.window, "連携設定の操作結果").stringValue.contains("接続先URL"), "validation names offending field in Japanese")
        try field(controller.window, "接続先URL ＊").stringValue = "https://example.invalid"
        try button(controller.window, "導入する").performClick(nil); try await settle(controller.window)
        let installed = try admin.detail(id)
        try check(installed.installed && installed.enabled, "UI installs enabled plugin")
        try check(installed.secretFlags["apiKey"] == true, "detail exposes only secret presence")
        try check(try field(controller.window, "APIキー").stringValue.isEmpty, "successful save clears secret draft")
        try check(try field(controller.window, "APIキー").placeholderString?.contains("設定済み") == true, "saved credential placeholder")
        let savedState = try host.state(id)!, originalReference = savedState["secrets"].string
        try check(savedState["settings"].string.contains(secret) == false && originalReference != secret, "SQLite holds opaque reference only")
        try field(controller.window, "同期間隔（分）").stringValue = "25"
        try button(controller.window, "設定を保存").performClick(nil); try await settle(controller.window)
        let saved = try host.state(id)!
        try check(try host.secretStore.read(saved["secrets"].string)["apiKey"] as? String == secret, "blank credential input preserves key")
        try check(saved["secrets"].string != originalReference && secretStore.references == 1, "immutable credential publication retires old reference")
        try check(NativePluginJSON.number(try admin.detail(id).settings["syncMinutes"]) == 25, "changed number persisted")
        try await refused("stale detail cannot overwrite newer settings") { try await admin.save(installed, settings: installed.settings, secrets: [:], granted: true) }
        try check(NativePluginJSON.number(try admin.detail(id).settings["syncMinutes"]) == 25, "stale save leaves current settings intact")
        try field(controller.window, "データベース名 ＊").stringValue = "未保存の変更"
        try button(controller.window, "再読み込み").performClick(nil)
        try check(confirmations == 1 && (try field(controller.window, "データベース名 ＊").stringValue) == "未保存の変更", "cancel keeps unsaved draft")
        allowDiscard = true; try button(controller.window, "再読み込み").performClick(nil); try await settle(controller.window)
        try check(try field(controller.window, "データベース名 ＊").stringValue == "qa-db", "confirmed discard reloads stored settings")
        try button(controller.window, "無効にする").performClick(nil); try await settle(controller.window)
        try check(try !admin.detail(id).enabled, "UI disables plugin")
        try check(!views(controller.window.contentView!).compactMap { $0 as? NSButton }.contains { $0.title == "接続テスト" }, "disabled plugin hides admin actions")
        try button(controller.window, "有効にする").performClick(nil); try await settle(controller.window)
        try button(controller.window, "接続テスト").performClick(nil); try await settle(controller.window)
        try check(try field(controller.window, "連携設定の操作結果").stringValue == "接続を確認しました。", "admin action result reaches UI")

        let store = NativePluginStore(db: db, pluginId: id)
        try db.transaction { for i in 0..<205 { try store.set("item-" + String(format: "%03d", i), ["name": "日本語\(i)"]) } }
        try store.forRecord(.account, "company-1").set("one", true)
        let snapshot = try admin.detail(id)
        try check(snapshot.entries == 206 && snapshot.records == 1, "bounded summary counts global and record entries")
        let exportURL = root.appendingPathComponent("export.json")
        try admin.export(snapshot, to: exportURL)
        let exportText = try String(contentsOf: exportURL, encoding: .utf8), exported = try NativePluginJSON.record(exportText)
        try check((exported["data"] as? [Any])?.count == 206, "stream export covers all pages")
        try check(!exportText.contains(secret) && !exportText.contains(saved["secrets"].string), "export excludes secrets and reference")
        let permission = try FileManager.default.attributesOfItem(atPath: exportURL.path)[.posixPermissions] as? NSNumber
        try check(permission?.intValue == 0o600, "export file owner-only")
        try await refused("exclusive export refuses existing destination") { try admin.export(snapshot, to: exportURL) }
        try check(try String(contentsOf: exportURL, encoding: .utf8) == exportText, "existing export not modified on failure")
        try db.transaction { for i in 0..<205 { host.log(id, "info", "日本語ログ\(i)") } }
        let logPage = try admin.logs(id, offset: 0)
        try check(logPage.rows.count == 100 && logPage.total == 205, "logs first page bounded")
        let logWindow = NativePluginLogWindow(admin: admin, id: id, name: "検証用の連携")
        logWindow.start(); try await settle(logWindow.window)
        try Self.snapshot(logWindow.window, name: "plugins-admin-logs")
        let table = views(logWindow.window.contentView!).compactMap { $0 as? NSTableView }.first!
        try check(table.numberOfRows == 100 && !(try button(logWindow.window, "前へ").isEnabled), "actual log table starts on first page")
        try button(logWindow.window, "次へ").performClick(nil); try await settle(logWindow.window)
        try check(table.numberOfRows == 100 && (try button(logWindow.window, "前へ").isEnabled), "log next page")
        try button(logWindow.window, "次へ").performClick(nil); try await settle(logWindow.window)
        try check(table.numberOfRows == 5 && !(try button(logWindow.window, "次へ").isEnabled), "log final page disables next")
        var user = try db.get("Users", key: ["id": .text(identity.id)])!
        try db.update(user, changes: ["role": .text("user")], actor: identity.id)
        try await refused("admin detail rechecks current role") { _ = try admin.detail(id) }
        try await refused("admin actions recheck current role") { _ = try await admin.action(snapshot, id: "test") }
        try button(logWindow.window, "再読み込み").performClick(nil); try await settle(logWindow.window)
        try check(table.numberOfRows == 0, "lost authority clears log table")
        try button(controller.window, "再読み込み").performClick(nil); try await settle(controller.window)
        try check(!views(controller.window.contentView!).contains { $0 is NSSecureTextField }, "lost authority clears settings fields")
        user = try db.get("Users", key: ["id": .text(identity.id)])!
        try db.update(user, changes: ["role": .text("admin")], actor: identity.id)
        try button(logWindow.window, "閉じる").performClick(nil)
        try button(controller.window, "閉じる").performClick(nil)
        let guardedDetail = try admin.detail(id)
        requestHook = { try host.setEnabled(id, actor: actor, enabled: false) }
        try await refused("manual action stops after plugin disabled during HTTP") { _ = try await admin.action(guardedDetail, id: "guarded") }
        try check(try store.get("must-not-be-written") == nil, "disabled action cannot commit after await")
        try host.setEnabled(id, actor: actor, enabled: true)
        let currentDetail = try admin.detail(id)
        requestHook = {
            try NativePluginActorScope.$current.withValue(nil) {
                let user = try db.get("Users", key: ["id": .text(identity.id)])!
                try db.update(user, changes: ["role": .text("user")], actor: identity.id)
            }
        }
        try await refused("manual action stops after administrator role revoked during HTTP") { _ = try await admin.action(currentDetail, id: "guarded") }
        try check(try store.get("must-not-be-written") == nil, "revoked action cannot commit after await")
        user = try db.get("Users", key: ["id": .text(identity.id)])!
        try db.update(user, changes: ["role": .text("admin")], actor: identity.id); requestHook = nil
        try await admin.uninstall(try admin.detail(id))
        try check(try host.state(id) == nil && secretStore.references == 0, "uninstall removes installed row and credential")
        try check(try db.page("PluginData", fields: [], equal: ["pluginId": .text(id)]).total == 0, "uninstall clears all store pages")
        try check(try db.page("PluginLog", fields: [], equal: ["pluginId": .text(id)]).total == 0, "uninstall clears log pages")
        try db.insert("InstalledPlugin", values: ["id": .text("missing-plugin"), "version": .text("0.1.0"), "status": .text("ENABLED"), "settings": .text("{}")], actor: identity.id)
        let missing = try admin.detail("missing-plugin")
        try check(missing.item.status == "MISSING" && missing.definition == nil && missing.installed, "missing definition remains manageable")
        try await host.uninstall("missing-plugin", actor: actor)
        try check(try host.state("missing-plugin") == nil, "missing definition can be uninstalled")
        try await adapters(root: root, db: db)
    }
    @MainActor static func adapters(root: URL, db: NativeDatabase) async throws {
        let mailStore = AdminMailCredentials(); var requests = 0, responseStatus = 200, sentFile: URL?
        let mail = NativePluginsMail(root: root, store: mailStore, request: { request, file in
            requests += 1; sentFile = file
            try check(request.value(forHTTPHeaderField: "Idempotency-Key")?.hasPrefix("nextcrm/plugin/") == true, "plugin notification has separate idempotency scope")
            try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-mail-key", "configured sender key reaches only provider header")
            let body = try NativePluginJSON.record(String(contentsOf: file, encoding: .utf8))
            try check(body["subject"] as? String == "担当保護のお知らせ" && body["text"] as? String == "日本語の本文\n確認してください。", "Japanese plain notification preserved")
            try check(body["from"] as? String == "sender@example.invalid" && body["to"] as? [String] == ["recipient@example.invalid"], "notification sends one intended recipient")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o600, "notification spool owner-only")
            return (try NativePluginJSON.data(["id": UUID().uuidString.lowercased()]), HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: nil, headerFields: [:])!)
        })
        try await refused("unconfigured notification fails before provider") { try await mail.send(to: "recipient@example.invalid", subject: "担当保護のお知らせ", text: "日本語の本文\n確認してください。") }
        try check(requests == 0, "no unconfigured outbound request")
        mailStore.account = .init(from: "sender@example.invalid", apiKey: "synthetic-mail-key")
        try await mail.send(to: "recipient@example.invalid", subject: "担当保護のお知らせ", text: "日本語の本文\n確認してください。")
        try check(requests == 1 && !FileManager.default.fileExists(atPath: sentFile!.path), "successful notification removes temporary spool")
        responseStatus = 429
        try await refused("provider failure propagates to plugin job") { try await mail.send(to: "recipient@example.invalid", subject: "担当保護のお知らせ", text: "日本語の本文\n確認してください。") }
        try check(requests == 2 && !FileManager.default.fileExists(atPath: sentFile!.path), "failed notification also removes temporary spool")
        try await refused("invalid mailbox rejected before provider") { try await mail.send(to: "a@example.invalid,b@example.invalid", subject: "担当保護のお知らせ", text: "本文") }
        try check(requests == 2, "invalid recipient no outbound request")
        try await refused("QA backing refuses unmarked root") { _ = try NativePluginsQACredentials(root: root) }
        try Data("NextCRM isolated mail QA\n".utf8).write(to: root.appendingPathComponent(".native-mail-test"))
        let backing = try NativePluginsQACredentials(root: root), vault = NativePluginCredentialVault(db: db, backing: backing)
        let reference = try vault.write("qa", ["apiKey": "synthetic-plugin-key"])
        try check(try vault.read(reference)["apiKey"] as? String == "synthetic-plugin-key", "QA credential vault uses isolated backing")
        let reopened = try NativePluginsQACredentials(root: root)
        try check(try reopened.load(reference) == backing.load(reference), "QA credentials survive application restart")
        try await refused("QA backing rejects arbitrary path") { try backing.save("../../escape", data: Data()) }
        try vault.remove(reference)
        try check(try reopened.load(reference) == nil, "QA credential removal is persistent")
    }
}
