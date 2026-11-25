import Foundation

/// Account-specific MCP operations reuse the native scope and transactional
/// store. API values are not silently trimmed or truncated by UI form rules.
enum NativeMCPAccounts {
    static let names: Set<String> = ["crm_list_accounts", "crm_get_account", "crm_search_accounts", "crm_create_account", "crm_update_account", "crm_delete_account"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let model = "crm_Accounts", db = service.db, actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name)
        func visible(_ id: String, write: Bool = false) throws -> NativeRecord {
            let filter = RecordFilter.every([service.scope(model, write: write), .equal("id", .text(id))])
            guard let record = try db.page(model, fields: fields, filter: filter, limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            return record
        }
        func strings(_ names: [String]) throws -> [String: SQLValue] {
            var values: [String: SQLValue] = [:]
            for name in names where arguments[name] != nil {
                guard let value = arguments[name] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }
                values[name] = .text(value)
            }
            return values
        }
        switch name {
        case "crm_list_accounts", "crm_search_accounts":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100)
            let offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: fields, filter: service.scope(model), searchFields: ["name", "website"], query: name == "crm_search_accounts" ? arguments["query"] as? String : nil, limit: limit, offset: offset)
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "crm_get_account":
            return ["data": try NativeMCPWire.record(visible(arguments["id"] as! String), schema: db.schema)]
        case "crm_create_account":
            var values = try strings(["name", "email", "description", "office_phone", "website"])
            values.merge(["v": .integer(0), "assigned_to": .text(actor), "createdBy": .text(actor), "updatedBy": .text(actor), "status": .text("Active")]) { _, new in new }
            let record = try db.insert(model, values: values, actor: actor)
            return ["data": try NativeMCPWire.record(record, schema: db.schema)]
        case "crm_update_account":
            let original = try visible(arguments["id"] as! String, write: true)
            var values = try strings(["name", "email", "description", "office_phone", "website"])
            if let assigned = arguments["assigned_to"] {
                if assigned is NSNull { values["assigned_to"] = .null }
                else {
                    guard let id = assigned as? String, let user = try db.get("Users", key: ["id": .text(id)]), user["userStatus"] == .text("ACTIVE") else { throw NativeMCPFailure.notFound }
                    values["assigned_to"] = .text(id)
                }
            }
            values["updatedBy"] = .text(actor)
            let record = try db.update(original, changes: values, actor: actor)
            return ["data": try NativeMCPWire.record(record, schema: db.schema)]
        case "crm_delete_account":
            let original = try visible(arguments["id"] as! String, write: true)
            let record = try db.setDeleted(original, deleted: true, actor: actor)
            return ["data": ["id": record["id"].string, "deletedAt": try NativeMCPWire.value(record["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
