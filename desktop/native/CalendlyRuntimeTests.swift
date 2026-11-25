import Foundation

@main enum CalendlyRuntimeTests {
    typealias Tests = CalendlySubscriptionTests
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("CalendlyRuntime FAIL: "+label) }; checks += 1 }
    static func fixture(_ resources: URL) async throws -> Tests.Fixture { let f = try Tests.Fixture(resources); try await f.save(key:"native-calendly-fixture-key"); return f }
    static func worker(_ f: Tests.Fixture,request: @escaping CalendlyRelayClient.Request = CalendlyRelayClient.network,clock: @escaping () -> Date = Date.init) -> CalendlyJobWorker { .init(db:f.db,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:request,clock:clock) }
    static func subscribe(_ f: Tests.Fixture) async throws {
        let m = f.manager(); try await m.begin(.subscribe); let id = try f.service.requestCalendlyJob(CalendlyJobs.subscription)
        let same = try f.service.requestCalendlyJob(CalendlyJobs.subscription); try check(id == same,"subscription requests coalesce into one durable job")
        let w = worker(f); let ran = try await w.runNext(); try check(try ran && f.db.job(id:id)?.status == "done" && f.state().registration?.actorID == f.service.identity.id,"subscription persists authorized owner and completes durable job")
        let sync = try CalendlyJobs.last(db:f.db,event:CalendlyJobs.sync)!
        try check(sync.status == "pending","subscription completion atomically queues initial import")
        _ = try await w.runNext(); try check(try f.db.job(id:sync.id)?.status == "done","initial import finishes through production worker")
    }
    static func jobs(_ resources: URL) async throws {
        let f = try await fixture(resources); try await subscribe(f)
        _ = try f.server.command(["action":"seed","count":205]); let id = try f.service.requestCalendlyJob(CalendlyJobs.sync)
        var again = false
        let w = worker(f,request:{req in
            let response = try await CalendlyRelayClient.network(req)
            if !again { again = true; _ = try f.service.requestCalendlyJob(CalendlyJobs.sync) }; return response
        })
        _ = try await w.runNext(); let followup = try CalendlyJobs.last(db:f.db,event:CalendlyJobs.sync)!
        try check(try f.db.job(id:id)?.status == "done" && f.db.page("crm_Activities",fields:[]).total == 205 && followup.id != id && followup.status == "pending","wake during multipage import queues exactly one durable followup")
        _ = try await w.runNext(); try check(try f.db.job(id:followup.id)?.status == "done" && f.db.page("crm_Activities",fields:[]).total == 205,"coalesced followup does not duplicate activities")
        let retryID = try f.service.requestCalendlyJob(CalendlyJobs.sync)
        _ = try await worker(f,request:{_ in throw URLError(.networkConnectionLost)}).runNext()
        try check(try f.db.job(id:retryID)?.status == "retry","network failure persists retry deadline")
        _ = try f.service.requestCalendlyJob(CalendlyJobs.sync); _ = try await worker(f).runNext()
        try check(try f.db.job(id:retryID)?.status == "done" && f.db.job(id:retryID)?.attempts == 2,"manual retry preserves job identity and attempt history")
        let oldID = try f.service.requestCalendlyJob(CalendlyJobs.sync); try f.service.replaceCalendlyAPIToken("fixture-api-token",store:f.store); let newID = try f.service.requestCalendlyJob(CalendlyJobs.sync)
        _ = try await worker(f).runNext(); _ = try await worker(f).runNext()
        try check(try oldID != newID && f.db.job(id:oldID)?.result["skipped"] == "superseded" && f.db.job(id:newID)?.status == "done","new credentials fence and retire old job without repeated retries")
        let bannedID = try f.service.requestCalendlyJob(CalendlyJobs.sync), actor = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!
        _ = try f.db.update(actor,changes:["banned":.integer(1)],actor:f.service.identity.id)
        var calls = 0; _ = try await worker(f,request:{req in calls += 1; return try await CalendlyRelayClient.network(req)}).runNext()
        try check(try calls == 0 && f.db.job(id:bannedID)?.status == "failed" && !CalendlyJobs.enqueueDue(db:f.db),"revoked administrator stops automatic sync before transport")
        let banned = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!; _ = try f.db.update(banned,changes:["banned":.integer(0)],actor:f.service.identity.id)
        try check(try !CalendlyJobs.enqueueDue(db:f.db),"terminal failure is not silently retried on app wake")
        _ = try f.service.requestCalendlyJob(CalendlyJobs.sync); _ = try await worker(f).runNext()
        try check(try f.db.job(id:bannedID)?.status == "done","restored administrator can explicitly retry")
    }
    static func lease(_ resources: URL) async throws {
        let f = try await fixture(resources); try await subscribe(f); _ = try f.server.command(["action":"seed","count":1])
        let id = try f.service.requestCalendlyJob(CalendlyJobs.sync), now = Date()
        let other = try NativeDatabase(url:f.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        var stolen: NativeJob?
        let stale = worker(f,request:{req in let response = try await CalendlyRelayClient.network(req); stolen = try other.claimJob(events:[CalendlyJobs.sync],now:now.addingTimeInterval(301)); return response},clock:{now})
        _ = try await stale.runNext()
        try check(try stolen?.id == id && f.db.page("crm_Activities",fields:[]).total == 0 && CalendlyRelayBinding.load(db:f.db)?.cursor == 0,"expired lease owner cannot publish fetched page")
        try other.failJob(stolen!,message:"restart fixture",retryAt:now)
        _ = try await worker(f,clock:{now.addingTimeInterval(302)}).runNext()
        try check(try f.db.job(id:id)?.status == "done" && f.db.page("crm_Activities",fields:[]).total == 1,"replacement worker resumes unchanged cursor after stale lease")
        let g = try await fixture(resources); let m = g.manager(); try await m.begin(.subscribe); let controlID = try g.service.requestCalendlyJob(CalendlyJobs.subscription)
        let otherDB = try NativeDatabase(url:g.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")); var controlLease: NativeJob?
        g.provider.after = {req in if req.httpMethod == "POST" { controlLease = try otherDB.claimJob(events:[CalendlyJobs.subscription],now:now.addingTimeInterval(301)) } }
        _ = try await worker(g,clock:{now}).runNext(); g.provider.after = nil
        try check(try controlLease?.id == controlID && g.state().operation?.phase == .creating && g.state().registration == nil,"expired subscription lease preserves uncertain remote create intent")
        try otherDB.failJob(controlLease!,message:"restart fixture",retryAt:now)
        _ = try await worker(g,clock:{now.addingTimeInterval(302)}).runNext()
        try check(try g.state().registration != nil && g.provider.createCount == 1,"new lease reconciles remote registration without duplicate POST")
    }
    static func unknown(_ resources: URL) async throws {
        let f = try await fixture(resources); let m = f.manager(); try await m.begin(.subscribe); let id = try f.service.requestCalendlyJob(CalendlyJobs.subscription)
        f.provider.loseBeforeCreate = true; let w = worker(f); _ = try await w.runNext()
        try check(try f.db.job(id:id)?.status == "retry" && f.state().operation?.phase == .creating,"unknown POST retry retains original callback intent")
        _ = try f.service.requestCalendlyJob(CalendlyJobs.subscription); _ = try await w.runNext()
        try check(try f.db.job(id:id)?.status == "needs_review" && f.provider.createCount == 1,"empty provider reconciliation holds for explicit review")
        _ = try CalendlyJobs.enqueueDue(db:f.db); let noWork = try await w.runNext()
        try check(!noWork && f.provider.createCount == 1,"app wake does not retry review-held creation")
        try await m.confirmCreateNotApplied(operationID:f.state().operation!.id,note:"未登録を確認")
        let reviewedID = try f.service.requestCalendlyJob(CalendlyJobs.subscription); _ = try await w.runNext()
        try check(try reviewedID != id && f.db.job(id:id)?.status == "needs_review" && f.db.job(id:reviewedID)?.status == "done" && f.provider.rows.count == 1,"review keeps failed attempt history and completes one new job")
    }
    static func main() async { do { let resources = URL(fileURLWithPath:CommandLine.arguments[1]); try await jobs(resources); try await lease(resources); try await unknown(resources); print("CalendlyRuntimeTests: \(checks) checks passed; durable jobs, lease fences, retries, permission revocation and review") } catch { FileHandle.standardError.write(Data("CalendlyRuntimeTests: \(error)\n".utf8)); exit(1) } }
}
