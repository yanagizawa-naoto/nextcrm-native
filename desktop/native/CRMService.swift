import Foundation

struct CRMIdentity {
    let id: String; let role: String; let partnerAccountID: String?
    var elevated: Bool { role == "admin" || role == "manager" }
}
struct CRMListRow { let record: NativeRecord; let cells: [String] }

final class CRMService {
    let db: NativeDatabase
    let identity: CRMIdentity
    init(db: NativeDatabase, identity: CRMIdentity) { self.db = db; self.identity = identity }
    static func bootstrap(_ db: NativeDatabase, resources: URL) throws -> CRMIdentity {
        try db.transaction {
            if let id = try db.metadata("localActor") {
                guard let existing = try db.get("Users", key: ["id": .text(id)]) else { throw NativeDBError.message("このデータの利用者を確認できません。利用者を選び直してください。") }
                let identity = CRMIdentity(id: id, role: existing["role"].string, partnerAccountID: existing["partnerAccountId"] == .null ? nil : existing["partnerAccountId"].string)
                try CRMService(db: db, identity: identity).authenticated()
                return identity
            }
            let marker = db.url.deletingLastPathComponent().appendingPathComponent(".native-migration-candidate")
            guard !db.isReadOnly, !FileManager.default.fileExists(atPath: marker.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path)) == nil,
                  try db.isPristinePersonalWorkspace() else {
                throw NativeDBError.message("既存データには管理者を自動作成しません。このMacで使う利用者を選んでください。")
            }
            let actor = try db.insert("Users", values: ["name": .text("ローカル管理者"), "email": .text("local@nextcrm.local"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: "local-setup")
            try db.setMetadata("localActor", value: actor["id"].string)
            let actorID = actor["id"].string
            if try db.metadata("initialConfiguration") == nil {
                for name in ["crm_Industry_Type","crm_Contact_Types","crm_Lead_Sources","crm_Lead_Statuses","crm_Lead_Types","crm_Opportunities_Sales_Stages","crm_Opportunities_Type"] {
                    let file = resources.appendingPathComponent("initial-data/\(name).json")
                    let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
                    for raw in rows {
                        let values = raw.mapValues { value -> SQLValue in
                            if value is NSNull { return .null }; if let number = value as? NSNumber { return .integer(number.int64Value) }
                            return .text(value as! String)
                        }
                        _ = try db.insert(name, values: values, actor: actorID)
                    }
                }
                for (code, name, symbol) in [("JPY","日本円","¥"),("USD","米ドル","$"),("EUR","ユーロ","€"),("CZK","チェココルナ","Kč")] {
                    if try db.get("Currency", key: ["code": .text(code)]) == nil {
                        _ = try db.insert("Currency", values: ["code": .text(code),"name": .text(name),"symbol": .text(symbol),"isDefault": .integer(code == "JPY" ? 1 : 0)], actor: actorID)
                    }
                }
                try db.setMetadata("initialConfiguration", value: "1")
            }
            if try db.metadata("initialOrderSeries") == nil {
                if try db.page("NumberSeries",fields:[],equal:["scope":.text("order")]).total == 0 {
                    _ = try db.insert("NumberSeries",values:["scope":.text("order"),"name":.text("受注"),"template":.text("ORD-{YYYY}-{####}"),"resetPolicy":.text("YEARLY"),"isDefault":.integer(1),"active":.integer(1)],actor:actorID)
                }
                try db.setMetadata("initialOrderSeries",value:"1")
            }
            let identity = CRMIdentity(id: actorID, role: actor["role"].string, partnerAccountID: actor["partnerAccountId"] == .null ? nil : actor["partnerAccountId"].string)
            try CRMService(db: db, identity: identity).authenticated()
            return identity
        }
    }
    func authenticated() throws {
        guard ["user","manager","admin","partner"].contains(identity.role),
              let user = try db.get("Users", key: ["id": .text(identity.id)]), user["userStatus"] == .text("ACTIVE"), user["banned"] != .integer(1), user["role"] == .text(identity.role),
              (identity.role != "partner" || user["partnerAccountId"] == identity.partnerAccountID.map(SQLValue.text) ?? .null) else {
            throw NativeDBError.message("この利用者では操作できません。管理者に確認してください。")
        }
    }
    /// The outbox retains its owner after schedule/configuration deletion, so
    /// an ambiguous receipt can still be reviewed without recreating a schedule.
    func reportMailJobAccess(_ id:String)throws->NativeJob {
        try authenticated()
        guard let job=try db.job(id:id),job.event=="reports.scheduled",identity.elevated || job.payload["ownerId"]==identity.id else {throw NativeDBError.message("定期送信の履歴が見つからないか、操作する権限がありません。")}
        return job
    }
    /// Original report/global-search scopes intentionally differ from detail
    /// read scopes: an ordinary contact search does not inherit account access.
    func reportScope(_ model: String) -> RecordFilter {
        if identity.elevated { return .all }
        if identity.role == "partner" {
            switch model {
            case "crm_Accounts", "crm_Contacts", "crm_Leads", "crm_Opportunities", "crm_Contracts": return scope(model)
            default: return .none
            }
        }
        guard identity.role == "user" else { return .none }
        switch model {
        case "crm_Accounts": return accountOwnership
        case "crm_Contacts", "crm_Leads", "crm_Opportunities", "crm_Contracts": return ownership
        case "Tasks": return .equal("user", .text(identity.id))
        case "crm_campaigns", "crm_TargetLists": return .equal("created_by", .text(identity.id))
        case "crm_Activities": return .equal("createdBy", .text(identity.id))
        default: return .none
        }
    }
    private var ownership: RecordFilter { .any([.equal("assigned_to", .text(identity.id)), .equal("createdBy", .text(identity.id))]) }
    private var accountOwnership: RecordFilter { .any([ownership, .relation(model: "AccountWatchers", local: "id", foreign: "account_id", matching: .equal("user_id", .text(identity.id)))]) }
    private func partnerAccounts(visibleOwn: Bool) -> RecordFilter {
        let partner = RecordFilter.equal("partnerUserId", .text(identity.id))
        let own = RecordFilter.equal("id", .text(identity.partnerAccountID ?? ""))
        return .every([.equal("deletedAt", .null), visibleOwn ? .any([partner, own]) : .every([partner, .not(own)])])
    }
    private func activityLinks(write: Bool) -> RecordFilter {
        let parents = CRMModule.all.filter { ["account","contact","lead","opportunity","contract"].contains($0.entity) && !(write && identity.role == "partner" && $0.entity == "contract") }
        let allowed = RecordFilter.any(parents.map { parent in
            let parentScope = scope(parent.model, write: write || (identity.role == "partner" && ["account","contact"].contains(parent.entity)))
            return .every([.equal("entityType", .text(parent.entity)), .relation(model: parent.model, local: "entityId", foreign: "id", matching: .every([parentScope, .equal("deletedAt", .null)]))])
        })
        let some = RecordFilter.relation(model: "crm_ActivityLinks", local: "id", foreign: "activityId", matching: allowed)
        if write && identity.role == "partner" {
            return .every([some, .not(.relation(model: "crm_ActivityLinks", local: "id", foreign: "activityId", matching: .not(allowed)))])
        }
        return some
    }
    func scope(_ model: String, write: Bool = false, deletion: Bool = false) -> RecordFilter {
        // Personal mail never inherits the administrator's general CRM scope.
        if model == "EmailAccount" { return .equal("userId",.text(identity.id)) }
        if model == "Email" { return .every([.equal("userId",.text(identity.id)),.relation(model:"EmailAccount",local:"emailAccountId",foreign:"id",matching:scope("EmailAccount"))]) }
        if model == "EmailsToContacts" || model == "EmailsToAccounts" || model == "EmailEmbedding" {
            return .relation(model:"Email",local:"emailId",foreign:"id",matching:.every([scope("Email"),.equal("isDeleted",.integer(0))]))
        }
        if model == "crm_campaigns" {
            let live = RecordFilter.every([.equal("deletedAt",.null),.any([.equal("status",.null),.not(.equal("status",.text("deleted")))])])
            let owner: RecordFilter = identity.elevated ? .all : identity.role == "user" ? .equal("created_by",.text(identity.id)) : .none
            return .every([live,owner])
        }
        if ["crm_campaign_steps","CampaignToTargetLists","crm_campaign_sends"].contains(model) { return .relation(model:"crm_campaigns",local:"campaign_id",foreign:"id",matching:scope("crm_campaigns",write:write)) }
        if model == "crm_campaign_templates" {
            if identity.elevated { return .all }
            return identity.role == "user" ? .equal("created_by",.text(identity.id)) : .none
        }
        if model == "Documents" {
            // History inherits its root's access; a version's uploader does
            // not retain access after the root's sharing is revoked.
            let root = RecordFilter.every([.equal("parent_document_id",.null),.equal("deletedAt",.null),documentRootScope(write:write)])
            return .any([root,.every([.equal("deletedAt",.null),.relation(model:"Documents",local:"parent_document_id",foreign:"id",matching:root)])])
        }
        if model == "Documents_Types" { return write ? (identity.role == "admin" ? .all : .none) : (["admin","manager","user","partner"].contains(identity.role) ? .all : .none) }
        if model == "Boards" {
            if identity.elevated { return .all }
            guard identity.role == "user" else { return .none }
            let owner = RecordFilter.equal("user",.text(identity.id))
            return write ? owner : .any([owner,.arrayContains("sharedWith",identity.id),.equal("visibility",.text("public")),
                .relation(model:"BoardWatchers",local:"id",foreign:"board_id",matching:.equal("user_id",.text(identity.id)))])
        }
        if model == "Sections" { return .relation(model:"Boards",local:"board",foreign:"id",matching:.every([scope("Boards",write:write),.equal("deletedAt",.null)])) }
        if model == "Tasks" { return .relation(model:"Sections",local:"section",foreign:"id",matching:scope("Sections",write:write)) }
        if model == "crm_Accounts_Tasks" {
            if identity.elevated { return .all }
            if identity.role == "partner" {
                if deletion { return .none }
                let accounts = partnerAccounts(visibleOwn:false)
                return .any([.relation(model:"crm_Accounts",local:"account",foreign:"id",matching:accounts),
                    .relation(model:"crm_Opportunities",local:"opportunity_id",foreign:"id",matching:.relation(model:"crm_Accounts",local:"account",foreign:"id",matching:accounts))])
            }
            guard identity.role == "user" else { return .none }
            let own = RecordFilter.any([.equal("createdBy",.text(identity.id)),.equal("user",.text(identity.id))])
            return write ? own : .any([own,.relation(model:"crm_Accounts",local:"account",foreign:"id",matching:.every([accountOwnership,.equal("deletedAt",.null)]))])
        }
        if model == "tasksComments" { return .any([
            .relation(model:"Tasks",local:"task",foreign:"id",matching:scope("Tasks",write:write)),
            .relation(model:"crm_Accounts_Tasks",local:"assigned_crm_account_task",foreign:"id",matching:scope("crm_Accounts_Tasks",write:write,deletion:deletion))]) }
        if model == "Invoices" {
            if write { return .every([.equal("status",.text("DRAFT")),identity.elevated ? .all : identity.role == "user" ? .equal("createdBy",.text(identity.id)) : .none]) }
            if identity.elevated { return .all }
            if identity.role == "partner" { return .relation(model:"crm_Accounts",local:"accountId",foreign:"id",matching:partnerAccounts(visibleOwn:true)) }
            return identity.role == "user" ? .equal("createdBy",.text(identity.id)) : .none
        }
        if ["Invoice_LineItems","Invoice_Payments","Invoice_Activity","Invoice_Attachments"].contains(model) { return .relation(model:"Invoices",local:"invoiceId",foreign:"id",matching:scope("Invoices",write:write)) }
        if ["Invoice_Settings","Invoice_Series","Invoice_TaxRates"].contains(model) { return write ? (identity.role == "admin" ? .all : .none) : (["admin","manager","user","partner"].contains(identity.role) ? .all : .none) }
        if model == "crm_Orders" {
            if write {
                guard identity.role != "partner" else { return .none }
                return .every([.equal("source",.text("CRM")),.equal("status",.text("DRAFT")),identity.elevated ? .all : .equal("createdBy",.text(identity.id))])
            }
            if identity.elevated { return .all }
            let account: RecordFilter = .relation(model:"crm_Accounts",local:"accountId",foreign:"id",matching:identity.role == "partner" ? partnerAccounts(visibleOwn:true) : accountOwnership)
            return identity.role == "partner" ? account : identity.role == "user" ? .any([.equal("ownerId",.text(identity.id)),.equal("createdBy",.text(identity.id)),account]) : .none
        }
        if model == "crm_OrderLines" { return .relation(model:"crm_Orders",local:"orderId",foreign:"id",matching:scope("crm_Orders",write:write)) }
        if model == "NumberSeries" { return identity.role == "admin" ? .equal("scope",.text("order")) : .none }
        if let context = LineContext.forModel(model) {
            return .relation(model:context.parentModel,local:context.field,foreign:"id",matching:.every([scope(context.parentModel,write:write),.equal("deletedAt",.null)]))
        }
        if Self.catalogModels.contains(model) {
            if !write { return ["user","manager","admin","partner"].contains(identity.role) ? .all : .none }
            guard identity.elevated, !["crm_ProductCategories","ExchangeRate"].contains(model) || identity.role == "admin" else { return .none }
            if model == "crm_PriceListRules" { return .relation(model:"crm_PriceLists",local:"priceListId",foreign:"id",matching:.not(.equal("source",.text("EXTERNAL")))) }
            return model == "ExchangeRate" ? .all : .not(.equal("source",.text("EXTERNAL")))
        }
        if identity.elevated { return .all }
        guard ["user","partner"].contains(identity.role) else { return .none }
        let parent = ["crm_Contacts":"accountsIDs","crm_Leads":"accountsIDs","crm_Opportunities":"account","crm_Contracts":"account"]
        if identity.role == "partner" {
            if deletion { return .none }
            if model == "crm_Activities" { return activityLinks(write: write) }
            if model == "crm_Accounts" { return partnerAccounts(visibleOwn: !write) }
            if let field = parent[model] {
                if write && model == "crm_Contracts" { return .none }
                return .relation(model: "crm_Accounts", local: field, foreign: "id", matching: partnerAccounts(visibleOwn: !write && model == "crm_Contacts"))
            }
            if model == "Users" { return .equal("id", .text(identity.id)) }
            if Self.configurationModels.contains(model) { return .all }
            return .none
        }
        if model == "crm_Accounts" { return accountOwnership }
        if let field = parent[model] {
            return write ? ownership : .any([ownership, .relation(model: "crm_Accounts", local: field, foreign: "id", matching: .every([accountOwnership, .equal("deletedAt", .null)]))])
        }
        if model == "crm_Targets" || model == "crm_TargetLists" { return .equal("created_by", .text(identity.id)) }
        if model == "crm_Activities" { return write ? .equal("createdBy", .text(identity.id)) : .any([.equal("createdBy", .text(identity.id)), activityLinks(write: false)]) }
        if model == "Users" || Self.configurationModels.contains(model) { return .all }
        return .none
    }
    static let configurationModels = ["Currency","crm_Industry_Type","crm_Contact_Types","crm_Lead_Sources","crm_Lead_Statuses","crm_Lead_Types","crm_Opportunities_Sales_Stages","crm_Opportunities_Type"]
    func documentRootScope(write: Bool) -> RecordFilter {
        if identity.elevated { return .all }
        if identity.role == "partner", write { return .none }
        guard ["user","partner"].contains(identity.role) else { return .none }
        let links: [(String,String,String,String?)] = [("DocumentsToAccounts","account_id","crm_Accounts",nil),
                     ("DocumentsToLeads","lead_id","crm_Leads","accountsIDs"),
                     ("DocumentsToContacts","contact_id","crm_Contacts","accountsIDs"),
                     ("DocumentsToOpportunities","opportunity_id","crm_Opportunities","account")]
        let related = links.map { junction,field,model,parent -> RecordFilter in
            let access: RecordFilter
            if identity.role == "partner" {
                access = parent.map { .relation(model:"crm_Accounts",local:$0,foreign:"id",matching:partnerAccounts(visibleOwn:false)) } ?? partnerAccounts(visibleOwn:false)
            } else { access = model == "crm_Accounts" ? accountOwnership : ownership }
            return .relation(model:junction,local:"id",foreign:"document_id",matching:.relation(model:model,local:field,foreign:"id",matching:.every([.equal("deletedAt",.null),access])))
        }
        if identity.role == "partner" { return .any(related) }
        return .any(related+[.equal("created_by_user",.text(identity.id)),.equal("createdBy",.text(identity.id)),.equal("assigned_user",.text(identity.id)),.equal("visibility",.text("public"))])
    }
    func assertAccess(_ model: String, id: String, write: Bool = false, deletion: Bool = false, includeDeleted: Bool = false) throws {
        try authenticated()
        let filter = RecordFilter.every([scope(model, write: write, deletion: deletion), .equal(model == "Currency" ? "code" : "id", .text(id))])
        guard try db.page(model, fields: [], includeDeleted: includeDeleted, filter: filter).total == 1 else { throw NativeDBError.message("対象が見つからないか、操作する権限がありません。") }
    }
    func fullRecord(_ summary: NativeRecord) throws -> NativeRecord {
        try assertAccess(summary.model, id: summary["id"].string, includeDeleted: identity.role == "admin")
        guard let record = try db.get(summary.model, key: db.key(for: summary)) else { throw NativeDBError.message("対象が見つかりません。") }
        return record
    }
    func list(_ module: CRMModule, search: String = "", offset: Int = 0, trash: Bool = false, linkedTo: NativeRecord? = nil, matching: RecordFilter = .all, invoiceSort: InvoiceListSort = InvoiceListSort()) throws -> (rows: [CRMListRow], total: Int) {
        try authenticated()
        if trash && identity.role != "admin" { throw NativeDBError.message("削除済みデータは管理者のみ表示できます。") }
        var extra = RecordFilter.all
        if let parent = linkedTo, ["crm_Orders","Invoices"].contains(module.model), parent.model == "crm_Accounts" {
            try assertAccess(parent.model,id:parent["id"].string); extra = .equal("accountId",parent["id"])
        } else if let parent = linkedTo, let context = LineContext.forModel(module.model) {
            try assertAccess(parent.model,id:parent["id"].string)
            if parent.model == context.parentModel { extra = .equal(context.field,parent["id"]) }
            else if module.model == "crm_AccountProducts", parent.model == "crm_Products" { extra = .equal("productId",parent["id"]) }
            else { throw NativeDBError.message("関連先が一致しません。") }
        } else if let parent = linkedTo, module.model == "crm_PriceListRules", parent.model == "crm_PriceLists" {
            try assertAccess(parent.model,id:parent["id"].string); extra = .equal("priceListId",parent["id"])
        } else if let parent = linkedTo {
            guard module.model == "crm_Activities", let entity = CRMModule.find(parent.model)?.entity, ["account","contact","lead","opportunity","contract"].contains(entity) else { throw NativeDBError.message("活動の関連先が不正です。") }
            try assertAccess(parent.model, id: parent["id"].string, write: identity.role == "partner" && ["account","contact"].contains(entity))
            extra = .relation(model:"crm_ActivityLinks",local:"id",foreign:"activityId",matching:.every([.equal("entityType",.text(entity)),.equal("entityId",parent["id"])]))
        }
        let fields = Array(Set(module.columns.flatMap(\.fields)))
        let supportsTrash = try db.schema.model(module.model).field("deletedAt") != nil
        let filter = RecordFilter.every([scope(module.model), extra, matching, trash && supportsTrash ? .not(.equal("deletedAt", .null)) : .all])
        let isInvoice = module.model == "Invoices"
        let relationOrder = isInvoice && invoiceSort.field == .account ? RecordRelationSort(model:"crm_Accounts",local:"accountId",foreign:"id",field:"name") : nil
        let page = try db.page(module.model, fields: fields, search: search, includeDeleted: trash, offset: offset, filter: filter,
                              sort:isInvoice ? invoiceSort.field.column : module.sort,
                              descending:isInvoice ? invoiceSort.descending : ["crm_AccountProducts","crm_Orders","Tasks","Boards"].contains(module.model),
                              relatedSort:relationOrder,nullsFirst:isInvoice && !invoiceSort.descending,localizedSort:isInvoice)
        var names: [String: String] = [:]
        let date = DateFormatter(); date.locale = Locale(identifier: "ja_JP"); date.dateFormat = "yyyy/MM/dd HH:mm"
        let timestamp = ISO8601DateFormatter(); let fractionalTimestamp = ISO8601DateFormatter(); fractionalTimestamp.formatOptions.insert(.withFractionalSeconds)
        let schema = try db.schema.model(module.model)
        let rows = try page.rows.map { row -> CRMListRow in
            let cells = try module.columns.map { column -> String in
                if let target = column.relation {
                    let id = row[column.fields[0]].string; if id.isEmpty { return "—" }
                    let key = target + ":" + id
                    if let name = names[key] { return name }
                    let name = try referenceName(target, id: id); names[key] = name; return name
                }
                return column.fields.map { field -> String in
                    let value = row[field]; if module.model == "Invoices", field == "number", value == .null { return row["status"] == .text("DRAFT") ? "下書き" : "未採番" }; if value == .null { return "" }
                    if module.model == "Invoices", ["status","type"].contains(field) { return CRMModule.invoiceLabel(value.string) }
                    if module.model == "Invoices", ["dueDate","issueDate","taxableSupplyDate"].contains(field) { return String(value.string.prefix(10)).replacingOccurrences(of:"-",with:"/") }
                    if module.model == "Invoices", field == "number", value.string.isEmpty { return row["status"] == .text("DRAFT") ? "下書き" : "未採番" }
                    if module.model == "crm_Orders", field == "status" { return OrderWorkflow.labels[value.string] ?? value.string }
                    if ["Boards","Tasks"].contains(module.model), ["visibility","priority","taskStatus"].contains(field) { return CRMModule.projectLabel(value.string) }
                    if module.model == "crm_Orders", field == "orderDate" { return String(value.string.prefix(10)).replacingOccurrences(of:"-",with:"/") }
                    if field == "discount_type" { return value == .text("PERCENTAGE") ? "%" : row["currency"].string }
                    if schema.field(field)?.type == "Boolean" { return field == "do_not_email" ? (value == .integer(1) ? "停止" : "許可") : (value == .integer(1) ? "有効" : "無効") }
                    if schema.field(field)?.type == "DateTime", let parsed = timestamp.date(from: value.string) ?? fractionalTimestamp.date(from: value.string) { return date.string(from: parsed) }
                    return CRMModule.label(value.string)
                }.filter { !$0.isEmpty }.joined(separator: " ")
            }
            return CRMListRow(record: row, cells: cells)
        }
        return (rows, page.total)
    }
    func references(_ model: String, search: String, offset: Int = 0, userRole: String? = nil, matching: RecordFilter = .all) throws -> (rows: [NativeRecord], total: Int) {
        try authenticated()
        if model == "crm_Accounts" {
            return try db.textSearchPage(model, field: "name", query: search, filter: .every([scope(model), matching]), offset: offset, validate: { try self.authenticated() })
        }
        let schema = try db.schema.model(model)
        let names = CRMModule.find(model)?.nameFields ?? (model == "Currency" ? ["code","name"] : model == "Users" ? ["name","email"] : ["name"])
        let available = names.filter { schema.field($0) != nil }
        let extra: RecordFilter = model == "Users" ? .every([.equal("userStatus", .text("ACTIVE")), .equal("banned", .integer(0))]) : model == "Currency" ? .equal("isEnabled", .integer(1)) : .all
        let role: RecordFilter = model == "Users" ? userRole.map { .equal("role",.text($0)) } ?? .all : .all
        return try db.page(model, fields: available, search: search, offset: offset, filter: .every([scope(model), extra, role, matching]), sort: available.first)
    }
    func referenceName(_ model: String, id: String) throws -> String {
        guard !id.isEmpty else { return "未設定" }
        // Names of linked accounts may be visible through the parent record's authorized projection;
        // the picker and opening the related record still apply its own read scope.
        if let record = try db.get(model, key: [model == "Currency" ? "code" : "id": .text(id)]) { return CRMModule.displayName(record) }
        return "（関連先なし）"
    }
    func save(_ module: CRMModule, original: NativeRecord?, input: [String: SQLValue], linkedTo: NativeRecord? = nil) throws -> NativeRecord {
        try authenticated()
        guard module.model != "Documents" else { throw NativeDBError.message("文書の専用画面から保存してください。") }
        guard !["Boards","Sections","Tasks","crm_Accounts_Tasks","tasksComments","crm_campaign_templates","crm_campaigns","crm_campaign_steps","CampaignToTargetLists","crm_campaign_sends"].contains(module.model) else { throw NativeDBError.message("この項目の専用画面から保存してください。") }
        guard module.model != "Invoices", !module.model.hasPrefix("Invoice_") else { throw NativeDBError.message("請求書の専用画面から保存してください。") }
        guard !["crm_Orders","crm_OrderLines","NumberSeries"].contains(module.model) else { throw NativeDBError.message("受注の専用画面から保存してください。") }
        if LineContext.forModel(module.model) != nil { return try saveLine(module,original:original,input:input,linkedTo:linkedTo) }
        if Self.catalogModels.contains(module.model) { return try saveCatalog(module,original:original,input:input,linkedTo:linkedTo) }
        return try db.transaction {
            if module.model == "crm_Accounts", !Set(input.keys).isDisjoint(with: ["case_study_candidate", "case_study_approved"]) { throw NativeDBError.message("導入事例の専用画面から変更してください。") }
            guard original == nil || original?.model == module.model else { throw NativeDBError.message("編集対象の種類が一致しません。") }
            guard input.keys.allSatisfy({ key in module.fields.contains { $0.key == key } }) else { throw NativeDBError.message("変更できない項目が含まれています。") }
            if let original { try assertAccess(module.model, id: original["id"].string, write: true); try guardParentLineFields(original,changes:input) }
            else if identity.role == "partner" && !["crm_Contacts","crm_Leads","crm_Opportunities","crm_Activities"].contains(module.model) { throw NativeDBError.message("このデータを作成する権限がありません。") }
            if module.model == "crm_Activities", identity.role == "partner", original == nil && linkedTo == nil { throw NativeDBError.message("担当する取引先・連絡先・リード・商談に活動を関連付けてください。") }
            var values = input
            for field in module.fields where field.required {
                let text = (values[field.key] ?? original?[field.key] ?? .null).string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw NativeDBError.message("\(field.label)を入力してください。") }
            }
            for name in module.nameFields {
                if case let .text(text) = values[name] {
                    guard text.count <= 500 else { throw NativeDBError.message("名称は500文字以内にしてください。") }
                    values[name] = .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            for field in module.fields {
                if case let .relation(target) = field.kind, let value = values[field.key], value != .null, value != original?[field.key] {
                    if target == "crm_Accounts" { try assertAccess(target, id: value.string, write: true) }
                    else if target == "Users" {
                        let user = try db.get("Users", key: ["id": value])
                        guard user?["userStatus"] == .text("ACTIVE"), user?["banned"] == .integer(0) else { throw NativeDBError.message("有効な担当者を選択してください。") }
                    } else { try assertAccess(target, id: value.string) }
                }
            }
            let schema = try db.schema.model(module.model)
            if original == nil {
                if schema.field("v") != nil { values["v"] = .integer(0) }
                for field in ["createdBy","created_by"] where schema.field(field) != nil { values[field] = .text(identity.id) }
                if schema.field("assigned_to") != nil && (values["assigned_to"] == nil || values["assigned_to"] == .null) { values["assigned_to"] = .text(identity.id) }
            }
            if identity.role == "partner", module.model != "crm_Activities" {
                if schema.field("assigned_to") != nil { values["assigned_to"] = .text(identity.id) }
                let accountField = module.model == "crm_Opportunities" ? "account" : "accountsIDs"
                let account = values[accountField] ?? original?[accountField] ?? .null
                guard account != .null else { throw NativeDBError.message("担当する取引先を選択してください。") }
                try assertAccess("crm_Accounts", id: account.string, write: true)
            }
            for field in ["updatedBy"] where schema.field(field) != nil { values[field] = .text(identity.id) }
            for field in ["updatedAt","last_activity"] where schema.field(field) != nil { values[field] = .text(ISO8601DateFormatter().string(from: Date())) }
            if module.model == "crm_Targets", values["do_not_email"] != original?["do_not_email"] {
                values["do_not_email_at"] = values["do_not_email"] == .integer(1) ? .text(ISO8601DateFormatter().string(from: Date())) : .null
            }
            if module.model == "crm_Opportunities" {
                let stage = values["sales_stage"] ?? original?["sales_stage"] ?? .null
                if stage != .null, stage != original?["sales_stage"] {
                    let target = try db.get("crm_Opportunities_Sales_Stages", key: ["id": stage])
                    if target?["stage_kind"] == .text("qualified"), original?["approval_status"] != .text("APPROVED") { throw NativeDBError.message("この営業段階へ進むには、見積・提案の承認が必要です。先に承認を申請してください。") }
                    values["stage_entered_at"] = .text(ISO8601DateFormatter().string(from: Date()))
                }
            }
            let result = try original.map { try db.update($0, changes: values, actor: identity.id) } ?? db.insert(module.model, values: values, actor: identity.id)
            // The original lead UI/service mails only a newly selected assignee
            // other than the caller, including assignment during creation.
            if module.model == "crm_Leads", result["assigned_to"] != .null,
               result["assigned_to"] != .text(identity.id), result["assigned_to"] != original?["assigned_to"],
               let recipient = try db.get("Users", key: ["id": result["assigned_to"]]), !recipient["email"].string.isEmpty {
                let name = [result["firstName"].string, result["lastName"].string].filter { !$0.isEmpty }.joined(separator: " ")
                try db.enqueue("crm.lead_assigned", payload: ["leadId": result["id"].string, "recipientId": recipient["id"].string, "recipientEmail": recipient["email"].string, "leadName": name, "actorID": identity.id])
            }
            if let linkedTo {
                guard module.model == "crm_Activities", let parent = CRMModule.find(linkedTo.model), ["account","contact","lead","opportunity","contract"].contains(parent.entity) else { throw NativeDBError.message("活動の関連先が不正です。") }
                if identity.role == "partner" && parent.entity == "contract" { throw NativeDBError.message("契約に活動を追加する権限がありません。") }
                try assertAccess(parent.model, id: linkedTo["id"].string, write: true)
                let values: [String:SQLValue] = ["activityId":result["id"],"entityType":.text(parent.entity),"entityId":linkedTo["id"]]
                if try db.page("crm_ActivityLinks", fields: [], equal: values).total == 0 { _ = try db.insert("crm_ActivityLinks", values: values, actor: identity.id) }
            }
            try db.enqueue("crm/\(module.entity).saved", payload: ["record_id": result["id"].string, "actorID": identity.id])
            if module.model == "crm_Opportunities", result["sales_stage"] != .null, result["sales_stage"] != original?["sales_stage"] {
                try db.enqueueOpportunityStageChange(recordID: result["id"].string, toStage: result["sales_stage"].string)
            }
            if module.model == "crm_Activities", result["type"] == .text("meeting") { try db.enqueue("calendar/outbound", payload: ["activity_id":result["id"].string,"operation":result["status"] == .text("cancelled") ? "cancel" : "upsert"]) }
            else if module.model == "crm_Activities", original?["type"] == .text("meeting") { try db.enqueue("calendar/outbound", payload: ["activity_id":result["id"].string,"operation":"cancel"]) }
            return result
        }
    }
    func delete(_ record: NativeRecord, restore: Bool = false) throws {
        try authenticated()
        guard record.model != "Documents" else { throw NativeDBError.message("文書の専用画面から削除してください。") }
        guard !["Sections","Tasks","crm_Accounts_Tasks","tasksComments","crm_campaign_templates","crm_campaigns","crm_campaign_steps","CampaignToTargetLists","crm_campaign_sends"].contains(record.model) else { throw NativeDBError.message("この項目の専用画面から操作してください。") }
        guard record.model != "Invoices", !record.model.hasPrefix("Invoice_") else { throw NativeDBError.message("請求書の専用画面から操作してください。") }
        if record.model == "crm_Orders" { guard !restore else { throw NativeDBError.message("受注は復元できません。") }; try deleteOrder(record); return }
        if ["crm_OrderLines","NumberSeries"].contains(record.model) { throw NativeDBError.message("受注の専用画面から操作してください。") }
        if LineContext.forModel(record.model) != nil { guard !restore else { throw NativeDBError.message("明細は復元できません。") }; try removeLine(record); return }
        if Self.catalogModels.contains(record.model) { try deleteCatalog(record,restore:restore); return }
        if restore && identity.role != "admin" { throw NativeDBError.message("復元できるのは管理者のみです。") }
        try db.transaction {
            try assertAccess(record.model, id: record["id"].string, write: true, deletion: true, includeDeleted: restore)
            _ = try db.setDeleted(record, deleted: !restore, actor: identity.id)
            if record.model == "crm_Activities", record["type"] == .text("meeting") {
                try db.enqueue("calendar/outbound", payload: ["activity_id":record["id"].string,"operation":restore && record["status"] != .text("cancelled") ? "upsert" : "cancel"])
            }
        }
    }
    func history(_ record: NativeRecord) throws -> [[String: SQLValue]] {
        try assertAccess(record.model, id: record["id"].string, includeDeleted: identity.role == "admin")
        return try db.history(record)
    }
    func historyText(_ record: NativeRecord) throws -> String {
        let entries = try history(record)
        guard let module = CRMModule.find(record.model) else { throw NativeDBError.message("履歴の種類を確認できません。") }
        var fields = module.fields
        if record.model == "crm_Orders" { fields += [EditorField("lineCount","明細数")] }
        if record.model == "crm_Accounts" { fields += [EditorField("partnerUserId","外部パートナー",.relation("Users")),EditorField("case_study_candidate","導入事例の候補",.choice([("0","未登録"),("1","候補")])),EditorField("case_study_approved","導入事例の承認",.choice([("0","未承認"),("1","承認済み")]))] }
        if record.model == "crm_Targets" { fields += [EditorField("converted_at","変換日時",.dateTime),EditorField("converted_account_id","変換先の取引先",.relation("crm_Accounts")),EditorField("converted_contact_id","変換先の連絡先",.relation("crm_Contacts"))] }
        if record.model == "crm_Opportunities" {
            fields += [EditorField("approval_status","承認状況"),EditorField("approval_note","承認メモ"),EditorField("approval_requested_at","申請日時",.dateTime),EditorField("approved_by","承認担当者",.relation("Users")),EditorField("approved_at","承認日時",.dateTime)]
        }
        let parser = ISO8601DateFormatter(); let fractions = ISO8601DateFormatter(); fractions.formatOptions.insert(.withFractionalSeconds)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"ja_JP"); formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        func dateLabel(_ value: String) -> String { (parser.date(from:value) ?? fractions.date(from:value)).map { formatter.string(from:$0) } ?? value }
        func label(_ value: Any?, _ field: EditorField) throws -> String {
            guard let value, !(value is NSNull) else { return "未設定" }
            let text = String(describing:value); if text.isEmpty { return "未設定" }
            switch field.kind {
            case let .relation(model): return try referenceName(model,id:text)
            case let .choice(options): return options.first { $0.0 == text }?.1 ?? CRMModule.label(text)
            case .toggle: return field.key == "do_not_email" ? (text == "1" ? "配信停止" : "配信許可") : (text == "1" ? "有効" : "無効")
            case .date, .dateTime: return dateLabel(text)
            case .lines:
                let values = value as? [String] ?? (try? JSONDecoder().decode([String].self,from:Data(text.utf8))) ?? []
                return values.isEmpty ? "未設定" : values.joined(separator:"、")
            default: return CRMModule.label(text)
            }
        }
        var lines: [String] = []
        for entry in entries {
            let action = ["order_lines":"受注明細を更新","order_save":"受注を保存","order_submit":"受注を提出","order_approve":"受注を承認","order_reject":"受注を却下","order_withdraw":"受注の申請を取り下げ","order_reopen":"受注を下書きに戻す","order_cancel":"受注を取消","order_retry":"受注の連携を再試行","order_advance":"受注の状態を変更","allocate":"番号を発行","cancel":"割当取消","reorder":"明細並べ替え","line_total":"明細合計を反映","create":"登録","update":"更新","delete":"削除","restore":"復元","unlink":"関連解除","members_add":"営業対象をリストに追加","members_remove":"営業対象をリストから解除","watch":"ウォッチ開始","unwatch":"ウォッチ解除","convert":"取引先・連絡先へ変換","partner":"外部パートナー設定"][entry["action"]?.string ?? ""] ?? "変更"
            let actor = try referenceName("Users",id:entry["actor"]?.string ?? "")
            lines.append("\(dateLabel(entry["created_at"]?.string ?? ""))　\(action)　\(actor)")
            let before = (try? JSONSerialization.jsonObject(with:Data((entry["before_json"]?.string ?? "{}").utf8))) as? [String:Any] ?? [:]
            let after = (try? JSONSerialization.jsonObject(with:Data((entry["after_json"]?.string ?? "{}").utf8))) as? [String:Any] ?? [:]
            for field in fields {
                let old = try label(before[field.key],field); let new = try label(after[field.key],field)
                if old != new { lines.append("  \(field.label)：\(old) → \(new)") }
            }
            lines.append("")
        }
        return lines.isEmpty ? "履歴はありません。" : lines.joined(separator:"\n")
    }
    func approval(_ record: NativeRecord, decision: String, note: String = "") throws -> NativeRecord {
        try authenticated(); try assertAccess(record.model, id: record["id"].string, write: true)
        guard record.model == "crm_Opportunities", ["PENDING","APPROVED","REJECTED"].contains(decision), identity.role != "partner" else { throw NativeDBError.message("承認操作を実行できません。") }
        if decision != "PENDING", !identity.elevated { throw NativeDBError.message("承認・却下できるのは管理者とマネージャーです。") }
        if decision == "PENDING", ["PENDING","APPROVED"].contains(record["approval_status"].string) { throw NativeDBError.message("すでに申請中、または承認済みです。") }
        if decision != "PENDING", record["approval_status"] != .text("PENDING") { throw NativeDBError.message("承認申請中の商談を選択してください。") }
        return try db.transaction {
            var changes: [String:SQLValue] = ["approval_status": .text(decision), "approval_note": note.isEmpty ? .null : .text(note), "updatedBy": .text(identity.id)]
            if decision == "PENDING" { changes["approval_requested_at"] = .text(ISO8601DateFormatter().string(from: Date())) }
            else { changes["approved_by"] = .text(identity.id); changes["approved_at"] = .text(ISO8601DateFormatter().string(from: Date())) }
            let saved = try db.update(record, changes: changes, actor: identity.id)
            try db.enqueue("crm/opportunity.approval", payload: ["record_id":record["id"].string,"decision":decision])
            return saved
        }
    }
}
