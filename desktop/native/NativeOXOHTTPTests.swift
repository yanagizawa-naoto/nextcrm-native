import Foundation

// Standalone transport fixture: production Context is deliberately not linked.
final class NativePluginContext {
    let settings:NativePluginRecord=[:],secrets:NativePluginRecord=[:]
    func http(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) { fatalError("No real network") }
}
@main enum NativeOXOHTTPTests {
    typealias Row=NativePluginRecord
    static var checks=0
    static func compare(_ a:Any,_ b:Any,_ path:String) throws {
        checks+=1
        if let a=a as? Row,let b=b as? Row { guard Set(a.keys)==Set(b.keys) else { throw NativePluginError(message:path+" keys "+a.keys.sorted().description+" != "+b.keys.sorted().description) };for k in b.keys.sorted(){try compare(a[k]!,b[k]!,path+"."+k)};return }
        if let a=a as? [Any],let b=b as? [Any] { guard a.count==b.count else{throw NativePluginError(message:path+" length")};for i in b.indices{try compare(a[i],b[i],path+"[\(i)]")};return }
        guard NativePluginJSON.equal(a,b) else{throw NativePluginError(message:path+": "+(try NativePluginJSON.text(a))+" != "+(try NativePluginJSON.text(b)))}
    }
    static func main() async {
        do {
            let fixture=try NativePluginJSON.record(String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)),cases=fixture["scenarios"] as! [Row]
            for scenario in cases {
                let responses=scenario["responses"] as! [Row];var requests:[Row]=[],reason=""
                let client=NativeOXOHTTPClient(url:"https://oxo.example.invalid///",apiKey:"oxo_"+String(repeating:"a",count:40),transport:{req in
                    var request:Row=["url":req.url!.absoluteString,"method":req.httpMethod!,"headers":["Authorization":req.value(forHTTPHeaderField:"Authorization")!,"Content-Type":req.value(forHTTPHeaderField:"Content-Type")!],"timeoutMs":req.timeoutInterval*1000]
                    if let body=req.httpBody{request["body"]=try JSONSerialization.jsonObject(with:body)}
                    requests.append(request);let response=responses[requests.count-1];if let message=response["throw"] as? String{throw NativePluginError(message:message)}
                    reason=response["statusText"] as? String ?? "";let status=Int(NativePluginJSON.number(response["status"])!)
                    let bytes=try (response["raw"] as? String).map{Data($0.utf8)} ?? NativePluginJSON.data(response["body"] ?? NSNull())
                    return (bytes,HTTPURLResponse(url:req.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:[:])!)
                },statusText:{_ in reason})
                var result:Row=[:]
                do { let op=scenario["op"] as! String,path=scenario["path"] as! String,params=(scenario["params"] as! [[String]]).map{($0[0],$0[1])}
                    if op=="get"{result["value"]=try await client.get(path,params)}else if op=="all"{result["value"]=try await client.all(path,params)}else{let r=try await client.post(path,scenario["body"] as! Row);result["value"]=["status":r.status,"body":r.body]}
                }catch{let e=error as? NativeOXOError;result["error"]=["message":error.localizedDescription,"status":e?.status as Any? ?? NSNull(),"code":e?.code as Any? ?? NSNull()]}
                result["requests"]=requests;try compare(result,scenario["result"]!,scenario["name"] as! String)
            }
            print("NativeOXOHTTPTests: \(cases.count) source cases / \(checks) checks passed")
        }catch{print(error.localizedDescription);exit(1)}
    }
}
