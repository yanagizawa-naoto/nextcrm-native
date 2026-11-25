import Foundation

/// Uses the administrator's existing notification sender. The plugin job owns
/// retry policy; this adapter sends one recipient and retains no body in RAM.
struct NativePluginsMail {
    let root: URL, store: InvoiceMailCredentialStore, request: ResendMailClient.Request
    func send(to: String, subject: String, text: String) async throws {
        try Task.checkCancellation()
        guard let account = try store.load(interactive: false) else {
            throw NativeDBError.message("通知メールの送信設定がありません。管理者が差出人とAPIキーを設定してください。")
        }
        let preparation = try NativeMailPreparationFiles.create(.plugin,root:root)
        defer { withExtendedLifetime(preparation) {} }
        let id = preparation.id
        let body = try InvoiceMail.prepareText(root: preparation.url, id: id, from: account.from, to: to, subject: subject, message: text)
        try Task.checkCancellation()
        _ = try await ResendMailClient.send(body: body.url, jobID: id, apiKey: account.apiKey, scope: "plugin", request: request)
        try Task.checkCancellation()
    }
}
