import Foundation
import SQLite3

@main enum GoogleCalendarAuthTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("GoogleCalendarAuth FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ operation: () async throws -> Void) async throws { do { try await operation() } catch { checks += 1; return }; throw NativeDBError.message("GoogleCalendarAuth expected rejection: "+label) }
    final class Store: GoogleCalendarSecretStore {
        var values: [String:Data] = [:]; var failSave = false, failRemove = false
        func load(id: String, interactive: Bool) throws -> Data? { values[id] }
        func save(id: String, data: Data) throws { guard !failSave, values[id] == nil else { throw NativeDBError.message("test keychain save failure") }; values[id] = data }
        func remove(id: String) throws { guard !failRemove else { throw NativeDBError.message("test keychain delete failure") }; values.removeValue(forKey:id) }
    }
    final class Fixture {
        let root: URL, resources: URL; let db: NativeDatabase; let service: CRMService; let store = Store()
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GoogleCalendarAuth-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        func sql(_ text: String) throws { var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.message("test sqlite") }; defer{sqlite3_close(c)}; guard sqlite3_exec(c,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) } }
    }
    static let client = GoogleCalendarClientSettings(clientID:"test-desktop.apps.googleusercontent.com",clientSecret:"qa-calendar-client-secret-unique")
    static func grant(_ scope: GoogleCalendarScope = .readonly,_ email: String = "rep@example.invalid") -> GoogleCalendarGrant { .init(accountEmail:email,accessToken:"qa-calendar-access-token-unique",refreshToken:"qa-calendar-refresh-token-unique",expiresAt:Date(timeIntervalSince1970:1_900_000_000),grantedScopes:scope.requested) }
    static func response(_ request: URLRequest,_ body: [String:Any],status: Int = 200) throws -> (Data,HTTPURLResponse) { (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }
    static func services(_ resources: URL) async throws {
        let f = try Fixture(resources), s = f.service, db = f.db, store = f.store
        try s.saveGoogleCalendarClient(clientID:client.clientID,clientSecret:client.clientSecret,store:store)
        try check(try s.googleCalendarClientReference()?.clientID == client.clientID && store.values.count == 1,"scoped client settings saved without copying secret to metadata")
        let ticket = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:store), row = try s.completeGoogleCalendarAuthorization(ticket,grant:grant(.readwrite),store:store)
        try check(row["scopeLevel"] == .text("readwrite") && GoogleCalendarStorage.itemID(row["refreshTokenEncrypted"]) != nil && row["accessTokenEncrypted"] == .null,"public row uses opaque reference and actual grant scope")
        try check(try s.googleCalendarGrant(row,store:store).grant == grant(.readwrite),"bound credentials round trip")
        try await rejects("authorization ticket consumed once"){_ = try s.completeGoogleCalendarAuthorization(ticket,grant:grant(),store:store)}
        let upgrade = try s.beginGoogleCalendarAuthorization(expected:row,requested:.readonly,store:store)
        try check(upgrade.requested == .readwrite,"reauth requests at least prior permission")
        let downgraded = try s.completeGoogleCalendarAuthorization(upgrade,grant:grant(.readonly),store:store)
        try check(downgraded["scopeLevel"] == .text("readonly") && downgraded["syncToken"] == .null && store.values.count == 2,"actual granted downgrade is truthful and old credential removed")
        let mismatch = try s.beginGoogleCalendarAuthorization(expected:downgraded,requested:.readonly,store:store)
        try await rejects("wrong Google account on selected reauth"){_ = try s.completeGoogleCalendarAuthorization(mismatch,grant:grant(.readonly,"other@example.invalid"),store:store)}
        try check(try s.googleCalendarConnection(downgraded["id"].string).revision == downgraded.revision && store.values.count == 2,"rejected account does not replace existing grant")
        let cancelled = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store); try s.cancelGoogleCalendarAuthorization(cancelled)
        try await rejects("cancelled authorization"){_ = try s.completeGoogleCalendarAuthorization(cancelled,grant:grant(),store:store)}
        let older = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store), newer = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store)
        try await rejects("superseded authorization"){_ = try s.completeGoogleCalendarAuthorization(older,grant:grant(),store:store)}; try s.cancelGoogleCalendarAuthorization(newer)
        let configChanged = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store)
        try s.saveGoogleCalendarClient(clientID:client.clientID,clientSecret:"",store:store)
        try await rejects("configuration changed during browser auth"){_ = try s.completeGoogleCalendarAuthorization(configChanged,grant:grant(),store:store)}
        let revoked = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store), user = try db.get("Users",key:["id":.text(s.identity.id)])!
        _ = try db.update(user,changes:["banned":.integer(1)],actor:s.identity.id)
        try await rejects("permission revoked during browser auth"){_ = try s.completeGoogleCalendarAuthorization(revoked,grant:grant(),store:store)}
        let banned = try db.get("Users",key:["id":.text(s.identity.id)])!; _ = try db.update(banned,changes:["banned":.integer(0)],actor:s.identity.id)
        let failing = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store); let oldCount = store.values.count
        try f.sql("CREATE TRIGGER calendar_auth_failure BEFORE INSERT ON CalendarConnection BEGIN SELECT RAISE(ABORT,'test rollback'); END;")
        try await rejects("SQLite failure cleans unpublished Keychain item"){_ = try s.completeGoogleCalendarAuthorization(failing,grant:grant(.readonly,"new@example.invalid"),store:store)}
        let remainingConnections = try s.googleCalendarConnections().total
        try check(store.values.count == oldCount && remainingConnections == 1,"failed publish leaves old account intact")
        try f.sql("DROP TRIGGER calendar_auth_failure")
        let missing = try s.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store); store.failSave = true
        try await rejects("Keychain failure creates no row"){_ = try s.completeGoogleCalendarAuthorization(missing,grant:grant(.readonly,"new@example.invalid"),store:store)}; store.failSave = false
        let other = try db.insert("Users",values:["name":.text("他の利用者"),"email":.text("other-user@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:s.identity.id)
        let otherService = CRMService(db:db,identity:.init(id:other["id"].string,role:"user",partnerAccountID:nil))
        try check(try otherService.googleCalendarConnections().total == 0,"connections scoped to owner")
        try await rejects("administrator row inaccessible to other user"){_ = try otherService.googleCalendarConnection(row["id"].string)}
        try await rejects("ordinary user cannot change shared client"){try otherService.saveGoogleCalendarClient(clientID:client.clientID,clientSecret:"",store:store)}
        let allowed = try otherService.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store)
        let own = try otherService.completeGoogleCalendarAuthorization(allowed,grant:grant(),store:store)
        try check(try otherService.googleCalendarConnections().total == 1 && s.googleCalendarConnections().total == 1,"same Google account can connect independently for two CRM users")
        try await rejects("even admin cannot disconnect another user's connection"){try s.disconnectGoogleCalendar(own,store:store)}
        // Link a real imported event before disconnecting. Deletion preserves the
        // activity and mapping, clearing only the connection foreign key.
        _ = try db.insert("crm_Targets",values:["last_name":.text("顧客"),"email":.text("client@external.invalid")],actor:s.identity.id)
        let input = NativeCalendarInput(source:.google,externalID:"linked-event",connectionID:downgraded["id"].string,title:"予定",startAt:Date(timeIntervalSince1970:1_900_000_000),counterpartyEmails:["client@external.invalid"],hostEmail:"rep@example.invalid")
        let imported = try NativeCalendarImporter(db:db).apply(input,authorizedBy:s.identity)
        let inFlight = try s.beginGoogleCalendarAuthorization(expected:downgraded,requested:.readonly,store:store)
        store.failRemove = true
        try await rejects("failed Keychain deletion remains retryable"){try s.disconnectGoogleCalendar(downgraded,store:store)}
        let inactive = try s.googleCalendarConnection(row["id"].string); try check(inactive["isActive"] == .integer(0),"failed disconnect leaves inactive visible connection")
        try await rejects("auth cannot revive disconnected account"){_ = try s.completeGoogleCalendarAuthorization(inFlight,grant:grant(),store:store)}
        store.failRemove = false; try s.disconnectGoogleCalendar(inactive,store:store)
        let mapping = try db.page("crm_CalendarEvents",fields:["connectionId","activityId"],equal:["externalId":.text(input.externalID)]).rows.first!
        let preserved = try db.get("crm_Activities",key:["id":.text(imported.activityID!)])
        try check(mapping["connectionId"] == .null && mapping["activityId"] == .text(imported.activityID!) && preserved != nil,"disconnect preserves imported CRM history")
        for path in [db.url,URL(fileURLWithPath:db.url.path+"-wal")] where FileManager.default.fileExists(atPath:path.path) {
            let bytes = try Data(contentsOf:path)
            for secret in [client.clientSecret,grant().accessToken,grant().refreshToken] { try check(bytes.range(of:Data(secret.utf8)) == nil,"no OAuth secrets in SQLite or WAL") }
        }
        // Source profile routes allow every authenticated role, including partners.
        let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("パートナー企業")],actor:s.identity.id)
        let partner = try db.insert("Users",values:["email":.text("partner@example.invalid"),"role":.text("partner"),"userStatus":.text("ACTIVE"),"partnerAccountId":account["id"]],actor:s.identity.id)
        let partnerService = CRMService(db:db,identity:.init(id:partner["id"].string,role:"partner",partnerAccountID:account["id"].string))
        let partnerTicket = try partnerService.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store), partnerRow = try partnerService.completeGoogleCalendarAuthorization(partnerTicket,grant:grant(.readonly,"partner@example.invalid"),store:store)
        let partnerInput = NativeCalendarInput(source:.google,externalID:"partner-event",connectionID:partnerRow["id"].string,title:"予定",startAt:input.startAt,counterpartyEmails:["client@external.invalid"],hostEmail:"partner@example.invalid")
        try check(try NativeCalendarImporter(db:db).apply(partnerInput,authorizedBy:partnerService.identity).action == "created","authenticated partner-owned Google connection retains original capability")
    }
    static func transport(_ resources: URL) async throws {
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/google-calendar-auth-reference.json"))) as! [String:Any]
        for row in reference["scopeCases"] as! [[String:Any]] { try check(GoogleCalendarScope.granted(row["input"] as? String).rawValue == row["expected"] as? String,"original granted scope parity") }
        for row in reference["errorCases"] as! [[String:Any]] {
            let status = row["status"] as! Int, body = row["body"] as! [String:Any]
            let data = try JSONSerialization.data(withJSONObject:body), response = HTTPURLResponse(url:URL(string:"https://www.googleapis.com/calendar/v3/test")!,statusCode:status,httpVersion:nil,headerFields:nil)!
            do { _ = try GoogleCalendarOAuth.json(data,response:response); throw NativeDBError.message("Expected Google error") }
            catch let error as GoogleCalendarHTTPError {
                try check(error.revoked == (row["expected"] as! Bool),"actual original auth revocation classification")
                try check(!error.reason.contains("secret-placeholder") && !error.localizedDescription.contains("secret-placeholder"),"server error text is not retained or rendered")
            }
        }
        let pkce = reference["pkce"] as! [String:String], state = try GoogleCalendarOAuth.random()
        let auth = try GoogleCalendarOAuth.authorizationURL(client:client,scope:.readwrite,redirect:URL(string:"http://127.0.0.1:12345/")!,state:state,verifier:pkce["verifier"]!,loginHint:nil)
        let params = Dictionary(uniqueKeysWithValues:URLComponents(url:auth,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value!)})
        try check(params["code_challenge"] == pkce["challenge"] && params["code_challenge_method"] == "S256","independent PKCE challenge")
        try check(try state.count == 43 && state != GoogleCalendarOAuth.random() && !auth.absoluteString.contains(client.clientSecret),"fresh random state and no client secret in authorization URL")
        var requests: [URLRequest] = []; var callbackURL: URL?
        let result = try await GoogleCalendarBrowserAuthorization.run(client:client,scope:.readwrite,loginHint:nil,open:{ url in
            let values = Dictionary(uniqueKeysWithValues:URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value!)})
            let redirect = URL(string:values["redirect_uri"]!)!; callbackURL = redirect
            func callback(_ query: [URLQueryItem]) -> URL { var u = URLComponents(url:redirect,resolvingAgainstBaseURL:false)!; u.queryItems = query; return u.url! }
            for items in [[URLQueryItem(name:"state",value:"wrong"),.init(name:"code",value:"unused")],[.init(name:"state",value:values["state"]),.init(name:"state",value:nil),.init(name:"code",value:"unused")]] {
                let (_,response) = try await URLSession.shared.data(from:callback(items)); try check((response as? HTTPURLResponse)?.statusCode == 400,"invalid/duplicate state rejected without stopping valid attempt")
            }
            let (body,response) = try await URLSession.shared.data(from:callback([.init(name:"state",value:values["state"]),.init(name:"code",value:"qa-code+&=value")]))
            try check((response as? HTTPURLResponse)?.statusCode == 200 && !String(decoding:body,as:UTF8.self).contains("qa-code"),"real loopback callback accepted with no reflected secrets")
        },request:{ request in
            requests.append(request)
            if request.url!.host == "oauth2.googleapis.com" { return try response(request,["access_token":grant().accessToken,"refresh_token":grant().refreshToken,"token_type":"Bearer","scope":GoogleCalendarScope.read,"expires_in":3600]) }
            return try response(request,["id":"REP@example.invalid"])
        })
        try check(result.accountEmail == "rep@example.invalid" && result.scope == .readonly && requests.count == 2,"requested write permission does not override actual readonly grant")
        let body = String(decoding:requests[0].httpBody!,as:UTF8.self)
        try check(body.contains("code=qa-code%2B%26%3Dvalue") && body.contains("code_verifier=") && requests[1].value(forHTTPHeaderField:"Authorization") == "Bearer "+grant().accessToken,"token exchange form escaping and Authorization header")
        try await listenerClosed(callbackURL!)
        let receiver = try GoogleCalendarLoopback(state:GoogleCalendarOAuth.random(),timeout:0.1); let timeoutURL = try await receiver.start()
        try await rejects("authorization timeout"){_ = try await receiver.code()}; try await listenerClosed(timeoutURL)
        let cancelled = try GoogleCalendarLoopback(state:GoogleCalendarOAuth.random()); let cancelledURL = try await cancelled.start()
        let waiting = Task { try await cancelled.code() }; waiting.cancel()
        try await rejects("authorization cancellation"){_ = try await waiting.value}; try await listenerClosed(cancelledURL)
        try await rejects("missing refresh token"){_ = try await GoogleCalendarOAuth.exchange(client:client,code:"test",verifier:pkce["verifier"]!,redirect:URL(string:"http://127.0.0.1:12345/")!,request:{r in try response(r,["access_token":"access","token_type":"Bearer"])})}
        try await rejects("invalid client input"){_ = try GoogleCalendarClientSettings(clientID:"https://invalid.example",clientSecret:"").validated()}
        let denied = GoogleCalendarHTTPError(status:403,reason:"ratelimitexceeded"), revoked = GoogleCalendarHTTPError(status:403,reason:"insufficientpermissions")
        try check(denied.retryable && !denied.revoked && revoked.revoked && !revoked.retryable,"rate limit and permission revocation stay distinct")
    }
    static func listenerClosed(_ url: URL) async throws {
        for _ in 0..<10 {
            var request = URLRequest(url:url); request.timeoutInterval = 0.2
            do { _ = try await URLSession.shared.data(for:request) } catch let error as URLError where error.code == .cannotConnectToHost { checks += 1; return } catch { }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        throw NativeDBError.message("OAuth receiver remained open")
    }
    static func keychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendarKeychain-"+UUID().uuidString), store = KeychainGoogleCalendarSecrets(databaseURL:root.appendingPathComponent("crm.sqlite")), id = UUID().uuidString.lowercased(), data = Data("fake-calendar-keychain-probe".utf8)
        defer { try? store.remove(id:id) }
        try check(try store.load(id:id,interactive:true) == nil,"new scoped Keychain item absent")
        try store.save(id:id,data:data); try check(try store.load(id:id,interactive:true) == data,"real scoped Keychain read/write with fake data")
        try store.remove(id:id); try check(try store.load(id:id,interactive:true) == nil,"real scoped Keychain cleanup")
    }
    static func main() async { do { let resources = URL(fileURLWithPath:CommandLine.arguments[1]); try await services(resources); try await transport(resources); if CommandLine.arguments.contains("--keychain") { try keychain() }; print("GoogleCalendarAuthTests: \(checks) checks passed; real loopback callback, fake Google HTTP and isolated SQLite") } catch { FileHandle.standardError.write(Data("GoogleCalendarAuthTests: \(error)\n".utf8)); exit(1) } }
}
