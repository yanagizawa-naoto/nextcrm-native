import Foundation
import SQLite3

@main enum NativeCRMSweepTests {
    static var checks = 0
    enum Failure: Error { case assertion(String), injected }
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws { guard try ok() else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed]) }
    static func seed(_ initial: [String:Any],db:NativeDatabase,models:[String]) throws {
        try db.transaction { for model in models { for row in initial[model] as? [[String:Any]] ?? [] {
            let values = try row.mapValues { value -> SQLValue in
                if value is NSNull { return .null }; if let text = value as? String { return .text(text) }
                if let n = value as? NSNumber { return .integer(n.int64Value) }
                return .text(String(decoding:try json(value),as:UTF8.self))
            }
            _ = try db.insert(model,values:values,actor:"synthetic")
        } } }
    }
    static func rows(_ db:NativeDatabase,_ model:String) throws -> [[String:Any]] {
        var result:[[String:Any]] = [],offset = 0
        while true { let rows = try db.page(model,fields:db.schema.model(model).fields.map(\.name),includeDeleted:true,offset:offset,insertionOrderForTies:true).rows
            result += rows.map { $0.values.mapValues(\.json) }; if rows.count < 100 { return result };offset += rows.count
        }
    }
    static func jobs(_ db:NativeDatabase,_ events:[String]) throws -> [NativeJob] {
        var result:[NativeJob] = [],offset = 0
        while true { let rows = try db.jobs(events:events,offset:offset); result += rows; if rows.count < 100 { return result };offset += rows.count }
    }
    static func drain(_ db:NativeDatabase,now:Date) throws {
        var count = 0
        while try NativeCRMSweepJobs.runNext(db:db,clock:{now}) { count += 1;try check(count < 2000,"drain bounded") }
    }
    static func sql(_ db:NativeDatabase,_ statement:String) throws {
        var c:OpaquePointer?;guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw Failure.injected };defer{sqlite3_close(c)}
        guard sqlite3_exec(c,statement,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }
    }
    static func sealedCopy(_ db:NativeDatabase,to target:URL) throws {
        var source:OpaquePointer?,destination:OpaquePointer?
        guard sqlite3_open_v2(db.url.path,&source,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { throw Failure.injected };defer{sqlite3_close(source)}
        guard sqlite3_open(target.path,&destination) == SQLITE_OK else { throw Failure.injected };defer{sqlite3_close(destination)}
        guard let backup=sqlite3_backup_init(destination,"main",source,"main") else { throw Failure.injected }
        let step=sqlite3_backup_step(backup,-1),finish=sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE,finish == SQLITE_OK else { throw Failure.injected }
    }
    final class Transport {
        var bodies:[[String:Any]] = [],keys:[String] = [],status=200,hook:(()->Void)?
        func request(_ request:URLRequest,_ body:URL) async throws -> (Data,HTTPURLResponse) {
            bodies.append(try JSONSerialization.jsonObject(with:Data(contentsOf:body)) as! [String:Any]); keys.append(request.value(forHTTPHeaderField:"Idempotency-Key") ?? "")
            hook?()
            return (Data((status == 200 ? "{\"id\":\"e1000000-0000-4000-8000-000000999999\"}":"{\"message\":\"synthetic unavailable\"}").utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        }
    }
    static let account = InvoiceMailAccount(from:"sender@example.invalid",apiKey:"synthetic-never-live")
    static func main() async {
        do { try await run();print("CRM sweeps: \(checks) native checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n",stderr);exit(1) }
    }
    static func run() async throws {
        let native = URL(fileURLWithPath:CommandLine.arguments[1]),candidate = URL(fileURLWithPath:CommandLine.arguments[2])
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:candidate.appendingPathComponent("reference.json"))) as! [String:Any]
        let models = reference["models"] as! [String],samples = reference["cases"] as! [[String:Any]],now = try NativeCRMAutomationDates.parse(reference["epoch"] as! String)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Sweeps-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        func open(_ name:String) throws -> NativeDatabase {
            let folder = root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            return try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        }
        var output:[[String:Any]] = []
        for sample in samples {
            let label = sample["label"] as! String,db = try open(label),kind = sample["kind"] as! String
            try seed(sample["initial"] as! [String:Any],db:db,models:models)
            if sample["auditFailure"] as? Bool == true { db.beforeRecordWrite = {model,_,_,values,_ in if model == "crm_AuditLog" { throw Failure.injected };return values} }
            let event = kind == "kill" ? NativeCRMSweepJobs.killScan:NativeCRMSweepJobs.recycleScan
            _ = try db.enqueue(event,payload:[:],now:now);try drain(db,now:now)
            if sample["rerun"] as? Bool == true { _ = try db.enqueue(event,payload:[:],now:now);try drain(db,now:now) }
            let local = try jobs(db,NativeCRMSweepJobs.events)
            try check(local.allSatisfy{$0.status == "done"},"no hidden local error "+label+" "+local.filter{$0.status != "done"}.map{$0.lastError ?? ""}.joined())
            let notices = try jobs(db,NativeCRMSweepJobs.mailEvents)
            let transport = Transport();if sample["mailFailure"] as? Bool == true { transport.status = 500 }
            let worker = NativeCRMSweepMailWorker(db:db,account:{account},request:transport.request,clock:{now})
            while try await worker.runNext() {}
            for notice in try jobs(db,NativeCRMSweepJobs.mailEvents) {
                let file = try InvoiceMail.bodyURL(root:db.url.deletingLastPathComponent(),id:notice.id)
                if sample["mailFailure"] as? Bool == true { try check(notice.status == "retry" && FileManager.default.fileExists(atPath:file.path),"failed send remains durable "+label) }
                else { try check(notice.status == "done" && notice.result["providerID"] != nil && !FileManager.default.fileExists(atPath:file.path),"committed receipt/terminal cleanup "+label) }
            }
            let after = try Dictionary(uniqueKeysWithValues:models.map{($0,try rows(db,$0))})
            output.append(["label":label,"after":after,"jobs":local.map{["event":$0.event,"result":$0.result,"payload":$0.payload]},"notices":notices.map{["event":$0.event,"payload":$0.payload]},"bodies":transport.bodies,"keys":transport.keys])
        }
        try await edges(open:open,samples:samples,models:models,now:now)
        try json(["cases":output,"checks":checks]).write(to:candidate.appendingPathComponent("native-results.json"))
    }
    static func edges(open:(String)throws->NativeDatabase,samples:[[String:Any]],models:[String],now:Date) async throws {
        func prepared(_ name:String,_ label:String) throws -> NativeDatabase { let db=try open(name);try seed(samples.first{$0["label"] as? String == label}!["initial"] as! [String:Any],db:db,models:models);return db }
        let id="e1000000-0000-4000-8000-000000000100"
        let db=try prepared("kill-rollback","kill-0")
        _ = try db.enqueue(NativeCRMSweepJobs.killScan,payload:[:],now:now);_ = try NativeCRMSweepJobs.runNext(db:db,clock:{now})
        do { _ = try NativeCRMSweepJobs.runNext(db:db,clock:{now},checkpoint:{name,_ in if name == "beforeFinish" { throw CancellationError() }});throw Failure.injected } catch is CancellationError {}
        try check(try db.get("crm_Opportunities",key:["id":.text(id)])?["status"] == .text("ACTIVE"),"kill cancellation rollback")
        try check(try rows(db,"crm_AuditLog").isEmpty && jobs(db,NativeCRMSweepJobs.mailEvents).isEmpty,"audit/intent rollback")
        try drain(db,now:now)
        try check(try rows(db,"crm_AuditLog").count == 1 && jobs(db,NativeCRMSweepJobs.mailEvents).count == 1,"retry exactly once")
        let r=try prepared("recycle-rollback","recycle-30")
        _ = try r.enqueue(NativeCRMSweepJobs.recycleScan,payload:[:],now:now);_ = try NativeCRMSweepJobs.runNext(db:r,clock:{now})
        do{_ = try NativeCRMSweepJobs.runNext(db:r,clock:{now},checkpoint:{name,n in if name == "recycleMembership" && n == 101 { throw CancellationError() }});throw Failure.injected}catch is CancellationError{}
        try check(try rows(r,"crm_TargetLists").isEmpty && rows(r,"TargetsToTargetLists").isEmpty && jobs(r,NativeCRMSweepJobs.mailEvents).isEmpty,"205 membership/list/notice outer rollback")
        let scan = try jobs(r,[NativeCRMSweepJobs.recycleScan]).first!
        try check(try r.crmAutomationSnapshotPage(ownerID:scan.id,kind:"recycleTarget").count == 100,"frozen snapshot survives apply rollback")
        try drain(r,now:now)
        try check(try rows(r,"TargetsToTargetLists").count == 205,"retry all frozen IDs")
        let alias=try prepared("alias-priority","recycle-12")
        let japanese = try alias.insert("crm_TargetLists",values:["name":.text("再開対象")],actor:"test")
        _ = try alias.enqueue(NativeCRMSweepJobs.recycleScan,payload:[:],now:now);try drain(alias,now:now)
        try check(try alias.get("TargetsToTargetLists",key:["target_id":.text("e1000000-0000-4000-8000-000000001000"),"target_list_id":japanese["id"]]) != nil,"Japanese alias wins over legacy")
        try check(try alias.get("crm_TargetLists",key:["id":.text("e1000000-0000-4000-8000-000000000080")])?["name"] == .text("Recycled"),"legacy name unmodified")
        _ = try alias.enqueue(NativeCRMSweepJobs.recycleScan,payload:[:],now:now);try drain(alias,now:now)
        try check(try jobs(alias,NativeCRMSweepJobs.mailEvents).count == 1,"Japanese alias membership excludes replay")
        let leased=try prepared("lease","kill-0")
        _ = try leased.enqueue(NativeCRMSweepJobs.killScan,payload:[:],now:now)
        let claimed = try leased.claimJob(events:NativeCRMSweepJobs.events,now:now)!
        let second = try open("lease")
        try check(try second.claimJob(events:NativeCRMSweepJobs.events,now:now) == nil,"second connection cannot claim active lease")
        let replaced = try second.claimJob(events:NativeCRMSweepJobs.events,now:now.addingTimeInterval(301))!
        do { _ = try leased.requireJobLease(claimed);throw Failure.injected } catch is NativeDBError {checks += 1}
        try check(replaced.leaseToken != claimed.leaseToken,"expired claim fenced by token")
        let snapshot=try prepared("snapshot-rollback","recycle-30"),sid=try snapshot.enqueue(NativeCRMSweepJobs.recycleScan,payload:[:],now:now)
        do{_ = try NativeCRMSweepJobs.runNext(db:snapshot,clock:{now},checkpoint:{name,n in if name == "recycleSnapshot" && n == 101 { throw CancellationError() }});throw Failure.injected}catch is CancellationError{}
        try check(try snapshot.crmAutomationSnapshotPage(ownerID:sid,kind:"recycleTarget").isEmpty,"cancelled scan snapshot rollback")
        let schedule=try open("schedule")
        let next=try NativeCRMSweepJobs.enqueueDue(db:schedule,now:now)
        try check(try jobs(schedule,NativeCRMSweepJobs.events).isEmpty,"initial no catchup")
        _ = try NativeCRMSweepJobs.enqueueDue(db:schedule,now:next.addingTimeInterval(3*86400));_ = try NativeCRMSweepJobs.enqueueDue(db:schedule,now:next.addingTimeInterval(3*86400))
        try check(try jobs(schedule,NativeCRMSweepJobs.events).count == 2,"missed cron coalesces and same wake idempotent")
        for bad in ["", "../x", "e1000000-0000-4000-8000-000000000100%"] { do{_ = try r.crmAutomationSnapshotPage(ownerID:bad,kind:"recipient");throw Failure.injected}catch is NativeDBError{checks += 1} }
        do{_ = try r.crmAutomationSnapshotPage(ownerID:sid,kind:"unknown");throw Failure.injected}catch is NativeDBError{checks += 1}
        let link=try NativeCRMSweepLink(destination:.opportunity,id:id)
        try check((try? NativeCRMSweepLink(text:link.string))?.id == id,"typed link roundtrip")
        for bad in [link.string+"?x=1",link.string+"/x","https://opportunities/"+id,"nextcrm-native://opportunities/../"+id,"nextcrm-native://unknown/"+id,link.string+"#x"] { try check((try? NativeCRMSweepLink(text:bad)) == nil,"strict link rejects") }
        let navigation=try prepared("navigation","kill-0")
        let owner="e1000000-0000-4000-8000-000000000002",admin="e1000000-0000-4000-8000-000000000001"
        let service=CRMService(db:navigation,identity:.init(id:owner,role:"user",partnerAccountID:nil))
        try check(try service.crmSweepRecord(from:link)["id"] == .text(id),"owned opportunity link")
        let administrator=CRMService(db:navigation,identity:.init(id:admin,role:"admin",partnerAccountID:nil))
        let list=try navigation.insert("crm_TargetLists",values:["name":.text("再開対象")],actor:admin)
        let listLink=try NativeCRMSweepLink(destination:.targetList,id:list["id"].string)
        try check(try administrator.crmSweepRecord(from:listLink)["id"] == list["id"],"admin target-list link")
        do{_ = try service.crmSweepRecord(from:listLink);throw Failure.injected}catch is NativeDBError{checks += 1}
        _ = try navigation.update(navigation.get("Users",key:["id":.text(owner)])!,changes:["banned":.integer(1)],actor:admin)
        do{_ = try service.crmSweepRecord(from:link);throw Failure.injected}catch is NativeDBError{checks += 1}
        _ = try navigation.update(navigation.get("crm_Opportunities",key:["id":.text(id)])!,changes:["deletedAt":.text(try NativeCRMSweepJobs.stamp(now))],actor:admin)
        do{_ = try administrator.crmSweepRecord(from:link);throw Failure.injected}catch is NativeDBError{checks += 1}
        try await mailEdges(open:open,samples:samples,models:models,now:now)
        try await noticeEdges(open:open,samples:samples,models:models,now:now)
    }
    static func mailEdges(open:(String)throws->NativeDatabase,samples:[[String:Any]],models:[String],now:Date) async throws {
        func prepared(_ name:String) throws -> NativeDatabase { let db=try open(name);try seed(samples[0]["initial"] as! [String:Any],db:db,models:models);_ = try db.enqueue(NativeCRMSweepJobs.killScan,payload:[:],now:now);try drain(db,now:now);return db }
        let db=try prepared("retry"),t=Transport();var clock=now;t.status=500
        let worker=NativeCRMSweepMailWorker(db:db,account:{account},request:t.request,clock:{clock})
        _ = try await worker.runNext();let first=try jobs(db,NativeCRMSweepJobs.mailEvents).first!
        try check(first.status == "retry" && first.deliveryStartedAt != nil,"provider failure retry preserves unknown outcome")
        clock=now.addingTimeInterval(60);t.status=200;_ = try await worker.runNext()
        try check(t.keys.count == 2 && t.keys[0] == t.keys[1] && (try json(t.bodies[0])) == json(t.bodies[1]),"retry immutable body/idempotency key")
        try check(try jobs(db,NativeCRMSweepJobs.mailEvents).first!.status == "done","retry accepted")
        let changed=try prepared("changed-recipient"),ct=Transport(),owner="e1000000-0000-4000-8000-000000000002"
        _ = try changed.update(changed.get("Users",key:["id":.text(owner)])!,changes:["email":.text("different@example.invalid")],actor:"test")
        _ = try await NativeCRMSweepMailWorker(db:changed,account:{account},request:ct.request,clock:{now}).runNext()
        try check(ct.bodies.isEmpty && jobs(changed,NativeCRMSweepJobs.mailEvents).first?.result["outcome"] == "skipped","changed recipient never sends")
        let late=try prepared("retry-deadline"),lt=Transport();lt.status=500;var lclock=now
        let lw=NativeCRMSweepMailWorker(db:late,account:{account},request:lt.request,clock:{lclock})
        _ = try await lw.runNext();let unknown=try jobs(late,NativeCRMSweepJobs.mailEvents).first!
        let la=CRMService(db:late,identity:.init(id:"e1000000-0000-4000-8000-000000000001",role:"admin",partnerAccountID:nil))
        do{try la.retryCRMSweepNotice(unknown,now:now.addingTimeInterval(23*3600));throw Failure.injected}catch is NativeDBError{checks += 1}
        try check(try late.job(id:unknown.id)==unknown,"manual retry deadline refuses unchanged row")
        lclock=now.addingTimeInterval(23*3600);_ = try await lw.runNext()
        let held=try jobs(late,NativeCRMSweepJobs.mailEvents).first!
        try check(lt.bodies.count == 1 && held.status == "needs_review","23-hour worker deadline no resend")
        do{try la.retryCRMSweepNotice(held,now:lclock);throw Failure.injected}catch is NativeDBError{checks += 1}
        let rc=try prepared("recipient-after-start"),rtarget=Transport();rtarget.status=500;var targetClock=now
        let targetWorker=NativeCRMSweepMailWorker(db:rc,account:{account},request:rtarget.request,clock:{targetClock})
        _ = try await targetWorker.runNext()
        _ = try rc.update(rc.get("Users",key:["id":.text(owner)])!,changes:["email":.text("new@example.invalid")],actor:"test")
        targetClock=now.addingTimeInterval(60);_ = try await targetWorker.runNext()
        try check(rtarget.bodies.count == 1 && jobs(rc,NativeCRMSweepJobs.mailEvents).first?.status == "needs_review","changed recipient after ambiguous send holds")
        let credential=try prepared("changed-credential"),kt=Transport();kt.status=500;var key=account;var kclock=now
        let kw=NativeCRMSweepMailWorker(db:credential,account:{key},request:kt.request,clock:{kclock})
        _ = try await kw.runNext();key = .init(from:account.from,apiKey:"synthetic-replacement");kclock=now.addingTimeInterval(60);_ = try await kw.runNext()
        try check(kt.bodies.count == 1 && jobs(credential,NativeCRMSweepJobs.mailEvents).first?.status == "needs_review","changed key after unknown send holds")
        let receipt=try prepared("receipt"),rt=Transport();rt.hook={try? sql(receipt,"CREATE TRIGGER fail_finish BEFORE UPDATE OF status ON native_outbox WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT,'injected finish'); END")}
        var rclock=now;let rw=NativeCRMSweepMailWorker(db:receipt,account:{account},request:rt.request,clock:{rclock})
        _ = try await rw.runNext();let pending=try jobs(receipt,NativeCRMSweepJobs.mailEvents).first!
        try check(pending.result["providerID"] != nil && pending.status == "retry","receipt survives local finish failure")
        try sql(receipt,"DROP TRIGGER fail_finish");rt.hook=nil;rclock=now.addingTimeInterval(60);_ = try await rw.runNext()
        try check(rt.bodies.count == 1 && jobs(receipt,NativeCRMSweepJobs.mailEvents).first!.status == "done","receipt restart completes without resend")
    }
    static func noticeEdges(open:(String)throws->NativeDatabase,samples:[[String:Any]],models:[String],now:Date) async throws {
        let db=try open("notice-management");try seed(samples[0]["initial"] as! [String:Any],db:db,models:models)
        let owner="e1000000-0000-4000-8000-000000000002",aid="e1000000-0000-4000-8000-000000000001"
        let admin=CRMService(db:db,identity:.init(id:aid,role:"admin",partnerAccountID:nil)),rep=CRMService(db:db,identity:.init(id:owner,role:"user",partnerAccountID:nil))
        let payload=["recipientId":owner,"recipientEmail":"rep@example.invalid","subject":"日本語通知","message":"本文"]
        let id=try db.enqueue(NativeCRMSweepJobs.killNotice,payload:payload,now:now),pending=try db.job(id:id)!
        let body=try InvoiceMail.prepareText(root:db.url.deletingLastPathComponent(),id:id,from:account.from,to:"rep@example.invalid",subject:"日本語通知",message:"本文")
        try check(try rep.crmSweepNoticeAccess(id)==pending && admin.crmSweepNotices().count == 1,"notice fresh owner/admin access")
        do{try db.transaction{try rep.cancelCRMSweepNotice(pending);throw Failure.injected}}catch Failure.injected{}
        try check(try db.job(id:id)==pending && FileManager.default.fileExists(atPath:body.url.path),"cancel outer rollback keeps body and job")
        try rep.cancelCRMSweepNotice(pending)
        try check(try db.job(id:id)?.status == "cancelled" && !FileManager.default.fileExists(atPath:body.url.path),"committed cancel cleanup")
        let id2=try db.enqueue(NativeCRMSweepJobs.killNotice,payload:payload,now:now),t=Transport();t.status=500
        _ = try await NativeCRMSweepMailWorker(db:db,account:{account},request:t.request,clock:{now}).runNext()
        var retry=try db.job(id:id2)!,file=try InvoiceMail.bodyURL(root:db.url.deletingLastPathComponent(),id:id2)
        try check(retry.canReviewMail,"notice appears in generic review allowlist")
        do{try db.transaction{try admin.retryCRMSweepNotice(retry,now:now);throw Failure.injected}}catch Failure.injected{}
        try check(try db.job(id:id2)==retry && FileManager.default.fileExists(atPath:file.path),"manual retry budget outer rollback")
        try admin.retryCRMSweepNotice(retry,now:now)
        do{try admin.retryCRMSweepNotice(retry,now:now);throw Failure.injected}catch is NativeDBError{checks += 1}
        try check(FileManager.default.fileExists(atPath:file.path),"retry retains immutable body")
        _ = try await NativeCRMSweepMailWorker(db:db,account:{account},request:t.request,clock:{now}).runNext();retry=try db.job(id:id2)!
        do{try admin.cancelCRMSweepNotice(retry);throw Failure.injected}catch is NativeDBError{checks += 1}
        // Simulate a persisted eighth permanent rejection: explicit manual retry
        // must preserve total counters/body/clocks and grant the new budget.
        try sql(db,"UPDATE native_outbox SET attempts=8,status='failed' WHERE id='"+id2+"'")
        retry=try db.job(id:id2)!
        let begun=retry.deliveryStartedAt,first=retry.firstAttemptAt
        try admin.retryCRMSweepNotice(retry,now:now)
        _ = try await NativeCRMSweepMailWorker(db:db,account:{account},request:t.request,clock:{now}).runNext()
        retry=try db.job(id:id2)!
        try check(retry.attempts == 9 && retry.status == "retry" && retry.deliveryStartedAt == begun && retry.firstAttemptAt == first && retry.result["manualRetryAttemptBase"] == "8","manual retry new budget preserves total and dedupe clocks")
        let receipt="e1000000-0000-4000-8000-000000999998"
        do{try db.transaction{try admin.reviewCRMSweepNotice(retry,outcome:.accepted,providerID:receipt,note:"送信サービスで確認",now:now);throw Failure.injected}}catch Failure.injected{}
        try check(try db.job(id:id2)==retry && FileManager.default.fileExists(atPath:file.path),"review rollback restores row and body")
        _ = try db.update(db.get("Users",key:["id":.text(aid)])!,changes:["role":.text("user")],actor:"test")
        do{try admin.reviewCRMSweepNotice(retry,outcome:.accepted,providerID:receipt,note:"確認",now:now);throw Failure.injected}catch is NativeDBError{checks += 1}
        _ = try db.update(db.get("Users",key:["id":.text(aid)])!,changes:["role":.text("admin")],actor:"test")
        try admin.reviewCRMSweepNotice(retry,outcome:.accepted,providerID:receipt,note:"送信サービスで確認",now:now)
        let done=try db.job(id:id2)!
        try check(done.status == "done" && done.result["providerID"] == receipt && done.result["reviewedBy"] == aid && !FileManager.default.fileExists(atPath:file.path),"accepted review records actor and cleans committed body")
        for (index,outcome) in [MailReviewOutcome.notSent,.unknown].enumerated() {
            let nid=try db.enqueue(NativeCRMSweepJobs.killNotice,payload:payload,now:now)
            _ = try await NativeCRMSweepMailWorker(db:db,account:{account},request:t.request,clock:{now}).runNext()
            let job=try db.job(id:nid)!
            do{try rep.reviewCRMSweepNotice(job,outcome:.accepted,providerID:receipt,note:"別の通知の受付ID",now:now);throw Failure.injected}catch is NativeDBError{checks += 1}
            try check(try db.job(id:nid)==job,"duplicate receipt refuses exact row")
            try rep.reviewCRMSweepNotice(job,outcome:outcome,providerID:"",note:"結果を確認",now:now)
            try check(try db.job(id:nid)?.result["outcome"] == (index == 0 ? "not_sent":"unconfirmed"),"manual result without invented receipt")
        }
        for invalid in ["-1","future","1000","01","9223372036854775808"] {
            let bad=try db.enqueue(NativeCRMSweepJobs.killNotice,payload:payload,now:now)
            try sql(db,"UPDATE native_outbox SET result='{\"manualRetryAttemptBase\":\""+invalid+"\"}' WHERE id='"+bad+"'")
            let count=t.bodies.count
            _ = try await NativeCRMSweepMailWorker(db:db,account:{account},request:t.request,clock:{now}).runNext()
            try check(t.bodies.count == count && db.job(id:bad)?.status == "failed","invalid retry base refuses effect "+invalid)
        }
        let digest=try db.enqueue(NativeCRMSweepJobs.recycleNotice,payload:["recipientCount":"1"],now:now)
        do{_ = try rep.crmSweepNoticeAccess(digest);throw Failure.injected}catch is NativeDBError{checks += 1}
        try check(try !rep.crmSweepNotices().contains{$0.id==digest} && admin.crmSweepNotices().contains{$0.id==digest},"digest limited to current admin")
        let sealed=db.url.deletingLastPathComponent().appendingPathComponent("sealed.sqlite")
        try sealedCopy(db,to:sealed)
        let ro=try NativeDatabase(readOnlyURL:sealed,schemaURL:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("schema.json"))
        let readAdmin=CRMService(db:ro,identity:.init(id:aid,role:"admin",partnerAccountID:nil)),djob=try db.job(id:digest)!
        do{try readAdmin.cancelCRMSweepNotice(djob);throw Failure.injected}catch is NativeDBError{checks += 1}
        try check(try db.job(id:digest)==djob,"read-only notice mutation refused")
    }

}
