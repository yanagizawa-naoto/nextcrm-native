@testable import NextCRMR2Integrated
import Foundation
import AppKit
import SQLite3

@main enum SMTPReviewTests {
    static let owner="b1000000-0000-4000-8000-000000000001",accountID="b1000000-0000-4000-8000-000000000700"
    static var checks=0
    enum Injected:Error {case rollback}
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("Test: "+label)};checks+=1}
    static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("Accepted: "+label)}
    static func raw(_ db:NativeDatabase,_ sql:String)throws {var p:OpaquePointer?;guard sqlite3_open(db.url.path,&p)==SQLITE_OK,let p else{throw NativeDBError.conflict};defer{sqlite3_close(p)};guard sqlite3_exec(p,sql,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message(String(cString:sqlite3_errmsg(p)))}}
    static func addAccount(_ db:NativeDatabase)throws->NativeRecord {
        try db.insert("EmailAccount",values:["id":.text(accountID),"userId":.text(owner),"label":.text("合成メール"),"username":.text("sender@example.invalid"),"passwordEncrypted":.text("native-keychain:b1000000-0000-4000-8000-000000000701"),"imapHost":.text("imap.example.invalid"),"imapPort":.integer(993),"imapSsl":.integer(1),"smtpHost":.text("smtp.example.invalid"),"smtpPort":.integer(465),"smtpSsl":.integer(1),"isActive":.integer(0)],actor:owner)
    }
    static func seed(_ db:NativeDatabase)throws {
        let account=try addAccount(db),service=CRMService(db:db,identity:.init(id:owner,role:"admin",partnerAccountID:nil)),now=Date(timeIntervalSince1970:1_800_000_000)
        for n in 1...12 {
            let id=try service.queueMailSend(account:account,draft:.init(to:["受信者 <recipient@example.invalid>"],subject:"合成SMTP \(n)",body:"保持する本文 \(n)"),now:now)
            try db.setMetadata("test.smtp.\(n)",value:id)
            let status=n==2 || n==3 ? "running":n==4 ? "retry":"needs_review"
            let started=n==3 ? "NULL":"1800000000.0"
            let result=n==4 ? "{\"smtpAccepted\":\"true\",\"acceptedAt\":\"2027-01-15T08:00:00Z\"}":"{}"
            try raw(db,"UPDATE native_outbox SET status='\(status)',delivery_started_at=\(started),attempts=1,first_attempt_at=1800000000,lease_token=\(status == "running" ? "'source-lease'":"NULL"),lease_until=1800000300,result='\(result)' WHERE id='\(id)'")
        }
        for n in 100...201{try db.enqueue("future.smtp-boundary",payload:[:],id:String(format:"b2000000-0000-4000-8000-%012d",n),now:now)}
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
    @MainActor static func main()async {
        do{_ = NSApplication.shared;try await run();print("Restored SMTP review: \(checks) checks passed")}
        catch{fputs("Restored SMTP review after \(checks): \(error)\n",stderr);exit(1)}
    }
    static func property<T>(_ object:Any,_ name:String,_ type:T.Type)throws->T {guard let value=Mirror(reflecting:object).children.first(where:{$0.label==name})?.value as? T else{throw NativeDBError.message("Missing "+name)};return value}
    @MainActor static func run()async throws {
        let f=Fixture(base:URL(fileURLWithPath:CommandLine.arguments[2]),resources:URL(fileURLWithPath:CommandLine.arguments[1]));try f.prepare()
        let startup=try f.start(),pending=try await f.begin(startup),opened=try f.complete(pending,startup),db=opened.db
        let service=CRMService(db:db,identity:opened.identity),clock=Clock()
        let api=try NativePersonalProviderReview(service:service,startup:startup,record:opened.record,clock:{clock.now})
        let p1=try api.page(),p2=try api.page(offset:100),all=p1.rows+p2.rows
        try check(p1.rows.count==100 && all.count==115,"actual complete backup/restore resume-plan pagination")
        func id(_ n:Int)throws->String{try db.metadata("test.smtp.\(n)")!}
        func row(_ n:Int)throws->NativePersonalProviderReview.Row{let id=try id(n);return all.first{$0.id==id}!}
        try rejects("SMTP requires completed isolation"){_ = try api.prepareSMTP(row(1))}
        let q=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:opened.record);_ = try q.install()
        func ambiguous()throws->Bool {try NativePersonalSMTPReview.hasAmbiguous(service:service,startup:startup,record:opened.record)}
        try check(try ambiguous(),"old ambiguous SMTP blocks before explicit review")
        try check(try db.claimJob(events:[NativeMailDelivery.event],now:clock.now)==nil,"old source jobs never claimed")
        let t1=try api.prepareSMTP(row(1)),raw1=try db.restoredMailReviewSnapshot(t1.job).digestMaterial,mime1=try db.mailSendPayload(t1.job.id)!["mime"]!
        let panel=NativePersonalSMTPReviewWindow(api:api,ticket:t1)
        let select=try property(panel,"outcome",NSPopUpButton.self),note=try property(panel,"note",NSTextField.self),confirm=try property(panel,"confirmation",NSButton.self),save=try property(panel,"save",NSButton.self)
        try check(select.numberOfItems==3 && select.indexOfSelectedItem==0,"actual SMTP panel three choices defaults held")
        save.performClick(nil)
        try check(try NativePersonalSMTPReview.read(db:db,generation:opened.record.authority.selection.generation,id:t1.job.id)==nil,"actual primary requires explicit checkbox")
        confirm.state = .on;save.performClick(nil)
        try check(try NativePersonalSMTPReview.read(db:db,generation:opened.record.authority.selection.generation,id:t1.job.id)==nil,"actual primary requires reason")
        note.stringValue="送信済みフォルダでも確認できないため、旧メールを保留";save.performClick(nil)
        let held1=try NativePersonalSMTPReview.read(db:db,generation:opened.record.authority.selection.generation,id:t1.job.id)!
        try check(held1.outcome == .unknownHeld && !held1.providerPermissionGranted,"actual panel records explicit held receipt")
        try check(try db.restoredMailReviewSnapshot(t1.job).digestMaterial==raw1 && db.mailSendPayload(t1.job.id)!["mime"]==mime1,"held preserves every raw outbox column and MIME")
        try rejects("duplicate stale ticket"){_ = try api.recordSMTP(t1,outcome:.sent,note:"後から確認")}
        let sentTicket=try api.prepareSMTP(row(1));let sent=try api.recordSMTP(sentTicket,outcome:.sent,note:"送信済みフォルダのMessage-IDを本人が確認")
        let sentJob=try db.job(id:t1.job.id)!,email=try db.get("Email",key:["id":.text(sentJob.result["emailID"]!)])!
        try check(sent.outcome == .sent && sentJob.status=="done" && sentJob.result["review"]=="sent" && sentJob.result["smtpAccepted"]=="true","sent uses existing SMTP review values and locally terminates")
        try check(email["bodyText"].string=="保持する本文 1" && email["folder"].string=="SENT" && email["userId"].string==owner,"sent local Email body/account/owner exact")
        try check(try db.mailSendPayload(t1.job.id)!["mime"] == .null && db.metadata("mail.bodyLoaded."+email["id"].string)=="1","sent same MIME release and loaded metadata semantics")
        try check(try db.job(id:t1.job.id)?.leaseToken==nil && db.metadata(NativeDatabase.restoredJobQuarantinePrefix+t1.job.id)==sent.quarantineValue,"no invented transport lease; quarantine remains")
        let t2=try api.prepareSMTP(row(2)),before2=try db.mailSendPayload(t2.job.id)!["mime"]!
        _ = try api.recordSMTP(t2,outcome:.notSent,note:"事業者の履歴で未送信と確認")
        let notSent=try db.job(id:t2.job.id)!
        try check(notSent.status=="failed" && notSent.result["review"]=="notSent" && notSent.deliveryStartedAt==nil && notSent.leaseToken==nil,"old running confirmed not sent preserves failed semantics")
        try check(try db.mailSendPayload(t2.job.id)!["mime"]==before2,"not sent MIME retained")
        try rejects("old failed SMTP cannot manual retry"){try service.retryMailSend(notSent)}
        let t3=try api.prepareSMTP(row(3));try check(!t3.canConfirmResult,"unstarted running cannot be asserted sent/not sent")
        try rejects("unstarted sent"){_ = try api.recordSMTP(t3,outcome:.sent,note:"証拠無し")}
        try rejects("unstarted not sent"){_ = try api.recordSMTP(t3,outcome:.notSent,note:"証拠無し")}
        let p3=NativePersonalSMTPReviewWindow(api:api,ticket:t3);try check(try property(p3,"outcome",NSPopUpButton.self).numberOfItems==1,"unstarted UI only unknown hold")
        _ = try api.recordSMTP(t3,outcome:.unknownHeld,note:"実行中だが開始記録がないので保留")
        let t4=try api.prepareSMTP(row(4));try rejects("stored acceptance contradicts not sent"){_ = try api.recordSMTP(t4,outcome:.notSent,note:"矛盾")}
        _ = try api.recordSMTP(t4,outcome:.sent,note:"保存済み受付記録を確認")
        try check(try db.job(id:t4.job.id)?.status=="done","known acceptance local reconciliation no external request")
        let t5=try api.prepareSMTP(row(5));clock.now=clock.now.addingTimeInterval(301)
        try rejects("expired fresh UI decision"){_ = try api.recordSMTP(t5,outcome:.unknownHeld,note:"期限切れ")};clock.now=clock.now.addingTimeInterval(-301)
        let t6=try api.prepareSMTP(row(6));try raw(db,"UPDATE native_outbox SET lease_until=1800000400 WHERE id='"+t6.job.id+"'")
        try check(try db.job(id:t6.job.id)==t6.job,"lease_until omitted from NativeJob demonstrates full-row boundary")
        try rejects("full raw-row CAS includes lease_until"){_ = try api.recordSMTP(t6,outcome:.unknownHeld,note:"古い行")}
        let t7=try api.prepareSMTP(row(7)),b7=try db.restoredMailReviewSnapshot(t7.job).digestMaterial
        do{try db.transaction{_ = try api.recordSMTP(t7,outcome:.sent,note:"外側取消");throw Injected.rollback}}catch Injected.rollback{}
        try check(try db.restoredMailReviewSnapshot(t7.job).digestMaterial==b7 && db.mailSendPayload(t7.job.id)!["mime"] != .null,"sent outer rollback keeps outbox and MIME")
        try check(try NativePersonalSMTPReview.read(db:db,generation:opened.record.authority.selection.generation,id:t7.job.id)==nil,"outer rollback removes receipt")
        let t8=try api.prepareSMTP(row(8));let account=try service.mailAccount(accountID)
        _ = try db.update(account,changes:["label":.text("別の設定")],actor:owner)
        try rejects("account revision changed"){_ = try api.recordSMTP(t8,outcome:.unknownHeld,note:"古い設定")}
        let t9=try api.prepareSMTP(row(9));let user=try db.get("Users",key:["id":.text(owner)])!
        _ = try db.update(user,changes:["name":.text("変更後の本人")],actor:owner)
        try rejects("owner revision changed"){_ = try api.recordSMTP(t9,outcome:.unknownHeld,note:"古い本人")}
        let t10=try api.prepareSMTP(row(10));let saved10=try db.mailSendPayload(t10.job.id)!["mime"]!
        try raw(db,"UPDATE native_mail_sends SET mime=x'00' WHERE job_id='"+t10.job.id+"'")
        try rejects("corrupt stored MIME sent fails atomically"){_ = try api.recordSMTP(t10,outcome:.sent,note:"確認済み")}
        try check(try db.job(id:t10.job.id)==t10.job,"failed reconciliation restores needs_review")
        if case .blob(let data)=saved10 {try raw(db,"UPDATE native_mail_sends SET mime=x'"+data.map{String(format:"%02x",$0)}.joined()+"' WHERE job_id='"+t10.job.id+"'")}
        let t11=try api.prepareSMTP(row(11)),raw11=try db.restoredMailReviewSnapshot(t11.job),quarantine11=try db.metadata(NativeDatabase.restoredJobQuarantinePrefix+t11.job.id)!
        try rejects("cancellation after local effects rolls transaction back") {
            try db.reviewRestoredSMTP(t11.job,snapshot:raw11,quarantineValue:quarantine11,sent:true,now:clock.now,
                authorize:{_ = try q.requireReady();try service.authenticated()},localCopy:{job in
                    _ = try NativeMailDelivery.recordLocalCopy(db:db,current:job,now:clock.now);throw CancellationError()
                })
        }
        try check(try db.restoredMailReviewSnapshot(t11.job).digestMaterial==raw11.digestMaterial && db.mailSendPayload(t11.job.id)!["mime"] != .null,"cancel after local insert retains old job and MIME")
        try check(try db.page("Email",fields:[],equal:["rfcMessageId":.text(t11.job.payload["messageID"]!)],limit:1).rows.isEmpty,"cancel removes local Email insert")
        for n in 5...12 {_ = try api.recordSMTP(api.prepareSMTP(row(n)),outcome:.unknownHeld,note:"結果不明の旧メールを保留し、新しい送信だけ利用する")}
        try check(try !ambiguous(),"all exact held receipts allow future-only SMTP prerequisite")
        let prerequisite=try NativePersonalRuntimePrerequisites(service:service,startup:startup,personal:opened.record,stores:stores(db,Secrets()),clock:{clock.now})
        let prompt=try prerequisite.inspect(.imapSMTPAccountsAndCursors)
        _ = try prerequisite.review(prompt,choice:.continueReviewed,confirmedSubject:prompt.subjectSHA256)
        let evidence=try prerequisite.verify(.imapSMTPAccountsAndCursors,nil,service)
        try check(evidence.requirement == .imapSMTPAccountsAndCursors,"actual prerequisite admits explicitly held old SMTP")
        try rejects("ordinary review cannot alter old job"){try service.reviewMailSend(try db.job(id:id(5))!,sent:false)}
        try check(try db.claimJob(events:[NativeMailDelivery.event],now:clock.now)==nil,"held and confirmed old IDs never re-claimed")
        let currentAccount=try service.mailAccount(accountID),newID=try service.queueMailSend(account:currentAccount,draft:.init(to:["new@example.invalid"],subject:"別の新規メール",body:"新しい明示操作"),now:clock.now)
        let newJob=try db.claimJob(events:[NativeMailDelivery.event],now:clock.now)!
        try check(newJob.id==newID && newJob.payload["messageID"] != t1.job.payload["messageID"],"fresh explicit send uses new job and Message-ID")
        try check(try !ambiguous(),"new-job progress does not invalidate old acknowledgement")
        try check(try prerequisite.verify(.imapSMTPAccountsAndCursors,evidence,service)==evidence,"actual stable approval survives new job")
        do {
            let reopened=try f.db(f.candidate),current=CRMService(db:reopened,identity:opened.identity)
            let cold=try NativePersonalRestoredJobQuarantine(service:current,startup:startup,record:opened.record);_ = try cold.attach()
            try check(try !NativePersonalSMTPReview.hasAmbiguous(service:current,startup:startup,record:opened.record),"cold attach retains exact held receipt")
            try check(try reopened.claimJob(events:[NativeMailDelivery.event],now:clock.now)==nil,"cold attach cannot claim old IDs or live new lease")
        }
        let receiptKey=NativePersonalSMTPReview.key(generation:opened.record.authority.selection.generation,id:try id(11)),savedReceipt=try db.metadata(NativePersonalSMTPReview.key(generation:opened.record.authority.selection.generation,id:try id(11)))!
        var wrong=try JSONSerialization.jsonObject(with:Data(savedReceipt.utf8)) as! [String:Any];wrong["bindingSHA256"]=String(repeating:"0",count:64)
        try db.setMetadata(receiptKey,value:String(decoding:try JSONSerialization.data(withJSONObject:wrong),as:UTF8.self))
        try check(try ambiguous(),"wrong restoration binding receipt cannot exempt old row")
        try rejects("actual prerequisite rejects wrong binding"){_ = try prerequisite.verify(.imapSMTPAccountsAndCursors,evidence,service)}
        wrong["bindingSHA256"]=try NativePersonalSMTPReview.read(db:db,generation:opened.record.authority.selection.generation,id:try id(10))!.bindingSHA256
        wrong["generation"]=UUID().uuidString.lowercased()
        try db.setMetadata(receiptKey,value:String(decoding:try JSONSerialization.data(withJSONObject:wrong),as:UTF8.self))
        try rejects("wrong generation acknowledgement"){_ = try ambiguous()}
        try db.setMetadata(receiptKey,value:savedReceipt)
        let mutateID=try id(12);try raw(db,"UPDATE native_outbox SET completed_at='raw-mutated' WHERE id='"+mutateID+"'")
        try check(try ambiguous(),"changed raw old row invalidates exact acknowledgement")
        try rejects("actual prerequisite rejects modified old raw row"){_ = try prerequisite.verify(.imapSMTPAccountsAndCursors,evidence,service)}
        // Real ordinary SMTP domain proof, isolated from the restored database.
        let ordinary=try f.db(f.base.appendingPathComponent("ordinary"))
        _ = try ordinary.insert("Users",values:["id":.text(owner),"email":.text("ordinary@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:owner)
        let oa=try addAccount(ordinary),os=CRMService(db:ordinary,identity:.init(id:owner,role:"admin",partnerAccountID:nil))
        let ordinaryID=try os.queueMailSend(account:oa,draft:.init(to:["x@example.invalid"],subject:"通常確認",body:"通常本文"),now:clock.now)
        let claim=try ordinary.claimJob(events:[NativeMailDelivery.event],now:clock.now)!,started=try ordinary.markJobDeliveryStarted(claim,now:clock.now)
        try ordinary.failJob(started,message:"模擬不明",needsReview:true);try os.reviewMailSend(try ordinary.job(id:ordinaryID)!,sent:true,now:clock.now)
        let spy=Secrets();var sends=0
        let worker=NativeMailSendWorker(db:ordinary,store:spy,send:{_ in sends += 1;throw NativeDBError.conflict},clock:{clock.now})
        let didRun=try await worker.runNext();try check(didRun,"ordinary accepted local reconcile executed")
        try check(sends==0 && spy.reads==0 && ordinary.job(id:ordinaryID)?.status=="done","ordinary known-accepted does not call provider or Keychain")
        let ordinaryID2=try os.queueMailSend(account:oa,draft:.init(to:["x@example.invalid"],subject:"通常未送信",body:"本文"),now:clock.now)
        let claim2=try ordinary.claimJob(events:[NativeMailDelivery.event],now:clock.now)!,started2=try ordinary.markJobDeliveryStarted(claim2,now:clock.now)
        try ordinary.failJob(started2,message:"不明",needsReview:true);try os.reviewMailSend(try ordinary.job(id:ordinaryID2)!,sent:false,now:clock.now)
        try os.retryMailSend(try ordinary.job(id:ordinaryID2)!)
        try check(try ordinary.job(id:ordinaryID2)?.status=="pending","ordinary non-restored notSent retry remains available")
        api.close();panel.window.orderOut(nil);p3.window.orderOut(nil)
    }
}
