import Foundation

/// Mirrors lib/invoices/totals.ts: discount first, round each net/tax amount to
/// two decimal places, then sum the rounded amounts. No binary floating point.
enum InvoiceMath {
    struct Input: Codable { let quantity: String; let unitPrice: String; let discountPercent: String; let taxRate: String }
    struct Line: Codable { let lineSubtotal: String; let lineVat: String; let lineTotal: String }
    struct Bucket: Codable { let rate: String; let base: String; let vat: String }
    struct Total: Codable { let subtotal: String; let discountTotal: String; let vatTotal: String; let grandTotal: String; let vatBreakdown: [Bucket] }
    private struct Parsed { let quantity: Decimal; let price: Decimal; let discount: Decimal; let tax: Decimal }
    private static func parse(_ string: String) throws -> Decimal {
        guard string.count <= 40, string.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw NativeDBError.message("金額・数量の形式が不正です。")
        }
        return value
    }
    private static func parse(_ line: Input) throws -> Parsed {
        let value = try Parsed(quantity: parse(line.quantity), price: parse(line.unitPrice), discount: parse(line.discountPercent), tax: parse(line.taxRate))
        guard value.quantity > 0, value.price >= 0, value.discount >= 0, value.discount <= 100, value.tax >= 0 else {
            throw NativeDBError.message("数量は正数、単価・税率は0以上、割引率は0〜100で入力してください。")
        }
        return value
    }
    private static func calculate(_ lhs: Decimal, _ rhs: Decimal, operation: String) throws -> Decimal {
        var lhs = lhs; var rhs = rhs; var result = Decimal()
        let error: Decimal.CalculationError
        switch operation {
        case "+": error = NSDecimalAdd(&result, &lhs, &rhs, .plain)
        case "-": error = NSDecimalSubtract(&result, &lhs, &rhs, .plain)
        case "*": error = NSDecimalMultiply(&result, &lhs, &rhs, .plain)
        default: error = NSDecimalDivide(&result, &lhs, &rhs, .plain)
        }
        guard error == .noError else { throw NativeDBError.message("計算可能な精度を超えています。金額・数量を確認してください。") }
        return result
    }
    private static func round(_ value: Decimal) -> Decimal {
        var source = value; var result = Decimal(); NSDecimalRound(&result, &source, 2, .plain); return result
    }
    private static func string(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    private static func amounts(_ line: Parsed) throws -> (net: Decimal, vat: Decimal, discount: Decimal) {
        let gross = try calculate(line.quantity, line.price, operation: "*")
        let discount = try calculate(calculate(gross, line.discount, operation: "*"), 100, operation: "/")
        let net = try round(calculate(gross, discount, operation: "-"))
        let vat = try round(calculate(calculate(net, line.tax, operation: "*"), 100, operation: "/"))
        return (net, vat, discount)
    }
    static func line(_ input: Input) throws -> Line {
        let a = try amounts(parse(input))
        return try Line(lineSubtotal: string(a.net), lineVat: string(a.vat), lineTotal: string(round(calculate(a.net, a.vat, operation: "+"))))
    }
    struct Accumulator {
        private var net = Decimal(0); private var vat = Decimal(0); private var discount = Decimal(0)
        private var rates: [String] = []; private var buckets: [String: (base: Decimal, vat: Decimal)] = [:]
        private(set) var count = 0
        mutating func add(_ input: Input) throws {
            let parsed = try parse(input); let a = try amounts(parsed); let rate = string(parsed.tax)
            net = try calculate(net, a.net, operation: "+"); vat = try calculate(vat, a.vat, operation: "+")
            discount = try calculate(discount, a.discount, operation: "+")
            if buckets[rate] == nil { rates.append(rate); buckets[rate] = (0, 0) }
            let old = buckets[rate]!
            buckets[rate] = try (calculate(old.base, a.net, operation: "+"), calculate(old.vat, a.vat, operation: "+"))
            count += 1
        }
        func total() throws -> Total {
            let breakdown = rates.map { rate in Bucket(rate: rate, base: string(round(buckets[rate]!.base)), vat: string(round(buckets[rate]!.vat))) }
            return try Total(subtotal: string(round(net)), discountTotal: string(round(discount)), vatTotal: string(round(vat)),
                             grandTotal: string(round(calculate(net, vat, operation: "+"))), vatBreakdown: breakdown)
        }
    }
    static func total(_ inputs: [Input]) throws -> Total {
        var accumulator = Accumulator(); for input in inputs { try accumulator.add(input) }; return try accumulator.total()
    }
}
