@testable import NextCRMR2Integrated
import Foundation
import AppKit
import SQLite3

@main enum PersonalGoogleRestoredReviewTests {
    static let owner="b1000000-0000-4000-8000-000000000001"
    static var checks=0
    static let epoch=Date(timeIntervalSince1970:1_800_000_000)
    enum Injected:Error{case rollback}
    static func id(_ n:Int)->String{String(format:"b2000000-0000-4000-8000-%012d",n)}
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("Test: "+label)};checks+=1}
    static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("Accepted: "+label)}
    static func raw(_ db:NativeDatabase,_ sql:String)throws->[String] {
        var handle:OpaquePointer?;guard sqlite3_open_v2(db.url.path,&handle,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let handle else{throw NativeDBError.conflict};defer{sqlite3_close(handle)}
        var s:OpaquePointer?;guard sqlite3_prepare_v2(handle,sql,-1,&s,nil)==SQLITE_OK,let s else{throw NativeDBError.message(String(cString:sqlite3_errmsg(handle)))};defer{sqlite3_finalize(s)}
        var rows:[String]=[]
        while true{let status=sqlite3_step(s);if status==SQLITE_DONE{return rows};guard status==SQLITE_ROW else{throw NativeDBError.message(String(cString:sqlite3_errmsg(handle)))};rows.append((0..<sqlite3_column_count(s)).map{sqlite3_column_text(s,$0).map{String(cString:$0)} ?? "NULL"}.joined(separator:"|"))}
    }
    static func seed(_ db:NativeDatabase)throws {
        _ = try db.insert("CalendarConnection",values:["id":.text(id(700)),"userId":.text(owner),"provider":.text("google"),"accountEmail":.text("calendar@example.invalid"),"scopeLevel":.text("readwrite"),"isActive":.integer(1),"refreshTokenEncrypted":.text("synthetic-unused")],actor:owner)
        for n in Array(1...13).filter({$0 != 12})+[12] {
            let activity=try db.insert("crm_Activities",values:["id":.text(id(100+n)),"type":.text("meeting"),"title":.text("旧予定 \(n)"),"date":.text("2030-01-01T09:00:00Z"),"createdBy":.text(owner)],actor:owner)
            try db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activity["id"].string,"operation":"upsert"],id:id(n),now:epoch.addingTimeInterval(Double(n)))
            if n==12{continue}
            // Independent synthetic source jobs may be running concurrently;
            // the generic lease API seeds those historical records only.
            let job=try db.claimJob(events:[GoogleCalendarOutbound.event],now:epoch.addingTimeInterval(Double(n)))!
            let plan=GoogleCalendarPushPlan(activityID:activity["id"].string,ownerID:owner,connectionID:id(700),accountEmail:"calendar@example.invalid",action:"insert",eventID:"syntheticgoogleevent\(n)",marker:job.id,activityRevision:activity.revision,mappingID:nil,mappingRevision:nil,start:"2030-01-01T09:00:00Z",end:"2030-01-01T09:30:00Z",counterparty:nil,body:"{}")
            var result=["requestOutcome":n==3 ? "confirmed":n==10 ? "rejected":n==13 ? "prepared":"unknown"]
            if n != 9{result["plan"]=String(decoding:try JSONEncoder().encode(plan),as:UTF8.self)}
            if n==3{result["remote"]="{\"id\":\"syntheticgoogleevent3\"}"}
            try db.recordJobResult(job,result:result)
            if [2,4,6,7,10].contains(n){try db.failJob(job,message:"synthetic unknown",needsReview:true)}
        }
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
    final class Secrets:NativeMailSecretStore,GoogleCalendarSecretStore,CalendlySecretStore,NativeAISecretStore,NativeMCPSecretStore {
        var data:[String:Data]=[:],reads=0,writes=0,deletes=0
        func load(id:String,interactive:Bool)throws->Data?{reads += 1;return data[id]}
        func load(id:String)throws->Data?{try load(id:id,interactive:false)}
        func save(id:String,data:Data)throws{writes += 1;self.data[id]=data}
        func remove(id:String)throws{deletes += 1;data.removeValue(forKey:id)}
    }
    final class InvoiceSecrets:InvoiceMailCredentialStore {
        var account:InvoiceMailAccount?,reads=0,writes=0,deletes=0
        func load(interactive:Bool)throws->InvoiceMailAccount?{reads += 1;return account}
        func save(_ account:InvoiceMailAccount)throws{writes += 1;self.account=account}
        func remove()throws{deletes += 1;account=nil}
    }
    final class RelaySecrets:CampaignRelayCredentialStore {
        var value:CampaignRelayCredentials?
        func load(interactive:Bool)throws->CampaignRelayCredentials?{value}
        func save(_ value:CampaignRelayCredentials)throws{self.value=value}
        func remove()throws{value=nil}
    }
    static let secretText="SYNTHETIC-NEVER-PERSIST-PREREQUISITE-SECRET"
    static func stores(_ db:NativeDatabase,_ secrets:Secrets,_ invoice:InvoiceSecrets=InvoiceSecrets())->NativePersonalRuntimePrerequisites.Stores {
        .init(databaseURL:db.url,mail:secrets,invoice:invoice,google:secrets,calendly:secrets,campaign:RelaySecrets(),ai:secrets,mcp:secrets,
              plugins:.init(read:{reference in guard let data=secrets.data[reference],let object=try JSONSerialization.jsonObject(with:data) as? NativePluginRecord else{throw NativeDBError.conflict};return object},write:{_,_ in throw NativeDBError.conflict},remove:{_ in throw NativeDBError.conflict},validatePublication:{_ in throw NativeDBError.conflict}),
              pluginDefinitions:[NativeAccountProtection.definition(),NativeOdooPlugin.definition,NativeOXOConnector.definition()],environment:.init(lookup:{_ in nil}))
    }
    final class Clock {var now=epoch.addingTimeInterval(100)}
    @MainActor static func main()async {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        do{try await run();print("Personal Google restored review: \(checks) checks passed")}
        catch{fputs("Google restored review after \(checks): \(error)\n",stderr);exit(1)}
    }
    @MainActor static func run()async throws {
        let f=Fixture(base:URL(fileURLWithPath:CommandLine.arguments[2]),resources:URL(fileURLWithPath:CommandLine.arguments[1]));try f.prepare()
        let startup=try f.start(),pending=try await f.begin(startup),opened=try f.complete(pending,startup),db=opened.db
        let service=CRMService(db:db,identity:opened.identity),clock=Clock(),secrets=Secrets()
        let q=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:opened.record);_ = try q.install()
        var api=try NativePersonalProviderReview(service:service,startup:startup,record:opened.record,clock:{clock.now})
        let page=try api.page();try check(page.total==14,"actual sealed source plan has thirteen Google jobs plus untouched unknown event")
        func row(_ n:Int)throws->NativePersonalProviderReview.Row{guard let value=page.rows.first(where:{$0.id==id(n)})else{throw NativeDBError.conflict};return value}
        let prerequisites=try NativePersonalRuntimePrerequisites(service:service,startup:startup,personal:opened.record,stores:stores(db,secrets),clock:{clock.now})
        try check(try prerequisites.hasAmbiguous(.googleConnectionsAndCursors),"baseline actual ambiguous old jobs block Google group")
        try rejects("original mail-only R1 API still rejects Google"){_ = try api.prepare(row(1))}
        try check(try row(1).eventLabel=="Googleへの予定の反映","Google source row visible as supported type")
        let t1=try api.prepareGoogle(row(1)),countBefore=try raw(db,"SELECT COUNT(*) FROM native_outbox"),storage1=try db.restoredMailReviewSnapshot(t1.job)
        try check(t1.canConfirmNotApplied && t1.scope.kind == .activityAndRemote,"unknown source plan supports honest no-followup confirmation")
        let editor=NativePersonalGoogleReviewWindow(api:api,ticket:t1)
        func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap{descendants($0)}}
        let views=descendants(editor.window.contentView!),buttons=views.compactMap{$0 as? NSButton}
        let notApplied=buttons.first{$0.title=="未反映の確認を記録"}!,hold=buttons.first{$0.title=="結果を確定せず保留を記録"}!
        try check(!notApplied.isEnabled && hold.isEnabled && !editor.window.isVisible,"review UI requires explicit notApplied confirmation and remains non-visible")
        _ = hold.target?.perform(hold.action,with:hold)
        try check(try db.restoredMailReviewSnapshot(t1.job).digestMaterial==storage1.digestMaterial && api.receipt(jobID:id(1))==nil,"empty UI note changes no job/hold/receipt")
        try check(views.compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("2,000") || $0.stringValue.contains("2000")},"Japanese bounded note requirement is visible")
        editor.window.close()
        try rejects("ordinary retry cannot bypass restoration review"){try service.retryGoogleCalendarPush(t1.job)}
        let t2=try api.prepareGoogle(row(2))
        try rejects("ordinary notApplied cannot enqueue for quarantined old ID"){_ = try service.reviewGoogleCalendarPushNotApplied(t2.job,note:"未反映を確認")}
        try check(try db.job(id:id(2))==t2.job && raw(db,"SELECT COUNT(*) FROM native_outbox")==countBefore,"ordinary old-ID rejection has no writes")
        do{try db.transaction{_ = try api.recordGoogleNotApplied(t1,note:"Googleで未反映を確認");throw Injected.rollback}}catch Injected.rollback{}
        try check(try db.restoredMailReviewSnapshot(t1.job).digestMaterial==storage1.digestMaterial && api.receipt(jobID:id(1))==nil,"outer rollback restores exact raw running row and receipt absence")
        try rejects("empty confirmation note"){_ = try api.recordGoogleNotApplied(t1,note:" \n ")}
        let receipt=try api.recordGoogleNotApplied(t1,note:" Googleの当該アカウント・予定で未反映を確認 ")
        let after=try db.job(id:id(1))!
        try check(after.status=="done" && after.result["requestOutcome"]=="reviewedNotApplied" && after.result["followUpJob"]==nil,"running normalizes and terminates with no replacement")
        try check(after.result["plan"]==t1.job.result["plan"] && after.result["restoreReviewPreviousRequestOutcome"]=="unknown" && after.result["restoreReviewPreviousStatus"]=="running","plan and prior uncertainty preserved")
        try check(try raw(db,"SELECT COUNT(*) FROM native_outbox")==countBefore && db.metadata(NativeDatabase.restoredJobQuarantinePrefix+after.id) != nil,"no new job and permanent old-ID quarantine")
        try check(receipt.outcome=="googleNotApplied" && !receipt.providerPermissionGranted && receipt.calendarScope==nil,"notApplied receipt grants no worker/provider authority")
        try rejects("same confirmation cannot be reused"){_ = try api.recordGoogleNotApplied(t1,note:"二度目")}
        let confirmed=try api.prepareGoogle(row(3)),confirmedStorage=try db.restoredMailReviewSnapshot(confirmed.job)
        try check(!confirmed.canConfirmNotApplied,"saved confirmed remote evidence disables contradictory notApplied")
        try rejects("confirmed cannot be called notApplied"){_ = try api.recordGoogleNotApplied(confirmed,note:"矛盾")}
        do{try db.transaction{_ = try api.recordGoogleHeld(confirmed,note:"反映済みの可能性があるため保留");throw Injected.rollback}}catch Injected.rollback{}
        try check(try db.restoredMailReviewSnapshot(confirmed.job).digestMaterial==confirmedStorage.digestMaterial && api.receipt(jobID:id(3))==nil && db.metadata(NativePersonalCalendarHold.receiptPrefix+id(3))==nil,"hold/receipt/lookups all rollback without touching old evidence")
        let held=try api.recordGoogleHeld(confirmed,note:"Googleに反映済みの記録を保ち、旧予定への書込みを止める")
        try check(try db.restoredMailReviewSnapshot(confirmed.job).digestMaterial==confirmedStorage.digestMaterial,"confirmed/oldstatus/lease/result all byte-identical after hold acknowledgement")
        try check(held.outcome=="googleUnknownHold" && held.calendarScope==confirmed.scope && !held.providerPermissionGranted,"honest hold has scope without claiming provider outcome")
        try check(try NativePersonalProviderReview.googleHeldAcknowledged(service:service,startup:startup,record:opened.record,jobID:id(3)),"domain fence and exact R1 receipt validate")
        try check(try prerequisites.hasAmbiguous(.googleConnectionsAndCursors),"other unreviewed old jobs remain blocked")
        // Lease_until is absent from NativeJob; full storage CAS must still see it.
        let t4=try api.prepareGoogle(row(4));_ = try raw(db,"UPDATE native_outbox SET lease_until=123 WHERE id='"+id(4)+"'")
        try rejects("invisible raw lease column CAS"){_ = try api.recordGoogleHeld(t4,note:"古い票")}
        _ = try raw(db,"UPDATE native_outbox SET lease_until=NULL WHERE id='"+id(4)+"'")
        let t5=try api.prepareGoogle(row(5)),user=try db.get("Users",key:["id":.text(owner)])!
        _ = try db.update(user,changes:["userStatus":.text("INACTIVE")],actor:owner)
        try rejects("revoked current owner"){_ = try api.recordGoogleHeld(t5,note:"権限なし")}
        let inactive=try db.get("Users",key:["id":.text(owner)])!;_ = try db.update(inactive,changes:["userStatus":.text("ACTIVE")],actor:owner)
        try rejects("changed owner revision invalidates old ticket"){_ = try api.recordGoogleHeld(t5,note:"旧版")}
        let t6=try api.prepareGoogle(row(6)),activity=try db.get("crm_Activities",key:["id":.text(id(106))])!
        _ = try db.update(activity,changes:["title":.text("確認中の別編集")],actor:owner)
        try rejects("scope reference revision changed"){_ = try api.recordGoogleHeld(t6,note:"変更前")}
        let t7=try api.prepareGoogle(row(7));clock.now.addTimeInterval(301)
        try rejects("ticket expiration"){_ = try api.recordGoogleHeld(t7,note:"期限切れ")};clock.now.addTimeInterval(-301)
        let t8=try api.prepareGoogle(row(8)),control=startup.control,selection=opened.record.authority.selection
        let changed=NativeRestoreActivationSelection(generation:UUID().uuidString.lowercased(),root:selection.root)
        try control.write(changed,name:"active-root.json")
        try rejects("different selected generation"){_ = try api.recordGoogleHeld(t8,note:"違う世代")}
        try control.write(selection,name:"active-root.json")
        try rejects("pending without uncertainty is never review-terminalized"){_ = try api.prepareGoogle(row(12))}
        let t9=try api.prepareGoogle(row(9));try check(t9.scope.kind == .allOutbound,"missing identity visibly uses conservative all-outbound hold")
        let t10=try api.prepareGoogle(row(10));_ = try api.recordGoogleNotApplied(t10,note:"拒否結果とGoogle上の未反映を確認")
        try check(try db.job(id:id(10))?.result["followUpJob"]==nil,"needsReview no-followup path also preserves enqueue count")
        for n in [2,4,5,6,7,8,9,11,13] {_ = try api.recordGoogleHeld(api.prepareGoogle(row(n)),note:"確認不能のため対象範囲を保留")}
        try check(try !prerequisites.hasAmbiguous(.googleConnectionsAndCursors),"explicit exact holds remove group-level review deadlock without claiming old result")
        try check(try db.job(id:id(2))==t2.job && raw(db,"SELECT COUNT(*) FROM native_outbox")==countBefore,"hold path keeps old raw operation and creates no outbox jobs")
        try check(try db.claimCalendarOutboundJob(now:epoch.addingTimeInterval(1000))==nil,"no old source job is claimable after either review outcome")
        try check(secrets.reads==0 && secrets.writes==0 && secrets.deletes==0,"review and ambiguity resolution never access credentials")
        let holdKey=NativePersonalCalendarHold.receiptPrefix+id(3),saved=try db.metadata(holdKey)!
        try db.setMetadata(holdKey,value:"{}")
        try check(try prerequisites.hasAmbiguous(.googleConnectionsAndCursors),"tampered domain receipt blocks group again")
        try db.setMetadata(holdKey,value:saved)
        _ = try raw(db,"UPDATE native_outbox SET completed_at='tampered' WHERE id='"+id(3)+"'")
        try check(try prerequisites.hasAmbiguous(.googleConnectionsAndCursors),"post-review hidden raw column tamper blocks group")
        _ = try raw(db,"UPDATE native_outbox SET completed_at=NULL WHERE id='"+id(3)+"'")
        try check(try !prerequisites.hasAmbiguous(.googleConnectionsAndCursors),"exact restored evidence revalidates")
        api.close();api=try NativePersonalProviderReview(service:service,startup:startup,record:opened.record,clock:{clock.now});_ = try api.page()
        try check(try api.receipt(jobID:id(3))==held,"receipt persists on review controller reopen")
        try rejects("acknowledged hold does not get a second confirmation ticket"){_ = try api.prepareGoogle(row(3))}
        // An ordinary non-restored job still has the original domain behavior.
        let normal=try f.db(f.base.appendingPathComponent("ordinary"))
        _ = try normal.insert("Users",values:["id":.text(owner),"name":.text("本人"),"email":.text("normal@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:owner)
        _ = try normal.insert("crm_Activities",values:["id":.text(id(500)),"type":.text("meeting"),"title":.text("通常"),"date":.text("2030-01-01T00:00:00Z"),"createdBy":.text(owner)],actor:owner)
        let normalID=try normal.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":id(500),"operation":"upsert"])
        let lease=try normal.claimCalendarOutboundJob()!;try normal.recordJobResult(lease,result:["requestOutcome":"unknown"]);try normal.failJob(lease,message:"test",needsReview:true)
        let normalService=CRMService(db:normal,identity:service.identity),original=try normal.job(id:normalID)!,next=try normalService.reviewGoogleCalendarPushNotApplied(original,note:"通常の未反映確認")
        try check(try normal.job(id:next)?.status=="pending" && normal.job(id:normalID)?.result["followUpJob"]==next,"ordinary reviewer still enqueues exactly one follow-up")
        try check(try raw(normal,"SELECT COUNT(*) FROM native_outbox")==["2"],"ordinary regression exact job count")
        api.close();startup.lease.close()
    }
}
