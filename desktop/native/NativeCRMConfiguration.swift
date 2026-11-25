import Foundation

/// Administrator-owned CRM dictionaries. The source actions operate across all
/// accounts, including soft-deleted references; ordinary record scopes must not
/// hide those references during counts, reassignment, or deletion.
struct NativeCRMConfiguration {
    enum Kind: String, CaseIterable {
        case industry, contactType, leadSource, leadStatus, leadType, opportunityType, salesStage

        var model: String {
            switch self {
            case .industry: return "crm_Industry_Type"
            case .contactType: return "crm_Contact_Types"
            case .leadSource: return "crm_Lead_Sources"
            case .leadStatus: return "crm_Lead_Statuses"
            case .leadType: return "crm_Lead_Types"
            case .opportunityType: return "crm_Opportunities_Type"
            case .salesStage: return "crm_Opportunities_Sales_Stages"
            }
        }
        var title: String {
            switch self {
            case .industry: return "業種"
            case .contactType: return "連絡先の種別"
            case .leadSource: return "リードの流入元"
            case .leadStatus: return "リードの状態"
            case .leadType: return "リードの種別"
            case .opportunityType: return "商談の種別"
            case .salesStage: return "営業段階"
            }
        }
        var reference: (model: String, field: String) {
            switch self {
            case .industry: return ("crm_Accounts", "industry")
            case .contactType: return ("crm_Contacts", "contact_type_id")
            case .leadSource: return ("crm_Leads", "lead_source_id")
            case .leadStatus: return ("crm_Leads", "lead_status_id")
            case .leadType: return ("crm_Leads", "lead_type_id")
            case .opportunityType: return ("crm_Opportunities", "type")
            case .salesStage: return ("crm_Opportunities", "sales_stage")
            }
        }
        var allowsReassignment: Bool {
            [.contactType, .leadSource, .leadStatus, .leadType].contains(self)
        }
    }

    /// `unchanged` is the source's omitted argument; `set(nil)` explicitly clears
    /// the automation kind. Non-stage dictionaries ignore this argument.
    enum StageKindChange { case unchanged, set(String?) }
    static let stageKinds = ["pre_sale", "qualified", "purchase_order", "delivery", "care"]
    struct Value {
        let record: NativeRecord
        let usageCount: Int
        var id: String { record["id"].string }
        var name: String { record["name"].string }
        var stageKind: String? { record["stage_kind"] == .null ? nil : record["stage_kind"].string }
    }
    struct Page { let values: [Value]; let total: Int; let offset: Int }
    let service: CRMService

    private func administrator() throws {
        try service.authenticated()
        guard service.identity.role == "admin" else { throw NativeDBError.message("操作する権限がありません") }
    }

    /// Paginated form of getConfigValues. One transaction supplies a consistent
    /// dictionary/count snapshot, and only this page's records enter memory.
    func page(_ kind: Kind, offset: Int = 0, limit: Int = 100) throws -> Page {
        try service.db.transaction {
            try administrator()
            guard offset >= 0, (1...100).contains(limit) else { throw NativeDBError.message("一覧の範囲が不正です。") }
            let fields = kind == .salesStage ? ["name", "v", "stage_kind"] : ["name", "v"]
            let page = try service.db.mcpPage(kind.model, fields: fields, filter: .all, limit: limit, offset: offset,
                                            order: [("name", false)], includeDeleted: true)
            let reference = kind.reference
            let values = try page.rows.map { row -> Value in
                let count = try service.db.mcpPage(reference.model, fields: [], filter: .equal(reference.field, row["id"]),
                                                  limit: 1, offset: 0, order: [("id", false)], includeDeleted: true).total
                return Value(record: row, usageCount: count)
            }
            return Page(values: values, total: page.total, offset: offset)
        }
    }

    @discardableResult
    func create(_ kind: Kind, name: String, stageKind: StageKindChange = .unchanged) throws -> NativeRecord {
        try service.db.transaction {
            try administrator()
            var values = try changes(kind, name: name, stageKind: stageKind)
            values["v"] = .integer(0)
            return try service.db.insert(kind.model, values: values, actor: service.identity.id)
        }
    }

    /// Optional revision protects a native editor's retained form. Omission
    /// preserves the original action's update-by-ID behavior.
    @discardableResult
    func update(_ kind: Kind, id: String, name: String, stageKind: StageKindChange = .unchanged,
                expectedRevision: Int64? = nil) throws -> NativeRecord {
        try service.db.transaction {
            try administrator()
            let values = try changes(kind, name: name, stageKind: stageKind)
            let row = try current(kind, id: id, expectedRevision: expectedRevision)
            return try service.db.update(row, changes: values, actor: service.identity.id)
        }
    }

    func delete(_ kind: Kind, id: String, replacementID: String? = nil, expectedRevision: Int64? = nil) throws {
        try service.db.transaction {
            try administrator()
            if replacementID == id { throw NativeDBError.message("replacementId must differ from id") }
            let replacement = replacementID.flatMap { $0.isEmpty ? nil : $0 }
            if replacement != nil && !kind.allowsReassignment {
                throw NativeDBError.message("Config type does not support reassignment")
            }
            let row = try current(kind, id: id, expectedRevision: expectedRevision)
            if let replacement {
                let reference = kind.reference
                // Every processed row leaves this predicate. Starting at zero
                // avoids skipping rows as a page is reassigned, including trash.
                while true {
                    let page = try service.db.mcpPage(reference.model, fields: [], filter: .equal(reference.field, row["id"]),
                                                      limit: 100, offset: 0, order: [("id", false)], includeDeleted: true)
                    if page.rows.isEmpty { break }
                    for item in page.rows {
                        try Task.checkCancellation()
                        guard let full = try service.db.get(reference.model, key: ["id": item["id"]]) else { throw NativeDBError.conflict }
                        let changed = try service.db.update(full, changes: [reference.field: .text(replacement)], actor: service.identity.id)
                        guard changed[reference.field] == .text(replacement) else { throw NativeDBError.conflict }
                    }
                }
            }
            // Native SQL intentionally uses NO ACTION FKs. This narrow helper
            // mirrors the source's nullable-FK SET NULL without changing the
            // referring records' business timestamps or emitting save events.
            try service.db.deleteCRMConfiguration(row, actor: service.identity.id)
        }
    }

    private func current(_ kind: Kind, id: String, expectedRevision: Int64?) throws -> NativeRecord {
        guard let row = try service.db.get(kind.model, key: ["id": .text(id)]) else { throw NativeDBError.message("対象が見つかりません。") }
        if let expectedRevision, row.revision != expectedRevision { throw NativeDBError.conflict }
        return row
    }

    private func changes(_ kind: Kind, name: String, stageKind: StageKindChange) throws -> [String: SQLValue] {
        // ECMAScript String.trim (including FEFF, excluding NEL), followed by
        // the installed Zod's Unicode code-point length rule.
        func whitespace(_ value: Unicode.Scalar) -> Bool {
            switch value.value {
            case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
        let scalars = name.unicodeScalars
        let start = scalars.firstIndex { !whitespace($0) } ?? scalars.endIndex
        let suffix = scalars[start...]
        let end = suffix.lastIndex { !whitespace($0) }.map { scalars.index(after: $0) } ?? start
        let parsed = String(scalars[start..<end])
        guard !parsed.isEmpty else { throw NativeDBError.message("名称を入力してください") }
        guard parsed.unicodeScalars.count <= 100 else { throw NativeDBError.message("100文字以内で入力してください") }
        var result: [String: SQLValue] = ["name": .text(parsed)]
        if kind == .salesStage, case let .set(value) = stageKind {
            guard value == nil || Self.stageKinds.contains(value!) else { throw NativeDBError.message("営業段階の自動処理を選択してください。") }
            result["stage_kind"] = value.map(SQLValue.text) ?? .null
        }
        return result
    }
}
