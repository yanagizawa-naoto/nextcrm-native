import Foundation

enum NativeMCPSettingsError: LocalizedError {
    case forbidden, invalid, credentials, cleanupFull
    var errorDescription: String? {
        switch self {
        case .forbidden: return "MCP の設定を変更できるのは管理者だけです。"
        case .invalid: return "MCP の設定を確認してください。ポート番号は 1024〜65535、同時接続数は 2〜32 です。"
        case .credentials: return "MCP の署名キーを利用できません。Mac のキーチェーンを確認するか、設定で署名キーを再作成してください。"
        case .cleanupFull: return "以前の署名キーを整理できません。Mac のキーチェーンを確認してから、もう一度お試しください。"
        }
    }
}

/// This snapshot contains references and ordinary settings only, never secret
/// bytes. A database backup alone cannot move its path-scoped Keychain item.
struct NativeMCPSettings: Codable, Equatable {
    var version = 1
    var enabled = false
    var port = 53180
    var maximumConnections = 4
    var revision: Int64 = 0
    var bucket = "nextcrm"
    var credentialID: String?
    var configuredBy: String?
    var hasSigningSecret: Bool { credentialID != nil }
    var origin: String { "http://127.0.0.1:\(port)" }
    var endpoint: String { origin + "/api/mcp/mcp" }
    func validate() throws {
        guard version == 1, (1024...65535).contains(port), (2...32).contains(maximumConnections), revision >= 0,
              !bucket.isEmpty, bucket.utf8.count <= 1024, !bucket.contains("\0"),
              credentialID.map({ UUID(uuidString: $0) != nil }) ?? true,
              !enabled || (credentialID != nil && configuredBy != nil) else { throw NativeMCPSettingsError.invalid }
    }
}

final class NativeMCPSettingsStore {
    static let metadataKey = "mcp.settings.v1", cleanupKey = "mcp.signing.cleanup.v1"
    static let didChange = Notification.Name("NextCRMNativeMCPSettingsChanged")
    let service: CRMService, secretStore: NativeMCPSecretStore
    private let clock: () -> Date
    init(service: CRMService, secretStore: NativeMCPSecretStore? = nil, clock: @escaping () -> Date = Date.init) {
        self.service = service; self.secretStore = secretStore ?? KeychainNativeMCPSecrets(databaseURL: service.db.url); self.clock = clock
    }
    private func access() throws {
        try service.authenticated()
        guard service.identity.role == "admin" else { throw NativeMCPSettingsError.forbidden }
    }
    static func read(db: NativeDatabase) throws -> NativeMCPSettings {
        try db.transaction {
            var value: NativeMCPSettings
            if let raw = try db.metadata(metadataKey) {
                guard raw.utf8.count <= 8192, let parsed = try? JSONDecoder().decode(NativeMCPSettings.self, from: Data(raw.utf8)) else { throw NativeMCPSettingsError.invalid }
                value = parsed
            } else { value = .init() }
            if let bucket = try db.metadata("document.storage.bucket") { value.bucket = bucket }
            try value.validate(); return value
        }
    }
    func snapshot() throws -> NativeMCPSettings { try service.db.transaction { try access(); return try Self.read(db: service.db) } }
    private static func pending(db: NativeDatabase) throws -> [String: Double] {
        guard let raw = try db.metadata(cleanupKey) else { return [:] }
        guard raw.utf8.count <= 128 * 1024, let values = try? JSONDecoder().decode([String: Double].self, from: Data(raw.utf8)), values.count <= 1024,
              values.allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.isFinite }) else { throw NativeMCPSettingsError.credentials }
        return values
    }
    private static func putPending(_ values: [String: Double], db: NativeDatabase) throws {
        let data = try JSONEncoder().encode(values); try db.setMetadata(cleanupKey, value: String(decoding: data, as: UTF8.self))
    }
    @discardableResult static func cleanup(db: NativeDatabase, secretStore: NativeMCPSecretStore, now: Date) throws -> (removed: Int, pending: Int) {
        guard !db.isReadOnly else { throw NativeDBError.message("このデータベースは閲覧専用です。") }
        var removed = 0
        // The settings publication and reference test share the same DB lock.
        // A failed delete leaves the durable reservation for a later attempt.
        let ids = try db.transaction { try pending(db: db).filter { $0.value <= now.timeIntervalSince1970 }.map(\.key).sorted() }
        for id in ids {
            try db.transaction {
                var values = try pending(db: db)
                guard let deadline = values[id], deadline <= now.timeIntervalSince1970,
                      try read(db: db).credentialID != id else { return }
                do { try secretStore.remove(id: id) } catch { return }
                values.removeValue(forKey: id); try putPending(values, db: db); removed += 1
            }
        }
        return (removed, try db.transaction { try pending(db: db).count })
    }
    @discardableResult func cleanup() throws -> (removed: Int, pending: Int) {
        try service.db.transaction { try access() }
        return try Self.cleanup(db: service.db, secretStore: secretStore, now: clock())
    }
    @discardableResult func save(expected: NativeMCPSettings, enabled: Bool, port: Int, maximumConnections: Int, rotateSecret: Bool = false) throws -> NativeMCPSettings {
        let db = service.db
        var next = expected; next.enabled = enabled; next.port = port; next.maximumConnections = maximumConnections
        guard (1024...65535).contains(port), (2...32).contains(maximumConnections), !rotateSecret || enabled else { throw NativeMCPSettingsError.invalid }
        let create = enabled && (expected.credentialID == nil || rotateSecret)
        let freshID = create ? UUID().uuidString.lowercased() : nil
        try db.transaction {
            try access(); guard try Self.read(db: db) == expected, expected.revision < Int64.max else { throw NativeDBError.conflict }
            if let freshID {
                var values = try Self.pending(db: db)
                guard values.count < 1024 else { throw NativeMCPSettingsError.cleanupFull }
                values[freshID] = clock().addingTimeInterval(600).timeIntervalSince1970
                try Self.putPending(values, db: db)
            }
        }
        do {
            if let freshID {
                try Task.checkCancellation()
                try secretStore.save(id: freshID, data: KeychainNativeMCPSecrets.generate())
            }
            try Task.checkCancellation()
            next = try db.transaction {
                try access(); guard try Self.read(db: db) == expected else { throw NativeDBError.conflict }
                if let freshID {
                    var values = try Self.pending(db: db)
                    guard let deadline = values[freshID], deadline > clock().timeIntervalSince1970 else { throw NativeDBError.conflict }
                    values.removeValue(forKey: freshID)
                    if let previous = expected.credentialID { values[previous] = clock().timeIntervalSince1970 }
                    try Self.putPending(values, db: db); next.credentialID = freshID
                }
                next.revision = expected.revision + 1; next.configuredBy = service.identity.id
                try next.validate()
                if enabled, try db.metadata("document.storage.bucket") == nil { try db.setMetadata("document.storage.bucket", value: next.bucket) }
                try db.setMetadata(Self.metadataKey, value: String(decoding: JSONEncoder().encode(next), as: UTF8.self))
                try Task.checkCancellation(); return next
            }
        } catch {
            if let freshID {
                try? db.transaction {
                    var values = try Self.pending(db: db); values[freshID] = clock().timeIntervalSince1970
                    try Self.putPending(values, db: db)
                }
                _ = try? Self.cleanup(db: db, secretStore: secretStore, now: clock())
            }
            throw error
        }
        if enabled { _ = try? Self.cleanup(db: db, secretStore: secretStore, now: clock()) }
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["database": db.url.path])
        return next
    }
    static func signingSecret(expected: NativeMCPSettings, db: NativeDatabase, store: NativeMCPSecretStore) throws -> String {
        guard expected.enabled, let id = expected.credentialID else { throw NativeMCPSettingsError.credentials }
        guard let data = try store.load(id: id), data.count == 32 else { throw NativeMCPSettingsError.credentials }
        try requireCurrent(expected, db: db)
        return data.base64EncodedString()
    }
    static func requireCurrent(_ expected: NativeMCPSettings, db: NativeDatabase) throws {
        guard try read(db: db) == expected, expected.enabled else { throw NativeDBError.conflict }
    }
}
