import Foundation

enum NativeMCPTargets {
    static let names: Set<String> = ["crm_list_targets", "crm_get_target", "crm_search_targets", "crm_create_target", "crm_update_target", "crm_delete_target"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let model = "crm_Targets", db = service.db, actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name)
        // Unlike the target-list tools, the original target tools restrict
        // managers and administrators to their own created targets as well.
        let owner = RecordFilter.equal("created_by", .text(actor))
        func visible(_ id: String) throws -> NativeRecord {
            guard let row = try db.page(model, fields: fields, equal: ["id": .text(id)], filter: owner, limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
        }
        func input() throws -> [String: SQLValue] {
            var result: [String: SQLValue] = [:]
            for key in ["first_name", "last_name", "email", "mobile_phone", "office_phone", "company", "position"] where arguments[key] != nil {
                guard let value = arguments[key] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }
                result[key] = .text(value)
            }
            return result
        }
        switch name {
        case "crm_list_targets", "crm_search_targets":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: fields, filter: owner, searchFields: ["first_name", "last_name", "email", "company"], query: name == "crm_search_targets" ? arguments["query"] as? String : nil, limit: limit, offset: offset, order: [("created_on", true), ("id", true)])
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "crm_get_target": return ["data": try NativeMCPWire.record(visible(arguments["id"] as! String), schema: db.schema)]
        case "crm_create_target":
            var values = try input(); values["created_by"] = .text(actor)
            return ["data": try NativeMCPWire.record(db.insert(model, values: values, actor: actor), schema: db.schema)]
        case "crm_update_target":
            let row = try visible(arguments["id"] as! String); var values = try input(); values["updatedBy"] = .text(actor)
            return ["data": try NativeMCPWire.record(db.update(row, changes: values, actor: actor), schema: db.schema)]
        case "crm_delete_target":
            let row = try db.setDeleted(visible(arguments["id"] as! String), deleted: true, actor: actor)
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
