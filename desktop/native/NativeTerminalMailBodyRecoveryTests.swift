import Foundation
import Darwin
import SQLite3

@main enum TerminalMailRecoveryTests {
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL: "+label)};checks+=1}
    final class Fixture {
        let root:URL, resources:URL, db:NativeDatabase, service:CRMService
        let campaignID:String
        var sendID="", now=CampaignWorkflow.date(.text("2026-11-14T10:00:00.125Z"))!
        var requests=0, sent:[Data]=[], keys:[String]=[]
        var failCleanup=false
        let credential=InvoiceMailAccount(from:"sender@example.invalid",apiKey:"synthetic-never-used-on-network")
        let config=try! CampaignMailConfiguration(publicURL:"https://crm.example.invalid/base/")
        init(_ resources:URL,_ root:URL)throws {
            self.resources=resources;self.root=root
            db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            let template=try service.saveCampaignTemplate(nil,input:["name":.text("本文保持"),"subject_default":.text("再開通知"),"content_html":.text("<p>{{first_name}} 様 日本語😀 再開前の本文</p>")])
            let target=try db.insert("crm_Targets",values:["last_name":.text("検証"),"first_name":.text("山田"),"email":.text("recipient@example.invalid"),"created_by":.text(service.identity.id)],actor:service.identity.id)
            let list=try db.insert("crm_TargetLists",values:["name":.text("合成対象"),"created_by":.text(service.identity.id)],actor:service.identity.id)
            _=try db.insert("TargetsToTargetLists",values:["target_id":target["id"],"target_list_id":list["id"]],actor:service.identity.id)
            let draft=try service.createCampaign(input:["name":.text("再開検証")],targetListIDs:[list["id"].string],steps:[.init(order:0,templateID:template["id"].string,subject:"再開確認")])
            campaignID=draft["id"].string
            _=try service.sendCampaignNow(draft,now:now)
        }
        func record(_ db:NativeDatabase?=nil)throws->NativeRecord {try (db ?? self.db).get("crm_campaigns",key:["id":.text(campaignID)])!}
        func worker(_ connection:NativeDatabase?=nil,pause:Bool=false)->CampaignMailWorker {
            CampaignMailWorker(db:connection ?? db,account:{self.credential},configuration:{self.config},endpointReady:{_,_ in
                if pause {_ = try self.service.pauseCampaign(self.record())}
            },request:{request,url in
                if self.failCleanup {try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:self.root.appendingPathComponent("mail-outbox").path)}
                self.requests+=1;self.sent.append(try Data(contentsOf:url));self.keys.append(request.value(forHTTPHeaderField:"Idempotency-Key") ?? "")
                return (Data("{\"id\":\"10000000-0000-4000-8000-000000000001\"}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            },clock:{self.now})
        }
        func paused()async throws->(NativeJob,Data) {
            _=try await CampaignDispatchWorker(db:db,clock:{self.now}).runNext()
            sendID=try db.page("crm_campaign_sends",fields:[],limit:1).rows[0]["id"].string
            _=try await worker(pause:true).runNext()
            let job=try db.job(id:sendID)!,body=try Data(contentsOf:InvoiceMail.bodyURL(root:root,id:sendID))
            try check(job.status=="done" && job.result["outcome"]=="skipped","actual worker paused after immutable preparation, before request")
            try check(job.deliveryStartedAt==nil && job.result["providerID"]==nil && requests==0,"skip did not start provider request")
            try check(try record()["status"] == .text("paused"),"actual service pause persisted")
            try InvoiceMail.verify(InvoiceMail.bodyURL(root:root,id:sendID),sha256:job.result["sha256"]!,bytes:Int(job.result["bytes"]!)!)
            checks+=1
            return (job,body)
        }
    }
    static let now=Date(timeIntervalSince1970:1_800_000_000)
    static func newDB(_ root:URL,_ resources:URL)throws->NativeDatabase {try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))}
    static func published(_ db:NativeDatabase,event:String="crm.task_assigned",status:String="done",outcome:String?=nil,started:Bool=true,receipt:Bool=true,cancelledBy:Bool=true)throws->String {
        let id=UUID().uuidString.lowercased(),body=try InvoiceMail.prepareText(root:db.url.deletingLastPathComponent(),id:id,from:"a@example.invalid",to:"b@example.invalid",subject:"合成通知",message:"保持する本文 "+id)
        let metadata=["sha256":body.sha256,"bytes":String(body.bytes)]
        try db.enqueue(event,payload:metadata,id:id,now:now)
        if status=="pending" {return id}
        if status=="cancelled" {try db.cancelJob(id:id,result:metadata.merging(cancelledBy ? ["cancelledBy":"fixture"]:[:]){_,v in v});return id}
        // All earlier unclaimed pending rows are scheduled in the future by callers.
        let job=try db.claimJob(events:[event],now:now)!
        try check(job.id==id,"fixture claims exact job")
        var result=metadata
        if receipt {result["providerID"]=UUID().uuidString.lowercased();result["acceptedAt"]=ISO8601DateFormatter().string(from:now)}
        if let outcome {result["outcome"]=outcome;if outcome=="skipped"{result["reason"]="送信対象外"}}
        try db.recordJobResult(job,result:result)
        if started{_ = try db.markJobDeliveryStarted(job,now:now)}
        switch status {
        case "done":try db.finishJob(job,result:result,now:now)
        case "running":break
        case "retry":try db.failJob(job,message:"再試行",retryAt:now.addingTimeInterval(3600))
        case "failed":try db.failJob(job,message:"失敗")
        default:try db.failJob(job,message:"不明",needsReview:true)
        }
        return id
    }
    static func file(_ db:NativeDatabase,_ id:String)throws->URL {try InvoiceMail.bodyURL(root:db.url.deletingLastPathComponent(),id:id)}
    static func exists(_ db:NativeDatabase,_ id:String)throws->Bool {try FileManager.default.fileExists(atPath:file(db,id).path)}
    static func drain(_ recovery:NativeTerminalMailBodyRecovery,page:Int=64)throws->(pages:Int,removed:Int,held:Int,failed:Int) {
        var result=(pages:0,removed:0,held:0,failed:0)
        while true {let p=try recovery.step(maximumEntries:page);result.pages+=1;result.removed+=p.removed;result.held+=p.held;result.failed+=p.failed;try check(p.scanned<=page,"bounded directory page");if p.finished{return result};guard result.pages<1000 else{throw NativeDBError.conflict}}
    }
    static func main()async {do {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        if CommandLine.arguments.contains("--crash") {
            let root=URL(fileURLWithPath:CommandLine.arguments[2]),db=try newDB(root,resources),id=try published(db)
            try Data(id.utf8).write(to:root.appendingPathComponent("committed-id"))
            kill(getpid(),SIGKILL);exit(9)
        }
        try await run(resources)
    }catch{FileHandle.standardError.write(Data("TerminalMailRecoveryTests: \(error)\n".utf8));exit(1)}}
    static func run(_ resources:URL)async throws {
        let out=URL(fileURLWithPath:CommandLine.arguments[2]),base=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory().appendingPathComponent("NextCRM-TerminalRecovery-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        // Actual campaign worker: directory permission removes only unlink permission,
        // after immutable prepare and before provider receipt reconciliation.
        let f=try Fixture(resources,base.appendingPathComponent("actual-worker"))
        _=try await CampaignDispatchWorker(db:f.db,clock:{f.now}).runNext();f.sendID=try f.db.page("crm_campaign_sends",fields:[],limit:1).rows[0]["id"].string;f.failCleanup=true
        _=try await f.worker().runNext();let terminal=try f.db.job(id:f.sendID)!
        try check(terminal.status=="done" && terminal.result["providerID"] != nil && f.requests==1,"actual accepted worker committed receipt")
        try check(try exists(f.db,f.sendID),"actual worker's failed unlink leaves terminal body")
        let failed=try drain(NativeTerminalMailBodyRecovery(db:f.db));try check(failed.failed==1 && exists(f.db,f.sendID),"unlink failure is retained and reported, not success")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:f.root.appendingPathComponent("mail-outbox").path)
        let removed=try drain(NativeTerminalMailBodyRecovery(db:f.db));try check(removed.removed==1 && !exists(f.db,f.sendID),"later eligible pass recovers actual failed cleanup")
        try check(try f.db.job(id:f.sendID)==terminal,"recovery does not edit receipt/history")
        // Real process death after committed terminal state; never any real provider.
        let crash=base.appendingPathComponent("crash"),process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=[resources.path,crash.path,"--crash"];try process.run();process.waitUntilExit()
        try check(process.terminationReason == .uncaughtSignal && process.terminationStatus==SIGKILL,"owned child really died by SIGKILL")
        let crashed=try newDB(crash,resources),id=try String(contentsOf:crash.appendingPathComponent("committed-id"),encoding:.utf8),before=try crashed.job(id:id)!
        try check(before.status=="done" && exists(crashed,id),"SIGKILL leaves committed result and body")
        try check(try drain(NativeTerminalMailBodyRecovery(db:crashed)).removed==1,"restart recovers committed crash leftover")
        try check(try crashed.job(id:id)==before,"crash recovery leaves receipt exact")
        try states(resources,base:base)
        try races(resources,base:base)
        try await lifecycle(resources,base:base)
        let result:[String:Any]=["checks":checks,"actualWorkerFailure":true,"actualSIGKILL":true,"realProviderCalls":0,"realKeychainCalls":0,"fixtureWillBeRemoved":true]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out);print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    }
    static func states(_ resources:URL,base:URL)throws {
        let db=try newDB(base.appendingPathComponent("states"),resources);var eligible:[String]=[],held:[String]=[]
        for event in NativeTerminalMailBodyRecovery.events.sorted() {
            eligible.append(try published(db,event:event))
            eligible.append(try published(db,event:event,status:"cancelled",started:false,receipt:false))
            let skip=try published(db,event:event,outcome:"skipped",started:false,receipt:false)
            if event=="campaigns/send-step" {held.append(skip)}else{eligible.append(skip)}
        }
        for outcome in ["accepted","notSent","unknown"] {
            let id=try published(db,event:"reports.scheduled",status:"needs_review",started:true,receipt:false),job=try db.job(id:id)!
            var result=job.result;result["reviewOutcome"]=outcome;result["reviewedBy"]="synthetic-reviewer";result["reviewNote"]="確認済み";result["reviewedAt"]=ISO8601DateFormatter().string(from:now);result["reviewPreviousStatus"]="needs_review"
            result["outcome"]=outcome=="accepted" ? "sent":outcome=="notSent" ? "not_sent":"unconfirmed"
            if outcome=="accepted"{result["providerID"]=UUID().uuidString.lowercased()}
            try db.completeReviewedMail(job,result:result,now:now);eligible.append(id)
        }
        held.append(try published(db,event:"campaigns/send-step",status:"cancelled",started:false,receipt:false,cancelledBy:false))
        for state in ["running","retry","failed","needs_review"] {held.append(try published(db,event:"crm.task_watched",status:state,started:true,receipt:false))}
        held.append(try published(db,event:"crm.task_watched",status:"pending",started:false,receipt:false))
        held.append(try published(db,event:"unknown.event"))
        held.append(try published(db,event:"projects.task_assigned",outcome:"mystery",started:false,receipt:false))
        held.append(try published(db,event:"projects.task_assigned",outcome:"mystery",started:true,receipt:true))
        let invalid=try published(db,event:"projects.task_updated");held.append(invalid);try Data("changed file".utf8).write(to:file(db,invalid))
        let unowned=UUID().uuidString.lowercased();held.append(unowned);_ = try InvoiceMail.prepareText(root:db.url.deletingLastPathComponent(),id:unowned,from:"a@example.invalid",to:"b@example.invalid",subject:"未公開",message:"unpublished/plugin preparation")
        for raw in ["{broken", "{\"providerID\":12}", "{\"padding\":\""+String(repeating:"x",count:262144)+"\"}"] {
            let id=try published(db,event:"projects.task_commented",status:"cancelled",started:false,receipt:false);held.append(id)
            try replaceRawResult(db,id:id,json:raw)
        }
        let root=db.url.deletingLastPathComponent().appendingPathComponent("mail-outbox")
        for i in 0..<150 {try Data("held legacy".utf8).write(to:root.appendingPathComponent("legacy-\(i).json"))}
        let scan=try drain(NativeTerminalMailBodyRecovery(db:db),page:17)
        try check(scan.pages>8 && scan.removed==eligible.count,"one persistent cursor crosses >150 held names and all eligible files")
        for id in eligible {try check(try !exists(db,id),"definitive published terminal body removed")}
        for id in held {try check(try exists(db,id),"rearmable/uncertain/unknown/unpublished/tampered body preserved")}
        try check(try db.jobs(events:Array(NativeTerminalMailBodyRecovery.events)+["unknown.event"]).count==eligible.count+held.count-1,"all job history remains")

    }
    static func replaceRawResult(_ db:NativeDatabase,id:String,json:String)throws {
        var raw:OpaquePointer?,statement:OpaquePointer?
        guard sqlite3_open(db.url.path,&raw)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_close(raw)}
        guard sqlite3_prepare_v2(raw,"UPDATE native_outbox SET result=? WHERE id=?",-1,&statement,nil)==SQLITE_OK else{throw NativeDBError.conflict};defer{sqlite3_finalize(statement)}
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        sqlite3_bind_text(statement,1,json,-1,transient);sqlite3_bind_text(statement,2,id,-1,transient)
        guard sqlite3_step(statement)==SQLITE_DONE else{throw NativeDBError.conflict}
    }
    static func races(_ resources:URL,base:URL)throws {
        let db=try newDB(base.appendingPathComponent("races"),resources),id=try published(db),url=try file(db,id),bytes=try Data(contentsOf:url)
        enum Rollback:Error {case expected}
        do {try db.transaction {let result=try drain(NativeTerminalMailBodyRecovery(db:db));try check(result.removed==0 && exists(db,id),"outer transaction cannot trigger deletion even for committed terminal");throw Rollback.expected}}catch Rollback.expected{}
        let target=base.appendingPathComponent("do-not-touch");try bytes.write(to:target)
        var swapped=false
        let recovery=NativeTerminalMailBodyRecovery(db:db,checkpoint:{point in if point=="beforeUnlink" && !swapped {swapped=true;try FileManager.default.removeItem(at:url);try FileManager.default.createSymbolicLink(at:url,withDestinationURL:target)}})
        try check(try drain(recovery).removed==0,"symlink replacement refuses unlink")
        try check(try Data(contentsOf:target)==bytes && FileManager.default.destinationOfSymbolicLink(atPath:url.path)==target.path,"symlink and outside target preserved")
        try FileManager.default.removeItem(at:url);try bytes.write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        // A simulated active backup pin is the exact hard-link mechanism used by
        // NativeBackupWorkspace; removing the ordinary name must keep its bytes.
        let pinned=base.appendingPathComponent("backup-pin");try FileManager.default.linkItem(at:url,to:pinned)
        try check(try drain(NativeTerminalMailBodyRecovery(db:db)).removed==1,"known terminal primary name reclaimed while backup pin exists")
        try check(try Data(contentsOf:pinned)==bytes,"backup hardlink bytes survive unchanged")
        let pending=try published(db,status:"pending",started:false,receipt:false)
        do {try db.transaction {let job=try db.claimJob(events:["crm.task_assigned"],now:now)!;_=try db.markJobDeliveryStarted(job,now:now);try db.finishJob(job,result:job.payload.merging(["providerID":UUID().uuidString.lowercased(),"acceptedAt":ISO8601DateFormatter().string(from:now)]){_,v in v});try check(try drain(NativeTerminalMailBodyRecovery(db:db)).removed==0,"uncommitted terminal result never permits unlink");throw Rollback.expected}}catch Rollback.expected{}
        try check(try db.job(id:pending)?.status=="pending" && exists(db,pending),"outer rollback preserves pending body")
        let backupDB=try newDB(base.appendingPathComponent("active-backup-source"),resources),backupID=try published(backupDB,status:"pending",started:false,receipt:false),backupBytes=try Data(contentsOf:file(backupDB,backupID))
        let backupURL=base.appendingPathComponent("active-backup")
        let snapshot=NativeBackup(checkpoint:{point in if point=="afterFence" {
            let job=try backupDB.claimJob(events:["crm.task_assigned"],now:now)!;_=try backupDB.markJobDeliveryStarted(job,now:now)
            try backupDB.finishJob(job,result:job.payload.merging(["providerID":UUID().uuidString.lowercased(),"acceptedAt":ISO8601DateFormatter().string(from:now)]){_,v in v})
            try check(try drain(NativeTerminalMailBodyRecovery(db:backupDB)).removed==1,"actual backup pins permit later committed cleanup")
        }}).prepare(source:backupDB,destinationURL:backupURL)
        try check(snapshot.candidateCreated && snapshot.fileCount==1 && !exists(backupDB,backupID),"active backup completes after source primary unlink")
        let restoreURL=base.appendingPathComponent("active-backup-restored"),restored=NativeRestore().prepare(backupURL:backupURL,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:restoreURL)
        try check(restored.candidateCreated && Data(contentsOf:InvoiceMail.bodyURL(root:restoreURL,id:backupID))==backupBytes,"actual backup/restore preserves pending snapshot body byte-for-byte")
        let readonly=try NativeDatabase(readOnlyURL:restoreURL.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json")),result=try NativeTerminalMailBodyRecovery(db:readonly).step()
        try check(result.readOnly && result.removed==0 && exists(readonly,backupID),"actual restored readonly root never scanned or unlinked")

    }
    final class Gate {let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0);private let lock=NSLock();private var drained=false;func mark(){lock.lock();drained=true;lock.unlock()};func done()->Bool{lock.lock();defer{lock.unlock()};return drained};func waitForEntry()->Bool{entered.wait(timeout:.now()+5) == .success}}
    static func lifecycle(_ resources:URL,base:URL)async throws {
        let db=try newDB(base.appendingPathComponent("runtime"),resources),id=try published(db,event:"projects.task_assigned"),gate=Gate()
        let recovery=NativeTerminalMailBodyRecovery(db:db,checkpoint:{point in if point=="beforeUnlink"{gate.entered.signal();gate.release.wait()}})
        let worker=InvoiceJobWorker(db:db,apiKey:{throw NativeDBError.conflict},terminalBodyRecovery:recovery)
        let runner=await MainActor.run {InvoiceJobRunner(db:db,events:CRMService.invoiceJobEvents,runNext:{try await worker.runNext()})}
        await MainActor.run{runner.kick()}
        let arrived=await Task.detached{gate.waitForEntry()}.value
        try check(arrived,"actual existing runner enters cleanup task")
        let stop=Task{@MainActor in await runner.stopAndDrain();gate.mark()}
        let otherGate=Gate(),otherStop=Task{@MainActor in await runner.stopAndDrain();otherGate.mark()}
        try await Task.sleep(nanoseconds:50_000_000);let early=gate.done()
        try check(!early && !otherGate.done(),"concurrent stopAndDrain waits for cancellation-ignoring accepted cleanup callback")
        stop.cancel();gate.release.signal();await stop.value;await otherStop.value
        try check(gate.done() && otherGate.done(),"both concurrent drain callers join actual completion")
        try check(try exists(db,id),"cancel before unlink keeps body")
        await MainActor.run{runner.kick()};try await Task.sleep(nanoseconds:20_000_000)
        try check(try exists(db,id),"stopped runner refuses later wake")
        let restart=InvoiceJobWorker(db:db,apiKey:{throw NativeDBError.conflict})
        while try await restart.runNext(){}
        try check(try !exists(db,id),"ordinary new owner runs bounded pass without mail work or provider")
        let pdfDB=try newDB(base.appendingPathComponent("cleanup-unavailable"),resources)
        let service=CRMService(db:pdfDB,identity:try CRMService.bootstrap(pdfDB,resources:resources.appendingPathComponent("../../prisma")))
        let account=try pdfDB.insert("crm_Accounts",values:["v":.integer(0),"name":.text("合成取引先"),"createdBy":.text(service.identity.id)],actor:service.identity.id)
        let series=try service.saveInvoiceSeries(original:nil,input:["name":.text("標準"),"prefixTemplate":.text("INV-{YYYY}-{####}")])
        _=try service.saveInvoiceSettings(original:nil,input:["companyName":.text("合成会社"),"companyAddress":.text("住所"),"companyCity":.text("東京"),"companyZip":.text("1000000"),"companyCountry":.text("日本"),"companyRegNo":.text("1234567890123"),"baseCurrency":.text("JPY"),"defaultDueDays":.integer(14),"defaultSeriesId":series["id"]])
        let draft=try service.saveInvoice(original:nil,header:["accountId":account["id"],"currency":.text("JPY")],lines:{$0==0 ? [.init(productID:nil,description:"合成商品",quantity:"1",unitPrice:"100",discountPercent:"0",taxRateID:nil)] : []})
        let invoice=try service.issueInvoice(draft)
        // A non-directory at the cleanup path must not prevent unrelated PDF work.
        let obstacle=pdfDB.url.deletingLastPathComponent().appendingPathComponent("mail-outbox");try Data("hold".utf8).write(to:obstacle)
        let pdfWorker=InvoiceJobWorker(db:pdfDB,apiKey:{throw NativeDBError.conflict})
        let worked=try await pdfWorker.runNext()
        let updated=try pdfDB.get("Invoices",key:["id":invoice["id"]])!
        try check(worked && updated["pdfStorageKey"] != .null && pdfDB.jobs(events:["invoice.pdf_requested"]).first?.status=="done","cleanup failure leaves ordinary actual PDF generation operational")
        try check(try Data(contentsOf:obstacle)==Data("hold".utf8),"inaccessible/unknown cleanup path never removed")
        // Actual invoice cancellation before first claim leaves SQL NULL result;
        // the immutable digest is in its payload and must remain recoverable.
        try FileManager.default.removeItem(at:obstacle)
        let mailID=try service.queueInvoiceEmail(updated,from:"a@example.invalid",to:"b@example.invalid",subject:"合成取消",message:"未送信本文")
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:obstacle.path)
        try service.cancelInvoiceJob(mailID)
        let cancelled=try pdfDB.job(id:mailID)!
        try check(cancelled.status=="cancelled" && cancelled.result.isEmpty && exists(pdfDB,mailID),"actual unclaimed invoice cancel leaves NULL-result published body after failed unlink")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:obstacle.path)
        try check(try drain(NativeTerminalMailBodyRecovery(db:pdfDB)).removed==1 && !exists(pdfDB,mailID),"NULL result with exact payload proof is recovered after actual cancellation")
        try check(try pdfDB.job(id:mailID)==cancelled,"actual cancelled invoice history remains exact")
    }
}
