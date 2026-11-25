import Foundation
import CryptoKit

@main enum CampaignRelayClientTests {
    static var checks = 0
    static let now = CampaignRelayClient.date("2026-11-14T10:00:00.125Z")!
    static let key = Data(repeating:7,count:32)
    static var encodedKey: String { key.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw CampaignRelayError(message:"FAIL client: "+label,retryable:false) }; checks += 1 }
    static func rejects(_ label: String,_ body: () async throws -> Void) async throws { do { try await body() } catch { checks += 1; return }; throw CampaignRelayError(message:"FAIL accepted: "+label,retryable:false) }
    static func response(_ request: URLRequest, object: [String:Any], status: Int = 200, signingKey: Data = key) throws -> (Data,HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        let nonce = request.value(forHTTPHeaderField:"X-NextCRM-Nonce")!
        var input = Data(("nextcrm-relay-v1-response\n"+nonce+"\n"+String(status)+"\n").utf8); input.append(data)
        let signature = Data(HMAC<SHA256>.authenticationCode(for:input,using:SymmetricKey(data:signingKey))).base64EncodedString()
        return (data,HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["X-NextCRM-Signature":signature])!)
    }
    final class Server {
        let process = Process(); let output = Pipe(); let errors = Pipe(); let baseURL: URL; let instanceID: String
        init(resources: URL, database: URL) throws {
            process.executableURL = URL(fileURLWithPath:"/usr/bin/env"); process.arguments = ["node",resources.appendingPathComponent("../campaign-relay/native-harness.cjs").standardizedFileURL.path,database.path]
            process.standardOutput = output; process.standardError = errors
            try process.run()
            var line = Data()
            while line.count < 4096, let byte = try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty { line.append(byte); if byte[0] == 10 { break } }
            guard let json = try? JSONSerialization.jsonObject(with:line) as? [String:Any], let port = json["port"] as? Int, let id = json["instanceId"] as? String else {
                if process.isRunning { process.terminate(); process.waitUntilExit() }; throw CampaignRelayError(message:"local receiver did not start",retryable:false)
            }
            baseURL = URL(string:"http://127.0.0.1:\(port)/crm")!; instanceID = id
        }
        func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        deinit { stop() }
    }
    static func main() async { do { try await run() } catch { FileHandle.standardError.write(Data("CampaignRelayClientTests: \(error)\n".utf8)); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        try await fakeResponses()
        try await integration(resources)
        print("CampaignRelayClientTests: \(checks) checks passed; real loopback receiver and signed HTTP, no external service")
    }
    static func fakeResponses() async throws {
        let clientID = UUID().uuidString.lowercased(), instance = UUID().uuidString.lowercased(), base = URL(string:"https://relay.example.invalid/base")!
        let identity: [String:Any] = ["version":1,"instanceId":instance,"clientId":clientID,"head":0]
        func client(_ request: @escaping CampaignRelayClient.Request) throws -> CampaignRelayClient { try .init(baseURL:base,authKey:encodedKey,clientID:clientID,expectedInstanceID:instance,request:request,clock:{now}) }
        let good = try client{request in try response(request,object:identity)}
        let state = try await good.health(); try check(state.instanceId == instance,"authenticated health")
        for mode in ["bad-mac","missing-mac","tampered-body","tampered-status","wrong-instance","wrong-client","wrong-version","huge-response"] {
            let invalid = try client{request in
                if mode == "bad-mac" { return try response(request,object:identity,signingKey:Data(repeating:8,count:32)) }
                if mode == "missing-mac" { return (Data("{}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!) }
                if mode == "huge-response" { return (Data(repeating:0,count:CampaignRelayClient.maximumResponseBytes+1),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!) }
                var object = identity
                if mode == "wrong-instance" { object["instanceId"] = UUID().uuidString }
                if mode == "wrong-client" { object["clientId"] = UUID().uuidString }
                if mode == "wrong-version" { object["version"] = 2 }
                var pair = try response(request,object:object)
                if mode == "tampered-body" { pair.0.append(32) }
                if mode == "tampered-status" { pair.1 = HTTPURLResponse(url:request.url!,statusCode:201,httpVersion:nil,headerFields:["X-NextCRM-Signature":pair.1.value(forHTTPHeaderField:"X-NextCRM-Signature")!])! }
                return pair
            }
            try await rejects(mode){_ = try await invalid.health()}
        }
        var previous: (Data,HTTPURLResponse)?
        let replay = try client{request in if let previous { return previous }; let result = try response(request,object:identity); previous = result; return result }
        _ = try await replay.health(); try await rejects("response from previous nonce"){_ = try await replay.health()}
        let transient = try client{request in try response(request,object:["error":"unavailable"],status:503)}
        do { _ = try await transient.health(); throw CancellationError() } catch let error as CampaignRelayError { try check(error.retryable,"authenticated503 retryable") }
        let rollback = try client{request in try response(request,object:identity.merging(["events":[],"cursor":1,"hasMore":false]){_,b in b})}
        try await rejects("server cursor moved backwards"){_ = try await rollback.events(after:1)}
        let sendID = UUID().uuidString.lowercased(), token = UUID().uuidString.lowercased()
        for mode in ["repeated-seq","missing-page","wrong-cursor","unknown-event","bad-token","future","bad-hash","oversized-page"] {
            let c = try client{request in
                var event: [String:Any] = ["seq":1,"kind":"unsubscribe","sendId":sendID,"token":token,"providerId":NSNull(),"sourceEventId":"unsubscribe/"+token,"bodySHA256":NSNull(),"receivedAt":"2026-11-14T10:00:00.125Z"]
                var events = [event], cursor = 1, head = 1, more = false
                switch mode {
                case "repeated-seq": events = [event,event]
                case "missing-page": events = []; cursor = 0; more = true
                case "wrong-cursor": cursor = 0
                case "unknown-event": event["kind"] = "new.unsupported"; events = [event]
                case "bad-token": event["token"] = "bad"; events = [event]
                case "future": event["receivedAt"] = "2099-01-01T00:00:00Z"; events = [event]
                case "bad-hash": event["kind"] = "email.opened"; event["providerId"] = UUID().uuidString; event["token"] = NSNull(); event["bodySHA256"] = "bad"; events = [event]
                case "oversized-page": events = (1...101).map { n in var copy=event; copy["seq"]=n; return copy }; cursor = 101; head = 101
                default: break
                }
                let object = identity.merging(["head":head,"events":events,"cursor":cursor,"hasMore":more]){_,b in b}
                return try response(request,object:object)
            }
            try await rejects("event validation "+mode){_ = try await c.events(after:0)}
        }
        try await rejects("HTTP cannot be enabled for public hosts"){_ = try CampaignRelayClient(baseURL:URL(string:"http://example.invalid")!,authKey:encodedKey,clientID:clientID,allowLoopbackHTTP:true)}
        try await rejects("loopback HTTP requires explicit option"){_ = try CampaignRelayClient(baseURL:URL(string:"http://127.0.0.1")!,authKey:encodedKey,clientID:clientID)}
        try await rejects("invalid authentication key"){_ = try CampaignRelayClient(baseURL:base,authKey:"secret",clientID:clientID)}
        try await rejects("duplicate registration IDs"){_ = try await good.register([.init(sendId:sendID,token:token),.init(sendId:sendID,token:token)])}
    }
    static func integration(_ resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RelayClient-"+UUID().uuidString), database = root.appendingPathComponent("relay.sqlite")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); defer { try? FileManager.default.removeItem(at:root) }
        let id = UUID().uuidString.lowercased(), sendID = UUID().uuidString.lowercased(), token = UUID().uuidString.lowercased(), providerID = UUID().uuidString.lowercased()
        let server = try Server(resources:resources,database:database); defer { server.stop() }
        let setup = try CampaignRelayClient(baseURL:server.baseURL,authKey:encodedKey,clientID:id,allowLoopbackHTTP:true,clock:{now})
        let initial = try await setup.health(); try check(initial.clientId == nil && initial.head == 0,"real unbound receiver")
        let client = try setup.expecting(instanceID:initial.instanceId)
        _ = try await client.bind(); let registered = try await client.register([.init(sendId:sendID,token:token)])
        try check(registered.registrations?.first?.token == token && registered.clientId == id,"cross-language signed registration")
        // Recipient clicks while no CRM database/worker process exists here.
        var link = URLComponents(url:server.baseURL.appendingPathComponent("api/campaigns/unsubscribe"),resolvingAgainstBaseURL:false)!; link.queryItems = [.init(name:"token",value:token)]
        let (page,response) = try await CampaignRelayClient.network(URLRequest(url:link.url!))
        try check(response.statusCode == 200 && String(decoding:page,as:UTF8.self).contains("配信停止を受け付けました"),"actual public Japanese unsubscribe over HTTP")
        let payload = try JSONSerialization.data(withJSONObject:["type":"email.opened","data":["email_id":providerID,"message_id":"<header@example.invalid>"]],options:.sortedKeys)
        let timestamp = String(Int64(floor(now.timeIntervalSince1970))), messageID = "msg_swift_http"
        var signing = Data((messageID+"."+timestamp+".").utf8); signing.append(payload)
        let signature = Data(HMAC<SHA256>.authenticationCode(for:signing,using:SymmetricKey(data:Data("relay-fixture-signing-key-not-real".utf8)))).base64EncodedString()
        var webhook = URLRequest(url:server.baseURL.appendingPathComponent("api/campaigns/webhooks/resend")); webhook.httpMethod = "POST"; webhook.httpBody = payload
        webhook.setValue(messageID,forHTTPHeaderField:"svix-id"); webhook.setValue(timestamp,forHTTPHeaderField:"svix-timestamp"); webhook.setValue("v1,"+signature,forHTTPHeaderField:"svix-signature")
        let (_,accepted) = try await CampaignRelayClient.network(webhook); try check(accepted.statusCode == 200,"real signed provider webhook accepted before receipt mapping")
        server.stop(); try check(server.process.terminationStatus == 0,"receiver clean shutdown")
        let restarted = try Server(resources:resources,database:database); defer { restarted.stop() }
        let resumed = try CampaignRelayClient(baseURL:restarted.baseURL,authKey:encodedKey,clientID:id,expectedInstanceID:initial.instanceId,allowLoopbackHTTP:true,clock:{now})
        let first = try await resumed.events(after:0); try check(first.events?.count == 1 && first.events?.first?.token == token,"offline unsubscribe survives receiver restart")
        _ = try await resumed.register([.init(sendId:sendID,token:token,providerId:providerID)])
        let next = try await resumed.events(after:first.cursor!)
        try check(next.events?.count == 1 && next.events?.first?.kind == "email.opened" && next.events?.first?.providerId == providerID,"early webhook becomes replayable after receipt registration")
        let empty = try await resumed.events(after:next.cursor!); try check(empty.events?.isEmpty == true && empty.hasMore == false,"bounded cursor reaches receiver head")
        let wrong = try CampaignRelayClient(baseURL:restarted.baseURL,authKey:encodedKey,clientID:UUID().uuidString,allowLoopbackHTTP:true,clock:{now})
        try await rejects("different CRM cannot take over receiver"){_ = try await wrong.bind()}
        let swapped = try CampaignRelayClient(baseURL:restarted.baseURL,authKey:encodedKey,clientID:id,expectedInstanceID:UUID().uuidString,allowLoopbackHTTP:true,clock:{now})
        try await rejects("receiver identity changed"){_ = try await swapped.health()}
        restarted.stop()
    }
}
