import Foundation

enum NativeMCPOpportunities {
    static let names: Set<String> = ["crm_list_opportunity_options", "crm_list_opportunities", "crm_get_opportunity", "crm_search_opportunities", "crm_create_opportunity", "crm_update_opportunity", "crm_delete_opportunity"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    private static let approvalReason = "Quote approval is required before moving this deal to the Qualified stage. Request approval from the deal page first."
    private static func readScope(_ service: CRMService) -> RecordFilter {
        if service.identity.elevated { return .all }
        let owner = RecordFilter.any([.equal("assigned_to", .text(service.identity.id)), .equal("createdBy", .text(service.identity.id))])
        // The original nested account ownership predicate does not exclude a
        // deleted parent. The opportunity itself must always be live.
        return .any([owner, .relation(model: "crm_Accounts", local: "account", foreign: "id", matching: service.scope("crm_Accounts"))])
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let model = "crm_Opportunities", db = service.db, actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name)
        func visible(_ id: String, write: Bool = false) throws -> NativeRecord {
            guard let row = try db.page(model, fields: fields, equal: ["id": .text(id)], filter: write ? service.scope(model, write: true) : readScope(service), limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            return row
        }
        func lookup(_ model: String, id: String) throws -> NativeRecord {
            guard let row = try db.get(model, key: ["id": .text(id)]) else { throw NativeMCPFailure.notFound }; return row
        }
        func options(_ model: String, _ fields: [String]) throws -> [[String: Any]] {
            var result: [[String: Any]] = [], offset = 0
            let schema = try db.schema.model(model)
            while true {
                try Task.checkCancellation()
                let page = try db.mcpPage(model, fields: fields, filter: .all, limit: 100, offset: offset, order: [("order", false), ("name", false)])
                result += try page.rows.map { row in try Dictionary(uniqueKeysWithValues: fields.map { ($0, try NativeMCPWire.value(row[$0], field: schema.field($0)!)) }) }
                if page.rows.count < 100 { return result }; offset += page.rows.count
            }
        }
        func inputValues() throws -> [String: SQLValue] {
            var values: [String: SQLValue] = [:]
            for field in ["name", "description", "currency", "next_step"] where arguments[field] != nil {
                guard let text = arguments[field] as? String, !text.contains("\0") else { throw NativeMCPFailure.internalError }; values[field] = .text(text)
            }
            for field in ["budget", "expected_revenue"] where arguments[field] != nil {
                values[field] = .text(String(try NativeMCPWire.integer(arguments[field], range: 0...9_007_199_254_740_991)))
            }
            if let text = arguments["close_date"] as? String {
                guard let date = NativeMCPWire.canonicalUTC(text) else { throw NativeMCPFailure.internalError }
                values["close_date"] = .text(date)
            }
            for (input, field, table) in [("sales_stage_id", "sales_stage", "crm_Opportunities_Sales_Stages"), ("type_id", "type", "crm_Opportunities_Type")] {
                if let value = arguments[input] {
                    if value is NSNull { values[field] = .null }
                    else { let id = value as! String; _ = try lookup(table, id: id); values[field] = .text(id) }
                }
            }
            return values
        }
        func requireApproved(from: SQLValue, to: SQLValue, approval: SQLValue) throws {
            guard to != .null, to != from, approval != .text("APPROVED") else { return }
            if try lookup("crm_Opportunities_Sales_Stages", id: to.string)["stage_kind"] == .text("qualified") { throw NativeMCPFailure.conflict(approvalReason) }
        }
        func transition(_ row: NativeRecord, from: SQLValue) throws {
            guard row["sales_stage"] != .null, row["sales_stage"] != from else { return }
            _ = try db.update(row, changes: ["stage_entered_at": .text(NativeAPITokens.timestamp(Date()))], actor: actor)
            try db.enqueueOpportunityStageChange(recordID: row["id"].string, toStage: row["sales_stage"].string)
        }
        func audit(_ row: NativeRecord, before: NativeRecord?) throws {
            var values: [String: SQLValue] = ["entityType": .text("opportunity"), "entityId": row["id"], "action": .text(before == nil ? "created" : "updated"), "userId": .text(actor)]
            if let before {
                let old = try NativeMCPWire.record(before, schema: db.schema), new = try NativeMCPWire.record(row, schema: db.schema)
                let hidden: Set<String> = ["updatedAt", "updatedBy", "createdAt", "createdBy", "created_on", "cratedAt", "v", "deletedAt", "deletedBy"]
                var changes: [[String: Any]] = []
                for field in fields where !hidden.contains(field) {
                    let oldValue = old[field] ?? NSNull(), newValue = new[field] ?? NSNull()
                    let left = try JSONSerialization.data(withJSONObject: oldValue, options: [.sortedKeys, .fragmentsAllowed])
                    let right = try JSONSerialization.data(withJSONObject: newValue, options: [.sortedKeys, .fragmentsAllowed])
                    if left != right { changes.append(["field": field, "old": oldValue, "new": newValue]) }
                }
                values["changes"] = .text(String(decoding: try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys]), as: UTF8.self))
            }
            // Source audit-log.ts explicitly makes this additional business
            // history best effort. NativeDatabase's transactional audit remains.
            _ = try? db.transaction { try db.insert("crm_AuditLog", values: values, actor: actor) }
        }
        switch name {
        case "crm_list_opportunity_options":
            return ["data": ["stages": try options("crm_Opportunities_Sales_Stages", ["id", "name", "order", "probability", "stage_kind"]), "types": try options("crm_Opportunities_Type", ["id", "name", "order"])]]
        case "crm_list_opportunities", "crm_search_opportunities":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let page = try db.mcpPage(model, fields: fields, filter: readScope(service), searchFields: ["name", "description"], query: name == "crm_search_opportunities" ? arguments["query"] as? String : nil, limit: limit, offset: offset)
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "crm_get_opportunity": return ["data": try NativeMCPWire.record(visible(arguments["id"] as! String), schema: db.schema)]
        case "crm_create_opportunity":
            var values = try inputValues()
            try requireApproved(from: .null, to: values["sales_stage"] ?? .null, approval: .text("NONE"))
            values.merge(["v": .integer(0), "assigned_to": .text(actor), "createdBy": .text(actor), "updatedBy": .text(actor)]) { _, new in new }
            let row = try db.insert(model, values: values, actor: actor)
            try transition(row, from: .null); try audit(row, before: nil)
            try db.enqueue("crm/opportunity.saved", payload: ["record_id": row["id"].string, "actorID": actor])
            return ["data": try NativeMCPWire.record(row, schema: db.schema)]
        case "crm_update_opportunity":
            let before = try visible(arguments["id"] as! String, write: true)
            // Parent write checks precede option validation, matching the source.
            var relations: [String: SQLValue] = [:]
            for (field, parent) in [("account", "crm_Accounts"), ("contact", "crm_Contacts")] {
                if let value = arguments[field] {
                    if value is NSNull { relations[field] = .null }
                    else {
                        let id = value as! String
                        guard try db.page(parent, fields: [], equal: ["id": .text(id)], filter: service.scope(parent, write: true), limit: 1).rows.first != nil else { throw NativeMCPFailure.notFound }
                        relations[field] = .text(id)
                    }
                }
            }
            if let assigned = arguments["assigned_to"] {
                if assigned is NSNull { relations["assigned_to"] = .null }
                else { let id = assigned as! String; guard try lookup("Users", id: id)["userStatus"] == .text("ACTIVE") else { throw NativeMCPFailure.notFound }; relations["assigned_to"] = .text(id) }
            }
            var values = try inputValues(); values.merge(relations) { _, new in new }
            try requireApproved(from: before["sales_stage"], to: values["sales_stage"] ?? .null, approval: before["approval_status"])
            if let stage = values["sales_stage"], stage != .null, stage != before["sales_stage"] { values["status"] = .text("ACTIVE") }
            values["updatedBy"] = .text(actor)
            let row = try db.update(before, changes: values, actor: actor)
            try transition(row, from: before["sales_stage"]); try audit(row, before: before)
            try db.enqueue("crm/opportunity.saved", payload: ["record_id": row["id"].string, "actorID": actor])
            return ["data": try NativeMCPWire.record(row, schema: db.schema)]
        case "crm_delete_opportunity":
            let row = try db.setDeleted(visible(arguments["id"] as! String, write: true), deleted: true, actor: actor)
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model(model).field("deletedAt")!)]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
