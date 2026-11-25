import Foundation
import CryptoKit

#if !CALENDLY_RUNTIME_TESTS && !CALENDLY_UI_TESTS
@main
#endif
enum CalendlySubscriptionTests {
    static var checks = 0
    static let organization = "https://api.calendly.com/organizations/fixture-org"
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("CalendlySubscription FAIL: "+label) }; checks += 1 }
    static func reject(_ label: String,_ action: () async throws -> Void) async throws { var failed = false; do { try await action() } catch { failed = true }; try check(failed,label) }
    static func response(_ request: URLRequest,_ object: Any,status: Int = 200) throws -> (Data,HTTPURLResponse) { (try JSONSerialization.data(withJSONObject:object),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }
    final class Store: CalendlySecretStore {
        var items = [String:Data](), failSave = false, failRemove = false
        var onSave: (() throws -> Void)?
        func load(id: String,interactive: Bool) throws -> Data? { items[id] }
        func save(id: String,data: Data) throws { if failSave { throw NativeDBError.conflict }; guard items[id] == nil else { throw NativeDBError.conflict }; items[id] = data; try onSave?() }
        func remove(id: String) throws { if failRemove { throw NativeDBError.conflict }; items.removeValue(forKey:id) }
    }
    final class Provider {
        var rows = [String:[String:Any]](), calls = [String](), createCount = 0, deleteCount = 0
        var loseCreateResponse = false, loseBeforeCreate = false, loseDeleteResponse = false, rejectCreate: Int?, failDelete = false
        var after: ((URLRequest) throws -> Void)?
        var afterAsync: ((URLRequest) async throws -> Void)?
        func request(_ req: URLRequest) async throws -> (Data,HTTPURLResponse) {
            try check(req.url!.host == "api.calendly.com" && req.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-api-token","provider token goes only to fixed origin")
            let path = req.url!.path, method = req.httpMethod!; calls.append(method+" "+path)
            let output: (Data,HTTPURLResponse)
            if path == "/users/me" { output = try response(req,["resource":["current_organization":organization]]) }
            else if path == "/webhook_subscriptions", method == "POST" {
                createCount += 1
                if let status = rejectCreate { return try response(req,["error":"DO-NOT-EXPOSE-TOKEN"],status:status) }
                if loseBeforeCreate { loseBeforeCreate = false; throw URLError(.networkConnectionLost) }
                let body = try JSONSerialization.jsonObject(with:req.httpBody!) as! [String:Any]
                try check(body["scope"] as? String == "organization" && Set(body["events"] as! [String]) == Set(CalendlyAPIClient.events) && !(body["signing_key"] as! String).isEmpty,"original organization, events and signing-key request retained")
                let uri = "https://api.calendly.com/webhook_subscriptions/"+UUID().uuidString.lowercased()
                let row: [String:Any] = ["uri":uri,"callback_url":body["url"]!,"organization":body["organization"]!,"scope":"organization","state":"active","events":CalendlyAPIClient.events]
                rows[uri] = row
                if loseCreateResponse { loseCreateResponse = false; throw URLError(.networkConnectionLost) }
                output = try response(req,["resource":row],status:201)
            } else if path == "/webhook_subscriptions" { output = try response(req,["collection":Array(rows.values),"pagination":["next_page_token":NSNull()]]) }
            else if method == "GET" { output = try response(req,rows[req.url!.absoluteString].map{["resource":$0]} ?? [:],status:rows[req.url!.absoluteString] == nil ? 404 : 200) }
            else if method == "DELETE" {
                if failDelete { return try response(req,[:],status:500) }; deleteCount += 1; let old = rows.removeValue(forKey:req.url!.absoluteString)
                if loseDeleteResponse { loseDeleteResponse = false; throw URLError(.networkConnectionLost) }
                output = try response(req,[:],status:old == nil ? 404 : 204)
            } else { throw NativeDBError.message("Unexpected fake API route") }
            try after?(req); try await afterAsync?(req); return output
        }
    }
    final class Fixture {
        let root: URL, resources: URL, db: NativeDatabase, service: CRMService, server: CalendlyRelayTests.Harness
        let store = Store(), provider = Provider()
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendlySubscription-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            server = try CalendlyRelayTests.Harness(resources:resources,root:root.appendingPathComponent("relay"))
        }
        deinit { server.stop(); try? FileManager.default.removeItem(at:root) }
        func save(token: String = "fixture-api-token",key: String = "",relayKey: String = CalendlyRelayTests.authKey) async throws {
            try await service.saveCalendlySettings(publicURL:server.url.absoluteString,authKey:relayKey,apiToken:token,signingKey:key,store:store,allowLoopbackHTTP:true)
        }
        func manager(service: CRMService? = nil) -> CalendlySubscriptionManager { .init(service:service ?? self.service,store:store,allowLoopbackHTTP:true,apiRequest:provider.request) }
        func state() throws -> CalendlyControlState { try service.calendlyControl() }
        func secret() throws -> CalendlyCredentials { try service.calendlyCredentials(state(),store:store) }
    }
    static func credentials(_ resources: URL) async throws {
        let f = try Fixture(resources)
        try await reject("missing token rejected"){try await f.save(token:"")}
        try await reject("bad relay key rejected"){try await f.save(relayKey:"bad")}
        f.store.failSave = true; try await reject("keychain failure after bind leaves no credential reference"){try await f.save()}; f.store.failSave = false
        try check(try f.state().credentialID == nil && f.store.items.isEmpty && CalendlyRelayBinding.load(db:f.db) != nil,"failed save preserves recoverable bound receiver")
        try await f.save(); let first = try f.state(), secret = try f.secret()
        try check(secret.signingKey.utf8.count == 43 && f.store.items.count == 1,"generated signature key saved only in immutable secret item")
        try await f.save(token:"",relayKey:""); let second = try f.state()
        try check(try f.secret().signingKey == secret.signingKey && first.credentialID != second.credentialID && f.store.items.count == 1,"blank secret inputs retain secrets while atomically replacing reference")
        let metadata = try f.db.metadata(CalendlyControlState.metadataKey)!
        try check(!metadata.contains(secret.apiToken) && !metadata.contains(secret.authKey) && !metadata.contains(secret.signingKey),"database control state contains no secrets")
        f.store.onSave = { var state = try f.state(); let before = state; try state.save(f.db,expected:before) }
        try await reject("concurrent settings edit fences stale secret publication"){try await f.save()}; f.store.onSave = nil
        try check(f.store.items.count == 1,"losing settings candidate secret cleaned up")
        f.store.items.removeAll()
        try await f.save(key:"explicit-replacement-key")
        try check(f.store.items.count == 1,"fully supplied settings repair missing old Keychain item")
        f.store.failRemove = true; try await reject("failed keychain deletion retains retryable reference"){try f.service.removeCalendlySettings(store:f.store)}; f.store.failRemove = false
        try f.service.removeCalendlySettings(store:f.store)
        try check(try f.state().credentialID == nil && f.store.items.isEmpty && CalendlyRelayBinding.load(db:f.db) != nil,"removing secrets preserves permanent receipt cursor and binding")
        let ordinary = CRMService(db:f.db,identity:.init(id:f.service.identity.id,role:"user",partnerAccountID:nil))
        try await reject("ordinary role cannot read configuration"){_ = try ordinary.calendlyControl()}
    }
    static func lifecycle(_ resources: URL) async throws {
        let f = try Fixture(resources); try await f.save(); let manager = f.manager()
        try await manager.begin(.subscribe); try await reject("pending operation prevents secret replacement"){try await f.save()}
        let subscribed = try await manager.resume()
        try check(subscribed.operation == nil && subscribed.registration != nil && f.provider.createCount == 1,"complete subscription persisted")
        _ = try await f.manager().resume(); try check(f.provider.createCount == 1,"restart after completed registration never recreates subscription")
        let registration = subscribed.registration!, secret = try f.secret(), relay = try secret.relay(db:f.db,allowLoopbackHTTP:true)
        let raw = Data("{\"event\":\"invitee.created\",\"payload\":{\"uri\":\"https://api.calendly.com/scheduled_events/event/invitees/native\",\"email\":\"customer@example.invalid\",\"name\":\"予約のお客様\",\"scheduled_event\":{\"start_time\":\"2027-01-15T10:00:00Z\"}}}".utf8)
        let timestamp = String(Int(Date().timeIntervalSince1970)); var signed = Data((timestamp+".").utf8); signed.append(raw)
        let digest = HMAC<SHA256>.authenticationCode(for:signed,using:SymmetricKey(data:Data(secret.signingKey.utf8))).map{String(format:"%02x",$0)}.joined()
        var notice = URLRequest(url:URL(string:registration.callbackURL)!); notice.httpMethod = "POST"; notice.httpBody = raw; notice.setValue("t="+timestamp+",v1="+digest,forHTTPHeaderField:"Calendly-Webhook-Signature")
        let response = try await CalendlyRelayClient.network(notice); try check(response.1.statusCode == 200,"actual unique callback receives signed provider delivery")
        let sync = try CalendlyRelaySync(service:f.service,client:relay,binding:CalendlyRelayBinding.load(db:f.db)!)
        let imported = try await sync.run(); try check(imported == 1,"registered callback delivery becomes native CRM meeting")
        try await reject("active registration prevents credential deletion"){try f.service.removeCalendlySettings(store:f.store)}
        try await f.save(key:"rotated-fixture-signing-key"); f.provider.failDelete = true; try await manager.begin(.subscribe)
        try await reject("failed prior subscription deletion blocks replacement"){_ = try await manager.resume()}
        try check(f.provider.createCount == 1 && f.provider.rows.count == 1,"no duplicate create after failed deletion")
        f.provider.failDelete = false; f.provider.loseDeleteResponse = true
        try await reject("lost deletion response retains durable intent"){_ = try await manager.resume()}
        _ = try await f.manager().resume(); try check(f.provider.createCount == 2 && f.provider.rows.count == 1,"restart observes404 then recreates exactly once")
        let disconnected = f.manager(); try await disconnected.begin(.unsubscribe); _ = try await disconnected.resume()
        try check(try f.state().registration == nil && f.provider.rows.isEmpty,"unsubscribe removes owned remote registration")
        try f.service.removeCalendlySettings(store:f.store)
        try check(try CalendlyRelayBinding.load(db:f.db)?.cursor == 1,"unsubscribe and credential removal retain imported history")
    }
    static func recovery(_ resources: URL) async throws {
        let f = try Fixture(resources); try await f.save(); f.provider.loseCreateResponse = true; let worker = f.manager(); try await worker.begin(.subscribe)
        try await reject("lost successful create response leaves reconcilable intent"){_ = try await worker.resume()}
        try check(try f.state().operation?.phase == .creating && f.provider.rows.count == 1,"unknown create persisted before remote mutation")
        try await reject("unknown creation cannot be discarded as simple cancellation"){try await worker.cancelPreparation(operationID:f.state().operation!.id)}
        try await reject("existing remote registration cannot be reviewed as not created"){try await worker.confirmCreateNotApplied(operationID:f.state().operation!.id,note:"確認")}
        let otherDB = try NativeDatabase(url:f.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), other = CRMService(db:otherDB,identity:f.service.identity)
        let restored = try await f.manager(service:other).resume()
        try check(restored.registration != nil && f.provider.createCount == 1,"fresh database connection adopts lost response without another POST")
        let fresh = try Fixture(resources); try await fresh.save(); fresh.provider.loseBeforeCreate = true; let uncertain = fresh.manager(); try await uncertain.begin(.subscribe)
        try await reject("failure before server mutation remains uncertain"){_ = try await uncertain.resume()}
        let id = try fresh.state().operation!.id
        try await reject("empty reconciliation does not silently resend"){_ = try await fresh.manager().resume()}
        try check(fresh.provider.createCount == 1,"automatic resume never duplicates uncertain POST")
        let pending = try fresh.state(), originalKey = try fresh.secret().signingKey
        try fresh.service.replaceCalendlyAPIToken("fixture-api-token",store:fresh.store)
        try check(try fresh.state().operation?.id == id && fresh.state().operation?.phase == .creating && fresh.state().credentialID != pending.credentialID && fresh.secret().signingKey == originalKey,"token renewal retains unknown request identity and exact provider signing key")
        try await reject("review requires explanatory note"){try await uncertain.confirmCreateNotApplied(operationID:id,note:" ")}
        try await uncertain.confirmCreateNotApplied(operationID:id,note:"Calendly管理画面で該当通知登録がないことを確認")
        _ = try await uncertain.resume(); try check(fresh.provider.createCount == 2 && fresh.provider.rows.count == 1,"explicit reviewed noncreation permits one new attempt")
    }
    static func fences(_ resources: URL) async throws {
        let f = try Fixture(resources); try await f.save(); let worker = f.manager(); try await worker.begin(.subscribe); f.provider.rejectCreate = 401
        try await reject("definite provider rejection remains retryable"){_ = try await worker.resume()}
        try check(try f.state().operation?.phase == .ready,"known rejected request is not treated as unknown creation")
        f.provider.rejectCreate = nil
        let secret = try f.secret(), relay = try secret.relay(db:f.db,allowLoopbackHTTP:true), health = try await relay.health()
        _ = try await relay.configure(signingKey:"externally-changed",expectedGeneration:health.keyGeneration)
        try await reject("receiver key change prevents posting broken subscription"){_ = try await worker.resume()}
        try check(f.provider.createCount == 1,"wrong receiver key sends no new provider POST")
        try await worker.restartReceiverPreparation(operationID:f.state().operation!.id)
        f.provider.after = { req in if req.httpMethod == "POST" { let row = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!; _ = try f.db.update(row,changes:["banned":.integer(1)],actor:f.service.identity.id) } }
        try await reject("admin revoked while create in flight cannot publish success"){_ = try await worker.resume()}
        try check(try CalendlyControlState.load(f.db).operation?.phase == .creating && CalendlyControlState.load(f.db).registration == nil,"revocation leaves durable intent for later authorized reconciliation")
        f.provider.after = nil; let actor = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!; _ = try f.db.update(actor,changes:["banned":.integer(0)],actor:f.service.identity.id)
        _ = try await f.manager().resume(); try check(f.provider.createCount == 2 && f.provider.rows.count == 1,"restored permission reconciles already-created subscription")
        let race = try Fixture(resources); try await race.save(); let first = race.manager(); try await first.begin(.subscribe)
        let otherDB = try NativeDatabase(url:race.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), other = race.manager(service:CRMService(db:otherDB,identity:race.service.identity))
        race.provider.afterAsync = { req in if req.httpMethod == "POST" { race.provider.afterAsync = nil; _ = try await other.resume() } }
        try await reject("concurrent worker publication fences first response"){_ = try await first.resume()}
        try check(try race.state().registration != nil && race.provider.createCount == 1,"two workers publish one remote subscription with one POST")
        let takeover = try Fixture(resources); try await takeover.save(); let original = takeover.manager(); try await original.begin(.subscribe)
        let id = try takeover.state().operation!.id
        let admin = try takeover.db.insert("Users",values:["name":.text("別の管理者"),"email":.text("admin2@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:takeover.service.identity.id)
        let service = CRMService(db:takeover.db,identity:.init(id:admin["id"].string,role:"admin",partnerAccountID:nil)), newAdmin = takeover.manager(service:service)
        try await reject("different administrator must explicitly take over pending operation"){_ = try await newAdmin.resume()}
        try await newAdmin.takeOverOperation(operationID:id)
        try await reject("former owner is fenced after explicit takeover"){_ = try await original.resume()}
        try await newAdmin.cancelPreparation(operationID:id)
        try check(try service.calendlyControl().operation == nil && takeover.provider.createCount == 0,"new administrator can cancel untouched preparation without provider mutation")
    }
    static func apiGuards() async throws {
        var requests = 0
        let api = try CalendlyAPIClient(token:"fixture-api-token",request:{ req in requests += 1; return try response(req,[:]) })
        for uri in ["http://api.calendly.com/webhook_subscriptions/a","https://evil.invalid/webhook_subscriptions/a","https://api.calendly.com@evil.invalid/webhook_subscriptions/a","https://api.calendly.com/webhook_subscriptions/%2e%2e","https://api.calendly.com/webhook_subscriptions/a?token=leak","https://api.calendly.com/users/a"] {
            try await reject("untrusted provider URI rejected before token use"){try await api.delete(uri)}
        }
        try check(requests == 0,"URI guards make no outgoing request")
        let callback = "https://relay.example.invalid/calendly?subscription=fixture", row: [String:Any] = ["uri":"https://api.calendly.com/webhook_subscriptions/fixture","callback_url":"https://relay.example.invalid/calendly?subscription=fixture","organization":organization,"scope":"organization","state":"active","events":CalendlyAPIClient.events]
        var pages = 0
        let paged = try CalendlyAPIClient(token:"fixture-api-token",request:{ req in
            pages += 1; try check(req.url!.host == "api.calendly.com","untrusted next_page URL never followed")
            return try response(req,["collection":pages == 1 ? [] : [row],"pagination":["next_page_token":pages == 1 ? "opaque-token" as Any : NSNull(),"next_page":"https://evil.invalid/steal"]])
        })
        let found = try await paged.find(callback:callback,organization:organization); try check(found != nil && pages == 2,"bounded provider pagination locates matching callback on later page")
        let loop = try CalendlyAPIClient(token:"fixture-api-token",request:{req in try response(req,["collection":[],"pagination":["next_page_token":"repeated"]])})
        try await reject("pagination loop fails closed"){_ = try await loop.find(callback:callback,organization:organization)}
        let duplicate = try CalendlyAPIClient(token:"fixture-api-token",request:{req in try response(req,["collection":[row,row],"pagination":["next_page_token":NSNull()]])})
        try await reject("duplicate matching registrations require review"){_ = try await duplicate.find(callback:callback,organization:organization)}
        let denied = try CalendlyAPIClient(token:"fixture-api-token",request:{req in try response(req,["error":"DO-NOT-EXPOSE-TOKEN"],status:403)})
        do { _ = try await denied.organization(); throw NativeDBError.conflict } catch let error as CalendlyAPIError { try check(!error.localizedDescription.contains("DO-NOT-EXPOSE"),"provider errors never expose response secrets") }
    }
    static func main() async {
        do { let resources = URL(fileURLWithPath:CommandLine.arguments[1]); try await apiGuards(); try await credentials(resources); try await lifecycle(resources); try await recovery(resources); try await fences(resources); if CommandLine.arguments.contains("--keychain-probe") { try await keychainProbe() }; print("CalendlySubscriptionTests: \(checks) checks passed; Keychain references, actual receiver, provider crash recovery and current permissions") }
        catch { FileHandle.standardError.write(Data("CalendlySubscriptionTests: \(error)\n".utf8)); exit(1) }
    }
    static func keychainProbe() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendlyKeychainProbe-"+UUID().uuidString)
        let store = KeychainCalendlySecrets(databaseURL:root.appendingPathComponent("a.sqlite")), other = KeychainCalendlySecrets(databaseURL:root.appendingPathComponent("b.sqlite")), id = UUID().uuidString.lowercased(), data = Data("fake-calendly-token-probe".utf8)
        defer{try? store.remove(id:id)}
        try store.save(id:id,data:data)
        try check(try store.load(id:id,interactive:false) == data,"real Keychain isolated fake item round trip")
        try check(try other.load(id:id,interactive:false) == nil,"real Keychain database scopes isolated")
        try await reject("real Keychain items immutable"){try store.save(id:id,data:Data("replacement".utf8))}
        try store.remove(id:id); try check(try store.load(id:id,interactive:false) == nil,"real Keychain fake item deleted")
    }
}
