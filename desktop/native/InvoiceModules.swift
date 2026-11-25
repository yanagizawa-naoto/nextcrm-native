import Foundation

struct InvoiceListSort {
    enum Field: String, CaseIterable {
        case number, account, issueDate, dueDate, grandTotal, status
        var label: String { switch self {
        case .number: return "番号"; case .account: return "取引先"; case .issueDate: return "発行日"
        case .dueDate: return "支払期限"; case .grandTotal: return "合計"; case .status: return "状態"
        } }
        var column: String { self == .account ? "accountId" : rawValue }
    }
    var field: Field = .issueDate
    var descending = true
    mutating func toggle(_ next: Field) { descending = field == next ? !descending : false; field = next }
}

/// Invoice dates are calendar dates encoded at UTC midnight, independent of local offsets.
enum InvoiceCalendar {
    static var utc: Calendar { var c = Calendar(identifier:.gregorian); c.timeZone = TimeZone(secondsFromGMT:0)!; return c }
    static func today(_ now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier:.gregorian); local.timeZone = timeZone
        return utc.date(from:local.dateComponents([.year,.month,.day],from:now))!
    }
    static func canonical(_ date: Date) -> Date { utc.startOfDay(for:date) }
}

extension CRMModule {
    static let invoiceStatuses = [("DRAFT","下書き"),("ISSUED","発行済み"),("SENT","送信済み"),("PARTIALLY_PAID","一部入金"),("PAID","入金済み"),("OVERDUE","支払期限超過"),("CANCELLED","取消済み"),("DISPUTED","異議申立て中"),("REFUNDED","返金済み"),("WRITTEN_OFF","貸倒処理済み")]
    static let invoiceTypes = [("INVOICE","請求書"),("CREDIT_NOTE","返金・減額伝票"),("PROFORMA","仮請求書")]
    static let paymentMethods = [("Bank Transfer","銀行振込"),("Cash","現金"),("Card","カード"),("Check","小切手"),("PayPal","PayPal"),("Other","その他")]
    static let invoiceEvents = [("CREATED","下書きを作成"),("UPDATED","下書きを更新"),("ISSUED","発行"),("CANCELLED","取消"),("DUPLICATED","複製"),("PAYMENT_ADDED","入金を登録"),("PAYMENT_DELETED","入金を削除"),("SENT","メールを送信"),("EMAIL_SENT","メールを送信"),("EMAIL_REVIEWED","メールの結果を確認")]
    static func invoiceLabel(_ value: String) -> String { (invoiceStatuses+invoiceTypes+paymentMethods+invoiceEvents).first { $0.0 == value }?.1 ?? value }
    static let invoices = CRMModule(model:"Invoices",title:"請求書",singular:"請求書",entity:"invoice",nameFields:["number"],columns:[CRMColumn("番号","number",0.17),CRMColumn("取引先","accountId",0.19,relation:"crm_Accounts"),CRMColumn("種類","type",0.10),CRMColumn("状態","status",0.10),CRMColumn("合計","grandTotal+currency",0.18),CRMColumn("発行日","issueDate",0.13),CRMColumn("支払期限","dueDate",0.13)],fields:[
        EditorField("accountId","取引先",.relation("crm_Accounts"),required:true),EditorField("type","種類",.choice(invoiceTypes),required:true),EditorField("seriesId","採番系列",.relation("Invoice_Series")),EditorField("currency","通貨",.relation("Currency"),required:true),
        EditorField("issueDate","発行日",.date),EditorField("taxableSupplyDate","取引日",.date),EditorField("dueDate","支払期限",.date),
        EditorField("bankName","銀行名"),EditorField("bankAccount","口座番号"),EditorField("iban","IBAN"),EditorField("swift","SWIFT"),EditorField("variableSymbol","支払参照番号"),EditorField("publicNotes","請求書に記載する備考",.multiline),EditorField("internalNotes","社内メモ",.multiline)])
    static let invoiceSeries = CRMModule(model:"Invoice_Series",title:"請求書の採番系列",singular:"採番系列",entity:"invoiceSeries",nameFields:["name"],columns:[CRMColumn("名称","name",0.30),CRMColumn("書式","prefixTemplate",0.35),CRMColumn("連番","counter",0.15),CRMColumn("有効","active",0.20)],fields:[EditorField("name","名称",required:true),EditorField("prefixTemplate","書式（例 INV-{YYYY}-{####}）",required:true),EditorField("resetPolicy","連番のリセット",.choice([("YEARLY","毎年"),("NEVER","リセットしない")])),EditorField("isDefault","標準の候補",.toggle),EditorField("active","有効",.toggle)])
    static let invoiceTax = CRMModule(model:"Invoice_TaxRates",title:"請求書の税率",singular:"税率",entity:"invoiceTax",nameFields:["name"],columns:[CRMColumn("名称","name",0.50),CRMColumn("税率（%）","rate",0.30),CRMColumn("有効","active",0.20)],fields:[EditorField("name","名称",required:true),EditorField("rate","税率（%）",.number,required:true),EditorField("isDefault","標準の候補",.toggle),EditorField("active","有効",.toggle)])
    static let invoiceCompany = CRMModule(model:"Invoice_Settings",title:"請求書の会社設定",singular:"請求書の会社設定",entity:"invoiceSettings",nameFields:["companyName"],columns:[],fields:[
        EditorField("companyName","会社名",required:true),EditorField("companyAddress","住所・番地",required:true),EditorField("companyCity","市区町村",required:true),EditorField("companyZip","郵便番号",required:true),EditorField("companyCountry","国・地域",required:true),EditorField("companyRegNo","法人番号",required:true),EditorField("companyVatId","税務登録番号"),EditorField("companyTaxId","税番号"),EditorField("companyEmail","メール"),EditorField("companyPhone","電話"),EditorField("companyWebsite","Webサイト"),
        EditorField("baseCurrency","基準通貨",.relation("Currency"),required:true),EditorField("defaultDueDays","支払期限までの日数",.number,required:true),EditorField("defaultSeriesId","標準の採番系列",.relation("Invoice_Series")),EditorField("defaultTaxRateId","標準税率",.relation("Invoice_TaxRates")),EditorField("bankName","銀行名"),EditorField("bankAccount","口座番号"),EditorField("iban","IBAN"),EditorField("swift","SWIFT"),EditorField("footerText","PDFの末尾の文章",.multiline)])
    static let invoicePayments = CRMModule(model:"Invoice_Payments",title:"入金履歴",singular:"入金",entity:"invoicePayment",nameFields:["reference"],columns:[CRMColumn("入金日","paidAt",0.22),CRMColumn("金額","amount",0.20),CRMColumn("方法","method",0.20),CRMColumn("参照番号","reference",0.38)],fields:[EditorField("amount","入金額",.number,required:true),EditorField("paidAt","入金日",.date,required:true),EditorField("method","入金方法",.choice(paymentMethods),required:true),EditorField("reference","参照番号"),EditorField("note","備考",.multiline)])
    static let invoiceActivity = CRMModule(model:"Invoice_Activity",title:"請求書の履歴",singular:"履歴",entity:"invoiceActivity",nameFields:["action"],columns:[CRMColumn("日時","createdAt",0.30),CRMColumn("操作","action",0.40),CRMColumn("利用者","actorId",0.30,relation:"Users")],fields:[EditorField("createdAt","日時",.dateTime),EditorField("action","操作",.choice(invoiceEvents)),EditorField("actorId","利用者",.relation("Users")),EditorField("meta","詳細",.multiline)])
    static let invoiceLine = CRMModule(model:"Invoice_LineItems",title:"請求明細",singular:"請求明細",entity:"invoiceLine",nameFields:["description"],columns:[],fields:[EditorField("productId","商品（任意）",.relation("crm_Products")),EditorField("description","品名・内容",.multiline,required:true),EditorField("quantity","数量",.number,required:true),EditorField("unitPrice","単価",.number,required:true),EditorField("discountPercent","値引率（%）",.number,required:true),EditorField("taxRateId","税率",.relation("Invoice_TaxRates"))])
    static let invoiceModules = [invoiceSeries,invoiceTax,invoiceCompany,invoicePayments,invoiceActivity,invoiceLine]
}
