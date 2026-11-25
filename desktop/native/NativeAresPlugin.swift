import Foundation

enum NativeAresPlugin {
    static let id = "registry-ares"
    static func definition() -> NativePluginDefinition {
        var definition = NativePluginDefinition(id: id, name: "企業登録情報（ARES・VIES）", version: "0.1.0", sdk: "^0.2.0", description: "チェコの企業登録情報をARESから取得し、EUの税務登録番号をVIESで確認します。", permissions: ["http"])
        definition.companyRegistries = [.init(countries: ["CZ"], lookup: { number, _, context in
            try await NativeAres.lookup(number, fetch: context.http)
        }, validateVat: { vat, context in
            try await NativeAres.validateVat(vat, fetch: context.http)
        })]
        return definition
    }
}

extension NativeCompanyRegistry {
    /// Snapshot definitions under the database lock, then build a fresh plugin
    /// context for each request. No transaction spans a provider await.
    init(service: CRMService, host: NativePluginHost) {
        precondition(service.db === host.db)
        let actor = NativePluginActor(type: .user, userId: service.identity.id, role: service.identity.role)
        func current(_ definition: NativePluginDefinition) throws {
            try service.authenticated()
            guard try host.state(definition.id)?["status"] == .text("ENABLED") else { throw NativePluginError(message: "企業登録情報の連携が無効になりました。") }
        }
        self.init(authenticate: { try service.authenticated() }, providers: {
            try service.db.transaction {
                try service.authenticated()
                return try host.enabled().flatMap { definition in
                    definition.companyRegistries.map { provider in
                        Provider(countries: provider.countries, lookup: { number, country in
                            var context: NativePluginContext?
                            do {
                                let ctx = try service.db.transaction { try current(definition); return try host.context(definition, actor: actor) }
                                context = ctx
                                let value = try await provider.lookup(number, country, ctx)
                                try Task.checkCancellation()
                                try service.db.transaction { try current(definition) }
                                return value
                            } catch is CancellationError { throw CancellationError() }
                            catch {
                                if let context { context.log("error", "Registry lookup failed: " + error.localizedDescription) }
                                else { host.log(definition.id, "error", "Registry lookup failed: " + error.localizedDescription) }
                                throw error
                            }
                        }, validateVat: provider.validateVat.map { validate in
                            { vat in
                                var context: NativePluginContext?
                                do {
                                    let ctx = try service.db.transaction { try current(definition); return try host.context(definition, actor: actor) }
                                    context = ctx
                                    let value = try await validate(vat, ctx)
                                    try Task.checkCancellation()
                                    try service.db.transaction { try current(definition) }
                                    return value
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    if let context { context.log("error", "VAT validation failed: " + error.localizedDescription) }
                                    else { host.log(definition.id, "error", "VAT validation failed: " + error.localizedDescription) }
                                    throw error
                                }
                            }
                        })
                    }
                }
            }
        })
    }
}
