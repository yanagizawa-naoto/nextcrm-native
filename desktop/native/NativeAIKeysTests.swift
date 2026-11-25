import Foundation
import SQLite3

@main enum NativeAIKeysTests {
    final class Secrets: NativeAISecretStore {
        var values: [String: Data] = [:], saveCount = 0, loads = 0
        var failSave = false, failRemove = false, failLoad = false
        var onSave: (() throws -> Void)?, onLoad: (() throws -> Void)?
        func save(id: String, data: Data) throws {
            if failSave { throw NativeDBError.message("secret-error-must-not-leak") }
            guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data; saveCount += 1
            let callback = onSave; onSave = nil; try callback?()
        }
        func load(id: String, interactive: Bool) throws -> Data? {
            loads += 1; if failLoad { throw NativeDBError.message("secret-error-must-not-leak") }
            let value = values[id], callback = onLoad; onLoad = nil; try callback?(); return value
        }
        func remove(id: String) throws { if failRemove { throw NativeDBError.message("locked") }; values.removeValue(forKey: id) }
    }
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { try check(!error.localizedDescription.contains("secret-error-must-not-leak"), label); return }
        throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func main() {
        do { try run(); print("Native AI keys: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        struct Reference: Decodable {
            struct Env: Decodable { let input: String; let expected: String? }
            struct Case: Decodable { let provider: NativeAIProvider; let environment: String; let system: String?; let personal: String?; let expected: String? }
            let environment: [Env]; let cases: [Case]
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/native-ai-keys-reference.json")))
        for item in reference.environment { try check(NativeAIEnvironment(lookup: { _ in item.input }).key(.openai) == item.expected, "actual envSecret JS reference") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AIKeys-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func open() throws -> NativeDatabase { try NativeDatabase(url: folder.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql")) }
        let db = try open(), identity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db: db, identity: identity), store = Secrets()
        var environment: [String: String] = [:], now = Date()
        let env = NativeAIEnvironment(lookup: { environment[$0] })
        func keys(_ service: CRMService) -> NativeAIKeys { NativeAIKeys(service: service, store: store, environment: env, clock: { now }) }
        func user(_ role: String, _ name: String) throws -> NativeRecord { try db.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE")], actor: identity.id) }
        let alice = try user("user", "alice"), bob = try user("user", "bob"), manager = try user("manager", "manager"), partner = try user("partner", "partner")
        func service(_ row: NativeRecord) -> CRMService { CRMService(db: db, identity: .init(id: row["id"].string, role: row["role"].string, partnerAccountID: nil)) }
        let a = keys(service(alice)), b = keys(service(bob)), shared = keys(admin)
        func set(_ value: String?, _ owner: NativeAIKeys, _ provider: NativeAIProvider, _ scope: NativeAIKeyScope) throws {
            let setting = try owner.setting(provider, scope: scope)
            if let value { try owner.save(setting, key: value) } else { try owner.remove(setting) }
        }
        for item in reference.cases {
            environment[item.provider.environmentName] = item.environment
            try set(item.system, shared, item.provider, .system); try set(item.personal, a, item.provider, .user)
            try check(try a.resolve(item.provider)?.key == item.expected, "actual getApiKey priority reference \(item.provider)")
        }
        environment = [:]
        for provider in NativeAIProvider.allCases { try set(nil, shared, provider, .system); try set(nil, a, provider, .user) }
        try check(store.values.isEmpty, "retired secrets removed")
        for role in [a, b, keys(service(manager)), keys(service(partner))] {
            try rejects("system management requires admin") { _ = try role.setting(.openai, scope: .system) }
            try set("personal-test-1111", role, .openai, .user)
        }
        try set("alice-only-2222", a, .openai, .user)
        try check(try b.resolve(.openai)?.key == "personal-test-1111", "personal owner isolation")
        let foreign = try a.setting(.openai, scope: .user)
        try rejects("cannot save another user's snapshot") { try b.save(foreign, key: "intruder-0000") }
        try rejects("cannot delete another user's snapshot") { try b.remove(foreign) }
        try set("system-test-3333", shared, .openai, .system)
        let resolved = try a.resolve(.openai)!
        try check(resolved.key == "system-test-3333" && resolved.choice.source == .system && resolved.masked == "••••3333", "system usable without system management")
        try set("system-test-4444", shared, .openai, .system)
        try rejects("key changed while provider request runs") { try a.requireCurrent(resolved) }
        let stale = try a.setting(.openai, scope: .user)
        try set("personal-new-5555", a, .openai, .user)
        let before = store.saveCount
        try rejects("stale save rejected before Keychain write") { try a.save(stale, key: "stale-value-0000") }
        try check(store.saveCount == before, "no side effect on initial conflict")
        let current = try a.setting(.openai, scope: .user)
        store.failSave = true
        try rejects("failed Keychain save preserves old setting") { try a.save(current, key: "will-fail-9999") }
        store.failSave = false
        try check(try a.setting(.openai, scope: .user) == current, "old setting retained")
        try set(nil, shared, .openai, .system)
        try check(try a.resolve(.openai)?.key == "personal-new-5555", "system deletion falls back to personal")
        store.failRemove = true
        try set("replacement-6666", a, .openai, .user)
        try check(try a.resolve(.openai)?.key == "replacement-6666" && a.cleanup().pending == 1, "cleanup failure does not undo committed key")
        store.failRemove = false
        try check(try a.cleanup().removed == 1, "durable cleanup retry")

        let concurrent = try a.setting(.openai, scope: .user)
        store.onSave = { try set("concurrent-winner-7777", a, .openai, .user) }
        try rejects("change during Keychain save") { try a.save(concurrent, key: "concurrent-loser-8888") }
        try check(try a.resolve(.openai)?.key == "concurrent-winner-7777", "concurrent winning key preserved")
        store.onSave = { now = now.addingTimeInterval(601); _ = try a.cleanup() }
        try rejects("expired staging reservation") { try a.save(a.setting(.openai, scope: .user), key: "expired-key-9999") }
        try check(try a.resolve(.openai)?.key == "concurrent-winner-7777", "expired publisher cannot resurrect removed secret")
        store.onLoad = { try set("load-changed-0001", a, .openai, .user) }
        try rejects("selection changed during Keychain load") { _ = try a.resolve(.openai) }
        store.failLoad = true
        try rejects("locked key does not silently fall back") { _ = try a.resolve(.openai) }
        store.failLoad = false
        for invalid in ["", "a b", "a\nb", "日本語", String(repeating: "x", count: 16_385)] { try rejects("invalid API key") { try a.save(a.setting(.openai, scope: .user), key: invalid) } }
        environment[NativeAIProvider.openai.environmentName] = " env-real-9999 "
        let loads = store.loads, envKey = try a.resolve(.openai)!
        try check(envKey.choice.source == .environment && envKey.key == "env-real-9999" && store.loads == loads, "environment bypasses Keychain")
        environment[NativeAIProvider.openai.environmentName] = "your-api-key"
        try rejects("environment precedence change fences existing result") { try a.requireCurrent(envKey) }
        try check(try a.resolve(.openai)?.key == "load-changed-0001", "placeholder does not shadow DB")
        environment = [:]

        let pointer = try a.setting(.openai, scope: .user).rows[0], bytes = store.values[pointer.credentialID!]!
        var encoded = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        encoded["ownerID"] = bob["id"].string; store.values[pointer.credentialID!] = try JSONSerialization.data(withJSONObject: encoded)
        try rejects("Keychain owner binding") { _ = try a.resolve(.openai) }
        encoded["ownerID"] = alice["id"].string; encoded["provider"] = "GROQ"; store.values[pointer.credentialID!] = try JSONSerialization.data(withJSONObject: encoded)
        try rejects("Keychain provider binding") { _ = try a.resolve(.openai) }
        store.values[pointer.credentialID!] = bytes
        let reopened = NativeAIKeys(service: CRMService(db: try open(), identity: a.service.identity), store: store, environment: env)
        try check(try reopened.resolve(.openai)?.key == "load-changed-0001", "database reopen preserves credential reference")
        for type: String in ["encrypted-legacy", "native-ai-keychain:not-a-uuid"] {
            let raw = try db.insert("ApiKeys", values: ["scope": .text("USER"), "provider": .text("FIRECRAWL"), "userId": alice["id"], "encryptedKey": .text(type)], actor: identity.id)
            try check(try a.setting(.firecrawl, scope: .user).needsReplacement, "legacy key explicitly requires migration")
            try rejects("legacy ciphertext not sent as plaintext") { _ = try a.resolve(.firecrawl) }
            try db.remove(raw, actor: identity.id)
        }
        for _ in 0..<2 { _ = try db.insert("ApiKeys", values: ["scope": .text("USER"), "provider": .text("FIRECRAWL"), "userId": alice["id"], "encryptedKey": .text("legacy")], actor: identity.id) }
        try rejects("duplicate keys require repair") { _ = try a.resolve(.firecrawl) }
        try set("repaired-key-1234", a, .firecrawl, .user)
        try check(try a.setting(.firecrawl, scope: .user).rows.count == 1 && a.resolve(.firecrawl)?.key == "repaired-key-1234", "replace all duplicate rows atomically")
        func sql(_ text: String) throws {
            var connection: OpaquePointer?
            guard sqlite3_open(db.url.path, &connection) == SQLITE_OK else { throw NativeDBError.conflict }
            defer { sqlite3_close(connection) }
            guard sqlite3_exec(connection, text, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message("test SQL failed") }
        }
        try sql("CREATE TRIGGER ai_test_abort BEFORE INSERT ON ApiKeys BEGIN SELECT RAISE(ABORT,'test rollback'); END;")
        let beforeRollback = try a.setting(.openai, scope: .user), secretCount = store.values.count
        try rejects("DB transaction failure after Keychain write") { try a.save(beforeRollback, key: "rollback-key-2222") }
        try sql("DROP TRIGGER ai_test_abort;")
        try check(try a.setting(.openai, scope: .user) == beforeRollback && store.values.count == secretCount && a.resolve(.openai)?.key == "load-changed-0001", "DB rollback preserves old key and cleans unpublished key")
        let orphan = UUID().uuidString.lowercased(); try db.queueAIKeyCleanup(orphan, notBefore: now.addingTimeInterval(600)); store.values[orphan] = Data("fake orphan".utf8)
        try check(try a.cleanup().removed == 0 && store.values[orphan] != nil, "unexpired reservation protected")
        now = now.addingTimeInterval(601)
        try check(try reopened.cleanup().removed == 0, "cleanup uses configured clock")
        try check(try a.cleanup().removed == 1 && store.values[orphan] == nil, "crash-leftover reservation reclaimed after expiry")
        let liveID = try a.setting(.openai, scope: .user).rows[0].credentialID!
        try db.queueAIKeyCleanup(liveID, notBefore: now)
        try check(try a.cleanup().removed == 0 && store.values[liveID] != nil, "cleanup cannot remove referenced key")
        try db.clearAIKeyCleanup(liveID)
        for file in [db.url, URL(fileURLWithPath: db.url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            try check(data.range(of: Data("load-changed-0001".utf8)) == nil && data.range(of: Data("repaired-key-1234".utf8)) == nil, "plaintext absent from DB/WAL/audit")
        }
        _ = try db.update(alice, changes: ["banned": .integer(1)], actor: identity.id)
        try rejects("banned user resolve") { _ = try a.resolve(.openai) }
        try rejects("banned user settings") { _ = try a.setting(.openai, scope: .user) }
        if CommandLine.arguments.contains("--keychain") {
            let keychain = KeychainNativeAISecrets(databaseURL: db.url), id = UUID().uuidString.lowercased(), payload = Data("synthetic-ai-keychain-verification".utf8)
            defer { try? keychain.remove(id: id) }
            try keychain.save(id: id, data: payload)
            try check(try KeychainNativeAISecrets(databaseURL: db.url).load(id: id, interactive: false) == payload, "actual Mac Keychain persist/load")
            try check(try KeychainNativeAISecrets(databaseURL: folder.appendingPathComponent("other.sqlite")).load(id: id, interactive: false) == nil, "actual Keychain database namespace")
            try keychain.remove(id: id); try check(try keychain.load(id: id, interactive: false) == nil, "actual Keychain removal")
        }
    }
}
