import Foundation

/// Currency and rate administration, separate from pricing calculations. The
/// source offers enable/disable, not destructive currency deletion.
struct NativeCurrencyAdministration {
    struct Page { let rows: [NativeRecord]; let total: Int; let offset: Int }
    struct Settings { let enabled: Bool; let revision: Int64?; let defaultCode: String? }
    let service: CRMService
    var clock: () -> Date = Date.init

    func requireAdmin() throws {
        try service.authenticated()
        guard service.identity.role == "admin" else { throw NativeDBError.message("通貨の設定は管理者が行ってください。") }
    }
    func currencies(offset: Int = 0, search: String = "") throws -> Page {
        try service.db.transaction {
            try requireAdmin()
            guard offset >= 0 else { throw NativeDBError.message("一覧の範囲が不正です。") }
            let result = try service.db.page("Currency", fields: ["code", "name", "symbol", "isEnabled", "isDefault"], search: search,
                                             offset: offset, sort: "code", limit: 100)
            return Page(rows: result.rows, total: result.total, offset: offset)
        }
    }
    func rates(offset: Int = 0, search: String = "") throws -> Page {
        try service.db.transaction {
            try requireAdmin()
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let filter: RecordFilter = search.isEmpty ? .all : .any([.scalar("fromCurrency", "contains", [.text(escaped)], true), .scalar("toCurrency", "contains", [.text(escaped)], true)])
            let result = try service.db.mcpPage("ExchangeRate", fields: ["fromCurrency", "toCurrency", "rate", "source", "effectiveDate", "updatedAt"],
                                              filter: filter, limit: 100, offset: offset, order: [("fromCurrency", false), ("toCurrency", false)])
            return Page(rows: result.rows, total: result.total, offset: offset)
        }
    }
    func settings() throws -> Settings {
        try service.db.transaction {
            try requireAdmin()
            let row = try service.db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")])
            return Settings(enabled: row?["value"] == .text("true"), revision: row?.revision,
                            defaultCode: try service.db.get("crm_SystemSettings", key: ["key": .text("default_currency")])?["value"].string)
        }
    }
    @discardableResult func create(code: String, name: String, symbol: String) throws -> NativeRecord {
        try service.db.transaction {
            try requireAdmin()
            guard code.unicodeScalars.count == 3 else { throw NativeDBError.message("通貨コードは3文字で入力してください。") }
            guard (1...100).contains(name.unicodeScalars.count) else { throw NativeDBError.message("名称は1〜100文字で入力してください。") }
            guard (1...5).contains(symbol.unicodeScalars.count) else { throw NativeDBError.message("通貨記号は1〜5文字で入力してください。") }
            let upper = code.uppercased()
            guard upper.unicodeScalars.count <= 3 else { throw NativeDBError.message("大文字に変換した通貨コードが3文字を超えています。") }
            return try service.db.insert("Currency", values: ["code": .text(upper), "name": .text(name), "symbol": .text(symbol), "isEnabled": .integer(1), "isDefault": .integer(0)], actor: service.identity.id)
        }
    }
    /// UI passes expectedRevision and protects the default. Omitting both
    /// preserves the original action's direct update-by-code contract.
    func setEnabled(code: String, enabled: Bool, expectedRevision: Int64? = nil, protectDefault: Bool = false) throws {
        try service.db.transaction {
            try requireAdmin()
            let row = try currency(code, expectedRevision: expectedRevision)
            guard !protectDefault || enabled || row["isDefault"] != .integer(1) else { throw NativeDBError.message("既定の通貨は無効にできません。先に別の通貨を既定にしてください。") }
            _ = try service.db.update(row, changes: ["isEnabled": .integer(enabled ? 1 : 0)], actor: service.identity.id)
        }
    }
    func setDefault(code: String, expectedRevision: Int64? = nil) throws {
        try service.db.transaction {
            try requireAdmin(); _ = try currency(code, expectedRevision: expectedRevision)
            // The source updateMany touches every row (including already-false
            // flags), so preserve its updatedAt behavior while paging by code.
            var offset = 0
            while true {
                let page = try service.db.page("Currency", fields: [], offset: offset, sort: "code", limit: 100)
                for item in page.rows {
                    try Task.checkCancellation()
                    let current = try currency(item["code"].string, expectedRevision: nil)
                    _ = try service.db.update(current, changes: ["isDefault": .integer(0)], actor: service.identity.id)
                }
                offset += page.rows.count; if offset >= page.total || page.rows.isEmpty { break }
            }
            _ = try service.db.update(currency(code, expectedRevision: nil), changes: ["isDefault": .integer(1), "isEnabled": .integer(1)], actor: service.identity.id)
            try Self.setting("default_currency", value: code, db: service.db, actor: service.identity.id)
        }
    }
    func setECBEnabled(_ enabled: Bool, expected: Settings? = nil) throws {
        try service.db.transaction {
            try requireAdmin()
            if let expected { guard try settings().revision == expected.revision else { throw NativeDBError.conflict } }
            try Self.setting("ecb_auto_update", value: enabled ? "true" : "false", db: service.db, actor: service.identity.id)
        }
        // Wake a retained scheduler only after the settings transaction commits.
        service.db.deferUntilTransactionEnds(onCommit: { NotificationCenter.default.post(name: Self.settingsDidChange, object: nil, userInfo: ["database": service.db.url.path]) }, onRollback: {})
    }
    static let settingsDidChange = Notification.Name("NextCRMNativeCurrencySettingsChanged")
    @discardableResult func saveRate(from: String, to: String, input: String, expected: NativeRecord? = nil, protectAutomatic: Bool = false) throws -> NativeRecord {
        try service.db.transaction {
            try requireAdmin()
            guard from.unicodeScalars.count == 3, to.unicodeScalars.count == 3 else { throw NativeDBError.message("元通貨と換算先のコードは3文字で入力してください。") }
            let validation = NativeOdooMap.number(input)
            guard !validation.isNaN, validation > 0 else { throw NativeDBError.message("レートは0より大きい値で入力してください。") }
            let current = try Self.rate(from: from, to: to, db: service.db)
            if let expected { guard current?["id"] == expected["id"], current?.revision == expected.revision else { throw NativeDBError.conflict } }
            if protectAutomatic, current?["source"] == .text("ECB"), try settings().enabled { throw NativeDBError.message("自動更新中のECBレートは編集できません。先に自動更新を無効にしてください。") }
            return try Self.upsertRate(from: from, to: to, value: Self.parseFloat(input), source: "MANUAL", db: service.db, actor: service.identity.id, at: clock())
        }
    }
    private func currency(_ code: String, expectedRevision: Int64?) throws -> NativeRecord {
        guard let row = try service.db.get("Currency", key: ["code": .text(code)]) else { throw NativeDBError.message("通貨が見つかりません。") }
        if let expectedRevision, row.revision != expectedRevision { throw NativeDBError.conflict }; return row
    }
    static func setting(_ key: String, value: String, db: NativeDatabase, actor: String) throws {
        if let row = try db.get("crm_SystemSettings", key: ["key": .text(key)]) { _ = try db.update(row, changes: ["value": .text(value)], actor: actor) }
        else { _ = try db.insert("crm_SystemSettings", values: ["key": .text(key), "value": .text(value)], actor: actor) }
    }
    static func rate(from: String, to: String, db: NativeDatabase) throws -> NativeRecord? {
        try db.page("ExchangeRate", fields: db.schema.model("ExchangeRate").fields.map(\.name), equal: ["fromCurrency": .text(from), "toCurrency": .text(to)], limit: 1).rows.first
    }
    static func parseFloat(_ input: String) -> Double {
        let text = input.trimmingCharacters(in: NativeOdooMap.whitespace)
        guard let match = text.range(of: #"^[+-]?(?:Infinity|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"#, options: .regularExpression) else { return .nan }
        return Double(text[match]) ?? .nan
    }
    static func storedRate(_ value: Double) throws -> String {
        guard value.isFinite else { throw NativeDBError.message("保存可能な為替レートの範囲を超えています。") }
        if abs(value) < 0.000000005 { return "0" }
        guard let decimal = Decimal(string: NativePluginJSON.numberString(value), locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else { throw NativeDBError.message("保存可能な為替レートの範囲を超えています。") }
        let rounded = PriceDecimal.rounded(decimal, scale: 8)
        guard rounded < Decimal(10_000_000_000 as Int64), rounded > Decimal(-10_000_000_000 as Int64) else { throw NativeDBError.message("保存可能な為替レートの範囲を超えています。") }
        return PriceDecimal.string(rounded)
    }
    @discardableResult static func upsertRate(from: String, to: String, value: Double, source: String, db: NativeDatabase, actor: String, at: Date) throws -> NativeRecord {
        try db.transaction {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
            let values: [String: SQLValue] = ["rate": .text(try storedRate(value)), "source": .text(source), "effectiveDate": .text(formatter.string(from: at))]
            if let current = try rate(from: from, to: to, db: db) { return try db.update(current, changes: values, actor: actor) }
            return try db.insert("ExchangeRate", values: values.merging(["fromCurrency": .text(from), "toCurrency": .text(to)]) { a, _ in a }, actor: actor)
        }
    }
}
