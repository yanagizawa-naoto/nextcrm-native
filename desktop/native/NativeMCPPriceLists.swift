import Foundation

/// Date strings in the original pricing APIs pass through JavaScript Date,
/// unlike the strict Zod datetime fields elsewhere. ISO/date-only/offset and
/// common V8 legacy inputs are handled without a JavaScript runtime.
enum NativeMCPPriceDate {
    private static let iso = try! NSRegularExpression(pattern: #"^([0-9]{4}|[+-][0-9]{6})(?:-([0-9]{2})(?:-([0-9]{2}))?)?(?:[Tt]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?([Zz]|[+-][0-9]{2}:?[0-9]{2})?)?$"#)
    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : (a - b + 1) / b }
    private static func days(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let year = y - (m <= 2 ? 1 : 0), era = floorDiv(year, 400), yoe = year - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        return era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
    }
    private static func civil(_ day: Int64) -> (Int64, Int64, Int64) {
        let z = day + 719468, era = floorDiv(z, 146097), doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365, y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1, m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
    private static func canonical(_ milliseconds: Int64) -> String? {
        guard abs(milliseconds) <= 8_640_000_000_000_000 else { return nil }
        let day = floorDiv(milliseconds, 86_400_000), remainder = milliseconds - day * 86_400_000
        let (y, m, d) = civil(day)
        let year = (0...9999).contains(y) ? String(format: "%04lld", y) : (y < 0 ? "-" : "+") + String(format: "%06lld", abs(y))
        return year + String(format: "-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ", m, d, remainder / 3_600_000, remainder / 60_000 % 60, remainder / 1000 % 60, remainder % 1000)
    }
    private static func instant(year: Int64, month: Int64, day: Int64, hour: Int64 = 0, minute: Int64 = 0, second: Int64 = 0, millisecond: Int64 = 0, offset: Int64?) -> String? {
        guard (1...12).contains(month), (1...31).contains(day), (0...24).contains(hour), (0...59).contains(minute), (0...59).contains(second), hour != 24 || minute == 0 && second == 0 && millisecond == 0 else { return nil }
        let local = days(year, month, day) * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + millisecond
        if let offset { return canonical(local - offset * 1000) }
        // JS legacy dates / ISO datetimes without a zone use the host timezone.
        // Resolve ordinary offsets and DST ambiguity/gaps deterministically.
        let zone = TimeZone.current
        func zoneOffset(_ ms: Int64) -> Int64 { Int64(zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(ms) / 1000))) }
        let candidates = Set([-86_400_000, 0, 86_400_000].map { local - zoneOffset(local + Int64($0)) * 1000 })
        let valid = candidates.filter { $0 + zoneOffset($0) * 1000 == local }
        return canonical(valid.min() ?? candidates.max()!)
    }
    static func parse(_ text: String) -> String? {
        let text = String(text.prefix { $0 != "\0" })
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = iso.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) {
            func part(_ i: Int) -> String? { Range(match.range(at: i), in: trimmed).map { String(trimmed[$0]) } }
            guard let yearText = part(1), yearText != "-000000", let year = Int64(yearText) else { return nil }
            let month = Int64(part(2) ?? "1")!, day = Int64(part(3) ?? "1")!, hasTime = part(4) != nil
            if hasTime && (part(2) == nil || part(3) == nil) { return nil }
            // Spaces around a legacy date-only string cause V8 to use local time.
            if trimmed != text && hasTime { return nil }
            var offset: Int64? = !hasTime && trimmed == text ? 0 : nil
            if let zone = part(8) {
                if zone.uppercased() == "Z" { offset = 0 }
                else {
                    let digits = zone.dropFirst().replacingOccurrences(of: ":", with: ""), h = Int64(digits.prefix(2))!, m = Int64(digits.suffix(2))!
                    guard h <= 23, m <= 59 else { return nil }; offset = (h * 60 + m) * 60 * (zone.hasPrefix("-") ? -1 : 1)
                }
            }
            let fraction = String((part(7) ?? "").prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            return instant(year: year, month: month, day: day, hour: Int64(part(4) ?? "0")!, minute: Int64(part(5) ?? "0")!, second: Int64(part(6) ?? "0")!, millisecond: Int64(fraction)!, offset: offset)
        }
        // V8's numeric legacy forms, including 0 -> January 2000.
        if !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int64(trimmed), trimmed.count < 4 {
            if number == 0 { return instant(year: 2000, month: 1, day: 1, offset: nil) }
            if number <= 12 { return instant(year: 2001, month: number, day: 1, offset: nil) }
            if number <= 31 { return nil }
            return instant(year: number < 50 ? 2000 + number : number < 100 ? 1900 + number : number, month: 1, day: 1, offset: nil)
        }
        // V8's non-padded numeric dates are local, while the exact ISO
        // YYYY-MM-DD form above is UTC. Avoid Gregorian cutover formatting.
        let legacy = try! NSRegularExpression(pattern: #"^([0-9]{1,6})[-/]([0-9]{1,2})(?:[-/]([0-9]{1,6}))?(?: ([0-9]{1,2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?)?(?: ?(Z|GMT|UTC)([+-][0-9]{2}:?[0-9]{2})?)?$"#, options: .caseInsensitive)
        if let match = legacy.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)) {
            func part(_ i: Int) -> String? { Range(match.range(at: i), in: trimmed).map { String(trimmed[$0]) } }
            let first = Int64(part(1)!)!, second = Int64(part(2)!)!, third = part(3).flatMap(Int64.init)
            let yearFirst = part(1)!.count >= 3 || first > 31
            let rawYear = yearFirst ? first : third ?? 2001, year = rawYear < 50 ? rawYear + 2000 : rawYear < 100 ? rawYear + 1900 : rawYear
            var offset: Int64? = part(8) == nil ? nil : 0
            if let raw = part(9) { let digits = raw.dropFirst().replacingOccurrences(of: ":", with: ""), h = Int64(digits.prefix(2))!, m = Int64(digits.suffix(2))!; guard h <= 23, m <= 59 else { return nil }; offset = (h * 60 + m) * 60 * (raw.hasPrefix("-") ? -1 : 1) }
            let fraction = String((part(7) ?? "").prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            return instant(year: year, month: yearFirst ? second : first, day: yearFirst ? third ?? 1 : second, hour: Int64(part(4) ?? "0")!, minute: Int64(part(5) ?? "0")!, second: Int64(part(6) ?? "0")!, millisecond: Int64(fraction)!, offset: offset)
        }
        // Locale-independent English RFC/legacy formats used by V8.
        let formats = ["MM/dd/yyyy", "yyyy/MM/dd", "MMM d, yyyy", "MMM d yyyy", "MMMM d, yyyy", "MMMM d yyyy", "d MMM yyyy", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE MMM dd yyyy HH:mm:ss 'GMT'Z"]
        for format in formats {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
            formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = format; formatter.isLenient = false
            if let date = formatter.date(from: trimmed) { return canonical(Int64((date.timeIntervalSince1970 * 1000).rounded(.towardZero))) }
        }
        return nil
    }
}

/// Original MCP price-list semantics with bounded list traversal and paged rule
/// reads; monetary arithmetic is shared with the native line-item price engine.
enum NativeMCPPriceLists {
    static let names: Set<String> = ["crm_list_price_lists", "crm_get_price_list", "crm_get_price", "crm_create_price_list", "crm_update_price_list", "crm_archive_price_list", "crm_upsert_price_list_rule", "crm_delete_price_list_rule"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } }) })
    }
    private static func rule(_ row: NativeRecord) -> PricingEngine.Rule {
        func optional(_ key: String) -> String? { row[key] == .null ? nil : row[key].string }
        return PricingEngine.Rule(id: row["id"].string, appliesTo: row["appliesTo"].string, categoryId: optional("categoryId"), productId: optional("productId"), minQuantity: row["minQuantity"].string, dateStart: optional("dateStart"), dateEnd: optional("dateEnd"), computePrice: row["computePrice"].string, fixedPrice: optional("fixedPrice"), percentPrice: optional("percentPrice"), base: row["base"].string, basePriceListId: optional("basePriceListId"), priceDiscount: row["priceDiscount"].string, priceSurcharge: row["priceSurcharge"].string, priceRound: optional("priceRound"), priceMinMargin: optional("priceMinMargin"), priceMaxMargin: optional("priceMaxMargin"), createdAt: row["createdAt"].string)
    }
    private static func fixed(_ text: String) throws -> String {
        let value = try PriceDecimal.parse(text); var rounded = PriceDecimal.rounded(value)
        let raw = NSDecimalString(&rounded, Locale(identifier: "en_US_POSIX")), pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        return (rounded == 0 && value < 0 ? "-" : "") + String(pieces[0]) + "." + (pieces.count > 1 ? String(pieces[1]) : "").padding(toLength: 2, withPad: "0", startingAt: 0)
    }
    /// Shared unrounded pricing boundary for authorized API transactions.
    /// Orders convert this result to their stored currency before final rounding.
    static func rawPrice(_ arguments: [String: Any], service: CRMService) throws -> (result: PricingEngine.Result, listID: String?) {
        let db = service.db, productID = arguments["productId"] as! String
        var listID = arguments["priceListId"] as? String
        if (listID ?? "").isEmpty, let accountID = arguments["accountId"] as? String, !accountID.isEmpty {
            try NativeMCPCatalogValues.uuid(accountID)
            guard let account = try db.page("crm_Accounts", fields: ["pricelist_id"], equal: ["id": .text(accountID)], filter: service.scope("crm_Accounts"), limit: 1).rows.first else { throw NativeMCPFailure.notFound }
            listID = account["pricelist_id"] == .null ? nil : account["pricelist_id"].string
            if (listID ?? "").isEmpty { listID = try db.get("crm_SystemSettings", key: ["key": .text("default_pricelist_id")])?["value"].string; if listID == "" { listID = nil } }
        }
        try NativeMCPCatalogValues.uuid(productID)
        guard let row = try db.get("crm_Products", key: ["id": .text(productID)]), row["deletedAt"] == .null else { throw NativeMCPFailure.validation("Product not found: " + productID) }
        let product = PricingEngine.Product(id: productID, unitPrice: row["unit_price"].string, unitCost: row["unit_cost"] == .null ? nil : row["unit_cost"].string, currency: row["currency"].string, categoryId: row["categoryId"] == .null ? nil : row["categoryId"].string)
        let number = (arguments["quantity"] as! NSNumber).doubleValue
        // Thresholds have at most ten integer / four fractional digits. Values
        // outside Decimal's exponent range still have an exact comparison here.
        let quantity = number >= 10_000_000_000 ? Decimal(10_000_000_000) : number < 0.0001 ? Decimal(0) : Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))!
        let dateText = arguments["date"] as? String ?? "", date = dateText.isEmpty ? NativeAPITokens.timestamp(Date()) : NativeMCPPriceDate.parse(dateText)
        var chain: [String] = [], categoryID = product.categoryId
        while let id = categoryID, chain.count < 20, !chain.contains(id) {
            chain.append(id); let parent = try db.get("crm_ProductCategories", key: ["id": .text(id)])?["parentId"]
            categoryID = parent == nil || parent == .null ? nil : parent!.string
        }
        func day(_ text: String) throws -> String {
            guard let canonical = NativeMCPPriceDate.parse(text) else { throw NativeMCPFailure.internalError }; return String(canonical.prefix(10))
        }
        func applicable(_ r: PricingEngine.Rule) throws -> Bool {
            guard r.appliesTo == "ALL" || r.appliesTo == "PRODUCT" && r.productId == productID || r.appliesTo == "CATEGORY" && chain.contains(r.categoryId ?? ""), try PriceDecimal.parse(r.minQuantity) <= quantity else { return false }
            guard let date else { return false }; let today = String(date.prefix(10))
            if let start = r.dateStart, try day(start) > today { return false }
            if let end = r.dateEnd, try day(end) < today { return false }; return true
        }
        func precedes(_ a: PricingEngine.Rule, _ b: PricingEngine.Rule) throws -> Bool {
            let ranks = ["PRODUCT": 0, "CATEGORY": 1, "ALL": 2], ar = ranks[a.appliesTo]!, br = ranks[b.appliesTo]!
            if ar != br { return ar < br }
            let aq = try PriceDecimal.parse(a.minQuantity), bq = try PriceDecimal.parse(b.minQuantity); if aq != bq { return aq > bq }
            let ad = chain.firstIndex(of: a.categoryId ?? "") ?? -1, bd = chain.firstIndex(of: b.categoryId ?? "") ?? -1
            if a.appliesTo == "CATEGORY", ad != bd { return ad < bd }
            let at = NativeMCPPriceDate.parse(a.createdAt) ?? a.createdAt, bt = NativeMCPPriceDate.parse(b.createdAt) ?? b.createdAt
            return at == bt ? a.id > b.id : at > bt
        }
        var lists: [String: (currency: String, rule: PricingEngine.Rule?)] = [:], queue = (listID ?? "").isEmpty ? [] : [listID!], queued = Set([listID].compactMap { $0 }), head = 0
        // Foreign keys guarantee each queued base exists. Eleven distinct IDs
        // reproduce source BFS while bounding pending work even for huge lists.
        while head < queue.count && lists.count < 11 {
            try Task.checkCancellation(); let id = queue[head]; head += 1
            if lists[id] != nil { continue }; try NativeMCPCatalogValues.uuid(id)
            guard let list = try db.get("crm_PriceLists", key: ["id": .text(id)]) else { continue }
            var winner: PricingEngine.Rule?, offset = 0
            while true {
                let page = try db.page("crm_PriceListRules", fields: db.schema.model("crm_PriceListRules").fields.map(\.name), equal: ["priceListId": .text(id)], offset: offset, insertionOrderForTies: true)
                for row in page.rows {
                    let candidate = rule(row)
                    if try applicable(candidate), try winner.map({ try precedes(candidate, $0) }) ?? true { winner = candidate }
                    if candidate.base == "PRICE_LIST", let baseID = candidate.basePriceListId, !baseID.isEmpty, lists[baseID] == nil, queue.count < 11, queued.insert(baseID).inserted { queue.append(baseID) }
                }
                if page.rows.count < 100 { break }; offset += page.rows.count
            }
            lists[id] = (list["currency"].string, winner)
        }
        func rate(_ from: String, _ to: String) throws -> Decimal {
            if from == to { return 1 }
            if let direct = try db.page("ExchangeRate", fields: ["rate"], equal: ["fromCurrency": .text(from), "toCurrency": .text(to)], limit: 1).rows.first { return try PriceDecimal.parse(direct["rate"].string) }
            if let inverse = try db.page("ExchangeRate", fields: ["rate"], equal: ["fromCurrency": .text(to), "toCurrency": .text(from)], limit: 1).rows.first { return try PriceDecimal.calculate(1, "/", PriceDecimal.parse(inverse["rate"].string)) }
            throw NativeMCPFailure.validation("Missing exchange rate " + from + " → " + to)
        }
        let result = try PricingEngine.compute(product: product, listID: (listID ?? "").isEmpty ? nil : listID, quantity: quantity, date: date ?? "", resolve: { id in
            guard let list = lists[id] else { throw NativeMCPFailure.validation("Price list not found: " + id) }
            _ = try rate(product.currency, list.currency) // source converts before date validation
            guard date != nil else { throw NativeMCPFailure.internalError }; return list
        }, rate: rate, depthFailure: { NativeMCPFailure.validation("Price list chain too deep at " + $0) })
        return (result, listID)
    }
    private static func price(_ arguments: [String: Any], service: CRMService) throws -> Any {
        let (result, listID) = try rawPrice(arguments, service: service)
        return ["data": ["price": try fixed(result.price), "listPrice": try fixed(result.listPrice), "currency": result.currency, "ruleId": result.ruleId as Any? ?? NSNull(), "priceListId": listID as Any? ?? NSNull(), "steps": try result.steps.map { ["label": $0.label, "value": try fixed($0.value)] }]]
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, actor = service.identity.id, model = "crm_PriceLists", ruleModel = "crm_PriceListRules"
        func get(_ model: String, _ id: String) throws -> NativeRecord { try NativeMCPCatalogValues.uuid(id); guard let row = try db.get(model, key: ["id": .text(id)]) else { throw NativeMCPFailure.notFound }; return row }
        func writable(_ id: String?) throws -> NativeRecord? {
            let row = try id.flatMap { $0.isEmpty ? nil : try get(model, $0) }
            guard service.identity.elevated, row?["source"] != .text("EXTERNAL") else { throw NativeMCPFailure.forbidden }; return row
        }
        func currency(_ code: String) throws { guard try db.get("Currency", key: ["code": .text(code)])?["isEnabled"] == .integer(1) else { throw NativeMCPFailure.validation("currency is not enabled") } }
        func audit(_ type: String, _ id: String, _ action: String) {
            // The source audit service is best-effort. Native DB history remains
            // mandatory and transactional independently of this business log.
            _ = try? db.insert("crm_AuditLog", values: ["entityType": .text(type), "entityId": .text(id), "action": .text(action), "userId": .text(actor)], actor: actor)
        }
        func response(_ row: NativeRecord) throws -> Any { ["data": try NativeMCPWire.record(row, schema: db.schema)] }
        switch name {
        case "crm_list_price_lists":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            var filters: [RecordFilter] = []; if arguments["includeArchived"] as? Bool != true { filters.append(.equal("isActive", .integer(1))) }; if let source = arguments["source"] as? String { filters.append(.equal("source", .text(source))) }
            let page = try db.mcpPage(model, fields: db.schema.model(model).fields.map(\.name), filter: .every(filters), limit: limit, offset: offset, order: [("name", false), ("id", false)])
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "crm_get_price_list":
            let row = try get(model, arguments["id"] as! String); var data = try NativeMCPWire.record(row, schema: db.schema)
            data["rules"] = try NativeMCPCatalogValues.rows(ruleModel, db: db, equal: ["priceListId": row["id"]]).map { try NativeMCPWire.record($0, schema: db.schema) }; return ["data": data]
        case "crm_get_price": return try price(arguments, service: service)
        case "crm_create_price_list":
            _ = try writable(nil); try currency(arguments["currency"] as! String)
            var data = try NativeMCPCatalogValues.strings(arguments, fields: ["name", "currency"]); data["createdBy"] = .text(actor); data["updatedBy"] = .text(actor)
            let row = try db.insert(model, values: data, actor: actor); audit("price_list", row["id"].string, "created"); return try response(row)
        case "crm_update_price_list", "crm_archive_price_list":
            let id = arguments["id"] as! String, existing = try writable(id)
            if let code = arguments["currency"] as? String { try currency(code) }
            var data = try NativeMCPCatalogValues.strings(arguments, fields: ["name", "currency"]); data["updatedBy"] = .text(actor)
            if name == "crm_archive_price_list" { data["isActive"] = .integer(0) } else if let active = arguments["isActive"] as? Bool { data["isActive"] = .integer(active ? 1 : 0) }
            guard let existing else { throw NativeMCPFailure.internalError }
            let row = try db.update(existing, changes: data, actor: actor); audit("price_list", id, "updated"); return try response(row)
        case "crm_upsert_price_list_rule":
            let listID = arguments["priceListId"] as! String; _ = try writable(listID)
            let ruleID = arguments["ruleId"] as? String; var existing: NativeRecord?
            if let ruleID, !ruleID.isEmpty { existing = try get(ruleModel, ruleID); guard existing?["priceListId"] == .text(listID) else { throw NativeMCPFailure.notFound } }
            func string(_ name: String) -> String? { arguments[name] as? String }
            func number(_ name: String) -> Double? { (arguments[name] as? NSNumber)?.doubleValue }
            let target = string("appliesTo")!, compute = string("computePrice")!, base = compute == "FIXED" ? "LIST_PRICE" : string("base") ?? "LIST_PRICE", formula = compute == "FORMULA"
            let start = string("dateStart").flatMap { $0.isEmpty ? nil : NativeMCPPriceDate.parse($0) }, end = string("dateEnd").flatMap { $0.isEmpty ? nil : NativeMCPPriceDate.parse($0) }
            var problems: [String] = []
            if target == "CATEGORY", (string("categoryId") ?? "").isEmpty { problems.append("categoryRequired") }
            if target == "PRODUCT", (string("productId") ?? "").isEmpty { problems.append("productRequired") }
            if compute == "FIXED", number("fixedPrice") == nil { problems.append("fixedPriceRequired") }
            if compute == "PERCENTAGE" { if let percent = number("percentPrice") { if percent < 0 || percent > 100 { problems.append("percentRange") } } else { problems.append("percentRequired") } }
            if compute != "FIXED", base == "PRICE_LIST" { if (string("basePriceListId") ?? "").isEmpty { problems.append("baseListRequired") } else if string("basePriceListId") == listID { problems.append("baseListSelf") } }
            if let start, let end, end < start { problems.append("dateOrder") }
            if let quantity = number("minQuantity"), quantity < 0 { problems.append("minQuantityNegative") }
            if formula, let round = number("priceRound"), round <= 0 { problems.append("roundPositive") }
            if formula, let minimum = number("priceMinMargin"), let maximum = number("priceMaxMargin"), minimum > maximum { problems.append("marginOrder") }
            if !problems.isEmpty { throw NativeMCPFailure.validation(problems.joined(separator: ",")) }
            let baseID = compute != "FIXED" && base == "PRICE_LIST" ? string("basePriceListId") : nil
            if let baseID, !baseID.isEmpty {
                _ = try get(model, baseID)
                var seen = Set<String>(), stack = [baseID]
                while let id = stack.popLast() {
                    if id == listID { throw NativeMCPFailure.validation("cycle") }; if !seen.insert(id).inserted { continue }
                    let edges = try NativeMCPCatalogValues.rows(ruleModel, db: db, equal: ["priceListId": .text(id)])
                    for edge in edges where edge["id"].string != ruleID && edge["basePriceListId"] != .null { stack.append(edge["basePriceListId"].string) }
                }
            }
            // Invalid Date values survive rule validation in JS and fail only
            // at Prisma serialization, after cycle / missing-base validation.
            for key in ["dateStart", "dateEnd"] { if let raw = string(key), !raw.isEmpty, NativeMCPPriceDate.parse(raw) == nil { throw NativeMCPFailure.internalError } }
            var data: [String: SQLValue] = ["appliesTo": .text(target), "computePrice": .text(compute), "base": .text(base), "categoryId": target == "CATEGORY" ? string("categoryId").map(SQLValue.text) ?? .null : .null, "productId": target == "PRODUCT" ? string("productId").map(SQLValue.text) ?? .null : .null, "basePriceListId": baseID.map(SQLValue.text) ?? .null, "dateStart": start.map(SQLValue.text) ?? .null, "dateEnd": end.map(SQLValue.text) ?? .null]
            for (key, relevant, zero) in [("minQuantity", true, true), ("fixedPrice", compute == "FIXED", false), ("percentPrice", compute == "PERCENTAGE", false), ("priceDiscount", formula, true), ("priceSurcharge", formula, true), ("priceRound", formula, false), ("priceMinMargin", formula, false), ("priceMaxMargin", formula, false)] {
                if relevant, let value = arguments[key], !(value is NSNull) { data[key] = try NativeMCPCatalogValues.decimal(value, scale: 4) } else { data[key] = zero ? .text("0") : .null }
            }
            let row: NativeRecord
            if let existing { row = try db.update(existing, changes: data, actor: actor) } else { data["priceListId"] = .text(listID); row = try db.insert(ruleModel, values: data, actor: actor) }
            audit("price_list_rule", row["id"].string, existing == nil ? "created" : "updated"); return try response(row)
        case "crm_delete_price_list_rule":
            let row = try get(ruleModel, arguments["id"] as! String); _ = try writable(row["priceListId"].string)
            try db.remove(row, actor: actor); audit("price_list_rule", row["id"].string, "deleted"); return ["data": ["id": row["id"].string]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
