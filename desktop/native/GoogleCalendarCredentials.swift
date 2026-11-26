import Foundation
import Security
import LocalAuthentication
import CryptoKit

enum GoogleCalendarScope: String, Codable { case readonly, readwrite
    static let read = "https://www.googleapis.com/auth/calendar.readonly"
    static let write = "https://www.googleapis.com/auth/calendar.events"
    var title: String { self == .readwrite ? "読み取り・書き込み" : "読み取りのみ" }
    var requested: String { self == .readwrite ? Self.read+" "+Self.write : Self.read }
    static func granted(_ scopes: String?) -> Self { scopes?.split(separator:" ").contains(Substring(write)) == true ? .readwrite : .readonly }
}
struct GoogleCalendarClientSettings: Codable, Equatable {
    let clientID: String
    let clientSecret: String
    func validated() throws -> Self {
        guard clientID.utf8.count <= 512, clientID.range(of:#"^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,options:.regularExpression) != nil,
              clientSecret.utf8.count <= 4096, !clientSecret.unicodeScalars.contains(where:{$0.value <= 32 || $0.value == 127}) else { throw NativeDBError.message("デスクトップアプリ用のGoogleクライアントIDとシークレットを確認してください。") }
        return self
    }
}
struct GoogleCalendarGrant: Codable, Equatable {
    let accountEmail: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date?
    let grantedScopes: String?
    var scope: GoogleCalendarScope { .granted(grantedScopes) }
    func validated() throws -> Self {
        let parts = accountEmail.split(separator:"@",omittingEmptySubsequences:false)
        guard accountEmail.utf8.count <= 320, parts.count == 2, parts.allSatisfy({!$0.isEmpty}),
              !accountEmail.isEmpty, !accountEmail.unicodeScalars.contains(where:{$0.value <= 32 || $0.value == 127}),
              [accessToken,refreshToken].allSatisfy({!$0.isEmpty && $0.utf8.count <= 16_384 && $0.unicodeScalars.allSatisfy({(33...126).contains($0.value)})}),
              grantedScopes == nil || grantedScopes!.utf8.count <= 16_384 else { throw NativeDBError.message("Googleの認証結果が不正です。もう一度接続してください。") }
        if let expiresAt { _ = try NativeCalendarEvents.stamp(expiresAt) }
        return self
    }
}
struct GoogleCalendarStoredGrant: Codable {
    var version = 1
    let connectionID: String
    let userID: String
    let client: GoogleCalendarClientSettings
    let grant: GoogleCalendarGrant
}
protocol GoogleCalendarSecretStore {
    func load(id: String, interactive: Bool) throws -> Data?
    func save(id: String, data: Data) throws
    func remove(id: String) throws
}

/// Immutable items allow SQLite to publish a new credential reference atomically.
/// The DB, audits and job payloads contain references, never OAuth tokens.
struct KeychainGoogleCalendarSecrets: GoogleCalendarSecretStore {
    private let database: String
    init(databaseURL: URL) { database = SHA256.hash(data:Data(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined() }
    private func query(_ id: String) throws -> [String:Any] {
        guard UUID(uuidString:id) != nil else { throw NativeDBError.message("カレンダー認証情報の識別子が不正です。") }
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.nextcrm.native.google-calendar.v1",kSecAttrAccount as String:database+"/"+id,kSecAttrSynchronizable as String:false]
    }
    private func failure() -> NativeDBError { .message("カレンダーの認証情報を利用できません。Macのキーチェーンを解除してから、もう一度お試しください。") }
    func load(id: String, interactive: Bool) throws -> Data? {
        var q = try query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 65_536 else { throw failure() }; return data
    }
    func save(id: String, data: Data) throws {
        guard data.count <= 65_536 else { throw NativeDBError.message("カレンダーの認証情報が大きすぎます。") }
        var q = try query(id); q[kSecValueData as String] = data; q[kSecAttrLabel as String] = "NextCRM Googleカレンダー"
        guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw failure() }
    }
    func remove(id: String) throws { let status = SecItemDelete(try query(id) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() } }
}

struct GoogleCalendarClientReference: Codable, Equatable { let id: String; let clientID: String }
struct GoogleCalendarAuthorizationTicket {
    let id: String; let actorID: String; let client: GoogleCalendarClientSettings; let reference: GoogleCalendarClientReference?
    let distributionClient: NativeDistributionConfiguration.GoogleClient?
    let resolveDistributionClient: () throws -> NativeDistributionConfiguration.GoogleClient?
    let expected: NativeRecord?; let requested: GoogleCalendarScope
}
enum GoogleCalendarStorage {
    static let clientKey = "calendar.google.client.v1"
    static let prefix = NativeUserCredentialCleanup.Family.google.prefix
    static func pendingKey(_ userID: String) -> String { "calendar.google.authorization."+userID }
    static func itemID(_ value: SQLValue) -> String? { let s = value.string; guard s.hasPrefix(prefix) else { return nil }; let id = String(s.dropFirst(prefix.count)); return UUID(uuidString:id) == nil ? nil : id }
}

extension CRMService {
    private func freshGoogleCredentialReferenced(_ id:String)throws->Bool {
        if try NativeUserCredentialCleanup.isHeld(db:db,family:.google,credentialID:id){return true}
        if try googleCalendarClientReference()?.id==id{return true}
        let value=GoogleCalendarStorage.prefix+id
        return try db.page("CalendarConnection",fields:["id"],equal:["refreshTokenEncrypted":.text(value)],includeDeleted:true,limit:1).total>0 || db.page("CalendarConnection",fields:["id"],equal:["accessTokenEncrypted":.text(value)],includeDeleted:true,limit:1).total>0
    }
    @discardableResult func cleanupFailedGoogleCredentials(store:GoogleCalendarSecretStore)throws->NativeFreshCredentialPublication.Cleanup {
        try NativeFreshCredentialPublication.cleanup(db:db,purpose:.google,ownerID:identity.id,authorize:authenticated,referenced:freshGoogleCredentialReferenced,remove:{try store.remove(id:$0)})
    }
    func googleCalendarClientReference() throws -> GoogleCalendarClientReference? {
        try authenticated(); guard let raw = try db.metadata(GoogleCalendarStorage.clientKey), !raw.isEmpty else { return nil }
        guard let value = try? JSONDecoder().decode(GoogleCalendarClientReference.self,from:Data(raw.utf8)), UUID(uuidString:value.id) != nil else { throw NativeDBError.message("Googleカレンダーのアプリ設定を保存し直してください。") }; return value
    }
    func saveGoogleCalendarClient(clientID: String, clientSecret: String, store: GoogleCalendarSecretStore) throws {
        try authenticated(); guard identity.role == "admin" else { throw NativeDBError.message("Googleのアプリ設定は管理者が変更してください。") }
        let old = try googleCalendarClientReference(), trimmed = clientID.trimmingCharacters(in:.whitespacesAndNewlines)
        var secret = clientSecret
        if secret.isEmpty, let old, old.clientID == trimmed, let data = try store.load(id:old.id,interactive:true) { secret = try JSONDecoder().decode(GoogleCalendarClientSettings.self,from:data).clientSecret }
        let settings = try GoogleCalendarClientSettings(clientID:trimmed,clientSecret:secret).validated()
        try NativeFreshCredentialPublication.perform(db:db,purpose:.google,ownerID:identity.id,authorize:{try self.authenticated();guard self.identity.role=="admin" else{throw NativeDBError.conflict}},referenced:freshGoogleCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(settings))},remove:{try store.remove(id:$0)}) {id in
            try db.transaction {
            try authenticated(); guard identity.role == "admin", try googleCalendarClientReference() == old else { throw NativeDBError.conflict }
            let reference = GoogleCalendarClientReference(id:id,clientID:settings.clientID)
            try db.setMetadata(GoogleCalendarStorage.clientKey,value:String(decoding:try JSONEncoder().encode(reference),as:UTF8.self))
            }
        }
        if let old { try? NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .google, credentialID: old.id) { try store.remove(id:old.id) } }
    }
    func googleCalendarConnections(offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try authenticated()
        return try db.page("CalendarConnection",fields:["accountEmail","scopeLevel","isActive","lastSyncedAt","lastSyncError","createdAt"],equal:["userId":.text(identity.id),"provider":.text("google")],offset:offset,sort:"createdAt")
    }
    func googleCalendarConnection(_ id: String) throws -> NativeRecord {
        try authenticated(); guard let row = try db.get("CalendarConnection",key:["id":.text(id)]), row["userId"] == .text(identity.id), row["provider"] == .text("google") else { throw NativeDBError.message("カレンダーの接続が見つかりません。") }; return row
    }
    func beginGoogleCalendarAuthorization(expected: NativeRecord?, requested: GoogleCalendarScope, store: GoogleCalendarSecretStore, distributionClient: @escaping () throws -> NativeDistributionConfiguration.GoogleClient? = { try NativeDistributionConfiguration.googleClient() }) throws -> GoogleCalendarAuthorizationTicket {
        try db.transaction {
            try authenticated()
            if let expected { let current = try googleCalendarConnection(expected["id"].string); guard current.revision == expected.revision else { throw NativeDBError.conflict } }
            let reference = try googleCalendarClientReference()
            let client: GoogleCalendarClientSettings, bundled: NativeDistributionConfiguration.GoogleClient?
            if let reference {
                // An explicit developer override remains usable after an app update.
                guard let data = try store.load(id:reference.id,interactive:true), let saved = try? JSONDecoder().decode(GoogleCalendarClientSettings.self,from:data), saved.clientID == reference.clientID else { throw NativeDBError.message("詳細設定に保存したGoogleの認証設定を読み込めません。設定を保存し直してください。") }
                client = saved; bundled = nil
            } else {
                guard let value = try distributionClient() else { throw NativeDBError.message("この配布版ではGoogleログインの設定がまだ用意されていません。アプリの配布元に確認してください。") }
                bundled = value; client = .init(clientID:value.clientID,clientSecret:value.clientSecret)
            }
            _ = try client.validated(); let id = UUID().uuidString.lowercased()
            try db.setMetadata(GoogleCalendarStorage.pendingKey(identity.id),value:id)
            let level: GoogleCalendarScope = expected?["scopeLevel"] == .text("readwrite") ? .readwrite : requested
            return .init(id:id,actorID:identity.id,client:client,reference:reference,distributionClient:bundled,resolveDistributionClient:distributionClient,expected:expected,requested:level)
        }
    }
    func cancelGoogleCalendarAuthorization(_ ticket: GoogleCalendarAuthorizationTicket) throws {
        try db.transaction { if ticket.actorID == identity.id, try db.metadata(GoogleCalendarStorage.pendingKey(identity.id)) == ticket.id { try db.setMetadata(GoogleCalendarStorage.pendingKey(identity.id),value:"") } }
    }
    func completeGoogleCalendarAuthorization(_ ticket: GoogleCalendarAuthorizationTicket, grant: GoogleCalendarGrant, store: GoogleCalendarSecretStore) throws -> NativeRecord {
        _ = try grant.validated(); try authenticated()
        let email = grant.accountEmail.lowercased()
        func validate() throws {
            try authenticated(); try Task.checkCancellation()
            guard ticket.actorID == identity.id, try db.metadata(GoogleCalendarStorage.pendingKey(identity.id)) == ticket.id, try googleCalendarClientReference() == ticket.reference else { throw NativeDBError.message("認証中に接続設定が変わりました。もう一度接続してください。") }
            if ticket.reference == nil {
                guard let bundled = ticket.distributionClient, try ticket.resolveDistributionClient() == bundled,
                      ticket.client.clientID == bundled.clientID, ticket.client.clientSecret.isEmpty else { throw NativeDBError.message("認証中に配布版のGoogle設定が変わりました。もう一度ログインしてください。") }
            }
            if let expected = ticket.expected { let current = try googleCalendarConnection(expected["id"].string); guard current.revision == expected.revision, current["accountEmail"].string.lowercased() == email else { throw NativeDBError.message("選択した接続とGoogleアカウントが一致しないか、接続が変更されています。") } }
        }
        let previous = try db.transaction { () -> NativeRecord? in
            try validate()
            if let expected = ticket.expected { return try googleCalendarConnection(expected["id"].string) }
            return try db.page("CalendarConnection",fields:["refreshTokenEncrypted"],equal:["userId":.text(identity.id),"provider":.text("google"),"accountEmail":.text(email)],limit:1).rows.first
        }
        let connectionID = previous?["id"].string ?? UUID().uuidString.lowercased()
        let bundle = GoogleCalendarStoredGrant(connectionID:connectionID,userID:identity.id,client:ticket.client,grant:grant)
        let saved = try NativeFreshCredentialPublication.perform(db:db,purpose:.google,ownerID:identity.id,authorize:authenticated,referenced:freshGoogleCredentialReferenced,save:{try validate();try store.save(id:$0,data:JSONEncoder().encode(bundle))},remove:{try store.remove(id:$0)}) { itemID in
            try db.transaction {
            try validate()
            let current = try db.get("CalendarConnection",key:["id":.text(connectionID)])
            guard current?.revision == previous?.revision else { throw NativeDBError.conflict }
            let values: [String:SQLValue] = ["refreshTokenEncrypted":.text(GoogleCalendarStorage.prefix+itemID),"accessTokenEncrypted":.null,"tokenExpiresAt":try grant.expiresAt.map{.text(try NativeCalendarEvents.stamp($0))} ?? .null,"isActive":.integer(1),"scopeLevel":.text(grant.scope.rawValue),"syncToken":.null,"lastSyncError":.null]
            let row: NativeRecord
            if let current { row = try db.update(current,changes:values,actor:identity.id,action:"calendar_connected") }
            else { row = try db.insert("CalendarConnection",values:values.merging(["id":.text(connectionID),"userId":.text(identity.id),"provider":.text("google"),"accountEmail":.text(email)]){_,v in v},actor:identity.id) }
            try db.setMetadata(GoogleCalendarStorage.pendingKey(identity.id),value:""); return row
            }
        }
        if let previous, let oldID = GoogleCalendarStorage.itemID(previous["refreshTokenEncrypted"]) { try? NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .google, credentialID: oldID) { try store.remove(id:oldID) } }
        return saved
    }
    func googleCalendarGrant(_ expected: NativeRecord, store: GoogleCalendarSecretStore) throws -> GoogleCalendarStoredGrant {
        let current = try googleCalendarConnection(expected["id"].string)
        guard current.revision == expected.revision, current["isActive"] == .integer(1), let id = GoogleCalendarStorage.itemID(current["refreshTokenEncrypted"]),
              let data = try store.load(id:id,interactive:false), let stored = try? JSONDecoder().decode(GoogleCalendarStoredGrant.self,from:data), stored.version == 1,
              stored.connectionID == current["id"].string, stored.userID == identity.id, stored.grant.accountEmail.lowercased() == current["accountEmail"].string.lowercased(), stored.grant.scope.rawValue == current["scopeLevel"].string else { throw NativeDBError.message("カレンダーの認証情報が一致しません。接続し直してください。") }
        _ = try stored.client.validated(); _ = try stored.grant.validated(); return stored
    }
    func disconnectGoogleCalendar(_ expected: NativeRecord, store: GoogleCalendarSecretStore) throws {
        let inactive = try db.transaction { () -> NativeRecord in
            let current = try googleCalendarConnection(expected["id"].string); guard current.revision == expected.revision else { throw NativeDBError.conflict }
            try db.setMetadata(GoogleCalendarStorage.pendingKey(identity.id),value:"")
            return try db.update(current,changes:["isActive":.integer(0)],actor:identity.id,action:"calendar_disconnecting")
        }
        // A Keychain error leaves an inactive visible row so deletion can be
        // retried; a concurrently reconnected row must never be deleted here.
        if let itemID = GoogleCalendarStorage.itemID(inactive["refreshTokenEncrypted"]) { try NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .google, credentialID: itemID) { try store.remove(id:itemID) } }
        try db.transaction {
            let current = try googleCalendarConnection(inactive["id"].string); guard current.revision == inactive.revision else { throw NativeDBError.conflict }
            try db.remove(current,actor:identity.id)
        }
    }
}
