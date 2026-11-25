import Foundation

enum CalendlyJobs {
    static let sync = "native.calendly.sync", subscription = "native.calendly.subscription"
    static let interval: TimeInterval = 60
    static func pointer(_ event: String) -> String { event+".job.v1" }
    static let generation = "calendly.syncGeneration.v1"
    static func owner(db: NativeDatabase,id: String) throws -> CRMService {
        guard let user = try db.get("Users",key:["id":.text(id)]) else { throw NativeDBError.message("予約連携の担当者が見つかりません。") }
        let service = CRMService(db:db,identity:.init(id:id,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        try service.requireCalendlyAdmin(); return service
    }
    static func last(db: NativeDatabase,event: String) throws -> NativeJob? {
        guard let id = try db.metadata(pointer(event)), let job = try db.job(id:id), job.event == event else { return nil }; return job
    }
    /// No automatic retries of a terminal error; the administrator can inspect
    /// and request another run. Existing retry deadlines remain intact on wake.
    static func enqueueDue(db: NativeDatabase,now: Date = Date(),interval: TimeInterval = interval,force: Bool = false) throws -> Bool {
        let state = try CalendlyControlState.load(db)
        if let op = state.operation {
            guard let service = try? owner(db:db,id:op.actorID) else { return false }
            let job = try last(db:db,event:subscription)
            if job?.payload["operationID"] != op.id || job?.payload["actorID"] != op.actorID { _ = try service.requestCalendlyJob(subscription,now:now,manual:false) }
            return false
        }
        guard let reg = state.registration, let id = reg.actorID, state.credentialID != nil, let service = try? owner(db:db,id:id) else { return false }
        let job = try last(db:db,event:sync)
        let matches = job?.payload["registrationURI"] == reg.uri && job?.payload["actorID"] == id && job?.payload["credentialID"] == state.credentialID
        if matches, let job {
            if ["failed","needs_review","cancelled"].contains(job.status) { return false }
            if ["pending","running","retry"].contains(job.status) { if force { _ = try service.requestCalendlyJob(sync,now:now,manual:false) }; return true }
        }
        let last = try db.metadata("calendlyRelay.lastSyncedAt.v1").flatMap{try? NativeCalendarEvents.date($0)}
        if force || !matches || last == nil || last! > now || now.timeIntervalSince(last!) >= interval { _ = try service.requestCalendlyJob(sync,now:now,manual:false) }
        return true
    }
}
extension CRMService {
    @discardableResult func requestCalendlyJob(_ event: String,now: Date = Date(),manual: Bool = true) throws -> String {
        try db.transaction {
            let state = try calendlyControl(); let payload: [String:String]
            if event == CalendlyJobs.subscription {
                guard let op = state.operation, op.actorID == identity.id else { throw NativeDBError.message("通知設定の担当者が処理を再開するか、管理者が引き継いでください。") }
                payload = ["actorID":identity.id,"operationID":op.id]
            } else if event == CalendlyJobs.sync {
                guard state.operation == nil, let reg = state.registration, reg.actorID == identity.id, let id = state.credentialID else { throw NativeDBError.message("通知登録と自動取込の担当者を確認してください。") }
                payload = ["actorID":identity.id,"registrationURI":reg.uri,"credentialID":id]
                try db.setMetadata(CalendlyJobs.generation,value:UUID().uuidString.lowercased())
            } else { throw NativeDBError.conflict }
            if let job = try CalendlyJobs.last(db:db,event:event), job.payload == payload {
                if ["pending","running","retry"].contains(job.status) { if manual && job.status == "retry" { try db.retryJob(id:job.id,now:now) }; return job.id }
                if manual && job.status == "failed" { try db.retryJob(id:job.id,now:now); return job.id }
            }
            let id = try db.enqueue(event,payload:payload,now:now); try db.setMetadata(CalendlyJobs.pointer(event),value:id); return id
        }
    }
    func takeOverCalendlySync() throws {
        try db.transaction { let before = try calendlyControl(); guard before.registration != nil, before.operation == nil else { throw NativeDBError.conflict }; var next = before; next.registration!.actorID = identity.id; try next.save(db,expected:before) }
    }
}

actor CalendlyJobWorker {
    let db: NativeDatabase, store: CalendlySecretStore
    private let apiRequest: CalendlyAPIClient.Request, relayRequest: CalendlyRelayClient.Request?, clock: () -> Date, allowLoopbackHTTP: Bool
    private var active = false
    init(db: NativeDatabase,store: CalendlySecretStore,allowLoopbackHTTP: Bool = false,apiRequest: @escaping CalendlyAPIClient.Request = CalendlyRelayClient.network,relayRequest: CalendlyRelayClient.Request? = nil,clock: @escaping () -> Date = Date.init) {
        self.db = db; self.store = store; self.apiRequest = apiRequest; self.relayRequest = relayRequest; self.clock = clock; self.allowLoopbackHTTP = allowLoopbackHTTP
    }
    static func message(_ error: Error) -> String {
        if error is CancellationError { return "予約連携の処理を中断しました。起動後に再試行します。" }
        if error is CalendlyAPIError || error is CalendlyRelayError || error is NativeDBError { return error.localizedDescription }
        return "予約連携の処理が完了しませんでした。接続設定と空き容量を確認してください。"
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer{active = false}
        guard let job = try db.claimJob(events:[CalendlyJobs.subscription,CalendlyJobs.sync],now:clock()) else { return false }
        do {
            guard let actorID = job.payload["actorID"] else { throw NativeDBError.conflict }
            let service = try CalendlyJobs.owner(db:db,id:actorID)
            func heartbeat() throws {
                try db.transaction {
                    try Task.checkCancellation(); try service.requireCalendlyAdmin(); _ = try db.requireJobLease(job)
                    guard try db.metadata(CalendlyJobs.pointer(job.event)) == job.id else { throw NativeDBError.conflict }
                    try db.renewJobLease(job,now:clock())
                }
            }
            try heartbeat(); let state = try service.calendlyControl()
            if job.event == CalendlyJobs.subscription {
                guard let op = state.operation, op.id == job.payload["operationID"], op.actorID == actorID else { try db.finishJob(job,result:["skipped":"superseded"],now:clock()); return true }
                let manager = CalendlySubscriptionManager(service:service,store:store,allowLoopbackHTTP:allowLoopbackHTTP,apiRequest:apiRequest,relayRequest:relayRequest ?? CalendlyRelayClient.network,validate:{
                    try heartbeat(); let current = try service.calendlyControl()
                    guard current.operation == nil || (current.operation!.id == op.id && current.operation!.actorID == actorID) else { throw NativeDBError.conflict }
                })
                let completed = try await manager.resume(); try heartbeat()
                try db.transaction {
                    try db.finishJob(job,result:["operationID":op.id,"result":completed.registration == nil ? "unsubscribed" : "subscribed"],now:clock())
                    if completed.registration?.actorID == actorID, completed.operation == nil { _ = try service.requestCalendlyJob(CalendlyJobs.sync,now:clock(),manual:false) }
                }
            } else {
                guard state.operation == nil, let reg = state.registration, reg.actorID == actorID, reg.uri == job.payload["registrationURI"], state.credentialID == job.payload["credentialID"] else { try db.finishJob(job,result:["skipped":"superseded"],now:clock()); return true }
                let generation = try db.metadata(CalendlyJobs.generation), secret = try service.calendlyCredentials(state,store:store)
                let client = try secret.relay(db:db,allowLoopbackHTTP:allowLoopbackHTTP,request:relayRequest)
                guard let binding = try CalendlyRelayBinding.load(db:db) else { throw NativeDBError.conflict }
                let sync = try CalendlyRelaySync(service:service,client:client,binding:binding,clock:clock,validate:{try heartbeat(); guard try service.calendlyControl() == state else { throw NativeDBError.conflict }})
                let applied = try await sync.run(); try heartbeat()
                try db.transaction {
                    guard try service.calendlyControl() == state else { throw NativeDBError.conflict }
                    try db.finishJob(job,result:["applied":String(applied),"syncedAt":try NativeCalendarEvents.stamp(clock())],now:clock())
                    if try db.metadata(CalendlyJobs.generation) != generation { _ = try service.requestCalendlyJob(CalendlyJobs.sync,now:clock(),manual:false) }
                }
            }
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if try db.metadata(CalendlyJobs.pointer(job.event)) != job.id { try db.finishJob(current,result:["skipped":"superseded"],now:clock()); return true }
            let authorized = job.payload["actorID"].flatMap{try? CalendlyJobs.owner(db:db,id:$0)} != nil
            let retryable: Bool
            if let api = error as? CalendlyAPIError { retryable = api.status == nil || api.status == 429 || (api.status ?? 0) >= 500 }
            else if let relay = error as? CalendlyRelayError { retryable = relay.retryable }
            else if error is CancellationError { retryable = true }
            else if case NativeDBError.conflict = error { retryable = true }
            else { retryable = false }
            let retry = authorized && retryable && current.attempts < 4
            let uncertain = job.event == CalendlyJobs.subscription && (try? CalendlyControlState.load(db).operation?.phase) == .creating
            try db.failJob(current,message:Self.message(error),retryAt:retry ? clock().addingTimeInterval(min(300,5*pow(2,Double(current.attempts-1)))) : nil,needsReview:!retry && uncertain)
        }
        return true
    }
}
