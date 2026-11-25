import Foundation

@main enum LineItemMathTests {
    struct Fixture: Decodable { let quantity: Int64; let price: String; let type: String; let discount: String; let expected: String; let original: String }
    static func main() throws {
        let fixtures = try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        var differences = 0
        for (i,row) in fixtures.enumerated() {
            let result = try LineItemMath.total(quantity:row.quantity,price:row.price,type:row.type,discount:row.discount)
            guard try PriceDecimal.parse(result) == PriceDecimal.parse(row.expected) else { throw NativeDBError.message("Fixture \(i): \(result) != \(row.expected)") }
            if try PriceDecimal.parse(row.original) != PriceDecimal.parse(row.expected) { differences += 1 }
        }
        var rejected = 0
        for (q,p,t,d) in [(Int64(0),"1","PERCENTAGE","0"),(1,"-1","FIXED","0"),(1,"1","OTHER","0"),(1,"1","PERCENTAGE","101"),(1,"1","FIXED","-1"),(1,"bad","FIXED","0"),(Int64(Int32.max)+1,"1","FIXED","0")] {
            do { _ = try LineItemMath.total(quantity:q,price:p,type:t,discount:d) } catch { rejected += 1 }
        }
        guard rejected == 7 else { throw NativeDBError.message("Invalid input accepted") }
        print("{\"ok\":true,\"suite\":\"LineItemMath\",\"referenceCases\":\(fixtures.count),\"intentionalBinaryFloatCorrections\":\(differences),\"invalidInputs\":\(rejected)}")
    }
}
