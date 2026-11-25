import Foundation

enum NativeMCPContacts {
    static let names: Set<String> = ["crm_list_contacts", "crm_get_contact", "crm_search_contacts", "crm_create_contact", "crm_update_contact", "crm_delete_contact"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func readScope(_ service: CRMService) -> RecordFilter {
        if service.identity.elevated { return .all }
        let owner = RecordFilter.any([.equal("assigned_to", .text(service.identity.id)), .equal("createdBy", .text(service.identity.id))])
        // Original MCP contactReadScopeWhere grants linked-account ownership
        // even when that parent is soft-deleted. Contact deletion is separate.
        return .any([owner, .relation(model: "crm_Accounts", local: "accountsIDs", foreign: "id", matching: service.scope("crm_Accounts"))])
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let model = "crm_Contacts", db = service.db, actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name)
        func visible(_ id: String, write: Bool = false) throws -> NativeRecord {
            let scope = write ? service.scope(model, write: true) : readScope(service)
            guard let row = try db.page(model, fields: fields, equal: ["id": .text(id)], filter: scope, limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            return row
        }
        func values() throws -> [String: SQLValue] {
            var result: [String: SQLValue] = [:]
            for field in ["first_name", "last_name", "email", "office_phone", "mobile_phone", "position"] where arguments[field] != nil {
                guard let text = arguments[field] as? String, !text.contains("\0") else { throw NativeMCPFailure.internalError }
                result[field] = .text(text)
            }
            return result
        }
        switch name {
        case "crm_list_contacts", "crm_search_contacts":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: fields, filter: readScope(service), searchFields: ["first_name", "last_name", "email", "office_phone", "mobile_phone"], query: name == "crm_search_contacts" ? arguments["query"] as? String : nil, limit: limit, offset: offset, order: [("created_on", true), ("id", true)])
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "crm_get_contact": return ["data": try NativeMCPWire.record(visible(arguments["id"] as! String), schema: db.schema)]
        case "crm_create_contact":
            var data = try values()
            data.merge(["v": .integer(0), "assigned_to": .text(actor), "createdBy": .text(actor), "updatedBy": .text(actor)]) { _, new in new }
            return ["data": try NativeMCPWire.record(db.insert(model, values: data, actor: actor), schema: db.schema)]
        case "crm_update_contact":
            let original = try visible(arguments["id"] as! String, write: true)
            var data = try values()
            if let account = arguments["account"] {
                if account is NSNull { data["accountsIDs"] = .null }
                else {
                    guard let id = account as? String, try db.page("crm_Accounts", fields: [], equal: ["id": .text(id)], filter: service.scope("crm_Accounts", write: true), limit: 1).rows.first != nil else { throw NativeMCPFailure.notFound }
                    data["accountsIDs"] = .text(id)
                }
            }
            if let assigned = arguments["assigned_to"] {
                if assigned is NSNull { data["assigned_to"] = .null }
                else {
                    guard let id = assigned as? String, let user = try db.get("Users", key: ["id": .text(id)]), user["userStatus"] == .text("ACTIVE") else { throw NativeMCPFailure.notFound }
                    data["assigned_to"] = .text(id)
                }
            }
            data["updatedBy"] = .text(actor)
            return ["data": try NativeMCPWire.record(db.update(original, changes: data, actor: actor), schema: db.schema)]
        case "crm_delete_contact":
            let row = try db.setDeleted(visible(arguments["id"] as! String, write: true), deleted: true, actor: actor)
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
