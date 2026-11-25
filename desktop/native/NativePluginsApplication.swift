import Foundation

private final class NativePluginsHostReference { weak var value: NativePluginHost? }

/// Retained by the app delegate so database hooks keep their host alive.
final class NativePluginsApplication {
    let host: NativePluginHost, vault: NativePluginCredentialVault, runtime: NativePluginsRuntime
    let admin: NativePluginsAdmin, registry: NativeCompanyRegistry
    init(service: CRMService, mail: InvoiceMailRuntime) throws {
        let db = service.db, root = db.url.deletingLastPathComponent(), isQA = mail.isQA
        let backing: NativePluginCredentialBacking? = isQA ? try NativePluginsQACredentials(root: root) : nil
        vault = NativePluginCredentialVault(db: db, backing: backing)
        let notification = NativePluginsMail(root: root, store: mail.store, request: mail.request)
        let allowPrivate = ProcessInfo.processInfo.environment["PLUGIN_HTTP_ALLOW_PRIVATE_HOSTS"] == "true"
        let reference = NativePluginsHostReference()
        host = try NativePluginHost(db: db, definitions: [NativeAccountProtection.definition(), NativeAresPlugin.definition(), NativeOdooPlugin.definition, NativeOXOConnector.definition()], secretStore: vault.store,
            sendNotification: { try await notification.send(to: $0, subject: $1, text: $2) },
            transport: { id, request in
                guard !isQA else { throw NativeDBError.message("検証モードでは実際の連携先に接続しません。") }
                guard let host = reference.value, let definition = host.definition(id) else { throw CancellationError() }
                let context = try host.context(definition, actor: .plugin(id))
                return try await NativePluginHTTP.fetch(request, transport: { try await NativePluginHTTPTransport.request($0, allowPrivate: allowPrivate) }, log: context.log)
            })
        reference.value = host
        runtime = NativePluginsRuntime(host: host, vault: vault)
        let runtime = runtime
        admin = NativePluginsAdmin(service: service, host: host, wake: { await runtime.wake() })
        registry = NativeCompanyRegistry(service: service, host: host)
        host.attach()
    }
}
