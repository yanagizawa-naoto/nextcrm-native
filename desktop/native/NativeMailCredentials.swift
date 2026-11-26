import Foundation
import Security
import LocalAuthentication
import CryptoKit

protocol NativeMailSecretStore {
    func load(id: String,interactive: Bool) throws -> Data?
    func save(id: String,data: Data) throws
    func remove(id: String) throws
}
struct KeychainNativeMailSecrets: NativeMailSecretStore {
    private let database: String
    init(databaseURL: URL) { database = SHA256.hash(data:Data(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined() }
    private func query(_ id: String) throws -> [String:Any] {
        guard UUID(uuidString:id) != nil else { throw NativeDBError.conflict }
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.nextcrm.native.email.v1",kSecAttrAccount as String:database+"/"+id,kSecAttrSynchronizable as String:false]
    }
    private func failure() -> NativeDBError { .message("メールの認証情報を利用できません。Macのキーチェーンを解除してから、もう一度お試しください。") }
    func load(id: String,interactive: Bool) throws -> Data? {
        var q = try query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { let context = LAContext(); context.interactionNotAllowed = true; q[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess, let bytes = result as? Data, bytes.count <= 65_536 else { throw failure() }; return bytes
    }
    func save(id: String,data: Data) throws {
        guard data.count <= 65_536 else { throw failure() }; var q = try query(id); q[kSecValueData as String] = data; q[kSecAttrLabel as String] = "NextCRM 通常メール"
        guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { throw failure() }
    }
    func remove(id: String) throws { let status = SecItemDelete(try query(id) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() } }
}
struct NativeMailCredential: Codable {
    var version = 1
    let password: String
    var google: GoogleMailStoredGrant? = nil
    var oauthBearer: String? { google?.grant.accessToken }
    func validate() throws {
        if let google { guard version == 2, password.isEmpty else { throw GoogleMailFailure.invalid }; try google.validate(); return }
        guard version == 1, !password.isEmpty, password.utf8.count <= 16_384,
              !password.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeMailFailure.invalid("メールのパスワードを確認してください。") }
    }
}
struct NativeMailAccountSettings: Codable, Equatable {
    var label: String
    var username: String
    var imap: NativeMailEndpoint
    var smtp: NativeMailEndpoint
    var sentFolder = "Sent"
    func validate() throws {
        guard !label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, label.utf8.count <= 256,
              !username.isEmpty, username.utf8.count <= 1024,
              !username.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}),
              imap.allowSelfSigned == smtp.allowSelfSigned, !sentFolder.isEmpty else { throw NativeMailFailure.invalid("メールの表示名・利用者名・接続設定を確認してください。") }
        try imap.validate(smtp:false); try smtp.validate(smtp:true); _ = try NativeMailUTF7.encode(sentFolder)
    }
}

extension CRMService {
    static let mailAccountFields = ["label","username","imapHost","imapPort","imapSsl","smtpHost","smtpPort","smtpSsl","allowSelfSignedTls","sentFolderName","isActive","lastSyncedAt","createdAt","userId"]
    func mailAccounts(offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try authenticated()
        return try db.page("EmailAccount",fields:Self.mailAccountFields,equal:["userId":.text(identity.id)],offset:offset,sort:"createdAt")
    }
    func mailAccount(_ id: String,active: Bool = false) throws -> NativeRecord {
        try authenticated()
        guard let value = try db.get("EmailAccount",key:["id":.text(id)]), value["userId"] == .text(identity.id), !active || value["isActive"] == .integer(1) else { throw NativeDBError.message("メールアカウントを利用できません。") }; return value
    }
    func mailSettings(_ account: NativeRecord) throws -> NativeMailAccountSettings {
        let row = try mailAccount(account["id"].string)
        guard row.revision == account.revision else { throw NativeDBError.conflict }
        let modes: [String:Int]
        if let raw = try db.metadata("mail.tls."+row["id"].string) { guard let data = raw.data(using:.utf8), let parsed = try? JSONDecoder().decode([String:Int].self,from:data) else { throw NativeDBError.conflict }; modes = parsed } else { modes = [:] }
        // The original IMAP false flag is plaintext. Nodemailer's SMTP false
        // flag instead upgrades when STARTTLS is advertised. Explicit native
        // modes continue to take precedence over either legacy Boolean.
        guard let imapMode = NativeMailTLS(rawValue:modes["imap"] ?? (row["imapSsl"] == .integer(1) ? 2 : 0)), let smtpMode = NativeMailTLS(rawValue:modes["smtp"] ?? (row["smtpSsl"] == .integer(1) ? 2 : 3)) else { throw NativeDBError.conflict }
        let selfSigned = row["allowSelfSignedTls"] == .integer(1)
        let value = NativeMailAccountSettings(label:row["label"].string,username:row["username"].string,imap:.init(host:row["imapHost"].string,port:Int(row["imapPort"].string) ?? 0,tls:imapMode,allowSelfSigned:selfSigned),smtp:.init(host:row["smtpHost"].string,port:Int(row["smtpPort"].string) ?? 0,tls:smtpMode,allowSelfSigned:selfSigned),sentFolder:row["sentFolderName"].string)
        try value.validate(); return value
    }
    static func mailCredentialID(_ account: NativeRecord) throws -> String {
        let prefix = NativeUserCredentialCleanup.Family.email.prefix, reference = account["passwordEncrypted"].string
        guard reference.hasPrefix(prefix), UUID(uuidString:String(reference.dropFirst(prefix.count))) != nil else { throw NativeDBError.message("このメールアカウントの認証情報を保存し直してください。") }
        return String(reference.dropFirst(prefix.count))
    }
    func mailCredential(_ expected: NativeRecord,store: NativeMailSecretStore,interactive: Bool = false) throws -> NativeMailCredential {
        let current = try mailAccount(expected["id"].string)
        guard current.revision == expected.revision else { throw NativeDBError.conflict }
        guard let data = try store.load(id:Self.mailCredentialID(current),interactive:interactive), let value = try? JSONDecoder().decode(NativeMailCredential.self,from:data) else { throw NativeDBError.message("メールの認証情報を保存し直してください。") }
        try value.validate()
        if let google = value.google {
            guard google.accountID == current["id"].string, google.userID == identity.id,
                  google.namespace == NativeFreshCredentialPublication.namespace(db),
                  try db.metadata("mail.auth."+current["id"].string) == "google" else { throw GoogleMailFailure.invalid }
            try GoogleMailStoredGrant.validate(settings:mailSettings(current),email:google.grant.email)
        } else if try db.metadata("mail.auth."+current["id"].string) == "google" { throw GoogleMailFailure.invalid }
        return value
    }
    func freshMailCredentialReferenced(_ id:String)throws->Bool {
        if try NativeUserCredentialCleanup.isHeld(db:db,family:.email,credentialID:id){return true}
        return try db.page("EmailAccount",fields:["id"],equal:["passwordEncrypted":.text(NativeUserCredentialCleanup.Family.email.prefix+id)],includeDeleted:true,limit:1).total>0
    }
    @discardableResult func cleanupFailedMailCredentials(store:NativeMailSecretStore)throws->NativeFreshCredentialPublication.Cleanup {
        try NativeFreshCredentialPublication.cleanup(db:db,purpose:.email,ownerID:identity.id,authorize:authenticated,referenced:freshMailCredentialReferenced,remove:{try store.remove(id:$0)})
    }
    @discardableResult func createMailAccount(_ settings: NativeMailAccountSettings,password: String,store: NativeMailSecretStore) throws -> NativeRecord {
        try authenticated(); try settings.validate(); let value = NativeMailCredential(password:password); try value.validate()
        let id = UUID().uuidString.lowercased()
        return try NativeFreshCredentialPublication.perform(db:db,purpose:.email,ownerID:identity.id,authorize:authenticated,referenced:freshMailCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(value))},remove:{try store.remove(id:$0)}) { credentialID in
            try db.transaction {
            try authenticated()
            let row = try db.insert("EmailAccount",values:["id":.text(id),"userId":.text(identity.id),"label":.text(settings.label),"username":.text(settings.username),"imapHost":.text(settings.imap.host),"imapPort":.integer(Int64(settings.imap.port)),"imapSsl":.integer(settings.imap.tls == .implicitTLS ? 1 : 0),"smtpHost":.text(settings.smtp.host),"smtpPort":.integer(Int64(settings.smtp.port)),"smtpSsl":.integer(settings.smtp.tls == .implicitTLS ? 1 : 0),"allowSelfSignedTls":.integer(settings.imap.allowSelfSigned ? 1 : 0),"passwordEncrypted":.text(NativeUserCredentialCleanup.Family.email.prefix+credentialID),"sentFolderName":.text(settings.sentFolder)],actor:identity.id)
            try db.setMetadata("mail.tls."+id,value:String(decoding:JSONEncoder().encode(["imap":settings.imap.tls.rawValue,"smtp":settings.smtp.tls.rawValue]),as:UTF8.self))
            return row
            }
        }
    }
    @discardableResult func setMailAccountActive(_ expected: NativeRecord,active: Bool) throws -> NativeRecord {
        try db.transaction { let current = try mailAccount(expected["id"].string); guard current.revision == expected.revision else { throw NativeDBError.conflict }; return try db.update(current,changes:["isActive":.integer(active ? 1 : 0)],actor:identity.id) }
    }
    /// A settings edit and optional password replacement publish together.
    /// Existing workers keep immutable snapshots and fail their revision fence.
    @discardableResult func updateMailAccount(_ expected: NativeRecord,settings: NativeMailAccountSettings,password: String?,store: NativeMailSecretStore) throws -> NativeRecord {
        let before = try mailAccount(expected["id"].string)
        guard before.revision == expected.revision else { throw NativeDBError.conflict }
        try settings.validate()
        if try db.metadata("mail.auth."+before["id"].string) == "google" {
            try GoogleMailStoredGrant.validate(settings:settings,email:before["username"].string)
            guard password == nil else { throw NativeDBError.message("Googleの認証は「Googleを接続し直す」から更新してください。") }
        }
        let credential = try password.map { value -> NativeMailCredential in let credential=NativeMailCredential(password:value);try credential.validate();return credential }
        func publish(_ credentialID:String?)throws->NativeRecord {
            try db.transaction {
                let current=try mailAccount(before["id"].string);guard current.revision==before.revision else{throw NativeDBError.conflict}
                var fields:[String:SQLValue] = ["label":.text(settings.label),"username":.text(settings.username),"imapHost":.text(settings.imap.host),"imapPort":.integer(Int64(settings.imap.port)),"imapSsl":.integer(settings.imap.tls == .implicitTLS ? 1 : 0),"smtpHost":.text(settings.smtp.host),"smtpPort":.integer(Int64(settings.smtp.port)),"smtpSsl":.integer(settings.smtp.tls == .implicitTLS ? 1 : 0),"allowSelfSignedTls":.integer(settings.imap.allowSelfSigned ? 1 : 0),"sentFolderName":.text(settings.sentFolder)]
                if let credentialID{fields["passwordEncrypted"] = .text(NativeUserCredentialCleanup.Family.email.prefix+credentialID)}
                let row=try db.update(current,changes:fields,actor:identity.id)
                try db.setMetadata("mail.tls."+row["id"].string,value:String(decoding:JSONEncoder().encode(["imap":settings.imap.tls.rawValue,"smtp":settings.smtp.tls.rawValue]),as:UTF8.self));return row
            }
        }
        let changed:NativeRecord
        if let credential {
            changed=try NativeFreshCredentialPublication.perform(db:db,purpose:.email,ownerID:identity.id,authorize:authenticated,referenced:freshMailCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(credential))},remove:{try store.remove(id:$0)},publish:{try publish($0)})
        }else{changed=try publish(nil)}
        if credential != nil,let old=try? Self.mailCredentialID(before){do{try NativeUserCredentialCleanup.removeUnlessHeld(db:db,family:.email,credentialID:old){try store.remove(id:old)}}catch{try? db.setMetadata("mail.orphanCredential."+old,value:"pending")}}
        return changed
    }
    @discardableResult func replaceMailPassword(_ expected: NativeRecord,password: String,store: NativeMailSecretStore) throws -> NativeRecord {
        let before = try mailAccount(expected["id"].string); guard before.revision == expected.revision else { throw NativeDBError.conflict }
        guard try db.metadata("mail.auth."+before["id"].string) != "google" else { throw NativeDBError.message("Googleの認証は「Googleを接続し直す」から更新してください。") }
        let value=NativeMailCredential(password:password);try value.validate()
        let changed=try NativeFreshCredentialPublication.perform(db:db,purpose:.email,ownerID:identity.id,authorize:authenticated,referenced:freshMailCredentialReferenced,save:{try store.save(id:$0,data:JSONEncoder().encode(value))},remove:{try store.remove(id:$0)}){id in
            try db.transaction{let current=try mailAccount(before["id"].string);guard current.revision==before.revision else{throw NativeDBError.conflict};return try db.update(current,changes:["passwordEncrypted":.text(NativeUserCredentialCleanup.Family.email.prefix+id)],actor:identity.id)}
        }
        if let old = try? Self.mailCredentialID(before) { do { try NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .email, credentialID: old) { try store.remove(id:old) } } catch { try? db.setMetadata("mail.orphanCredential."+old,value:"pending") } }
        return changed
    }
    /// Deletion commits before Keychain cleanup, so a DB failure cannot remove
    /// the only usable secret of an account that still exists.
    func deleteMailAccount(_ expected: NativeRecord,store: NativeMailSecretStore) throws {
        let old = try db.transaction { () -> String? in
            let current = try mailAccount(expected["id"].string); guard current.revision == expected.revision else { throw NativeDBError.conflict }
            let id = try? Self.mailCredentialID(current); try db.removeMailAccount(current,actor:identity.id); return id
        }
        if let old { do { try NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .email, credentialID: old) { try store.remove(id:old) } } catch { try? db.setMetadata("mail.orphanCredential."+old,value:"pending") } }
    }
}
