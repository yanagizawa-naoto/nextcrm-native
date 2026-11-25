import Foundation
import Security
import LocalAuthentication
import CryptoKit

enum NativeAIProvider: String, CaseIterable, Codable {
    case openai = "OPENAI", firecrawl = "FIRECRAWL", anthropic = "ANTHROPIC", groq = "GROQ"
    var title: String {
        switch self { case .openai: return "OpenAI"; case .firecrawl: return "Firecrawl"; case .anthropic: return "Anthropic"; case .groq: return "Groq" }
    }
    var environmentName: String { rawValue + "_API_KEY" }
}
enum NativeAIKeyScope: String, Codable { case system = "SYSTEM", user = "USER" }
enum NativeAIKeySource: String { case environment, system, user, none
    var title: String { switch self { case .environment: return "環境設定"; case .system: return "共通キー"; case .user: return "個人キー"; case .none: return "未設定" } }
}
protocol NativeAISecretStore {
    func load(id: String, interactive: Bool) throws -> Data?
    func save(id: String, data: Data) throws
    func remove(id: String) throws
}
struct KeychainNativeAISecrets: NativeAISecretStore {
    private let database: String
    init(databaseURL: URL) { database = NativeEmbeddingVector.hash(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path) }
    private func query(_ id: String) throws -> [String: Any] {
        guard UUID(uuidString: id) != nil else { throw NativeDBError.conflict }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.nextcrm.native.ai.v1", kSecAttrAccount as String: database + "/" + id, kSecAttrSynchronizable as String: false]
    }
    private func failure() -> NativeAIError { .init(message: "AIのAPIキーを利用できません。Macのキーチェーンを解除してから、もう一度お試しください。") }
    func load(id: String, interactive: Bool) throws -> Data? {
        var q = try query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else { throw failure() }; return data
    }
    func save(id: String, data: Data) throws {
        guard data.count <= 65_536 else { throw failure() }
        var q = try query(id); q[kSecValueData as String] = data; q[kSecAttrLabel as String] = "NextCRM AI連携"
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw failure() }
    }
    func remove(id: String) throws {
        var q = try query(id); let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context
        let status = SecItemDelete(q as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
}

struct NativeAIKeyRow: Equatable {
    let id: String, revision: Int64, credentialID: String?
}
struct NativeAIKeySetting: Equatable {
    let provider: NativeAIProvider, scope: NativeAIKeyScope, ownerID: String?
    let rows: [NativeAIKeyRow]
    var isSet: Bool { !rows.isEmpty }
    var needsReplacement: Bool { rows.count > 1 || rows.contains { $0.credentialID == nil } }
}
struct NativeAIKeyChoice: Equatable {
    let provider: NativeAIProvider, source: NativeAIKeySource
    var row: NativeAIKeyRow? = nil
    var environmentHash: String? = nil
}
struct NativeAIResolvedKey {
    let choice: NativeAIKeyChoice
    let key: String
    var masked: String { key.count > 4 ? "••••" + key.suffix(4) : "••••" }
}
struct NativeAICredential: Codable {
    var version = 1
    let recordID: String, provider: NativeAIProvider, scope: NativeAIKeyScope, ownerID: String?, key: String
}
struct NativeAIEnvironment {
    let lookup: (String) -> String?
    init(lookup: @escaping (String) -> String? = { ProcessInfo.processInfo.environment[$0] }) { self.lookup = lookup }
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let leading = scalars.drop { NativeEmbeddingVector.isBlank(String($0)) }
        return String(String.UnicodeScalarView(leading.reversed().drop { NativeEmbeddingVector.isBlank(String($0)) }.reversed()))
    }
    func key(_ provider: NativeAIProvider) -> String? {
        key(environmentName: provider.environmentName)
    }
    func key(environmentName: String) -> String? {
        guard let raw = lookup(environmentName) else { return nil }
        let value = Self.trim(raw)
        guard !value.isEmpty, value.range(of: "placeholder", options: .caseInsensitive) == nil,
              !value.lowercased().hasPrefix("your-"), !value.lowercased().hasPrefix("your_") else { return nil }
        return value
    }
}

/// Settings/credential service shared by the Japanese UI and background jobs.
/// Keychain publication is fenced by a durable reservation; retired secrets
/// remain queued until removal succeeds, without invalidating a committed key.
struct NativeAIKeys {
    let service: CRMService, store: NativeAISecretStore
    var environment = NativeAIEnvironment()
    var clock: () -> Date = Date.init
    static let prefix = NativeUserCredentialCleanup.Family.ai.prefix
    static let didChange = Notification.Name("NextCRMNativeAIKeysChanged")
    private var db: NativeDatabase { service.db }
    private func access(_ scope: NativeAIKeyScope) throws {
        try service.authenticated()
        guard scope != .system || service.identity.role == "admin" else { throw NativeAIError(message: "共通APIキーを変更できるのは管理者だけです。") }
    }
    private func filter(_ provider: NativeAIProvider, _ scope: NativeAIKeyScope) -> RecordFilter {
        .every([.equal("provider", .text(provider.rawValue)), .equal("scope", .text(scope.rawValue))] + (scope == .user ? [.equal("userId", .text(service.identity.id))] : []))
    }
    private func rows(_ provider: NativeAIProvider, _ scope: NativeAIKeyScope) throws -> [NativeAIKeyRow] {
        var result: [NativeAIKeyRow] = [], after: String?
        while true {
            let page = try db.keysetPage("ApiKeys", fields: ["encryptedKey"], after: after, filter: filter(provider, scope))
            for row in page {
                let pointer = row["encryptedKey"].string
                let suffix = pointer.hasPrefix(Self.prefix) ? String(pointer.dropFirst(Self.prefix.count)) : ""
                result.append(.init(id: row["id"].string, revision: row.revision, credentialID: UUID(uuidString: suffix) == nil ? nil : suffix))
            }
            if page.count < 100 { return result }; after = page.last!["id"].string
        }
    }
    func setting(_ provider: NativeAIProvider, scope: NativeAIKeyScope) throws -> NativeAIKeySetting {
        try db.transaction {
            try access(scope)
            return .init(provider: provider, scope: scope, ownerID: scope == .user ? service.identity.id : nil, rows: try rows(provider, scope))
        }
    }
    private func selection(_ provider: NativeAIProvider) throws -> (NativeAIKeyChoice, String?) {
        try service.authenticated()
        if let key = environment.key(provider) { return (.init(provider: provider, source: .environment, environmentHash: NativeEmbeddingVector.hash(key)), key) }
        for scope: NativeAIKeyScope in [.system, .user] {
            let rows = try rows(provider, scope)
            if !rows.isEmpty {
                guard rows.count == 1 else { throw NativeAIError(message: "\(provider.title)のAPIキーが複数登録されています。設定を保存し直してください。") }
                return (.init(provider: provider, source: scope == .system ? .system : .user, row: rows[0]), nil)
            }
        }
        return (.init(provider: provider, source: .none), nil)
    }
    func source(_ provider: NativeAIProvider) throws -> NativeAIKeySource { try db.transaction { try selection(provider).0.source } }
    static func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 16_384, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw NativeAIError(message: "APIキーを確認してください。空白や改行を含むキーは保存できません。") }
    }
    func resolve(_ provider: NativeAIProvider, interactive: Bool = false) throws -> NativeAIResolvedKey? {
        let (choice, environmentKey) = try db.transaction { try selection(provider) }
        if choice.source == .none { return nil }
        let key: String
        if let environmentKey { key = environmentKey }
        else {
            guard let row = choice.row, let id = row.credentialID else { throw NativeAIError(message: "以前のAPIキーを移行できていません。キーを入力して保存し直してください。") }
            let data: Data?
            do { data = try store.load(id: id, interactive: interactive) }
            catch { throw NativeAIError(message: "APIキーを読み取れません。Macのキーチェーンを確認してください。") }
            guard let data, data.count <= 65_536, let credential = try? JSONDecoder().decode(NativeAICredential.self, from: data), credential.version == 1,
                  credential.recordID == row.id, credential.provider == provider,
                  credential.scope == (choice.source == .system ? .system : .user), credential.ownerID == (choice.source == .system ? nil : service.identity.id) else {
                throw NativeAIError(message: "APIキーの保存情報が一致しません。設定を保存し直してください。")
            }
            key = credential.key
        }
        try Self.validate(key)
        let result = NativeAIResolvedKey(choice: choice, key: key); try requireCurrent(result)
        return result
    }
    func requireCurrent(_ key: NativeAIResolvedKey) throws {
        try requireCurrent(key.choice)
    }
    func requireCurrent(_ choice: NativeAIKeyChoice) throws {
        try db.transaction { guard try selection(choice.provider).0 == choice else { throw NativeDBError.conflict } }
    }
    func save(_ expected: NativeAIKeySetting, key: String) throws {
        try Self.validate(key)
        let id = UUID().uuidString.lowercased()
        try db.transaction {
            guard try setting(expected.provider, scope: expected.scope) == expected else { throw NativeDBError.conflict }
            try db.queueAIKeyCleanup(id, notBefore: clock().addingTimeInterval(600))
        }
        do {
            let credential = NativeAICredential(recordID: id, provider: expected.provider, scope: expected.scope, ownerID: expected.ownerID, key: key)
            do { try store.save(id: id, data: JSONEncoder().encode(credential)) }
            catch { throw NativeAIError(message: "APIキーをキーチェーンに保存できません。以前の設定は保持されています。") }
            try db.transaction {
                guard try setting(expected.provider, scope: expected.scope) == expected else { throw NativeDBError.conflict }
                try db.requireAIKeyReservation(id, now: clock())
                try retire(expected)
                _ = try db.insert("ApiKeys", values: ["id": .text(id), "scope": .text(expected.scope.rawValue), "userId": expected.ownerID.map(SQLValue.text) ?? .null, "provider": .text(expected.provider.rawValue), "encryptedKey": .text(Self.prefix + id)], actor: service.identity.id)
                try db.clearAIKeyCleanup(id)
            }
        } catch {
            try? db.queueAIKeyCleanup(id, notBefore: clock()); _ = try? cleanup(); throw error
        }
        _ = try? cleanup(); changed()
    }
    private func retire(_ expected: NativeAIKeySetting) throws {
        for row in expected.rows {
            guard let current = try db.get("ApiKeys", key: ["id": .text(row.id)]), current.revision == row.revision else { throw NativeDBError.conflict }
            try db.remove(current, actor: service.identity.id, action: "remove_api_key")
            if let id = row.credentialID { try db.queueAIKeyCleanup(id, notBefore: clock()) }
        }
    }
    func remove(_ expected: NativeAIKeySetting) throws {
        try db.transaction { guard try setting(expected.provider, scope: expected.scope) == expected else { throw NativeDBError.conflict }; try retire(expected) }
        _ = try? cleanup(); changed()
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["database": db.url.path]) }
    @discardableResult func cleanup() throws -> (removed: Int, pending: Int) {
        guard !db.isReadOnly else {throw NativeDBError.message("このデータベースは閲覧専用です。")}
        var after = "", removed = 0, pending = 0
        while true {
            let ids = try db.aiKeyCleanupPage(after: after, now: clock())
            for id in ids {
                do {
                    try db.transaction {
                        guard try !db.aiKeyIsReferenced(id) else { return }
                        guard try !NativeUserCredentialCleanup.isHeld(db: db, credentialID: id) else { pending += 1; return }
                        try store.remove(id: id); try db.clearAIKeyCleanup(id); removed += 1
                    }
                } catch { pending += 1 }
            }
            if ids.count < 100 { return (removed, pending) }; after = ids.last!
        }
    }
}
