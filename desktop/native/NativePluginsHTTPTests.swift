import Foundation

@main enum NativePluginsHTTPTests {
    static var checks=0
    static func check(_ result:Bool,_ label:String) throws { checks+=1;if !result { throw NativePluginError(message:label) } }
    static func main() async {
        do { try await run();print(try NativePluginJSON.text(["exit":0,"checks":checks])) }
        catch { print(try! NativePluginJSON.text(["exit":1,"checks":checks,"error":error.localizedDescription]));exit(1) }
    }
    static func run() async throws {
        let fixture=try NativePluginJSON.record(String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8))
        for (index,test) in (fixture["cases"] as! [NativePluginRecord]).enumerated() {
            let input=test["input"] as! NativePluginRecord,responses=input["responses"] as! [NativePluginRecord]
            var request=URLRequest(url:URL(string:input["url"] as! String)!),requests:[NativePluginRecord]=[],hosts:[NativePluginRecord]=[],logs:[NativePluginRecord]=[],position=0
            request.httpMethod=input["method"] as? String;request.allHTTPHeaderFields=input["headers"] as? [String:String];request.httpBody=(input["body"] as? String).map { Data($0.utf8) };if let timeout=NativePluginJSON.number(input["timeout"]) { request.timeoutInterval=timeout/1000 }
            let actual:NativePluginRecord
            do {
                let result=try await NativePluginHTTP.fetch(request,transport:{ value in
                    let host=value.url!.host!;hosts.append(["host":host,"allowPrivate":input["private"] as? Bool ?? false]);if host==input["failHost"] as? String { throw NativePluginError(message:"Host is not allowed") }
                    requests.append(["url":value.url!.absoluteString,"method":value.httpMethod ?? "GET","headers":Dictionary(uniqueKeysWithValues:(value.allHTTPHeaderFields ?? [:]).map{($0.key.lowercased(),$0.value)}),"body":value.httpBody.map { String(decoding:$0,as:UTF8.self) } as Any? ?? NSNull()])
                    let response=responses[min(position,responses.count-1)];position+=1
                    return (Data(),HTTPURLResponse(url:value.url!,statusCode:response["status"] as! Int,httpVersion:"HTTP/1.1",headerFields:(response["location"] as? String).map { ["location":$0] } ?? [:])!)
                },log:{ level,message,context in logs.append(["level":level,"message":message,"url":context?["url"] ?? ""]) })
                actual=["ok":true,"status":result.1.statusCode]
            } catch { actual=["ok":false,"error":error.localizedDescription] }
            try check(NativePluginJSON.equal(actual,test["result"]),"policy \(index) result")
            func canonical(_ rows:[NativePluginRecord])->[NativePluginRecord] { rows.map { row in var row=row;if var components=URLComponents(string:row["url"] as! String),components.scheme=="https",components.port==443 { components.port=nil;row["url"]=components.url!.absoluteString };return row } }
            try check(NativePluginJSON.equal(canonical(requests),canonical(test["requests"] as! [NativePluginRecord])),"policy \(index) requests")
            try check(NativePluginJSON.equal(hosts,test["hosts"]),"policy \(index) every redirect checked")
            try check(NativePluginJSON.equal(logs,test["logs"]),"policy \(index) logs exclude query and secrets")
        }
        let port=Int(CommandLine.arguments[2])!,base="http://synthetic.invalid:\(port)"
        func request(_ path:String,_ timeout:Double=2)->URLRequest { URLRequest(url:URL(string:base+path)!,timeoutInterval:timeout) }
        let ok=try await NativePluginHTTPTransport.request(request("/ok"),allowPrivate:true,resolvedAddresses:["127.0.0.1"])
        try check(String(decoding:ok.0,as:UTF8.self)=="日本語 fixture","real HTTP body")
        try check((ok.1 as? NativePluginHTTPResponse)?.statusText=="Fixture OK","real reason phrase retained")
        let host=try await NativePluginHTTPTransport.request(request("/host"),allowPrivate:true,resolvedAddresses:["127.0.0.1"])
        try check(String(decoding:host.0,as:UTF8.self)=="synthetic.invalid:\(port)","DNS pin keeps original Host")
        do { _=try await NativePluginHTTPTransport.request(request("/ok"),resolvedAddresses:["127.0.0.1"]);try check(false,"private host accepted") } catch { try check(error.localizedDescription=="Host is not allowed","private address rejected") }
        do { _=try await NativePluginHTTPTransport.request(request("/ok"),resolvedAddresses:["1.1.1.1","127.0.0.1"]);try check(false,"mixed DNS accepted") } catch { try check(error.localizedDescription=="Host is not allowed","all DNS answers checked") }
        do { _=try await NativePluginHTTPTransport.request(request("/large"),allowPrivate:true,maximumBytes:1000,resolvedAddresses:["127.0.0.1"]);try check(false,"oversized body accepted") } catch { try check(error.localizedDescription.contains("configured limit"),"streaming body cap") }
        do { _=try await NativePluginHTTPTransport.request(request("/slow",0.15),allowPrivate:true,resolvedAddresses:["127.0.0.1"]);try check(false,"deadline ignored") } catch { try check(error.localizedDescription.contains("timed out"),"request deadline") }
        let task=Task { try await NativePluginHTTPTransport.request(request("/slow",5),allowPrivate:true,resolvedAddresses:["127.0.0.1"]) };try await Task.sleep(nanoseconds:100_000_000);let start=Date();task.cancel()
        do { _=try await task.value;try check(false,"cancel ignored") } catch { try check(error is CancellationError && Date().timeIntervalSince(start)<2,"inflight cancellation") }
        var redirect=request("/redirect");redirect.setValue("fixture-secret",forHTTPHeaderField:"Authorization")
        let redirected=try await NativePluginHTTP.fetch(redirect,transport:{ try await NativePluginHTTPTransport.request($0,allowPrivate:true,resolvedAddresses:["127.0.0.1"]) })
        try check(String(decoding:redirected.0,as:UTF8.self)=="none","real cross-origin strips credentials")
    }
}
