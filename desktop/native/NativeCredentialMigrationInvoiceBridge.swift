import Foundation

/// Explicit runtime integration point. Reads legacy settings only until an
/// immutable binding/tombstone exists. Saves/removes never mutate the singleton
/// or old immutable items, so an older backup retains its previous credentials.
struct NativeCredentialMigrationInvoiceBridge:InvoiceMailCredentialStore {
    let service:CRMService,vault:NativeCredentialMigrationVault,legacy:InvoiceMailCredentialStore
    func load(interactive:Bool)throws->InvoiceMailAccount? {
        let result=try NativeCredentialMigration.readInvoice(service:service,vault:vault)
        if result.configured {return try result.data.map{try JSONDecoder().decode(InvoiceMailAccount.self,from:$0)}}
        return try legacy.load(interactive:interactive)
    }
    func save(_ account:InvoiceMailAccount)throws {
        let migration=try NativeCredentialMigration(service:service,vault:vault)
        let expected=try service.db.metadata(NativeCredentialMigration.invoiceKey)
        _ = try migration.replaceInvoice(JSONEncoder().encode(account),expectedBinding:expected)
    }
    func remove()throws {
        let migration=try NativeCredentialMigration(service:service,vault:vault)
        let expected=try service.db.metadata(NativeCredentialMigration.invoiceKey)
        _ = try migration.replaceInvoice(nil,expectedBinding:expected)
    }
}
