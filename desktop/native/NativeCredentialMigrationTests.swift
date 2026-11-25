import Foundation
import CryptoKit
import SQLite3
import Darwin

final class MigrationFakeVault:NativeCredentialMigrationVault {
    let namespace:String
    var values:[String:(NativeCredentialMigrationLease?,Data)]=[:],inserts=0,removes=0
    var afterInsert:(()throws->Void)?,failRemove=false
    init(_ namespace:String){self.namespace=namespace}
    func key(_ family:NativeCredentialMigrationFamily,_ id:String)->String{family.rawValue+"/"+id}
    func insert(_ lease:NativeCredentialMigrationLease,data:Data)throws {
        guard lease.namespace==namespace,values[key(lease.family,lease.id)]==nil else{throw NativeCredentialMigrationFailure.conflict}
        inserts+=1;values[key(lease.family,lease.id)]=(lease,data);try afterInsert?()
    }
    func load(_ family:NativeCredentialMigrationFamily,id:String)throws->Data?{values[key(family,id)]?.1}
    func removeCreated(_ lease:NativeCredentialMigrationLease)throws {
        if failRemove{throw NativeCredentialMigrationFailure.cleanup}
        let k=key(lease.family,lease.id);guard let old=values[k] else{return}
        guard old.0==lease,NativeCredentialMigrationEnvelope.hash(old.1)==lease.payloadSHA256 else{return}
        removes+=1;values.removeValue(forKey:k)
    }
}
final class MigrationLegacyInvoice:InvoiceMailCredentialStore {
    var account:InvoiceMailAccount? = .init(from:"old@fixture.invalid",apiKey:"synthetic-legacy-backup-key")
    var saves=0,removes=0,loads=0
    func load(interactive:Bool)throws->InvoiceMailAccount?{loads+=1;return account}
    func save(_ account:InvoiceMailAccount)throws{saves+=1;self.account=account}
    func remove()throws{removes+=1;account=nil}
}
@main enum NativeCredentialMigrationTests {
    static var checks=0
    static let admin="e7000000-0000-4000-8000-000000000001",user="e7000000-0000-4000-8000-000000000002"
    static func check(_ condition:@autoclosure()throws->Bool,_ label:String)throws{guard try condition() else{fputs("Synthetic check failed: \(label)\n",stderr);throw NativeCredentialMigrationFailure.conflict};checks+=1}
    static func reject(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};fputs("Unexpected acceptance: \(label)\n",stderr);throw NativeCredentialMigrationFailure.conflict}
    static func hex(_ text:String)->Data{Data(stride(from:0,to:text.count,by:2).map{i in let a=text.index(text.startIndex,offsetBy:i);return UInt8(text[a..<text.index(a,offsetBy:2)],radix:16)!})}
    static func seed(_ root:URL,_ resources:URL)throws->(CRMService,MigrationFakeVault) {
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        _ = try db.insert("Users",values:["id":.text(admin),"email":.text("admin@migration.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:admin)
        _ = try db.insert("Users",values:["id":.text(user),"email":.text("user@migration.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:admin)
        return (CRMService(db:db,identity:.init(id:admin,role:"admin",partnerAccountID:nil)),MigrationFakeVault(NativeCredentialMigration.namespace(db)))
    }
    static func row(_ service:CRMService,_ entry:NativeCredentialMigrationEnvelope.Entry)throws->NativeRecord {
        let db=service.db,key=entry.owner.key.mapValues(SQLValue.text)
        if let old=try db.get(entry.owner.model,key:key){return old}
        var values=key;values[entry.owner.field] = .text("")
        switch entry.owner.model {
        case "ApiKeys":values.merge(["scope":.text("SYSTEM"),"provider":.text("OPENAI")]){$1}
        case "EmailAccount":values.merge(["userId":.text(user),"label":.text("合成メール"),"imapHost":.text("imap.fixture.invalid"),"imapPort":.integer(993),"smtpHost":.text("smtp.fixture.invalid"),"smtpPort":.integer(465),"username":.text("user@fixture.invalid")]){$1}
        case "InstalledPlugin":values.merge(["version":.text("1.0.0"),"settings":.text("{}")]){$1}
        case "CalendarConnection":values.merge(["userId":.text(user),"provider":.text("google"),"accountEmail":.text("user@fixture.invalid"),"refreshTokenEncrypted":.text(""),"accessTokenEncrypted":.null,"scopeLevel":.text("readonly"),"tokenExpiresAt":.text("2026-11-20T12:30:00.000Z")]){$1}
        case "systemServices":values.merge(["v":.integer(0),"name":.text("resend_smtp")]){$1}
        case "crm_SystemSettings":break
        default:throw NativeCredentialMigrationFailure.unsupported
        }
        return try db.insert(entry.owner.model,values:values,actor:admin)
    }
    static func object(_ data:Data)throws->[String:Any]{try JSONSerialization.jsonObject(with:data) as! [String:Any]}
    static func reference(_ result:NativeCredentialMigrationResult)throws->String{switch result{case let .applied(v),let .alreadyApplied(v):return v;case .held:throw NativeCredentialMigrationFailure.unsupported}}
    static func sql(_ db:NativeDatabase,_ query:String)throws{var handle:OpaquePointer?;guard sqlite3_open(db.url.path,&handle)==SQLITE_OK else{throw NativeCredentialMigrationFailure.unavailable};defer{sqlite3_close(handle)};guard sqlite3_exec(handle,query,nil,nil,nil)==SQLITE_OK else{throw NativeCredentialMigrationFailure.unavailable}}
    static func backup(_ source:URL,_ destination:URL)throws{var s:OpaquePointer?,d:OpaquePointer?;guard sqlite3_open_v2(source.path,&s,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(destination.path,&d)==SQLITE_OK else{throw NativeCredentialMigrationFailure.unavailable};defer{sqlite3_close(s);sqlite3_close(d)};guard let copy=sqlite3_backup_init(d,"main",s,"main"),sqlite3_backup_step(copy,-1)==SQLITE_DONE,sqlite3_backup_finish(copy)==SQLITE_OK else{throw NativeCredentialMigrationFailure.unavailable}}
    static func main()async {
        do {
            umask(0o077);let resources=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=URL(fileURLWithPath:CommandLine.arguments[2]),root=URL(fileURLWithPath:CommandLine.arguments[3]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let f=try object(Data(contentsOf:fixture.appendingPathComponent("handoff-fixture.json"))),source=try object(Data(contentsOf:fixture.appendingPathComponent("reference.json"))),key=hex(source["handoffKeyHex"] as! String),serverKey=hex(source["serverKeyHex"] as! String)
            let descriptor=try JSONDecoder().decode(NativeCredentialMigrationDescriptor.self,from:JSONSerialization.data(withJSONObject:f["descriptor"]!)),reader=try NativeCredentialMigrationEnvelope(root:fixture.appendingPathComponent("handoff"),descriptor:descriptor,key:key,schemaSHA256:f["schemaSHA256"] as! String,snapshotID:f["snapshotID"] as! String)
            var entries:[(NativeCredentialMigrationEnvelope.Entry,Data)]=[];try reader.forEach{entries.append(($0,$1))} // bounded 12-entry synthetic fixture only
            let (service,vault)=try seed(root.appendingPathComponent("first"),resources),migration=try NativeCredentialMigration(service:service,vault:vault)
            var references:[String:String]=[:]
            for index in [0,1,2] {
                let e=entries[index],before=try row(service,e.0),result=try migration.migrate(e.0,original:e.1,expected:before,serverKey:serverKey),ref=try reference(result),family:NativeCredentialMigrationFamily=index==0 ? .ai:index==1 ? .email:.plugin,id=String(ref.dropFirst(family.prefix.count)),payload=try object(vault.load(family,id:id)!)
                references[before.model]=ref
                try check(ref.hasPrefix(family.prefix)&&UUID(uuidString:id) != nil,"fresh purpose reference");try check(try service.db.get(before.model,key:e.0.owner.key.mapValues(SQLValue.text))?[e.0.owner.field] == .text(ref),"reference published")
                if index==0 {try check(payload["recordID"] as? String==before["id"].string&&payload["scope"] as? String=="SYSTEM"&&payload["provider"] as? String=="OPENAI"&&payload["ownerID"]==nil,"AI owner/scope binding");try check(payload["key"] as? String=="synthetic-openai-key","AI original decrypted")}
                if index==1 {try check(payload["password"] as? String=="合成メールパスワード"&&payload["version"] as? Int==1,"Email native format")}
                if index==2 {try check((payload["unknownBusiness"] as? [String:Any])?["note"] as? String=="保持する","Unknown plugin business preserved")}
                let current=try row(service,e.0),count=vault.inserts
                try check(try migration.migrate(e.0,original:e.1,expected:current,serverKey:serverKey) == .alreadyApplied(ref),"retry idempotence")
                try check(vault.inserts==count,"retry creates no extra secret")
            }
            let invoice=entries[3],invoiceRow=try row(service,invoice.0);var options=NativeCredentialMigrationOptions();options.resendSender="billing@fixture.invalid";options.resendServiceID=invoiceRow["id"].string
            try check(try migration.migrate(invoice.0,original:invoice.1,expected:invoiceRow,serverKey:serverKey,options:options) == .held("invoice-destination-binding"),"legacy singleton never overwritten")
            options.legacyInvoiceConfigured={false};let invoiceRef=try reference(migration.migrate(invoice.0,original:invoice.1,expected:invoiceRow,serverKey:serverKey,options:options)),invoicePayload=try object(migration.invoicePayload()!)
            try check(invoiceRef.hasPrefix(NativeCredentialMigrationFamily.invoice.prefix),"invoice immutable ID");try check(invoicePayload["from"] as? String=="billing@fixture.invalid"&&invoicePayload["apiKey"] as? String=="synthetic-resend-key","invoice bridge source value")
            let old=entries[4],oldRow=try row(service,old.0);options.resendServiceID=oldRow["id"].string
            try reject("second service cannot replace configured destination"){_ = try migration.migrate(old.0,original:old.1,expected:oldRow,serverKey:serverKey,options:options)}
            let google=try row(service,entries[5].0)
            try check(try migration.migrateGoogle(google,refresh:entries[5],access:entries[6],serverKey:serverKey,options:.init()) == .held("google-related-token-and-client-required"),"no invented OAuth client")
            options.google = .init(clientID:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic-client-secret")
            let googleRef=try reference(migration.migrateGoogle(google,refresh:entries[5],access:entries[6],serverKey:serverKey,options:options)),googleData=try object(vault.load(.google,id:String(googleRef.dropFirst(NativeCredentialMigrationFamily.google.prefix.count)))!)
            try check(googleData["connectionID"] as? String==google["id"].string&&googleData["userID"] as? String==user,"Google connection/user binding")
            let grant=googleData["grant"] as! [String:Any];try check(grant["refreshToken"] as? String=="synthetic-refresh-token"&&grant["accessToken"] as? String=="synthetic-access-token","Google original pair")
            try check(try row(service,entries[5].0)["accessTokenEncrypted"] == .null,"Google two source fields become one native bundle")
            let token=try row(service,entries[7].0),signing=try row(service,entries[8].0)
            try check(try migration.migrateCalendly(token:(token,entries[7].0,entries[7].1),signing:(signing,entries[8].0,entries[8].1),serverKey:serverKey,options:.init()) == .held("calendly-pair-and-relay-required"),"no invented receiver")
            let client="e7000000-0000-4000-8000-000000000090",instance="e7000000-0000-4000-8000-000000000091",url="https://relay.fixture.invalid/"
            options.calendly = .init(publicURL:url,clientID:client,instanceID:instance,authKey:String(repeating:"A",count:43))
            try service.db.setMetadata("calendlyRelay.clientID.v1",value:client);try service.db.setMetadata("calendlyRelay.binding.v1",value:String(decoding:JSONSerialization.data(withJSONObject:["clientID":client,"instanceID":instance,"publicURL":url,"cursor":0]),as:UTF8.self))
            let calRef=try reference(migration.migrateCalendly(token:(token,entries[7].0,entries[7].1),signing:(signing,entries[8].0,entries[8].1),serverKey:serverKey,options:options))
            try check(try row(service,entries[7].0)["value"] == .text(calRef)&&row(service,entries[8].0)["value"] == .text(calRef),"Calendly two rows atomically bind same item")
            try check(try service.db.metadata("calendly.control.v1")?.contains(String(calRef.dropFirst(NativeCredentialMigrationFamily.calendly.prefix.count)))==true,"Calendly active reference bound")
            let calCount=vault.inserts
            try check(try migration.migrateCalendly(token:(row(service,entries[7].0),entries[7].0,entries[7].1),signing:(row(service,entries[8].0),entries[8].0,entries[8].1),serverKey:serverKey,options:options) == .alreadyApplied(calRef),"Calendly replay recognizes exact current binding")
            try check(vault.inserts==calCount,"Calendly replay creates no extra item")
            try check(vault.removes==0,"successful migration never deletes previous/source keys")
            // Actual SQLite trigger forces failure after vault insertion, before publication.
            for (label,afterInsert,removeFails) in [("sql",false,false),("ambiguous-insert",true,false),("pending-cleanup",false,true)] {
                let (s,v)=try seed(root.appendingPathComponent(label),resources),m=try NativeCredentialMigration(service:s,vault:v),e=entries[0],r=try row(s,e.0);v.failRemove=removeFails
                if afterInsert {v.afterInsert={throw NativeCredentialMigrationFailure.unavailable}} else {try sql(s.db,"CREATE TRIGGER stop_secret BEFORE UPDATE ON ApiKeys BEGIN SELECT RAISE(ABORT,'synthetic-publication'); END")}
                try reject(label){_ = try m.migrate(e.0,original:e.1,expected:r,serverKey:serverKey)}
                try check(try row(s,e.0).values==r.values,"failed publication row unchanged")
                if removeFails {try check(v.values.count==1,"failed cleanup keeps owned item and journal");try check(try s.db.metadata(NativeCredentialMigration.pendingKey)?.contains("payloadSHA256")==true,"nonsecret retry receipt survives");v.failRemove=false;try check(try m.retryPendingCleanup()==1&&v.values.isEmpty,"retry removes only created item")}
                else {try check(v.values.isEmpty&&v.removes==1,"failure cleanup owned item only")}
            }
            let (revoked,revokedVault)=try seed(root.appendingPathComponent("revoked"),resources),revokedMigration=try NativeCredentialMigration(service:revoked,vault:revokedVault),r=try row(revoked,entries[0].0)
            revokedVault.afterInsert={let u=try revoked.db.get("Users",key:["id":.text(admin)])!;_ = try revoked.db.update(u,changes:["role":.text("user")],actor:admin)}
            try reject("fresh authority after vault"){_ = try revokedMigration.migrate(entries[0].0,original:entries[0].1,expected:r,serverKey:serverKey)}
            try check(revokedVault.values.count==1&&revokedVault.removes==0,"revoked authority cannot delete keys during cleanup")
            try check(try row(revoked,entries[0].0).values==r.values,"revoked update refused")
            let reauth=try revoked.db.get("Users",key:["id":.text(admin)])!;_ = try revoked.db.update(reauth,changes:["role":.text("admin")],actor:admin);try check(try revokedMigration.retryPendingCleanup()==1&&revokedVault.values.isEmpty,"fresh admin can finish deferred cleanup")
            // Real backup, new namespace, fresh immutable ID, source key stays available.
            let backupURL=root.appendingPathComponent("restored/crm.sqlite");try FileManager.default.createDirectory(at:backupURL.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try backup(service.db.url,backupURL)
            let targetDB=try NativeDatabase(url:backupURL,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),targetService=CRMService(db:targetDB,identity:service.identity),targetVault=MigrationFakeVault(NativeCredentialMigration.namespace(targetDB)),restored=try NativeCredentialMigration(service:targetService,vault:targetVault),beforeBackup=try row(targetService,entries[0].0)
            let oldRef=beforeBackup["encryptedKey"].string,newRef=try reference(restored.rebindNativeBackup(beforeBackup,field:"encryptedKey",family:.ai,sourceNamespace:vault.namespace,sourceVault:vault,authorizeSource:{try service.authenticated()}))
            try check(oldRef != newRef&&vault.namespace != targetVault.namespace,"restored path gets new namespace and fresh ID")
            try check(try vault.load(.ai,id:String(oldRef.dropFirst(NativeCredentialMigrationFamily.ai.prefix.count))) != nil&&vault.removes==0,"source and old backup credential preserved")
            try check(try vault.load(.ai,id:String(oldRef.dropFirst(NativeCredentialMigrationFamily.ai.prefix.count))) == targetVault.load(.ai,id:String(newRef.dropFirst(NativeCredentialMigrationFamily.ai.prefix.count))),"native backup payload exact")
            for (index,family,field) in [(1,NativeCredentialMigrationFamily.email,"passwordEncrypted"),(2,.plugin,"secrets"),(5,.google,"refreshTokenEncrypted"),(3,.invoice,"serviceKey")] {
                let before=try row(targetService,entries[index].0),old=before[field].string,new=try reference(restored.rebindNativeBackup(before,field:field,family:family,sourceNamespace:vault.namespace,sourceVault:vault,authorizeSource:{try service.authenticated()}))
                try check(old != new,"backup family fresh ID")
                try check(try vault.load(family,id:String(old.dropFirst(family.prefix.count)))==targetVault.load(family,id:String(new.dropFirst(family.prefix.count))),"backup family exact payload")
            }
            let restoredInvoice=try restored.rebindInvoiceBackup(sourceNamespace:vault.namespace,sourceVault:vault,authorizeSource:{try service.authenticated()})
            try check(restoredInvoice != String(invoiceRef.dropFirst(NativeCredentialMigrationFamily.invoice.prefix.count)),"invoice backup fresh ID")
            try check(try restored.invoicePayload()==migration.invoicePayload(),"invoice backup active payload")
            let backupCalToken=try row(targetService,entries[7].0),backupCalSigning=try row(targetService,entries[8].0)
            let reboundCal=try reference(restored.rebindCalendlyBackup(token:backupCalToken,signing:backupCalSigning,sourceNamespace:vault.namespace,sourceVault:vault,authorizeSource:{try service.authenticated()}))
            try check(reboundCal != calRef,"Calendly backup fresh ID")
            try check(try row(targetService,entries[7].0)["value"] == .text(reboundCal)&&row(targetService,entries[8].0)["value"] == .text(reboundCal),"backup pair stays atomic")
            try check(vault.removes==0,"all source namespace keys preserved")
            // The same encrypted source archive can be applied independently.
            let (third,thirdVault)=try seed(root.appendingPathComponent("third-namespace"),resources),thirdM=try NativeCredentialMigration(service:third,vault:thirdVault),thirdRow=try row(third,entries[0].0)
            let thirdRef=try reference(thirdM.migrate(entries[0].0,original:entries[0].1,expected:thirdRow,serverKey:serverKey))
            try check(thirdRef != oldRef&&thirdRef != newRef&&thirdVault.namespace != vault.namespace,"encrypted source independent destination")
            // Existing settings consumers use the bridge without a silent legacy fallback.
            let legacy=MigrationLegacyInvoice(),bridge=NativeCredentialMigrationInvoiceBridge(service:service,vault:vault,legacy:legacy),legacyKey=legacy.account!.apiKey
            try check(try bridge.load(interactive:false)?.apiKey=="synthetic-resend-key"&&legacy.loads==0,"bridge reads immutable active setting")
            let oldCount=vault.values.count
            try service.saveInvoiceMailSettings(from:"new@fixture.invalid",apiKey:"synthetic-next-key",store:bridge)
            try check(try bridge.load(interactive:false)?.from=="new@fixture.invalid"&&vault.values.count==oldCount+1,"settings consumer creates new immutable item")
            try service.saveInvoiceMailSettings(from:"again@fixture.invalid",apiKey:"",store:bridge)
            try check(try bridge.load(interactive:false)?.apiKey=="synthetic-next-key","empty key retains current immutable payload")
            try service.removeInvoiceMailSettings(store:bridge)
            try check(try bridge.load(interactive:false)==nil,"remove publishes disabled tombstone")
            try check(legacy.loads==0&&legacy.removes==0&&legacy.saves==0&&legacy.account?.apiKey==legacyKey&&vault.removes==0,"legacy/source/backup items never overwritten or erased")
            try service.saveInvoiceMailSettings(from:"restored@fixture.invalid",apiKey:"synthetic-restored-key",store:bridge)
            try check(try bridge.load(interactive:false)?.apiKey=="synthetic-restored-key","save after disabled creates fresh item")
            let freshLegacy=MigrationLegacyInvoice(),freshBridge=NativeCredentialMigrationInvoiceBridge(service:third,vault:thirdVault,legacy:freshLegacy)
            try check(try freshBridge.load(interactive:false)?.apiKey==freshLegacy.account?.apiKey&&freshLegacy.loads==1,"legacy fallback only before binding exists")
            let binding=try service.db.metadata(NativeCredentialMigration.invoiceKey)
            try reject("metadata CAS"){_ = try migration.replaceInvoice(nil,expectedBinding:nil)}
            try check(try service.db.metadata(NativeCredentialMigration.invoiceKey)==binding,"metadata CAS leaves active item")
            let countBefore=vault.values.count
            vault.afterInsert={try service.db.setMetadata(NativeCredentialMigration.invoiceKey,value:"synthetic-concurrent-nonsecret")}
            try reject("invoice publication CAS"){try bridge.save(.init(from:"race@fixture.invalid",apiKey:"synthetic-race-key"))}
            try check(vault.values.count==countBefore,"invoice failed publication recovers newly created item only")
            vault.afterInsert=nil;try service.db.setMetadata(NativeCredentialMigration.invoiceKey,value:binding!)
            let (hookS,hookV)=try seed(root.appendingPathComponent("hook"),resources),hookM=try NativeCredentialMigration(service:hookS,vault:hookV),hookRow=try row(hookS,entries[0].0)
            var hookCalls=0;hookS.db.beforeRecordWrite={_,_,_,changes,_ in hookCalls+=1;return changes}
            _ = try reference(hookM.migrate(entries[0].0,original:entries[0].1,expected:hookRow,serverKey:serverKey))
            try check(hookCalls==0,"credential publication does not invoke business plugin hooks")
            let (cancelS,cancelV)=try seed(root.appendingPathComponent("cancel"),resources),cancelM=try NativeCredentialMigration(service:cancelS,vault:cancelV),cancelRow=try row(cancelS,entries[0].0)
            let cancellation=Task { ()throws->Void in
                cancelV.afterInsert={withUnsafeCurrentTask{$0?.cancel()}}
                _ = try cancelM.migrate(entries[0].0,original:entries[0].1,expected:cancelRow,serverKey:serverKey)
            }
            var wasCancelled=false;do{try await cancellation.value}catch{wasCancelled=true};try check(wasCancelled,"cancelled publication fails")
            try check(cancelV.inserts==1&&cancelV.values.isEmpty&&cancelV.removes==1,"cancel after insert completes owned cleanup")
            let (foreignS,foreignV)=try seed(root.appendingPathComponent("foreign-replacement"),resources),foreignM=try NativeCredentialMigration(service:foreignS,vault:foreignV),foreignRow=try row(foreignS,entries[0].0)
            foreignV.afterInsert={let k=foreignV.values.keys.first!,data=foreignV.values[k]!.1;foreignV.values[k]=(nil,data);throw NativeCredentialMigrationFailure.unavailable}
            try reject("foreign receipt replacement"){_ = try foreignM.migrate(entries[0].0,original:entries[0].1,expected:foreignRow,serverKey:serverKey)}
            try check(foreignV.values.count==1&&foreignV.removes==0,"cleanup never removes replacement not owned by receipt")
            let (casS,casV)=try seed(root.appendingPathComponent("row-cas"),resources),casM=try NativeCredentialMigration(service:casS,vault:casV),casRow=try row(casS,entries[0].0)
            casV.afterInsert={_ = try casS.db.update(casRow,changes:["provider":.text("FIRECRAWL")],actor:admin)}
            try reject("row changed after insert"){_ = try casM.migrate(entries[0].0,original:entries[0].1,expected:casRow,serverKey:serverKey)}
            try check(casV.values.isEmpty&&casV.removes==1&&row(casS,entries[0].0)["provider"] == .text("FIRECRAWL"),"row CAS preserves unrelated change and cleans only new item")
            let wrong=MigrationFakeVault("not-this-database");try reject("wrong destination namespace"){_ = try NativeCredentialMigration(service:targetService,vault:wrong)};try check(wrong.inserts==0,"wrong namespace no side effect")
            let sealed=root.appendingPathComponent("sealed.sqlite");try backup(service.db.url,sealed);let bytes=try Data(contentsOf:sealed),readDB=try NativeDatabase(readOnlyURL:sealed,schemaURL:resources.appendingPathComponent("schema.json")),readService=CRMService(db:readDB,identity:service.identity),readVault=MigrationFakeVault(NativeCredentialMigration.namespace(readDB));try reject("readonly before vault"){_ = try NativeCredentialMigration(service:readService,vault:readVault)};try check(readVault.inserts==0&&readVault.removes==0&&Data(contentsOf:sealed)==bytes,"readonly unchanged")
            for secret in ["synthetic-openai-key","合成メールパスワード","synthetic-resend-key","synthetic-client-secret","synthetic-refresh-token","synthetic-restored-key"] {try check(bytes.range(of:Data(secret.utf8))==nil,"SQLite backup contains no plaintext credential")}
            let readBridge=NativeCredentialMigrationInvoiceBridge(service:readService,vault:readVault,legacy:MigrationLegacyInvoice())
            try reject("readonly bridge save"){try readBridge.save(.init(from:"blocked@fixture.invalid",apiKey:"synthetic-no-save"))};try reject("readonly bridge remove"){try readBridge.remove()}
            try check(readVault.inserts==0&&readVault.removes==0&&Data(contentsOf:sealed)==bytes,"readonly bridge no key or DB mutation")
            let (tx,txVault)=try seed(root.appendingPathComponent("outer"),resources),txMigration=try NativeCredentialMigration(service:tx,vault:txVault),txRow=try row(tx,entries[0].0)
            try tx.db.transaction {try reject("outer transaction"){_ = try txMigration.migrate(entries[0].0,original:entries[0].1,expected:txRow,serverKey:serverKey)}}
            try check(txVault.inserts==0,"outer rejection has no secret writes")
            try check(try migration.invoicePayload() != nil,"immutable invoice bridge remains readable")
            print("{\"checks\":\(checks),\"families\":6,\"keychain\":false,\"network\":false}")
        }catch{fputs("Credential migration failed after \(checks): \(type(of:error))\n",stderr);exit(1)}
    }
}
