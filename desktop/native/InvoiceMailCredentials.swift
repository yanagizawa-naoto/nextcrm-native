import Foundation
import Security
import LocalAuthentication
import CryptoKit

struct InvoiceMailAccount: Codable {
    let from: String
    let apiKey: String
}

protocol InvoiceMailCredentialStore {
    func load(interactive: Bool) throws -> InvoiceMailAccount?
    func save(_ account: InvoiceMailAccount) throws
    func remove() throws
}

/// The sender and secret are one Keychain item, so an interrupted update cannot
/// pair a new sender with the old secret. Separate databases have separate items.
struct KeychainInvoiceMailCredentials: InvoiceMailCredentialStore {
    private let account: String
    init(databaseURL: URL) {
        let path = databaseURL.resolvingSymlinksInPath().standardizedFileURL.path
        account = SHA256.hash(data:Data(path.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.nextcrm.native.invoice-mail",kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]
    }
    private func failure() -> NativeDBError { .message("メール設定のキーチェーンを利用できません。Macのキーチェーンを解除してから、もう一度お試しください。") }
    func load(interactive: Bool = false) throws -> InvoiceMailAccount? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure() }
        guard let settings = try? JSONDecoder().decode(InvoiceMailAccount.self,from:data) else { throw NativeDBError.message("保存したメール設定を読み取れません。メール送信の設定を保存し直してください。") }
        return settings
    }
    func save(_ settings: InvoiceMailAccount) throws {
        let data = try JSONEncoder().encode(settings)
        let changes = [kSecValueData as String:data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary,changes)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "NextCRM 請求書メール送信"
            status = SecItemAdd(item as CFDictionary,nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary,changes) }
        }
        guard status == errSecSuccess else { throw failure() }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
}

extension CRMService {
    func invoiceMailSender(store: InvoiceMailCredentialStore) throws -> String? {
        try authenticated()
        guard identity.role != "partner" else { throw NativeDBError.message("メール送信の設定を利用する権限がありません。") }
        return try store.load(interactive:false)?.from
    }
    func saveInvoiceMailSettings(from: String, apiKey: String, store: InvoiceMailCredentialStore) throws {
        try authenticated()
        guard identity.role == "admin" else { throw NativeDBError.message("メール送信の設定は管理者が変更してください。") }
        let sender = try InvoiceMail.mailbox(from)
        let key = try apiKey.isEmpty ? store.load(interactive:true)?.apiKey ?? "" : apiKey
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { throw NativeDBError.message("送信サービスのAPIキーを入力してください。") }
        try store.save(.init(from:sender,apiKey:key))
    }
    func removeInvoiceMailSettings(store: InvoiceMailCredentialStore) throws {
        try authenticated()
        guard identity.role == "admin" else { throw NativeDBError.message("メール送信の設定は管理者が変更してください。") }
        try store.remove()
    }
}
