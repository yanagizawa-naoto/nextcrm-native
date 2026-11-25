import Foundation
import SQLite3

@main enum CampaignResumeBackupTests {
    static var checks=0, observed:[String:Any]=[:]
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws {guard try value() else {throw NativeDBError.message("FAIL: "+label)};checks+=1}
    final class Fixture {
        let root:URL, resources:URL, db:NativeDatabase, service:CRMService
        let campaignID:String
        var sendID="", now=CampaignWorkflow.date(.text("2026-11-14T10:00:00.125Z"))!
        var requests=0, sent:[Data]=[], keys:[String]=[]
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
    static func main()async {do {try await run()}catch {FileHandle.standardError.write(Data("CampaignResumeBackupTests: \(error)\n".utf8));exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
        let base=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory().appendingPathComponent("NextCRM-G05-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:base)}
        let f=try Fixture(resources,base.appendingPathComponent("source"));let (before,body)=try await f.paused()
        let backupURL=base.appendingPathComponent("backup"),restoredURL=base.appendingPathComponent("restored")
        let backup=NativeBackup().prepare(source:f.db,destinationURL:backupURL)
        try check(backup.candidateCreated,"actual backup completed: "+backup.diagnostics.map { $0.code+":"+$0.message }.joined(separator:","))
        try check(try f.db.job(id:f.sendID)==before,"backup did not mutate source queue")
        try check(try Data(contentsOf:InvoiceMail.bodyURL(root:f.root,id:f.sendID))==body,"backup preserves original body")
        let restore=NativeRestore().prepare(backupURL:backupURL,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:restoredURL)
        try check(restore.candidateCreated,"actual restore completed: "+restore.diagnostics.map(\.code).joined(separator:","))
        try check(!restore.activated && !restore.workersStarted,"restore only prepares fixture, no automatic runtime")
        let restored=try NativeDatabase(url:restoredURL.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try restored.job(id:f.sendID)==before,"restore preserves exact job identity/digest/receipt fields")
        let restoredService=CRMService(db:restored,identity:f.service.identity)
        _=try restoredService.resumeCampaign(f.record(restored),now:f.now)
        _=try await CampaignDispatchWorker(db:restored,clock:{f.now}).runNext()
        let resumed=try restored.job(id:f.sendID)!
        try check(resumed.id==before.id && resumed.status=="pending" && resumed.result==before.result,"authorized resume reuses exact published metadata")
        let restoredBody=try InvoiceMail.bodyURL(root:restoredURL,id:f.sendID)
        let filePresent=FileManager.default.fileExists(atPath:restoredBody.path)
        try check(filePresent && backup.fileCount==1,"resumable frozen body is a backup reference");try check(try Data(contentsOf:restoredBody)==body,"restored bytes equal pre-pause content")
        _=try await f.worker(restored).runNext()
        let final=try restored.job(id:f.sendID)!

            try check(f.requests==1 && final.status=="done" && final.result["outcome"]=="sent","same-ID resume succeeds with fake provider receipt")
            try check(f.sent==[body] && f.keys==["campaign-send/"+before.id],"same immutable bytes and idempotency key reach fake transport")
            try check(!FileManager.default.fileExists(atPath:restoredBody.path),"accepted completion removes transport body")
            try check(try restored.get("crm_campaign_sends",key:["id":.text(f.sendID)])?["status"] == .text("sent"),"sent receipt/history remains")
            let terminalBackup=NativeBackup().prepare(source:restored,destinationURL:base.appendingPathComponent("terminal-backup"))
            try check(terminalBackup.candidateCreated && terminalBackup.fileCount==0,"accepted terminal body no longer required")
            try boundaryChecks(f,before:before,body:body,base:base)
            try await explicitCancellation(f,base:base)
            try await matrix(resources,base:base)
        observed=["mode":"production","checks":checks,"backupFiles":backup.fileCount,"restoredFiles":restore.fileCount,"sameJobID":before.id==final.id,"resumedStatus":final.status,"fakeRequests":f.requests,"realNetworkRequests":0,"realKeychainCalls":0,"fixtureWillBeRemoved":true]
        try JSONSerialization.data(withJSONObject:observed,options:[.sortedKeys,.prettyPrinted]).write(to:output)
        print(String(data:try JSONSerialization.data(withJSONObject:observed,options:[.sortedKeys]),encoding:.utf8)!)
    }
    static func boundaryChecks(_ f:Fixture,before:NativeJob,body:Data,base:URL)throws {
        let path=try InvoiceMail.bodyURL(root:f.root,id:f.sendID)
        try FileManager.default.removeItem(at:path)
        let missing=NativeBackup().prepare(source:f.db,destinationURL:base.appendingPathComponent("missing"))
        try check(!missing.candidateCreated && !FileManager.default.fileExists(atPath:base.appendingPathComponent("missing").path),"missing required skipped body rejects and cleans staging")
        try body.write(to:path,options:.atomic)
        try Data(repeating:120,count:body.count).write(to:path)
        let corrupt=NativeBackup().prepare(source:f.db,destinationURL:base.appendingPathComponent("corrupt"))
        try check(!corrupt.candidateCreated,"skipped hash mismatch rejects backup")
        try body.write(to:path,options:.atomic)
        var cancelled=false
        let cancelledBackup=NativeBackup(cancelled:{cancelled},checkpoint:{if $0=="pinsComplete" {cancelled=true}}).prepare(source:f.db,destinationURL:base.appendingPathComponent("cancelled"))
        try check(cancelledBackup.status == .cancelled && !cancelledBackup.candidateCreated,"cancel after required body pin aborts")
        try check(!FileManager.default.fileExists(atPath:base.appendingPathComponent("cancelled").path),"cancelled snapshot staging removed")
        try check(try Data(contentsOf:path)==body && f.db.job(id:f.sendID)==before,"missing/corrupt/cancel tests preserve source final bytes and queue")
        let unknown=f.root.appendingPathComponent("mail-outbox/legacy-unowned.json")
        try Data("unowned legacy body".utf8).write(to:unknown)
        let valid=NativeBackup().prepare(source:f.db,destinationURL:base.appendingPathComponent("with-unknown"))
        try check(valid.candidateCreated && valid.fileCount==1,"no arbitrary directory sweep or legacy inclusion")
        try check(try Data(contentsOf:unknown)==Data("unowned legacy body".utf8),"unknown legacy file not deleted")
    }
    static func explicitCancellation(_ f:Fixture,base:URL)async throws {
        _=try f.service.resumeCampaign(f.record(),now:f.now)
        _=try await CampaignDispatchWorker(db:f.db,clock:{f.now}).runNext()
        try f.service.cancelCampaignMailJob(f.db.job(id:f.sendID)!,now:f.now)
        let job=try f.db.job(id:f.sendID)!
        try check(job.status=="cancelled" && job.result["cancelledBy"]==f.service.identity.id,"explicit cancellation is a permanent decision")
        try check(try !FileManager.default.fileExists(atPath:InvoiceMail.bodyURL(root:f.root,id:f.sendID).path),"explicit cancel uses committed cleanup")
        let backup=NativeBackup().prepare(source:f.db,destinationURL:base.appendingPathComponent("cancelled-recipient"))
        try check(backup.candidateCreated && backup.fileCount==0,"cancelled recipient with retained digest does not demand removed body")
    }
    static func matrix(_ resources:URL,base:URL)async throws {
        let root=base.appendingPathComponent("matrix"),db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let events=["invoice.email_requested","orders.approval_requested","orders.approval_decided","projects.task_assigned","projects.task_updated","projects.task_commented","crm.task_assigned","crm.task_watched","crm.lead_assigned","campaigns/send-step","reports.scheduled","crm.automation.kill.notice","crm.automation.recycle.notice"]
        var required:Set<String>=[],excluded:Set<String>=[]
        // Each event uses the public queue APIs; pre-existing terminal hash fields
        // intentionally coexist with absent files, as after committed cleanup.
        for event in events {
            for status in ["pending","running","retry","failed","needs_review","done","skipped","cancelled"] {
                let id=UUID().uuidString.lowercased(),body=try InvoiceMail.prepareText(root:root,id:id,from:"a@example.invalid",to:"b@example.invalid",subject:"合成通知",message:event+" "+status)
                let metadata=["sha256":body.sha256,"bytes":String(body.bytes)]
                try db.enqueue(event,payload:metadata,id:id,now:now)
                if status=="cancelled" {try db.cancelJob(id:id,result:metadata.merging(["cancelledBy":"fixture"]){_,v in v})}
                else if status != "pending" {
                    // Explicit future runAt for every previous active row means
                    // this fresh identity is the only currently claimable row.
                    let job=try db.claimJob(events:[event],now:now)!
                    try check(job.id==id,"matrix claims its own fresh row")
                    try db.recordJobResult(job,result:metadata)
                    switch status {
                    case "running":break
                    case "retry":try db.failJob(job,message:"retry",retryAt:now.addingTimeInterval(3600))
                    case "failed":try db.failJob(job,message:"failed")
                    case "needs_review":_ = try db.markJobDeliveryStarted(job,now:now);try db.failJob(job,message:"unknown",needsReview:true)
                    default:try db.finishJob(job,result:metadata.merging(["outcome":status=="skipped" ? "skipped":"sent"]){_,v in v},now:now)
                    }
                }
                let keep=["pending","running","retry","failed","needs_review"].contains(status) || (event=="campaigns/send-step" && status=="skipped")
                if keep {required.insert("mail-outbox/"+id+".json")} else {excluded.insert("mail-outbox/"+id+".json");try FileManager.default.removeItem(at:body.url)}
                if status=="pending" {
                    // Prevent this pending row from being claimed by later cases.
                    var conn:OpaquePointer?;guard sqlite3_open(db.url.path,&conn)==SQLITE_OK else {throw NativeDBError.conflict};defer{sqlite3_close(conn)}
                    guard sqlite3_exec(conn,"UPDATE native_outbox SET next_run_at='2099-01-01T00:00:00Z' WHERE id='"+id+"'",nil,nil,nil)==SQLITE_OK else {throw NativeDBError.conflict}
                }
            }
        }
        let dest=base.appendingPathComponent("matrix-backup"),result=NativeBackup().prepare(source:db,destinationURL:dest)
        try check(result.candidateCreated,"13 event matrix backup")
        let lines=try String(contentsOf:dest.appendingPathComponent("files.ndjson"),encoding:.utf8).split(separator:"\n")
        let actual=Set(try lines.map{try JSONDecoder().decode(NativeBackupFile.self,from:Data($0.utf8)).sourcePath})
        try check(actual==required && actual.isDisjoint(with:excluded),"all 104 event/state ownership decisions exact")
        let restore=NativeRestore().prepare(backupURL:dest,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:base.appendingPathComponent("matrix-restored"))
        try check(restore.candidateCreated && restore.fileCount==Int64(required.count),"all required pending/retry/unknown and resumable bodies restore")
        for path in required {try check(try Data(contentsOf:root.appendingPathComponent(path))==Data(contentsOf:base.appendingPathComponent("matrix-restored").appendingPathComponent(path)),"matrix exact immutable bytes")}
        for path in excluded {try check(!FileManager.default.fileExists(atPath:base.appendingPathComponent("matrix-restored").appendingPathComponent(path).path),"matrix accepted/cancelled terminal absent")}
        try check(try db.jobs(events:events).count+db.jobs(events:events,offset:100).count==104,"no history queue row pruned")
    }
}
