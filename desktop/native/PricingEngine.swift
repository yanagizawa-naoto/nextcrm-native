import Foundation

/// Decimal.js-compatible 20 significant digit arithmetic for lib/pricing/engine.ts.
/// Display rounding happens only at the boundary; rule selection uses exact stored decimals.
enum PriceDecimal {
    static func parse(_ value: String) throws -> Decimal {
        guard value.count <= 64, value.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options:.regularExpression) != nil,
              let result = Decimal(string:value,locale:Locale(identifier:"en_US_POSIX")), !result.isNaN else {
            throw NativeDBError.message("金額・数量の形式が不正です。")
        }
        return result
    }
    static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal:value).stringValue }
    static func rounded(_ value: Decimal, scale: Int = 2) -> Decimal {
        var value = value; var result = Decimal(); NSDecimalRound(&result,&value,scale,.plain); return result
    }
    static func calculate(_ a: Decimal, _ op: String, _ b: Decimal) throws -> Decimal {
        var a = a; var b = b; var result = Decimal(); let error: Decimal.CalculationError
        switch op {
        case "+": error = NSDecimalAdd(&result,&a,&b,.plain)
        case "-": error = NSDecimalSubtract(&result,&a,&b,.plain)
        case "*": error = NSDecimalMultiply(&result,&a,&b,.plain)
        default: error = NSDecimalDivide(&result,&a,&b,.plain)
        }
        guard error == .noError || error == .lossOfPrecision, !result.isNaN else { throw NativeDBError.message("価格の計算可能な範囲を超えています。") }
        if result == 0 { return 0 }
        let text = string(result < 0 ? -result : result)
        let parts = text.split(separator:".",omittingEmptySubsequences:false)
        let digits = parts[0].drop(while: { $0 == "0" }).count
        let scale = digits > 0 ? 20-digits : 20+(parts.count > 1 ? parts[1].prefix(while: { $0 == "0" }).count : 0)
        return rounded(result,scale:scale)
    }
}

enum PricingEngine {
    struct Product: Codable { let id: String; let unitPrice: String; let unitCost: String?; let currency: String; let categoryId: String? }
    struct Rule: Codable {
        let id: String; let appliesTo: String; let categoryId: String?; let productId: String?
        let minQuantity: String; let dateStart: String?; let dateEnd: String?
        let computePrice: String; let fixedPrice: String?; let percentPrice: String?
        let base: String; let basePriceListId: String?
        let priceDiscount: String; let priceSurcharge: String; let priceRound: String?
        let priceMinMargin: String?; let priceMaxMargin: String?; let createdAt: String
    }
    struct Step: Codable { let label: String; let value: String }
    struct Result: Codable { let price: String; let currency: String; let listPrice: String; let ruleId: String?; let steps: [Step] }
    static func date(_ text: String) throws -> Date {
        let f = ISO8601DateFormatter()
        if let date = f.date(from:text) { return date }
        f.formatOptions.insert(.withFractionalSeconds)
        guard let date = f.date(from:text) else { throw NativeDBError.message("価格の適用日が不正です。") }; return date
    }
    static func day(_ text: String) throws -> String { String(ISO8601DateFormatter().string(from:try date(text)).prefix(10)) }
    static func applicable(_ r: Rule, product: Product, chain: [String], quantity: Decimal, date: String) throws -> Bool {
        guard r.appliesTo == "ALL" || r.appliesTo == "PRODUCT" && r.productId == product.id || r.appliesTo == "CATEGORY" && chain.contains(r.categoryId ?? "") else { return false }
        guard try PriceDecimal.parse(r.minQuantity) <= quantity else { return false }
        let today = try day(date)
        if let start = r.dateStart, try day(start) > today { return false }
        if let end = r.dateEnd, try day(end) < today { return false }
        return true
    }
    static func precedes(_ a: Rule, _ b: Rule, chain: [String]) throws -> Bool {
        let ranks = ["PRODUCT":0,"CATEGORY":1,"ALL":2]
        guard let ar = ranks[a.appliesTo], let br = ranks[b.appliesTo] else { throw NativeDBError.message("価格ルールの対象が不正です。") }
        if ar != br { return ar < br }
        let aq = try PriceDecimal.parse(a.minQuantity); let bq = try PriceDecimal.parse(b.minQuantity)
        if aq != bq { return aq > bq }
        let ad = chain.firstIndex(of:a.categoryId ?? "") ?? -1; let bd = chain.firstIndex(of:b.categoryId ?? "") ?? -1
        if a.appliesTo == "CATEGORY", ad != bd { return ad < bd }
        let at = try date(a.createdAt); let bt = try date(b.createdAt)
        return at == bt ? a.id > b.id : at > bt
    }
    static func compute(product: Product, listID: String?, quantity: Decimal, date: String,
                        resolve: (String) throws -> (currency: String, rule: Rule?),
                        rate: (String,String) throws -> Decimal, depth: Int = 0,
                        depthFailure: ((String) -> Error)? = nil) throws -> Result {
        guard depth <= 10 else { throw depthFailure?(listID ?? "") ?? NativeDBError.message("価格表の参照が10段階を超えています。循環参照を確認してください。") }
        let unitPrice = try PriceDecimal.parse(product.unitPrice)
        guard let listID else { return Result(price:product.unitPrice,currency:product.currency,listPrice:product.unitPrice,ruleId:nil,steps:[Step(label:"fallback",value:product.unitPrice)]) }
        let list = try resolve(listID)
        func convert(_ amount: Decimal, from: String) throws -> Decimal { try PriceDecimal.calculate(amount,"*",rate(from,list.currency)) }
        let listPrice = try convert(unitPrice,from:product.currency)
        func result(_ price: Decimal, _ id: String?, _ steps: [Step]) -> Result { Result(price:PriceDecimal.string(price),currency:list.currency,listPrice:PriceDecimal.string(listPrice),ruleId:id,steps:steps) }
        guard let r = list.rule else { return result(listPrice,nil,[Step(label:"fallback",value:PriceDecimal.string(listPrice))]) }
        if r.computePrice == "FIXED" { let price = try PriceDecimal.parse(r.fixedPrice ?? "0"); return result(price,r.id,[Step(label:"fixed",value:PriceDecimal.string(price))]) }
        let base: Decimal
        if r.base == "COST" { base = try convert(PriceDecimal.parse(product.unitCost ?? "0"),from:product.currency) }
        else if r.base == "PRICE_LIST", let baseID = r.basePriceListId {
            let inner = try compute(product:product,listID:baseID,quantity:quantity,date:date,resolve:resolve,rate:rate,depth:depth+1,depthFailure:depthFailure)
            base = try convert(PriceDecimal.parse(inner.price),from:inner.currency)
        } else { base = listPrice }
        var steps = [Step(label:"base",value:PriceDecimal.string(base))]
        func discount(_ percentage: String) throws -> Decimal { try PriceDecimal.calculate(base,"-",PriceDecimal.calculate(PriceDecimal.calculate(base,"*",PriceDecimal.parse(percentage)),"/",100)) }
        if r.computePrice == "PERCENTAGE" {
            let price = try discount(r.percentPrice ?? "0"); steps.append(Step(label:"percentage",value:PriceDecimal.string(price))); return result(price,r.id,steps)
        }
        guard r.computePrice == "FORMULA" else { throw NativeDBError.message("価格ルールの計算方法が不正です。") }
        var price = try discount(r.priceDiscount); steps.append(Step(label:"discount",value:PriceDecimal.string(price)))
        for (label,raw) in [("round",r.priceRound),("surcharge",Optional(r.priceSurcharge)),("minMargin",r.priceMinMargin),("maxMargin",r.priceMaxMargin)] {
            guard let raw else { continue }; let amount = try PriceDecimal.parse(raw); if amount == 0 { continue }
            switch label {
            case "round": price = try PriceDecimal.calculate(PriceDecimal.rounded(PriceDecimal.calculate(price,"/",amount),scale:0),"*",amount)
            case "surcharge": price = try PriceDecimal.calculate(price,"+",amount)
            case "minMargin": price = try max(price,PriceDecimal.calculate(base,"+",amount))
            default: price = try min(price,PriceDecimal.calculate(base,"+",amount))
            }
            steps.append(Step(label:label,value:PriceDecimal.string(price)))
        }
        return result(price,r.id,steps)
    }
}
