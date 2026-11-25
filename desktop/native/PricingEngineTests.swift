import Foundation

@main enum PricingEngineTests {
    struct List: Decodable { let id: String; let currency: String; let rules: [PricingEngine.Rule] }
    struct Rate: Decodable { let from: String; let to: String; let rate: String }
    struct Fixture: Decodable {
        let product: PricingEngine.Product; let categoryChain: [String]; let quantity: String; let date: String
        let listID: String; let lists: [List]; let rates: [Rate]; let expected: PricingEngine.Result
    }
    static func main() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var steps = 0
        for (index,f) in fixtures.enumerated() {
            let quantity = try PriceDecimal.parse(f.quantity)
            let result = try PricingEngine.compute(product:f.product,listID:f.listID,quantity:quantity,date:f.date,resolve:{ id in
                guard let list = f.lists.first(where: { $0.id == id }) else { throw NativeDBError.message("missing fixture list") }
                var winner: PricingEngine.Rule?
                for rule in list.rules {
                    if try PricingEngine.applicable(rule,product:f.product,chain:f.categoryChain,quantity:quantity,date:f.date), try winner == nil || PricingEngine.precedes(rule,winner!,chain:f.categoryChain) { winner = rule }
                }; return (list.currency,winner)
            },rate:{ from,to in
                if from == to { return 1 }
                if let r = f.rates.first(where: { $0.from == from && $0.to == to }) { return try PriceDecimal.parse(r.rate) }
                if let r = f.rates.first(where: { $0.from == to && $0.to == from }) { return try PriceDecimal.calculate(1,"/",PriceDecimal.parse(r.rate)) }
                throw NativeDBError.message("missing fixture rate")
            })
            func same(_ a: String,_ b: String) throws -> Bool { try PriceDecimal.parse(a) == PriceDecimal.parse(b) }
            guard try same(result.price,f.expected.price), try same(result.listPrice,f.expected.listPrice), result.currency == f.expected.currency, result.ruleId == f.expected.ruleId,
                  result.steps.count == f.expected.steps.count else { throw NativeDBError.message("Price fixture \(index): \(result) expected \(f.expected)") }
            for (a,b) in zip(result.steps,f.expected.steps) { guard try a.label == b.label && same(a.value,b.value) else { throw NativeDBError.message("Price step \(index): \(a) expected \(b)") }; steps += 1 }
        }
        print("{\"ok\":true,\"suite\":\"PricingEngine\",\"referenceCases\":\(fixtures.count),\"steps\":\(steps)}")
    }
}
