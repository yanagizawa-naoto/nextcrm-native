import Foundation
import Security
import LocalAuthentication
import CryptoKit

protocol NativePluginCredentialBacking {
    func load(_ reference:String) throws -> Data?
    func save(_ reference:String,data:Data) throws
    func remove(_ reference:String) throws
}

/// Each database has a separate Keychain namespace. References are immutable;
/// importing a server ciphertext never treats it as a native Keychain name.
struct KeychainNativePluginCredentials:NativePluginCredentialBacking {
    private let namespace:String
    init(databaseURL:URL) {
        namespace=SHA256.hash(data:Data(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func query(_ reference:String) throws -> [String:Any] {
        guard NativePluginCredentialVault.valid(reference) else { throw NativePluginError(message:"プラグインの秘密情報を確認できません") }
        let context=LAContext();context.interactionNotAllowed=true
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.nextcrm.native.plugins.secrets.v1",kSecAttrAccount as String:namespace+"/"+reference,kSecAttrSynchronizable as String:false,kSecUseAuthenticationContext as String:context]
    }
    func load(_ reference:String) throws -> Data? {
        var query=try query(reference);query[kSecReturnData as String]=true;query[kSecMatchLimit as String]=kSecMatchLimitOne
        var item:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&item)
        if status==errSecItemNotFound { return nil }
        guard status==errSecSuccess,let data=item as? Data else { throw NativePluginError(message:"プラグインの秘密情報を読み込めません") };return data
    }
    func save(_ reference:String,data:Data) throws {
        var query=try query(reference);query[kSecValueData as String]=data
        query[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String]="NextCRM プラグイン"
        guard SecItemAdd(query as CFDictionary,nil)==errSecSuccess else { throw NativePluginError(message:"プラグインの秘密情報を保存できません") }
    }
    func remove(_ reference:String) throws {
        let status=SecItemDelete(try query(reference) as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else { throw NativePluginError(message:"以前のプラグイン秘密情報を削除できません") }
    }
}

final class NativePluginCredentialVault {
    static let prefix="native-plugin-keychain:",cleanupKey="plugins.secrets.cleanup.v1"
    let db:NativeDatabase,backing:NativePluginCredentialBacking,clock:()->Date
    init(db:NativeDatabase,backing:NativePluginCredentialBacking?=nil,clock:@escaping ()->Date=Date.init) {
        self.db=db;self.backing=backing ?? KeychainNativePluginCredentials(databaseURL:db.url);self.clock=clock
    }
    static func valid(_ reference:String)->Bool { reference.hasPrefix(prefix) && UUID(uuidString:String(reference.dropFirst(prefix.count))) != nil }
    private func pending() throws -> [String:Double] {
        guard let raw=try db.metadata(Self.cleanupKey) else { return [:] }
        guard raw.utf8.count<=128*1024,let values=try? JSONDecoder().decode([String:Double].self,from:Data(raw.utf8)),values.count<=1024,values.allSatisfy({Self.valid($0.key) && $0.value.isFinite}) else { throw NativePluginError(message:"プラグイン秘密情報の整理状態を確認できません") };return values
    }
    private func put(_ pending:[String:Double]) throws { try db.setMetadata(Self.cleanupKey,value:String(decoding:JSONEncoder().encode(pending),as:UTF8.self)) }
    private func referenced(_ reference:String) throws -> Bool {
        try db.mcpPage("InstalledPlugin",fields:["id"],filter:.equal("secrets",.text(reference)),limit:1,offset:0,order:[],includeDeleted:true,allowEmptyOrder:true).total>0
    }
    func read(_ reference:String) throws -> NativePluginRecord {
        guard Self.valid(reference),let data=try backing.load(reference),let text=String(data:data,encoding:.utf8) else { throw NativePluginError(message:"プラグインの秘密情報を確認できません。設定画面で再入力してください") }
        return try NativePluginJSON.record(text)
    }
    func write(_ pluginId:String,_ values:NativePluginRecord) throws -> String {
        let reference=Self.prefix+UUID().uuidString.lowercased(),data=try NativePluginJSON.data(values)
        try Task.checkCancellation()
        try db.transaction {
            var values=try pending();guard values.count<1024 else { throw NativePluginError(message:"以前の秘密情報を整理できません。キーチェーンを確認してください") }
            values[reference]=clock().addingTimeInterval(600).timeIntervalSince1970;try put(values)
        }
        do {
            try backing.save(reference,data:data);try Task.checkCancellation()
            try db.transaction { try validatePublication(reference) }
            return reference
        } catch { try? remove(reference);throw error }
    }
    /// Called inside the same DB transaction that publishes InstalledPlugin.
    /// Cleanup may have run while Keychain was waiting; never publish a missing
    /// or expired reservation. Rollback restores the reservation for cleanup.
    func validatePublication(_ reference:String) throws {
        guard Self.valid(reference),let until=try pending()[reference],until>clock().timeIntervalSince1970 else { throw NativeDBError.conflict }
        try Task.checkCancellation()
    }
    func remove(_ reference:String) throws {
        guard Self.valid(reference) else { return } // Legacy encrypted values are not ours.
        try db.transaction {
            guard try !referenced(reference) else { return }
            var values=try pending();guard values[reference] != nil || values.count<1024 else { throw NativePluginError(message:"以前の秘密情報を整理できません") }
            values[reference]=clock().timeIntervalSince1970;try put(values)
            do { try backing.remove(reference) } catch { return }
            values.removeValue(forKey:reference);try put(values)
        }
    }
    @discardableResult func cleanup() throws -> (removed:Int,pending:Int) {
        guard !db.isReadOnly else { throw NativeDBError.message("このデータベースは閲覧専用です。") }
        let keys=try db.transaction { try pending().filter { $0.value<=clock().timeIntervalSince1970 }.keys.sorted() }
        var removed=0
        for key in keys {
            try db.transaction {
                var values=try pending();guard let until=values[key],until<=clock().timeIntervalSince1970 else { return }
                if try referenced(key) { values.removeValue(forKey:key);try put(values);return }
                do { try backing.remove(key) } catch { return }
                values.removeValue(forKey:key);try put(values);removed+=1
            }
        }
        return (removed,try db.transaction { try pending().count })
    }
    // Publication validation is connected by NativePluginSecretStore's adapter
    // at the Host's transaction boundary, never by UI callbacks.
    var store:NativePluginSecretStore { .init(read:read,write:write,remove:remove,validatePublication:validatePublication) }
}
