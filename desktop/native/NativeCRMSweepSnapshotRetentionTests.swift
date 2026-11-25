import Foundation
import SQLite3

@main enum NativeCRMSweepSnapshotRetentionTests {
    static var checks=0
    enum Failure:Error {case assertion(String),injected}
    static func check(_ ok:@autoclosure()throws->Bool,_ label:String)throws{guard try ok() else{throw Failure.assertion(label)};checks += 1}
    static func json(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])}
    static func seed(_ value:[String:Any],db:NativeDatabase,models:[String])throws{
        try db.transaction{for model in models{for row in value[model] as? [[String:Any]] ?? [] {
            let fields=try row.mapValues{value->SQLValue in if value is NSNull{return .null};if let s=value as? String{return .text(s)};if let n=value as? NSNumber{return .integer(n.int64Value)};return .text(String(decoding:try json(value),as:UTF8.self))}
            _ = try db.insert(model,values:fields,actor:"synthetic")
        }}}
    }
    static func sql(_ db:NativeDatabase,_ statement:String)throws{
        var c:OpaquePointer?;guard sqlite3_open(db.url.path,&c)==SQLITE_OK else{throw Failure.injected};defer{sqlite3_close(c)}
        guard sqlite3_exec(c,statement,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message(String(cString:sqlite3_errmsg(c)))}
    }
    static func rows(_ db:NativeDatabase,_ statement:String)throws->[[String]]{
        var c:OpaquePointer?,s:OpaquePointer?;guard sqlite3_open(db.url.path,&c)==SQLITE_OK else{throw Failure.injected};defer{sqlite3_close(c)}
        guard sqlite3_prepare_v2(c,statement,-1,&s,nil)==SQLITE_OK else{throw Failure.injected};defer{sqlite3_finalize(s)}
        var result:[[String]]=[];while sqlite3_step(s)==SQLITE_ROW{result.append((0..<sqlite3_column_count(s)).map{sqlite3_column_text(s,$0).map{String(cString:$0)} ?? ""})};return result
    }
    static func copy(_ db:NativeDatabase,to target:URL)throws{
        var a:OpaquePointer?,b:OpaquePointer?;guard sqlite3_open_v2(db.url.path,&a,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else{throw Failure.injected};defer{sqlite3_close(a)}
        guard sqlite3_open(target.path,&b)==SQLITE_OK else{throw Failure.injected};defer{sqlite3_close(b)}
        guard let backup=sqlite3_backup_init(b,"main",a,"main") else{throw Failure.injected};let step=sqlite3_backup_step(backup,-1),finish=sqlite3_backup_finish(backup);guard step==SQLITE_DONE,finish==SQLITE_OK else{throw Failure.injected}
    }
    static func jobs(_ db:NativeDatabase,_ events:[String])throws->[NativeJob]{var all:[NativeJob]=[],offset=0;while true{let page=try db.jobs(events:events,offset:offset);all += page;if page.count<100{return all};offset += 100}}
    static func drain(_ db:NativeDatabase,now:Date)throws{var loops=0;while try NativeCRMSweepJobs.runNext(db:db,clock:{now}){loops += 1;try check(loops<1000,"local drain bounded")}}
    static func snapshots(_ db:NativeDatabase,_ owner:String,_ kind:String)throws->[String]{var all:[String]=[],after:String?;while true{let p=try db.crmAutomationSnapshotPage(ownerID:owner,kind:kind,after:after);all += p.map(\.value);if p.count<100{return all};after=p.last!.key}}
    static func pass(_ db:NativeDatabase)throws->(deleted:Int,held:Int,pages:Int){var deleted=0,held=0,pages=0;while true{let r=try NativeCRMSweepSnapshotRetention.runPage(db:db);try check(r.scanned<=100,"bounded cleanup page");deleted += r.deleted;held += r.held;pages += 1;guard r.hasMore else{return(deleted,held,pages)};try check(pages<100,"finite pass")}}
    final class Transport {
        var calls=0,status=200,bodies:[Data]=[]
        func request(_ request:URLRequest,_ body:URL)async throws->(Data,HTTPURLResponse){calls += 1;bodies.append(try Data(contentsOf:body));return(Data((status==200 ? "{\"id\":\"e1000000-0000-4000-8000-000000999999\"}":"{}").utf8),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)}
    }
    final class Pause {
        private let lock=NSCondition();private var entered=false,released=false
        func wait(){lock.lock();entered=true;lock.broadcast();while !released{lock.wait()};lock.unlock()}
        func ready()->Bool{lock.lock();defer{lock.unlock()};return entered}
        func release(){lock.lock();released=true;lock.broadcast();lock.unlock()}
    }
    static let account=InvoiceMailAccount(from:"sender@example.invalid",apiKey:"synthetic-unused")
    static func main()async{do{try await run();print("CRM snapshot retention: \(checks) checks passed")}catch{fputs("After \(checks): \(error)\n",stderr);exit(1)}}
    static func run()async throws{
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),candidate=URL(fileURLWithPath:CommandLine.arguments[2])
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:candidate.appendingPathComponent("reference.json"))) as! [String:Any]
        let models=reference["models"] as! [String],cases=reference["cases"] as! [[String:Any]],now=try NativeCRMAutomationDates.parse(reference["epoch"] as! String)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-SnapshotRetention-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        func open(_ name:String)throws->NativeDatabase{let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);return try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))}
        func prepared(_ name:String,count:Int=1,admins:Int=1,apply:Bool=true)throws->(NativeDatabase,String){let db=try open(name);var initial=cases.first{$0["label"] as? String == (count>1 ? "recycle-30":"recycle-0")}!["initial"] as! [String:Any]
            if admins>1{initial["Users"]=(cases.first{$0["label"] as? String == "recycle-31"}!["initial"] as! [String:Any])["Users"]}
            try seed(initial,db:db,models:models);let scan=try db.enqueue(NativeCRMSweepJobs.recycleScan,payload:[:],now:now);_ = try NativeCRMSweepJobs.runNext(db:db,clock:{now});if apply{try drain(db,now:now)};return(db,scan)}
        let (db,scan)=try prepared("dependent",count:205,admins:206,apply:false)
        let scanJob=try db.job(id:scan)!,applyID=scanJob.result["applyJobId"]!
        try check(try snapshots(db,scan,"recycleTarget").count==205,"actual producer target snapshot")
        let held=try pass(db);try check(held.deleted==0 && held.held==205,"pending apply retains all target IDs")
        try drain(db,now:now)
        let notice=try jobs(db,NativeCRMSweepJobs.mailEvents).first!,applyJob=try db.job(id:applyID)!
        try check(try snapshots(db,notice.id,"recipient").count==206,"actual producer recipient snapshot")
        let localDone=try pass(db)
        try check(localDone.deleted==205 && localDone.held==206,"finished apply frees targets while mail material held")
        try check(try db.job(id:scan)==scanJob && db.job(id:applyID)==applyJob && db.job(id:notice.id)==notice,"cleanup never changes job state/proofs")
        let transport=Transport();transport.status=500;var clock=now
        let worker=NativeCRMSweepMailWorker(db:db,account:{account},request:transport.request,clock:{clock})
        _ = try await worker.runNext();let retry=try db.job(id:notice.id)!,body=try InvoiceMail.bodyURL(root:db.url.deletingLastPathComponent(),id:notice.id)
        let originalBody=try Data(contentsOf:body)
        try check((try JSONSerialization.jsonObject(with:originalBody) as! [String:Any])["to"] as? [String] != nil,"actual consumer prepares single recipient array")
        try check(try pass(db).deleted==0 && snapshots(db,notice.id,"recipient").count==206 && Data(contentsOf:body)==originalBody,"retry retains recipients and immutable body")
        clock=now.addingTimeInterval(23*3600);_ = try await worker.runNext()
        let review=try db.job(id:notice.id)!
        try check(review.status=="needs_review" && transport.calls==1,"actual consumer uncertain timeout holds")
        try check(try pass(db).deleted==0 && Data(contentsOf:body)==originalBody,"review retains source material")
        let admin=CRMService(db:db,identity:.init(id:"e1000000-0000-4000-8000-000000000001",role:"admin",partnerAccountID:nil))
        try admin.reviewCRMSweepNotice(review,outcome:.unknown,providerID:"",note:"再送せず終了を確認",now:clock)
        let terminal=try db.job(id:notice.id)!
        try check(try pass(db).deleted==206 && snapshots(db,notice.id,"recipient").isEmpty && !FileManager.default.fileExists(atPath:body.path),"actual manual unknown terminal reclaims recipient snapshot")
        try check(try db.job(id:notice.id)==terminal && terminal.result["reviewOutcome"]=="unknown" && retry.deliveryStartedAt==terminal.deliveryStartedAt,"manual evidence and delivery start retained")
        for mode in ["accepted","cancelled","skipped","notSent","reviewAccepted"] {
            let (sample,sid)=try prepared(mode),job=try jobs(sample,NativeCRMSweepJobs.mailEvents).first!,tx=Transport()
            let sa=CRMService(db:sample,identity:.init(id:"e1000000-0000-4000-8000-000000000001",role:"admin",partnerAccountID:nil))
            if mode=="cancelled"{try sa.cancelCRMSweepNotice(job)}
            else {
                if mode=="skipped"{let user=try sample.get("Users",key:["id":.text(sa.identity.id)])!;_ = try sample.update(user,changes:["email":.text("new@example.invalid")],actor:sa.identity.id)}
                if mode=="notSent" || mode=="reviewAccepted"{tx.status=500}
                _ = try await NativeCRMSweepMailWorker(db:sample,account:{account},request:tx.request,clock:{now}).runNext()
                if mode=="notSent"{try sa.reviewCRMSweepNotice(sample.job(id:job.id)!,outcome:.notSent,providerID:"",note:"サービスで未送信を確認",now:now)}
                if mode=="reviewAccepted"{try sa.reviewCRMSweepNotice(sample.job(id:job.id)!,outcome:.accepted,providerID:"e1000000-0000-4000-8000-000000999998",note:"サービスで受付を確認",now:now)}
            }
            let before=try sample.job(id:job.id)!,result=try pass(sample)
            try check(result.deleted==2 && snapshots(sample,sid,"recycleTarget").isEmpty && snapshots(sample,job.id,"recipient").isEmpty,"known terminal reclaims "+mode)
            try check(try sample.job(id:job.id)==before && (mode != "skipped" || tx.calls==0),"consumer receipts preserved "+mode)
        }
        let (cancelApply,cancelScan)=try prepared("cancel-apply",apply:false),cancelID=try cancelApply.job(id:cancelScan)!.result["applyJobId"]!
        try cancelApply.cancelJob(id:cancelID,result:["outcome":"cancelled","cancelledBy":"synthetic"])
        try check(try pass(cancelApply).deleted==1,"cancelled unstarted apply no longer consumes snapshot")
        try await rollbackAndBounds(prepared:prepared,open:open,native:native,now:now)
        try contradictions(prepared:prepared,now:now)
        let plan=try rows(db,"EXPLAIN QUERY PLAN SELECT key FROM native_metadata WHERE key>='crm.automation.snapshot.v1.' AND key<'crm.automation.snapshot.v1/' AND key>'crm.automation.snapshot.v1.' ORDER BY key LIMIT 100")
        try check(plan.flatMap{$0}.contains{$0.contains("SEARCH native_metadata") && $0.contains("key>?")},"actual SQLite indexed namespace range")
        try json(["checks":checks,"queryPlan":plan,"fixturesRemoved":true,"liveProviders":false]).write(to:candidate.appendingPathComponent("native-results.json"))
    }
    typealias Prepare=(String,Int,Int,Bool)throws->(NativeDatabase,String)
    static func rollbackAndBounds(prepared:Prepare,open:(String)throws->NativeDatabase,native:URL,now:Date)async throws{
        let (db,scan)=try prepared("rollback",205,1,true)
        let before=try snapshots(db,scan,"recycleTarget"),cursor=try db.metadata(NativeCRMSweepSnapshotRetention.cursorKey)
        do{try db.transaction{_ = try NativeCRMSweepSnapshotRetention.runPage(db:db);throw Failure.injected}}catch Failure.injected{}
        try check(try snapshots(db,scan,"recycleTarget")==before && db.metadata(NativeCRMSweepSnapshotRetention.cursorKey)==cursor,"outer rollback restores snapshot/cursor")
        do{_ = try NativeCRMSweepSnapshotRetention.runPage(db:db,checkpoint:{n in if n==50{throw CancellationError()}});throw Failure.injected}catch is CancellationError{}
        try check(try snapshots(db,scan,"recycleTarget")==before && db.metadata(NativeCRMSweepSnapshotRetention.cursorKey)==cursor,"mid-page cancellation rolls back deletes/cursor")
        let pause=Pause(),task=Task.detached{try NativeCRMSweepSnapshotRetention.runPage(db:db,checkpoint:{n in if n==3{pause.wait()}})}
        while !pause.ready(){try await Task.sleep(nanoseconds:1_000_000)}
        task.cancel();pause.release();do{_ = try await task.value;throw Failure.injected}catch is CancellationError{}
        try check(try snapshots(db,scan,"recycleTarget")==before,"owner scan Task cancellation joins rollback")
        let other=try open("rollback")
        async let a=Task.detached{try NativeCRMSweepSnapshotRetention.runPage(db:db)}.value
        async let b=Task.detached{try NativeCRMSweepSnapshotRetention.runPage(db:other)}.value
        let both=try await(a,b)
        try check(both.0.scanned==100 && both.1.scanned==100 && both.0.deleted+both.1.deleted<=200,"two connections serialize bounded cursor progress")
        _ = try pass(db);try check(try snapshots(db,scan,"recycleTarget").isEmpty,"next pages finish after concurrent progress")
        let unknown=UUID().uuidString.lowercased(),key=NativeCRMSweepJobs.snapshotKey(unknown,"recipient",0)
        try db.setMetadata(key,value:"unknown-owned-data");try db.setMetadata("unrelated.value",value:"untouched")
        try db.setMetadata("crm.automation.snapshot.v1."+unknown+".foreign.000000000000",value:"not-ours")
        try db.setMetadata("crm.automation.snapshot.v1."+unknown+".recipient.bad",value:"not-ours")
        _ = try pass(db)
        try check(try db.metadata(key)=="unknown-owned-data" && db.metadata("unrelated.value")=="untouched","unknown owner and unrelated namespace retained")
        let sealed=db.url.deletingLastPathComponent().appendingPathComponent("sealed.sqlite");try copy(db,to:sealed)
        let ro=try NativeDatabase(readOnlyURL:sealed,schemaURL:native.appendingPathComponent("schema.json")),r=try NativeCRMSweepSnapshotRetention.runPage(db:ro)
        try check(r.readOnly && r.scanned==0 && ro.metadata(key)=="unknown-owned-data","restored sealed readonly never writes")
        let huge="crm.automation.snapshot.v1."+String(repeating:"x",count:1024)
        try db.setMetadata(huge,value:"unknown");let oversized=try NativeCRMSweepSnapshotRetention.runPage(db:db)
        try check(oversized.oversizedKey && oversized.deleted==0 && db.metadata(huge)=="unknown","oversized unknown key fails closed without loading full key")
    }
    static func contradictions(prepared:Prepare,now:Date)throws{
        let variations:[(String,String)] = [
            ("pending","status='pending'"),("running","status='running'"),("retry","status='retry'"),("failed","status='failed'"),("needs-review","status='needs_review'"),
            ("unknown-outcome","status='done',result='{\"outcome\":\"mystery\"}'"),
            ("begun-skipped","status='done',delivery_started_at=1,result='{\"outcome\":\"skipped\",\"reason\":\"changed\"}'"),
            ("cancelled-begun","status='cancelled',delivery_started_at=1"),
            ("skip-with-receipt","status='done',result='{\"outcome\":\"skipped\",\"reason\":\"changed\",\"providerID\":\"bad\"}'"),
            ("receipt-incomplete","status='done',delivery_started_at=1,result='{\"outcome\":\"sent\",\"providerID\":\"e1000000-0000-4000-8000-000000999999\"}'"),
            ("review-incomplete","status='done',delivery_started_at=1,result='{\"outcome\":\"not_sent\",\"reviewOutcome\":\"notSent\"}'")]
        for (name,patch) in variations {
            let (db,_)=try prepared("hold-"+name,1,1,true),job=try jobs(db,NativeCRMSweepJobs.mailEvents).first!
            try sql(db,"UPDATE native_outbox SET "+patch+" WHERE id='"+job.id+"'")
            let prior=try snapshots(db,job.id,"recipient");_ = try pass(db)
            try check(try snapshots(db,job.id,"recipient")==prior,"uncertain/contradictory terminal held "+name)
        }
        for mode in ["legacy","wrong-link","failed-apply","pending-scan","ordinal"] {
            let (db,scan)=try prepared("proof-"+mode,1,1,true),apply=try db.job(id:scan)!.result["applyJobId"]!
            switch mode {
            case "legacy":try sql(db,"UPDATE native_outbox SET result=json_remove(result,'$.applyJobId') WHERE id='"+scan+"'")
            case "wrong-link":try sql(db,"UPDATE native_outbox SET payload=json_set(payload,'$.scanId','e1000000-0000-4000-8000-000000999999') WHERE id='"+apply+"'")
            case "failed-apply":try sql(db,"UPDATE native_outbox SET status='failed' WHERE id='"+apply+"'")
            case "pending-scan":try sql(db,"UPDATE native_outbox SET status='pending' WHERE id='"+scan+"'")
            default:try db.setMetadata(NativeCRMSweepJobs.snapshotKey(scan,"recycleTarget",9),value:"out-of-range")
            }
            _ = try pass(db)
            try check(try !snapshots(db,scan,"recycleTarget").isEmpty,"unproven consumer/ordinal held "+mode)
        }
    }
}
