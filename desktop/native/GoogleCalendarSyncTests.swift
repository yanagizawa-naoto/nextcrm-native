import Foundation
import SQLite3

@main enum GoogleCalendarSyncTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("GoogleCalendarSync FAIL: "+label) }; checks += 1 }
    final class Store: GoogleCalendarSecretStore {
        var values: [String:Data] = [:], failSave = false
        func load(id: String,interactive: Bool) throws -> Data? { values[id] }
        func save(id: String,data: Data) throws { guard !failSave, values[id] == nil else { throw NativeDBError.message("fake secret save failure") }; values[id] = data }
        func remove(id: String) throws { values.removeValue(forKey:id) }
    }
    final class Fixture {
        let root: URL, resources: URL, db: NativeDatabase, service: CRMService; let store = Store()
        var now = Date(timeIntervalSince1970:1_800_000_000); var id = ""
        init(_ resources: URL,expired: Bool = false) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GoogleSyncTests-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            try service.saveGoogleCalendarClient(clientID:"sync-test.apps.googleusercontent.com",clientSecret:"fake-sync-client-secret",store:store)
            let ticket = try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:store)
            let row = try service.completeGoogleCalendarAuthorization(ticket,grant:grant(expired:expired),store:store); id = row["id"].string
            _ = try db.insert("crm_Targets",values:["last_name":.text("同期先"),"email":.text("client@external.invalid"),"created_by":.text(service.identity.id)],actor:service.identity.id)
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        func grant(expired: Bool = false) -> GoogleCalendarGrant { .init(accountEmail:"rep@example.invalid",accessToken:"fake-sync-access",refreshToken:"fake-sync-refresh",expiresAt:now.addingTimeInterval(expired ? -60 : 3600),grantedScopes:GoogleCalendarScope.readwrite.requested) }
        func current() throws -> NativeRecord { try service.googleCalendarConnection(id) }
        func enqueue() throws -> String { try service.requestGoogleCalendarSync(current(),now:now) }
        func worker(_ request: @escaping GoogleCalendarOAuth.Request) -> GoogleCalendarSyncWorker { .init(db:db,store:store,request:request,clock:{self.now}) }
        func count(_ model: String = "crm_CalendarEvents") throws -> Int { try db.page(model,fields:[]).total }
        func setCursor(_ value: String) throws { _ = try db.update(current(),changes:["syncToken":.text(value)],actor:service.identity.id) }
        func sql(_ sql: String) throws { var h: OpaquePointer?; guard sqlite3_open(db.url.path,&h) == SQLITE_OK else { throw NativeDBError.conflict }; defer{sqlite3_close(h)}; guard sqlite3_exec(h,sql,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(h))) } }
        func reopen() throws -> NativeDatabase { try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
    }
    static func event(_ id: String,day: Int = 15) -> [String:Any] { ["id":id,"summary":"日本語の予定😀","start":["dateTime":String(format:"2027-01-%02dT10:00:00.000Z",day)],"attendees":[["email":"client@external.invalid"]]] }
    static func response(_ request: URLRequest,_ body: [String:Any],status: Int = 200) throws -> (Data,HTTPURLResponse) { (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }
    static func params(_ request: URLRequest) -> [String:String] { Dictionary(uniqueKeysWithValues:(URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []).map{($0.name,$0.value ?? "")}) }
    static func actualOriginal(_ resources: URL) async throws {
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/google-calendar-sync-reference.json"))) as! [String:Any]
        for test in reference["cases"] as! [[String:Any]] {
            let f = try Fixture(resources), expected = test["expected"] as! [String:Any], responses = test["responses"] as! [[String:Any]], queries = expected["queries"] as! [[String:Any]]
            if let cursor = test["cursor"] as? String { try f.setCursor(cursor) }
            let job = try f.enqueue(); var index = 0
            let worker = f.worker { request in
                try check(try f.count() == 0,"all downloads finish before any CRM import")
                let query = params(request), original = queries[index]
                try check(request.url?.path == "/calendar/v3/calendars/primary/events" && request.value(forHTTPHeaderField:"Authorization") == "Bearer fake-sync-access","primary calendar request with header token")
                for field in ["timeMin","timeMax","syncToken","pageToken","maxResults","singleEvents"] {
                    let value = field == "singleEvents" ? (original[field] as? Bool).map{$0 ? "true" : "false"} : original[field].map{String(describing:$0)}
                    try check(query[field] == value,"original request parameter: "+field)
                }
                let reply = responses[index]; index += 1
                if let status = reply["status"] as? Int { return try response(request,["error":reply["error"] ?? [:]],status:status) }
                return try response(request,reply)
            }
            let didRun = try await worker.runNext(); try check(didRun && index == responses.count,"source fixture consumed")
            let row = try f.current(), stored = try f.db.job(id:job)!
            try check((row["isActive"] == .integer(1)) == (expected["active"] as! Bool),"original connection active semantics")
            let cursor = expected["cursor"] as? String; try check(row["syncToken"] == (cursor.map(SQLValue.text) ?? .null),"original cursor commit/reset semantics")
            let ids = try f.db.page("crm_CalendarEvents",fields:["externalId"]).rows.map{$0["externalId"].string}.sorted()
            try check(ids == (expected["imported"] as! [String]).sorted(),"original imported events after success/failure/410")
            if let counts = expected["result"] as? [String:Int] { try check(stored.result == counts.mapValues(String.init) && stored.status == "done","original final event counts") }
            else { try check(["retry","failed"].contains(stored.status) && row["lastSyncedAt"] == .null,"failure never advances successful timestamp") }
        }
    }
    static func pagingAndRecovery(_ resources: URL) async throws {
        let f = try Fixture(resources); let job = try f.enqueue(); try check(try f.enqueue() == job,"duplicate queued requests coalesce")
        var page = 0
        let worker = f.worker { request in
            let lower = page*250, upper = min(501,lower+250); var reply: [String:Any] = ["items":(lower..<upper).map{event("bulk-\($0)")}]
            if page < 2 { reply["nextPageToken"] = "page-\(page+1)" } else { reply["nextSyncToken"] = "bulk-cursor" }
            page += 1; return try response(request,reply)
        }
        _ = try await worker.runNext()
        try check(try page == 3 && f.count() == 501 && f.db.job(id:job)?.result["created"] == "501","501 events processed in bounded pages")
        let reopened = try f.reopen(); try check(try reopened.get("CalendarConnection",key:["id":.text(f.id)])?["syncToken"] == .text("bulk-cursor"),"cursor survives reopen")
        let changeJob = try f.enqueue()
        _ = try await f.worker { request in try response(request,["items":[["id":"bulk-0","status":"cancelled"],event("bulk-1",day:16)],"nextSyncToken":"changed-cursor"]) }.runNext()
        try check(try f.count() == 501 && f.db.job(id:changeJob)?.result["cancelled"] == "1" && f.db.job(id:changeJob)?.result["updated"] == "1","incremental cancellation/reschedule preserve identity")
        let failed = try f.enqueue(); var download = 0
        let unstable = f.worker { request in download += 1; if download == 1 { return try response(request,["items":[event("later")],"nextPageToken":"later-page"]) }; throw URLError(.networkConnectionLost) }
        _ = try await unstable.runNext()
        try check(try f.count() == 501 && f.current()["syncToken"] == .text("changed-cursor") && f.db.job(id:failed)?.status == "retry","mid-download failure keeps original cursor and no staged changes")
        f.now = f.now.addingTimeInterval(6)
        _ = try await f.worker { request in try check(params(request)["syncToken"] == "changed-cursor","retry starts from old committed cursor"); return try response(request,["items":[event("later")],"nextSyncToken":"retried-cursor"]) }.runNext()
        try check(try f.count() == 502 && f.db.job(id:failed)?.attempts == 2 && f.db.job(id:failed)?.status == "done","durable same-job retry")
        let partial = try Fixture(resources); try partial.setCursor("before-partial"); let partialJob = try partial.enqueue()
        try partial.sql("CREATE TRIGGER late_import_failure BEFORE INSERT ON crm_CalendarEvents WHEN NEW.externalId='second' BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        let partialWorker = partial.worker { request in try response(request,["items":[event("first"),event("second")],"nextSyncToken":"after-partial"]) }
        _ = try await partialWorker.runNext()
        try check(try partial.count() == 1 && partial.count("crm_Activities") == 1 && partial.current()["syncToken"] == .text("before-partial") && partial.db.job(id:partialJob)?.status == "failed","late import rolls back current event and retains cursor")
        try partial.sql("DROP TRIGGER late_import_failure"); _ = try partial.enqueue(); _ = try await partialWorker.runNext()
        try check(try partial.count() == 2 && partial.count("crm_Activities") == 2 && partial.current()["syncToken"] == .text("after-partial"),"replay after partial import is idempotent")
        let final = try Fixture(resources); try final.setCursor("before-commit"); _ = try final.enqueue()
        try final.sql("CREATE TRIGGER final_cursor_failure BEFORE UPDATE ON CalendarConnection WHEN NEW.syncToken='after-commit' BEGIN SELECT RAISE(ABORT,'injected final failure'); END")
        let finalWorker = final.worker { request in try response(request,["items":[event("committed-event")],"nextSyncToken":"after-commit"]) }
        _ = try await finalWorker.runNext()
        try check(try final.count() == 1 && final.current()["syncToken"] == .text("before-commit") && final.current()["lastSyncedAt"] == .null,"final commit failure cannot publish cursor or success")
        try final.sql("DROP TRIGGER final_cursor_failure"); _ = try final.enqueue(); _ = try await finalWorker.runNext()
        try check(try final.count() == 1 && final.current()["syncToken"] == .text("after-commit"),"final-commit retry does not duplicate event")
    }
    static func refreshAndFences(_ resources: URL) async throws {
        let f = try Fixture(resources,expired:true); let oldRef = try f.current()["refreshTokenEncrypted"]; _ = try f.enqueue(); var requests = 0
        _ = try await f.worker { request in
            requests += 1
            if request.url?.host == "oauth2.googleapis.com" {
                let body = String(decoding:request.httpBody!,as:UTF8.self)
                try check(request.httpMethod == "POST" && body.contains("grant_type=refresh_token") && body.contains("refresh_token=fake-sync-refresh"),"refresh posts expected grant")
                return try response(request,["access_token":"fresh-access","refresh_token":"rotated-refresh","expires_in":3600,"token_type":"Bearer"])
            }
            try check(request.value(forHTTPHeaderField:"Authorization") == "Bearer fresh-access","feed uses refreshed access token")
            return try response(request,["items":[],"nextSyncToken":"fresh-cursor"])
        }.runNext()
        let current = try f.current(), grant = try f.service.googleCalendarGrant(current,store:f.store)
        try check(requests == 2 && current["refreshTokenEncrypted"] != oldRef && f.store.values.count == 2 && grant.grant.refreshToken == "rotated-refresh" && grant.grant.scope == .readwrite,"refresh atomically replaces secret and preserves omitted scope")
        for path in [f.db.url,URL(fileURLWithPath:f.db.url.path+"-wal")] where FileManager.default.fileExists(atPath:path.path) {
            let bytes = try Data(contentsOf:path); for secret in ["fresh-access","rotated-refresh","fake-sync-client-secret"] { try check(bytes.range(of:Data(secret.utf8)) == nil,"no secret in SQLite/WAL") }
        }
        let rejected = try Fixture(resources); _ = try rejected.enqueue(); var n = 0
        _ = try await rejected.worker { request in n += 1; if n == 1 { return try response(request,["error":[:]],status:401) }; if n == 2 { return try response(request,["access_token":"retried-access","expires_in":3600,"token_type":"Bearer","scope":GoogleCalendarScope.read]) }; return try response(request,["items":[],"nextSyncToken":"after401"]) }.runNext()
        try check(try n == 3 && rejected.current()["isActive"] == .integer(1) && rejected.current()["scopeLevel"] == .text("readonly"),"401 refreshes once and actual returned permission stored")
        let stale = try Fixture(resources); let staleJob = try stale.enqueue(); var revision: Int64 = 0
        _ = try await stale.worker { request in
            let ticket = try stale.service.beginGoogleCalendarAuthorization(expected:stale.current(),requested:.readonly,store:stale.store)
            let reconnected = try stale.service.completeGoogleCalendarAuthorization(ticket,grant:stale.grant(),store:stale.store); revision = reconnected.revision
            return try response(request,["error":"invalid_grant"],status:400)
        }.runNext()
        try check(try stale.current().revision == revision && stale.current()["isActive"] == .integer(1) && stale.current()["lastSyncError"] == .null && stale.count() == 0 && stale.db.job(id:staleJob)?.status == "retry","stale auth error cannot invalidate new connection")
        let revoked = try Fixture(resources); let revokedJob = try revoked.enqueue()
        _ = try await revoked.worker { request in let actor = try revoked.db.get("Users",key:["id":.text(revoked.service.identity.id)])!; _ = try revoked.db.update(actor,changes:["banned":.integer(1)],actor:actor["id"].string); return try response(request,["items":[event("unauthorized")],"nextSyncToken":"never"]) }.runNext()
        try check(try revoked.count() == 0 && revoked.db.job(id:revokedJob)?.status == "failed","actor revocation during await prevents import")
        let disconnected = try Fixture(resources); _ = try disconnected.enqueue()
        _ = try await disconnected.worker { request in try disconnected.service.disconnectGoogleCalendar(disconnected.current(),store:disconnected.store); return try response(request,["items":[event("removed")],"nextSyncToken":"never"]) }.runNext()
        try check(try disconnected.count() == 0 && disconnected.service.googleCalendarConnections().total == 0,"disconnect during request cannot recreate row or import")
        let lease = try Fixture(resources); let leaseJob = try lease.enqueue(); let other = try lease.reopen(); var reclaimed: NativeJob?
        _ = try await lease.worker { request in reclaimed = try other.claimJob(events:[GoogleCalendarSyncJobs.event],now:lease.now.addingTimeInterval(301)); return try response(request,["items":[event("stale-lease")],"nextSyncToken":"never"]) }.runNext()
        try check(try reclaimed?.id == leaseJob && lease.db.job(id:leaseJob)?.leaseToken == reclaimed?.leaseToken && lease.db.job(id:leaseJob)?.status == "running" && lease.count() == 0,"new lease fences old response and old completion")
        lease.now = lease.now.addingTimeInterval(602)
        _ = try await lease.worker { request in try response(request,["items":[event("recovered-lease")],"nextSyncToken":"recovered"]) }.runNext()
        try check(try lease.count() == 1 && lease.db.job(id:leaseJob)?.attempts == 3,"abandoned attempt is recoverable with same job")
        let wake = try Fixture(resources); let original = try wake.enqueue()
        _ = try await wake.worker { request in try check(try wake.enqueue() == original,"wake coalesces while running"); return try response(request,["items":[],"nextSyncToken":"first-wake"]) }.runNext()
        let following = try wake.service.googleCalendarSyncJob(wake.id)!
        try check(try following.id != original && following.status == "pending" && wake.db.job(id:original)?.status == "done","wake during sync creates one follow-up after success")
    }
    static func invalidResponses(_ resources: URL) async throws {
        let cases: [[String:Any]] = [["items":"bad","nextSyncToken":"bad"],["items":[event("missing-cursor")]],["items":[],"nextPageToken":"both","nextSyncToken":"both"],["items":Array(repeating:event("overflow"),count:251),"nextSyncToken":"bad"]]
        for body in cases { let f = try Fixture(resources); let job = try f.enqueue(); _ = try await f.worker{request in try response(request,body)}.runNext(); try check(try f.count() == 0 && f.current()["syncToken"] == .null && f.db.job(id:job)?.status == "failed","malformed page cannot mark success or advance cursor") }
        let loop = try Fixture(resources); let loopJob = try loop.enqueue(); var requests = 0
        _ = try await loop.worker { request in requests += 1; return try response(request,["items":[],"nextPageToken":"same"]) }.runNext()
        try check(try requests == 2 && loop.db.job(id:loopJob)?.status == "failed","repeated page token stops using disk-backed history")
        let secret = try Fixture(resources); let secretJob = try secret.enqueue()
        _ = try await secret.worker { _ in throw NativeDBError.message("fake-sync-refresh must not reach UI") }.runNext()
        try check(try !(secret.db.job(id:secretJob)?.lastError ?? "").contains("fake-sync-refresh") && !secret.current()["lastSyncError"].string.contains("fake-sync-refresh"),"arbitrary transport error cannot disclose secrets")
        let unavailable = try Fixture(resources,expired:true); let prior = try unavailable.current()["refreshTokenEncrypted"]; let failedJob = try unavailable.enqueue(); unavailable.store.failSave = true
        _ = try await unavailable.worker { request in try response(request,["access_token":"unpublished-access","expires_in":3600,"token_type":"Bearer"]) }.runNext()
        try check(try unavailable.current()["refreshTokenEncrypted"] == prior && unavailable.store.values.count == 2 && unavailable.db.job(id:failedJob)?.status == "failed","failed Keychain replacement retains prior reference")
        var spoolPath: URL!
        do { let spool = try GoogleCalendarSpool(); spoolPath = spool.directory; try spool.append([event("disk")]); var count = 0; try spool.forEach{_ in count += 1}; try check(count == 1,"spool streams staged records"); try spool.reset(); count = 0; try spool.forEach{_ in count += 1}; try check(count == 0,"spool reset discards expired cursor records") }
        try check(!FileManager.default.fileExists(atPath:spoolPath.path),"normal spool lifecycle removes private files")
    }
    static func main() async { do { let resources = URL(fileURLWithPath:CommandLine.arguments[1]); try await actualOriginal(resources); try await pagingAndRecovery(resources); try await refreshAndFences(resources); try await invalidResponses(resources); print("GoogleCalendarSyncTests: \(checks) checks passed; original sync fixtures, paginated fake HTTP, scoped secrets and isolated SQLite") } catch { FileHandle.standardError.write(Data("GoogleCalendarSyncTests: \(error)\n".utf8)); exit(1) } }
}
