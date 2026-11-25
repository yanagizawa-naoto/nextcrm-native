import Foundation
import CoreFoundation

/// MCP contracts retain the original API's inputs, nested item snapshots and
/// projections; UI line recalculation and title trimming do not apply here.
enum NativeMCPContracts {
    static let names: Set<String> = ["crm_list_contracts", "crm_get_contract", "crm_create_contract", "crm_update_contract", "crm_delete_contract"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    private static func money(_ value: Any) throws -> SQLValue {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { throw NativeMCPFailure.internalError }
        // The source accepts JS numbers and PostgreSQL numeric(18,2) rounds
        // them to cents (ties away from zero). Preserve its decimal conversion.
        if number.doubleValue < 0.005 { return .text("0") }
        // Foundation may parse 0.015 as an NSDecimalNumber whose stringValue
        // exposes 0.014999999999999999. Source JSON.parse/Zod use JS Double.
        guard var decimal = Decimal(string: String(number.doubleValue), locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else { throw NativeMCPFailure.internalError }
        var rounded = Decimal(); NSDecimalRound(&rounded, &decimal, 2, .plain)
        guard !rounded.isNaN else { throw NativeMCPFailure.internalError }
        return .text(NSDecimalNumber(decimal: rounded).stringValue)
    }
    private static func date(_ value: Any) throws -> SQLValue {
        guard let text = value as? String, let canonical = NativeMCPWire.canonicalUTC(text) else { throw NativeMCPFailure.internalError }
        return .text(canonical)
    }
    private static func readScope(_ service: CRMService) -> RecordFilter {
        if service.identity.elevated { return .all }
        let own = RecordFilter.any([.equal("assigned_to", .text(service.identity.id)), .equal("createdBy", .text(service.identity.id))])
        // Source contractReadScopeWhere includes ownership through a parent
        // account even when the account itself is soft-deleted.
        return .any([own, .relation(model: "crm_Accounts", local: "account", foreign: "id", matching: service.scope("crm_Accounts"))])
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, model = "crm_Contracts", lineModel = "crm_ContractLineItems", actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name), lineFields = try db.schema.model(lineModel).fields.map(\.name)
        func visible(_ id: String, write: Bool = false) throws -> NativeRecord {
            guard let row = try db.page(model, fields: fields, equal: ["id": .text(id)], filter: write ? service.scope(model, write: true) : readScope(service), limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            return row
        }
        func linkable(_ id: String) throws {
            guard try db.page("crm_Accounts", fields: [], equal: ["id": .text(id)], includeDeleted: true, filter: service.scope("crm_Accounts", write: true), limit: 1).rows.first != nil else { throw NativeMCPFailure.notFound }
        }
        func strings(_ input: [String: Any], _ names: [String]) throws -> [String: SQLValue] {
            var result: [String: SQLValue] = [:]
            for key in names where input[key] != nil {
                guard let value = input[key] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }
                result[key] = .text(value)
            }
            return result
        }
        func contractValues() throws -> [String: SQLValue] {
            var values = try strings(arguments, ["title", "description", "account", "assigned_to", "status", "type", "currency"])
            if let amount = arguments["value"] { values["value"] = try money(amount) }
            for key in ["startDate", "endDate"] { if let value = arguments[key] { values[key] = try date(value) } }
            values["updatedBy"] = .text(actor)
            return values
        }
        func items(_ contract: NativeRecord, sorted: Bool) throws -> [[String: Any]] {
            var result: [[String: Any]] = [], offset = 0
            while true {
                try Task.checkCancellation()
                let rows = try db.page(lineModel, fields: lineFields, equal: ["contractId": contract["id"]], offset: offset, sort: sorted ? "sort_order" : nil, insertionOrderForTies: true).rows
                result += try rows.map { try NativeMCPWire.record($0, schema: db.schema) }
                if rows.count < 100 { return result }; offset += rows.count
            }
        }
        func included(_ contract: NativeRecord, sorted: Bool) throws -> [String: Any] {
            var row = try NativeMCPWire.record(contract, schema: db.schema)
            row["lineItems"] = try items(contract, sorted: sorted)
            // Source includes only id/name even when independent account access
            // is denied. Do not materialize the parent's other scalar fields.
            if contract["account"] != .null, let account = try db.page("crm_Accounts", fields: ["name"], equal: ["id": contract["account"]], includeDeleted: true, limit: 1).rows.first {
                row["assigned_account"] = ["id": account["id"].string, "name": account["name"].json]
            } else { row["assigned_account"] = NSNull() }
            return row
        }
        switch name {
        case "crm_list_contracts":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            var scopes = [readScope(service)]
            for field in ["status", "account"] { if let value = arguments[field] as? String { scopes.append(.equal(field, .text(value))) } }
            let page = try db.mcpPage(model, fields: fields, filter: .every(scopes), limit: limit, offset: offset)
            return ["data": try page.rows.map { try included($0, sorted: false) }, "total": page.total, "offset": offset]
        case "crm_get_contract": return ["data": try included(visible(arguments["id"] as! String), sorted: true)]
        case "crm_create_contract":
            if let account = arguments["account"] as? String { try linkable(account) }
            var values = try contractValues(); values["v"] = .integer(0); values["createdBy"] = .text(actor)
            let row = try db.insert(model, values: values, actor: actor)
            for item in arguments["lineItems"] as? [[String: Any]] ?? [] {
                try Task.checkCancellation()
                var data = try strings(item, ["productId", "name", "sku", "description", "discount_type", "currency"])
                for field in ["unit_price", "discount_value", "line_total"] { data[field] = try money(item[field]!) }
                data["quantity"] = .integer(Int64(try NativeMCPWire.integer(item["quantity"], range: 1...Int(Int32.max))))
                data["sort_order"] = .integer(Int64(try NativeMCPWire.integer(item["sort_order"], range: Int(Int32.min)...Int(Int32.max))))
                data["contractId"] = row["id"]; data["createdBy"] = .text(actor)
                _ = try db.insert(lineModel, values: data, actor: actor)
            }
            var result = try NativeMCPWire.record(row, schema: db.schema); result["lineItems"] = try items(row, sorted: false)
            return ["data": result]
        case "crm_update_contract":
            let current = try visible(arguments["id"] as! String, write: true)
            if let account = arguments["account"] as? String, current["account"] != .text(account) { try linkable(account) }
            return ["data": try NativeMCPWire.record(db.update(current, changes: contractValues(), actor: actor), schema: db.schema)]
        case "crm_delete_contract":
            let row = try db.setDeleted(visible(arguments["id"] as! String, write: true), deleted: true, actor: actor)
            return ["data": ["id": row["id"].string, "status": "DELETED"]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
