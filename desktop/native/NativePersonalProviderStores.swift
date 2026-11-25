import Foundation
import CryptoKit

/// Current-workspace factories only. No permission is granted by constructing
/// this object: the host checks settings/worker authority before using it.
/// Prerequisite proxies instantiate only the family actually inspected.
final class NativePersonalProviderStores {
    /// Every executing group sharing a mutable credential purpose must drain
    /// before settings change; the Composition owns the actual transition.
    static func settingsAffectedGroups(for group:NativePersonalRuntimeGroup)->Set<NativePersonalRuntimeGroup> {
        switch group {
        case .resendNotifications,.scheduledReports,.campaigns:return [.resendNotifications,.scheduledReports,.campaigns,.plugins]
        case .aiDocumentsAndSearch,.aiContacts,.aiTargets,.aiKeyCleanup:return [.aiDocumentsAndSearch,.aiContacts,.aiTargets,.aiKeyCleanup]
        default:return [group]
        }
    }
    let service:CRMService,usesQAServices:Bool
    var databaseURL:URL{service.db.url}
    var environment:NativeAIEnvironment{usesQAServices ? .init(lookup:{_ in nil}):.init()}
    var pluginDefinitions:[NativePluginDefinition]{[NativeAccountProtection.definition(),NativeAresPlugin.definition(),NativeOdooPlugin.definition,NativeOXOConnector.definition()]}
    private let lock=NSRecursiveLock()
    private var values:[String:Any]=[:]
    init(service:CRMService,usesQAServices:Bool){self.service=service;self.usesQAServices=usesQAServices}
    private func cached<T>(_ name:String,_ create:()throws->T)rethrows->T {
        lock.lock();defer{lock.unlock()};if let value=values[name] as? T{return value}
        let value=try create();values[name]=value;return value
    }
    private func qa(_ family:String)throws->NativePersonalSettingsQASecrets{try cached("qa."+family){try .init(root:databaseURL.deletingLastPathComponent(),family:family)}}
    func mailAccounts()throws->NativeMailSecretStore {try cached("mail") { () throws -> NativeMailSecretStore in usesQAServices ? try qa("mail"):KeychainNativeMailSecrets(databaseURL:databaseURL)}}
    func googleCalendar()throws->GoogleCalendarSecretStore {try cached("google") { () throws -> GoogleCalendarSecretStore in usesQAServices ? try qa("google"):KeychainGoogleCalendarSecrets(databaseURL:databaseURL)}}
    func calendly()throws->CalendlySecretStore {try cached("calendly") { () throws -> CalendlySecretStore in usesQAServices ? try CalendlyQAServices(db:service.db):KeychainCalendlySecrets(databaseURL:databaseURL)}}
    func campaignRelay()throws->CampaignRelayCredentialStore {try cached("campaign") { () throws -> CampaignRelayCredentialStore in usesQAServices ? try CampaignRelayQACredentials(db:service.db):KeychainCampaignRelayCredentials(databaseURL:databaseURL)}}
    func aiSecretStore()throws->NativeAISecretStore {try cached("ai") { () throws -> NativeAISecretStore in usesQAServices ? try qa("ai"):KeychainNativeAISecrets(databaseURL:databaseURL)}}
    func aiKeys()throws->NativeAIKeys{.init(service:service,store:try aiSecretStore(),environment:environment)}
    func mcpSecretStore()throws->NativeMCPSecretStore {try cached("mcp") { () throws -> NativeMCPSecretStore in usesQAServices ? try NativeMCPQAServices(root:databaseURL.deletingLastPathComponent()):KeychainNativeMCPSecrets(databaseURL:databaseURL)}}
    func mcpSettings()throws->NativeMCPSettingsStore{try cached("mcp.settings"){.init(service:service,secretStore:try mcpSecretStore())}}
    func invoiceMail()throws->InvoiceMailCredentialStore {try cached("invoice"){
        if usesQAServices{return try NativePersonalInvoiceQAStore(backing:qa("invoice")) as InvoiceMailCredentialStore}
        guard !service.db.isReadOnly else{throw NativeDBError.message("閲覧専用の保存先では接続設定を変更できません。")}
        return NativeCredentialMigrationInvoiceBridge(service:service,vault:NativeCredentialMigrationKeychainVault(databaseURL:databaseURL),legacy:KeychainInvoiceMailCredentials(databaseURL:databaseURL)) as InvoiceMailCredentialStore
    }}
    func pluginVault()throws->NativePluginCredentialVault{try cached("plugin.vault"){
        .init(db:service.db,backing:usesQAServices ? try NativePluginsQACredentials(root:databaseURL.deletingLastPathComponent()):nil)
    }}
    func pluginSecrets()->NativePluginSecretStore{
        .init(read:{try self.pluginVault().read($0)},write:{try self.pluginVault().write($0,$1)},remove:{try self.pluginVault().remove($0)},validatePublication:{try self.pluginVault().validatePublication($0)})
    }
    /// No attach(), interpreter replacement, timers, scheduler or worker. Local
    /// protection remains owned by the workspace's retained local rule host.
    func settingsOnlyPluginAdmin()throws->NativePluginsAdmin {
        let host=try NativePluginHost(db:service.db,definitions:pluginDefinitions,secretStore:pluginSecrets(),
            sendNotification:{_,_,_ in throw NativePluginError(message:"連携の送信は再開の確認待ちです。")},
            transport:{_,_ in throw NativePluginError(message:"連携の実行は再開の確認待ちです。")},
            capabilities:.init(allowSecretRead:true,allowExternalEffects:false,
                beforeWrite:{_,_,_,_ in throw NativePluginError(message:"設定専用の連携は保護ルールを置き換えられません。")},
                after:{_,_ in throw NativePluginError(message:"設定専用の連携は処理を実行できません。") }))
        return NativePluginsAdmin(service:service,host:host,allowsActions:false)
    }
}

/// Private QA persistence uses the already guarded synthetic-credential backing.
/// Family-bound UUID names avoid aliases across credential purposes. This is not
/// a real-secret implementation, and refuses an unmarked or normal data root.
private final class NativePersonalSettingsQASecrets:NativeMailSecretStore,GoogleCalendarSecretStore,NativeAISecretStore {
    private let backing:NativePluginsQACredentials,family:String,lock=NSLock()
    init(root:URL,family:String)throws{self.backing=try .init(root:root);self.family=family}
    private func reference(_ id:String)->String {
        let hex=SHA256.hash(data:Data((family+"\u{0}"+id).utf8)).map{String(format:"%02x",$0)}.joined()
        let s=Array(hex.prefix(32));let uuid=String(s[0..<8])+"-"+String(s[8..<12])+"-"+String(s[12..<16])+"-"+String(s[16..<20])+"-"+String(s[20..<32])
        return NativePluginCredentialVault.prefix+uuid
    }
    func load(id:String,interactive:Bool)throws->Data?{try backing.load(reference(id))}
    func save(id:String,data:Data)throws{guard data.count<=65_536 else{throw NativeDBError.conflict};try backing.save(reference(id),data:data)}
    func remove(id:String)throws{try backing.remove(reference(id))}
    func replace(id:String,data:Data)throws{lock.lock();defer{lock.unlock()};try remove(id:id);try save(id:id,data:data)}
}
private final class NativePersonalInvoiceQAStore:InvoiceMailCredentialStore {
    let backing:NativePersonalSettingsQASecrets
    init(backing:NativePersonalSettingsQASecrets){self.backing=backing}
    func load(interactive:Bool)throws->InvoiceMailAccount?{
        guard let data=try backing.load(id:"account",interactive:interactive) else{return .init(from:"billing@example.invalid",apiKey:"qa-fake-key")}
        return try JSONDecoder().decode(InvoiceMailAccount?.self,from:data)
    }
    func save(_ account:InvoiceMailAccount)throws{try backing.replace(id:"account",data:JSONEncoder().encode(account))}
    func remove()throws{try backing.replace(id:"account",data:Data("null".utf8))}
}
