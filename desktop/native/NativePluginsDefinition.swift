import Foundation

enum NativePluginActorScope {
    struct Frame { let actor: NativePluginActor; let depth: Int; let locale: String }
    @TaskLocal static var current: Frame? = nil
    static func withActor<T>(_ actor: NativePluginActor, locale: String? = nil, _ body: () throws -> T) rethrows -> T {
        let frame = Frame(actor:actor,depth:(current?.depth ?? 0)+(actor.type == .plugin ? 1:0),locale:locale ?? current?.locale ?? "en")
        return try $current.withValue(frame,operation:body)
    }
    static func withActor<T>(_ actor: NativePluginActor, locale: String? = nil, _ body: () async throws -> T) async rethrows -> T {
        let frame = Frame(actor:actor,depth:(current?.depth ?? 0)+(actor.type == .plugin ? 1:0),locale:locale ?? current?.locale ?? "en")
        return try await $current.withValue(frame,operation:body)
    }
}

struct NativePluginRule {
    let entity: NativePluginEntity, operation: NativePluginRuleInput.Operation
    var onError = "allow", priority = 100
    let handler: (NativePluginRuleInput, NativePluginContext) throws -> NativePluginRuleResult
}
struct NativePluginAfter {
    let entity: NativePluginEntity, operation: NativePluginAfterInput.Operation
    let handler: (NativePluginAfterInput, NativePluginContext) async throws -> Void
}
struct NativePluginCron {
    let id: String, schedule: String
    let handler: (NativePluginContext) async throws -> Void
}
struct NativePluginEvent {
    let event: String
    let handler: (NativePluginRecord, NativePluginContext) async throws -> Void
}
struct NativePluginSlot {
    enum Kind: String { case accountTab, accountPanel, orderPanel, productPanel, page, adminSection, adminAction, companyRegistry }
    let kind: Kind, id: String
    var title: String? = nil, roles = NativePluginSDK.internalRoles
    var nav: String? = nil
}
struct NativePluginCompanyRegistry {
    let countries:[String]
    let lookup:(String,String,NativePluginContext) async throws -> NativePluginRecord?
    var validateVat:((String,NativePluginContext) async throws -> Bool)? = nil
}
struct NativePluginDefinition {
    let id: String, name: String, version: String, sdk: String, description: String
    var permissions: [String] = []
    var settings = NativePluginSettingsSchema(), secrets = NativePluginSettingsSchema()
    var rules: [NativePluginRule] = [], afters: [NativePluginAfter] = [], crons: [NativePluginCron] = [], events: [NativePluginEvent] = [], slots: [NativePluginSlot] = []
    var onInstall: ((NativePluginContext) async throws -> Void)? = nil
    var onUpgrade: ((NativePluginContext, String) async throws -> Void)? = nil
    var onUninstall: ((NativePluginContext) async throws -> Void)? = nil
    var actions: [String:(NativePluginRecord,NativePluginContext) async throws -> Any] = [:]
    var companyRegistries:[NativePluginCompanyRegistry]=[]
    func validate() throws {
        try NativePluginSDK.validate(id:id,version:version,sdk:sdk,permissions:permissions)
        func unique(_ values: [String], _ label: String) throws {
            var seen = Set<String>()
            for value in values { guard seen.insert(value).inserted else { throw NativePluginError(message:label+": "+value) } }
        }
        try unique(crons.map(\.id),"Duplicate cron id"); try unique(events.map(\.event),"Duplicate event handler")
        for (kind,label) in [(NativePluginSlot.Kind.accountTab,"account tab id"),(.accountPanel,"account panel id"),(.orderPanel,"order panel id"),(.productPanel,"product panel id"),(.page,"page path"),(.adminAction,"admin action id")] {
            try unique(slots.filter { $0.kind == kind }.map(\.id),"Duplicate "+label)
        }
    }
}

struct NativePluginNotification {
    var userIds: [String] = [], roles: [String] = []
    let subject: String, text: String
}

final class NativePluginContext {
    private var warnings = Set<String>()
    let plugin: (id: String,version: String), actor: NativePluginActor, locale: String
    let settings: NativePluginRecord, secrets: NativePluginRecord
    let store: NativePluginStore, data: NativePluginData
    let clock: () -> Date
    private let permissions: Set<String>
    private let logger: (String,String,NativePluginRecord?) -> Void
    private let translator: (String,NativePluginRecord?) -> String
    private let notification: (NativePluginNotification) async throws -> Void
    private let transport: (URLRequest) async throws -> (Data,HTTPURLResponse)
    /// A rule can retain small side effects after the rejected record rolls back.
    /// Never capture this context or secrets in the deferred callback.
    let persistAfterTransaction: (@escaping () -> Void) -> Void
    init(definition: NativePluginDefinition,actor: NativePluginActor,locale: String,settings: NativePluginRecord,secrets: NativePluginRecord,store: NativePluginStore,data: NativePluginData,clock: @escaping () -> Date,logger: @escaping (String,String,NativePluginRecord?) -> Void,translator: @escaping (String,NativePluginRecord?) -> String,notification: @escaping (NativePluginNotification) async throws -> Void,transport: @escaping (URLRequest) async throws -> (Data,HTTPURLResponse),persistAfterTransaction: @escaping (@escaping () -> Void) -> Void) {
        plugin=(definition.id,definition.version); self.actor=actor; self.locale=locale; self.settings=settings; self.secrets=secrets; self.store=store; self.data=data; self.clock=clock; permissions=Set(definition.permissions); self.logger=logger; self.translator=translator; self.notification=notification; self.transport=transport; self.persistAfterTransaction=persistAfterTransaction
    }
    func need(_ permission: String) throws { try NativePluginExecutionScope.check(plugin.id);guard permissions.contains(permission) else { throw NativePluginError.permission(plugin.id,permission) } }
    func log(_ level: String, _ message: String, _ context: NativePluginRecord? = nil) { logger(level,message,context) }
    func warnOnce(_ key:String,_ message:String) { if warnings.insert(key).inserted { log("warn",message) } }
    func t(_ key: String, _ params: NativePluginRecord? = nil) -> String { translator(key,params) }
    func notify(_ input: NativePluginNotification) async throws { try need("notify"); try await notification(input);try NativePluginExecutionScope.check(plugin.id) }
    func http(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) { try need("http");let result=try await transport(request);try NativePluginExecutionScope.check(plugin.id);return result }
}
