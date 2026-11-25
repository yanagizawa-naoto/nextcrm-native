import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Not used by tests. No environment lookup or legacy deletion. Migration IDs
/// use the same purpose-specific services/account format as existing consumers.
struct NativeCredentialMigrationKeychainVault:NativeCredentialMigrationVault {
    let namespace:String
    init(databaseURL:URL) {namespace=NativeCredentialMigrationEnvelope.hash(Data(databaseURL.resolvingSymlinksInPath().standardizedFileURL.path.utf8))}
    private func query(_ family:NativeCredentialMigrationFamily,_ id:String)throws->[String:Any] {
        guard UUID(uuidString:id) != nil else{throw NativeCredentialMigrationFailure.format}
        let service:String
        switch family {
        case .ai:service="local.nextcrm.native.ai.v1"
        case .email:service="local.nextcrm.native.email.v1"
        case .plugin:service="local.nextcrm.native.plugins.secrets.v1"
        case .google:service="local.nextcrm.native.google-calendar.v1"
        case .invoice:service="local.nextcrm.native.invoice-mail.immutable.v1"
        case .calendly:service="local.nextcrm.native.calendly.v1"
        }
        let context=LAContext();context.interactionNotAllowed=true
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:namespace+"/"+(family == .plugin ? family.prefix:"")+id,kSecAttrSynchronizable as String:false,kSecUseAuthenticationContext as String:context]
    }
    private func marker(_ lease:NativeCredentialMigrationLease)throws->Data {
        guard lease.namespace==namespace,UUID(uuidString:lease.creationToken) != nil else{throw NativeCredentialMigrationFailure.authority}
        return Data(("nextcrm-migration-v1/"+lease.creationToken+"/"+lease.payloadSHA256).utf8)
    }
    func insert(_ lease:NativeCredentialMigrationLease,data:Data)throws {
        guard NativeCredentialMigrationEnvelope.hash(data)==lease.payloadSHA256 else{throw NativeCredentialMigrationFailure.integrity}
        var q=try query(lease.family,lease.id);q[kSecAttrGeneric as String]=try marker(lease);q[kSecValueData as String]=data;q[kSecAttrLabel as String]="NextCRM 移行済み認証情報";q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary,nil)==errSecSuccess else{throw NativeCredentialMigrationFailure.unavailable}
    }
    func load(_ family:NativeCredentialMigrationFamily,id:String)throws->Data? {
        var q=try query(family,id);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound{return nil}
        guard status==errSecSuccess,let data=result as? Data else{throw NativeCredentialMigrationFailure.unavailable};return data
    }
    func removeCreated(_ lease:NativeCredentialMigrationLease)throws {
        var q=try query(lease.family,lease.id);q[kSecAttrGeneric as String]=try marker(lease)
        var read=q;read[kSecReturnData as String]=true;read[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let status=SecItemCopyMatching(read as CFDictionary,&result)
        if status==errSecItemNotFound{return}
        guard status==errSecSuccess,let data=result as? Data,NativeCredentialMigrationEnvelope.hash(data)==lease.payloadSHA256 else{throw NativeCredentialMigrationFailure.cleanup}
        let removed=SecItemDelete(q as CFDictionary);guard removed==errSecSuccess||removed==errSecItemNotFound else{throw NativeCredentialMigrationFailure.cleanup}
    }
}
