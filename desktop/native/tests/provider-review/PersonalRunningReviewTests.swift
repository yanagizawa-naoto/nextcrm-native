import Foundation
import AppKit
import SQLite3
@testable import NextCRMR2Integrated

@main enum PersonalRunningReviewTests {
    static let owner="b1000000-0000-4000-8000-000000000001"
    static var checks=0
    enum Injected:Error {case rollback}
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("Test: "+label)};checks+=1;fputs("CHECK \(checks) \(label)\n",stderr)}
    static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("Accepted: "+label)}
    static func id(_ n:Int)->String{String(format:"b2000000-0000-4000-8000-%012d",n)}
    static let events=["invoice.email_requested","orders.approval_requested","orders.approval_decided","projects.task_assigned","projects.task_updated","projects.task_commented","crm.task_assigned","crm.task_watched","crm.lead_assigned","campaigns/send-step","reports.scheduled","crm.automation.kill.notice","crm.automation.recycle.notice"]
    static func seed(_ db:NativeDatabase)throws {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        let account=try db.insert("crm_Accounts",values:["name":.text("合成取引先"),"v":.integer(0)],actor:owner)
        let invoice=try db.insert("Invoices",values:["accountId":account["id"],"createdBy":.text(owner),"currency":.text("JPY"),"status":.text("ISSUED")],actor:owner)
        let series=try db.insert("NumberSeries",values:["name":.text("合成番号"),"template":.text("T-{####}"),"scope":.text("orders")],actor:owner)
        let order=try db.insert("crm_Orders",values:["number":.text("T-1"),"seriesId":series["id"],"accountId":account["id"],"currency":.text("JPY"),"createdBy":.text(owner)],actor:owner)
        let campaign=try db.insert("crm_campaigns",values:["name":.text("合成"),"created_by":.text(owner),"status":.text("paused"),"v":.integer(0)],actor:owner)
        let template=try db.insert("crm_campaign_templates",values:["name":.text("合成"),"content_html":.text("<p>合成</p>"),"content_json":.text("{}")],actor:owner)
        let step=try db.insert("crm_campaign_steps",values:["campaign_id":campaign["id"],"template_id":template["id"],"subject":.text("合成"),"order":.integer(0)],actor:owner)
        func running(_ n:Int,_ event:String,started:Bool=true,known:Bool=false,failed:Bool=false)throws {
            let jobID=id(n)
            var payload=["ownerId":owner,"scheduleId":id(900),"subject":"合成確認","to":"recipient@example.invalid","actorId":owner,"recipientId":owner,"taskId":id(901),"leadId":id(902),"orderId":order["id"].string,"invoiceId":invoice["id"].string]
            if event==CampaignWorkflow.sendStepEvent {
                let recipient=try db.insert("crm_Targets",values:["last_name":.text("合成先 "+jobID)],actor:owner)
                _ = try db.insert("crm_campaign_sends",values:["id":.text(jobID),"campaign_id":campaign["id"],"step_id":step["id"],"target_id":recipient["id"],"email":.text("recipient@example.invalid"),"status":.text("sending")],actor:owner)
                payload["campaignId"]=campaign["id"].string;payload["sendId"]=jobID
            }
            try db.enqueue(event,payload:payload,id:jobID,now:now)
            var job=try db.claimJob(events:[event],now:now)!
            guard job.id==jobID else{throw NativeDBError.conflict}
            if started{job=try db.markJobDeliveryStarted(job,now:now)}
            let body=try InvoiceMail.prepareText(root:db.url.deletingLastPathComponent(),id:jobID,from:"sender@example.invalid",to:"recipient@example.invalid",subject:"合成確認",message:"保持する本文")
            var result=["sha256":body.sha256,"bytes":String(body.bytes),"bodyReady":"true"]
            if known{result["providerID"]=id(999)}
            try db.recordJobResult(job,result:result)
            if failed{try db.failJob(job,message:"合成結果不明",needsReview:true)}
        }
        for (i,event) in events.enumerated(){for choice in 0..<3{try running(1+i*3+choice,event)}}
        for n in 50...62{try running(n,"reports.scheduled",started:n != 61,known:n==50,failed:n==62)}
        try running(63,CampaignWorkflow.sendStepEvent,started:false)
        try db.enqueue("reports.scheduled",payload:["ownerId":owner,"scheduleId":id(900)],id:id(64),now:now)
        for n in 100...250{try db.enqueue("future.unknown",payload:["preserve":"yes"],id:id(n),now:now)}
    }
    struct Fixture {
        let base:URL,resources:URL
        var candidate:URL{base.appendingPathComponent("candidate")}
        var verifier:NativeRestoreActivationVerifier{.init(schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{false})}
        func db(_ root:URL)throws->NativeDatabase{try .init(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))}
        func start()throws->NativeRestoreApplicationStartup{try .init(baseRootURL:base.appendingPathComponent("old"),controlURL:base.appendingPathComponent("control"),runtimes:NativeRestoreRuntimeCatalog.runtimes)}
        func select()throws->NativePersonalWorkspace.Selection {
            let read=try NativeDatabase(readOnlyURL:candidate.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"))
            return try NativePersonalWorkspace.select(read,userID:owner)
        }
        func prepare(protection:Bool=false,invalidProtection:String?=nil)throws {
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            do {
                let source=try db(base.appendingPathComponent("old"))
                _ = try source.insert("Users",values:["id":.text(owner),"email":.text("personal@example.invalid"),"name":.text("個人用"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:owner)
                _ = try source.insert("Users",values:["email":.text("history@example.invalid"),"name":.text("過去の担当者"),"role":.text("user"),"userStatus":.text("INACTIVE")],actor:owner)
                for (code,name,symbol) in [("JPY","日本円","¥"),("USD","米ドル","$")] {
                    _ = try source.insert("Currency",values:["code":.text(code),"name":.text(name),"symbol":.text(symbol),"isDefault":.integer(code=="JPY" ? 1:0)],actor:owner)
                }
                try seed(source)
                _ = try source.enqueue("future.external",payload:["unconfirmed":"keep"])
                let old=try source.claimJob(events:["future.external"])!;_ = try source.markJobDeliveryStarted(old)
                if protection { _ = try source.insert("InstalledPlugin",values:["id":.text("account-protection"),"version":.text("0.2.0"),"status":.text("ENABLED"),"settings":.text("{}"),"secrets":.text("never-read-private-fixture")],actor:owner) }
                if invalidProtection=="missing-index" {
                    _ = try source.insert("crm_Accounts",values:["name":.text("未確認の旧索引"),"company_id":.text("33333333"),"billing_country":.text("CZ"),"v":.integer(0)],actor:owner)
                }
                if invalidProtection=="malformed-reg" {
                    _ = try source.insert("PluginData",values:["pluginId":.text("account-protection"),"entityType":.text(""),"entityId":.text(""),"key":.text("reg:"+owner),"value":.text("{\"protectedUntil\":12}")],actor:owner)
                }
                let backup=NativeBackup().prepare(source:source,destinationURL:base.appendingPathComponent("backup"))
                guard backup.candidateCreated else{throw NativeRestoreActivationFailure("test.backup."+backup.diagnostics.map(\.code).joined(separator:","))}
            }
            let restored=NativeRestore().prepare(backupURL:base.appendingPathComponent("backup"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:candidate)
            guard restored.candidateCreated else{throw NativeRestoreActivationFailure("test.restore."+restored.diagnostics.map(\.code).joined(separator:","))}
            let verified=try verifier.inspect(candidate);try verifier.validate(verified)
            let control=try NativeRestoreActivationControl(url:base.appendingPathComponent("control"))
            let previous=NativeRestoreActivationSelection(generation:UUID().uuidString.lowercased(),root:try NativeRestoreActivationControl.root(base.appendingPathComponent("old")))
            let selected=NativeRestoreActivationSelection(generation:UUID().uuidString.lowercased(),root:verified.root)
            // Actual Backup/Restore/verifier above. This test's held-active
            // journal is a composition fixture, not an actual App/IPC ACK claim.
            var journal=NativeRestoreActivationJournal(activationID:UUID().uuidString.lowercased(),phase:.active,previous:previous,candidate:selected,seal:verified.seal)
            journal.runtimeCatalog=NativeRestoreRuntimeCatalog.runtimes;journal.previousRunning=["workspace.local"]
            journal.permittedRuntimes=["workspace.local"];journal.heldRuntimes=NativeRestoreRuntimeCatalog.heldAutomatic.sorted()
            try control.write(journal,name:"activation.json");try control.write(selected,name:"active-root.json")
        }
        func begin(_ startup:NativeRestoreApplicationStartup)async throws->NativePersonalRestoreAdmission.Record {
            let approval=try await NativePersonalRestoreAdmission.review(startup:startup,verifier:verifier,owner:select(),confirm:{ .enableLocalEditingAndKeepExternalHeld(subjectSHA256:$0.subjectSHA256) })
            return try NativePersonalRestoreAdmission.begin(approval,startup:startup,verifier:verifier)
        }
        func complete(_ record:NativePersonalRestoreAdmission.Record,_ startup:NativeRestoreApplicationStartup,checkpoint:@escaping(String)throws->Void={_ in})throws->NativePersonalRestoreAdmission.Opened {
            try NativePersonalRestoreAdmission.complete(record,startup:startup,openWritable:db,
                prepareLocalRules:{db,fence in try NativePersonalLocalPluginHost(db:db,definitions:[NativeAccountProtection.definition()],transitionID:record.transitionID,authorize:fence)},checkpoint:checkpoint)
        }
    }
    final class Clock {var now=Date(timeIntervalSince1970:1_800_000_100)}
    @MainActor static func main(){_ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited);Task{@MainActor in
        var code:Int32=0;do{try await run();print("Personal running review: \(checks) checks passed")}catch{fputs("Personal running review after \(checks): \(error)\n",stderr);code=1}
        let result=code;RunLoop.main.perform{exit(result)}
    };NSApp.run()}
    @MainActor static func wait(_ name:String,_ predicate:()->Bool)async throws{for _ in 0..<500{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NativeDBError.message("Timeout "+name)}
    static func property(_ object:Any,_ name:String)throws->Any{guard let item=Mirror(reflecting:object).children.first(where:{$0.label==name})else{throw NativeDBError.message("Missing label "+name)};return item.value}
    static func rawSQL(_ url:URL,_ sql:String)throws{var handle:OpaquePointer?;guard sqlite3_open_v2(url.path,&handle,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let handle else{throw NativeDBError.conflict};defer{sqlite3_close(handle)};guard sqlite3_exec(handle,sql,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message(String(cString:sqlite3_errmsg(handle)))}}
    @MainActor static func run()async throws {
        let f=Fixture(base:URL(fileURLWithPath:CommandLine.arguments[2]),resources:URL(fileURLWithPath:CommandLine.arguments[1]));try f.prepare()
        let originalHash=NativeMigrationCodec.hash(try Data(contentsOf:f.base.appendingPathComponent("old/crm.sqlite")))
        let startup=try f.start(),pending=try await f.begin(startup),opened=try f.complete(pending,startup),db=opened.db
        let service=CRMService(db:db,identity:opened.identity),clock=Clock()
        var api=try NativePersonalProviderReview(service:service,startup:startup,record:opened.record,clock:{clock.now})
        let p1=try api.page(),p2=try api.page(offset:100),p3=try api.page(offset:200),all=p1.rows+p2.rows+p3.rows
        try check(p1.rows.count==100 && p2.rows.count==100 && p3.rows.count==6 && p1.total==206,"complete bounded source pages")
        func row(_ n:Int)throws->NativePersonalProviderReview.Row{guard let row=all.first(where:{$0.id==id(n)})else{throw NativeDBError.conflict};return row}
        try rejects("old running needs actual ready quarantine"){_ = try api.prepare(row(1))}
        let quarantine=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:opened.record)
        let quarantineReceipt=try quarantine.install(),quarantineRaw=try db.restoredJobQuarantineMarker()
        try check(quarantineReceipt.jobCount==206,"actual sealed plan quarantine installed")
        try check(try db.claimJob(events:events,now:clock.now.addingTimeInterval(7200))==nil,"old IDs remain unclaimable after source leases expire")
        let unknown=try db.job(id:id(100))!,unstarted=try db.job(id:id(61))!,pendingJob=try db.job(id:id(64))!
        try rejects("unknown event stays held"){_ = try api.prepare(row(100))}
        try rejects("unstarted running no invented timestamp"){_ = try api.prepare(row(61))}
        try rejects("pending remains pending"){_ = try api.prepare(row(64))}
        let ticket=try api.prepare(row(51)),body=try InvoiceMail.bodyURL(root:f.candidate,id:id(51)),bytes=try Data(contentsOf:body)
        let full=try db.restoredMailReviewSnapshot(ticket.job).digestMaterial
        try check(try db.job(id:id(51))==ticket.job && db.restoredMailReviewSnapshot(ticket.job).digestMaterial==full,"prepare changes neither lease nor raw storage")
        try rejects("empty note rolls temporary state back"){_ = try api.record(ticket,expected:ticket.job,outcome:.unknown,providerID:"",note:"")}
        try check(try db.restoredMailReviewSnapshot(ticket.job).digestMaterial==full && api.receipt(jobID:ticket.job.id)==nil,"invalid reviewer preserves original full row")
        do{try db.transaction{_ = try api.record(ticket,expected:ticket.job,outcome:.unknown,providerID:"",note:"外側保存取消");throw Injected.rollback}}catch Injected.rollback{}
        try check(try db.restoredMailReviewSnapshot(ticket.job).digestMaterial==full && Data(contentsOf:body)==bytes && api.receipt(jobID:ticket.job.id)==nil,"outer rollback includes lease result receipt and body")
        let leaseTicket=try api.prepare(row(52))
        try rawSQL(db.url,"UPDATE native_outbox SET lease_until=lease_until+1 WHERE id='"+id(52)+"'")
        try check(try db.job(id:id(52))==leaseTicket.job,"NativeJob does not expose lease_until")
        try rejects("exact storage CAS catches hidden lease change"){_ = try api.record(leaseTicket,expected:leaseTicket.job,outcome:.unknown,providerID:"",note:"古い確認")}
        let rawTicket=try api.prepare(row(53))
        try rawSQL(db.url,"UPDATE native_outbox SET result=' '||result WHERE id='"+id(53)+"'")
        try check(try db.job(id:id(53))==rawTicket.job,"decoded job unchanged by raw JSON whitespace")
        try rejects("exact raw JSON CAS"){_ = try api.record(rawTicket,expected:rawTicket.job,outcome:.unknown,providerID:"",note:"古い確認")}
        let expired=try api.prepare(row(54));clock.now.addTimeInterval(301)
        try rejects("ticket expires"){_ = try api.record(expired,expected:expired.job,outcome:.unknown,providerID:"",note:"時間超過")};clock.now.addTimeInterval(-301)
        let wrong=try api.prepare(row(55))
        try rejects("wrong job"){_ = try api.record(wrong,expected:expired.job,outcome:.unknown,providerID:"",note:"別対象")}
        let selected=opened.record.authority.selection
        try startup.control.write(NativeRestoreActivationSelection(generation:UUID().uuidString.lowercased(),root:selected.root),name:"active-root.json")
        try rejects("wrong root generation"){_ = try api.record(wrong,expected:wrong.job,outcome:.unknown,providerID:"",note:"別世代")}
        try startup.control.write(selected,name:"active-root.json")
        let user=try db.get("Users",key:["id":.text(owner)])!,revoked=try db.update(user,changes:["banned":.integer(1)],actor:owner)
        try rejects("fresh owner revoked"){_ = try api.record(wrong,expected:wrong.job,outcome:.unknown,providerID:"",note:"失権")}
        _ = try db.update(revoked,changes:["banned":.integer(0)],actor:owner)
        try rejects("owner revision changed"){_ = try api.record(wrong,expected:wrong.job,outcome:.unknown,providerID:"",note:"古い権限確認")}
        let fenced=try api.prepare(row(59)),qkey=NativeDatabase.restoredJobQuarantinePrefix+id(59),qvalue=try db.metadata(qkey)!
        try db.setMetadata(qkey,value:String(repeating:"0",count:64)+":"+String(repeating:"1",count:64))
        try rejects("foreign quarantine binding"){_ = try api.record(fenced,expected:fenced.job,outcome:.unknown,providerID:"",note:"隔離不一致")}
        try db.setMetadata(qkey,value:qvalue)
        let plan=f.candidate.appendingPathComponent("resume-plan.ndjson"),planBytes=try Data(contentsOf:plan)
        try (planBytes+Data("\n".utf8)).write(to:plan)
        try rejects("plan changed after ticket"){_ = try api.record(fenced,expected:fenced.job,outcome:.unknown,providerID:"",note:"計画変更")}
        try planBytes.write(to:plan)
        // Fingerprint changed even after restoring bytes; open a new API below.
        api.close()
        api=try NativePersonalProviderReview(service:service,startup:startup,record:opened.record,clock:{clock.now})
        _ = try api.page()
        let cancelTicket=try api.prepare(row(58)),cancelFull=try db.restoredMailReviewSnapshot(cancelTicket.job).digestMaterial
        let observer=NotificationCenter.default.addObserver(forName:NativeDatabase.jobsDidChange,object:db,queue:nil){_ in withUnsafeCurrentTask{$0?.cancel()}}
        let cancelled=Task.detached{try api.record(cancelTicket,expected:cancelTicket.job,outcome:.unknown,providerID:"",note:"保存途中取消")}
        do{_ = try await cancelled.value;throw NativeDBError.message("Cancellation was ignored")}catch is CancellationError{checks+=1}
        NotificationCenter.default.removeObserver(observer)
        try check(try db.restoredMailReviewSnapshot(cancelTicket.job).digestMaterial==cancelFull && api.receipt(jobID:id(58))==nil,"actual task cancellation after domain review restores running lease and receipt")
        let known=try api.prepare(row(50))
        try rejects("known receipt cannot become not sent"){_ = try api.record(known,expected:known.job,outcome:.notSent,providerID:"",note:"矛盾")}
        try check(try db.job(id:id(50))==known.job,"known receipt rejection restores running")
        _ = try api.record(known,expected:known.job,outcome:.accepted,providerID:id(999),note:"送信サービスで保存済み受付を確認")
        for (i,event) in events.enumerated(){for (choice,outcome) in MailReviewOutcome.allCases.enumerated(){
            let n=1+i*3+choice,t=try api.prepare(row(n)),before=t.job,original=try db.restoredMailReviewSnapshot(before).digestMaterial
            let result=try api.record(t,expected:before,outcome:outcome,providerID:outcome == .accepted ? id(1000+n):"",note:"合成fixtureで明示的に確認")
            let after=try db.job(id:before.id)!
            try check(after.status=="done" && after.result["reviewOutcome"]==outcome.rawValue,"domain reviewer final state "+event+" "+outcome.rawValue)
            try check(after.result["outcome"]==(outcome == .accepted ? "sent":outcome == .notSent ? "not_sent":"unconfirmed"),"uncertain never becomes success "+event)
            try check(after.leaseToken==nil && after.attempts==before.attempts && after.firstAttemptAt==before.firstAttemptAt && after.deliveryStartedAt==before.deliveryStartedAt,"lease released without fabricated retry or dates "+event)
            try check(result.beforeStorageSHA256==NativeMigrationCodec.hash(original) && result.afterStorageSHA256==NativeMigrationCodec.hash(try db.restoredMailReviewSnapshot(after).digestMaterial) && !result.providerPermissionGranted,"full row receipt bound "+event)
            try check(try db.metadata(NativeDatabase.restoredJobQuarantinePrefix+before.id) != nil && db.claimJob(events:[event],now:clock.now.addingTimeInterval(7200))==nil,"review never releases source ID "+event)
            try rejects("replay "+event){_ = try api.record(t,expected:before,outcome:outcome,providerID:"",note:"再確認")}
        }}
        try check(try !db.personalPrerequisiteAmbiguous(events:[NativeCRMSweepJobs.killNotice,NativeCRMSweepJobs.recycleNotice],prefixes:[]),"known reviewed events no longer block prerequisite ambiguity")
        let exceptional=try api.prepare(row(63));_ = try api.record(exceptional,expected:exceptional.job,outcome:.unknown,providerID:"",note:"キャンペーン既存の不明終端")
        try check(try db.job(id:id(63))?.deliveryStartedAt==nil && db.job(id:id(63))?.result["outcome"]=="unconfirmed","existing campaign nil-delivery review exception does not invent a timestamp")
        let normal=try api.prepare(row(62));_ = try api.record(normal,expected:normal.job,outcome:.unknown,providerID:"",note:"既存確認経路")
        try check(try db.job(id:id(62))?.result["restoreReviewPreviousStatus"]==nil,"existing nonrunning review path remains direct")
        try await ui(api:api,jobID:id(57),db:db)
        try await cancellationJoin(service:service,startup:startup,record:opened.record)
        try check(try db.restoredJobQuarantineMarker()==quarantineRaw && db.job(id:id(100))==unknown && db.job(id:id(61))==unstarted && db.job(id:id(64))==pendingJob,"unsupported jobs and quarantine remain exact")
        try check(NativeMigrationCodec.hash(try Data(contentsOf:f.base.appendingPathComponent("old/crm.sqlite")))==originalHash,"source workspace SQLite bytes unchanged")
        api.close();try rejects("closed API"){_ = try api.page()}
    }
    final class Gate {
        private let lock=NSLock();private var started=false
        private let release=DispatchSemaphore(value:0)
        var entered:Bool{lock.lock();defer{lock.unlock()};return started}
        func hit(){lock.lock();if started{lock.unlock();return};started=true;lock.unlock();_ = release.wait(timeout:.now()+5)}
        func open(){release.signal()}
    }
    @MainActor static func cancellationJoin(service:CRMService,startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record)async throws {
        let before=NativePersonalProviderReviewIndex.liveForTesting,gate=Gate()
        NativePersonalProviderReviewIndex.didReadRowForTesting={gate.hit()}
        defer{gate.open();NativePersonalProviderReviewIndex.didReadRowForTesting=nil}
        let api=try NativePersonalProviderReview(service:service,startup:startup,record:record)
        let parent=NSPanel(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:false),controller=NativePersonalProviderReviewWindow(api:api)
        parent.beginSheet(controller.window,completionHandler:nil);controller.start()
        try await wait("actual cursor row checkpoint"){gate.entered}
        try check(NativePersonalProviderReviewIndex.liveForTesting==before+1,"temporary index owns one live connection while reading")
        _ = controller.perform(NSSelectorFromString("closeRequested"))
        try check(controller.window.sheetParent===parent && !controller.confirmDiscard(),"close waits while accepted callback ignores cancellation")
        try await Task.sleep(nanoseconds:30_000_000)
        try check(controller.window.sheetParent===parent,"cancel cannot falsely report completed close")
        gate.open();try await wait("cancel child joined"){controller.window.sheetParent==nil}
        try check(NativePersonalProviderReviewIndex.liveForTesting==before,"cancel joined and closed temporary SQLite index")
        try rejects("closed cancelled API"){_ = try api.page()};parent.close()
    }
    static func recordSelection(_ record:NativePersonalRestoreAdmission.Record)->NativeRestoreActivationSelection{record.authority.selection}
    @MainActor static func ui(api:NativePersonalProviderReview,jobID:String,db:NativeDatabase)async throws {
        let parent=NSPanel(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:false),window=NativePersonalProviderReviewWindow(api:api)
        parent.beginSheet(window.window,completionHandler:nil);window.start()
        try await wait("page loaded"){(try? property(window,"busy") as? Bool)==false}
        let table=try property(window,"table") as! NSTableView,rows=try property(window,"rows") as! [NativePersonalProviderReview.Row]
        guard let cancelPosition=rows.firstIndex(where:{$0.id==id(56)})else{throw NativeDBError.conflict}
        let beforeCancel=try db.job(id:id(56))!
        table.selectRowIndexes(IndexSet(integer:cancelPosition),byExtendingSelection:false)
        _ = window.perform(NSSelectorFromString("openReview"))
        let cancelRaw=try property(window,"reviewWindow"),cancelEditor=Mirror(reflecting:cancelRaw).children.first!.value as! CRMJobReviewWindow
        _ = cancelEditor.perform(NSSelectorFromString("cancel"));try await wait("empty review cancelled"){window.window.attachedSheet==nil}
        try check(try db.job(id:id(56))==beforeCancel && api.receipt(jobID:id(56))==nil,"cancel existing review form changes neither job nor receipt")
        guard let position=rows.firstIndex(where:{$0.id==jobID})else{throw NativeDBError.conflict};table.selectRowIndexes(IndexSet(integer:position),byExtendingSelection:false)
        _ = window.perform(NSSelectorFromString("openReview"))
        try check(window.window.attachedSheet != nil,"existing CRMJobReviewWindow reused")
        let raw=try property(window,"reviewWindow"),editor=Mirror(reflecting:raw).children.first!.value as! CRMJobReviewWindow
        let outcome=try property(editor,"outcome") as! NSPopUpButton,note=try property(editor,"note") as! NSTextView
        outcome.selectItem(at:2);_ = editor.perform(NSSelectorFromString("selectionChanged"));note.string="画面で結果不明を確認。外部接続は保留。"
        _ = editor.perform(NSSelectorFromString("save"));try await wait("review closed"){window.window.attachedSheet==nil}
        try check(try db.job(id:jobID)?.result["reviewOutcome"]=="unknown" && api.receipt(jobID:jobID)?.providerPermissionGranted==false,"actual existing UI records bound decision")
        _ = window.perform(NSSelectorFromString("closeRequested"));try await wait("parent closed"){window.window.sheetParent==nil}
        try check(window.confirmDiscard(),"closed UI has no accepted pending work");parent.close()
    }
}
