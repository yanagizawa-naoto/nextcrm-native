import Foundation
@main struct NativeOXOMapTests {
    typealias M=NativeOXOMap
    static var checks=0
    static func equal(_ a:Any,_ b:Any,_ path:String) throws {
        checks+=1
        if let a=a as? [String:Any],let b=b as? [String:Any] { guard Set(a.keys)==Set(b.keys) else { throw Failure(message:path+" keys "+a.keys.sorted().description+" != "+b.keys.sorted().description) };for k in b.keys.sorted() { try equal(a[k]!,b[k]!,path+"."+k) };return }
        if let a=a as? [Any],let b=b as? [Any] { guard a.count==b.count else { throw Failure(message:path+" length \(a.count) != \(b.count)") };for i in b.indices { try equal(a[i],b[i],path+"[\(i)]") };return }
        guard NativePluginJSON.equal(a,b) else { throw Failure(message:path+" got "+(try NativePluginJSON.text(a))+" expected "+(try NativePluginJSON.text(b))) }
    }
    struct Failure:Error,CustomStringConvertible { let message:String;var description:String { message } }
    static func run(_ op:String,_ value:Any) throws -> Any {
        let x=value as? M.Row ?? [:]
        switch op {
        case "countryCode":return try M.countryCode(value) as Any? ?? M.null
        case "countryName":return try M.countryName(value) as Any? ?? M.null
        case "account":return try M.accountFields(x)
        case "ref":return M.ref(x)
        case "changed":return M.changedFields(x["current"] as! M.Row,x["next"] as! M.Row)
        case "address":return M.sameAddress(x["a"] as! M.Row,x["b"] as! M.Row)
        case "number":return M.normalizeNumber(x["country"] as? String,x["raw"] as? String) as Any? ?? M.null
        case "vat":return M.normalizeVAT(value as? String) as Any? ?? M.null
        case "chosen":return M.chosenLists(value as! String)
        case "time":return try M.localTime(x["iso"] as! String,zone:x["zone"] as! String)
        case "categories":return M.categoryPaths(value as! [M.Row]).map{["path":$0.path,"ref":$0.ref]}
        case "product":return M.productFields(x["product"] as! M.Row,categoryRef:x["category"] as? String,currency:x["currency"] as! String,current:x["current"] as? M.Row)
        case "sameProduct":return M.sameProduct(x["current"] as? M.Row,x["fields"] as! M.Row,x["link"] as? M.Row)
        case "rules":
            let products=Dictionary(uniqueKeysWithValues:(x["products"] as! [[Any]]).map{(M.number($0[0]),$0[1] as! String)}),templates=Dictionary(uniqueKeysWithValues:(x["templates"] as! [[Any]]).map{(M.number($0[0]),$0[1] as! [String])})
            let result=M.mapRules(x["rules"] as! [M.Row],products:products,templates:templates,categoryRef:{(x["categories"] as! [String:String])[$0]},listRef:{(x["lists"] as! [String:String])[M.string($0)]});return ["rules":result.rules,"skipped":result.skipped]
        case "lists":return M.orderLists(Dictionary(uniqueKeysWithValues:(x["deps"] as! [[Any]]).map{(M.number($0[0]),($0[1] as! [Any]).map(M.number))}),maxChain:M.number(x["max"]))
        case "hash":return M.fnv(value as! String)
        case "listHash":return try M.listHash(name:x["name"]!,currency:x["currency"]!,active:x["isActive"] as! Bool,rules:x["rules"] as! [M.Row])
        case "status":return M.targetStatus(x) as Any? ?? M.null
        case "link":return M.linkFrom(x["order"] as! M.Row,previous:x["previous"] as! M.Row,now:try NativePluginJSON.date(x["now"] as! String))
        case "lines":let result=M.crmLines(Dictionary(uniqueKeysWithValues:(x["products"] as! [[Any]]).map{(M.number($0[0]),$0[1] as! String)}),x["order"] as! M.Row);return ["lines":result.lines,"missing":result.missing]
        case "decimal":return M.decimal(value)
        default:throw Failure(message:"unknown "+op)
        }
    }
    static func main() throws {
        let fixture=try NativeOXOTestJSON.parse(Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any],cases=fixture["cases"] as! [[String:Any]]
        for (i,c) in cases.enumerated() { let op=c["op"] as! String;var result:Any=M.null,errorText:String?
            do { result=try run(op,c["input"]!) } catch { errorText=(error as? LocalizedError)?.errorDescription ?? String(describing:error) }
            if let expected=c["error"] as? String { try equal(errorText as Any? ?? M.null,expected,"\(i).\(op).error") }
            else { if let errorText { throw Failure(message:"\(i).\(op): "+errorText) };try equal(result,c["result"] ?? M.null,"\(i).\(op)") }
        }
        print("NativeOXOMapTests: \(cases.count) source cases / \(checks) checks passed")
    }
}
