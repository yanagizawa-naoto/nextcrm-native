import Foundation

/// Four original MCP entry points feed the existing enrichment workers. Keys
/// remain in environment/Keychain; only opaque requests enter the durable queue.
enum NativeMCPEnrichment {
    struct Field: Codable, Equatable { let name: String; var description: String? }
    struct Event: Codable, Equatable {
        struct Data: Codable, Equatable {
            var contactId: String? = nil, targetId: String? = nil, enrichmentId: String? = nil
            var contactIds: [String]? = nil, targetIds: [String]? = nil
            let fields: [Field], triggeredBy: String
        }
        let name: String, data: Data
    }
    typealias EventSink = (Event, CRMService, NativeAISecretStore, NativeAIEnvironment, Date) throws -> Void
    typealias Store = (CRMService) -> NativeAISecretStore
    static let names: Set<String> = ["crm_enrich_contact", "crm_enrich_contact_bulk", "crm_enrich_target", "crm_enrich_target_bulk"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] { handlers(store: { KeychainNativeAISecrets(databaseURL: $0.db.url) }) }
    static func handlers(store: @escaping Store, environment: NativeAIEnvironment = NativeAIEnvironment(), events: @escaping EventSink = persist, clock: @escaping () -> Date = Date.init) -> [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in (name, { session, arguments in
            try session.withAccess { service in try run(name, arguments: arguments, service: service, store: store(service), environment: environment, events: events, now: clock()) }
        }) })
    }
    static func fields(_ raw: [Field]) -> [NativeEnrichmentField] {
        raw.map { .init(name: $0.name, displayName: $0.name, description: $0.description ?? "", mcpRequested: true) }
    }
    static func persist(_ event: Event, service: CRMService, store: NativeAISecretStore, environment: NativeAIEnvironment, now: Date) throws {
        let db = service.db, actor = service.identity.id, original = try NativeContactEnrichment.json(event.data.fields), native = fields(event.data.fields)
        guard event.data.triggeredBy == actor else { throw NativeMCPFailure.internalError }
        if let ids = event.data.contactIds ?? event.data.targetIds {
            guard [NativeContactEnrichment.bulkEvent, NativeTargetEnrichment.bulkEvent].contains(event.name) else { throw NativeMCPFailure.internalError }
            try db.enqueue(event.name, payload: ["actorID": actor, "ids": NativeContactEnrichment.json(ids), "fields": NativeContactEnrichment.json(native), "mcpFields": original, "mcpOrigin": "bulk"], now: now)
        } else {
            guard let id = event.data.enrichmentId else { throw NativeMCPFailure.internalError }
            if event.name == NativeContactEnrichment.event, let contactID = event.data.contactId,
               let history = try db.get(NativeContactEnrichment.model, key: ["id": .text(id)]) {
                let api = NativeContactEnrichmentService(service: service, store: store, environment: environment, clock: { now })
                _ = try api.enqueueMCP(api.contact(contactID, mode: .review, mcp: true), fields: native, originalFields: original, single: true, batch: id, history: history)
            } else if event.name == NativeTargetEnrichment.event, let targetID = event.data.targetId,
                      let history = try db.get(NativeTargetEnrichment.model, key: ["id": .text(id)]) {
                let api = NativeTargetEnrichmentService(service: service, store: store, environment: environment, clock: { now })
                _ = try api.enqueue(api.target(targetID, mcp: true), fields: native, mode: .automatic, force: false, batch: id, mcpOrigin: "single", originalFields: original, existingHistory: history)
            } else { throw NativeMCPFailure.internalError }
        }
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(), events: EventSink = persist, now: Date = Date()) throws -> Any {
        try service.authenticated(); try Task.checkCancellation()
        guard names.contains(name) else { throw NativeMCPFailure.internalError }
        let db = service.db, actor = service.identity.id, contact = name.contains("contact"), bulk = name.hasSuffix("_bulk")
        let model = contact ? "crm_Contacts" : "crm_Targets", historyModel = contact ? NativeContactEnrichment.model : NativeTargetEnrichment.model
        let singular = contact ? "contactId" : "targetId", plural = contact ? "contactIds" : "targetIds"
        let keys = NativeAIKeys(service: service, store: store, environment: environment, clock: { now })
        if contact {
            // Resolve both in source order even when the first key is absent.
            let firecrawl = try keys.resolve(.firecrawl), openai = try keys.resolve(.openai)
            guard firecrawl != nil && openai != nil else { throw NativeMCPFailure.external("Missing required API keys (FIRECRAWL and/or OPENAI)." + (bulk ? "" : " Configure them in Settings > API Keys.")) }
        } else {
            guard try keys.resolve(.anthropic) != nil else { throw NativeMCPFailure.external("Missing required API key (ANTHROPIC).") }
            // The shared Keychain E2B setting is the Mac equivalent of the
            // server environment. Preserve the source raw env presence check.
            guard try !(environment.lookup("E2B_API_KEY") ?? "").isEmpty || !(db.metadata(NativeE2BSettings.keyReference) ?? "").isEmpty else { throw NativeMCPFailure.external("Missing required API key (E2B_API_KEY).") }
        }
        let raw = try (arguments["fields"] as! [[String: Any]]).map { item -> Field in
            guard let name = item["name"] as? String else { throw NativeMCPFailure.internalError }
            return .init(name: name, description: item["description"] as? String)
        }
        func visible(_ id: String) throws -> NativeRecord {
            let filter = RecordFilter.every([.equal("id", .text(id)), contact ? NativeContactEnrichment.mcpScope(service, single: !bulk) : service.scope(model, write: true)])
            guard let row = try db.page(model, fields: ["email"], includeDeleted: !bulk || !contact, filter: filter, limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
        }
        if bulk {
            let ids = arguments[plural] as! [String]
            // PostgreSQL IN returns one row for each unique ID.
            guard Set(ids.map { $0.lowercased() }).count == ids.count else { throw NativeMCPFailure.notFound }
            for id in ids { _ = try visible(id) }
            let event = Event(name: contact ? NativeContactEnrichment.bulkEvent : NativeTargetEnrichment.bulkEvent,
                data: .init(contactIds: contact ? ids : nil, targetIds: contact ? nil : ids, fields: raw, triggeredBy: actor))
            try events(event, service, store, environment, now)
            return ["data": ["status": "DISPATCHED", "count": ids.count]]
        }
        let id = arguments[singular] as! String, row = try visible(id)
        guard !row["email"].string.isEmpty else { throw NativeMCPFailure.external((contact ? "Contact" : "Target") + " has no email. Add an email to enable enrichment.") }
        guard raw.allSatisfy({ !$0.name.contains("\0") }) else { throw NativeMCPFailure.internalError }
        let history = try db.insert(historyModel, values: [singular: row["id"], "status": .text("RUNNING"), "fields": .text(NativeContactEnrichment.json(raw.map(\.name))), "triggeredBy": .text(actor), "createdAt": .text(NativeContactEnrichment.stamp(now))], actor: actor)
        let enrichmentID = history["id"].string
        let event = Event(name: contact ? NativeContactEnrichment.event : NativeTargetEnrichment.event,
            data: .init(contactId: contact ? id : nil, targetId: contact ? nil : id, enrichmentId: enrichmentID, fields: raw, triggeredBy: actor))
        try events(event, service, store, environment, now)
        return ["data": ["enrichmentId": enrichmentID, "status": "RUNNING"]]
    }
}
