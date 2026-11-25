import Foundation

extension NativePersonalProviderStores {
    func prerequisiteStores() throws -> NativePersonalRuntimePrerequisites.Stores {
        .init(databaseURL:databaseURL,
            mail:PersonalDeferredSecrets(mailAccounts),invoice:PersonalDeferredInvoice(invoiceMail),
            google:PersonalDeferredSecrets(googleCalendar),calendly:PersonalDeferredSecrets(calendly),
            campaign:PersonalDeferredCampaign(campaignRelay),ai:PersonalDeferredSecrets(aiSecretStore),
            mcp:PersonalDeferredMCP(mcpSecretStore),plugins:pluginSecrets(),pluginDefinitions:pluginDefinitions,environment:environment)
    }
}
private struct PersonalDeferredSecrets:NativeMailSecretStore,GoogleCalendarSecretStore,CalendlySecretStore,NativeAISecretStore {
    let read:(String,Bool)throws->Data?,write:(String,Data)throws->Void,erase:(String)throws->Void
    init(_ factory:@escaping()throws->NativeMailSecretStore){read={try factory().load(id:$0,interactive:$1)};write={try factory().save(id:$0,data:$1)};erase={try factory().remove(id:$0)}}
    init(_ factory:@escaping()throws->GoogleCalendarSecretStore){read={try factory().load(id:$0,interactive:$1)};write={try factory().save(id:$0,data:$1)};erase={try factory().remove(id:$0)}}
    init(_ factory:@escaping()throws->CalendlySecretStore){read={try factory().load(id:$0,interactive:$1)};write={try factory().save(id:$0,data:$1)};erase={try factory().remove(id:$0)}}
    init(_ factory:@escaping()throws->NativeAISecretStore){read={try factory().load(id:$0,interactive:$1)};write={try factory().save(id:$0,data:$1)};erase={try factory().remove(id:$0)}}
    func load(id:String,interactive:Bool)throws->Data?{try read(id,interactive)}
    func save(id:String,data:Data)throws{try write(id,data)}
    func remove(id:String)throws{try erase(id)}
}
private struct PersonalDeferredInvoice:InvoiceMailCredentialStore {
    let factory:()throws->InvoiceMailCredentialStore
    init(_ factory:@escaping()throws->InvoiceMailCredentialStore){self.factory=factory}
    func load(interactive:Bool)throws->InvoiceMailAccount?{try factory().load(interactive:interactive)}
    func save(_ account:InvoiceMailAccount)throws{try factory().save(account)}
    func remove()throws{try factory().remove()}
}
private struct PersonalDeferredCampaign:CampaignRelayCredentialStore {
    let factory:()throws->CampaignRelayCredentialStore
    init(_ factory:@escaping()throws->CampaignRelayCredentialStore){self.factory=factory}
    func load(interactive:Bool)throws->CampaignRelayCredentials?{try factory().load(interactive:interactive)}
    func save(_ value:CampaignRelayCredentials)throws{try factory().save(value)}
    func remove()throws{try factory().remove()}
}
private struct PersonalDeferredMCP:NativeMCPSecretStore {
    let factory:()throws->NativeMCPSecretStore
    init(_ factory:@escaping()throws->NativeMCPSecretStore){self.factory=factory}
    func load(id:String)throws->Data?{try factory().load(id:id)}
    func save(id:String,data:Data)throws{try factory().save(id:id,data:data)}
    func remove(id:String)throws{try factory().remove(id:id)}
}
