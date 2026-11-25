import Foundation
import CoreFoundation

/// Scalar conversions for the source catalog APIs. These preserve API inputs
/// instead of applying the native editor's naming and business-form rules.
enum NativeMCPCatalogValues {
    static func decimal(_ value: Any, scale: Int) throws -> SQLValue {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw NativeMCPFailure.internalError }
        let d = number.doubleValue
        if abs(d) < pow(10, -Double(scale)) / 2 { return .text("0") }
        guard var exact = Decimal(string: String(d), locale: Locale(identifier: "en_US_POSIX")), !exact.isNaN else { throw NativeMCPFailure.internalError }
        var rounded = Decimal(); NSDecimalRound(&rounded, &exact, scale, .plain)
        guard !rounded.isNaN else { throw NativeMCPFailure.internalError }
        return .text(NSDecimalString(&rounded, Locale(identifier: "en_US_POSIX")))
    }
    static func strings(_ input: [String: Any], fields: [String]) throws -> [String: SQLValue] {
        var result: [String: SQLValue] = [:]
        for name in fields where input[name] != nil {
            guard let value = input[name] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }
            result[name] = .text(value)
        }
        return result
    }
    static func uuid(_ id: String) throws {
        // Several original pricing schemas accept arbitrary strings. Prisma
        // rejects malformed UUID query values before returning a missing row.
        guard UUID(uuidString: id) != nil else { throw NativeMCPFailure.internalError }
    }
    static func rows(_ model: String, db: NativeDatabase, equal: [String: SQLValue] = [:], filter: RecordFilter = .all) throws -> [NativeRecord] {
        let fields = try db.schema.model(model).fields.map(\.name)
        var result: [NativeRecord] = [], offset = 0
        while true {
            try Task.checkCancellation()
            let page = try db.page(model, fields: fields, equal: equal, includeDeleted: true, offset: offset, filter: filter, insertionOrderForTies: true)
            result += page.rows; if page.rows.count < 100 { return result }; offset += page.rows.count
        }
    }
}

enum NativeMCPProducts {
    static let names: Set<String> = ["crm_list_products", "crm_get_product", "crm_create_product", "crm_update_product", "crm_delete_product"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, model = "crm_Products", actor = service.identity.id
        let fields = try db.schema.model(model).fields.map(\.name)
        func visible(_ id: String) throws -> NativeRecord {
            guard let row = try db.get(model, key: ["id": .text(id)]), row["deletedAt"] == .null else { throw NativeMCPFailure.notFound }; return row
        }
        func included(_ row: NativeRecord) throws -> [String: Any] {
            var result = try NativeMCPWire.record(row, schema: db.schema)
            if row["categoryId"] != .null, let category = try db.get("crm_ProductCategories", key: ["id": row["categoryId"]]) { result["category"] = try NativeMCPWire.record(category, schema: db.schema) }
            else { result["category"] = NSNull() }
            return result
        }
        func manage() throws { guard service.identity.elevated else { throw NativeMCPFailure.forbidden } }
        func writable(_ row: NativeRecord) throws {
            // Original assertProductWritable throws AuthorizationError with a
            // descriptive message; run-tool maps this path to INTERNAL_ERROR.
            guard row["source"] != .text("EXTERNAL") else { throw NativeMCPFailure.internalError }
        }
        func values() throws -> [String: SQLValue] {
            var values = try NativeMCPCatalogValues.strings(arguments, fields: ["name", "description", "sku", "type", "status", "currency", "unit", "billing_period", "categoryId"])
            for field in ["unit_price", "unit_cost", "tax_rate"] { if let value = arguments[field] { values[field] = try NativeMCPCatalogValues.decimal(value, scale: 2) } }
            if let recurring = arguments["is_recurring"] as? Bool { values["is_recurring"] = .integer(recurring ? 1 : 0) }
            values["updatedBy"] = .text(actor); return values
        }
        switch name {
        case "crm_list_products":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            let filter: RecordFilter = (arguments["status"] as? String).map { .equal("status", .text($0)) } ?? .all
            let page = try db.mcpPage(model, fields: fields, filter: filter, limit: limit, offset: offset)
            return ["data": try page.rows.map(included), "total": page.total, "offset": offset]
        case "crm_get_product": return ["data": try included(visible(arguments["id"] as! String))]
        case "crm_create_product":
            try manage(); var data = try values(); data["status"] = .text("DRAFT"); data["createdBy"] = .text(actor)
            data["is_recurring"] = data["is_recurring"] ?? .integer(0)
            return ["data": try NativeMCPWire.record(db.insert(model, values: data, actor: actor), schema: db.schema)]
        case "crm_update_product":
            try manage(); let row = try visible(arguments["id"] as! String); try writable(row)
            return ["data": try NativeMCPWire.record(db.update(row, changes: values(), actor: actor), schema: db.schema)]
        case "crm_delete_product":
            try manage(); let row = try visible(arguments["id"] as! String); try writable(row)
            _ = try db.update(row, changes: ["deletedAt": .text(NativeAPITokens.timestamp(Date())), "deletedBy": .text(actor), "status": .text("ARCHIVED")], actor: actor, action: "delete")
            return ["data": ["id": row["id"].string, "status": "ARCHIVED"]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
