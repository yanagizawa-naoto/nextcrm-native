import Foundation

extension NativeCRMConfiguration {
    struct SearchPage { let page: Page; let dictionaryTotal: Int }

    /// Native UI search is literal, case-insensitive, and bounded. It does not
    /// change the source-compatible unfiltered service's ordering or writes.
    func searchPage(_ kind: Kind, search: String = "", excludingID: String? = nil, offset: Int = 0) throws -> SearchPage {
        try service.db.transaction {
            try service.authenticated()
            guard service.identity.role == "admin" else { throw NativeDBError.message("操作する権限がありません") }
            let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            var filters: [RecordFilter] = []
            if !text.isEmpty { filters.append(.scalar("name", "contains", [.text(text)], true)) }
            if let excludingID { filters.append(.not(.equal("id", .text(excludingID)))) }
            let fields = kind == .salesStage ? ["name", "v", "stage_kind"] : ["name", "v"]
            let result = try service.db.mcpPage(kind.model, fields: fields, filter: .every(filters), limit: 100, offset: offset,
                                               order: [("name", false)], includeDeleted: true)
            let total = try service.db.mcpPage(kind.model, fields: [], filter: .all, limit: 1, offset: 0, order: [("name", false)]).total
            let values = try result.rows.map { row in
                Value(record: row, usageCount: try service.db.mcpPage(kind.reference.model, fields: [], filter: .equal(kind.reference.field, row["id"]),
                                                                   limit: 1, offset: 0, order: [("id", false)], includeDeleted: true).total)
            }
            return SearchPage(page: Page(values: values, total: result.total, offset: offset), dictionaryTotal: total)
        }
    }

    /// Keep the original UI's last-value protection. Recheck the usage count
    /// inside the write transaction so a confirmation cannot silently acquire
    /// new effects while it is open. Direct action parity remains in delete().
    func deleteFromUI(_ kind: Kind, value: Value, replacementID: String?) throws {
        try service.db.transaction {
            try service.authenticated()
            guard service.identity.role == "admin" else { throw NativeDBError.message("操作する権限がありません") }
            guard try service.db.mcpPage(kind.model, fields: [], filter: .all, limit: 1, offset: 0, order: [("id", false)]).total > 1 else {
                throw NativeDBError.message("最後の項目は削除できません。")
            }
            let count = try service.db.mcpPage(kind.reference.model, fields: [], filter: .equal(kind.reference.field, .text(value.id)),
                                               limit: 1, offset: 0, order: [("id", false)], includeDeleted: true).total
            guard count == value.usageCount else { throw NativeDBError.message("使用件数が変わりました。いったん閉じて一覧を再読み込みしてください。") }
            var replacement: String?
            if count > 0 && kind.allowsReassignment {
                guard let replacementID, replacementID != value.id,
                      try service.db.get(kind.model, key: ["id": .text(replacementID)]) != nil else {
                    throw NativeDBError.message("削除前に有効な置き換え先を選択してください。")
                }
                replacement = replacementID
            }
            try delete(kind, id: value.id, replacementID: replacement, expectedRevision: value.record.revision)
        }
    }

    static func stageTitle(_ value: String?) -> String {
        switch value {
        case nil: return "なし"
        case "pre_sale": return "商談前"
        case "qualified": return "見込み確認済み"
        case "purchase_order": return "注文受付"
        case "delivery": return "納品"
        case "care": return "フォロー"
        default: return "未対応の設定（保持）"
        }
    }
}
