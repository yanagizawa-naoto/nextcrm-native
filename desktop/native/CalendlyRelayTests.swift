import Foundation
import CryptoKit
import SQLite3

#if !CALENDLY_SUBSCRIPTION_TESTS
@main
#endif
enum CalendlyRelayTests {
    static var checks = 0
    static let key = Data(repeating:31,count:32), authKey = key.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("CalendlyRelay FAIL: "+label) }; checks += 1 }
    static func reject(_ label: String,_ action: () async throws -> Void) async throws { var rejected = false; do { try await action() } catch { rejected = true }; try check(rejected,label) }
    final class Harness {
        let process = Process(), input = Pipe(), output = Pipe(); var url: URL!, instanceID: String!
        init(resources: URL,root: URL,port: Int = 0) throws {
            process.executableURL = URL(fileURLWithPath:"/usr/bin/env"); process.arguments = ["node",resources.appendingPathComponent("../calendar-relay/native-harness.cjs").path,root.path,String(port)]; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.standardError
            try process.run(); let ready = try read(); url = URL(string:ready["url"] as! String)!; instanceID = ready["instanceId"] as? String
        }
        func read() throws -> [String:Any] { var bytes = Data(); while true { guard let one = try output.fileHandleForReading.read(upToCount:1), !one.isEmpty else { throw NativeDBError.message("Calendar relay test process exited") }; if one[0] == 10 { break }; bytes.append(one); guard bytes.count < 10000 else { throw NativeDBError.conflict } }; return try JSONSerialization.jsonObject(with:bytes) as! [String:Any] }
        @discardableResult func command(_ value: [String:Any]) throws -> [String:Any] { var bytes = try JSONSerialization.data(withJSONObject:value); bytes.append(10); try input.fileHandleForWriting.write(contentsOf:bytes); return try read() }
        func stop() { guard process.isRunning else { return }; try? input.fileHandleForWriting.write(contentsOf:Data("{\"action\":\"stop\"}\n".utf8)); process.waitUntilExit() }
        deinit { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    }
    static func signed(_ request: URLRequest,_ object: [String:Any],status: Int = 200,corrupt: Bool = false) throws -> (Data,HTTPURLResponse) {
        let bytes = try JSONSerialization.data(withJSONObject:object), nonce = request.value(forHTTPHeaderField:"X-NextCRM-Nonce")!
        var input = Data(("nextcrm-calendar-v1-response\n"+nonce+"\n"+String(status)+"\n").utf8); input.append(bytes)
        let code = corrupt ? "bad" : Data(HMAC<SHA256>.authenticationCode(for:input,using:SymmetricKey(data:key))).base64EncodedString()
        return (bytes,HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["X-NextCRM-Signature":code])!)
    }
    static func transportGuards() async throws {
        let id = UUID().uuidString.lowercased(), instance = UUID().uuidString.lowercased(), url = URL(string:"https://calendar.example.invalid/crm")!
        for failure in ["unsigned","instance","client","version","rollback","missing-page","sequence","digest","cursor","more"] {
            let client = try CalendlyRelayClient(baseURL:url,authKey:authKey,clientID:id,expectedInstanceID:instance,request:{ request in
                let raw = Data("{}".utf8); var event: [String:Any] = ["seq":2,"body":raw.base64EncodedString(),"bodySHA256":SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined(),"signature":"test","receivedAt":"2027-01-15T10:00:00.000Z"]
                var state: [String:Any] = ["version":1,"instanceId":instance,"clientId":id,"head":2,"keyGeneration":NSNull(),"signingKeyFingerprint":NSNull(),"events":[event],"cursor":2,"hasMore":false]
                switch failure {
                case "instance":state["instanceId"] = UUID().uuidString
                case "client":state["clientId"] = UUID().uuidString
                case "version":state["version"] = 2
                case "rollback":state["head"] = 0
                case "missing-page":state.removeValue(forKey:"events")
                case "sequence":event["seq"] = 1; state["events"] = [event]
                case "digest":event["bodySHA256"] = String(repeating:"0",count:64); state["events"] = [event]
                case "cursor":state["cursor"] = 1
                case "more":state["hasMore"] = true
                default:break
                }
                return try signed(request,state,corrupt:failure == "unsigned")
            })
            try await reject("reject authenticated feed mismatch: "+failure){ _ = try await client.events(after:1) }
        }
        try await reject("plaintext remote URL rejected"){ _ = try CalendlyRelayClient(baseURL:URL(string:"http://remote.example.invalid")!,authKey:authKey,clientID:id) }
        try await reject("URL embedded credential rejected"){ _ = try CalendlyRelayClient(baseURL:URL(string:"https://secret@calendar.example.invalid")!,authKey:authKey,clientID:id) }
        try await reject("credential key format rejected"){ _ = try CalendlyRelayClient(baseURL:url,authKey:"bad",clientID:id) }
    }
    static func sql(_ db: NativeDatabase,_ statement: String) throws { var handle: OpaquePointer?; guard sqlite3_open(db.url.path,&handle) == SQLITE_OK else { throw NativeDBError.conflict }; defer{sqlite3_close(handle)}; guard sqlite3_exec(handle,statement,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(handle))) } }
    static func integration(_ resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendlyRelayTests-"+UUID().uuidString); defer{try? FileManager.default.removeItem(at:root)}
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
        let id = try CalendlyRelayBinding.clientID(db:db), relayRoot = root.appendingPathComponent("relay")
        let host = try db.insert("Users",values:["name":.text("面談担当者"),"email":.text("host@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:service.identity.id)
        var harness = try Harness(resources:resources,root:relayRoot); defer{harness.stop()}
        let client = try CalendlyRelayClient(baseURL:harness.url,authKey:authKey,clientID:id,allowLoopbackHTTP:true)
        let health = try await client.health(); try check(health.clientId == nil && health.head == 0,"fresh standalone receiver does not require campaign settings")
        let changedIdentityClient = try CalendlyRelayClient(baseURL:harness.url,authKey:authKey,clientID:id,allowLoopbackHTTP:true,request:{ request in
            let response = try await CalendlyRelayClient.network(request)
            if request.url!.path.hasSuffix("/bind") { try db.setMetadata(CalendlyRelayBinding.clientKey,value:UUID().uuidString.lowercased()) }; return response
        })
        try await reject("client identity changed during bind cannot publish stale connection"){ _ = try await CalendlyRelayBinding.connect(service:service,client:changedIdentityClient) }
        try check(try db.metadata(CalendlyRelayBinding.metadataKey) == nil,"failed initial connection leaves binding unpublished")
        try db.setMetadata(CalendlyRelayBinding.clientKey,value:id)
        let binding = try await CalendlyRelayBinding.connect(service:service,client:client), pinned = try client.expecting(binding.instanceID)
        try await reject("unconfigured public callback not ready"){ try await pinned.checkCallback() }
        let state = try await pinned.configure(signingKey:"native-calendly-fixture-key",expectedGeneration:nil); try await pinned.checkCallback()
        try check(state.keyGeneration != nil,"signed key configuration and public-route proof succeeded")
        try await reject("stale configuration cannot replace key"){ _ = try await pinned.configure(signingKey:"different-fixture-key",expectedGeneration:nil) }
        _ = try harness.command(["action":"seed","count":205]); let page = try await pinned.events(after:0)
        try check(page.events?.count == 100 && page.cursor == 100 && page.hasMore == true,"real HTTP receiver exposes100-row bounded first page")
        let first = try CalendlyRelaySync(service:service,client:pinned,binding:binding)
        try sql(db,"CREATE TRIGGER calendly_cursor_failure BEFORE UPDATE ON native_metadata WHEN NEW.key='calendlyRelay.binding.v1' BEGIN SELECT RAISE(ABORT,'injected cursor failure'); END")
        try await reject("import and cursor commit roll back together"){ _ = try await first.run() }
        try check(try db.page("crm_Activities",fields:[]).total == 0 && CalendlyRelayBinding.load(db:db)?.cursor == 0,"failed cursor commit publishes no imported meetings")
        try sql(db,"DROP TRIGGER calendly_cursor_failure")
        var failSecond = true
        let interrupted = try CalendlyRelayClient(baseURL:harness.url,authKey:authKey,clientID:id,expectedInstanceID:binding.instanceID,allowLoopbackHTTP:true,request:{ request in
            if failSecond, URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.contains(where:{$0.name == "after" && $0.value == "100"}) == true { failSecond = false; throw URLError(.networkConnectionLost) }
            return try await CalendlyRelayClient.network(request)
        })
        let interruptedSync = try CalendlyRelaySync(service:service,client:interrupted,binding:binding)
        try await reject("later page transport failure stops sync"){ _ = try await interruptedSync.run() }
        try check(try db.page("crm_Activities",fields:[]).total == 100 && CalendlyRelayBinding.load(db:db)?.cursor == 100,"completed first page remains durable after later network failure")
        let port = harness.url.port!, priorInstance = harness.instanceID; harness.stop(); harness = try Harness(resources:resources,root:relayRoot,port:port)
        try check(harness.instanceID == priorInstance,"receiver restart keeps bound identity and pending notices")
        let resumed = try CalendlyRelaySync(service:service,client:pinned,binding:CalendlyRelayBinding.load(db:db)!)
        let changed = try await resumed.run()
        try check(try changed == 105 && db.page("crm_Activities",fields:[]).total == 205 && CalendlyRelayBinding.load(db:db)?.cursor == 205,"restart resumes remaining pages without duplicate activities")
        try check(try db.page("crm_Targets",fields:["created_by"]).total == 1 && db.page("crm_Targets",fields:["created_by"]).rows[0]["created_by"] == host["id"],"all bookings retain shared CRM customer and matched host")
        let replayed = try await resumed.run(); try check(replayed == 0,"empty repeat sync adds no CRM changes")
        _ = try harness.command(["action":"cancel","id":1]); let cancelled = try await resumed.run()
        try check(try cancelled == 1 && db.page("crm_Activities",fields:[],equal:["status":.text("cancelled")]).total == 1,"signed real HTTP cancellation updates original meeting")
        _ = try harness.command(["action":"seed","count":1]); let raceStart = try CalendlyRelayBinding.load(db:db)!
        let otherDB = try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), otherService = CRMService(db:otherDB,identity:service.identity)
        let otherSync = try CalendlyRelaySync(service:otherService,client:pinned,binding:raceStart)
        var raced = false
        let racingClient = try CalendlyRelayClient(baseURL:harness.url,authKey:authKey,clientID:id,expectedInstanceID:binding.instanceID,allowLoopbackHTTP:true,request:{ request in
            let response = try await CalendlyRelayClient.network(request)
            if !raced { raced = true; _ = try await otherSync.run() }; return response
        })
        let racingSync = try CalendlyRelaySync(service:service,client:racingClient,binding:raceStart)
        try await reject("second process advancing cursor fences stale page publication"){ _ = try await racingSync.run() }
        try check(try CalendlyRelayBinding.load(db:db)?.cursor == raceStart.cursor+1 && db.page("crm_Activities",fields:[]).total == 206,"concurrent sync imports new booking exactly once")
        let before = try CalendlyRelayBinding.load(db:db)!
        _ = try harness.command(["action":"seed","count":1])
        let revoked = try CalendlyRelayClient(baseURL:harness.url,authKey:authKey,clientID:id,expectedInstanceID:binding.instanceID,allowLoopbackHTTP:true,request:{ request in
            let response = try await CalendlyRelayClient.network(request)
            let actor = try db.get("Users",key:["id":.text(service.identity.id)])!; _ = try db.update(actor,changes:["banned":.integer(1)],actor:service.identity.id); return response
        })
        let revokedSync = try CalendlyRelaySync(service:service,client:revoked,binding:before)
        try await reject("admin revoked during request cannot import"){ _ = try await revokedSync.run() }
        try check(try CalendlyRelayBinding.load(db:db) == before,"revoked administrator leaves cursor unchanged")
        let ordinary = CRMService(db:db,identity:.init(id:host["id"].string,role:"user",partnerAccountID:nil))
        try await reject("ordinary user cannot connect external receiver"){ _ = try await CalendlyRelayBinding.connect(service:ordinary,client:pinned) }
        harness.stop(); try check(harness.process.terminationStatus == 0,"isolated test receiver exits normally")
    }
    static func main() async { do { try await transportGuards(); try await integration(URL(fileURLWithPath:CommandLine.arguments[1])); print("CalendlyRelayTests: \(checks) checks passed; signed actual loopback HTTP, encrypted receiver and atomic CRM sync") } catch { FileHandle.standardError.write(Data("CalendlyRelayTests: \(error)\n".utf8)); exit(1) } }
}
