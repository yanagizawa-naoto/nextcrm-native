import Foundation
import Security
import LocalAuthentication
import CryptoKit

protocol CalendlySecretStore {
    func load(id: String,interactive: Bool) throws -> Data?
    func save(id: String,data: Data) throws
    func remove(id: String) throws
}
struct KeychainCalendlySecrets: CalendlySecretStore {
    private let database: String
    init(databaseURL: URL) { database = SHA256.hash(data:Data(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined() }
    private func query(_ id: String) throws -> [String:Any] {
        guard UUID(uuidString:id) != nil else { throw NativeDBError.conflict }
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.nextcrm.native.calendly.v1",kSecAttrAccount as String:database+"/"+id,kSecAttrSynchronizable as String:false]
    }
    private func failure() -> NativeDBError { .message("Calendlyの認証情報を利用できません。Macのキーチェーンを解除してから、もう一度お試しください。") }
    func load(id: String,interactive: Bool) throws -> Data? {
        var q = try query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else { throw failure() }; return data
    }
    func save(id: String,data: Data) throws {
        guard data.count <= 65_536 else { throw failure() }; var q = try query(id); q[kSecValueData as String] = data; q[kSecAttrLabel as String] = "NextCRM Calendly予約連携"
        guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw failure() }
    }
    func remove(id: String) throws { let status = SecItemDelete(try query(id) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() } }
}

struct CalendlyCredentials: Codable {
    var version = 1
    let publicURL: String, clientID: String, instanceID: String, authKey: String, apiToken: String, signingKey: String
    func relay(db: NativeDatabase,allowLoopbackHTTP: Bool = false,request: CalendlyRelayClient.Request? = nil) throws -> CalendlyRelayClient {
        guard version == 1, let binding = try CalendlyRelayBinding.load(db:db), binding.publicURL == publicURL, binding.clientID == clientID, binding.instanceID == instanceID,
              !signingKey.isEmpty, signingKey.utf8.count <= 16_384, !signingKey.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), let url = URL(string:publicURL) else { throw NativeDBError.message("Calendlyの認証情報と受信窓口が一致しません。設定を保存し直してください。") }
        _ = try CalendlyAPIClient(token:apiToken)
        return try CalendlyRelayClient(baseURL:url,authKey:authKey,clientID:clientID,expectedInstanceID:instanceID,allowLoopbackHTTP:allowLoopbackHTTP,request:request)
    }
    static func signingKey() throws -> String {
        var bytes = [UInt8](repeating:0,count:32); guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw NativeDBError.message("予約通知の署名キーを生成できません。") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    }
}


/// Committed deletion authorization only; no secret bytes. Keeping this intent
/// across a final SQLite failure makes a missing-key retry safe and blocks reuse.
private enum CalendlyCredentialRemoval {
    static let key="calendly.credential.cleanup.removal.v1"
    struct Intent:Codable,Equatable {let version:Int,namespace:String,credentialID:String,revision:String}
    static func load(_ db:NativeDatabase)throws->Intent? {
        guard let raw=try db.metadata(key),!raw.isEmpty else{return nil}
        guard raw.utf8.count<=2048,let value=try? JSONDecoder().decode(Intent.self,from:Data(raw.utf8)),value.version==1,UUID(uuidString:value.credentialID) != nil,UUID(uuidString:value.revision) != nil,value.namespace==NativeFreshCredentialPublication.namespace(db) else{throw NativeDBError.message("Calendly認証情報の削除待ち状態を確認してください。")};return value
    }
    static func requireAvailable(_ db:NativeDatabase)throws {guard try load(db)==nil else{throw NativeDBError.message("Calendlyの認証情報を削除中です。設定画面で削除を再試行してください。")}}
    static func shared(_ db:NativeDatabase,_ id:String)throws->Bool {
        // Migrated paired server settings retain their immutable key for later
        // backup/namespace recovery. Detaching this control is not their erasure.
        try db.page("crm_SystemSettings",fields:["key"],equal:["value":.text("native-calendly-keychain:"+id)],includeDeleted:true,limit:1).total>0
    }
}

extension CRMService {
    private func freshCalendlyCredentialReferenced(_ id:String)throws->Bool {
        let state=try CalendlyControlState.load(db)
        return state.credentialID==id || state.registration?.credentialID==id || state.operation?.credentialID==id
    }
    @discardableResult func cleanupFailedCalendlyCredentials(store:CalendlySecretStore)throws->NativeFreshCredentialPublication.Cleanup {
        try NativeFreshCredentialPublication.cleanup(db:db,purpose:.calendly,ownerID:identity.id,authorize:requireCalendlyAdmin,referenced:freshCalendlyCredentialReferenced,remove:{try store.remove(id:$0)})
    }
    func calendlyControl() throws -> CalendlyControlState { try requireCalendlyAdmin(); return try CalendlyControlState.load(db) }
    func calendlyCredentials(_ state: CalendlyControlState,store: CalendlySecretStore,interactive: Bool = false) throws -> CalendlyCredentials {
        try requireCalendlyAdmin();try CalendlyCredentialRemoval.requireAvailable(db)
        guard let id = state.credentialID, let data = try store.load(id:id,interactive:interactive), let value = try? JSONDecoder().decode(CalendlyCredentials.self,from:data), value.version == 1 else { throw NativeDBError.message("Calendlyの接続設定を保存してください。") }; return value
    }
    func saveCalendlySettings(publicURL: String,authKey: String,apiToken: String,signingKey: String,store: CalendlySecretStore,allowLoopbackHTTP: Bool = false,request: @escaping CalendlyRelayClient.Request = CalendlyRelayClient.network) async throws {
        try NativeFreshCredentialPublication.requireBoundary(db);try CalendlyCredentialRemoval.requireAvailable(db)
        let before = try calendlyControl()
        guard before.operation == nil else { throw NativeDBError.message("処理中の通知登録を完了してから、接続設定を変更してください。") }
        let needsPrevious = authKey.isEmpty || apiToken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || signingKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        let old = try before.credentialID == nil || !needsPrevious ? nil : calendlyCredentials(before,store:store,interactive:true)
        let token = apiToken.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? old?.apiToken ?? "" : apiToken.trimmingCharacters(in:.whitespacesAndNewlines)
        _ = try CalendlyAPIClient(token:token)
        let signing = signingKey.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? try old?.signingKey ?? CalendlyCredentials.signingKey() : signingKey.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !signing.isEmpty, signing.utf8.count <= 16_384, !signing.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), let url = URL(string:publicURL.trimmingCharacters(in:.whitespacesAndNewlines)) else { throw NativeDBError.message("受信URLと署名キーを確認してください。") }
        let key = authKey.isEmpty ? old?.authKey ?? "" : authKey
        let client = try CalendlyRelayClient(baseURL:url,authKey:key,clientID:CalendlyRelayBinding.clientID(db:db),allowLoopbackHTTP:allowLoopbackHTTP,request:request)
        func validate() throws { try Task.checkCancellation(); guard try calendlyControl() == before else { throw NativeDBError.conflict } }
        let binding = try await CalendlyRelayBinding.connect(service:self,client:client,validate:validate); try validate()
        let value = CalendlyCredentials(publicURL:binding.publicURL,clientID:binding.clientID,instanceID:binding.instanceID,authKey:key,apiToken:token,signingKey:signing)
        try NativeFreshCredentialPublication.perform(db:db,purpose:.calendly,ownerID:identity.id,authorize:requireCalendlyAdmin,referenced:freshCalendlyCredentialReferenced,save:{try validate();try store.save(id:$0,data:JSONEncoder().encode(value))},remove:{try store.remove(id:$0)}){id in
            try db.transaction{try validate();var next=before;next.credentialID=id;try next.save(db,expected:before)}
        }
        if let oldID = before.credentialID { try? store.remove(id:oldID) }
    }
    func removeCalendlySettings(store: CalendlySecretStore) throws {
        try NativeFreshCredentialPublication.requireBoundary(db);try requireCalendlyAdmin();try Task.checkCancellation()
        let intent=try db.transaction { () -> CalendlyCredentialRemoval.Intent? in
            let state=try calendlyControl();guard state.operation==nil,state.registration==nil else{throw NativeDBError.message("先にCalendlyの通知登録を解除してください。")}
            if let pending=try CalendlyCredentialRemoval.load(db){guard state.credentialID==pending.credentialID,state.revision==pending.revision else{throw NativeDBError.conflict};return pending}
            guard let id=state.credentialID else{return nil}
            let next=CalendlyCredentialRemoval.Intent(version:1,namespace:NativeFreshCredentialPublication.namespace(db),credentialID:id,revision:state.revision)
            try db.setMetadata(CalendlyCredentialRemoval.key,value:String(decoding:JSONEncoder().encode(next),as:UTF8.self));try Task.checkCancellation();return next
        }
        guard let intent else{return}
        // This second fence runs only after the deletion intent committed. If
        // removal or final COMMIT fails, intent+oldID remain for explicit retry;
        // all readers and new publications reject the pending removal state.
        try db.transaction {
            try requireCalendlyAdmin();try Task.checkCancellation()
            let state=try calendlyControl();guard try CalendlyCredentialRemoval.load(db)==intent,state.credentialID==intent.credentialID,state.revision==intent.revision,state.operation==nil,state.registration==nil else{throw NativeDBError.conflict}
            if try !CalendlyCredentialRemoval.shared(db,intent.credentialID){try store.remove(id:intent.credentialID)}
            var next=state;next.credentialID=nil;try next.save(db,expected:state)
            try db.setMetadata(CalendlyCredentialRemoval.key,value:"")
        }
    }
    /// Token renewal preserves the exact signing key/callback intent, including
    /// an unknown POST, while fencing any worker still using the previous token.
    func replaceCalendlyAPIToken(_ token: String,store: CalendlySecretStore) throws {
        try NativeFreshCredentialPublication.requireBoundary(db);try CalendlyCredentialRemoval.requireAvailable(db)
        let before = try calendlyControl(), old = try calendlyCredentials(before,store:store,interactive:true)
        let token = token.trimmingCharacters(in:.whitespacesAndNewlines); _ = try CalendlyAPIClient(token:token)
        let value = CalendlyCredentials(publicURL:old.publicURL,clientID:old.clientID,instanceID:old.instanceID,authKey:old.authKey,apiToken:token,signingKey:old.signingKey)
        try NativeFreshCredentialPublication.perform(db:db,purpose:.calendly,ownerID:identity.id,authorize:requireCalendlyAdmin,referenced:freshCalendlyCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(value))},remove:{try store.remove(id:$0)}){id in
            try db.transaction {
            guard try calendlyControl() == before else { throw NativeDBError.conflict }
            var next = before; next.credentialID = id; next.operation?.credentialID = id
            if let registration = before.registration, registration.credentialID == before.credentialID { next.registration = .init(uri:registration.uri,organization:registration.organization,callbackURL:registration.callbackURL,credentialID:id,actorID:registration.actorID) }
            try next.save(db,expected:before)
            }
        }
        if let id = before.credentialID { try? store.remove(id:id) }
    }
}
