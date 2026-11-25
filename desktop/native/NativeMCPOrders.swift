import Foundation

/// MCP order behavior follows the original service. The native editor has
/// stricter input rules, so its save path is intentionally not used here.
enum NativeMCPOrders {
    static let names: Set<String> = ["crm_list_orders", "crm_get_order", "crm_create_order", "crm_update_order", "crm_submit_order", "crm_decide_order_approval", "crm_set_order_status", "crm_cancel_order"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] { makeHandlers(clock: Date.init) }
    static func makeHandlers(clock: @escaping () -> Date) -> [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0, now: clock()) } }) })
    }
    private static let address = ["street", "city", "state", "postal_code", "country"]
    private static let headerKeys = ["contactId", "note"] + address.map { "shipping_" + $0 }
    private static let whitespace = CharacterSet(charactersIn: "\u{9}\u{B}\u{C}\u{20}\u{A0}\u{FEFF}\u{A}\u{D}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}\u{2028}\u{2029}")
    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: whitespace) }
    private static func number(_ text: String) throws -> Decimal {
        if let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN { return value }
        if let value = Double(text), value.isFinite, abs(value) < 1e-128 { return 0 }
        throw NativeMCPFailure.internalError
    }
    private static func fixed(_ value: Decimal) -> String {
        let rounded = PriceDecimal.rounded(value), pieces = PriceDecimal.string(rounded).split(separator: ".", omittingEmptySubsequences: false)
        return (rounded == 0 && value < 0 ? "-" : "") + String(pieces[0]) + "." + (pieces.count > 1 ? String(pieces[1]) : "").padding(toLength: 2, withPad: "0", startingAt: 0)
    }
    private static func readScope(_ service: CRMService) -> RecordFilter {
        if service.identity.elevated { return .all }
        return .any([.equal("ownerId", .text(service.identity.id)), .equal("createdBy", .text(service.identity.id)), .relation(model: "crm_Accounts", local: "accountId", foreign: "id", matching: service.scope("crm_Accounts"))])
    }
    private static func load(_ id: String, service: CRMService) throws -> NativeRecord {
        try NativeMCPCatalogValues.uuid(id)
        guard let row = try service.db.page("crm_Orders", fields: service.db.schema.model("crm_Orders").fields.map(\.name), equal: ["id": .text(id)], filter: readScope(service), limit: 1).rows.first else { throw NativeMCPFailure.notFound }
        return row
    }
    private static func permit(_ order: NativeRecord, _ action: String, service: CRMService) throws {
        guard service.orderCan(order, action) else { throw NativeMCPFailure.forbidden }
    }
    private static func contact(_ raw: Any?, accountID: String, db: NativeDatabase) throws {
        guard let id = raw as? String, !id.isEmpty else { return }
        try NativeMCPCatalogValues.uuid(id)
        guard let row = try db.get("crm_Contacts", key: ["id": .text(id)]) else { throw NativeMCPFailure.notFound }
        guard row["accountsIDs"] == .text(accountID) else { throw NativeMCPFailure.validation("contactNotOnAccount") }
    }
    private static func header(_ arguments: [String: Any]) throws -> [String: SQLValue] {
        var values: [String: SQLValue] = [:]
        for key in headerKeys where arguments[key] != nil {
            if arguments[key] is NSNull { values[key] = .null }
            else if let value = arguments[key] as? String, !value.contains("\0") { let clean = trim(value); values[key] = clean.isEmpty ? .null : .text(clean) }
            else { throw NativeMCPFailure.internalError }
        }
        if let raw = arguments["requestedDeliveryDate"] {
            if raw is NSNull || raw as? String == "" { values["requestedDeliveryDate"] = .null }
            else if let text = raw as? String, let date = NativeMCPPriceDate.parse(String(decoding: Array(text.utf16.prefix(10)), as: UTF16.self) + "T00:00:00Z") { values["requestedDeliveryDate"] = .text(date) }
            else { throw NativeMCPFailure.validation("invalid") }
        }
        return values
    }
    private static func context(_ account: NativeRecord, db: NativeDatabase) throws -> OrderPriceContext {
        var id = account["pricelist_id"] == .null ? nil : account["pricelist_id"].string
        if (id ?? "").isEmpty { id = try db.get("crm_SystemSettings", key: ["key": .text("default_pricelist_id")])?["value"].string }
        if let id, !id.isEmpty {
            try NativeMCPCatalogValues.uuid(id)
            if let list = try db.get("crm_PriceLists", key: ["id": .text(id)]) { return OrderPriceContext(listID: id, currency: list["currency"].string) }
        }
        let code = try db.get("crm_SystemSettings", key: ["key": .text("default_currency")])?["value"].string ?? ""
        return OrderPriceContext(listID: nil, currency: code.isEmpty ? "JPY" : code)
    }
    private static func rate(_ from: String, _ to: String, db: NativeDatabase) throws -> Decimal {
        if from == to { return 1 }
        if let row = try db.page("ExchangeRate", fields: ["rate"], equal: ["fromCurrency": .text(from), "toCurrency": .text(to)], limit: 1).rows.first { return try number(row["rate"].string) }
        if let row = try db.page("ExchangeRate", fields: ["rate"], equal: ["fromCurrency": .text(to), "toCurrency": .text(from)], limit: 1).rows.first { return try PriceDecimal.calculate(1, "/", number(row["rate"].string)) }
        throw NativeMCPFailure.validation("Missing exchange rate " + from + " → " + to)
    }
    private static func quote(_ input: OrderLineInput, context: OrderPriceContext, service: CRMService, now: Date) throws -> OrderLineQuote {
        let db = service.db
        try NativeMCPCatalogValues.uuid(input.productID)
        guard let product = try db.get("crm_Products", key: ["id": .text(input.productID)]), product["deletedAt"] == .null, product["status"] == .text("ACTIVE") else { throw NativeMCPFailure.validation("productInactive") }
        guard let quantityNumber = Double(input.quantity), quantityNumber.isFinite, quantityNumber > 0 else { throw NativeMCPFailure.validation("invalid") }
        var arguments: [String: Any] = ["productId": input.productID, "quantity": quantityNumber, "date": NativeAPITokens.timestamp(now)]
        if let id = context.listID { arguments["priceListId"] = id }
        let raw = try NativeMCPPriceLists.rawPrice(arguments, service: service).result
        let list = PriceDecimal.rounded(try PriceDecimal.calculate(number(raw.price), "*", rate(raw.currency, context.currency, db: db)))
        let price = try input.unitPrice.map { PriceDecimal.rounded(try number($0)) } ?? list
        guard price >= 0 else { throw NativeMCPFailure.validation("invalid") }
        let quantity = try number(input.quantity), vat = try number(product["tax_rate"] == .null ? "0" : product["tax_rate"].string)
        let net = PriceDecimal.rounded(try PriceDecimal.calculate(quantity, "*", price))
        let tax = PriceDecimal.rounded(try PriceDecimal.calculate(PriceDecimal.calculate(net, "*", vat), "/", 100))
        return OrderLineQuote(productId: input.productID, productName: product["name"].string, sku: product["sku"] == .null ? nil : product["sku"].string, unit: product["unit"] == .null ? nil : product["unit"].string,
                              quantity: PriceDecimal.string(PriceDecimal.rounded(quantity, scale: 4)), listPrice: PriceDecimal.string(list), priceRuleId: raw.ruleId, unitPrice: PriceDecimal.string(price), unitPriceOverridden: input.unitPrice != nil,
                              vatRate: PriceDecimal.string(vat), lineSubtotal: PriceDecimal.string(net), lineVat: PriceDecimal.string(tax), lineTotal: PriceDecimal.string(PriceDecimal.rounded(try PriceDecimal.calculate(net, "+", tax))))
    }
    private static func input(_ value: Any) throws -> OrderLineInput {
        guard let row = value as? [String: Any], let id = row["productId"] as? String, let quantity = row["quantity"] as? NSNumber else { throw NativeMCPFailure.internalError }
        return OrderLineInput(productID: id, quantity: String(quantity.doubleValue), unitPrice: (row["unitPrice"] as? NSNumber).map { String($0.doubleValue) })
    }
    private static func batch(context: OrderPriceContext, service: CRMService, now: Date, inputs: (Int) throws -> [OrderLineInput]) throws -> (OrderDraftStore, OrderTotals) {
        let buffer = try OrderDraftStore(); var offset = 0, totals = OrderTotals()
        while true {
            try Task.checkCancellation(); let page = try inputs(offset)
            for line in page { try autoreleasepool { let priced = try quote(line, context: context, service: service, now: now); try buffer.save(input: priced.input, quote: priced); try totals.add(priced) } }
            offset += page.count; if page.count < 100 { break }
        }
        return (buffer, totals)
    }
    private static func replaceLines(_ order: NativeRecord, buffer: OrderDraftStore, service: CRMService) throws {
        let db = service.db
        while true {
            let page = try db.page("crm_OrderLines", fields: [], equal: ["orderId": order["id"]])
            if page.rows.isEmpty { break }; for row in page.rows { try db.remove(row, actor: service.identity.id, action: "replace") }
        }
        var offset = 0
        while true {
            let page = try buffer.page(offset: offset)
            for (i, row) in page.enumerated() { var values = row.quote.values; values["orderId"] = order["id"]; values["position"] = .integer(Int64(offset + i)); _ = try db.insert("crm_OrderLines", values: values, actor: service.identity.id) }
            offset += page.count; if page.count < 100 { break }
        }
    }
    private static func audit(_ order: NativeRecord, action: String, changes: [[String: Any]]? = nil, service: CRMService) throws {
        var values: [String: SQLValue] = ["entityType": .text("order"), "entityId": order["id"], "action": .text(action), "userId": .text(service.identity.id)]
        if let changes { values["changes"] = .text(String(decoding: try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys]), as: UTF8.self)) }
        _ = try? service.db.insert("crm_AuditLog", values: values, actor: service.identity.id)
    }
    private static func statusAudit(_ before: NativeRecord, _ after: NativeRecord, decision: String? = nil, service: CRMService) throws {
        var change: [String: Any] = ["field": "status", "old": before["status"].string, "new": after["status"].string]
        if let decision { change["decision"] = decision }; try audit(after, action: "updated", changes: [change], service: service)
    }
    private static func notify(_ order: NativeRecord, decision: String? = nil, note: String? = nil, service: CRMService, now: Date) throws {
        let db = service.db
        guard try db.get("crm_SystemSettings", key: ["key": .text("orders_approval_emails")])?["value"] != .text("false") else { return }
        let filter: RecordFilter = decision == nil ? .every([.equal("userStatus", .text("ACTIVE")), .any([.equal("role", .text("admin")), .equal("role", .text("manager"))])]) : .equal("id", order["createdBy"])
        var offset = 0
        while true {
            let page = try db.page("Users", fields: ["email"], offset: offset, filter: filter)
            for user in page.rows where !user["email"].string.isEmpty {
                try db.enqueue(decision == nil ? "orders.approval_requested" : "orders.approval_decided", payload: ["orderId": order["id"].string, "number": order["number"].string, "recipientId": user["id"].string, "recipientEmail": user["email"].string, "actorId": service.identity.id, "requestedAt": order["approvalRequestedAt"].string, "requestRevision": String(order.revision), "decision": decision ?? "", "note": note ?? ""], now: now)
            }
            offset += page.rows.count; if page.rows.count < 100 { break }
        }
    }
    private static func serialized(_ order: NativeRecord, detail: Bool, service: CRMService) throws -> [String: Any] {
        let db = service.db
        func nullable(_ name: String) -> Any { order[name] == .null ? NSNull() : order[name].string }
        func date(_ name: String) throws -> Any { try NativeMCPWire.value(order[name], field: db.schema.model("crm_Orders").field(name)!) }
        func relationName(_ model: String, _ id: SQLValue) throws -> Any { if id == .null { return NSNull() }; return try db.get(model, key: ["id": id])?["name"].string as Any? ?? NSNull() }
        var result: [String: Any] = [:]
        for key in ["id", "number", "status", "source", "externalRef", "accountId", "contactId", "ownerId", "priceListId", "currency", "note", "approvedBy", "approvalNote", "createdBy"] + address.map({ "shipping_" + $0 }) { result[key] = nullable(key) }
        result["accountName"] = try relationName("crm_Accounts", order["accountId"]); result["ownerName"] = try relationName("Users", order["ownerId"])
        result["priceListName"] = detail ? try relationName("crm_PriceLists", order["priceListId"]) : NSNull()
        for key in ["approvalRequestedAt", "approvedAt", "createdAt", "updatedAt"] { result[key] = try date(key) }
        for key in ["orderDate", "requestedDeliveryDate"] { result[key] = (try date(key) as? String).map { String($0.prefix(10)) } as Any? ?? NSNull() }
        for key in ["subtotal", "vatTotal", "grandTotal"] { result[key] = try fixed(number(order[key].string)) }
        var lines: [[String: Any]] = [], reduction = Decimal(0), offset = 0
        if detail {
            while true {
                let page = try db.mcpPage("crm_OrderLines", fields: db.schema.model("crm_OrderLines").fields.map(\.name), filter: .equal("orderId", order["id"]), limit: 100, offset: offset, order: [("position", false)])
                for row in page.rows {
                    var value: [String: Any] = [:]
                    for key in ["id", "productId", "productName", "sku", "unit"] { value[key] = row[key] == .null ? NSNull() : row[key].string }
                    value["position"] = Int(row["position"].string)!; value["quantity"] = try NativeMCPWire.value(row["quantity"], field: db.schema.model("crm_OrderLines").field("quantity")!)
                    value["unitPriceOverridden"] = row["unitPriceOverridden"] == .integer(1)
                    for key in ["listPrice", "unitPrice", "vatRate", "lineSubtotal", "lineVat", "lineTotal"] { value[key] = try fixed(number(row[key].string)) }
                    let list = try number(row["listPrice"].string), price = try number(row["unitPrice"].string)
                    value["belowList"] = price < list
                    value["discountPercent"] = list == 0 ? NSNull() : try fixed(PriceDecimal.rounded(PriceDecimal.calculate(PriceDecimal.calculate(1, "-", PriceDecimal.calculate(price, "/", list)), "*", 100)))
                    let amount = try PriceDecimal.calculate(PriceDecimal.calculate(list, "-", price), "*", number(row["quantity"].string))
                    reduction = try PriceDecimal.calculate(reduction, "+", max(amount, 0)); lines.append(value)
                }
                offset += page.rows.count; if page.rows.count < 100 { break }
            }
            result["allowedActions"] = OrderWorkflow.actions.filter { service.orderCan(order, $0) }; result["nextStatuses"] = OrderWorkflow.next(order["status"].string)
        }
        result["lines"] = lines; result["belowListTotal"] = fixed(reduction); return result
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService, now: Date = Date()) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        return try service.db.transaction {
            let db = service.db, actor = service.identity.id
            if name == "crm_list_orders" {
                let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
                var filters = [readScope(service)]
                for key in ["status", "accountId", "ownerId"] { if let value = arguments[key] as? String, !value.isEmpty { if key != "status" { try NativeMCPCatalogValues.uuid(value) }; filters.append(.equal(key, .text(value))) } }
                let page = try db.mcpPage("crm_Orders", fields: db.schema.model("crm_Orders").fields.map(\.name), filter: .every(filters), limit: limit, offset: offset, order: [("createdAt", true), ("id", true)])
                return ["data": try page.rows.map { try serialized($0, detail: false, service: service) }, "total": page.total, "offset": offset]
            }
            if name == "crm_create_order" {
                let accountID = arguments["accountId"] as! String; try NativeMCPCatalogValues.uuid(accountID)
                do { try service.assertAccess("crm_Accounts", id: accountID, write: true) } catch { throw NativeMCPFailure.notFound }
                guard let account = try db.get("crm_Accounts", key: ["id": .text(accountID)]), account["deletedAt"] == .null else { throw NativeMCPFailure.notFound }
                try contact(arguments["contactId"], accountID: accountID, db: db)
                let context = try context(account, db: db), raw = arguments["lines"] as! [Any]
                let (buffer, totals) = try batch(context: context, service: service, now: now) { offset in try raw.dropFirst(offset).prefix(100).map(input) }
                var values = try header(arguments)
                let shipping = address.contains { !account["shipping_" + $0].string.isEmpty }
                for key in address { let name = "shipping_" + key; if let supplied = arguments[name] { values[name] = (supplied as? String).flatMap { $0.isEmpty ? nil : SQLValue.text($0) } ?? .null } else { values[name] = account[(shipping ? "shipping_" : "billing_") + key] } }
                guard let series = try db.page("NumberSeries", fields: db.schema.model("NumberSeries").fields.map(\.name), equal: ["scope": .text("order"), "isDefault": .integer(1), "active": .integer(1)], sort: "createdAt", insertionOrderForTies: true).rows.first else { throw NativeMCPFailure.validation("noSeries") }
                let year = OrderNumber.year(now), reset = series["resetPolicy"] == .text("YEARLY") && series["currentYear"] != .integer(Int64(year)), count = reset ? 1 : (Int64(series["counter"].string)! + 1)
                guard count <= Int32.max else { throw NativeMCPFailure.internalError }
                _ = try db.update(series, changes: ["counter": .integer(count), "currentYear": .integer(Int64(year))], actor: actor, action: "allocate")
                let number = OrderNumber.format(series["template"].string, year: year, counter: count)
                guard try db.page("crm_Orders", fields: [], equal: ["number": .text(number)]).total == 0 else { throw NativeMCPFailure.validation("numberTaken") }
                values.merge(try totals.values()) { _, new in new }
                values.merge(["number": .text(number), "seriesId": series["id"], "accountId": account["id"], "ownerId": account["assigned_to"], "priceListId": context.listID.map(SQLValue.text) ?? .null, "currency": .text(context.currency), "createdBy": .text(actor), "updatedBy": .text(actor), "orderDate": .text(String(NativeAPITokens.timestamp(now).prefix(10)) + "T00:00:00.000Z")]) { _, new in new }
                let order = try db.insert("crm_Orders", values: values, actor: actor); try replaceLines(order, buffer: buffer, service: service); try audit(order, action: "created", service: service)
                return ["data": ["id": order["id"].string, "number": number]]
            }
            let order = try load(arguments["id"] as! String, service: service)
            if name == "crm_get_order" { return ["data": try serialized(order, detail: true, service: service)] }
            if name == "crm_update_order" || name == "crm_submit_order" {
                let submit = name == "crm_submit_order"; try permit(order, submit ? "submit" : "edit", service: service)
                let count = try db.page("crm_OrderLines", fields: [], equal: ["orderId": order["id"]]).total
                if submit && count == 0 { throw NativeMCPFailure.validation("noLines") }
                if !submit { try contact(arguments["contactId"], accountID: order["accountId"].string, db: db) }
                var values = submit ? [:] : try header(arguments), headerFields = values
                let raw = arguments["lines"] as? [Any] ?? []
                let (buffer, totals) = try batch(context: service.orderContext(order), service: service, now: now) { offset in
                    if !submit { return try raw.dropFirst(offset).prefix(100).map(input) }
                    return try db.mcpPage("crm_OrderLines", fields: db.schema.model("crm_OrderLines").fields.map(\.name), filter: .equal("orderId", order["id"]), limit: 100, offset: offset, order: [("position", false)]).rows.map { OrderLineQuote.from($0).input }
                }
                values.merge(try totals.values()) { _, new in new }; values["updatedBy"] = .text(actor)
                let pending = submit && service.identity.role == "user" && totals.belowList
                if submit { values["status"] = .text(pending ? "PENDING_APPROVAL" : "READY"); if pending { values["approvalRequestedAt"] = .text(NativeAPITokens.timestamp(now)) } }
                let updated = try db.update(order, changes: values, actor: actor); try replaceLines(updated, buffer: buffer, service: service)
                if submit { try statusAudit(order, updated, service: service); if pending { try notify(updated, service: service, now: now) }; return ["data": ["status": updated["status"].string]] }
                var changes: [[String: Any]] = []
                for key in headerKeys + ["requestedDeliveryDate"] { if let value = headerFields[key], value != order[key] { let field = try db.schema.model("crm_Orders").field(key)!; changes.append(["field": key, "old": try NativeMCPWire.value(order[key], field: field), "new": try NativeMCPWire.value(value, field: field)]) } }
                changes.append(["field": "lines", "old": count, "new": totals.count]); try audit(updated, action: "updated", changes: changes, service: service)
                return ["data": ["id": order["id"].string]]
            }
            var changes: [String: SQLValue] = ["updatedBy": .text(actor)]
            if name == "crm_decide_order_approval" {
                let decision = arguments["decision"] as! String; try permit(order, decision == "APPROVED" ? "approve" : "reject", service: service)
                if let seen = arguments["updatedAt"] as? String, !seen.isEmpty {
                    let expected = try NativeMCPWire.value(order["updatedAt"], field: db.schema.model("crm_Orders").field("updatedAt")!) as! String
                    guard let parsed = NativeMCPPriceDate.parse(seen), parsed == expected else { throw NativeMCPFailure.conflict("the order changed") }
                }
                let text = trim(arguments["note"] as? String ?? "")
                if decision == "REJECTED" && text.isEmpty { throw NativeMCPFailure.validation("noteRequired") }
                changes["approvalNote"] = text.isEmpty ? .null : .text(text)
                if decision == "APPROVED" { changes.merge(["status": .text("READY"), "approvedBy": .text(actor), "approvedAt": .text(NativeAPITokens.timestamp(now))]) { _, new in new } }
                else { changes["status"] = .text("DRAFT"); changes["approvalRequestedAt"] = .null }
                let updated = try db.update(order, changes: changes, actor: actor); try statusAudit(order, updated, decision: decision, service: service); try notify(updated, decision: decision, note: text, service: service, now: now)
                return ["data": ["status": updated["status"].string]]
            }
            guard name == "crm_set_order_status" || name == "crm_cancel_order" else { throw NativeMCPFailure.internalError }
            let action = name == "crm_cancel_order" ? "cancel" : arguments["action"] as! String; try permit(order, action, service: service)
            switch action {
            case "withdraw": changes["status"] = .text("DRAFT"); changes["approvalRequestedAt"] = .null
            case "reopen": changes.merge(["status": .text("DRAFT"), "approvalRequestedAt": .null, "approvedBy": .null, "approvedAt": .null]) { _, new in new }
            case "cancel": changes["status"] = .text("CANCELLED")
            case "retry": changes["status"] = .text("READY")
            case "advance": guard let to = arguments["to"] as? String, OrderWorkflow.next(order["status"].string).contains(to) else { throw NativeMCPFailure.forbidden }; changes["status"] = .text(to)
            default: throw NativeMCPFailure.internalError
            }
            let updated = try db.update(order, changes: changes, actor: actor); try statusAudit(order, updated, service: service)
            return ["data": ["status": updated["status"].string]]
        }
    }
}
