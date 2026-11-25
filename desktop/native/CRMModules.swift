import Foundation

enum EditorKind {
    case text, multiline, number, signedNumber, date, dateTime, toggle, lines
    case choice([(String, String)]), relation(String)
}
struct EditorField {
    let key: String; let label: String; let kind: EditorKind; let required: Bool
    init(_ key: String, _ label: String, _ kind: EditorKind = .text, required: Bool = false) {
        self.key = key; self.label = label; self.kind = kind; self.required = required
    }
}
struct CRMColumn {
    let label: String; let fields: [String]; let fraction: Double; let relation: String?
    init(_ label: String, _ field: String, _ fraction: Double, relation: String? = nil) {
        self.label = label; self.fields = field.components(separatedBy: "+"); self.fraction = fraction; self.relation = relation
    }
}
struct CRMModule {
    let model: String; let title: String; let singular: String; let entity: String
    let nameFields: [String]; let columns: [CRMColumn]; let fields: [EditorField]
    var sort: String { model == "Boards" ? "updatedAt" : ["Tasks","Sections"].contains(model) ? "position" : LineContext.forModel(model)?.totalField != nil ? "sort_order" : ["crm_AccountProducts","crm_Orders","Invoices"].contains(model) ? "createdAt" : nameFields.first ?? "id" }
    static let active = [("Active", "有効"), ("Inactive", "無効")]
    static let owner = EditorField("assigned_to", "担当者", .relation("Users"))
    static let description = EditorField("description", "説明・メモ", .multiline)
    static let all: [CRMModule] = [
        CRMModule(model: "crm_Accounts", title: "取引先", singular: "取引先", entity: "account", nameFields: ["name"],
            columns: [CRMColumn("会社名", "name", 0.30), CRMColumn("担当者", "assigned_to", 0.16, relation: "Users"), CRMColumn("メール", "email", 0.25), CRMColumn("電話", "office_phone", 0.18), CRMColumn("状態", "status", 0.11)],
            fields: [EditorField("name", "会社名", required: true), EditorField("email", "メール"), EditorField("office_phone", "電話番号"), EditorField("website", "Webサイト"), EditorField("status", "状態", .choice(active)), owner,
                     EditorField("pricelist_id", "価格表", .relation("crm_PriceLists")), EditorField("industry", "業種", .relation("crm_Industry_Type")), EditorField("type", "区分", .choice([("Customer","顧客"),("Partner","パートナー"),("Prospect","見込み顧客"),("Other","その他")])),
                     EditorField("company_id", "法人番号"), EditorField("vat", "税務登録番号"), EditorField("annual_revenue", "年間売上"), EditorField("employees", "従業員数"), EditorField("fax", "FAX"),
                     EditorField("billing_postal_code", "請求先 郵便番号"), EditorField("billing_state", "請求先 都道府県"), EditorField("billing_city", "請求先 市区町村"), EditorField("billing_street", "請求先 番地・建物"), EditorField("billing_country", "請求先 国・地域"),
                     EditorField("shipping_postal_code", "送付先 郵便番号"), EditorField("shipping_state", "送付先 都道府県"), EditorField("shipping_city", "送付先 市区町村"), EditorField("shipping_street", "送付先 番地・建物"), EditorField("shipping_country", "送付先 国・地域"), description]),
        CRMModule(model: "crm_Contacts", title: "連絡先", singular: "連絡先", entity: "contact", nameFields: ["last_name", "first_name"],
            columns: [CRMColumn("氏名", "last_name+first_name", 0.24), CRMColumn("取引先", "accountsIDs", 0.24, relation: "crm_Accounts"), CRMColumn("メール", "email", 0.26), CRMColumn("電話", "mobile_phone", 0.16), CRMColumn("状態", "status", 0.10)],
            fields: [EditorField("last_name", "姓", required: true), EditorField("first_name", "名"), EditorField("accountsIDs", "取引先", .relation("crm_Accounts")), EditorField("position", "役職"), owner,
                     EditorField("email", "業務メール"), EditorField("personal_email", "個人メール"), EditorField("office_phone", "勤務先電話"), EditorField("mobile_phone", "携帯電話"), EditorField("website", "Webサイト"),
                     EditorField("contact_type_id", "連絡先区分", .relation("crm_Contact_Types")), EditorField("birthday", "誕生日（日/月/年）"), EditorField("status", "有効", .toggle),
                     EditorField("social_linkedin", "LinkedIn"), EditorField("social_twitter", "X / Twitter"), EditorField("social_facebook", "Facebook"), EditorField("social_instagram", "Instagram"), EditorField("social_skype", "Skype"), EditorField("social_youtube", "YouTube"), EditorField("social_tiktok", "TikTok"), EditorField("tags", "タグ（1行ずつ）", .lines), EditorField("notes", "メモ（1行ずつ）", .lines), description]),
        CRMModule(model: "crm_Leads", title: "リード", singular: "リード", entity: "lead", nameFields: ["lastName", "firstName"],
            columns: [CRMColumn("氏名", "lastName+firstName", 0.22), CRMColumn("会社名", "company", 0.25), CRMColumn("メール", "email", 0.28), CRMColumn("状態", "lead_status_id", 0.25, relation: "crm_Lead_Statuses")],
            fields: [EditorField("lastName", "姓", required: true), EditorField("firstName", "名"), EditorField("company", "会社名"), EditorField("jobTitle", "役職"), EditorField("email", "メール"), EditorField("phone", "電話番号"), owner,
                     EditorField("accountsIDs", "取引先", .relation("crm_Accounts")), EditorField("lead_source_id", "流入元", .relation("crm_Lead_Sources")), EditorField("lead_status_id", "状態", .relation("crm_Lead_Statuses")), EditorField("lead_type_id", "種別", .relation("crm_Lead_Types")), EditorField("refered_by", "紹介者"), EditorField("campaign", "キャンペーン"), description]),
        CRMModule(model: "crm_Opportunities", title: "商談", singular: "商談", entity: "opportunity", nameFields: ["name"],
            columns: [CRMColumn("商談名", "name", 0.30), CRMColumn("取引先", "account", 0.24, relation: "crm_Accounts"), CRMColumn("段階", "sales_stage", 0.20, relation: "crm_Opportunities_Sales_Stages"), CRMColumn("見込売上", "expected_revenue+currency", 0.16), CRMColumn("承認", "approval_status", 0.10)],
            fields: [EditorField("name", "商談名", required: true), EditorField("account", "取引先", .relation("crm_Accounts")), EditorField("contact", "連絡先", .relation("crm_Contacts")), owner,
                     EditorField("type", "商談種別", .relation("crm_Opportunities_Type")), EditorField("sales_stage", "営業段階", .relation("crm_Opportunities_Sales_Stages")), EditorField("currency", "通貨", .relation("Currency")), EditorField("budget", "予算", .number), EditorField("expected_revenue", "見込売上", .number),
                     EditorField("close_date", "成約予定日", .date), EditorField("delivery_deadline", "納期", .date), EditorField("next_step", "次のアクション"), description]),
        CRMModule(model: "crm_Contracts", title: "契約", singular: "契約", entity: "contract", nameFields: ["title"],
            columns: [CRMColumn("契約名", "title", 0.30), CRMColumn("取引先", "account", 0.25, relation: "crm_Accounts"), CRMColumn("契約金額", "value+currency", 0.20), CRMColumn("終了日", "endDate", 0.15), CRMColumn("状態", "status", 0.10)],
            fields: [EditorField("title", "契約名", required: true), EditorField("account", "取引先", .relation("crm_Accounts")), owner, EditorField("value", "契約金額", .number, required: true), EditorField("currency", "通貨", .relation("Currency")),
                     EditorField("status", "状態", .choice([("NOTSTARTED","未開始"),("INPROGRESS","進行中"),("SIGNED","締結済み")])), EditorField("type", "契約種別"), EditorField("startDate", "開始日", .date), EditorField("endDate", "終了日", .date), EditorField("renewalReminderDate", "更新通知日", .date), EditorField("customerSignedDate", "顧客署名日", .date), EditorField("companySignedDate", "自社署名日", .date), description]),
        CRMModule(model: "crm_Activities", title: "活動", singular: "活動", entity: "activity", nameFields: ["title"],
            columns: [CRMColumn("件名", "title", 0.38), CRMColumn("種別", "type", 0.15), CRMColumn("日時", "date", 0.28), CRMColumn("状態", "status", 0.19)],
            fields: [EditorField("title", "件名", required: true), EditorField("type", "種別", .choice([("call","電話"),("meeting","会議"),("note","メモ"),("email","メール"),("visit","訪問")])), EditorField("date", "日時", .dateTime, required: true), EditorField("duration", "所要時間（分）", .number), EditorField("status", "状態", .choice([("scheduled","予定"),("completed","完了"),("cancelled","取消")])), EditorField("outcome", "結果"), description]),
        CRMModule(model: "crm_Targets", title: "営業対象", singular: "営業対象", entity: "target", nameFields: ["last_name", "first_name"],
            columns: [CRMColumn("氏名", "last_name+first_name", 0.20), CRMColumn("会社名", "company", 0.23), CRMColumn("メール", "email", 0.27), CRMColumn("配信停止", "do_not_email", 0.10), CRMColumn("変換日時", "converted_at", 0.20)],
            fields: [EditorField("last_name", "姓", required: true), EditorField("first_name", "名"), EditorField("company", "会社名"), EditorField("position", "役職"), EditorField("email", "メール"), EditorField("personal_email", "個人メール"), EditorField("company_email", "会社メール"), EditorField("mobile_phone", "携帯電話"), EditorField("office_phone", "勤務先電話"), EditorField("company_phone", "会社電話"), EditorField("company_website", "会社Webサイト"), EditorField("personal_website", "個人Webサイト"), EditorField("city", "市区町村"), EditorField("country", "国・地域"), EditorField("industry", "業種"), EditorField("employees", "従業員数"), EditorField("social_linkedin", "LinkedIn"), EditorField("social_x", "X"), EditorField("social_facebook", "Facebook"), EditorField("social_instagram", "Instagram"), EditorField("status", "有効", .toggle), EditorField("do_not_email", "メール配信を停止", .toggle), EditorField("tags", "タグ（1行ずつ）", .lines), EditorField("notes", "メモ（1行ずつ）", .lines), description]),
        CRMModule(model: "crm_TargetLists", title: "対象リスト", singular: "対象リスト", entity: "targetList", nameFields: ["name"],
            columns: [CRMColumn("リスト名", "name", 0.70), CRMColumn("状態", "status", 0.30)],
            fields: [EditorField("name", "リスト名", required: true), EditorField("status", "有効", .toggle), description])
    ] + catalog + [orders,invoices,projects,documents]
    static let documentTypes = [("RECEIPT","領収書"),("CONTRACT","契約書"),("OFFER","提案書・見積書"),("OTHER","その他")]
    static let documentProcessing = [("PENDING","処理待ち"),("PROCESSING","処理中"),("READY","処理済み"),("FAILED","処理失敗")]
    static let documents = CRMModule(model:"Documents",title:"文書",singular:"文書",entity:"document",nameFields:["document_name"],
        columns:[CRMColumn("文書名","document_name",0.4),CRMColumn("区分","document_system_type",0.18),CRMColumn("形式","document_file_mimeType",0.18),CRMColumn("サイズ","size",0.12),CRMColumn("版","version",0.12)],
        fields:[EditorField("document_name","文書名",required:true),EditorField("description","説明",.multiline),EditorField("document_system_type","区分",.choice(documentTypes)),
                EditorField("document_type","文書の種類",.relation("Documents_Types")),EditorField("assigned_user","担当者",.relation("Users")),
                EditorField("visibility","公開範囲",.choice([("private","非公開"),("public","内部利用者に公開")])),EditorField("tags","タグ（1行ずつ）",.lines),EditorField("favourite","お気に入り",.toggle)])
    static let projectPriorities = [("low","低"),("normal","通常"),("high","高")]
    static let projectStates = [("ACTIVE","未完了"),("PENDING","保留"),("COMPLETE","完了")]
    static let projects = CRMModule(model:"Boards",title:"プロジェクト",singular:"プロジェクト",entity:"project",nameFields:["title"],
        columns:[CRMColumn("プロジェクト名","title",0.48),CRMColumn("所有者","user",0.22,relation:"Users"),CRMColumn("公開範囲","visibility",0.14),CRMColumn("更新日","updatedAt",0.16)],
        fields:[EditorField("title","プロジェクト名",required:true),EditorField("description","説明",.multiline,required:true),EditorField("visibility","公開範囲",.choice([("private","非公開"),("public","全利用者")]))])
    static let projectSection = CRMModule(model:"Sections",title:"セクション",singular:"セクション",entity:"section",nameFields:["title"],columns:[CRMColumn("セクション名","title",1)],fields:[EditorField("title","セクション名",required:true)])
    static let projectTask = CRMModule(model:"Tasks",title:"タスク",singular:"タスク",entity:"task",nameFields:["title"],
        columns:[CRMColumn("タスク名","title",0.42),CRMColumn("担当者","user",0.2,relation:"Users"),CRMColumn("期限","dueDateAt",0.2),CRMColumn("優先度","priority",0.08),CRMColumn("状態","taskStatus",0.1)],
        fields:[EditorField("title","タスク名",required:true),EditorField("content","内容",.multiline),EditorField("user","担当者",.relation("Users")),EditorField("priority","優先度",.choice(projectPriorities),required:true),EditorField("dueDateAt","期限",.dateTime)])
    static let projectComment = CRMModule(model:"tasksComments",title:"コメント",singular:"コメント",entity:"taskComment",nameFields:["comment"],columns:[CRMColumn("コメント","comment",0.7),CRMColumn("投稿者","user",0.3,relation:"Users")],fields:[EditorField("comment","コメント",.multiline,required:true)])
    static func projectLabel(_ value: String) -> String { ["private":"非公開","public":"全利用者","low":"低","normal":"通常","high":"高","ACTIVE":"未完了","PENDING":"保留","COMPLETE":"完了"][value] ?? value }
    static let crmTaskPriorities = [("low","低"),("medium","中"),("high","高"),("critical","緊急")]
    static let crmTask = CRMModule(model:"crm_Accounts_Tasks",title:"CRMタスク",singular:"CRMタスク",entity:"crmTask",nameFields:["title"],columns:projectTask.columns,
        fields:[EditorField("title","タスク名",required:true),EditorField("content","内容",.multiline,required:true),EditorField("user","担当者",.relation("Users"),required:true),EditorField("priority","優先度",.choice(crmTaskPriorities),required:true),EditorField("dueDateAt","期限",.dateTime)])
    static func find(_ model: String) -> CRMModule? { (all + [priceRule,orderSettings,projectSection,projectTask,projectComment,crmTask] + lineModules + invoiceModules).first { $0.model == model } }
    static func displayName(_ record: NativeRecord) -> String {
        if record.model == "Invoices", record["number"].string.isEmpty { return record["status"] == .text("DRAFT") ? "下書きの請求書" : "未採番の請求書" }
        if record.model == "crm_AccountProducts" { return "商品割当" }
        let names = find(record.model)?.nameFields ?? (record.model == "Currency" ? ["code", "name"] : record.model == "Users" ? ["name", "email"] : ["name"])
        let result = names.map { record.model == "crm_PriceListRules" ? label(record[$0].string) : record[$0].string }.filter { !$0.isEmpty }.joined(separator: " ")
        return result.isEmpty ? "（名称未設定）" : result
    }
    static func label(_ value: String) -> String {
        ["EXPIRED":"期限切れ","CANCELLED":"取消済み","PRODUCT":"商品","SERVICE":"サービス","DRAFT":"下書き","ARCHIVED":"アーカイブ","CRM":"手動管理","EXTERNAL":"外部管理","ALL":"全商品","CATEGORY":"カテゴリ","FIXED":"固定単価","PERCENTAGE":"割引率","FORMULA":"計算式","LIST_PRICE":"販売単価","COST":"原価","PRICE_LIST":"別の価格表","MONTHLY":"毎月","QUARTERLY":"3か月ごと","ANNUALLY":"毎年","ONE_TIME":"一括","MANUAL":"手動","Active":"有効","Inactive":"無効","ACTIVE":"有効","INACTIVE":"無効","PENDING":"確認待ち","CLOSED":"終了","NONE":"未申請","APPROVED":"承認済み","REJECTED":"却下","NOTSTARTED":"未開始","INPROGRESS":"進行中","SIGNED":"締結済み","call":"電話","meeting":"会議","note":"メモ","email":"メール","visit":"訪問","scheduled":"予定","completed":"完了","cancelled":"取消"][value] ?? value
    }
}
