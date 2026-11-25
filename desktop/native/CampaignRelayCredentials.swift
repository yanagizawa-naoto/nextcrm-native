import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Endpoint identity and its secret are one Keychain item. The database keeps
/// only the public binding and cursor, and never contains the shared secret.
struct CampaignRelayCredentials: Codable, Equatable {
    var version = 1
    let publicURL: String
    let appName: String
    let clientID: String
    let instanceID: String
    let authKey: String

    func client(db: NativeDatabase, allowLoopbackHTTP: Bool = false, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network, clock: @escaping () -> Date = Date.init) throws -> CampaignRelayClient {
        guard version == 1, let binding = try CampaignRelayBinding.load(db:db),
              binding.clientID == clientID, binding.instanceID == instanceID, binding.publicURL == publicURL else {
            throw NativeDBError.message("キーチェーンとCRMのメール受信窓口が一致しません。管理者が接続設定を確認してください。")
        }
        guard let url = URL(string:publicURL) else { throw NativeDBError.message("保存した受信窓口のURLが不正です。") }
        return try CampaignRelayClient(baseURL:url,authKey:authKey,clientID:clientID,expectedInstanceID:instanceID,allowLoopbackHTTP:allowLoopbackHTTP,request:request,clock:clock)
    }
    func configuration(allowLoopbackHTTP: Bool = false) throws -> CampaignMailConfiguration {
        try CampaignMailConfiguration(publicURL:publicURL,appName:appName,allowLoopbackHTTP:allowLoopbackHTTP)
    }
}

protocol CampaignRelayCredentialStore {
    func load(interactive: Bool) throws -> CampaignRelayCredentials?
    func save(_ settings: CampaignRelayCredentials) throws
    func remove() throws
}

struct KeychainCampaignRelayCredentials: CampaignRelayCredentialStore {
    private let account: String
    init(databaseURL: URL) {
        let path = databaseURL.resolvingSymlinksInPath().standardizedFileURL.path
        account = SHA256.hash(data:Data(path.utf8)).map{String(format:"%02x",$0)}.joined()
    }
    private var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.nextcrm.native.campaign-relay.v1",kSecAttrAccount as String:account,kSecAttrSynchronizable as String:false]
    }
    private func failure() -> NativeDBError { .message("受信窓口の接続キーを利用できません。Macのキーチェーンを解除してから、もう一度お試しください。") }
    func load(interactive: Bool = false) throws -> CampaignRelayCredentials? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure() }
        guard let value = try? JSONDecoder().decode(CampaignRelayCredentials.self,from:data), value.version == 1 else {
            throw NativeDBError.message("保存した受信窓口の接続設定を読み取れません。管理者が設定を保存し直してください。")
        }
        return value
    }
    func save(_ settings: CampaignRelayCredentials) throws {
        let data = try JSONEncoder().encode(settings)
        let changes = [kSecValueData as String:data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary,changes)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrLabel as String] = "NextCRM メール受信窓口"
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
    struct CampaignRelayPreferences {
        let publicURL: String
        let appName: String
        let instanceID: String
        let configured: Bool
    }
    private func requireCampaignRelayAdmin() throws {
        try authenticated()
        guard identity.role == "admin" else { throw NativeDBError.message("メール受信窓口の設定は管理者が変更してください。") }
    }
    func campaignRelayPreferences(store: CampaignRelayCredentialStore) throws -> CampaignRelayPreferences {
        try requireCampaignRelayAdmin()
        let value = try store.load(interactive:false), binding = try CampaignRelayBinding.load(db:db)
        let configured = value != nil && binding != nil && value!.version == 1 && value!.clientID == binding!.clientID && value!.instanceID == binding!.instanceID && value!.publicURL == binding!.publicURL
        return .init(publicURL:binding?.publicURL ?? value?.publicURL ?? "",appName:value?.appName ?? "NextCRM",instanceID:binding?.instanceID ?? "",configured:configured)
    }
    func saveCampaignRelaySettings(publicURL: String, appName: String, authKey: String, store: CampaignRelayCredentialStore, allowLoopbackHTTP: Bool = false, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network, clock: @escaping () -> Date = Date.init) async throws {
        try requireCampaignRelayAdmin()
        let name = appName.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, name.utf8.count <= 800, !name.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else {
            throw NativeDBError.message("メールのアプリ名は制御文字なし・200文字以内で入力してください。")
        }
        let config = try CampaignMailConfiguration(publicURL:publicURL.trimmingCharacters(in:.whitespacesAndNewlines),appName:name,allowLoopbackHTTP:allowLoopbackHTTP)
        let previous = try store.load(interactive:true)
        let key = authKey.isEmpty && previous?.publicURL == config.publicURL.absoluteString ? previous!.authKey : authKey
        let client = try CampaignRelayClient(baseURL:config.publicURL,authKey:key,clientID:CampaignRelayBinding.clientID(db:db),allowLoopbackHTTP:allowLoopbackHTTP,request:request,clock:clock)
        let binding = try await CampaignRelayBinding.connect(db:db,client:client,validate:requireCampaignRelayAdmin)
        try Task.checkCancellation(); try requireCampaignRelayAdmin()
        try store.save(.init(publicURL:binding.publicURL,appName:name,clientID:binding.clientID,instanceID:binding.instanceID,authKey:key))
    }
    func removeCampaignRelaySettings(store: CampaignRelayCredentialStore) throws {
        guard !db.isReadOnly else { throw NativeDBError.message("このデータベースは閲覧専用です。") }
        try requireCampaignRelayAdmin(); try store.remove()
        // Keep the binding/cursor: deleting a credential cannot erase opt-outs
        // or authorize silently switching a database to unrelated event history.
    }
}
