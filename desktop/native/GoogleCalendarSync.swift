import Foundation

enum GoogleCalendarSyncJobs {
    static let event = "native.google-calendar.sync"
    static func pointer(_ connection: String) -> String { "calendar.google.syncJob."+connection }
    static func generation(_ connection: String) -> String { "calendar.google.syncGeneration."+connection }
}
extension CRMService {
    @discardableResult func requestGoogleCalendarSync(_ expected: NativeRecord, now: Date = Date()) throws -> String {
        try db.transaction {
            let current = try googleCalendarConnection(expected["id"].string)
            guard current.revision == expected.revision, current["isActive"] == .integer(1) else { throw NativeDBError.conflict }
            let id = current["id"].string
            try db.setMetadata(GoogleCalendarSyncJobs.generation(id),value:UUID().uuidString.lowercased())
            if let jobID = try db.metadata(GoogleCalendarSyncJobs.pointer(id)), let job = try db.job(id:jobID), job.event == GoogleCalendarSyncJobs.event, job.payload["actorID"] == identity.id, job.payload["connectionID"] == id, ["pending","retry","running"].contains(job.status) {
                if job.status == "retry" { try db.retryJob(id:jobID,now:now) }; return jobID
            }
            let jobID = try db.enqueue(GoogleCalendarSyncJobs.event,payload:["actorID":identity.id,"connectionID":id],now:now)
            try db.setMetadata(GoogleCalendarSyncJobs.pointer(id),value:jobID); return jobID
        }
    }
    func googleCalendarSyncJob(_ connectionID: String) throws -> NativeJob? {
        _ = try googleCalendarConnection(connectionID)
        guard let id = try db.metadata(GoogleCalendarSyncJobs.pointer(connectionID)), let job = try db.job(id:id), job.event == GoogleCalendarSyncJobs.event, job.payload["actorID"] == identity.id, job.payload["connectionID"] == connectionID else { return nil }; return job
    }
}

extension GoogleCalendarOAuth {
    static func refresh(_ stored: GoogleCalendarStoredGrant, request: @escaping Request = network, now: Date = Date()) async throws -> GoogleCalendarStoredGrant {
        _ = try stored.client.validated(); _ = try stored.grant.validated()
        var fields = ["client_id":stored.client.clientID,"refresh_token":stored.grant.refreshToken,"grant_type":"refresh_token"]
        if !stored.client.clientSecret.isEmpty { fields["client_secret"] = stored.client.clientSecret }
        var query = URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!); query.httpMethod = "POST"; query.httpBody = form(fields); query.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        try Task.checkCancellation(); let (data,response) = try await request(query); try Task.checkCancellation()
        let tokens = try json(data,response:response)
        guard let access = tokens["access_token"] as? String, (tokens["token_type"] as? String)?.lowercased() == "bearer", let seconds = tokens["expires_in"] as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite, (0...31_536_000).contains(seconds.doubleValue), seconds.doubleValue > 0 else { throw NativeDBError.message("Googleから新しい認証情報を取得できませんでした。") }
        if let scope = tokens["scope"], !(scope is String) { throw NativeDBError.message("Googleの権限情報が不正です。") }
        if let token = tokens["refresh_token"], !(token is String) { throw NativeDBError.message("Googleの更新用認証情報が不正です。") }
        let grant = try GoogleCalendarGrant(accountEmail:stored.grant.accountEmail,accessToken:access,refreshToken:tokens["refresh_token"] as? String ?? stored.grant.refreshToken,expiresAt:now.addingTimeInterval(seconds.doubleValue),grantedScopes:tokens["scope"] as? String ?? stored.grant.grantedScopes).validated()
        return .init(connectionID:stored.connectionID,userID:stored.userID,client:stored.client,grant:grant)
    }
}

/// One durable job per connection; retries replay the previous cursor. Provider
/// pages live in a private disk spool, with only one page/event decoded at a time.
actor GoogleCalendarSyncWorker {
    static let maximumPageBytes = 16*1_048_576
    let db: NativeDatabase; let store: GoogleCalendarSecretStore
    let request: GoogleCalendarOAuth.Request; let pageRequest:NativeCalendarResponse.Request; let clock: () -> Date
    private var active = false
    init(db:NativeDatabase,store:GoogleCalendarSecretStore,request:GoogleCalendarOAuth.Request?=nil,pageRequest:NativeCalendarResponse.Request?=nil,clock:@escaping()->Date=Date.init) {
        self.db=db;self.store=store;self.request=request ?? GoogleCalendarOAuth.network;self.clock=clock
        if let pageRequest{self.pageRequest=pageRequest}
        else if let request{self.pageRequest={query in let(data,response)=try await request(query);return try NativeCalendarResponse(data:data,response:response)}}
        else{self.pageRequest=Self.diskNetwork}
    }
    static func diskNetwork(_ request:URLRequest)async throws->NativeCalendarResponse {
        guard let url=request.url,url.scheme=="https",url.host=="www.googleapis.com",url.user==nil,url.password==nil,url.port==nil || url.port==443 else{throw NativeDBError.message("Googleの接続先が不正です。")}
        return try await NativeCalendarResponse.network(request)
    }
    static func network(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) { try await GoogleCalendarOAuth.boundedNetwork(request,maximumBytes:maximumPageBytes) }
    static func message(_ error: Error) -> String {
        if let error = error as? GoogleCalendarHTTPError { return error.localizedDescription }
        if error is CancellationError { return "カレンダーの同期を中断しました。再開後に再試行します。" }
        if error is URLError { return "Googleに接続できません。ネットワークを確認して、もう一度同期してください。" }
        if case NativeDBError.conflict = error { return "同期中に接続または処理が更新されました。新しい設定で再試行します。" }
        return "カレンダーを同期できませんでした。接続設定と空き容量を確認して、もう一度同期してください。"
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer{active = false}
        guard let job = try db.claimJob(events:[GoogleCalendarSyncJobs.event],now:clock()) else { return false }
        var expected: NativeRecord?; var service: CRMService?
        do {
            guard let actorID = job.payload["actorID"], let id = job.payload["connectionID"], let actor = try db.get("Users",key:["id":.text(actorID)]) else { throw NativeDBError.conflict }
            let owner = CRMService(db:db,identity:.init(id:actorID,role:actor["role"].string,partnerAccountID:actor["partnerAccountId"] == .null ? nil : actor["partnerAccountId"].string)); service = owner
            var row = try owner.googleCalendarConnection(id); expected = row
            guard row["isActive"] == .integer(1) else { try db.finishJob(job,result:["skipped":"inactive"],now:clock()); return true }
            let generation = try db.metadata(GoogleCalendarSyncJobs.generation(id)) ?? ""
            func validate() throws {
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                let current = try owner.googleCalendarConnection(id)
                guard current.revision == row.revision, current["isActive"] == .integer(1), try db.metadata(GoogleCalendarSyncJobs.pointer(id)) == job.id else { throw NativeDBError.conflict }
            }
            func heartbeat() throws { try db.transaction { try validate(); try db.renewJobLease(job,now:clock()) } }
            try heartbeat(); var credentials = try owner.googleCalendarGrant(row,store:store); try heartbeat()
            func refresh() async throws {
                try heartbeat(); let updated = try await GoogleCalendarOAuth.refresh(credentials,request:request,now:clock()); try heartbeat()
                let previous = GoogleCalendarStorage.itemID(row["refreshTokenEncrypted"])
                func referenced(_ item:String)throws->Bool {
                    if try NativeUserCredentialCleanup.isHeld(db:db,family:.google,credentialID:item){return true}
                    if try owner.googleCalendarClientReference()?.id==item{return true}
                    let reference=GoogleCalendarStorage.prefix+item
                    return try db.page("CalendarConnection",fields:["id"],equal:["refreshTokenEncrypted":.text(reference)],includeDeleted:true,limit:1).total>0 || db.page("CalendarConnection",fields:["id"],equal:["accessTokenEncrypted":.text(reference)],includeDeleted:true,limit:1).total>0
                }
                row = try NativeFreshCredentialPublication.perform(db:db,purpose:.google,ownerID:actorID,authorize:owner.authenticated,referenced:referenced,save:{item in
                    try heartbeat();try store.save(id:item,data:JSONEncoder().encode(updated))
                },remove:{try store.remove(id:$0)}){item in
                    try validate()
                    return try db.update(row,changes:["refreshTokenEncrypted":.text(GoogleCalendarStorage.prefix+item),"accessTokenEncrypted":.null,"tokenExpiresAt":try updated.grant.expiresAt.map{.text(try NativeCalendarEvents.stamp($0))} ?? .null,"scopeLevel":.text(updated.grant.scope.rawValue)],actor:actorID,action:"calendar_token_refreshed")
                }
                expected = row; credentials = updated; if let previous { try? NativeUserCredentialCleanup.removeUnlessHeld(db: db, family: .google, credentialID: previous) { try store.remove(id:previous) } }
            }
            if credentials.grant.expiresAt == nil || credentials.grant.expiresAt! <= clock().addingTimeInterval(60) { try await refresh() }
            let spool = try GoogleCalendarSpool(), start = clock()
            var syncToken = row["syncToken"] == .null || row["syncToken"].string.isEmpty ? nil : row["syncToken"].string
            var pageToken: String?, nextSyncToken: String?, reset = false, refreshedAfterUnauthorized = false
            func token(_ value: Any?) throws -> String? {
                guard let value, !(value is NSNull) else { return nil }
                guard let text = value as? String, !text.isEmpty, text.utf8.count <= 16_384, !text.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw NativeDBError.message("Googleの同期情報が不正です。") }; return text
            }
            while true {
                try heartbeat()
                var url = URLComponents(string:"https://www.googleapis.com/calendar/v3/calendars/primary/events")!
                var fields = [URLQueryItem(name:"singleEvents",value:"true"),.init(name:"maxResults",value:"250")]
                if let syncToken { fields.append(.init(name:"syncToken",value:syncToken)) }
                else { fields += [URLQueryItem(name:"timeMin",value:try NativeCalendarEvents.stamp(start.addingTimeInterval(-60*86400))),.init(name:"timeMax",value:try NativeCalendarEvents.stamp(start.addingTimeInterval(60*86400)))] }
                if let pageToken { fields.append(.init(name:"pageToken",value:pageToken)) }; url.queryItems = fields
                var query = URLRequest(url:url.url!); query.setValue("Bearer "+credentials.grant.accessToken,forHTTPHeaderField:"Authorization")
                do {
                    let response=try await pageRequest(query);try heartbeat()
                    let page=try spool.appendPage(response)
                    let following = try token(page["nextPageToken"]), cursor = try token(page["nextSyncToken"])
                    guard following == nil || cursor == nil else { throw NativeDBError.message("Googleのページ情報が不正です。") }
                    if let following { try spool.remember(following); pageToken = following }
                    else { guard let cursor else { throw NativeDBError.message("Googleの同期完了情報がありません。") }; nextSyncToken = cursor; break }
                } catch let error as GoogleCalendarHTTPError {
                    if error.status == 410 && syncToken != nil && !reset { try spool.reset(); syncToken = nil; pageToken = nil; reset = true; continue }
                    if error.status == 401 && !refreshedAfterUnauthorized { refreshedAfterUnauthorized = true; try await refresh(); continue }
                    throw error
                }
            }
            var counts = ["events":0,"created":0,"updated":0,"cancelled":0,"skipped":0]
            try spool.forEach { data in
                try db.transaction {
                    try heartbeat(); counts["events",default:0] += 1
                    switch try NativeCalendarEvents.normalizeGoogle(data,connectionID:id,accountEmail:row["accountEmail"].string) {
                    case .skipped:counts["skipped",default:0] += 1
                    case let .event(event): let result = try NativeCalendarImporter(db:db).apply(event,authorizedBy:owner.identity); counts[result.action,default:0] += 1
                    }
                }
            }
            try db.transaction {
                try validate()
                row = try db.update(row,changes:["syncToken":nextSyncToken.map(SQLValue.text) ?? .null,"lastSyncedAt":.text(try NativeCalendarEvents.stamp(clock())),"lastSyncError":.null],actor:actorID,action:"calendar_synced"); expected = row
                try db.finishJob(job,result:counts.mapValues(String.init),now:clock())
                if try db.metadata(GoogleCalendarSyncJobs.generation(id)) != generation { _ = try owner.requestGoogleCalendarSync(row,now:clock()) }
            }
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            let message = Self.message(error)
            let retryable = (error as? GoogleCalendarHTTPError)?.retryable == true || error is URLError || error is CancellationError || { if case NativeDBError.conflict = error { return true }; return false }()
            try db.transaction {
                _ = try db.requireJobLease(job)
                if let expected, let service, let current = try? service.googleCalendarConnection(expected["id"].string), current.revision == expected.revision, current["isActive"] == .integer(1), try db.metadata(GoogleCalendarSyncJobs.pointer(current["id"].string)) == job.id {
                    var changes: [String:SQLValue] = ["lastSyncError":.text(String(message.prefix(500)))]
                    if (error as? GoogleCalendarHTTPError)?.revoked == true { changes["isActive"] = .integer(0) }
                    _ = try db.update(current,changes:changes,actor:service.identity.id,action:"calendar_sync_failed")
                }
                let retry = retryable && current.attempts < 4
                try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(min(300,5*pow(2,Double(current.attempts-1)))) : nil)
            }
        }
        return true
    }
}
