import AppKit

enum NativeE2BSettingsTests {
    typealias UI = NativeAISettingsUITests
    final class Secrets: NativeAISecretStore {
        private let lock = NSRecursiveLock()
        var values: [String: Data] = [:]
        var failSave = false, failRemove = false, failLoad = false
        var onSave: (() throws -> Void)?, onLoad: (() throws -> Void)?
        func save(id: String, data: Data) throws {
            lock.lock(); defer { lock.unlock() }
            if failSave { throw NativeDBError.message("secret-error-must-not-leak") }
            guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data
            let callback = onSave; onSave = nil; try callback?()
        }
        func load(id: String, interactive: Bool) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            if failLoad { throw NativeDBError.message("secret-error-must-not-leak") }
            let data = values[id], callback = onLoad; onLoad = nil; try callback?(); return data
        }
        func remove(id: String) throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw NativeDBError.conflict }; values.removeValue(forKey: id) }
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { try UI.check(!error.localizedDescription.contains("secret-error-must-not-leak"), label); return }
        throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func run(_ resources: URL) throws {
        let before = UI.checks, root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-E2BSettings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func database() throws -> NativeDatabase { try .init(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql")) }
        let db = try database(), admin = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))), store = Secrets()
        var environment: [String: String] = [:], now = Date()
        let env = NativeAIEnvironment(lookup: { environment[$0] })
        func api(_ service: CRMService? = nil) -> NativeE2BSettings { .init(service: service ?? admin, store: store, environment: env, clock: { now }) }
        let keys = NativeAIKeys(service: admin, store: store, environment: env, clock: { now })
        func set(_ value: String?, _ template: String = "qa-template") throws { try api().save(api().setting(), key: value, template: template) }
        let empty = try api().setting()
        try UI.check(empty.credentialID == nil && empty.template == "nextcrm-enrichment" && (try api().resolve()) == nil, "E2B defaults without key")
        try set("synthetic-e2b-first")
        let first = try api().setting(), connection = try api().resolve()!
        try UI.check(connection.key == "synthetic-e2b-first" && connection.template == "qa-template" && connection.choice.source == .system, "shared E2B key resolved")
        try UI.check(try db.metadata(NativeE2BSettings.keyReference) == first.credentialID && db.page("ApiKeys", fields: []).total == 0 && NativeAIProvider.allCases.count == 4, "opaque reference, original Prisma providers unchanged")
        store.failSave = true; try rejects("failed save preserves previous credential") { try set("failed-new-key") }; store.failSave = false
        try UI.check(try api().setting() == first && api().resolve()?.key == connection.key, "old setting survives keychain failure")
        try rejects("stale save") { try api().save(empty, key: "stale-key", template: "stale") }
        try rejects("invalid template") { try set(nil, "bad\nname") }
        try rejects("invalid key") { try set("bad key") }
        for role in ["user", "manager", "partner"] {
            let row = try db.insert("Users", values: ["name": .text(role), "email": .text(role + "@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE")], actor: admin.identity.id)
            let service = CRMService(db: db, identity: .init(id: row["id"].string, role: role, partnerAccountID: nil))
            try rejects(role + " cannot change global E2B") { try api(service).save(first, key: "forbidden-key", template: "forbidden") }
            if role == "partner" { try rejects("partner cannot read E2B key") { _ = try api(service).resolve() } }
            else {
                try UI.check(try api(service).resolve()?.key == connection.key, "internal user can run shared E2B")
                let readonly = try NativeE2BSettingsWindow(api: api(service)); try UI.layout(readonly.window)
                try UI.check(!(try UI.button("接続設定を保存", readonly.window)).isEnabled && !(try UI.field("E2B APIキー", readonly.window)).isEnabled, "shared settings read-only for nonadmin")
            }
        }
        environment = ["E2B_API_KEY": "synthetic-env-key", "E2B_ENRICHMENT_TEMPLATE": "env-template"]
        let effective = try api().resolve()!
        try UI.check(effective.key == "synthetic-env-key" && effective.template == "env-template", "environment overrides saved fields")
        try rejects("old saved choice invalid after environment override") { try api().requireCurrent(connection) }
        environment["E2B_API_KEY"] = "changed-env-key"
        try rejects("environment rotation fences old request") { try api().requireCurrent(effective) }
        environment = [:]
        for (name, value) in [("E2B_API_URL", "https://control.example.invalid/v1"), ("E2B_DOMAIN", "corp.invalid"), ("E2B_SANDBOX_URL", "https://worker.example.invalid/engine"), ("E2B_ACCESS_TOKEN", "qa-extra-access"), ("E2B_DEBUG", "true")] {
            environment[name] = value
            try rejects("changing " + name + " fences existing credentials") { try api().requireCurrent(connection) }
            let captured = try api().resolve()!, hash = captured.configuration.fingerprint
            environment.removeValue(forKey: name)
            try rejects("removing " + name + " fences custom connection") { try api().requireCurrent(captured) }
            try UI.check(captured.configuration.fingerprint == hash && captured.choice.configurationHash == hash, "resolved configuration is an immutable snapshot")
        }
        try set(nil, "new-template")
        try UI.check(try api().setting().credentialID == first.credentialID && api().resolve()?.key == connection.key, "template-only save preserves key")
        try rejects("template change fences old request") { try api().requireCurrent(connection) }
        try db.queueAIKeyCleanup(first.credentialID!, notBefore: now)
        let cleanup = try keys.cleanup()
        try UI.check(try db.aiKeyIsReferenced(first.credentialID!) && cleanup.removed == 0 && store.values[first.credentialID!] != nil, "shared cleanup never deletes live E2B key")
        store.failRemove = true; try set("rotated-key")
        try UI.check(try api().resolve()?.key == "rotated-key" && store.values[first.credentialID!] != nil, "retired secret cleanup failure preserves committed new key")
        store.failRemove = false; _ = try keys.cleanup()
        try UI.check(store.values[first.credentialID!] == nil, "retired key cleanup retries")
        let existing = try api().setting()
        let otherDB = try database(), other = NativeE2BSettings(service: .init(db: otherDB, identity: admin.identity), store: store, environment: env, clock: { now })
        store.onSave = { try other.save(other.setting(), key: nil, template: "concurrent-template") }
        try rejects("two-connection stale publication") { try api().save(existing, key: "losing-key", template: "losing-template") }
        try UI.check(try api().setting().template == "concurrent-template" && store.values.count == 1, "concurrent winner survives and losing secret removed")
        let beforeExpiry = try api().setting()
        store.onSave = { now = now.addingTimeInterval(601) }
        try rejects("expired reservation") { try set("expired-secret") }
        try UI.check(try api().setting() == beforeExpiry && store.values.count == 1, "expired publication does not replace valid key")
        store.onLoad = { try set("replaced-during-load") }
        try rejects("rotation during key load") { _ = try api().resolve() }
        store.failLoad = true; try rejects("keychain errors sanitized") { _ = try api().resolve() }; store.failLoad = false
        try UI.check(try other.resolve()?.key == "replaced-during-load", "reopened database resolves saved key")
        try api().removeKey(api().setting())
        try UI.check(try api().resolve() == nil && store.values.isEmpty && api().setting().template == "qa-template", "remove secret preserves template")

        let editor = try NativeE2BSettingsWindow(api: api()); try UI.layout(editor.window)
        try UI.check(try UI.field("E2B APIキー", editor.window) is NSSecureTextField, "secure E2B input")
        try UI.field("E2B APIキー", editor.window).stringValue = "ui-e2b-key-1234"
        try UI.field("実行環境名", editor.window).stringValue = "ui-template"
        try UI.click("接続設定を保存", editor.window); try UI.wait { try UI.button("接続設定を保存", editor.window).isEnabled }
        try UI.check(try api().resolve()?.key == "ui-e2b-key-1234" && api().resolve()?.template == "ui-template" && UI.field("E2B APIキー", editor.window).stringValue.isEmpty && UI.field("E2Bの利用状況", editor.window).stringValue.contains("••••1234"), "Japanese UI save clears key and displays masked state")
        let aiUI = try NativeAISettingsWindow(keys: keys); var opened = false
        aiUI.onE2BSettings = { opened = $0 === aiUI.window }; try UI.click("企業調査（E2B）の設定…", aiUI.window)
        try UI.check(opened, "AI settings routes to E2B panel"); try UI.layout(aiUI.window)
        try keys.save(keys.setting(.anthropic, scope: .system), key: "synthetic-anthropic")
        let target = try db.insert("crm_Targets", values: ["first_name": .text("太郎"), "last_name": .text("検証"), "email": .text("person@example.invalid"), "company": .text("検証会社"), "company_website": .text("https://example.invalid"), "created_by": .text(admin.identity.id)], actor: admin.identity.id)
        let targetAPI = NativeTargetEnrichmentService(service: admin, store: store, environment: env, clock: { now })
        let fields = NativeTargetEnrichment.fields(["industry"], scenario: .company)
        let jobID = try targetAPI.request(targetIDs: [target["id"].string], fields: fields, mode: .automatic)[0]
        let worker = NativeTargetEnrichmentWorker(db: db, store: store, environment: env, clock: { now }, review: { _, _, _, _ in throw NativeDBError.conflict }, agent: { _, anthropic, connection, report in
            let e2b = connection.key, template = connection.template
            guard anthropic == "synthetic-anthropic", e2b == "ui-e2b-key-1234", template == "ui-template" else { throw NativeDBError.conflict }
            try await report(.init(message: "保存した接続を使用", kind: .agent))
            return .init(target: ["industry": "情報通信"], contacts: [], confidence: [:])
        })
        var done = false, failure: Error?
        Task { do { _ = try await worker.runNext() } catch { failure = error }; done = true }
        try UI.wait { done }; if let failure { throw failure }
        try UI.check(try db.job(id: jobID)?.status == "done" && db.get("crm_Targets", key: ["id": target["id"]])?["industry"] == .text("情報通信"), "real durable worker uses UI-saved E2B key and template")
        let job = try db.job(id: jobID)!
        try UI.check(!job.payload.values.contains("ui-e2b-key-1234") && !job.result.values.contains("ui-e2b-key-1234"), "E2B secret absent from job payload/results")
        try UI.click("保存したE2Bキーを削除…", editor.window); try UI.wait { editor.window.attachedSheet != nil }
        editor.window.endSheet(editor.window.attachedSheet!, returnCode: .alertSecondButtonReturn); try UI.wait { editor.window.attachedSheet == nil }
        try UI.check(try api().resolve() != nil, "E2B delete cancellation preserves key")
        try UI.click("保存したE2Bキーを削除…", editor.window); try UI.wait { editor.window.attachedSheet != nil }
        editor.window.endSheet(editor.window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        try UI.wait { try api().resolve() == nil && UI.button("接続設定を保存", editor.window).isEnabled }
        try UI.check(editor.confirmDiscard() && (try api().setting().template) == "ui-template", "delete finishes with clean form and preserved template")
        print("Native E2B shared settings, failure recovery, worker and UI: \(UI.checks - before) checks passed")
    }
}
