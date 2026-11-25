import Foundation

enum NativeMCPTargetLists {
    static let names: Set<String> = ["crm_list_target_lists", "crm_get_target_list", "crm_create_target_list", "crm_update_target_list", "crm_delete_target_list", "crm_add_to_target_list", "crm_remove_from_target_list"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let model = "crm_TargetLists", links = "TargetsToTargetLists", db = service.db, actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name)
        func visible(_ id: String) throws -> NativeRecord {
            guard let row = try db.page(model, fields: fields, equal: ["id": .text(id)], filter: service.scope(model), limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
        }
        func input() throws -> [String: SQLValue] {
            var result: [String: SQLValue] = [:]
            for key in ["name", "description"] where arguments[key] != nil {
                guard let value = arguments[key] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }; result[key] = .text(value)
            }
            return result
        }
        func projection(_ row: NativeRecord, members: (limit: Int, offset: Int)? = nil) throws -> [String: Any] {
            var result = try NativeMCPWire.record(row, schema: db.schema)
            let page = try db.page(links, fields: [], equal: ["target_list_id": row["id"]], offset: members?.offset ?? 0, sort: "target_id", limit: members?.limit ?? 1)
            result["_count"] = ["targets": page.total]
            if members != nil {
                result["targets"] = try page.rows.map { link -> [String: Any] in
                    var member = try NativeMCPWire.record(link, schema: db.schema)
                    // List membership is the sharing boundary in the original
                    // API: include the linked target even if deleted or owned
                    // by another user. Do not silently change list counts.
                    guard let target = try db.get("crm_Targets", key: ["id": link["target_id"]]) else { throw NativeMCPFailure.internalError }
                    member["target"] = try NativeMCPWire.record(target, schema: db.schema); return member
                }
            }
            return result
        }
        switch name {
        case "crm_list_target_lists":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: fields, filter: service.scope(model), limit: limit, offset: offset, order: [("created_on", true), ("id", true)])
            return ["data": try page.rows.map { try projection($0) }, "total": page.total, "offset": offset]
        case "crm_get_target_list":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            return ["data": try projection(visible(arguments["id"] as! String), members: (limit, offset))]
        case "crm_create_target_list":
            var values = try input(); values["created_by"] = .text(actor)
            return ["data": try NativeMCPWire.record(db.insert(model, values: values, actor: actor), schema: db.schema)]
        case "crm_update_target_list":
            let row = try visible(arguments["id"] as! String)
            return ["data": try NativeMCPWire.record(db.update(row, changes: input(), actor: actor), schema: db.schema)]
        case "crm_delete_target_list":
            let row = try db.setDeleted(visible(arguments["id"] as! String), deleted: true, actor: actor)
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        case "crm_add_to_target_list", "crm_remove_from_target_list":
            let listID = arguments["target_list_id"] as! String, targetIDs = arguments["target_ids"] as! [String]
            _ = try visible(listID)
            if name == "crm_add_to_target_list" {
                let ids = RecordFilter.any(Set(targetIDs).map { .equal("id", .text($0)) })
                let owner: RecordFilter = service.identity.elevated ? .all : .equal("created_by", .text(actor))
                // Source filterAuthorizedTargetIds includes deleted targets and
                // returns each permitted database row once, not each input ID.
                let allowed = try db.page("crm_Targets", fields: [], includeDeleted: true, filter: .every([ids, owner]), limit: 100).rows
                for target in allowed {
                    try Task.checkCancellation()
                    let key = ["target_id": target["id"], "target_list_id": SQLValue.text(listID)]
                    if try db.get(links, key: key) == nil { _ = try db.insert(links, values: key, actor: actor) }
                }
                return ["data": ["target_list_id": listID, "added": allowed.count]]
            }
            for targetID in Set(targetIDs) {
                try Task.checkCancellation()
                if let link = try db.get(links, key: ["target_id": .text(targetID), "target_list_id": .text(listID)]) { try db.remove(link, actor: actor) }
            }
            // This is the source contract, not the physical DELETE row count.
            return ["data": ["target_list_id": listID, "removed": targetIDs.count]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
