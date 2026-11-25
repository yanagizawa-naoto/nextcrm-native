import Foundation

private final class FakeMailCredentials: InvoiceMailCredentialStore {
    var value: InvoiceMailAccount?
    var reads = 0
    var saves = 0
    var removes = 0
    func load(interactive: Bool) throws -> InvoiceMailAccount? { reads += 1; return value }
    func save(_ account: InvoiceMailAccount) throws { saves += 1; value = account }
    func remove() throws { removes += 1; value = nil }
}

extension InvoiceMailTests {
    static func keychainProbe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-KeychainProbe-"+UUID().uuidString)
        let store = KeychainInvoiceMailCredentials(databaseURL:root.appendingPathComponent("crm.sqlite"))
        guard try store.load(interactive:false) == nil else { throw NativeDBError.message("検証用の保存先が既に存在します。") }
        defer { try? store.remove() }
        let first = "fake-probe-"+UUID().uuidString
        try store.save(.init(from:"probe@example.invalid",apiKey:first))
        let loaded = try store.load(interactive:false)
        try check(loaded?.from == "probe@example.invalid" && loaded?.apiKey == first,"real Keychain save/read of fake credential")
        let second = "fake-probe-"+UUID().uuidString
        try store.save(.init(from:"updated@example.invalid",apiKey:second))
        let updated = try store.load(interactive:false)
        try check(updated?.from == "updated@example.invalid" && updated?.apiKey == second,"real Keychain atomic update")
        let isolated = KeychainInvoiceMailCredentials(databaseURL:root.appendingPathComponent("other.sqlite"))
        try check(try isolated.load(interactive:false) == nil,"real Keychain database isolation")
        try store.remove(); try store.remove()
        try check(try store.load(interactive:false) == nil,"real Keychain fake credential removed")
    }
    static func credentialTests(admin: CRMService, owner: CRMService) throws {
        let store = FakeMailCredentials()
        try rejects("nonadmin cannot save credentials") { try owner.saveInvoiceMailSettings(from:"sender@example.invalid",apiKey:"fake-private-value",store:store) }
        try rejects("nonadmin cannot remove credentials") { try owner.removeInvoiceMailSettings(store:store) }
        try check(store.reads == 0 && store.saves == 0 && store.removes == 0,"denied settings never touch credential storage")
        try rejects("missing credentials rejected") { try admin.saveInvoiceMailSettings(from:"sender@example.invalid",apiKey:"",store:store) }
        try rejects("sender injection rejected") { try admin.saveInvoiceMailSettings(from:"sender@example.invalid\r\nBcc:other@example.invalid",apiKey:"fake-private-value",store:store) }
        try rejects("key injection rejected") { try admin.saveInvoiceMailSettings(from:"sender@example.invalid",apiKey:"fake\r\nHeader:value",store:store) }
        try admin.saveInvoiceMailSettings(from:" sender@example.invalid ",apiKey:"fake-private-value",store:store)
        try check(store.value?.from == "sender@example.invalid" && store.value?.apiKey == "fake-private-value","credentials and normalized sender stored together")
        try check(try owner.invoiceMailSender(store:store) == "sender@example.invalid","authorized sender query returns only address")
        try admin.saveInvoiceMailSettings(from:"new@example.invalid",apiKey:"",store:store)
        try check(store.value?.from == "new@example.invalid" && store.value?.apiKey == "fake-private-value","blank key preserves existing secret")
        try admin.removeInvoiceMailSettings(store:store)
        try check(store.value == nil && store.removes == 1,"administrator removes credential")
    }
}
