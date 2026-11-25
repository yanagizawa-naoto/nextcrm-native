import Foundation

/// Same discount order and zero floor as lib/line-items.ts, with decimal arithmetic
/// so values such as 0.29 at 50% round to 0.15 rather than a binary-float artefact.
enum LineItemMath {
    static func calculate(_ a: Decimal,_ operation: String,_ b: Decimal) throws -> Decimal {
        var a = a; var b = b; var result = Decimal(); let error: Decimal.CalculationError
        switch operation {
        case "+": error = NSDecimalAdd(&result,&a,&b,.plain)
        case "-": error = NSDecimalSubtract(&result,&a,&b,.plain)
        case "*": error = NSDecimalMultiply(&result,&a,&b,.plain)
        default: error = NSDecimalDivide(&result,&a,&b,.plain)
        }
        guard error == .noError, !result.isNaN else { throw NativeDBError.message("明細の金額が計算できる範囲を超えています。") }; return result
    }
    static func total(quantity: Int64, price: String, type: String, discount: String) throws -> String {
        let unit = try PriceDecimal.parse(price); let deduction = try PriceDecimal.parse(discount)
        guard quantity > 0, quantity <= Int32.max, unit >= 0, deduction >= 0,
              ["FIXED","PERCENTAGE"].contains(type), type != "PERCENTAGE" || deduction <= 100 else {
            throw NativeDBError.message("数量は1以上の整数、単価と値引額は0以上、値引率は0〜100で入力してください。")
        }
        let subtotal = try calculate(Decimal(quantity),"*",unit)
        let amount = try type == "FIXED" ? deduction : calculate(calculate(subtotal,"*",deduction),"/",100)
        return try PriceDecimal.string(PriceDecimal.rounded(max(0,calculate(subtotal,"-",amount))))
    }
}
