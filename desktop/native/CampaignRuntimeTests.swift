import Foundation

enum CampaignRuntimeTests {
    typealias Fixture = CampaignMailTests.Fixture
    static var checks = 0
    final class MailStore: InvoiceMailCredentialStore {
        let value: InvoiceMailAccount
        init(_ value: InvoiceMailAccount) { self.value = value }
        func load(interactive: Bool) throws -> InvoiceMailAccount? { value }
        func save(_ account: InvoiceMailAccount) throws { throw NativeDBError.conflict }
        func remove() throws { throw NativeDBError.conflict }
    }
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL runtime: "+label) }; checks += 1 }
    static func setup(_ f: Fixture,_ server: CampaignRelaySyncTests.Server) async throws -> CampaignRelayCredentialsTests.Store {
        let store = CampaignRelayCredentialsTests.Store()
        try await f.service.saveCampaignRelaySettings(publicURL:server.url.absoluteString,appName:"NextCRM",authKey:CampaignRelaySyncTests.key,store:store,allowLoopbackHTTP:true,clock:{f.now})
        return store
    }
    static func runtime(_ f: Fixture,_ store: CampaignRelayCredentialsTests.Store, db: NativeDatabase? = nil, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network) -> CampaignRuntime {
        CampaignRuntime(db:db ?? f.db,mailStore:MailStore(f.credentials),mailRequest:{r,u in try f.response(r,u)},relayStore:store,allowLoopbackHTTP:true,relayRequest:request,clock:{f.now})
    }
    static func run(_ resources: URL) async throws {
        try await receiptAndWakes(resources)
        try await retryAndPreflight(resources)
        try await leaseAndSettings(resources)
        print("CampaignRuntimeTests: \(checks) checks passed; durable jobs and real loopback receiver, fake outgoing mail")
    }
    static func receiptAndWakes(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }
        let store = try await setup(f,server), rt = runtime(f,store)
        _ = try await rt.mail.runNext()
        try check(try f.job().status == "done" && f.bodies.count == 1,"runtime sends only after actual public route and token registration")
        let receiptJob = try f.db.jobs(events:[CampaignRelayJobs.event])
        try check(receiptJob.count == 1 && receiptJob[0].status == "pending","accepted receipt atomically queues durable sync")
        let id = receiptJob[0].id
        for _ in 0..<10 { guard try rt.requestSync(now:f.now) == id else { throw NativeDBError.conflict } }
        try check(try f.db.jobs(events:[CampaignRelayJobs.event]).count == 1,"pending wake requests coalesce")
        _ = try await rt.sync.runNext()
        try check(try f.db.job(id:id)?.status == "done" && f.db.nextJobDate(events:[CampaignRelayJobs.event],now:f.now) == nil,"idle runtime has no next wake")
        let empty = try await rt.sync.runNext(); try check(!empty,"no work when idle")
        try await server.webhook("email.delivered",provider:f.providerID,id:"msg_runtime_delivered",now:f.now)
        _ = try rt.requestSync(now:f.now); _ = try await rt.sync.runNext()
        try check(try f.send()["status"] == .text("delivered") && f.bodies.count == 1,"new wake imports delivery without another outgoing message")
        // A request arriving after a running sync's generation snapshot must
        // create one followup even when the current page was already fetched.
        var requestedDuringRun = false
        let concurrent = runtime(f,store,request:{ request in
            let response = try await CampaignRelayClient.network(request)
            if request.url!.path.hasSuffix("/events"), !requestedDuringRun {
                requestedDuringRun = true; _ = try CampaignRelayJobs.request(db:f.db,now:f.now)
            }
            return response
        })
        let activeID = try concurrent.requestSync(now:f.now)!
        _ = try await concurrent.sync.runNext()
        let followup = try f.db.metadata(CampaignRelayJobs.pointer)!
        try check(followup != activeID && (try f.db.job(id:activeID)?.status) == "done" && (try f.db.job(id:followup)?.status) == "pending","wake during running pass is not lost")
        _ = try await concurrent.sync.runNext()
        try check(try f.db.job(id:followup)?.status == "done" && f.db.nextJobDate(events:[CampaignRelayJobs.event],now:f.now) == nil,"coalesced followup returns to idle")
    }
    static func retryAndPreflight(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }
        let store = try await setup(f,server)
        let offline = runtime(f,store,request:{_ in throw URLError(.notConnectedToInternet)})
        let id = try offline.requestSync(now:f.now)!
        _ = try await offline.sync.runNext()
        try check(try f.db.job(id:id)?.status == "retry" && f.db.job(id:id)?.attempts == 1,"offline sync retains durable retry")
        try check(try f.db.nextJobDate(events:[CampaignRelayJobs.event],now:f.now) != nil,"failed sync has one scheduled wake")
        let connection = try f.connection(), resumed = runtime(f,store,db:connection)
        f.now = f.now.addingTimeInterval(6); _ = try await resumed.sync.runNext()
        try check(try f.db.job(id:id)?.status == "done" && f.db.job(id:id)?.attempts == 2,"retry resumes on another database connection")
        _ = try await offline.mail.runNext()
        try check(try f.job().status == "retry" && f.job().deliveryStartedAt == nil && f.bodies.isEmpty,"relay network failure retries before any mail request")
        let digest = try f.job().result["sha256"]
        f.now = f.now.addingTimeInterval(6); _ = try await resumed.mail.runNext()
        try check(try f.job().status == "done" && f.job().result["sha256"] == digest && f.bodies.count == 1,"preflight retry reuses same prepared body and send identity")
        let blocked = try await Fixture.make(resources), blockedServer = try CampaignRelaySyncTests.Server(blocked); defer { blockedServer.stop() }
        let blockedStore = try await setup(blocked,blockedServer)
        let proxy = runtime(blocked,blockedStore,request:{ request in
            if request.url!.path.hasSuffix("/api/campaigns/unsubscribe") { return (Data("not found".utf8),HTTPURLResponse(url:request.url!,statusCode:404,httpVersion:nil,headerFields:[:])!) }
            return try await CampaignRelayClient.network(request)
        })
        _ = try await proxy.mail.runNext()
        try check(try blocked.job().status == "failed" && blocked.job().deliveryStartedAt == nil && blocked.bodies.isEmpty,"public path blocked despite working management API prevents delivery")
        try check(try blocked.send()["unsubscribed_at"] == .null,"readiness probe never opts the recipient out")
        let cancelled = runtime(blocked,blockedStore,request:{_ in throw CancellationError()})
        let cancelID = try cancelled.requestSync(now:blocked.now)!
        _ = try await cancelled.sync.runNext()
        try check(try blocked.db.job(id:cancelID)?.status == "retry","cancelled sync remains resumable")
        blocked.now = blocked.now.addingTimeInterval(6)
        _ = try await runtime(blocked,blockedStore).sync.runNext()
        try check(try blocked.db.job(id:cancelID)?.status == "done","cancelled sync completes after restart")
    }
    static func leaseAndSettings(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }
        let store = try await setup(f,server), connection = try f.connection()
        var checkedLease = false
        let delayed = runtime(f,store,request:{ request in
            let response = try await CampaignRelayClient.network(request)
            f.now = f.now.addingTimeInterval(90)
            if request.url!.path.hasSuffix("/events") {
                try check(try connection.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now.addingTimeInterval(40)) == nil,"heartbeat prevents another process reclaiming a long preflight")
                checkedLease = true
            }
            return response
        })
        _ = try await delayed.mail.runNext()
        try check(checkedLease && (try f.job().status) == "done" && f.bodies.count == 1,"multi-request preflight renews lease through delivery")
        let changed = try await Fixture.make(resources), changedServer = try CampaignRelaySyncTests.Server(changed); defer { changedServer.stop() }
        let changedStore = try await setup(changed,changedServer)
        let editing = runtime(changed,changedStore,request:{ request in
            let response = try await CampaignRelayClient.network(request)
            if request.url!.path.hasSuffix("/events"), let old = changedStore.value {
                changedStore.value = .init(publicURL:old.publicURL,appName:"変更済み",clientID:old.clientID,instanceID:old.instanceID,authKey:old.authKey)
            }
            return response
        })
        _ = try await editing.mail.runNext()
        try check(try changed.job().status == "retry" && changed.job().deliveryStartedAt == nil && changed.bodies.isEmpty,"settings changed during awaited preflight block delivery")
        let unopened = try await Fixture.make(resources), noSettings = runtime(unopened,CampaignRelayCredentialsTests.Store())
        try check(try noSettings.requestSync(now:unopened.now) == nil && unopened.db.jobs(events:[CampaignRelayJobs.event]).isEmpty,"unused campaign feature creates no background sync jobs")
    }
}
