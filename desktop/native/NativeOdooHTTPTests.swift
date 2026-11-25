import Foundation

@main struct NativeOdooHTTPTests {
    typealias Row = NativePluginRecord
    final class Response:HTTPURLResponse,NativePluginHTTPStatusText { var statusText="" }
    static var checks=0
    static func main() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! Row
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-OdooHTTP-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),clock={ Date(timeIntervalSince1970:1791878400) }
        _=try db.insert("InstalledPlugin",values:["id":.text("odoo-connector"),"version":.text("0.4.2"),"status":.text("ENABLED"),"settings":.text("{}")],actor:"fixture")
        let store=NativePluginStore(db:db,pluginId:"odoo-connector",clock:clock),data=NativePluginData(db:db,pluginId:"odoo-connector",permissions:NativeOdooPlugin.permissions,clock:clock)
        for (index,c) in (fixture["cases"] as! [Row]).enumerated() {
            let input=c["input"] as! Row,plan=input["plan"] as! [Row]
            var calls:[Row]=[],sleeps:[Int]=[],cursor=0
            try store.set("meta:sendPaused",["reason":"fixture"])
            let ctx=NativePluginContext(definition:NativeOdooPlugin.definition,actor:.system,locale:"ja",settings:fixture["settings"] as! Row,secrets:fixture["secrets"] as! Row,store:store,data:data,clock:clock,logger:{ _,_,_ in },translator:{ key,params in
                if key == "admin.connected" { let p=params!;return key+":{\"version\":"+(try! NativePluginJSON.text(p["version"]!))+",\"user\":"+(try! NativePluginJSON.text(p["user"]!))+"}" };return key
            },notification:{ _ in throw NativePluginError(message:"Unexpected send") },transport:{ request in
                let headers=Dictionary(uniqueKeysWithValues:(request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(),$0.value) })
                calls.append(["url":request.url!.absoluteString,"method":request.httpMethod!,"headers":headers,"body":try JSONSerialization.jsonObject(with:request.httpBody!),"timeoutMs":request.timeoutInterval*1000])
                let p=plan[min(cursor,plan.count-1)];cursor += 1
                if let error=p["error"] as? String {
                    if p["kind"] as? String == "store" { throw NativePluginStoreError(message:error) }
                    if p["kind"] as? String == "rule" { throw NativePluginRuleError(pluginId:"fixture",messageKey:"blocked",translated:error) }
                    throw NativePluginError(message:error)
                }
                let bytes=try (p["raw"] as? String).map { Data($0.utf8) } ?? NativePluginJSON.data(p["json"] ?? Row())
                let response=Response(url:request.url!,statusCode:p["status"] as? Int ?? 200,httpVersion:"HTTP/1.1",headerFields:[:])!;response.statusText=p["statusText"] as? String ?? ""
                return (bytes,response)
            },persistAfterTransaction:{ $0() })
            let client=NativeOdooClient.json(ctx,sleep:{ sleeps.append($0) });let result:Row
            do {
                let value:Any
                if input["operation"] as? String == "version" { value=try await client.version() }
                else if input["operation"] as? String == "connection" { value=try await client.testConnection(ctx) }
                else { value=try await client.call(input["model"] as? String ?? "res.partner",input["method"] as? String ?? "search_read",input["body"] as? Row ?? [:],input["once"] as? Bool ?? false) }
                result=["ok":true,"value":value]
            } catch { let e=error as! NativeOdooError;result=["ok":false,"error":["name":e.authentication ? "OdooAuthError":"OdooError","message":e.message,"status":e.status]] }
            let actual:Row=["result":result,"calls":calls,"sleeps":sleeps,"store":try store.get("meta:sendPaused").map { ["meta:sendPaused":$0] } ?? Row()]
            var expected=c;expected.removeValue(forKey:"input");try compare(actual,expected,path:"\(index)")
        }
        print("NativeOdooHTTPTests: \((fixture["cases"] as! [Row]).count) original HTTP cases / \(checks) checks passed")
    }
    static func compare(_ a:Any,_ b:Any,path:String)throws {
        checks += 1
        if let a=a as? Row,let b=b as? Row { guard Set(a.keys)==Set(b.keys) else { throw NativePluginError(message:path+" keys differ") };for k in b.keys.sorted() { try compare(a[k]!,b[k]!,path:path+"."+k) };return }
        if let a=a as? [Any],let b=b as? [Any] { guard a.count==b.count else { throw NativePluginError(message:path+" counts \(a.count) != \(b.count)") };for i in b.indices { try compare(a[i],b[i],path:path+"[\(i)]") };return }
        guard NativePluginJSON.equal(a,b) else { throw NativePluginError(message:path+" got "+(try NativePluginJSON.text(a))+" expected "+(try NativePluginJSON.text(b))) }
    }
}
