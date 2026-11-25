import Foundation

@main enum InvoiceMathTests {
    struct Reference: Decodable { let inputs: [InvoiceMath.Input]; let lines: [InvoiceMath.Line]; let total: InvoiceMath.Total }
    static func main() throws {
        let reference = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        func same(_ lhs: String, _ rhs: String) -> Bool {
            Decimal(string: lhs, locale: Locale(identifier: "en_US_POSIX")) == Decimal(string: rhs, locale: Locale(identifier: "en_US_POSIX"))
        }
        var lines = 0
        for (index, example) in reference.enumerated() {
            let total = try InvoiceMath.total(example.inputs)
            guard same(total.subtotal, example.total.subtotal), same(total.discountTotal, example.total.discountTotal),
                  same(total.vatTotal, example.total.vatTotal), same(total.grandTotal, example.total.grandTotal),
                  total.vatBreakdown.count == example.total.vatBreakdown.count else { throw NativeDBError.message("Total mismatch at \(index)") }
            for (a, b) in zip(total.vatBreakdown, example.total.vatBreakdown) {
                guard same(a.rate, b.rate), same(a.base, b.base), same(a.vat, b.vat) else { throw NativeDBError.message("Tax bucket mismatch") }
            }
            for (input, expected) in zip(example.inputs, example.lines) {
                let actual = try InvoiceMath.line(input)
                guard same(actual.lineSubtotal, expected.lineSubtotal), same(actual.lineVat, expected.lineVat), same(actual.lineTotal, expected.lineTotal) else {
                    throw NativeDBError.message("Line mismatch at \(index)")
                }
                lines += 1
            }
        }
        for invalid in [InvoiceMath.Input(quantity: "0", unitPrice: "1", discountPercent: "0", taxRate: "10"),
                        InvoiceMath.Input(quantity: "1", unitPrice: "-1", discountPercent: "0", taxRate: "10"),
                        InvoiceMath.Input(quantity: "1", unitPrice: "1", discountPercent: "101", taxRate: "10"),
                        InvoiceMath.Input(quantity: "1", unitPrice: "NaN", discountPercent: "0", taxRate: "10")] {
            var rejected = false; do { _ = try InvoiceMath.line(invalid) } catch { rejected = true }
            guard rejected else { throw NativeDBError.message("Invalid input accepted") }
        }
        print("{\"ok\":true,\"referenceCases\":\(reference.count),\"lines\":\(lines),\"invalidInputs\":4}")
    }
}
