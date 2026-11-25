import Foundation

enum CampaignOperationsTests {
    typealias Fixture = CampaignMailTests.Fixture
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("CampaignOperations FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () async throws -> Void) async throws { do { try await body() } catch { checks += 1; return }; throw NativeDBError.message("CampaignOperations accepted: "+label) }
    static func run(_ resources: URL) async throws {
        try await launch(resources); try await readiness(resources); try await dispatch(resources); try await synchronization(resources)
        print("CampaignOperationsTests: \(checks) checks passed; launch/readiness/current gates, dispatch controls, sync and retired-observation retention; no external mail")
    }
    static func launch(_ resources: URL) async throws {
        for action in CampaignLaunchAction.allCases {
            let f = try await Fixture.make(resources)
            try f.change(f.campaign,["status":.text(action == .resume ? "paused" : "draft")])
            let expected = try f.fresh(f.campaign), before = try f.db.campaignJobCount(expected["id"].string,events:CampaignWorkflow.dispatchEvents)
            let summary = try f.service.campaignLaunchSummary(expected,action:action)
            try check(summary.candidates == 1 && summary.steps == 1,"bounded launch summary")
            var validated = 0
            let due = f.now.addingTimeInterval(3600), result = try await f.service.launchCampaign(expected,action:action,at:due,readiness:{validated += 1},now:{f.now})
            try check(validated == 1 && f.bodies.isEmpty,"launch validates configuration without outgoing mail")
            try check(result["status"] == .text(action == .schedule ? "scheduled" : "sending") && (try f.db.campaignJobCount(expected["id"].string,events:CampaignWorkflow.dispatchEvents)) == before+1,"one atomic dispatch command")
            if action == .schedule { try check(result["scheduled_at"] == .text(try CampaignWorkflow.stamp(due)),"requested scheduled instant retained") }
            try await tryRejectStale(f,expected,action)
        }
        for gate in ["permission","revision","date","failure","cancel"] {
            let f = try await Fixture.make(resources); try f.change(f.campaign,["status":.text("draft")]); let expected = try f.fresh(f.campaign)
            let before = try f.db.campaignJobCount(expected["id"].string,events:CampaignWorkflow.dispatchEvents)
            try await tryRejectGate(f,expected,gate)
            try check(try f.db.campaignJobCount(expected["id"].string,events:CampaignWorkflow.dispatchEvents) == before && f.bodies.isEmpty,"awaited gate creates no dispatch: "+gate)
        }
    }
    static func tryRejectStale(_ f: Fixture,_ expected: NativeRecord,_ action: CampaignLaunchAction) async throws {
        try await rejects("stale launch"){_ = try await f.service.launchCampaign(expected,action:action,at:f.now.addingTimeInterval(3600),readiness:{},now:{f.now})}
    }
    static func tryRejectGate(_ f: Fixture,_ expected: NativeRecord,_ gate: String) async throws {
        try await rejects("launch gate "+gate) {
            _ = try await f.service.launchCampaign(expected,action:.schedule,at:f.now.addingTimeInterval(30),readiness:{
                switch gate {
                case "permission":let user = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!; try f.change(user,["banned":.integer(1)])
                case "revision":try f.change(expected,["name":.text("変更後")])
                case "date":f.now.addTimeInterval(60)
                case "failure":throw CampaignRelayError(message:"接続不可",retryable:true)
                case "cancel":throw CancellationError()
                default:break
                }
            },now:{f.now})
        }
    }
    final class MailStore: InvoiceMailCredentialStore {
        var value: InvoiceMailAccount?; init(_ value: InvoiceMailAccount?) { self.value = value }
        func load(interactive: Bool) throws -> InvoiceMailAccount? { value }
        func save(_ value: InvoiceMailAccount) throws { self.value = value }
        func remove() throws { value = nil }
    }
    static func readiness(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }
        let store = try await CampaignRuntimeTests.setup(f,server), mail = MailStore(f.credentials)
        let rt = CampaignRuntime(db:f.db,mailStore:mail,mailRequest:{r,u in try f.response(r,u)},relayStore:store,allowLoopbackHTTP:true,clock:{f.now})
        try await rt.validateForLaunch()
        try check(f.bodies.isEmpty && (try f.job().deliveryStartedAt) == nil && f.job().result.isEmpty,"readiness neither prepares nor sends a recipient")
        mail.value = nil; try await rejects("missing mail settings"){try await rt.validateForLaunch()}; mail.value = f.credentials
        let blocked = CampaignRuntime(db:f.db,mailStore:mail,relayStore:store,allowLoopbackHTTP:true,relayRequest:{ request in (Data(),HTTPURLResponse(url:request.url!,statusCode:404,httpVersion:nil,headerFields:nil)!) },clock:{f.now})
        try await rejects("actual public route unavailable"){try await blocked.validateForLaunch()}
        let changed = CampaignRuntime(db:f.db,mailStore:mail,relayStore:store,allowLoopbackHTTP:true,relayRequest:{ request in let response = try await CampaignRelayClient.network(request); mail.value = .init(from:"changed@example.invalid",apiKey:"changed"); return response },clock:{f.now})
        try await rejects("mail settings changed during probe"){try await changed.validateForLaunch()}
        try check(f.bodies.isEmpty,"readiness failures never use provider transport")
    }
    static func dispatch(_ resources: URL) async throws {
        let f = try Fixture(resources), job = try f.db.claimJob(events:CampaignWorkflow.dispatchEvents,now:f.now)!
        let dispatcher = CampaignDispatchWorker(db:f.db,clock:{f.now})
        _ = try await dispatcher.advance(job); _ = try await dispatcher.advance(job)
        f.sendID = try f.db.page("crm_campaign_sends",fields:[]).rows[0]["id"].string
        let current = try f.db.requireJobLease(job), token = try f.db.metadata(CampaignWorkflow.runKey(f.campaign["id"].string))
        try await rejects("cannot cancel running fanout"){try f.service.cancelCampaignDispatchJobAndPause(current)}
        try check(try f.fresh(f.campaign)["status"] == .text("sending") && f.db.metadata(CampaignWorkflow.runKey(f.campaign["id"].string)) == token,"running cancel leaves state unchanged")
        try f.db.failJob(current,message:"interrupted",retryAt:f.now.addingTimeInterval(20))
        let retry = try f.db.job(id:job.id)!, cursor = retry.result["cursor"]
        try f.service.retryCampaignDispatchJob(retry,now:f.now)
        let pending = try f.db.job(id:job.id)!
        try check(pending.status == "pending" && pending.result["cursor"] == cursor,"manual dispatch retry preserves checkpoint")
        try await rejects("stale retry row"){try f.service.retryCampaignDispatchJob(retry,now:f.now)}
        try f.service.cancelCampaignDispatchJobAndPause(pending)
        try check(try f.db.job(id:job.id)?.status == "cancelled" && f.fresh(f.campaign)["status"] == .text("paused") && f.db.metadata(CampaignWorkflow.runKey(f.campaign["id"].string)) != token,"cancel fanout pauses all old generation work")
        _ = try await f.worker().runNext()
        try check(f.bodies.isEmpty && (try f.job().result["outcome"]) == "skipped","already-materialized recipient cannot send after cancellation")
        try await rejects("superseded fanout retry"){try f.service.retryCampaignDispatchJob(f.db.job(id:job.id)!,now:f.now)}
        _ = try f.service.resumeCampaign(f.fresh(f.campaign),now:f.now); _ = try await dispatcher.runNext(); _ = try await f.worker().runNext()
        try check(f.bodies.count == 1 && (try f.db.page("crm_campaign_sends",fields:[]).total) == 1,"explicit resume reuses recipient identity")
        let follow = try f.db.enqueue(CampaignWorkflow.followUpEvent,payload:["campaignId":f.campaign["id"].string,"actorId":f.service.identity.id,"runToken":f.db.metadata(CampaignWorkflow.runKey(f.campaign["id"].string))!],now:f.now,runAt:f.now.addingTimeInterval(86400))
        try f.service.cancelCampaignDispatchJobAndPause(f.db.job(id:follow)!)
        try check(try f.fresh(f.campaign)["status"] == .text("paused"),"pending followup can stop campaign after initial completion")
        let before = try f.service.campaignDispatchJobs(f.campaign["id"].string).total
        try f.db.transaction { for _ in 0..<204 { try f.db.enqueue(CampaignWorkflow.followUpEvent,payload:["campaignId":f.campaign["id"].string],now:f.now) } }
        let pages = try [0,100,200].map{try f.service.campaignDispatchJobs(f.campaign["id"].string,offset:$0)}
        try check(pages.map{$0.rows.count} == [100,100,before+4] && pages.allSatisfy{$0.total == before+204},"dispatch SQL pages exclude per-recipient mail jobs")
        try f.sql("DROP INDEX native_outbox_campaign")
        let reopened = try f.connection()
        try check(try reopened.campaignJobCount(f.campaign["id"].string,events:CampaignWorkflow.dispatchEvents) == before+204,"index migration preserves existing outbox")
    }
    static func synchronization(_ resources: URL) async throws {
        let f = try await Fixture.make(resources)
        try await rejects("unconfigured explicit sync"){try f.service.synchronizeCampaignResults(f.campaign["id"].string,now:f.now)}
        let server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }; let store = try await CampaignRuntimeTests.setup(f,server), rt = CampaignRuntimeTests.runtime(f,store)
        try f.service.synchronizeCampaignResults(f.campaign["id"].string,now:f.now)
        let pending = try f.service.campaignSynchronizationStatus(f.campaign["id"].string)
        try check(pending.configured && pending.latest?.status == "pending" && pending.lastSuccess == nil,"explicit sync has visible pending status")
        _ = try await rt.sync.runNext()
        let done = try f.service.campaignSynchronizationStatus(f.campaign["id"].string)
        try check(done.latest?.status == "done" && done.lastSuccess == (try CampaignWorkflow.stamp(f.now)),"successful sync persists last success separately")
        let provider = UUID().uuidString.lowercased(), instance = try CampaignRelayBinding.load(db:f.db)!.instanceID
        _ = try await f.worker(ready:{_ in throw CampaignRelayReceiptConflict(sendID:f.sendID,providerID:provider,instanceID:instance)}).runNext()
        try await rejects("unreviewed remote hint cannot retire an observation"){_ = try f.db.receiveCampaignEvent(id:"not-reviewed",providerID:provider,kind:"email.delivered",bodySHA256:String(repeating:"a",count:64),now:f.now,retiredSendID:f.sendID)}
        try f.service.reviewCampaignMailJob(f.job(),outcome:.unknown,providerID:"",note:"確認できず終了",now:f.now)
        try f.sql("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO native_campaign_events(event_id,provider_id,kind,body_sha256,received_at) SELECT 'pending_'||x,'unmatched','email.delivered','"+String(repeating:"a",count:64)+"','2026-11-14T10:00:00Z' FROM n")
        let outcome = try f.db.receiveCampaignEvent(id:"retired-result",providerID:provider,kind:"email.delivered",bodySHA256:String(repeating:"b",count:64),now:f.now,retiredSendID:f.sendID)
        try check(outcome == "retired" && (try f.send()["resend_message_id"]) == .null && f.bodies.isEmpty,"retired signed hint bypasses full pending inbox without adopting receipt")
        try check(try CampaignEventTests.scalar(f,"SELECT count(*) FROM native_campaign_events WHERE processed_at IS NULL") == "10000","retired result does not consume pending capacity")
        let duplicate = try f.db.receiveCampaignEvent(id:"retired-result",providerID:provider,kind:"email.delivered",bodySHA256:String(repeating:"b",count:64),now:f.now,retiredSendID:f.sendID)
        try check(duplicate == "retired","retired duplicate is idempotent")
        try await rejects("retirement cannot override a different provider"){_ = try f.db.receiveCampaignEvent(id:"wrong",providerID:UUID().uuidString.lowercased(),kind:"email.delivered",bodySHA256:String(repeating:"b",count:64),now:f.now,retiredSendID:f.sendID)}
    }
}
