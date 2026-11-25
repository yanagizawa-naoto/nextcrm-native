import Foundation

enum GoogleCalendarPushError: LocalizedError {
    case review(String)
    var errorDescription: String? { switch self { case let .review(message): return message } }
}

actor GoogleCalendarPushWorker {
    let db: NativeDatabase, store: GoogleCalendarSecretStore
    let request: GoogleCalendarOAuth.Request, eventRequest: GoogleCalendarOAuth.Request, clock: () -> Date
    private var active = false
    init(db: NativeDatabase,store: GoogleCalendarSecretStore,request: GoogleCalendarOAuth.Request? = nil,clock: @escaping () -> Date = Date.init) {
        self.db = db; self.store = store; self.request = request ?? GoogleCalendarOAuth.network
        self.eventRequest = request ?? Self.eventNetwork; self.clock = clock
    }
    /// One complete event may expand transiently; collection downloads remain
    /// streamed by the sync worker. OAuth/control replies retain their bound.
    static func eventNetwork(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard let url=request.url,url.scheme=="https",url.host=="www.googleapis.com",url.user==nil,url.password==nil,url.port==nil || url.port==443 else {throw NativeCalendarResponse.invalid}
        let reply=try await NativeCalendarResponse.network(request)
        return (try reply.data(maximumBytes:Int.max),reply.response)
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer{active = false}
        guard let job = try db.claimCalendarOutboundJob(now:clock()) else { return false }
        var owner: CRMService?, plan: GoogleCalendarPushPlan?, connection: NativeRecord?
        var providerFailed = false
        do {
            let result = job.result
            if ["unknown","confirmed"].contains(result["requestOutcome"] ?? ""), let json = result["plan"] { plan = try JSONDecoder().decode(GoogleCalendarPushPlan.self,from:Data(json.utf8)) }
            let activity = try job.payload["activity_id"].flatMap{try db.get("crm_Activities",key:["id":.text($0)])}
            let ownerID = plan?.ownerID ?? activity?["createdBy"].string ?? ""
            guard let user = try db.get("Users",key:["id":.text(ownerID)]) else {
                if plan != nil { throw GoogleCalendarPushError.review("予定の作成者を確認できません。Google側の反映結果を確認してください。") }
                let decision = try GoogleCalendarOutbound.decide(action:job.payload["operation"] ?? "upsert",activity:activity,mapping:try job.payload["activity_id"].flatMap{try db.calendarOutboundMapping(activityID:$0)},hasWriteConnection:false,now:clock())
                try db.finishJob(job,result:["pushed":"false","reason":decision.reason ?? "no-write-connection"],now:clock()); return true
            }
            let service = CRMService(db:db,identity:.init(id:ownerID,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string)); owner = service; try service.authenticated()
            if plan == nil { plan = try service.prepareGoogleCalendarPush(job,now:clock()) }
            guard var push = plan else { return true }
            if let confirmed = try db.requireJobLease(job).result["remote"], try db.requireJobLease(job).result["requestOutcome"] == "confirmed" {
                guard let remote = try JSONSerialization.jsonObject(with:Data(confirmed.utf8)) as? [String:Any] else { throw NativeDBError.conflict }
                try service.finishGoogleCalendarPush(job,plan:push,remote:remote,now:clock()); return true
            }
            var row = try service.googleCalendarConnection(push.connectionID); connection = row
            func validate() throws {
                try Task.checkCancellation(); _ = try db.requireJobLease(job); try service.authenticated()
                do { try db.requirePersonalCalendarOutboundAllowed(activityID:push.activityID,connectionID:push.connectionID,accountEmail:push.accountEmail,eventID:push.eventID) }
                catch { throw GoogleCalendarPushError.review(error.localizedDescription) }
                let current = try service.googleCalendarConnection(push.connectionID)
                guard current.revision == row.revision, current["isActive"] == .integer(1), current["scopeLevel"] == .text("readwrite"), current["accountEmail"] == .text(push.accountEmail), let activity = try db.get("crm_Activities",key:["id":.text(push.activityID)]), activity["createdBy"] == .text(push.ownerID) else { throw NativeDBError.conflict }
                if ["prepared","rejected"].contains(try db.requireJobLease(job).result["requestOutcome"] ?? "") {
                    let mapping = try db.calendarOutboundMapping(activityID:push.activityID)
                    guard activity.revision == push.activityRevision, mapping?["id"].string == push.mappingID, mapping?.revision == push.mappingRevision else { throw NativeDBError.conflict }
                }
            }
            func heartbeat() throws { try db.transaction { try validate(); try db.renewJobLease(job,now:clock()) } }
            try heartbeat(); var credentials = try service.googleCalendarGrant(row,store:store); try heartbeat()
            func refresh() async throws {
                try heartbeat()
                let next: GoogleCalendarStoredGrant
                do { next = try await GoogleCalendarOAuth.refresh(credentials,request:request,now:clock()) } catch { providerFailed = true; throw error }
                try heartbeat()
                let old = GoogleCalendarStorage.itemID(row["refreshTokenEncrypted"])
                func referenced(_ item:String)throws->Bool {
                    if try NativeUserCredentialCleanup.isHeld(db:db,family:.google,credentialID:item){return true}
                    if try service.googleCalendarClientReference()?.id==item{return true}
                    let reference=GoogleCalendarStorage.prefix+item
                    return try db.page("CalendarConnection",fields:["id"],equal:["refreshTokenEncrypted":.text(reference)],includeDeleted:true,limit:1).total>0 || db.page("CalendarConnection",fields:["id"],equal:["accessTokenEncrypted":.text(reference)],includeDeleted:true,limit:1).total>0
                }
                row = try NativeFreshCredentialPublication.perform(db:db,purpose:.google,ownerID:ownerID,authorize:service.authenticated,referenced:referenced,save:{item in
                    try heartbeat();try store.save(id:item,data:JSONEncoder().encode(next))
                },remove:{try store.remove(id:$0)}){item in
                    try validate()
                    return try db.update(row,changes:["refreshTokenEncrypted":.text(GoogleCalendarStorage.prefix+item),"accessTokenEncrypted":.null,"tokenExpiresAt":try next.grant.expiresAt.map{.text(try NativeCalendarEvents.stamp($0))} ?? .null,"scopeLevel":.text(next.grant.scope.rawValue)],actor:ownerID,action:"calendar_token_refreshed")
                }
                connection = row; credentials = next; if let old { try? NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .google, credentialID: old) { try store.remove(id:old) } }; try heartbeat()
            }
            if credentials.grant.expiresAt == nil || credentials.grant.expiresAt! <= clock().addingTimeInterval(60) { try await refresh() }
            func query(_ method: String,collection: Bool = false,body: [String:Any]? = nil,etag: String? = nil) throws -> URLRequest {
                guard !push.eventID.isEmpty, push.eventID.utf8.count <= 4096, !push.eventID.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeDBError.conflict }
                let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                let segment = push.eventID.addingPercentEncoding(withAllowedCharacters:allowed)!
                var url = URLComponents(string:"https://www.googleapis.com/calendar/v3/calendars/primary/events"+(collection ? "" : "/"+segment))!
                if method != "GET" { url.queryItems = [.init(name:"sendUpdates",value:"all")] }
                var request = URLRequest(url:url.url!); request.httpMethod = method; request.setValue("Bearer "+credentials.grant.accessToken,forHTTPHeaderField:"Authorization")
                if let body { request.httpBody = Data(try NativeCalendarEvents.json(body).utf8); request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
                if let etag { guard !etag.isEmpty, etag.utf8.count <= 4096, !etag.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeDBError.conflict }; request.setValue(etag,forHTTPHeaderField:"If-Match") }
                return request
            }
            func get() async throws -> [String:Any]? {
                var refreshed = false
                while true {
                    try heartbeat(); let response: (Data,HTTPURLResponse)
                    do { response = try await eventRequest(query("GET")) } catch { providerFailed = true; throw error }
                    try heartbeat()
                    if [404,410].contains(response.1.statusCode) { return nil }
                    if response.1.statusCode == 401 && !refreshed { refreshed = true; try await refresh(); continue }
                    do { return try GoogleCalendarOAuth.json(response.0,response:response.1,maximumBytes:Int.max) } catch { providerFailed = true; throw error }
                }
            }
            func matches(_ remote: [String:Any]) -> Bool {
                let privateValues = (remote["extendedProperties"] as? [String:Any])?["private"] as? [String:Any]
                return remote["id"] as? String == push.eventID && privateValues?["nextcrmPush"] as? String == push.marker && privateValues?["nextcrmActivity"] as? String == push.activityID
            }
            func confirm(_ remote: [String:Any]) throws {
                try db.transaction {
                    let current = try db.requireJobLease(job); var result = current.result
                    result["remote"] = try NativeCalendarEvents.json(remote); result["requestOutcome"] = "confirmed"
                    try db.recordJobResult(job,result:result)
                }
            }
            var refreshedMutation = false
            func mutate(_ method: String,body: [String:Any]? = nil,etag: String? = nil) async throws -> [String:Any] {
                let before = try db.requireJobLease(job).result["requestOutcome"]
                try db.transaction {
                    try heartbeat(); var result = try db.requireJobLease(job).result
                    result["plan"] = String(decoding:try JSONEncoder().encode(push),as:UTF8.self); result["requestOutcome"] = "unknown"
                    try db.recordJobResult(job,result:result); _ = try db.markJobDeliveryStarted(job,now:clock())
                }
                let response: (Data,HTTPURLResponse)
                do { response = try await eventRequest(query(method,collection:method == "POST",body:body,etag:etag)) } catch { providerFailed = true; throw error }
                // Preserve confirmation even if the user changed local settings
                // while Google was committing; publication still checks access.
                _ = try db.requireJobLease(job)
                if method == "DELETE", (200...299).contains(response.1.statusCode) || [404,410].contains(response.1.statusCode) { try confirm([:]); return [:] }
                let remote: [String:Any]
                do {
                    remote = try GoogleCalendarOAuth.json(response.0,response:response.1,maximumBytes:Int.max)
                    guard remote["id"] as? String == push.eventID else { throw GoogleCalendarPushError.review("Googleから返された予定を確認できません。反映結果を確認してください。") }
                } catch {
                    providerFailed = true
                    if let http = error as? GoogleCalendarHTTPError, (400...499).contains(http.status), ![408,409].contains(http.status), before != "unknown" {
                        var result = try db.requireJobLease(job).result; result["requestOutcome"] = "rejected"; try db.recordJobResult(job,result:result)
                    }
                    if (error as? GoogleCalendarHTTPError)?.status == 401, before != "unknown", !refreshedMutation {
                        refreshedMutation = true; try await refresh(); providerFailed = false
                        return try await mutate(method,body:body,etag:etag)
                    }
                    if (error as? GoogleCalendarHTTPError)?.status == 412 { throw GoogleCalendarPushError.review("Google側で予定が変更されています。内容を確認してから反映を再試行してください。") }
                    throw error
                }
                try confirm(remote); return remote
            }
            var remote = try await get()
            if push.action == "insert" {
                if let existing = remote {
                    guard matches(existing) else { throw GoogleCalendarPushError.review("同じ識別子の予定がありますが、このCRMの処理と一致しません。Google側の予定を確認してください。") }; try confirm(existing)
                } else {
                    var body = try JSONSerialization.jsonObject(with:Data(push.body.utf8)) as! [String:Any]
                    body["id"] = push.eventID; body["extendedProperties"] = ["private":["nextcrmPush":push.marker,"nextcrmActivity":push.activityID]]
                    do { remote = try await mutate("POST",body:body) }
                    catch let error as GoogleCalendarHTTPError where error.status == 409 {
                        guard let existing = try await get(), matches(existing) else { throw GoogleCalendarPushError.review("Google側の作成結果を確認できません。予定を確認してから再試行してください。") }; remote = existing; try confirm(existing)
                    }
                }
            } else if push.action == "delete" {
                if let existing = remote {
                    guard let etag = existing["etag"] as? String else { throw GoogleCalendarPushError.review("Google側の予定の版を確認できないため、取消を保留しました。") }
                    if try db.requireJobLease(job).result["requestOutcome"] == "unknown", push.etag != etag { throw GoogleCalendarPushError.review("前回の取消結果が未確定のままGoogle側の予定が変更されています。内容を確認してください。") }
                    push.etag = etag; plan = push
                    remote = try await mutate("DELETE",etag:etag)
                } else { remote = [:]; try confirm([:]) }
            } else {
                guard let existing = remote else { providerFailed = true; throw GoogleCalendarHTTPError(status:404,reason:"") }
                if matches(existing) { try confirm(existing) }
                else {
                    guard let etag = existing["etag"] as? String else { throw GoogleCalendarPushError.review("Google側の予定の版を確認できないため、変更を保留しました。") }
                    if try db.requireJobLease(job).result["requestOutcome"] == "unknown", let prior = push.etag, prior != etag { throw GoogleCalendarPushError.review("前回の反映結果が未確定のままGoogle側の予定が変更されています。内容を確認してください。") }
                    push.etag = etag; plan = push
                    var body = try JSONSerialization.jsonObject(with:Data(push.body.utf8)) as! [String:Any]
                    var properties = (existing["extendedProperties"] as? [String:Any])?["private"] as? [String:Any] ?? [:]
                    properties["nextcrmPush"] = push.marker; properties["nextcrmActivity"] = push.activityID
                    body["extendedProperties"] = ["private":properties]; body.removeValue(forKey:"attendees")
                    remote = try await mutate("PATCH",body:body,etag:etag)
                }
            }
            try service.finishGoogleCalendarPush(job,plan:push,remote:remote ?? [:],now:clock())
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            let message = (error as? GoogleCalendarPushError)?.localizedDescription ?? GoogleCalendarSyncWorker.message(error)
            let retryable = error is URLError || error is CancellationError || (error as? GoogleCalendarHTTPError)?.retryable == true || { if case NativeDBError.conflict = error { return true }; return false }()
            let confirmed = current.result["requestOutcome"] == "confirmed", uncertain = current.result["requestOutcome"] == "unknown"
            // Mapping/storage failures after acceptance retry only local work.
            let retry = (retryable || confirmed) && current.attempts < 4
            try db.transaction {
                _ = try db.requireJobLease(job)
                if providerFailed, let owner, let connection, let current = try? owner.googleCalendarConnection(connection["id"].string), current.revision == connection.revision {
                    var values: [String:SQLValue] = ["lastSyncError":.text(String(message.prefix(500)))]
                    if (error as? GoogleCalendarHTTPError)?.revoked == true { values["isActive"] = .integer(0) }
                    _ = try db.update(current,changes:values,actor:owner.identity.id,action:"calendar_push_failed")
                }
                try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(min(300,5*pow(2,Double(min(current.attempts-1,6))))) : nil,needsReview:!retry && (uncertain || confirmed || error is GoogleCalendarPushError))
            }
        }
        return true
    }
}
