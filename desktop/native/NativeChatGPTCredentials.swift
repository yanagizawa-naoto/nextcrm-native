import Foundation
import Security
import LocalAuthentication
import CryptoKit

protocol NativeChatGPTCredentialStore: Sendable {
    func load() throws -> Data?
    /// Replace one complete envelope atomically. An unexpected prior value fails closed.
    func replace(_ value: Data, expected: Data?) throws
}

/// The envelope is never placed in SQLite, backups, environment variables or logs.
/// The application already holds the workspace's exclusive instance lease.
struct KeychainNativeChatGPTCredentials: NativeChatGPTCredentialStore {
    private let account: String
    private static let lock = NSLock()
    init(databaseURL: URL, ownerID: String) {
        let binding = databaseURL.resolvingSymlinksInPath().standardizedFileURL.path + "\u{0}" + ownerID
        account = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var query: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.nextcrm.native.chatgpt.v1", kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false, kSecUseAuthenticationContext as String: context]
    }
    private func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 1_048_576 else { throw failure() }; return data
    }
    func load() throws -> Data? { Self.lock.lock(); defer { Self.lock.unlock() }; return try read() }
    func replace(_ value: Data, expected: Data?) throws {
        guard value.count <= 1_048_576 else { throw failure() }
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard try read() == expected else { throw NativeChatGPTError.invalid("接続設定が別の操作で変更されました。画面を開き直してください。") }
        let status: OSStatus
        if expected == nil {
            var q = query; q[kSecValueData as String] = value; q[kSecAttrLabel as String] = "NextCRM ChatGPT接続"
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        } else { status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary) }
        guard status == errSecSuccess else { throw failure() }
    }
    private func failure() -> NativeChatGPTError { .invalid("ChatGPTの認証を安全に保存・取得できません。Macのキーチェーンを確認してください。") }
}

struct NativeChatGPTTokens: Codable, Equatable {
    let access: String, refresh: String?, idToken: String
    let scopes: [String], expiresAt: Date, earliestRefreshAt: Date?
    var permitsInference: Bool { scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
    static func parse(_ json: [String: Any], now: Date, prior: NativeChatGPTTokens? = nil) throws -> Self {
        let failure = NativeChatGPTError.invalid("ChatGPTの認証応答が不正です。")
        guard let access = json["access_token"] as? String, (json["token_type"] as? String)?.lowercased() == "bearer",
              let duration = json["expires_in"] as? NSNumber, CFGetTypeID(duration) != CFBooleanGetTypeID(), duration.doubleValue.isFinite, duration.doubleValue > 0, duration.doubleValue <= 31_536_000 else { throw failure }
        let refresh = json["refresh_token"] as? String
        if let refresh { _ = try NativeChatGPTOAuth.token(refresh) }
        // A rotating refresh response must provide its replacement.
        if prior != nil, refresh == nil { throw failure }
        let id = json["id_token"] as? String ?? prior?.idToken
        guard let id else { throw failure }; _ = try NativeChatGPTOAuth.token(id)
        let scope = json["scope"] as? String
        guard scope != nil || prior != nil, (scope?.utf8.count ?? 0) <= 4096 else { throw failure }
        let scopes = scope?.split(separator: " ").map(String.init) ?? prior!.scopes
        if scopes.contains("offline_access"), refresh == nil { throw failure }
        var earliest: Date?
        if let raw = json["earliest_refresh_at"] {
            // OAuth extension is a Unix timestamp (seconds); a malformed bound is never ignored.
            if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 253_402_300_799 { earliest = Date(timeIntervalSince1970: n.doubleValue) }
            else if let text = raw as? String, let date = ISO8601DateFormatter().date(from: text) { earliest = date }
            else { throw failure }
        }
        return .init(access: try NativeChatGPTOAuth.token(access), refresh: refresh, idToken: id, scopes: scopes, expiresAt: now.addingTimeInterval(duration.doubleValue), earliestRefreshAt: earliest)
    }
}

struct NativeChatGPTRegistration: Codable, Equatable {
    let id: String
    var identity: NativeChatGPTIdentity
    var tokens: NativeChatGPTTokens?
    var model: String?
    var backgroundConsent = false
    var welcomed = false
}
struct NativeChatGPTEnvelope: Codable, Equatable {
    var version = 1
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var accounts: [NativeChatGPTRegistration] = []
    var selected: String?
    var useChatGPT = false
    func validated() throws -> Self {
        guard version == 1, hostID.hasPrefix("urn:uuid:"), UUID(uuidString: String(hostID.dropFirst(9))) != nil, accounts.count <= 16,
              Set(accounts.map(\.id)).count == accounts.count, selected == nil || accounts.contains(where: { $0.id == selected }) else { throw NativeChatGPTError.invalid("保存済みのChatGPT設定を読み取れません。") }
        for account in accounts {
            guard UUID(uuidString: account.id) != nil, account.identity.issuer == NativeChatGPTOAuth.issuer, !account.identity.subject.isEmpty else { throw NativeChatGPTError.invalid("保存済みのChatGPT設定が不正です。") }
            _ = try NativeChatGPTOAuth.client(account.identity.clientID)
            if let tokens = account.tokens { _ = try NativeChatGPTOAuth.token(tokens.access); _ = try NativeChatGPTOAuth.token(tokens.idToken); if let refresh = tokens.refresh { _ = try NativeChatGPTOAuth.token(refresh) } }
        }
        return self
    }
}
