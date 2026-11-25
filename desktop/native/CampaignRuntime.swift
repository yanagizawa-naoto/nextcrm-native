import Foundation

enum CampaignRelayJobs {
    static let event = "native.campaign-relay.sync"
    static let pointer = "campaignRelay.syncJob.v1"
    static let generation = "campaignRelay.syncGeneration.v1"
    static let lastSuccess = "campaignRelay.lastSuccess.v1"
    /// Persist a wake without a polling timer. Requests arriving during a running
    /// sync advance the generation so its completion queues one more pass.
    @discardableResult static func request(db: NativeDatabase, now: Date = Date()) throws -> String? {
        try db.transaction {
            guard try CampaignRelayBinding.load(db:db) != nil else { return nil }
            let token = UUID().uuidString.lowercased(); try db.setMetadata(generation,value:token)
            if let id = try db.metadata(pointer), let job = try db.job(id:id), job.event == event, ["pending","retry","running"].contains(job.status) {
                if job.status == "retry" { try db.retryJob(id:id,now:now) }; return id
            }
            let id = try db.enqueue(event,payload:[:],now:now); try db.setMetadata(pointer,value:id); return id
        }
    }
}

actor CampaignRelayCoordinator {
    let db: NativeDatabase
    let store: CampaignRelayCredentialStore
    let allowLoopbackHTTP: Bool
    let request: CampaignRelayClient.Request
    let clock: () -> Date
    private var cached: CampaignRelayCredentials?
    private var synchronizer: CampaignRelaySync?
    init(db: NativeDatabase, store: CampaignRelayCredentialStore, allowLoopbackHTTP: Bool = false, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.store = store; self.allowLoopbackHTTP = allowLoopbackHTTP; self.request = request; self.clock = clock
    }
    private func current() throws -> (CampaignRelayCredentials,CampaignRelaySync) {
        guard let credentials = try store.load(interactive:false) else { throw CampaignRelayError(message:"キャンペーンの受信窓口を設定してください。",retryable:false) }
        // Revalidate the local binding even when the cached transport is reused.
        let client = try credentials.client(db:db,allowLoopbackHTTP:allowLoopbackHTTP,request:request,clock:clock)
        if cached == credentials, let synchronizer { return (credentials,synchronizer) }
        guard let binding = try CampaignRelayBinding.load(db:db) else { throw NativeDBError.conflict }
        let sync = try CampaignRelaySync(db:db,client:client,binding:binding,clock:clock)
        cached = credentials; synchronizer = sync; return (credentials,sync)
    }
    func synchronize(heartbeat: () throws -> Void) async throws -> Int { try await current().1.synchronize(heartbeat:heartbeat) }
    func prepare(job: NativeJob, configuration: CampaignMailConfiguration) async throws {
        let (credentials,sync) = try current()
        guard try credentials.configuration(allowLoopbackHTTP:allowLoopbackHTTP) == configuration else { throw NativeDBError.conflict }
        try await sync.prepareToSend(sendID:job.id,configuration:configuration,heartbeat:{try self.db.renewJobLease(job,now:self.clock())})
        guard try store.load(interactive:false) == credentials else { throw CampaignRelayError(message:"同期中に受信窓口の設定が変更されました。再試行してください。",retryable:true) }
    }
}

actor CampaignRelaySyncWorker {
    let db: NativeDatabase
    let coordinator: CampaignRelayCoordinator
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, coordinator: CampaignRelayCoordinator, clock: @escaping () -> Date = Date.init) { self.db = db; self.coordinator = coordinator; self.clock = clock }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events:[CampaignRelayJobs.event],now:clock()) else { return false }
        do {
            let generation = try db.transaction { () -> String in
                _ = try db.requireJobLease(job)
                guard let token = try db.metadata(CampaignRelayJobs.generation) else { throw NativeDBError.conflict }; return token
            }
            let applied = try await coordinator.synchronize(heartbeat:{try self.db.renewJobLease(job,now:self.clock())})
            try db.transaction {
                let stamp = try CampaignWorkflow.stamp(clock())
                try db.finishJob(job,result:["applied":String(applied),"syncedAt":stamp],now:clock())
                try db.setMetadata(CampaignRelayJobs.lastSuccess,value:stamp)
                if try db.metadata(CampaignRelayJobs.generation) != generation { _ = try CampaignRelayJobs.request(db:db,now:clock()) }
            }
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            let retryable: Bool
            if error is CancellationError { retryable = true }
            else if let relay = error as? CampaignRelayError { retryable = relay.retryable }
            else if case NativeDBError.conflict = error { retryable = true }
            else { retryable = false }
            let retry = retryable && current.attempts < 8
            let delay = min(300,5*pow(2,Double(min(current.attempts-1,6))))
            try db.failJob(current,message:error is CancellationError ? "同期を中断しました。再開後に再試行します。" : error.localizedDescription,retryAt:retry ? clock().addingTimeInterval(delay) : nil)
        }
        return true
    }
}

/// Runtime dependencies are injectable for isolated QA. No receiver subprocess
/// or idle polling timer is started on the Mac.
struct CampaignRuntime {
    let store: CampaignRelayCredentialStore
    let dispatch: CampaignDispatchWorker
    let mail: CampaignMailWorker
    let sync: CampaignRelaySyncWorker
    private let db: NativeDatabase
    private let readiness: () async throws -> Void
    init(db: NativeDatabase, mailStore: InvoiceMailCredentialStore, mailRequest: @escaping ResendMailClient.Request = ResendMailClient.request, relayStore: CampaignRelayCredentialStore? = nil, allowLoopbackHTTP: Bool = false, relayRequest: @escaping CampaignRelayClient.Request = CampaignRelayClient.network, clock: @escaping () -> Date = Date.init) {
        self.db = db
        let store = relayStore ?? KeychainCampaignRelayCredentials(databaseURL:db.url); self.store = store
        readiness = {
            try Task.checkCancellation()
            guard let mail = try mailStore.load(interactive:false), !mail.apiKey.isEmpty, !mail.apiKey.contains(where:{$0.isWhitespace}) else { throw NativeDBError.message("メール送信の設定で、差出人とAPIキーを登録してください。") }
            _ = try InvoiceMail.mailbox(mail.from)
            guard let settings = try store.load(interactive:false) else { throw NativeDBError.message("キャンペーンの受信窓口を設定してください。") }
            _ = try settings.configuration(allowLoopbackHTTP:allowLoopbackHTTP)
            let client = try settings.client(db:db,allowLoopbackHTTP:allowLoopbackHTTP,request:relayRequest,clock:clock)
            try await client.checkUnsubscribeRoute()
            try Task.checkCancellation()
            guard let latest = try mailStore.load(interactive:false), latest.from == mail.from, latest.apiKey == mail.apiKey,
                  try store.load(interactive:false) == settings else { throw NativeDBError.message("確認中に送信設定が変更されました。もう一度確認してください。") }
            _ = try settings.client(db:db,allowLoopbackHTTP:allowLoopbackHTTP,request:relayRequest,clock:clock)
        }
        let coordinator = CampaignRelayCoordinator(db:db,store:store,allowLoopbackHTTP:allowLoopbackHTTP,request:relayRequest,clock:clock)
        sync = CampaignRelaySyncWorker(db:db,coordinator:coordinator,clock:clock)
        dispatch = CampaignDispatchWorker(db:db,clock:clock)
        mail = CampaignMailWorker(db:db,account:{
            guard let account = try mailStore.load(interactive:false) else { throw NativeDBError.message("メール送信の設定がありません。管理者が差出人とAPIキーを設定してください。") }; return account
        },configuration:{
            guard let settings = try store.load(interactive:false) else { throw NativeDBError.message("キャンペーンの受信窓口を設定してください。") }; return try settings.configuration(allowLoopbackHTTP:allowLoopbackHTTP)
        },endpointReady:{job,config in try await coordinator.prepare(job:job,configuration:config)},request:mailRequest,clock:clock)
    }
    @discardableResult func requestSync(now: Date = Date()) throws -> String? {
        guard try CampaignRelayBinding.load(db:db) != nil, try store.load(interactive:false) != nil else { return nil }
        return try CampaignRelayJobs.request(db:db,now:now)
    }
    /// Does not send mail or register a recipient. The mail worker repeats its
    /// own token/opt-out/credential gates at the actual delivery time.
    func validateForLaunch() async throws { try await readiness() }
}
