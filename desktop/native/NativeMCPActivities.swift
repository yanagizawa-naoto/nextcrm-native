import Foundation

enum NativeMCPActivities {
    static let names: Set<String> = ["crm_list_activities", "crm_get_activity", "crm_create_activity", "crm_update_activity", "crm_delete_activity"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, actor = service.identity.id, model = "crm_Activities"
        func fields(_ model: String) throws -> [String] { try db.schema.model(model).fields.map(\.name) }
        func wire(_ row: NativeRecord, links: Bool = false) throws -> [String: Any] {
            var value = try NativeMCPWire.record(row, schema: db.schema)
            if links {
                var related: [[String: Any]] = [], offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try db.page("crm_ActivityLinks", fields: fields("crm_ActivityLinks"), equal: ["activityId": row["id"]], offset: offset, insertionOrderForTies: true)
                    related += try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }
                    if page.rows.count < 100 { break }; offset += page.rows.count
                }
                value["links"] = related
            }
            return value
        }
        // MCP activity detail and mutations remain creator-only, including
        // administrators. Entity-feed visibility does not confer ownership.
        func own(_ id: String) throws -> NativeRecord {
            guard let row = try db.page(model, fields: fields(model), equal: ["id": .text(id), "createdBy": .text(actor)], limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            return row
        }
        func requireEntity(_ type: String, id: String, write: Bool) throws {
            let normalized = type.lowercased()
            let models = ["account": "crm_Accounts", "contact": "crm_Contacts", "lead": "crm_Leads", "opportunity": "crm_Opportunities", "contract": "crm_Contracts", "target": "crm_Targets", "targetlist": "crm_TargetLists", "target_list": "crm_TargetLists"]
            guard let target = models[normalized] else {
                guard !write, service.identity.elevated else { throw NativeMCPFailure.notFound }; return
            }
            // Source write helpers permit a deleted account/contact. Its
            // target read helper likewise does not filter deletedAt.
            let includeDeleted = write && ["account", "contact"].contains(normalized) || !write && normalized == "target"
            guard try db.page(target, fields: [], equal: ["id": .text(id)], includeDeleted: includeDeleted, filter: service.scope(target, write: write), limit: 1).rows.first != nil else { throw NativeMCPFailure.notFound }
        }
        func input(_ keys: [String]) throws -> [String: SQLValue] {
            var values: [String: SQLValue] = [:]
            for key in keys where arguments[key] != nil {
                guard let value = arguments[key] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }
                values[key] = .text(value)
            }
            if let value = arguments["date"] as? String {
                guard let canonical = NativeMCPWire.canonicalUTC(value) else { throw NativeMCPFailure.internalError }; values["date"] = .text(canonical)
            }
            if let value = arguments["duration"] { values["duration"] = .integer(Int64(try NativeMCPWire.integer(value, range: 0...Int(Int32.max)))) }
            return values
        }
        func calendar(_ row: NativeRecord, operation: String) throws {
            guard row["type"] == .text("meeting") else { return }
            try Task.checkCancellation()
            // The source treats event emission as best-effort. A savepoint
            // isolates an outbox failure from the activity transaction while
            // request cancellation still rolls back the entire operation.
            _ = try? db.transaction { try db.enqueue("calendar/outbound", payload: ["activity_id": row["id"].string, "operation": operation]) }
            try Task.checkCancellation()
        }
        switch name {
        case "crm_list_activities":
            var filters: [RecordFilter] = []
            if let type = arguments["entityType"] as? String, !type.isEmpty, let id = arguments["entityId"] as? String, !id.isEmpty {
                try requireEntity(type, id: id, write: false)
                // Authorization folds the type, but the original link query
                // retains the caller's exact spelling.
                filters.append(.relation(model: "crm_ActivityLinks", local: "id", foreign: "activityId", matching: .every([.equal("entityType", .text(type)), .equal("entityId", .text(id))])))
            } else { filters.append(.equal("createdBy", .text(actor))) }
            for key in ["type", "status"] { if let value = arguments[key] as? String { filters.append(.equal(key, .text(value))) } }
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: fields(model), filter: .every(filters), limit: limit, offset: offset, order: [("date", true), ("id", true)])
            return ["data": try page.rows.map { try wire($0, links: true) }, "total": page.total, "offset": offset]
        case "crm_get_activity": return ["data": try wire(own(arguments["id"] as! String), links: true)]
        case "crm_create_activity":
            let links = arguments["links"] as? [[String: Any]] ?? []
            for link in links { try requireEntity(link["entityType"] as! String, id: link["entityId"] as! String, write: true) }
            var values = try input(["type", "title", "description", "outcome", "status"])
            values["createdBy"] = .text(actor); values["updatedBy"] = .text(actor)
            let row = try db.insert(model, values: values, actor: actor)
            for link in links {
                _ = try db.insert("crm_ActivityLinks", values: ["activityId": row["id"], "entityType": .text(link["entityType"] as! String), "entityId": .text(link["entityId"] as! String)], actor: actor)
            }
            try calendar(row, operation: "upsert")
            return ["data": try wire(row, links: true)]
        case "crm_update_activity":
            let existing = try own(arguments["id"] as! String)
            var values = try input(["title", "description", "outcome", "status"]); values["updatedBy"] = .text(actor)
            let row = try db.update(existing, changes: values, actor: actor)
            try calendar(row, operation: arguments["status"] as? String == "cancelled" ? "cancel" : "upsert")
            return ["data": try wire(row)]
        case "crm_delete_activity":
            let row = try db.setDeleted(own(arguments["id"] as! String), deleted: true, actor: actor)
            try calendar(row, operation: "cancel")
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
