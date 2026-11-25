import Foundation

/// Two independently counted stores: imported/source business events and the
/// native mutation journal. They do not have a reliable shared event identity.
struct NativeAdminAudit {
    enum Source: String, CaseIterable { case local, business
        var title: String { self == .local ? "このMacの変更履歴" : "元の業務履歴" }
        var explanation: String { self == .local ? "このMacの画面・API・自動処理による保存を記録します。元の業務履歴とは別の一覧です。" : "移行した履歴と、元の業務処理に対応するAPI・連携の履歴です。通常のMac画面の変更は「このMacの変更履歴」で確認できます。" }
    }
    struct Filters { var source: Source = .local; var entityType: String?; var action: String?; var userID: String?; var dateFrom: Date?; var dateTo: Date?; var page = 1 }
    struct Entry { let source: Source; let id: String; let entityType: String; let model: String?; let entityID: String?; let action: String; let actorName: String; let createdAt: String
        var entityTitle: String { NativeAdminAudit.entityTitle(entityType) }
        var actionTitle: String { NativeAdminAudit.actionTitle(action) }
        var canOfferRestore: Bool { ["delete", "deleted"].contains(action) && model.map { NativeAdminAudit.restoreModels.contains($0) } == true && entityID != nil }
    }
    struct Page { let entries: [Entry]; let total: Int; let page: Int; var totalPages: Int { (total + 49) / 50 } }
    struct Field { let key: String; let label: String; let index: Int?; var attribute: String? = nil }
    struct Detail { let entry: Entry; let fields: [Field]; let total: Int; let page: Int; let restorable: NativeRecord?; let notice: String }
    enum Side: String { case before, after; var title: String { self == .before ? "変更前" : "変更後" } }
    struct Value { let text: String; let offset: Int; let total: Int; let protected: Bool; var hasNext: Bool { !protected && offset + 4096 < total } }
    struct User { let id: String; let name: String }
    let service: CRMService
    static let restoreModels: Set<String> = ["crm_Accounts", "crm_Contacts", "crm_Leads", "crm_Opportunities", "crm_Contracts"]
    static let entities: [(String, String, String)] = [("account","取引先","crm_Accounts"),("contact","連絡先","crm_Contacts"),("lead","見込み客","crm_Leads"),("opportunity","商談","crm_Opportunities"),("contract","契約","crm_Contracts"),("product","商品","crm_Products"),("account_product","取引先の商品","crm_AccountProducts"),("opportunity_line_item","商談明細","crm_OpportunityLineItems"),("contract_line_item","契約明細","crm_ContractLineItems"),("price_list","価格表","crm_PriceLists"),("price_list_rule","価格ルール","crm_PriceListRules"),("product_category","商品分類","crm_ProductCategories"),("order","受注","crm_Orders"),("user","利用者","Users"),("plugin","拡張機能","InstalledPlugin")]
    static let actions: [(String, String)] = [("created","作成"),("updated","更新"),("deleted","削除"),("restored","復元"),("relation_added","関連を追加"),("relation_removed","関連を解除"),("imported","取込"),("cancelled","取消"),("installed","導入"),("uninstalled","削除（拡張機能）"),("enabled","有効化"),("disabled","無効化"),("settings_changed","設定変更"),("upgraded","更新（拡張機能）")]
    static func entityTitle(_ entity: String) -> String { entities.first { $0.0 == entity || $0.2 == entity }?.1 ?? CRMModule.find(entity)?.title ?? "その他のデータ" }
    static func actionTitle(_ action: String) -> String {
        if let title = actions.first(where: { $0.0 == action })?.1 { return title }
        return ["create":"作成","update":"更新","delete":"削除","restore":"復元","unlink":"関連を解除","cancel":"取消","reorder":"並び替え","partner":"外部パートナー設定","watch":"ウォッチ開始","unwatch":"ウォッチ解除","convert":"変換","order_save":"受注保存","order_lines":"受注明細更新","order_submit":"受注申請","order_approve":"受注承認","order_reject":"受注却下","order_cancel":"受注取消","allocate":"番号発行"][action] ?? "変更"
    }
    func requireAdmin() throws { try service.authenticated(); guard service.identity.role == "admin" else { throw NativeDBError.message("操作する権限がありません") } }
    /// The primary BEGIN IMMEDIATE fences current authority and other writers
    /// while a separate read-only connection owns a consistent committed view.
    private func read<T>(_ body: (NativeAdminAuditReader) throws -> T) throws -> T {
        try service.db.transaction { try requireAdmin(); let reader = try NativeAdminAuditReader(url: service.db.url); return try reader.snapshot { try body(reader) } }
    }
    func page(_ filters: Filters = Filters()) throws -> Page {
        guard filters.page > 0, filters.page <= Int.max / 50, filters.dateFrom?.timeIntervalSince1970.isFinite != false, filters.dateTo?.timeIntervalSince1970.isFinite != false else { throw NativeDBError.message("ページまたは日時を確認してください。") }
        return try read { try $0.page(filters) }
    }
    func users(search: String = "", page: Int = 1) throws -> (rows: [User], total: Int) {
        guard page > 0, page <= Int.max / 50 else { throw NativeDBError.message("ページを確認してください。") }
        return try read { try $0.users(search: search, page: page) }
    }
    func detail(_ selected: Entry, page: Int = 1) throws -> Detail {
        guard page > 0, page <= Int.max / 50 else { throw NativeDBError.message("ページを確認してください。") }
        return try read { reader in
            let entry = try reader.entry(source: selected.source, id: selected.id)
            let result = try reader.fields(entry, page: page)
            let fields = result.rows.map { raw -> Field in
                let allowed = entry.model.map { NativeAdminAuditSafety.permits(field: raw.key, model: $0, schema: service.db.schema) } == true
                let label = allowed ? (entry.model.flatMap(CRMModule.find)?.fields.first { $0.key == raw.key }?.label ?? NativeAdminAuditSafety.fieldTitle(raw.key)) : "非公開の項目"
                return Field(key: raw.key, label: (raw.attribute == nil ? "" : "補足・") + label, index: raw.index, attribute: raw.attribute)
            }
            let record: NativeRecord?
            if entry.canOfferRestore, let model = entry.model, let id = entry.entityID, let current = try restoreRecord(model, id: id), current["deletedAt"] != .null { record = current } else { record = nil }
            return Detail(entry: entry, fields: fields, total: result.total, page: page, restorable: record, notice: result.invalid ? "保存された変更内容を読み取れません。元の記録は保持されています。" : "認証情報・秘密を含む項目と未対応の構造化値は非表示です。長い値は4,096文字ずつ表示します。")
        }
    }
    func value(_ selected: Entry, field: Field, side: Side, offset: Int = 0) throws -> Value {
        guard offset >= 0, offset <= Int.max - 4096 else { throw NativeDBError.message("表示位置を確認してください。") }
        return try read { reader in
            let entry = try reader.entry(source: selected.source, id: selected.id)
            guard let model = entry.model, NativeAdminAuditSafety.permits(field: field.key, model: model, schema: service.db.schema) else { return Value(text: "非公開の値", offset: 0, total: 0, protected: true) }
            return try reader.value(entry, field: field, side: side, offset: offset, allowArray: try service.db.schema.model(model).field(field.key)?.array == true)
        }
    }
    private func restoreRecord(_ model: String, id: String) throws -> NativeRecord? {
        // A retained confirmation needs only the key, deletion flag and CAS
        // revision; do not retain a large account description/notes snapshot.
        try service.db.mcpPage(model, fields: ["id", "deletedAt"], filter: .equal("id", .text(id)), limit: 1, offset: 0, order: [("id", false)], includeDeleted: true).rows.first
    }
    func restore(_ detail: Detail) throws {
        try service.db.transaction {
            try requireAdmin()
            guard let expected = detail.restorable, Self.restoreModels.contains(expected.model), detail.entry.canOfferRestore,
                  detail.entry.model == expected.model, detail.entry.entityID == expected["id"].string else { throw NativeDBError.message("この履歴から復元できるデータがありません。") }
            let reader = try NativeAdminAuditReader(url: service.db.url)
            let currentEntry = try reader.snapshot { try reader.entry(source: detail.entry.source, id: detail.entry.id) }
            guard currentEntry.canOfferRestore, currentEntry.model == expected.model, currentEntry.entityID == expected["id"].string,
                  let current = try restoreRecord(expected.model, id: expected["id"].string), current.revision == expected.revision, current["deletedAt"] != .null else { throw NativeDBError.conflict }
            try service.delete(expected, restore: true)
            // The source audit helper is best effort. Keep its failure isolated
            // from the successful restore, while native audit remains atomic.
            _ = try? service.db.transaction { try service.db.insert("crm_AuditLog", values: ["entityType": .text(Self.entities.first { $0.2 == expected.model }!.0), "entityId": expected["id"], "action": .text("restored"), "userId": .text(service.identity.id)], actor: service.identity.id) }
        }
    }
}
