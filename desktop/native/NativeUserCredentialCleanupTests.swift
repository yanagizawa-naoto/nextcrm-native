import Foundation

@main enum NativeUserCredentialCleanupTests {
    typealias Cleanup = NativeUserCredentialCleanup
    final class Store: NativeMailSecretStore, GoogleCalendarSecretStore {
        var values: [String: Data] = [:], removed: [String] = [], loaded: [String] = []
        func load(id: String, interactive: Bool) throws -> Data? { loaded.append(id); return values[id] }
        func save(id: String, data: Data) throws { guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data }
        func remove(id: String) throws { removed.append(id); values.removeValue(forKey:id) }
    }
    final class Fixture {
        let db: NativeDatabase, admin: CRMService, owner: CRMService, other: CRMService
        let mail = Store(), google = Store(), now = Date(timeIntervalSince1970:1_800_000_000)
        var account: NativeRecord!, connection: NativeRecord!
        let resources: URL
        init(_ resources: URL, _ root: URL) throws {
            self.resources = resources
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            admin = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            func make(_ name:String, database:NativeDatabase, adminID:String)throws->CRMService {
                let row=try database.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:adminID)
                return CRMService(db:database,identity:.init(id:row["id"].string,role:"user",partnerAccountID:nil))
            }
            owner=try make("owner",database:db,adminID:admin.identity.id);other=try make("other",database:db,adminID:admin.identity.id)
            account=try owner.createMailAccount(.init(label:"仕事",username:"owner@example.invalid",imap:.init(host:"imap.example.invalid",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.invalid",port:587,tls:.startTLS)),password:"synthetic-mail-password",store:mail)
            try admin.saveGoogleCalendarClient(clientID:"synthetic.apps.googleusercontent.com",clientSecret:"synthetic-client-secret",store:google)
            let ticket=try owner.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:google)
            connection=try owner.completeGoogleCalendarAuthorization(ticket,grant:.init(accountEmail:"owner@example.invalid",accessToken:"synthetic-access",refreshToken:"synthetic-refresh",expiresAt:now.addingTimeInterval(3600),grantedScopes:GoogleCalendarScope.readwrite.requested),store:google)
        }
        var manager: NativeUserAdministration { .init(service:admin,clock:{self.now}) }
        var mailID: String { try! CRMService.mailCredentialID(account) }
        var googleID: String { GoogleCalendarStorage.itemID(connection["refreshTokenEncrypted"])! }
        func intentKey(_ family: Cleanup.Family, _ row: NativeRecord, _ field:String, _ id:String) -> String {
            Cleanup.referenceIntentKey(family,namespace:Cleanup.namespace(db),recordID:row["id"].string,field:field,credentialID:id)
        }
        func delete() throws { _ = try manager.delete(owner.identity.id) }
    }
    final class Receiver: NativeMailReceiving {
        var statusAction: (() throws -> Void)?, calls=0, discovered=0
        func status(mailbox: String) async throws -> (validity: UInt32, next: UInt32) { calls += 1;try statusAction?();return (1,1) }
        func discover(mailbox:String,validity:UInt32,after:UInt32,through:UInt32,since:Date?) async throws -> NativeMailUIDSpool { discovered += 1;throw NativeDBError.conflict }
        func headers(mailbox:String,validity:UInt32,uids:[UInt32]) async throws -> [NativeMailIMAPHeader] { throw NativeDBError.conflict }
        func body(mailbox:String,validity:UInt32,uid:UInt32) async throws -> NativeMailBody? { throw NativeDBError.conflict }
    }
    static var checks=0
    static func check(_ value:@autoclosure ()throws->Bool,_ name:String)throws { guard try value() else{throw NativeDBError.message(name)};checks+=1 }
    static func rejects(_ name:String,_ body:()throws->Void)throws { do{try body()}catch{checks+=1;return};throw NativeDBError.message("accepted "+name) }
    static func main() async { do{try await run()}catch{fputs("After \(checks): \(error)\n",stderr);exit(1)} }
    static func run() async throws {
        let n=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2]),baseline=CommandLine.arguments.contains("--baseline")
        let f=try Fixture(n,root.appendingPathComponent("main"))
        let mailKey=f.intentKey(.email,f.account,"passwordEncrypted",f.mailID),googleKey=f.intentKey(.google,f.connection,"refreshTokenEncrypted",f.googleID)
        let client=try f.admin.googleCalendarClientReference()!,clientData=f.google.values[client.id]
        try check(try f.owner.mailCredential(f.account,store:f.mail).password=="synthetic-mail-password","actual mail credential initially resolves")
        try check(try f.owner.googleCalendarGrant(f.connection,store:f.google).grant.refreshToken=="synthetic-refresh","actual google credential initially resolves")
        if baseline {
            try f.delete()
            try check(try f.db.get("EmailAccount",key:["id":f.account["id"]])==nil,"baseline mail cascade")
            try check(try f.db.get("CalendarConnection",key:["id":f.connection["id"]])==nil,"baseline google cascade")
            try check(try f.db.metadata(mailKey)==nil && f.db.metadata(googleKey)==nil,"baseline lost reference provenance")
            try check(f.mail.values[f.mailID] != nil && f.google.values[f.googleID] != nil,"baseline orphan fake secrets remain")
            try check(f.google.values[client.id]==clientData,"baseline shared client stays")
            try await disconnectRace(n,root.appendingPathComponent("disconnect"),baseline:true)
            print("{\"checks\":\(checks),\"reproducedCascadeReferenceLoss\":true,\"reproducedDisconnectRaceRemoval\":true}")
            return
        }
        let originalMail=f.account!,originalGoogle=f.connection!
        try rejects("outer rollback"){try f.db.transaction{try f.delete();try check(try f.db.metadata(mailKey) != nil && f.db.metadata(googleKey) != nil,"both intents inside delete transaction");throw NativeDBError.conflict}}
        try check(try f.db.get("EmailAccount",key:["id":originalMail["id"]]) != nil,"outer rollback mail row")
        try check(try f.db.get("CalendarConnection",key:["id":originalGoogle["id"]]) != nil,"outer rollback google row")
        try check(try f.db.metadata(mailKey)==nil && f.db.metadata(googleKey)==nil,"outer rollback removes both intents")
        try check(try !Cleanup.isHeld(db:f.db,family:.email,credentialID:f.mailID) && !Cleanup.isHeld(db:f.db,family:.google,credentialID:f.googleID),"outer rollback removes both holds")
        let report=try f.db.insert("crm_Report_Config",values:["name":.text("restrict"),"category":.text("accounts"),"filters":.text("{}"),"createdBy":.text(f.owner.identity.id)],actor:f.admin.identity.id)
        try rejects("FK restriction"){try f.delete()}
        try check(try f.db.metadata(mailKey)==nil && f.db.metadata(googleKey)==nil,"FK rejection rolls back all intents")
        try f.db.remove(report,actor:f.admin.identity.id)
        // Unrelated active account + duplicate refs are real DB relationships.
        let otherMail=try f.other.createMailAccount(.init(label:"別",username:"other@example.invalid",imap:.init(host:"imap.example.invalid",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.invalid",port:587,tls:.startTLS)),password:"synthetic-unrelated-mail",store:f.mail)
        let otherMailID=try CRMService.mailCredentialID(otherMail)
        var aliasValues=originalMail.values;aliasValues["id"] = .text(UUID().uuidString.lowercased());aliasValues["label"] = .text("alias")
        let alias=try f.db.insert("EmailAccount",values:aliasValues,actor:f.admin.identity.id)
        let extraID="ABCDEF12-3456-4789-ABCD-1234567890AB"
        f.connection=try f.db.update(f.connection,changes:["accessTokenEncrypted":.text(GoogleCalendarStorage.prefix+extraID)],actor:f.admin.identity.id)
        try f.google.save(id:extraID,data:Data("synthetic-legacy-native-access".utf8))
        let accessKey=f.intentKey(.google,f.connection,"accessTokenEncrypted",extraID)
        var legacyValues=originalMail.values;legacyValues["id"] = .text(UUID().uuidString.lowercased());legacyValues["passwordEncrypted"] = .text("legacy-opaque-secret"+String(repeating:"x",count:200_000))
        let legacy=try f.db.insert("EmailAccount",values:legacyValues,actor:f.admin.identity.id)
        let beforeURL=root.appendingPathComponent("before-backup"),before=NativeBackup().prepare(source:f.db,destinationURL:beforeURL)
        try check(before.candidateCreated && !before.keychainExported,"actual pre-delete backup")
        try f.delete()
        try check(try f.db.get("Users",key:["id":.text(f.owner.identity.id)])==nil,"actual owner deleted")
        for (family,row,field,id) in [(Cleanup.Family.email,originalMail,"passwordEncrypted",f.mailID),(.email,alias,"passwordEncrypted",f.mailID),(.google,originalGoogle,"refreshTokenEncrypted",f.googleID),(.google,f.connection!,"accessTokenEncrypted",extraID)] {
            let key=f.intentKey(family,row,field,id),raw=try f.db.metadata(key)!
            let saved=try JSONDecoder().decode(Cleanup.Intent.self,from:Data(raw.utf8))
            try check(saved.state=="reviewHeld" && saved.credentialID==id,"typed held intent exact id")
            try check(saved.sourceNamespaceSHA256==Cleanup.namespace(f.db),"source namespace retained")
            try check(saved.service==family.service && saved.sourceModel==family.model && saved.sourceField==field,"family and source field provenance")
            try check(try Cleanup.isHeld(db:f.db,family:family,credentialID:id),"matching family marker")
        }
        try check(try f.db.metadata(f.intentKey(.email,otherMail,"passwordEncrypted",otherMailID))==nil,"unrelated user untouched")
        try check(try f.db.metadata(f.intentKey(.email,legacy,"passwordEncrypted",f.mailID))==nil,"legacy ciphertext not persisted in metadata")
        try check(try !Cleanup.isHeld(db:f.db,family:.google,credentialID:client.id),"shared client has no user deletion hold")
        try check(f.google.values[client.id]==clientData,"shared client exact bytes preserved")
        try check(f.mail.values[otherMailID] != nil,"unrelated mail secret preserved")
        let mailLoads=f.mail.loaded.count,googleLoads=f.google.loaded.count
        try rejects("deleted mail access"){_ = try f.owner.mailCredential(originalMail,store:f.mail)}
        try rejects("deleted google access"){_ = try f.owner.googleCalendarGrant(originalGoogle,store:f.google)}
        try check(f.mail.loaded.count==mailLoads && f.google.loaded.count==googleLoads,"deleted owner rejected before store reads")
        let heldBytes=try f.db.metadata(mailKey)
        try check(try Cleanup.holdPersonalReferences(db:f.db,userID:f.owner.identity.id,actorID:f.admin.identity.id,now:f.now)==0,"rerun after cascade idempotent")
        try check(try f.db.metadata(mailKey)==heldBytes,"rerun retains original intent")
        try check(f.mail.removed.isEmpty && f.google.removed.isEmpty,"no cascade secret removal")
        try check(try !Cleanup.isHeld(db:f.db,family:.google,credentialID:f.mailID),"same ID never crosses provider service namespace")
        let reader=try NativeBackupSQLite(path:f.db.url.path,readOnly:true,cancelled:{false});var metadata=""
        try reader.rows("SELECT value FROM native_metadata WHERE key LIKE 'user.credentials.cleanup.%'",cancelled:{false}){metadata += ($0["value"] ?? nil) ?? ""}
        for secret in ["synthetic-mail-password","synthetic-access","synthetic-refresh","synthetic-client-secret","legacy-opaque-secret"] { try check(!metadata.contains(secret),"held metadata excludes raw secrets") }
        let afterURL=root.appendingPathComponent("after-backup"),after=NativeBackup().prepare(source:f.db,destinationURL:afterURL)
        try check(after.candidateCreated && !after.keychainExported,"actual post-delete backup")
        for (label,url) in [("before",beforeURL),("after",afterURL)] {
            let dest=root.appendingPathComponent("restored-"+label),result=NativeRestore().prepare(backupURL:url,schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"),destinationURL:dest)
            try check(result.candidateCreated && !result.keychainAccessed && !result.activated,"actual restore preparation "+label)
            let restored=try NativeDatabase(readOnlyURL:dest.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"))
            let plan=try String(contentsOf:dest.appendingPathComponent("resume-plan.ndjson"),encoding:.utf8).split(separator:"\n").map{try JSONDecoder().decode(NativeRestorePlanEntry.self,from:Data($0.utf8))}
            try check(Cleanup.namespace(restored) != Cleanup.namespace(f.db),"restored namespace requires binding")
            if label=="before" {
                try check(try restored.get("EmailAccount",key:["id":originalMail["id"]])?["passwordEncrypted"]==originalMail["passwordEncrypted"],"before backup exact mail ref")
                try check(try restored.get("CalendarConnection",key:["id":originalGoogle["id"]])?["refreshTokenEncrypted"]==originalGoogle["refreshTokenEncrypted"],"before backup exact google ref")
                try check(plan.contains{$0.kind=="credential" && $0.model=="EmailAccount" && $0.key==originalMail["id"].string},"actual pre-delete mail credential plan")
                try check(plan.contains{$0.kind=="credential" && $0.model=="CalendarConnection" && $0.key==originalGoogle["id"].string},"actual pre-delete google credential plan")
            } else {
                for key in [mailKey,googleKey,accessKey] { try check(try restored.metadata(key)==f.db.metadata(key),"restored held provenance exact");try check(plan.contains{$0.kind=="credentialCleanup" && $0.key==key},"actual held restore cleanup classification") }
                try check(try Cleanup.isHeld(db:restored,family:.email,credentialID:f.mailID) && Cleanup.isHeld(db:restored,family:.google,credentialID:f.googleID),"holds survive destination namespace change")
                try check(plan.contains{$0.kind=="serviceSetting" && $0.key==GoogleCalendarStorage.clientKey},"shared google client review retained")
            }
        }
        try await disconnectRace(n,root.appendingPathComponent("disconnect"),baseline:false)
        try await activeWorkers(n,root.appendingPathComponent("active"))
        try await heldRotation(n,root.appendingPathComponent("rotation"))
        try await heldPushRefresh(n,root.appendingPathComponent("push"))
        print("{\"checks\":\(checks),\"heldSecretDeletes\":0,\"realBackupPreparations\":2,\"realRestorePreparations\":2,\"externalRequests\":0}")
    }
    static func disconnectRace(_ n:URL,_ root:URL,baseline:Bool) async throws {
        let f=try Fixture(n,root),id=f.googleID;var intercepted=false
        f.db.afterRecordWrite={model,op,before,after,changes,actor in
            if model=="CalendarConnection",changes["isActive"] == .integer(0),!intercepted { intercepted=true;try? f.delete() }
        }
        try rejects("disconnect loses owner after inactive publication"){try f.owner.disconnectGoogleCalendar(f.connection,store:f.google)}
        f.db.afterRecordWrite=nil
        try check(intercepted && (try f.db.get("Users",key:["id":.text(f.owner.identity.id)]))==nil,"real interleaving deleted owner")
        try check((f.google.values[id] != nil) == !baseline,"disconnect cleanup respects committed hold")
        try check(f.google.removed.contains(id)==baseline,"disconnect physical removal difference")
        if !baseline { try check(try Cleanup.isHeld(db:f.db,family:.google,credentialID:id),"disconnect race durable marker") }
    }
    static func activeWorkers(_ n:URL,_ root:URL) async throws {
        let mail=try Fixture(n,root.appendingPathComponent("mail")),receiver=Receiver()
        _ = try mail.owner.requestMailSync(mail.account,now:mail.now)
        receiver.statusAction={try mail.delete()}
        let mw=NativeMailSyncWorker(db:mail.db,store:mail.mail,makeClient:{_,_ in receiver},clock:{mail.now})
        let mailRan=try await mw.runNext();try check(mailRan,"active mail job finished")
        try check(receiver.calls==1 && receiver.discovered==0,"post-await owner fence stops further mail discovery")
        try check(mail.mail.values[mail.mailID] != nil && mail.mail.removed.isEmpty,"active mail secret retained")
        let google=try Fixture(n,root.appendingPathComponent("google"));var requests=0
        _ = try google.owner.requestGoogleCalendarSync(google.connection,now:google.now)
        let worker=GoogleCalendarSyncWorker(db:google.db,store:google.google,request:{request in requests+=1;try google.delete();return (Data("{\"items\":[],\"nextSyncToken\":\"fake-token\"}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)},clock:{google.now})
        let ran=try await worker.runNext();try check(ran,"active google job finished")
        try check(requests==1,"post-await google owner fence stops additional calls")
        try check(google.google.values[google.googleID] != nil && google.google.removed.isEmpty,"active google secret retained")
        try check(try google.db.page("crm_CalendarEvents",fields:[]).total==0,"deleted owner imports no response events")
    }
    static func heldRotation(_ n:URL,_ root:URL) async throws {
        let f=try Fixture(n,root)
        // A deleted alias owned the same immutable mail reference. Real user
        // deletion records its hold while the surviving account stays usable.
        var values=f.account.values;values["id"] = .text(UUID().uuidString.lowercased());values["userId"] = .text(f.other.identity.id)
        _ = try f.db.insert("EmailAccount",values:values,actor:f.admin.identity.id)
        var google=f.connection.values;google["id"] = .text(UUID().uuidString.lowercased());google["userId"] = .text(f.other.identity.id)
        _ = try f.db.insert("CalendarConnection",values:google,actor:f.admin.identity.id)
        _ = try f.manager.delete(f.other.identity.id)
        let changed=try f.owner.replaceMailPassword(f.account,password:"replacement-mail",store:f.mail)
        try check(f.mail.values[f.mailID] != nil && !f.mail.removed.contains(f.mailID),"password rotation keeps held original")
        try check(try f.owner.mailCredential(changed,store:f.mail).password=="replacement-mail","new mail publication usable")
        try f.owner.deleteMailAccount(changed,store:f.mail)
        try check(f.mail.removed==[try CRMService.mailCredentialID(changed)],"ordinary unheld explicit mail cleanup still works")
        // Refresh invokes actual worker save/CAS/old-key cleanup, with fake HTTP.
        let old=f.googleID,stored=try f.owner.googleCalendarGrant(f.connection,store:f.google)
        let expired=GoogleCalendarStoredGrant(connectionID:stored.connectionID,userID:stored.userID,client:stored.client,grant:.init(accountEmail:stored.grant.accountEmail,accessToken:stored.grant.accessToken,refreshToken:stored.grant.refreshToken,expiresAt:f.now,grantedScopes:stored.grant.grantedScopes))
        f.google.values[old]=try JSONEncoder().encode(expired) // fixture clock-expiry setup; immutable production store is not changed.
        _ = try f.owner.requestGoogleCalendarSync(f.connection,now:f.now);var calls=0
        let worker=GoogleCalendarSyncWorker(db:f.db,store:f.google,request:{request in calls+=1;let text=request.url!.host=="oauth2.googleapis.com" ? "{\"access_token\":\"fresh-access\",\"token_type\":\"Bearer\",\"expires_in\":3600}" : "{\"items\":[],\"nextSyncToken\":\"next\"}";return(Data(text.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)},clock:{f.now})
        let ran=try await worker.runNext();try check(ran && calls==2,"actual refresh and sync fake requests")
        let current=try f.owner.googleCalendarConnection(f.connection["id"].string)
        try check(current["refreshTokenEncrypted"] != f.connection["refreshTokenEncrypted"],"refresh published new immutable ref")
        try check(f.google.values[old] != nil && !f.google.removed.contains(old),"worker rotation retained held previous grant")
        try check(try f.owner.googleCalendarGrant(current,store:f.google).grant.accessToken=="fresh-access","new google ref resolves")
        let freshID=GoogleCalendarStorage.itemID(current["refreshTokenEncrypted"])!
        try f.owner.disconnectGoogleCalendar(current,store:f.google)
        try check(f.google.removed==[freshID] && f.google.values[old] != nil,"normal disconnect removes only new unheld grant")
        try check(try f.db.get("CalendarConnection",key:["id":current["id"]])==nil,"normal disconnect still removes row")
    }
    static func heldPushRefresh(_ n:URL,_ root:URL) async throws {
        let f=try Fixture(n,root),old=f.googleID
        var alias=f.connection.values;alias["id"] = .text(UUID().uuidString.lowercased());alias["userId"] = .text(f.other.identity.id)
        _ = try f.db.insert("CalendarConnection",values:alias,actor:f.admin.identity.id)
        _ = try f.manager.delete(f.other.identity.id)
        let stored=try f.owner.googleCalendarGrant(f.connection,store:f.google)
        f.google.values[old]=try JSONEncoder().encode(GoogleCalendarStoredGrant(connectionID:stored.connectionID,userID:stored.userID,client:stored.client,grant:.init(accountEmail:stored.grant.accountEmail,accessToken:stored.grant.accessToken,refreshToken:stored.grant.refreshToken,expiresAt:f.now,grantedScopes:stored.grant.grantedScopes)))
        let activity=try f.db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text("test"),"date":.text(try NativeCalendarEvents.stamp(f.now.addingTimeInterval(3600))),"status":.text("scheduled"),"createdBy":.text(f.owner.identity.id),"duration":.integer(30)],actor:f.owner.identity.id)
        _ = try f.db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activity["id"].string,"operation":"upsert"],now:f.now)
        var calls=0
        let worker=GoogleCalendarPushWorker(db:f.db,store:f.google,request:{request in
            calls+=1;let refresh=request.url!.host=="oauth2.googleapis.com"
            let body=refresh ? "{\"access_token\":\"push-refreshed\",\"token_type\":\"Bearer\",\"expires_in\":3600}" : "{\"error\":{}}"
            return(Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:refresh ? 200:503,httpVersion:nil,headerFields:nil)!)
        },clock:{f.now})
        let ran=try await worker.runNext();try check(ran && calls==2,"actual push refresh then fake read failure")
        let current=try f.owner.googleCalendarConnection(f.connection["id"].string)
        try check(current["refreshTokenEncrypted"] != f.connection["refreshTokenEncrypted"],"push worker publishes refreshed ref")
        try check(f.google.values[old] != nil && !f.google.removed.contains(old),"push worker keeps held previous ref")
        try check(try f.owner.googleCalendarGrant(current,store:f.google).grant.accessToken=="push-refreshed","push refreshed key resolves")
    }

}
