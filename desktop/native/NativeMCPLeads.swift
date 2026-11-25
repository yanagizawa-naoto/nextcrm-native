import Foundation

/// Original MCP lead operations, including the shared lead service's audit,
/// indexing event and changed-assignee notification. Effects commit together.
enum NativeMCPLeads {
    static let assignedEvent = "crm.lead_assigned"
    static let names: Set<String> = ["crm_list_lead_options", "crm_list_leads", "crm_get_lead", "crm_search_leads", "crm_create_lead", "crm_update_lead", "crm_delete_lead"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func readScope(_ service: CRMService) -> RecordFilter {
        if service.identity.elevated { return .all }
        let owner = RecordFilter.any([.equal("assigned_to", .text(service.identity.id)), .equal("createdBy", .text(service.identity.id))])
        // Preserve the original leadReadScopeWhere: a deleted parent still
        // contributes ownership, while a deleted lead itself stays hidden.
        return .any([owner, .relation(model: "crm_Accounts", local: "accountsIDs", foreign: "id", matching: service.scope("crm_Accounts"))])
    }
    private static let optionModels = [("lead_status_id", "crm_Lead_Statuses"), ("lead_source_id", "crm_Lead_Sources"), ("lead_type_id", "crm_Lead_Types")]
    private static func fields(_ arguments: [String: Any]) throws -> [String: SQLValue] {
        var result: [String: SQLValue] = [:]
        for key in ["firstName", "lastName", "email", "company", "phone", "jobTitle", "description", "campaign", "refered_by"] where arguments[key] != nil {
            guard let text = arguments[key] as? String, !text.contains("\0") else { throw NativeMCPFailure.internalError }
            result[key] = .text(text)
        }
        for key in ["assigned_to", "lead_status_id", "lead_source_id", "lead_type_id"] where arguments[key] != nil {
            if arguments[key] is NSNull { result[key] = .null }
            else if let id = arguments[key] as? String { result[key] = .text(id) }
            else { throw NativeMCPFailure.internalError }
        }
        return result
    }
    private static func checkOptions(_ values: [String: SQLValue], db: NativeDatabase) throws {
        for (field, model) in optionModels {
            if let value = values[field], value != .null, try db.get(model, key: ["id": value]) == nil { throw NativeMCPFailure.notFound }
        }
    }
    private static func audit(_ service: CRMService, before: NativeRecord?, after: NativeRecord, action: String) throws {
        var values: [String: SQLValue] = ["entityType": .text("lead"), "entityId": after["id"], "action": .text(action), "userId": .text(service.identity.id)]
        if let before {
            let internalFields: Set<String> = ["updatedAt", "updatedBy", "createdAt", "createdBy", "created_on", "cratedAt", "v", "deletedAt", "deletedBy"]
            let model = try service.db.schema.model("crm_Leads")
            let changes: [[String: Any]] = try model.fields.compactMap { field in
                guard !internalFields.contains(field.name), before[field.name] != after[field.name] else { return nil }
                return ["field": field.name, "old": try NativeMCPWire.value(before[field.name], field: field), "new": try NativeMCPWire.value(after[field.name], field: field)]
            }
            values["changes"] = .text(String(decoding: try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys]), as: UTF8.self))
        }
        // Original writeAuditLog is best effort. The native store's own audit
        // remains transactional even if this compatible domain log fails.
        _ = try? service.db.insert("crm_AuditLog", values: values, actor: service.identity.id)
    }
    private static func changedAssignee(_ before: NativeRecord, data: [String: SQLValue], service: CRMService) throws -> NativeRecord? {
        guard let assigned = data["assigned_to"], assigned != .null, assigned != before["assigned_to"], assigned != .text(service.identity.id) else { return nil }
        guard let user = try service.db.get("Users", key: ["id": assigned]), user["userStatus"] == .text("ACTIVE") else { throw NativeMCPFailure.notFound }
        return user
    }
    private static func notify(_ user: NativeRecord, lead: NativeRecord, service: CRMService) throws {
        guard !user["email"].string.isEmpty else { return }
        let name = [lead["firstName"].string, lead["lastName"].string].filter { !$0.isEmpty }.joined(separator: " ")
        try service.db.enqueue(assignedEvent, payload: ["leadId": lead["id"].string, "recipientId": user["id"].string, "recipientEmail": user["email"].string, "leadName": name, "actorID": service.identity.id])
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, actor = service.identity.id, model = "crm_Leads"
        let projection = try db.schema.model(model).fields.map(\.name)
        func visible(_ id: String, write: Bool = false) throws -> NativeRecord {
            let scope = write ? service.scope(model, write: true) : readScope(service)
            guard let row = try db.page(model, fields: projection, equal: ["id": .text(id)], filter: scope, limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            return row
        }
        switch name {
        case "crm_list_lead_options":
            var data: [String: [[String: Any]]] = [:]
            for (label, optionModel) in [("statuses", "crm_Lead_Statuses"), ("sources", "crm_Lead_Sources"), ("types", "crm_Lead_Types")] {
                var rows: [[String: Any]] = [], offset = 0
                repeat {
                    try Task.checkCancellation()
                    let page = try db.mcpPage(optionModel, fields: ["id", "name"], filter: .all, limit: 100, offset: offset, order: [("name", false), ("id", false)])
                    rows += page.rows.map { ["id": $0["id"].string, "name": $0["name"].string] }
                    offset += page.rows.count
                    if offset >= page.total || page.rows.isEmpty { break }
                } while true
                data[label] = rows
            }
            return ["data": data]
        case "crm_list_leads", "crm_search_leads":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: projection, filter: readScope(service), searchFields: ["firstName", "lastName", "email", "company"], query: name == "crm_search_leads" ? arguments["query"] as? String : nil, limit: limit, offset: offset)
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "crm_get_lead": return ["data": try NativeMCPWire.record(visible(arguments["id"] as! String), schema: db.schema)]
        case "crm_create_lead":
            var values = try fields(arguments); try checkOptions(values, db: db)
            values.merge(["v": .integer(1), "assigned_to": .text(actor), "createdBy": .text(actor), "updatedBy": .text(actor)]) { _, new in new }
            let row = try db.insert(model, values: values, actor: actor)
            try audit(service, before: nil, after: row, action: "created")
            try db.enqueue("crm/lead.saved", payload: ["record_id": row["id"].string, "actorID": actor])
            return ["data": try NativeMCPWire.record(row, schema: db.schema)]
        case "crm_update_lead":
            let before = try visible(arguments["id"] as! String, write: true)
            var values = try fields(arguments)
            let recipient = try changedAssignee(before, data: values, service: service)
            try checkOptions(values, db: db)
            values["v"] = .integer(1); values["updatedBy"] = .text(actor)
            let row = try db.update(before, changes: values, actor: actor)
            if let recipient { try notify(recipient, lead: row, service: service) }
            try audit(service, before: before, after: row, action: "updated")
            try db.enqueue("crm/lead.saved", payload: ["record_id": row["id"].string, "actorID": actor])
            return ["data": try NativeMCPWire.record(row, schema: db.schema)]
        case "crm_delete_lead":
            let row = try db.setDeleted(visible(arguments["id"] as! String, write: true), deleted: true, actor: actor)
            try audit(service, before: nil, after: row, action: "deleted")
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        default: throw NativeMCPFailure.internalError
        }
    }
}

struct NativeMCPLeadLink: Equatable {
    let leadID: String
    init(leadID: String) throws {
        guard let id = UUID(uuidString: leadID), id.uuidString.lowercased() == leadID.lowercased() else { throw NativeDBError.message("見込み客リンクの識別子が正しくありません。") }
        self.leadID = id.uuidString.lowercased()
    }
    init(text: String) throws {
        guard text.utf8.count <= 4096, let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "nextcrm-native", url.host?.lowercased() == "leads", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil, url.percentEncodedPath.hasPrefix("/"), !url.percentEncodedPath.dropFirst().contains("/") else { throw NativeDBError.message("NextCRMの見込み客リンクを入力してください。") }
        try self.init(leadID: String(url.percentEncodedPath.dropFirst()))
    }
    var string: String { "nextcrm-native://leads/" + leadID }
}
