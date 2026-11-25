import Foundation

/// Source report operations use SQL aggregation and bounded result pages. The
/// original users report also authenticates a cookie session, independently of
/// its bearer actor. A verified auth integration must supply that second gate.
enum NativeMCPReports {
    typealias UserDirectoryAuthorization = (NativeAPISession) async throws -> Void
    static let names: Set<String> = ["reports_list", "reports_run"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] { makeHandlers() }
    static func makeHandlers(clock: @escaping () -> Date = Date.init,
                             authorizeUserDirectory: @escaping UserDirectoryAuthorization = { _ in throw NativeMCPFailure.reportSessionUnauthenticated }) -> [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in
                let now = clock()
                if name == "reports_run", arguments["category"] as? String == "users" {
                    try session.withAccess { guard $0.identity.elevated else { throw NativeMCPFailure.forbidden } }
                    try await authorizeUserDirectory(session)
                    // Authentication may suspend: do not retain earlier access.
                    return try session.withAccess { service in
                        guard service.identity.elevated else { throw NativeMCPFailure.forbidden }
                        return try run(name, arguments: arguments, service: service, now: now, userDirectoryAuthorized: true)
                    }
                }
                return try session.withAccess { try run(name, arguments: arguments, service: $0, now: now) }
            })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService, now: Date, userDirectoryAuthorized: Bool = false) throws -> Any {
        let db = service.db
        if name == "reports_list" {
            let limit = try NativeMCPWire.integer(arguments["limit"] ?? 20, range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"] ?? 0, range: 0...Int(Int32.max))
            var filters: [RecordFilter] = []
            if let category = arguments["category"] as? String { filters.append(.equal("category", .text(category))) }
            if !service.identity.elevated { filters.append(.any([.equal("createdBy", .text(service.identity.id)), .equal("isShared", .integer(1))])) }
            let model = try db.schema.model("crm_Report_Config"), page = try db.mcpPage(model.name, fields: model.fields.map(\.name), filter: .every(filters), limit: limit, offset: offset)
            return ["data": try page.rows.map { try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        }
        guard name == "reports_run", let category = arguments["category"] as? String else { throw NativeMCPFailure.internalError }
        if category == "users" {
            guard service.identity.elevated else { throw NativeMCPFailure.forbidden }
            guard userDirectoryAuthorized else { throw NativeMCPFailure.reportSessionUnauthenticated }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let defaultFrom = calendar.date(byAdding: .day, value: -30, to: now)!
        func bound(_ key: String, fallback: Date) throws -> String {
            guard let text = arguments[key] as? String else { return NativeAPITokens.timestamp(fallback) }
            guard let canonical = NativeMCPWire.canonicalUTC(text) else { throw NativeMCPFailure.internalError }; return canonical
        }
        let from = try bound("dateFrom", fallback: defaultFrom), to = try bound("dateTo", fallback: now)
        func range(_ field: String) -> RecordFilter { .every([.compareDate(field, .greaterOrEqual, from), .compareDate(field, .lessOrEqual, to)]) }
        let data: Any
        if category == "campaigns" {
            let live = RecordFilter.every([.equal("deletedAt", .null), .any([.equal("status", .null), .not(.equal("status", .text("deleted")))])])
            let filter = RecordFilter.every([range("sent_at"), .equal("status", .text("sent")), .relation(model: "crm_campaigns", local: "campaign_id", foreign: "id", matching: .every([service.reportScope("crm_campaigns"), live]))])
            func count(_ extra: RecordFilter = .all) throws -> Int { try Task.checkCancellation(); return try db.page("crm_campaign_sends", fields: [], filter: .every([filter, extra]), limit: 1).total }
            let sent = try count(), opened = try count(.not(.equal("opened_at", .null))), clicked = try count(.not(.equal("clicked_at", .null)))
            data = ["sent": sent, "opened": opened, "clicked": clicked, "openRate": NativeReports.percent(opened, sent), "clickRate": NativeReports.percent(clicked, sent)]
        } else {
            let model: String, date: String, recipe: String
            switch category {
            case "sales": model = "crm_Opportunities"; date = "created_on"; recipe = "oppsByMonth"
            case "leads": model = "crm_Leads"; date = "createdAt"; recipe = "newLeads"
            case "accounts": model = "crm_Accounts"; date = "createdAt"; recipe = "newAccounts"
            case "activity": model = "Tasks"; date = "createdAt"; recipe = "mcpTasksByAssignee"
            case "users": model = "Users"; date = "created_on"; recipe = "userGrowth"
            default: throw NativeMCPFailure.internalError
            }
            var filters = [range(date), category == "users" ? .all : service.reportScope(model)]
            if try db.schema.model(model).field("deletedAt") != nil { filters.append(.equal("deletedAt", .null)) }
            if category == "activity" { filters.append(.any([.equal("section", .null), .relation(model: "Sections", local: "section", foreign: "id", matching: .relation(model: "Boards", local: "board", foreign: "id", matching: .equal("deletedAt", .null)))])) }
            let common = RecordFilter.every(filters)
            // SQLite maps years outside 1970...2037 into a modern year before
            // localtime(), losing historical offsets and future DST rules.
            let modern = RecordFilter.every([.compareDate(date, .greaterOrEqual, "1970-01-01T00:00:00.000Z"), .compareDate(date, .less, "2038-01-01T00:00:00.000Z")])
            if category != "activity" { filters.append(modern) }
            let token = try db.createReportWorkspace(); defer { db.removeReportWorkspace(token) }
            try db.aggregateReport(token, section: "data", recipe: recipe, filter: .every(filters))
            var rows: [[String: Any]] = [], offset = 0
            while true {
                try Task.checkCancellation()
                let page = try db.reportPage(token, section: "data", offset: offset)
                for row in page.rows {
                    var label = row["label"]!.string
                    if row["truncated"] == .integer(1) {
                        var bytes = Data(); try db.reportLabelChunks(token, rowID: Int64(row["id"]!.string)!) { bytes.append($0) }; label = String(decoding: bytes, as: UTF8.self)
                    }
                    let count = Int(row["value"]!.string)!
                    if category == "activity" {
                        // The original uses a plain JS object, including its
                        // inherited keys and integer-property enumeration.
                        if label == "__proto__" { continue }
                        let inherited: Set<String> = ["constructor", "toString", "toLocaleString", "valueOf", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__"]
                        let value: Any = inherited.contains(label) ? "function \(label == "constructor" ? "Object" : label)() { [native code] }" + String(repeating: "1", count: count) : count
                        rows.append(["name": label, "Number": value])
                    } else {
                        // JS interpolates a numeric year without four-digit padding.
                        let pieces = label.split(separator: "-")
                        if pieces.count == 2, let year = Int(pieces[0]) { label = String(year) + "-" + pieces[1] }
                        rows.append(["name": label, "Number": count])
                    }
                }
                offset += page.rows.count; if offset >= page.total { break }
            }
            if category == "activity" {
                func index(_ name: String) -> UInt32? { guard let number = UInt32(name), number < UInt32.max, String(number) == name else { return nil }; return number }
                rows = rows.enumerated().sorted { a, b in
                    let ai = index(a.element["name"] as! String), bi = index(b.element["name"] as! String)
                    if let ai, let bi { return ai < bi }; if ai != nil { return true }; if bi != nil { return false }; return a.offset < b.offset
                }.map(\.element)
            } else {
                var grouped = Dictionary(uniqueKeysWithValues: rows.map { ($0["name"] as! String, $0["Number"] as! Int) })
                if from < "1970-01-01T00:00:00.000Z" || to >= "2038-01-01T00:00:00.000Z" {
                    var after: String?
                    while true {
                        try Task.checkCancellation()
                        let page = try db.keysetPage(model, fields: [date], after: after, filter: .every([common, .not(modern)]))
                        if page.isEmpty { break }
                        for record in page { grouped[try localMonth(record[date].string), default: 0] += 1 }
                        after = page.last!["id"].string
                    }
                }
                rows = grouped.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }.map { ["name": $0, "Number": grouped[$0]!] }
            }
            data = rows
        }
        return ["data": ["category": category, "data": data]]
    }
    /// Arithmetic Gregorian conversion has no 1582 cutover or year-zero rewrite.
    /// Only the zone offset comes from the system IANA time-zone implementation.
    private static func localMonth(_ text: String) throws -> String {
        let instant: Double
        if let utc = NativeMCPWire.canonicalUTC(text) {
            let parts = utc.split(whereSeparator: { "-T:.Z".contains($0) }).map { Int($0)! }
            var year = parts[0]; let month = parts[1], day = parts[2]
            year -= month <= 2 ? 1 : 0
            let era = (year >= 0 ? year : year - 399) / 400, yearOfEra = year - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            instant = Double(era * 146097 + dayOfEra - 719468) * 86400 + Double(parts[3] * 3600 + parts[4] * 60 + parts[5]) + Double(parts[6]) / 1000
        } else {
            guard let date = NativeAPITokens.date(.text(text)) else { throw NativeMCPFailure.internalError }; instant = date.timeIntervalSince1970
        }
        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: instant))
        let z = Int(floor((instant + Double(offset)) / 86400)) + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097, dayOfEra = z - era * 146097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100), monthPrime = (5 * dayOfYear + 2) / 153
        let month = monthPrime + (monthPrime < 10 ? 3 : -9), year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(year) + "-" + String(format: "%02d", month)
    }
}
