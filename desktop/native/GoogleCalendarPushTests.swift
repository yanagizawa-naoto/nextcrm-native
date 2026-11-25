import Foundation
import SQLite3

@main enum GoogleCalendarPushTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ name: String) throws { guard try value() else { throw NativeDBError.message("GoogleCalendarPush FAIL: "+name) }; checks += 1 }
    static func record(_ model: String,_ input: Any?) throws -> NativeRecord? {
        guard let input = input as? [String:Any] else { return nil }; var values: [String:SQLValue] = [:]
        for (key,value) in input {
            if value is NSNull { values[key] = .null }
            else if let text = value as? String { values[key] = .text(text) }
            else if let number = value as? NSNumber { values[key] = .real(number.doubleValue) }
            else { values[key] = .text(try NativeCalendarEvents.json(value)) }
        }
        return NativeRecord(model:model,values:values,revision:0)
    }
    final class Store: GoogleCalendarSecretStore {
        var values: [String:Data] = [:]
        func load(id: String,interactive: Bool) throws -> Data? { values[id] }
        func save(id: String,data: Data) throws { guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data }
        func remove(id: String) throws { values.removeValue(forKey:id) }
    }
    final class Fixture {
        let root: URL,resources: URL,db: NativeDatabase,service: CRMService; let store = Store(); var now = Date(timeIntervalSince1970:1_800_000_000)
        var connection: NativeRecord!, activity: NativeRecord!
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GooglePushTests-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            try service.saveGoogleCalendarClient(clientID:"push-test.apps.googleusercontent.com",clientSecret:"fake-push-client",store:store)
            let ticket = try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:store)
            connection = try service.completeGoogleCalendarAuthorization(ticket,grant:.init(accountEmail:"rep@example.invalid",accessToken:"fake-push-access",refreshToken:"fake-push-refresh",expiresAt:now.addingTimeInterval(3600),grantedScopes:GoogleCalendarScope.readwrite.requested),store:store)
            activity = try db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text("日本語の商談"),"date":.text(try NativeCalendarEvents.stamp(now.addingTimeInterval(86400))),"status":.text("scheduled"),"createdBy":.text(service.identity.id),"duration":.integer(30)],actor:service.identity.id)
            let contact = try db.insert("crm_Contacts",values:["last_name":.text("顧客"),"email":.text("CLIENT@EXTERNAL.INVALID")],actor:service.identity.id)
            _ = try db.insert("crm_ActivityLinks",values:["activityId":activity["id"],"entityType":.text("contact"),"entityId":contact["id"]],actor:service.identity.id)
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        func current() throws -> NativeRecord { try db.get("crm_Activities",key:["id":activity["id"]])! }
        func enqueue(_ action: String = "upsert",activityID: String? = nil) throws -> String { try db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activityID ?? activity["id"].string,"operation":action],now:now) }
        func worker(_ server: Server) -> GoogleCalendarPushWorker { .init(db:db,store:store,request:server.send,clock:{self.now}) }
        func sql(_ sql: String) throws { var h: OpaquePointer?; guard sqlite3_open(db.url.path,&h) == SQLITE_OK else { throw NativeDBError.conflict }; defer{sqlite3_close(h)}; guard sqlite3_exec(h,sql,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(h))) } }
        func mapping() throws -> NativeRecord? { try db.calendarOutboundMapping(activityID:activity["id"].string) }
    }
    final class Server {
        var events: [String:[String:Any]] = [:], calls: [String] = [], patches: [[String:Any]] = []
        var inserts = 0, updates = 0, deletes = 0, lostReplyFor: String?, refuse: Int?, beforeGET: (() throws -> Void)?, afterWrite: (() throws -> Void)?
        var accessToken = "fake-push-access", beforeMutation: (() throws -> Void)?, intercept: ((URLRequest) throws -> (Data,HTTPURLResponse)?)?
        func response(_ request: URLRequest,_ body: [String:Any],_ status: Int = 200) throws -> (Data,HTTPURLResponse) { (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }
        func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
            let method = request.httpMethod ?? "GET", id = request.url!.lastPathComponent; calls.append(method)
            if let response = try intercept?(request) { return response }
            try check(request.value(forHTTPHeaderField:"Authorization") == "Bearer "+accessToken,"no token in URL, expected authorization header")
            if method == "GET" { try beforeGET?(); if let event = events[id] { return try response(request,event) }; return try response(request,["error":[:]],404) }
            let params = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems ?? []
            try check(params.contains{$0.name == "sendUpdates" && $0.value == "all"},"original guest notification behavior")
            if let refuse { return try response(request,["error":["errors":[["reason":refuse == 403 ? "forbiddenForNonOrganizer" : "unknown"]]]],refuse) }
            try beforeMutation?()
            let body = try request.httpBody.map{try JSONSerialization.jsonObject(with:$0) as! [String:Any]} ?? [:]
            var remote: [String:Any] = [:]
            if method == "POST" {
                let createdID = body["id"] as! String
                if events[createdID] != nil { return try response(request,["error":[:]],409) }
                remote = body; remote["etag"] = "\"version-1\""; remote["iCalUID"] = createdID+"@google.invalid"; remote["organizer"] = ["self":true]; events[createdID] = remote; inserts += 1
            } else {
                guard let existing = events[id] else { return try response(request,["error":[:]],404) }
                guard request.value(forHTTPHeaderField:"If-Match") == existing["etag"] as? String else { return try response(request,["error":[:]],412) }
                if method == "PATCH" { remote = existing.merging(body){_,new in new}; updates += 1; remote["etag"] = "\"version-\(updates+1)\""; events[id] = remote; patches.append(body) }
                else { events.removeValue(forKey:id); deletes += 1 }
            }
            try afterWrite?()
            if lostReplyFor == method { lostReplyFor = nil; throw URLError(.networkConnectionLost) }
            return try response(request,remote,method == "DELETE" ? 204 : 200)
        }
    }
    static func policy(_ resources: URL) throws {
        let ref = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/google-calendar-outbound-reference.json"))) as! [String:Any]
        for test in ref["decisions"] as! [[String:Any]] {
            let input = test["input"] as! [String:Any], expected = test["expected"] as! [String:Any]
            let actual = try GoogleCalendarOutbound.decide(action:input["action"] as! String,activity:record("crm_Activities",input["activity"]),mapping:record("crm_CalendarEvents",input["mapping"]),hasWriteConnection:input["hasWriteConnection"] as! Bool,now:NativeCalendarEvents.date(input["now"] as! String))
            try check(actual.action == expected["do"] as? String && actual.reason == expected["reason"] as? String && actual.eventID == expected["eventId"] as? String,"actual original outbound decision")
        }
        for test in ref["bodies"] as! [[String:Any]] {
            let activity = try record("crm_Activities",test["activity"])!, email = test["email"] as? String
            try check(try NativeCalendarEvents.json(GoogleCalendarOutbound.body(activity:activity,email:email)) == NativeCalendarEvents.json(test["expected"]!),"actual original event body")
            try check(try GoogleCalendarOutbound.body(activity:activity,email:email,patch:true)["attendees"] == nil,"patch never replaces Google guests")
        }
        for test in ref["counterparties"] as! [[String:Any]] {
            let f = try Fixture(resources)
            for row in try f.db.page("crm_ActivityLinks",fields:[]).rows { try f.db.remove(row,actor:f.service.identity.id) }
            let records = test["records"] as! [String:[[String:Any]]]; var ids: [String:String] = [:]
            for (model,rows) in records { for row in rows {
                var values = try record(model,row)!.values; let label = values.removeValue(forKey:"id")!.string
                if model == "crm_Contacts" || model == "crm_Targets" { values["last_name"] = .text("検証") }; if model == "crm_Leads" { values["lastName"] = .text("検証") }
                let saved = try f.db.insert(model,values:values,actor:f.service.identity.id); ids[label] = saved["id"].string
            } }
            for link in test["links"] as! [[String:String]] { _ = try f.db.insert("crm_ActivityLinks",values:["activityId":f.activity["id"],"entityType":.text(link["entityType"]!),"entityId":.text(ids[link["entityId"]!] ?? UUID().uuidString.lowercased())],actor:f.service.identity.id) }
            try check(try GoogleCalendarOutbound.counterparty(db:f.db,activityID:f.activity["id"].string) == test["expected"] as? String,"actual original contact/target/lead email fallback")
        }
    }
    static func lifecycle(_ resources: URL) async throws {
        let f = try Fixture(resources), server = Server(), worker = f.worker(server); let first = try f.enqueue(); _ = try await worker.runNext()
        let mapping = try f.mapping()!, eventID = mapping["externalId"].string
        try check(try f.db.job(id:first)?.status == "done" && server.inserts == 1 && mapping["activityId"] == f.activity["id"],"insert publishes stable Google mapping")
        try check(eventID.range(of:"^[0-9a-v]{5,1024}$",options:.regularExpression) != nil,"stable insert ID obeys Google constraints")
        var remote = server.events[eventID]!; remote["attendees"] = [["email":"client@external.invalid"],["email":"added-on-google@example.invalid"]]; remote["extendedProperties"] = ["private":["keep":"existing"]]; server.events[eventID] = remote
        _ = try f.db.update(f.current(),changes:["title":.text("更新した会議"),"date":.text(try NativeCalendarEvents.stamp(f.now.addingTimeInterval(172800)))],actor:f.service.identity.id)
        let patch = try f.enqueue(); _ = try await worker.runNext()
        try check(try f.db.job(id:patch)?.status == "done" && server.updates == 1 && server.patches[0]["attendees"] == nil && (server.events[eventID]!["attendees"] as! [[String:Any]]).count == 2,"patch preserves existing Google guest list")
        try check(((server.events[eventID]!["extendedProperties"] as? [String:Any])?["private"] as? [String:Any])?["keep"] as? String == "existing","operation marker preserves other private properties")
        let cancellation = try f.enqueue("cancel"); _ = try await worker.runNext()
        try check(try server.deletes == 1 && f.db.job(id:cancellation)?.status == "done" && f.mapping()?["status"] == .text("cancelled"),"delete retains cancelled mapping history")
        f.now = f.now.addingTimeInterval(1)
        let again = try f.enqueue(); _ = try await worker.runNext()
        try check(try server.inserts == 2 && f.db.job(id:again)?.status == "done" && f.db.page("crm_CalendarEvents",fields:[]).total == 2 && f.mapping()?["externalId"] != .text(eventID),"rescheduling cancelled mapping creates new Google event and retains history")
        let latest = try f.mapping()!; try f.service.disconnectGoogleCalendar(f.service.googleCalendarConnection(f.connection["id"].string),store:f.store)
        let newTicket = try f.service.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:f.store)
        _ = try f.service.completeGoogleCalendarAuthorization(newTicket,grant:.init(accountEmail:"different@example.invalid",accessToken:"fake-push-access",refreshToken:"fake-new-refresh",expiresAt:f.now.addingTimeInterval(3600),grantedScopes:GoogleCalendarScope.readwrite.requested),store:f.store)
        let mismatch = try f.enqueue("cancel"), callCount = server.calls.count; _ = try await worker.runNext()
        try check(try f.db.job(id:mismatch)?.result["reason"] == "connection-mismatch" && server.calls.count == callCount && f.db.get("crm_CalendarEvents",key:["id":latest["id"]])?["status"] == .text("scheduled"),"disconnected mapping never mutates via unrelated account")
    }
    static func recoveries(_ resources: URL) async throws {
        for method in ["POST","PATCH","DELETE"] {
            let f = try Fixture(resources), server = Server(), worker = f.worker(server)
            if method != "POST" { _ = try f.enqueue(); _ = try await worker.runNext() }
            server.lostReplyFor = method
            let job = try f.enqueue(method == "DELETE" ? "cancel" : "upsert"); _ = try await worker.runNext()
            try check(try f.db.job(id:job)?.status == "retry" && f.db.job(id:job)?.result["requestOutcome"] == "unknown","lost reply retains unknown outcome")
            let next = try f.enqueue(); try check(try f.db.claimCalendarOutboundJob(now:f.now) == nil,"later activity change cannot bypass unresolved earlier retry")
            f.now = f.now.addingTimeInterval(6); _ = try await worker.runNext()
            try check(try f.db.job(id:job)?.status == "done" && f.db.job(id:job)?.attempts == 2 && server.calls.filter{$0 == method}.count == 1,"remote confirmation recovers without repeated write/notification")
            try check(try f.db.job(id:next)?.status == "pending","following change stays queued until prior mapping published")
        }
        let f = try Fixture(resources), server = Server(), worker = f.worker(server); let job = try f.enqueue()
        try f.sql("CREATE TRIGGER push_mapping_failure BEFORE INSERT ON crm_CalendarEvents BEGIN SELECT RAISE(ABORT,'injected mapping failure'); END")
        _ = try await worker.runNext()
        try check(try f.db.job(id:job)?.result["requestOutcome"] == "confirmed" && f.db.job(id:job)?.status == "retry" && f.mapping() == nil && f.service.googleCalendarConnection(f.connection["id"].string)["lastSyncError"] == .null,"mapping failure retains remote receipt without marking connection error")
        try f.sql("DROP TRIGGER push_mapping_failure"); let calls = server.calls.count; f.now = f.now.addingTimeInterval(6); _ = try await worker.runNext()
        try check(try f.db.job(id:job)?.status == "done" && server.calls.count == calls && server.inserts == 1,"mapping retry performs local work only")
        let race = try Fixture(resources), racedServer = Server(), racedWorker = race.worker(racedServer); let raceJob = try race.enqueue(); var duplicateID: String?
        racedServer.afterWrite = {
            guard duplicateID == nil, let remote = racedServer.events.values.first else { return }
            let data = try JSONSerialization.data(withJSONObject:remote)
            if case let .event(event) = try NativeCalendarEvents.normalizeGoogle(data,connectionID:race.connection["id"].string,accountEmail:"rep@example.invalid") { duplicateID = try NativeCalendarImporter(db:race.db).apply(event,authorizedBy:race.service.identity).activityID }
        }
        _ = try await racedWorker.runNext()
        try check(try race.db.job(id:raceJob)?.status == "done" && race.mapping()?["activityId"] == race.activity["id"] && duplicateID != race.activity["id"].string,"inbound race mapping is repointed to original CRM meeting")
        try check(try race.db.get("crm_Activities",key:["id":.text(duplicateID!)])?["deletedAt"] != .null,"known inbound duplicate soft-deleted in reconciliation")
    }
    static func orderingAndFences(_ resources: URL) async throws {
        let f = try Fixture(resources); let first = try f.enqueue(), second = try f.enqueue()
        let otherDB = try NativeDatabase(url:f.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let claimed = try f.db.claimCalendarOutboundJob(now:f.now)!
        try check(try claimed.id == first && otherDB.claimCalendarOutboundJob(now:f.now) == nil && otherDB.nextCalendarOutboundJobDate(now:f.now) == f.now.addingTimeInterval(300),"one live outbound write across connections without busy polling")
        let newClaim = try otherDB.claimCalendarOutboundJob(now:f.now.addingTimeInterval(301))!
        try check(newClaim.id == first && newClaim.leaseToken != claimed.leaseToken,"expired lease reclaims same prior operation")
        try otherDB.failJob(newClaim,message:"review",needsReview:true)
        try check(try f.db.claimCalendarOutboundJob(now:f.now.addingTimeInterval(302)) == nil && f.db.nextCalendarOutboundJobDate(now:f.now) == nil,"review hold blocks same meeting and leaves no hot retry timer")
        let another = try f.db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text("別の会議"),"date":.text(try NativeCalendarEvents.stamp(f.now.addingTimeInterval(86400))),"status":.text("scheduled"),"createdBy":.text(f.service.identity.id)],actor:f.service.identity.id)
        let other = try f.enqueue(activityID:another["id"].string), independent = try f.db.claimCalendarOutboundJob(now:f.now)!
        try check(independent.id == other,"unrelated meeting progresses while original needs review"); try f.db.finishJob(independent)
        try f.db.retryCalendarOutboundJob(f.db.job(id:first)!); try check(try f.db.claimCalendarOutboundJob(now:f.now)?.id == first && f.db.job(id:second)?.status == "pending","manual recheck preserves original plan and causal order")
        let stale = try Fixture(resources), server = Server(); let job = try stale.enqueue(); let otherLease = try NativeDatabase(url:stale.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")); var reclaimed: NativeJob?
        server.afterWrite = { reclaimed = try otherLease.claimCalendarOutboundJob(now:stale.now.addingTimeInterval(301)) }
        _ = try await stale.worker(server).runNext()
        try check(try stale.db.job(id:job)?.leaseToken == reclaimed?.leaseToken && stale.mapping() == nil,"late response cannot publish after lease taken over")
        server.afterWrite = nil; stale.now = stale.now.addingTimeInterval(602); _ = try await stale.worker(server).runNext()
        try check(try stale.db.job(id:job)?.status == "done" && server.inserts == 1 && stale.mapping() != nil,"new process recovers stable event after abandoned response")
        let permission = try Fixture(resources), denied = Server(); let deniedJob = try permission.enqueue()
        denied.beforeGET = { let user = try permission.db.get("Users",key:["id":.text(permission.service.identity.id)])!; _ = try permission.db.update(user,changes:["banned":.integer(1)],actor:permission.service.identity.id) }
        _ = try await permission.worker(denied).runNext()
        try check(try denied.inserts == 0 && permission.db.job(id:deniedJob)?.status == "failed","revoked actor before mutation cannot push")
    }
    static func reviewsAndHistory(_ resources: URL) throws {
        let dates = try Fixture(resources), activityID = dates.activity["id"]
        let old = try dates.db.insert("crm_CalendarEvents",values:["source":.text("google"),"externalId":.text("old"),"activityId":activityID,"startAt":dates.activity["date"],"status":.text("cancelled"),"attendeeEmails":.text("[]"),"createdAt":.text("2026-11-15T01:00:00Z")],actor:dates.service.identity.id)
        let newer = try dates.db.insert("crm_CalendarEvents",values:["source":.text("google"),"externalId":.text("newer"),"activityId":activityID,"startAt":dates.activity["date"],"status":.text("scheduled"),"attendeeEmails":.text("[]"),"createdAt":.text("2026-11-15T01:00:00.900Z")],actor:dates.service.identity.id)
        try check(try dates.mapping()?["id"] == newer["id"],"subsecond mapping wins over older second-only timestamp")
        _ = try dates.db.update(old,changes:["source":.text("calendly")],actor:dates.service.identity.id)
        try check(try dates.mapping()?["id"] == old["id"],"Calendly ownership takes priority over newer Google mapping")
        let firstConnection = try dates.db.update(dates.connection,changes:["createdAt":.text("2026-11-15T01:00:00Z")],actor:dates.service.identity.id)
        let secondConnection = try dates.db.insert("CalendarConnection",values:["userId":.text(dates.service.identity.id),"provider":.text("google"),"accountEmail":.text("newer@example.invalid"),"scopeLevel":.text("readwrite"),"isActive":.integer(1),"refreshTokenEncrypted":.text("fake-unused-reference"),"createdAt":.text("2026-11-15T01:00:00.900Z")],actor:dates.service.identity.id)
        try check(try dates.db.calendarOutboundConnection(ownerID:dates.service.identity.id,preferredID:nil)?["id"] == firstConnection["id"],"fallback connection uses chronological order across timestamp formats")
        try check(try dates.db.calendarOutboundConnection(ownerID:dates.service.identity.id,preferredID:secondConnection["id"].string)?["id"] == secondConnection["id"],"bound connection takes priority over chronological fallback")
        let f = try Fixture(resources), id = try f.enqueue(), lease = try f.db.claimCalendarOutboundJob(now:f.now)!
        try f.db.recordJobResult(lease,result:["requestOutcome":"unknown","plan":String(repeating:"x",count:1_048_576)])
        try f.db.failJob(lease,message:"結果が未確定です",needsReview:true)
        let pending = try f.service.googleCalendarPushJob(id)
        func rejected(_ label: String,_ action: () throws -> Void) throws { var failed = false; do { try action() } catch { failed = true }; try check(failed,label) }
        try rejected("empty review note rejected"){ _ = try f.service.reviewGoogleCalendarPushNotApplied(pending,note:"  ") }
        try rejected("oversize review note rejected"){ _ = try f.service.reviewGoogleCalendarPushNotApplied(pending,note:String(repeating:"あ",count:2001)) }
        let other = try f.db.insert("Users",values:["name":.text("他の利用者"),"email":.text("push-other@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:f.service.identity.id)
        let otherService = CRMService(db:f.db,identity:.init(id:other["id"].string,role:"user",partnerAccountID:nil))
        try rejected("other owner cannot inspect history detail"){ _ = try otherService.googleCalendarPushJob(id) }
        try rejected("other owner cannot retry"){ try otherService.retryGoogleCalendarPush(pending) }
        try rejected("other owner cannot record review"){ _ = try otherService.reviewGoogleCalendarPushNotApplied(pending,note:"確認") }
        try check(try otherService.googleCalendarPushPage().total == 0,"history hides another owner's jobs")
        try f.sql("CREATE TRIGGER review_failure BEFORE UPDATE ON native_outbox WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT,'injected review failure'); END")
        try rejected("review and new job roll back together"){ _ = try f.service.reviewGoogleCalendarPushNotApplied(pending,note:"未反映を確認") }
        try check(try f.service.googleCalendarPushPage().total == 1 && f.db.job(id:id) == pending,"failed review leaves original job and no follow-up")
        try f.sql("DROP TRIGGER review_failure")
        let next = try f.service.reviewGoogleCalendarPushNotApplied(pending,note:"  Googleで予定なしを確認  ",now:f.now)
        let reviewed = try f.service.googleCalendarPushJob(id)
        try check(reviewed.status == "done" && reviewed.result["reviewNote"] == "Googleで予定なしを確認" && reviewed.result["reviewedBy"] == f.service.identity.id && reviewed.result["plan"] == pending.result["plan"],"immutable review preserves original evidence and trimmed note")
        try check(try f.db.job(id:next)?.payload["reviewed_job"] == id && f.db.claimCalendarOutboundJob(now:f.now)?.id == next,"review publishes a runnable follow-up atomically")
        try rejected("review cannot be repeated with stale snapshot"){ _ = try f.service.reviewGoogleCalendarPushNotApplied(pending,note:"再確認") }
        try rejected("completed review cannot be reopened"){ try f.service.retryGoogleCalendarPush(reviewed) }
        for _ in 0..<101 { _ = try f.enqueue() }
        let page = try f.service.googleCalendarPushPage(), tail = try f.service.googleCalendarPushPage(offset:100)
        try check(page.rows.count == 100 && page.total == 103 && tail.rows.count == 3,"history pages bounded at100 with stable tie ordering")
        try check(Set(page.rows.map{$0.job.id}).isDisjoint(with:Set(tail.rows.map{$0.job.id})),"same timestamp history has no duplicate page entries")
        try check((page.rows+tail.rows).allSatisfy{$0.job.result["plan"] == nil && $0.job.result["reviewNote"] == nil && $0.job.result.count <= 4},"large plan and private detail excluded by SQL summary projection")
        let confirmed = try Fixture(resources), confirmedID = try confirmed.enqueue(), confirmedLease = try confirmed.db.claimCalendarOutboundJob(now:confirmed.now)!
        try confirmed.db.recordJobResult(confirmedLease,result:["requestOutcome":"confirmed"]); try confirmed.db.failJob(confirmedLease,message:"local mapping issue",needsReview:true)
        try rejected("confirmed remote success cannot be marked unsubmitted"){ _ = try confirmed.service.reviewGoogleCalendarPushNotApplied(confirmed.db.job(id:confirmedID)!,note:"未反映") }
        let banned = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!; _ = try f.db.update(banned,changes:["banned":.integer(1)],actor:f.service.identity.id)
        try rejected("fresh ban prevents history access"){ _ = try f.service.googleCalendarPushPage() }
    }
    static func authenticationAndConflicts(_ resources: URL) async throws {
        for trigger in ["expired","GET","POST","PATCH","DELETE"] {
            let f = try Fixture(resources), server = Server(), worker = f.worker(server)
            if ["PATCH","DELETE"].contains(trigger) { _ = try f.enqueue(); _ = try await worker.runNext() }
            let oldReference = GoogleCalendarStorage.itemID(f.connection["refreshTokenEncrypted"])!
            if trigger == "expired" {
                let stored = try f.service.googleCalendarGrant(f.connection,store:f.store), grant = stored.grant
                let expired = GoogleCalendarStoredGrant(connectionID:stored.connectionID,userID:stored.userID,client:stored.client,grant:.init(accountEmail:grant.accountEmail,accessToken:grant.accessToken,refreshToken:grant.refreshToken,expiresAt:f.now.addingTimeInterval(-1),grantedScopes:grant.grantedScopes))
                f.store.values[oldReference] = try JSONEncoder().encode(expired)
            }
            var rejected = false, refreshes = 0
            server.intercept = { request in
                if request.url?.host == "oauth2.googleapis.com" {
                    refreshes += 1
                    let form = String(decoding:request.httpBody!,as:UTF8.self)
                    try check(form.contains("refresh_token=fake-push-refresh") && form.contains("grant_type=refresh_token") && request.url?.query == nil,"refresh credentials sent only in form body")
                    server.accessToken = "fake-refreshed-access"
                    return try server.response(request,["access_token":server.accessToken,"token_type":"Bearer","expires_in":3600])
                }
                if trigger != "expired", request.httpMethod == trigger, !rejected { rejected = true; return try server.response(request,["error":[:]],401) }
                return nil
            }
            let id = try f.enqueue(trigger == "DELETE" ? "cancel" : "upsert"); _ = try await worker.runNext()
            let row = try f.service.googleCalendarConnection(f.connection["id"].string), stored = try f.service.googleCalendarGrant(row,store:f.store)
            try check(try f.db.job(id:id)?.status == "done" && refreshes == 1 && stored.grant.accessToken == "fake-refreshed-access","outbound refresh succeeds for "+trigger)
            try check(stored.grant.refreshToken == "fake-push-refresh" && stored.grant.scope == .readwrite && f.store.values[oldReference] == nil,"refresh preserves omitted scope/token and removes obsolete secret")
            try check(try !String(describing:f.db.job(id:id)!).contains("fake-refreshed-access"),"job history excludes refreshed OAuth secret")
        }
        for outcome in ["revoked","readonly"] {
            let f = try Fixture(resources), server = Server(); f.now = f.now.addingTimeInterval(3601)
            server.intercept = { request in
                guard request.url?.host == "oauth2.googleapis.com" else { return nil }
                if outcome == "revoked" { return try server.response(request,["error":"invalid_grant"],400) }
                return try server.response(request,["access_token":"fake-readonly","token_type":"Bearer","expires_in":3600,"scope":GoogleCalendarScope.read])
            }
            let id = try f.enqueue(); _ = try await f.worker(server).runNext(); let row = try f.service.googleCalendarConnection(f.connection["id"].string)
            try check(server.inserts == 0 && server.updates == 0 && server.deletes == 0,"revocation or downgraded scope cannot mutate Google")
            if outcome == "revoked" { try check(try row["isActive"] == .integer(0) && f.db.job(id:id)?.status == "failed","invalid grant disables connection") }
            else { try check(try row["scopeLevel"] == .text("readonly") && f.db.job(id:id)?.status == "retry","actual downgraded scope saved before refusing write") }
        }
        for method in ["PATCH","DELETE"] {
            let f = try Fixture(resources), server = Server(), worker = f.worker(server); _ = try f.enqueue(); _ = try await worker.runNext(); let eventID = try f.mapping()!["externalId"].string
            server.beforeMutation = { server.beforeMutation = nil; server.events[eventID]?["etag"] = "changed-remotely"; server.events[eventID]?["summary"] = "Googleで変更" }
            let id = try f.enqueue(method == "DELETE" ? "cancel" : "upsert"); _ = try await worker.runNext(); let held = try f.db.job(id:id)!
            try check(held.status == "needs_review" && held.result["requestOutcome"] == "rejected" && server.events[eventID]?["summary"] as? String == "Googleで変更","412 retains remote changes and requires review for "+method)
            try f.service.retryGoogleCalendarPush(held); _ = try await worker.runNext()
            try check(try f.db.job(id:id)?.status == "done" && (method == "PATCH" ? server.updates == 1 : server.deletes == 1),"explicit 412 retry re-reads current revision")
        }
        for method in ["PATCH","DELETE"] {
            let f = try Fixture(resources), server = Server(), worker = f.worker(server); _ = try f.enqueue(); _ = try await worker.runNext(); let eventID = try f.mapping()!["externalId"].string
            server.beforeMutation = { server.beforeMutation = nil; throw URLError(.networkConnectionLost) }
            let id = try f.enqueue(method == "DELETE" ? "cancel" : "upsert"); _ = try await worker.runNext()
            server.events[eventID]?["etag"] = "edited-after-ambiguous-response"; server.events[eventID]?["summary"] = "後から編集"
            f.now = f.now.addingTimeInterval(6); _ = try await worker.runNext()
            try check(try f.db.job(id:id)?.status == "needs_review" && server.events[eventID]?["summary"] as? String == "後から編集" && server.updates == 0 && server.deletes == 0,"unknown previous result cannot overwrite or delete later Google edits for "+method)
        }
    }
    static func main() async { do { let resources = URL(fileURLWithPath:CommandLine.arguments[1]); try policy(resources); try await lifecycle(resources); try await recoveries(resources); try await orderingAndFences(resources); try reviewsAndHistory(resources); try await authenticationAndConflicts(resources); print("GoogleCalendarPushTests: \(checks) checks passed; actual original rules and simulated provider/SQLite recovery") } catch { FileHandle.standardError.write(Data("GoogleCalendarPushTests: \(error)\n".utf8)); exit(1) } }
}
