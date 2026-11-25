import Foundation
import Security
import LocalAuthentication
import CryptoKit

protocol NativeMCPSecretStore {
    func load(id: String) throws -> Data?
    func save(id: String, data: Data) throws
    func remove(id: String) throws
}

/// A different database and purpose never share a signing credential. Secrets
/// are immutable: rotation publishes a new reference, never overwrites a key.
struct KeychainNativeMCPSecrets: NativeMCPSecretStore {
    private let database: String
    init(databaseURL: URL) {
        database = SHA256.hash(data: Data(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func query(_ id: String) throws -> [String: Any] {
        guard UUID(uuidString: id) != nil else { throw NativeMCPSettingsError.credentials }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.nextcrm.native.mcp.runtime-signing.v1",
                kSecAttrAccount as String: database + "/" + id,
                kSecAttrSynchronizable as String: false]
    }
    private func withoutInteraction(_ query: [String: Any]) -> [String: Any] {
        var result = query
        let context = LAContext(); context.interactionNotAllowed = true
        result[kSecUseAuthenticationContext as String] = context
        return result
    }
    func load(id: String) throws -> Data? {
        var q = withoutInteraction(try query(id)); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else { throw NativeMCPSettingsError.credentials }
        return data
    }
    func save(id: String, data: Data) throws {
        guard data.count == 32 else { throw NativeMCPSettingsError.credentials }
        var q = withoutInteraction(try query(id)); q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "NextCRM MCP 署名"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw NativeMCPSettingsError.credentials }
    }
    func remove(id: String) throws {
        let status = SecItemDelete(withoutInteraction(try query(id)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeMCPSettingsError.credentials }
    }
    static func generate() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeMCPSettingsError.credentials }
        return Data(bytes)
    }
}
