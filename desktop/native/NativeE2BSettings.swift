import Foundation

struct NativeE2BSetting: Equatable {
    let credentialID: String?, template: String, revision: String?
}
struct NativeE2BKeyChoice: Equatable {
    let source: NativeAIKeySource, credentialID: String?, environmentHash: String?, template: String
    var configurationHash = ""
}
struct NativeE2BConnection {
    let choice: NativeE2BKeyChoice, key: String
    let configuration: NativeE2BConfiguration
    init(choice: NativeE2BKeyChoice, key: String, configuration: NativeE2BConfiguration = .standard) {
        self.choice = choice; self.key = key; self.configuration = configuration
    }
    var template: String { choice.template }
    var masked: String { key.count > 4 ? "••••" + key.suffix(4) : "••••" }
}
private struct NativeE2BCredential: Codable {
    var version = 1
    let id: String, key: String
}

/// E2B remains a shared server setting, independent of the original four
/// Prisma API-key providers. Only the opaque Keychain reference enters SQLite.
struct NativeE2BSettings {
    let service: CRMService, store: NativeAISecretStore
    var environment = NativeAIEnvironment()
    var clock: () -> Date = Date.init
    static let keyReference = "native_e2b_keychain", templateKey = "native_e2b_template", revisionKey = "native_e2b_revision"
    static let defaultTemplate = "nextcrm-enrichment"
    private var db: NativeDatabase { service.db }
    private var keys: NativeAIKeys { .init(service: service, store: store, environment: environment, clock: clock) }
    private func access(write: Bool = false) throws {
        try service.authenticated()
        guard ["user", "manager", "admin"].contains(service.identity.role), !write || service.identity.role == "admin" else {
            throw NativeAIError(message: "E2Bの共通接続設定を変更できるのは管理者だけです。")
        }
    }
    static func validateTemplate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 512, value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw NativeAIError(message: "実行環境名は512バイト以内の半角文字で入力してください。空白や改行は使用できません。")
        }
    }
    func setting() throws -> NativeE2BSetting {
        try db.transaction {
            try access()
            let id = try db.metadata(Self.keyReference).flatMap { $0.isEmpty ? nil : $0 }
            let revision = try db.metadata(Self.revisionKey)
            guard id == nil || UUID(uuidString: id!) != nil, revision == nil || UUID(uuidString: revision!) != nil else { throw NativeDBError.conflict }
            let template = try db.metadata(Self.templateKey) ?? Self.defaultTemplate
            try Self.validateTemplate(template)
            return .init(credentialID: id, template: template, revision: revision)
        }
    }
    private func selection() throws -> (NativeE2BKeyChoice, String?, NativeE2BConfiguration) {
        let current = try setting()
        let configured = NativeAIEnvironment.trim(environment.lookup("E2B_ENRICHMENT_TEMPLATE") ?? "")
        let template = configured.isEmpty ? current.template : configured
        try Self.validateTemplate(template)
        let configuration = try NativeE2BConfiguration(environment: environment)
        if let key = environment.key(environmentName: "E2B_API_KEY") {
            return (.init(source: .environment, credentialID: nil, environmentHash: NativeEmbeddingVector.hash(key), template: template, configurationHash: configuration.fingerprint), key, configuration)
        }
        return (.init(source: current.credentialID == nil ? .none : .system, credentialID: current.credentialID, environmentHash: nil, template: template, configurationHash: configuration.fingerprint), nil, configuration)
    }
    func source() throws -> NativeE2BKeyChoice { try db.transaction { try selection().0 } }
    func resolve() throws -> NativeE2BConnection? {
        let (choice, environmentKey, configuration) = try db.transaction { try selection() }
        if choice.source == .none { return nil }
        let key: String
        if let environmentKey { key = environmentKey }
        else {
            guard let id = choice.credentialID else { throw NativeDBError.conflict }
            let data: Data?
            do { data = try store.load(id: id, interactive: false) }
            catch { throw NativeAIError(message: "E2BのAPIキーを読み取れません。Macのキーチェーンを確認してください。") }
            guard let data, data.count <= 65_536, let secret = try? JSONDecoder().decode(NativeE2BCredential.self, from: data), secret.version == 1, secret.id == id else {
                throw NativeAIError(message: "E2BのAPIキーを読み取れません。管理者が接続設定を保存し直してください。")
            }
            key = secret.key
        }
        try NativeAIKeys.validate(key)
        let value = NativeE2BConnection(choice: choice, key: key, configuration: configuration); try requireCurrent(value); return value
    }
    func requireCurrent(_ value: NativeE2BConnection) throws {
        try db.transaction { guard try selection().0 == value.choice else { throw NativeDBError.conflict } }
    }
    /// A nil key preserves the existing secret. Replacement uses the same
    /// reservation/cleanup protocol as AI keys, including crash recovery.
    func save(_ expected: NativeE2BSetting, key: String?, template: String) throws {
        try access(write: true); try Self.validateTemplate(template)
        if let key { try NativeAIKeys.validate(key) }
        guard let key else { try publish(expected, id: expected.credentialID, template: template); changed(); return }
        let id = UUID().uuidString.lowercased()
        try db.transaction {
            try access(write: true); guard try setting() == expected else { throw NativeDBError.conflict }
            try db.queueAIKeyCleanup(id, notBefore: clock().addingTimeInterval(600))
        }
        do {
            do { try store.save(id: id, data: JSONEncoder().encode(NativeE2BCredential(id: id, key: key))) }
            catch { throw NativeAIError(message: "E2BのAPIキーをキーチェーンに保存できません。以前の設定は保持されています。") }
            try db.transaction {
                try db.requireAIKeyReservation(id, now: clock())
                try publish(expected, id: id, template: template)
                try db.clearAIKeyCleanup(id)
            }
        } catch {
            try? db.queueAIKeyCleanup(id, notBefore: clock()); _ = try? keys.cleanup(); throw error
        }
        _ = try? keys.cleanup(); changed()
    }
    private func publish(_ expected: NativeE2BSetting, id: String?, template: String) throws {
        try db.transaction {
            try access(write: true); guard try setting() == expected else { throw NativeDBError.conflict }
            try db.setMetadata(Self.keyReference, value: id ?? "")
            try db.setMetadata(Self.templateKey, value: template)
            try db.setMetadata(Self.revisionKey, value: UUID().uuidString.lowercased())
            if let old = expected.credentialID, old != id { try db.queueAIKeyCleanup(old, notBefore: clock()) }
        }
    }
    func removeKey(_ expected: NativeE2BSetting) throws {
        try publish(expected, id: nil, template: expected.template); _ = try? keys.cleanup(); changed()
    }
    private func changed() { NotificationCenter.default.post(name: NativeAIKeys.didChange, object: nil, userInfo: ["database": db.url.path]) }
}
