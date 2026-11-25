import Foundation

@main enum OrderReferenceTests {
    struct Transition: Decodable { let status: String; let source: String; let createdBy: String?; let externalRef: String?; let role: String; let action: String; let allowed: Bool }
    struct Plugin: Decodable { let status: String; let to: String; let allowed: Bool }
    struct Line: Decodable { let quantity: String; let unitPrice: String; let vatRate: String; let lineSubtotal: String; let lineVat: String; let lineTotal: String }
    struct Number: Decodable { let template: String; let counter: Int64; let year: Int; let number: String }
    struct Fixtures: Decodable { let transitions: [Transition]; let plugins: [Plugin]; let lines: [Line]; let numbers: [Number] }
    static func main() {
        do {
            let f = try JSONDecoder().decode(Fixtures.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
            for r in f.transitions { guard OrderWorkflow.can(status:r.status,source:r.source,creator:r.createdBy,externalRef:r.externalRef,action:r.action,actorID:"actor",role:r.role) == r.allowed else { throw NativeDBError.message("transition mismatch \(r.status) \(r.role) \(r.action)") } }
            for r in f.plugins { guard OrderWorkflow.canPluginSet(status:r.status,to:r.to) == r.allowed else { throw NativeDBError.message("plugin transition mismatch") } }
            for r in f.lines {
                let computed = try InvoiceMath.line(.init(quantity:r.quantity,unitPrice:r.unitPrice,discountPercent:"0",taxRate:r.vatRate))
                guard try PriceDecimal.parse(computed.lineSubtotal) == PriceDecimal.parse(r.lineSubtotal), try PriceDecimal.parse(computed.lineVat) == PriceDecimal.parse(r.lineVat), try PriceDecimal.parse(computed.lineTotal) == PriceDecimal.parse(r.lineTotal) else { throw NativeDBError.message("order amount mismatch") }
            }
            for r in f.numbers { guard OrderNumber.format(r.template,year:r.year,counter:r.counter) == r.number else { throw NativeDBError.message("number format mismatch") } }
            print("{\"ok\":true,\"suite\":\"OrderReference\",\"transitions\":\(f.transitions.count),\"pluginTransitions\":\(f.plugins.count),\"amounts\":\(f.lines.count),\"numbers\":\(f.numbers.count)}")
        } catch { FileHandle.standardError.write(Data("OrderReferenceTests: \(error)\n".utf8)); exit(1) }
    }
}
