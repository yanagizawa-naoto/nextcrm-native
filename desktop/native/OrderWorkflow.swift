import Foundation

enum OrderWorkflow {
    static let flow = ["READY","SENT","CONFIRMED","DELIVERED","INVOICED","PAID"]
    static let statuses = ["DRAFT","PENDING_APPROVAL"]+flow+["CANCELLED","SYNC_FAILED"]
    static let actions = ["edit","delete","submit","approve","reject","withdraw","reopen","cancel","retry","advance"]
    static let labels = ["DRAFT":"下書き","PENDING_APPROVAL":"承認待ち","READY":"手配待ち","SENT":"送信済み","CONFIRMED":"受注確定","DELIVERED":"納品済み","INVOICED":"請求済み","PAID":"入金済み","CANCELLED":"取消済み","SYNC_FAILED":"連携失敗"]
    static let actionLabels = ["edit":"編集","delete":"削除","submit":"提出","approve":"承認","reject":"却下","withdraw":"申請を取り下げる","reopen":"下書きに戻す","cancel":"受注を取り消す","retry":"連携を再試行","advance":"状態を進める"]
    static func next(_ status: String) -> [String] { guard let i = flow.firstIndex(of:status) else { return [] }; return Array(flow.dropFirst(i+1)) }
    static func can(status: String, source: String, creator: String?, externalRef: String?, action: String, actorID: String, role: String) -> Bool {
        guard ["user","manager","admin"].contains(role), source == "CRM" else { return false }
        let manager = role != "user"; let creator = creator == actorID; let owner = creator || manager
        switch action {
        case "edit","delete","submit": return status == "DRAFT" && owner
        case "approve","reject": return status == "PENDING_APPROVAL" && manager
        case "withdraw": return status == "PENDING_APPROVAL" && creator
        case "reopen": return status == "READY" && owner && (externalRef ?? "").isEmpty
        case "cancel": return (["PENDING_APPROVAL","READY"].contains(status) && owner) || (["SENT","CONFIRMED","DELIVERED","INVOICED","SYNC_FAILED"].contains(status) && manager)
        case "retry": return status == "SYNC_FAILED" && manager
        case "advance": return manager && !next(status).isEmpty
        default: return false
        }
    }
    static func canPluginSet(status: String, to: String) -> Bool {
        !["DRAFT","PENDING_APPROVAL","PAID","CANCELLED"].contains(status) && ["SENT","CONFIRMED","DELIVERED","INVOICED","PAID","SYNC_FAILED","CANCELLED"].contains(to) && status != to
    }
}

enum OrderNumber {
    static func year(_ date: Date) -> Int { var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!; return calendar.component(.year,from:date) }
    static func format(_ template: String, year: Int, counter: Int64) -> String {
        var output = template.replacingOccurrences(of:"{YYYY}",with:String(year))
        let pattern = try! NSRegularExpression(pattern:#"\{(#+)\}"#)
        for match in pattern.matches(in:output,range:NSRange(output.startIndex...,in:output)).reversed() {
            guard let range = Range(match.range,in:output) else { continue }; let digits = String(counter)
            output.replaceSubrange(range,with:String(repeating:"0",count:max(0,match.range(at:1).length-digits.count))+digits)
        }
        return output
    }
}

struct OrderLineInput: Codable { let productID: String; let quantity: String; let unitPrice: String? }
struct OrderPriceContext { let listID: String?; let currency: String }
struct OrderLineQuote: Codable {
    let productId: String; let productName: String; let sku: String?; let unit: String?
    let quantity: String; let listPrice: String; let priceRuleId: String?; let unitPrice: String; let unitPriceOverridden: Bool
    let vatRate: String; let lineSubtotal: String; let lineVat: String; let lineTotal: String
    var belowList: Bool { (try? PriceDecimal.parse(unitPrice) < PriceDecimal.parse(listPrice)) == true }
    var input: OrderLineInput { OrderLineInput(productID:productId,quantity:quantity,unitPrice:unitPriceOverridden ? unitPrice : nil) }
    var values: [String:SQLValue] {
        ["productId":.text(productId),"productName":.text(productName),"sku":sku.map(SQLValue.text) ?? .null,"unit":unit.map(SQLValue.text) ?? .null,
         "quantity":.text(quantity),"listPrice":.text(listPrice),"priceRuleId":priceRuleId.map(SQLValue.text) ?? .null,"unitPrice":.text(unitPrice),"unitPriceOverridden":.integer(unitPriceOverridden ? 1 : 0),
         "vatRate":.text(vatRate),"lineSubtotal":.text(lineSubtotal),"lineVat":.text(lineVat),"lineTotal":.text(lineTotal)]
    }
    static func from(_ record: NativeRecord) -> Self {
        Self(productId:record["productId"].string,productName:record["productName"].string,sku:record["sku"] == .null ? nil : record["sku"].string,unit:record["unit"] == .null ? nil : record["unit"].string,
             quantity:record["quantity"].string,listPrice:record["listPrice"].string,priceRuleId:record["priceRuleId"] == .null ? nil : record["priceRuleId"].string,unitPrice:record["unitPrice"].string,unitPriceOverridden:record["unitPriceOverridden"] == .integer(1),vatRate:record["vatRate"].string,lineSubtotal:record["lineSubtotal"].string,lineVat:record["lineVat"].string,lineTotal:record["lineTotal"].string)
    }
}
struct OrderDraftRow: Codable { let id: String; let input: OrderLineInput; let quote: OrderLineQuote }
struct OrderTotals {
    private var net = Decimal(0); private var tax = Decimal(0); private var reduction = Decimal(0)
    private(set) var belowList = false; private(set) var count = 0
    mutating func add(_ line: OrderLineQuote) throws {
        net = try LineItemMath.calculate(net,"+",PriceDecimal.parse(line.lineSubtotal)); tax = try LineItemMath.calculate(tax,"+",PriceDecimal.parse(line.lineVat))
        let difference = try LineItemMath.calculate(PriceDecimal.parse(line.listPrice),"-",PriceDecimal.parse(line.unitPrice))
        if difference > 0 { reduction = try LineItemMath.calculate(reduction,"+",LineItemMath.calculate(difference,"*",PriceDecimal.parse(line.quantity))) }
        belowList = belowList || line.belowList; count += 1
    }
    var discount: String { PriceDecimal.string(PriceDecimal.rounded(reduction)) }
    func values() throws -> [String:SQLValue] { ["subtotal":.text(PriceDecimal.string(PriceDecimal.rounded(net))),"vatTotal":.text(PriceDecimal.string(PriceDecimal.rounded(tax))),"grandTotal":.text(PriceDecimal.string(PriceDecimal.rounded(try LineItemMath.calculate(net,"+",tax))))] }
}
