import Foundation
import SQLite3

@main enum CampaignDispatchTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    final class Fixture {
        let root: URL; let resources: URL; let db: NativeDatabase; let service: CRMService; let template: NativeRecord
        var now = CampaignWorkflow.date(.text("2026-11-14T10:00:00.125Z"))!
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignDispatch-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            template = try service.saveCampaignTemplate(nil,input:["name":.text("案内"),"subject_default":.text("件名"),"content_html":.text("<p>日本語</p>")])
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        func connection() throws -> NativeDatabase { try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        func fresh(_ r: NativeRecord) throws -> NativeRecord { try db.get(r.model,key:db.key(for:r))! }
        func target(_ email: String, stop: Bool = false) throws -> NativeRecord { try db.insert("crm_Targets",values:["last_name":.text("検証"),"email":.text(email),"do_not_email":.integer(stop ? 1 : 0),"created_by":.text(service.identity.id)],actor:service.identity.id) }
        func campaign(_ emails: [String], followup: Bool = true) throws -> NativeRecord {
            try db.transaction {
                let list = try db.insert("crm_TargetLists",values:["name":.text("配信対象"),"created_by":.text(service.identity.id)],actor:service.identity.id)
                for email in emails { let t = try target(email,stop:email.hasPrefix("stop@")); _ = try db.insert("TargetsToTargetLists",values:["target_id":t["id"],"target_list_id":list["id"]],actor:service.identity.id) }
                var steps = [CampaignStepInput(order:0,templateID:template["id"].string,subject:"初回")]
                if followup { steps.append(CampaignStepInput(order:1,templateID:template["id"].string,subject:"追伸",delayDays:7)) }
                return try service.createCampaign(input:["name":.text("配信検証")],targetListIDs:[list["id"].string],steps:steps)
            }
        }
        func send(_ campaign: NativeRecord, step: NativeRecord, target: NativeRecord, status: String, opened: Bool = false, unsubscribed: Bool = false) throws -> NativeRecord {
            try db.insert("crm_campaign_sends",values:["campaign_id":campaign["id"],"step_id":step["id"],"target_id":target["id"],"email":target["email"],"status":.text(status),"opened_at":opened ? .text(try CampaignWorkflow.stamp(now)) : .null,"unsubscribed_at":unsubscribed ? .text(try CampaignWorkflow.stamp(now)) : .null],actor:service.identity.id)
        }
        func runToken(_ campaign: NativeRecord) throws -> String { let token = UUID().uuidString.lowercased(); try db.setMetadata(CampaignWorkflow.runKey(campaign["id"].string),value:token); return token }
        func worker(_ connection: NativeDatabase? = nil) -> CampaignDispatchWorker { CampaignDispatchWorker(db:connection ?? db,clock:{[self] in now}) }
        func sql(_ text: String) throws -> Int {
            var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(c) }
            var statement: OpaquePointer?; guard sqlite3_prepare_v2(c,text,-1,&statement,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }; defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement); guard result == SQLITE_ROW || result == SQLITE_DONE else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }; return result == SQLITE_ROW ? Int(sqlite3_column_int64(statement,0)) : 0
        }
    }
    struct Reference: Decodable {
        struct Dispatch: Decodable { let mode: String; let status: String; let resultStatus: String; let skipped: Bool; let emails: [String]; let followups: [String]; let delaySeconds: Double? }
        struct Followup: Decodable { let mode: String; let status: String; let suppressed: Bool; let unsubscribed: Bool; let emails: [String] }
        struct Completion: Decodable { let status: String; let suppressed: Bool; let unsubscribed: Bool; let resultStatus: String }
        let dispatch: [Dispatch]; let emptyStatus: String; let followups: [Followup]; let completion: [Completion]
    }
    struct Actions: Decodable {
        struct State: Decodable { let action: String; let role: String; let status: String; let allowed: Bool; let resultStatus: String; let scheduledAtSet: Bool }
        let states: [State]
    }
    static func main() async { do { try await run() } catch { FileHandle.standardError.write(Data("CampaignDispatchTests: \(error)\n".utf8)); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), reference = try JSONDecoder().decode(Reference.self,from:Data(contentsOf:resources.appendingPathComponent("build/campaign-dispatch-reference.json")))
        for row in reference.dispatch {
            let f = try Fixture(resources); var c = try f.campaign(["one@example.invalid","one@example.invalid","two@example.invalid","stop@example.invalid",""])
            c = try row.mode == "now" ? f.service.sendCampaignNow(c,now:f.now) : f.service.scheduleCampaign(c,at:f.now,now:f.now)
            if row.status == "paused" { c = try f.service.pauseCampaign(c) }
            if row.status == "deleted" { c = try f.db.update(c,changes:["status":.text("deleted")],actor:f.service.identity.id) }
            f.now.addTimeInterval(row.delaySeconds ?? 0)
            let processed = try await f.worker().runNext(); try check(processed,"source dispatch ran")
            let sends = try f.db.page("crm_campaign_sends",fields:["email"],equal:["campaign_id":c["id"]]).rows.map{$0["email"].string}.sorted()
            try check(sends == row.emails && f.fresh(c)["status"].string == row.resultStatus,"source dispatch/status")
            let followups = try f.db.jobs(events:[CampaignWorkflow.followUpEvent]).compactMap{$0.payload["scheduledAt"]}.sorted()
            try check(followups == row.followups,"source followup scheduling base")
            let job = try f.db.jobs(events:[row.mode == "now" ? CampaignWorkflow.sendEvent : CampaignWorkflow.scheduleEvent])[0]
            try check(job.status == "done" && (job.result["outcome"] == "skipped") == row.skipped,"source skipped run")
            for send in try f.db.page("crm_campaign_sends",fields:["id"]).rows { let mail = try f.db.job(id:send["id"].string); try check(mail?.payload["sendId"] == send["id"].string,"permanent per-send outbox identity") }
        }
        do {
            let f = try Fixture(resources), c = try f.service.sendCampaignNow(f.campaign([],followup:false),now:f.now)
            _ = try await f.worker().runNext(); try check(try f.fresh(c)["status"].string == reference.emptyStatus,"source empty campaign completes")
        }
        for row in reference.followups {
            let f = try Fixture(resources); var c = try f.campaign([]); c = try f.db.update(c,changes:["status":.text("sent")],actor:f.service.identity.id)
            let steps = try f.service.campaignSteps(c["id"].string).rows
            _ = try f.db.update(steps[1],changes:["send_to":.text(row.mode)],actor:f.service.identity.id)
            _ = try f.send(c,step:steps[0],target:f.target("one@example.invalid",stop:row.suppressed),status:row.status,unsubscribed:row.unsubscribed)
            _ = try f.send(c,step:steps[0],target:f.target("two@example.invalid"),status:row.status,opened:true)
            let token = try f.runToken(c)
            try f.db.enqueue(CampaignWorkflow.followUpEvent,payload:["campaignId":c["id"].string,"stepId":steps[1]["id"].string,"actorId":f.service.identity.id,"runToken":token,"scheduledAt":try CampaignWorkflow.stamp(f.now)],now:f.now,runAt:f.now)
            _ = try await f.worker().runNext()
            let emails = try f.db.page("crm_campaign_sends",fields:["email"],equal:["step_id":steps[1]["id"]]).rows.map{$0["email"].string}.sorted()
            try check(emails == row.emails,"actual source followup handler recipients")
        }
        for row in reference.completion {
            let f = try Fixture(resources); var c = try f.campaign([],followup:false); c = try f.db.update(c,changes:["status":.text("sending")],actor:f.service.identity.id)
            let step = try f.service.campaignSteps(c["id"].string).rows[0], token = try f.runToken(c)
            try f.db.setMetadata(CampaignWorkflow.dispatchDoneKey(c["id"].string),value:token)
            _ = try f.send(c,step:step,target:f.target("one@example.invalid",stop:row.suppressed),status:row.status,unsubscribed:row.unsubscribed)
            try CampaignDispatch.finishInitialIfReady(db:f.db,campaignID:c["id"].string,actorID:f.service.identity.id,now:f.now)
            try check(try f.fresh(c)["status"].string == row.resultStatus,"actual source step0 completion predicate")
        }
        try await recovery(resources)
        try await transitions(resources)
        try actionStates(resources)
        try mailRearming(resources)
        print("CampaignDispatchTests: \(checks) checks passed; local dispatch only, no transport")
    }
    static func actionStates(_ resources: URL) throws {
        let source = try JSONDecoder().decode(Actions.self,from:Data(contentsOf:resources.appendingPathComponent("build/campaigns-reference.json")))
        for row in source.states where row.action == "send" {
            let f = try Fixture(resources); var campaign = try f.campaign([]); var service = f.service
            if row.role == "user" {
                let user = try f.db.insert("Users",values:["name":.text("一般利用者"),"email":.text("user@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:f.service.identity.id)
                campaign = try f.db.update(campaign,changes:["created_by":user["id"]],actor:f.service.identity.id)
                service = CRMService(db:f.db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil))
            }
            campaign = try f.db.update(campaign,changes:["status":.text(row.status)],actor:f.service.identity.id)
            let result = Result { try service.sendCampaignNow(campaign,now:f.now) }
            try check(((try? result.get()) != nil) == row.allowed,"actual source send-now role/state")
            try check(try f.fresh(campaign)["status"].string == row.resultStatus,"actual source send-now transition")
            let updated = try f.fresh(campaign)
            try check((updated["scheduled_at"] != .null) == row.scheduledAtSet,"actual source send-now sets scheduled_at")
            if row.allowed { try check(CampaignWorkflow.date(updated["scheduled_at"]) == f.now,"send-now records command time") }
        }
    }
    static func mailRearming(_ resources: URL) throws {
        let f = try Fixture(resources), campaign = try f.campaign([],followup:false), step = try f.service.campaignSteps(campaign["id"].string).rows[0], token = try f.runToken(campaign)
        let send = try f.send(campaign,step:step,target:f.target("one@example.invalid"),status:"queued")
        try f.db.queueCampaignSend(send,token:token,actorID:f.service.identity.id,now:f.now)
        let claim = try f.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)!
        try f.db.recordJobResult(claim,result:["sha256":"frozen-body-hash","bytes":"123"])
        let marked = try f.db.markJobDeliveryStarted(claim,now:f.now)
        try f.db.failJob(marked,message:"temporary failure")
        f.now.addTimeInterval(60)
        try f.db.queueCampaignSend(send,token:token,actorID:f.service.identity.id,now:f.now)
        var queued = try f.db.job(id:send["id"].string)!
        try check(queued.status == "pending" && queued.result["sha256"] == "frozen-body-hash" && queued.deliveryStartedAt == marked.deliveryStartedAt,"rearm preserves frozen payload and dedupe epoch")
        let retry = try f.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)!
        try f.db.recordJobResult(retry,result:retry.result.merging(["providerID":UUID().uuidString]){_,v in v}); try f.db.failJob(retry,message:"receipt persisted, local transition interrupted")
        f.now.addTimeInterval(24*3600); try f.db.queueCampaignSend(send,token:token,actorID:f.service.identity.id,now:f.now)
        queued = try f.db.job(id:send["id"].string)!
        try check(queued.status == "pending" && queued.result["providerID"] != nil,"known acceptance can recover after23hours")
        let accepted = try f.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)!
        try f.db.finishJob(accepted,result:accepted.result.merging(["outcome":"sent"]){_,v in v},now:f.now)
        try f.db.queueCampaignSend(send,token:token,actorID:f.service.identity.id,now:f.now)
        try check(try f.db.job(id:send["id"].string)!.status == "done","completed delivery is never rearmed")
        let reviewSend = try f.send(campaign,step:step,target:f.target("review@example.invalid"),status:"failed")
        try f.db.queueCampaignSend(reviewSend,token:token,actorID:f.service.identity.id,now:f.now)
        let review = try f.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)!
        try f.db.failJob(review,message:"ambiguous",needsReview:true)
        try f.db.queueCampaignSend(reviewSend,token:token,actorID:f.service.identity.id,now:f.now)
        try check(try f.db.job(id:review.id)!.status == "needs_review","resume never bypasses required review")
        let oldTarget = try f.db.get("crm_Targets",key:["id":send["target_id"]])!
        _ = try f.db.update(oldTarget,changes:["email":.text("new-shared@example.invalid")],actor:f.service.identity.id)
        let newTarget = try f.db.insert("crm_Targets",values:["id":.text("ffffffff-ffff-4fff-bfff-ffffffffffff"),"last_name":.text("新しい対象"),"email":.text("new-shared@example.invalid")],actor:f.service.identity.id)
        let list = try f.service.campaignTargetLists(campaign["id"].string).rows[0]
        for target in [oldTarget,newTarget] { _ = try f.db.insert("TargetsToTargetLists",values:["target_id":target["id"],"target_list_id":list["id"]],actor:f.service.identity.id) }
        let snapshotJob = try f.db.enqueue(CampaignWorkflow.sendEvent,payload:[:],now:f.now)
        let count = try f.db.stageCampaignAudience(jobID:snapshotJob,campaignID:campaign["id"].string,stepID:step["id"].string,initial:true,sendTo:"all")
        try check(count == 3,"existing send keeps original address without hiding another eligible target")
        try check(try f.db.campaignDispatchRecipients(jobID:snapshotJob,after:"").contains{$0.targetID == newTarget["id"].string && $0.email == "new-shared@example.invalid"},"new target survives resumed cohort deduplication")
    }
    static func recovery(_ resources: URL) async throws {
        let f = try Fixture(resources), c = try f.service.sendCampaignNow(f.campaign((0..<205).map{"recipient\($0)@example.invalid"}),now:f.now), worker = f.worker()
        let job = try f.db.claimJob(events:CampaignWorkflow.dispatchEvents,now:f.now)!
        _ = try await worker.advance(job)
        try check(try f.db.campaignDispatchRecipients(jobID:job.id,after:"").count == 100,"cohort reader bounded at100")
        _ = try await worker.advance(job)
        try check(try f.db.page("crm_campaign_sends",fields:[]).total == 100,"one durable batch")
        let cursor = try f.db.job(id:job.id)!.result["cursor"]!
        try check(!cursor.isEmpty && f.db.job(id:job.id)!.result["materialized"] == "100","cursor commits with sends")
        try CampaignDispatch.finishInitialIfReady(db:f.db,campaignID:c["id"].string,actorID:f.service.identity.id,now:f.now)
        try check(try f.fresh(c)["status"] == .text("sending"),"cannot finish between fanout batches")
        let remaining = try f.db.campaignDispatchRecipients(jobID:job.id,after:cursor)[0]
        let changed = try f.db.get("crm_Targets",key:["id":.text(remaining.targetID)])!
        _ = try f.db.update(changed,changes:["email":.text("changed@example.invalid")],actor:f.service.identity.id)
        f.now.addTimeInterval(301); let second = try f.connection(), restarted = f.worker(second)
        try check(try second.claimJob(events:[],now:f.now) == nil,"empty event claim")
        _ = try await restarted.runNext()
        try check(try f.db.page("crm_campaign_sends",fields:[]).total == 205,"restart resumes remaining105")
        try check(try f.sql("SELECT COUNT(*) FROM native_outbox WHERE event='campaigns/send-step'") == 205,"no duplicate send jobs")
        try check(try f.sql("SELECT COUNT(*) FROM native_campaign_audience") == 0,"cohort released after durable completion")
        let record = try f.db.page("crm_campaign_sends",fields:["email"],equal:["target_id":changed["id"]]).rows[0]
        try check(record["email"] == .text(remaining.email),"staged address survives source mutation")
        let due = try f.db.jobs(events:[CampaignWorkflow.followUpEvent])[0]
        try check(due.nextRunAt == "2026-11-21T10:05:01.125Z","send-now followups begin from completed initial fanout")
        do { _ = try await worker.advance(job); throw NativeDBError.message("FAIL stale lease accepted") } catch NativeDBError.conflict { checks += 1 }
        try check(try f.db.integrityCheck(),"recovery FK/integrity")
        // Failure on the third child outbox insert must roll the entire batch back.
        let g = try Fixture(resources), c2 = try g.service.sendCampaignNow(g.campaign((0..<5).map{"rollback\($0)@example.invalid"},followup:false),now:g.now), w = g.worker()
        let j = try g.db.claimJob(events:CampaignWorkflow.dispatchEvents,now:g.now)!
        _ = try await w.advance(j)
        _ = try g.sql("CREATE TRIGGER fail_fanout BEFORE INSERT ON native_outbox WHEN NEW.event='campaigns/send-step' AND (SELECT COUNT(*) FROM crm_campaign_sends)>=3 BEGIN SELECT RAISE(ABORT,'injected'); END")
        do { _ = try await w.advance(j); throw NativeDBError.message("FAIL rollback injection did not fail") } catch { guard !error.localizedDescription.contains("FAIL") else { throw error }; checks += 1 }
        try check(try g.db.page("crm_campaign_sends",fields:[]).total == 0 && g.db.job(id:j.id)!.result["cursor"] == "","batch rollback includes cursor and sends")
        try check(try g.sql("SELECT COUNT(*) FROM native_campaign_mail_intents") == 0,"batch rollback includes intents")
        _ = try g.sql("DROP TRIGGER fail_fanout")
        while try await !w.advance(j) {}
        try check(try g.db.page("crm_campaign_sends",fields:[]).total == 5 && g.fresh(c2)["status"] == .text("sending"),"retry completes fanout, not unsent mail")
    }
    static func transitions(_ resources: URL) async throws {
        let f = try Fixture(resources), start = f.now
        var c = try f.service.scheduleCampaign(f.campaign(["one@example.invalid"]),at:start.addingTimeInterval(3600),now:start)
        let worker = f.worker(); let early = try await worker.runNext(); try check(!early,"scheduled run does not start early")
        c = try f.service.scheduleCampaign(c,at:start.addingTimeInterval(7200),now:start)
        f.now = start.addingTimeInterval(3600); _ = try await worker.runNext()
        try check(try f.db.page("crm_campaign_sends",fields:[]).total == 0,"superseded reservation cannot fanout")
        f.now = start.addingTimeInterval(7300); _ = try await worker.runNext()
        try check(try f.db.page("crm_campaign_sends",fields:[]).total == 1,"late scheduled wake dispatches once")
        let followup = try f.db.jobs(events:[CampaignWorkflow.followUpEvent])[0]
        try check(followup.nextRunAt == "2026-11-21T12:00:00.125Z","scheduled followup anchored to requested time")
        let send = try f.db.page("crm_campaign_sends",fields:["id","campaign_id","status"]).rows[0]
        let mail = try f.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)!
        _ = try f.db.markJobDeliveryStarted(mail,now:f.now); try f.db.failJob(mail,message:"simulated unknown acceptance")
        c = try f.service.pauseCampaign(f.fresh(c)); let oldToken = try f.db.metadata(CampaignWorkflow.runKey(c["id"].string))
        f.now.addTimeInterval(24*3600); c = try f.service.resumeCampaign(c,now:f.now); _ = try await worker.runNext()
        try check(try f.db.page("crm_campaign_sends",fields:[]).total == 1,"resume preserves send row")
        let retried = try f.db.job(id:send["id"].string)!
        try check(retried.status == "needs_review" && retried.deliveryStartedAt == mail.firstAttemptAt,"expired ambiguous send stays for review")
        try check(try f.db.campaignMailIntent(sendID:send["id"].string)?.token != oldToken,"resume updates intent generation")
        try rejects("stale campaign revision") { _ = try f.service.resumeCampaign(c,now:f.now) }
        // Revocation between snapshot and fanout prevents any delivery commands.
        let g = try Fixture(resources), restricted = try g.service.sendCampaignNow(g.campaign(["one@example.invalid"]),now:g.now), w = g.worker()
        let j = try g.db.claimJob(events:CampaignWorkflow.dispatchEvents,now:g.now)!; _ = try await w.advance(j)
        let actor = try g.db.get("Users",key:["id":.text(g.service.identity.id)])!; _ = try g.db.update(actor,changes:["banned":.integer(1)],actor:g.service.identity.id)
        g.now.addTimeInterval(301); _ = try await w.runNext()
        try check(try g.db.page("crm_campaign_sends",fields:[]).total == 0 && g.db.job(id:j.id)!.result["outcome"] == "skipped","revoked actor cannot fanout")
        try check(try g.fresh(restricted)["status"] == .text("sending"),"revocation does not falsely mark sent")
        // Pause while a batch is live; resume creates no duplicate sends or leases.
        let h = try Fixture(resources); var paused = try h.service.sendCampaignNow(h.campaign((0..<102).map{"pause\($0)@example.invalid"},followup:false),now:h.now)
        let hw = h.worker(), hj = try h.db.claimJob(events:CampaignWorkflow.dispatchEvents,now:h.now)!
        _ = try await hw.advance(hj); _ = try await hw.advance(hj)
        let inFlight = try h.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:h.now)!
        paused = try h.service.pauseCampaign(h.fresh(paused)); h.now.addTimeInterval(301); _ = try await hw.runNext()
        try check(try h.db.page("crm_campaign_sends",fields:[]).total == 100,"pause stops remaining batch")
        paused = try h.service.resumeCampaign(paused,now:h.now); _ = try await hw.runNext()
        try check(try h.db.page("crm_campaign_sends",fields:[]).total == 102,"resume materializes remainder without duplicates")
        try check(try h.db.job(id:inFlight.id)!.leaseToken == inFlight.leaseToken,"resume does not reset in-flight lease")
        try check(try h.db.integrityCheck(),"transition integrity")
    }
}
