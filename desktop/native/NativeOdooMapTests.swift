import Foundation

@main struct NativeOdooMapTests {
    typealias M = NativeOdooMap
    static func main() throws {
        let input=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),fixture=try JSONSerialization.jsonObject(with:input) as! [String:Any]
        var checks=0,cases=0
        for c in fixture["cases"] as! [[String:Any]] {
            let op=c["op"] as! String
            if op == "settings" { continue } // Settings schema is verified with the full shared plugin host.
            let value=c["input"]!,r=value as? [String:Any] ?? [:]
            let result:Any
            switch op {
            case "account":result=M.accountFields(r["partner"] as! M.Row,countries:r["countries"] as! [String:String],defaultCountry:r["defaultCountry"] as! String)
            case "contact":result=M.contactFields(r)
            case "name":result=M.splitName(value as! String)
            case "changed":result=M.changedFields(r["current"] as! M.Row,r["next"] as! M.Row)
            case "number":result=M.normalizeNumber(r["country"] as? String,r["raw"] as? String) as Any? ?? NSNull()
            case "vat":result=M.normalizeVAT(value as? String) as Any? ?? NSNull()
            case "chosen":result=M.chosenLists(value as! String)
            case "fixed":result=M.fixed(M.number(r["number"]),digits:r["digits"] as! Int)
            case "address":result=M.sameAddress(r["a"] as! M.Row,r["b"] as! M.Row)
            case "variant":result=M.variantFields(r["variant"] as! M.Row) { ids in guard ids.count == 1 else { return nil };return (r["taxes"] as! [String:String])[M.string(ids[0])] }
            case "categories":result=M.categoryOrder(value as! [M.Row])
            case "rules":result=M.mapRules(r["items"] as! [M.Row],variants:(r["variants"] as! [String:[Double]]),known:Set(r["known"] as! [String]))
            case "bases":result=M.baseRefs(value as! [M.Row])
            case "lists":result=M.orderLists(Dictionary(uniqueKeysWithValues:(r["deps"] as! [[Any]]).map { (M.number($0[0]),($0[1] as! [Any]).map(M.number)) }),maxChain:NativePluginJSON.number(r["max"]) ?? .infinity)
            case "sample":result=M.pickSample(r["rules"] as! [M.Row],products:r["products"] as! [M.Row],parents:r["parents"] as! M.Row,n:r["n"] as? Int ?? 20)
            case "status":result=M.targetStatus(r["sale"] as! M.Row,moves:r["moves"] as! [M.Row])
            case "invoices":result=M.invoiceRows(value as! [M.Row])
            case "note":result=M.note(r["html"],missing:r["missing"] as! Int) { key,args in key+":"+(try! NativePluginJSON.text(args)) }
            case "time":let p=try M.localParts(NativePluginJSON.date(r["iso"] as! String),zone:r["zone"] as! String);result=["day":p.day,"time":p.time]
            default:fatalError("unknown operation "+op)
            }
            cases += 1
            try compare(result,c["result"] ?? NSNull(),path:"\(cases).\(op)",checks:&checks)
        }
        print("NativeOdooMapTests: \(cases) source cases / \(checks) checks passed")
    }
    static func compare(_ a:Any,_ b:Any,path:String,checks:inout Int)throws {
        checks += 1
        if let a=a as? [String:Any],let b=b as? [String:Any] {
            guard Set(a.keys)==Set(b.keys) else { throw Failure(message:path+" keys "+a.keys.sorted().description+" expected "+b.keys.sorted().description) }
            for key in b.keys.sorted() { try compare(a[key]!,b[key]!,path:path+"."+key,checks:&checks) };return
        }
        if let a=a as? [Any],let b=b as? [Any] { guard a.count==b.count else { throw Failure(message:path+" count \(a.count) expected \(b.count)") };for i in b.indices { try compare(a[i],b[i],path:path+"[\(i)]",checks:&checks) };return }
        guard NativePluginJSON.equal(a,b) else { throw Failure(message:path+" got "+(try NativePluginJSON.text(a))+" expected "+(try NativePluginJSON.text(b))) }
    }
    struct Failure:Error,CustomStringConvertible { let message:String;var description:String { message } }
}
