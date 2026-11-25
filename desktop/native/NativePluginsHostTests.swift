import Foundation
import SQLite3

enum NativePluginsHostTests {
    static var checks=0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws { checks+=1;guard try value() else { throw NativePluginError(message:"Host: "+name) } }
    static func rejects(_ name:String,_ body:() throws -> Void) throws {
        do { try body() } catch { checks+=1;return };throw NativePluginError(message:"Host accepted: "+name)
    }
    static func sql(_ db:NativeDatabase,_ text:String) throws {
        var connection:OpaquePointer?;guard sqlite3_open(db.url.path,&connection)==SQLITE_OK else { throw NativePluginError(message:"fixture SQL") };defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection,text,nil,nil,nil)==SQLITE_OK else { throw NativePluginError(message:"fixture SQL: "+String(cString:sqlite3_errmsg(connection))) }
    }
    static func run(_ resources:URL) async throws -> Int {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NativePluginsHost-"+UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin=NativePluginActor(type:.user,userId:identity.id,role:"admin"),now=try NativePluginJSON.date("2026-01-01T00:00:00.000Z")
        var calls:[String]=[],seen:[NativePluginAfterInput]=[],settingsSeen:[NativePluginRecord]=[],secretsMemory:[String:NativePluginRecord]=[:],secretSerial=0
        var first=NativePluginDefinition(id:"aa-test",name:"A",version:"0.2.0",sdk:"^0.2.0",description:"fixture",permissions:["accounts:read","accounts:write"])
        first.rules=[.init(entity:.account,operation:.beforeCreate,priority:20,handler:{ input,_ in calls.append("a");return .modify(["description":(input.data["description"] as? String ?? "")+"a"]) })]
        first.afters=[.init(entity:.account,operation:.created,handler:{ input,ctx in seen.append(input);settingsSeen.append(ctx.settings) })]
        var second=NativePluginDefinition(id:"zz-test",name:"Z",version:"0.1.0",sdk:"^0.2.0",description:"fixture")
        second.rules=[.init(entity:.account,operation:.beforeCreate,priority:10,handler:{ input,_ in calls.append("z");return .modify(["description":"z"]) })]
        var secret=NativePluginDefinition(id:"secret-test",name:"S",version:"0.1.0",sdk:"^0.2.0",description:"fixture")
        secret.secrets = .init(fields:[.init(key:"apiKey",kind:.string,validate:{ ($0 as? String)?.isEmpty == false })])
        let store=NativePluginSecretStore(read:{ guard let value=secretsMemory[$0] else { throw NativePluginError(message:"missing key") };return value },write:{ _,value in secretSerial+=1;let ref="fixture-key-\(secretSerial)";secretsMemory[ref]=value;return ref },remove:{ secretsMemory.removeValue(forKey:$0) })
        let host=try NativePluginHost(db:db,definitions:[first,second,secret,NativeAccountProtection.definition()],secretStore:store,clock:{now},locale:"en",sendNotification:{ _,_,_ in },transport:{ _ ,_ in throw NativePluginError(message:"No network") })
        host.attach()
        try host.install(first.id,actor:admin,settings:[:],secrets:[:]);try host.install(second.id,actor:admin,settings:[:],secrets:[:])
        try check(try host.enabled().count==2,"enabled registry")
        let token=NativePluginActor(type:.token,userId:identity.id,role:"admin")
        let created=try NativePluginActorScope.withActor(token) { try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("New")],actor:identity.id) }
        try check(calls==["z","a"] && created["description"] == .text("za"),"priority order and shallow patches")
        let queued=try db.jobs(events:["plugin/after"]).first!
        _=try await host.runJob(queued)
        try check(seen.count==1 && seen[0].actor==token && seen[0].recordId==created["id"].string,"after preserves original token actor")
        try host.setEnabled(first.id,actor:admin,enabled:false)
        _=try await host.runJob(queued);try check(seen.count==1,"disabled queued hook skipped")
        try host.setEnabled(first.id,actor:admin,enabled:true)
        calls=[]
        _=try NativePluginActorScope.withActor(.plugin(first.id)) { try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Self")],actor:"plugin:"+first.id) }
        try check(calls==["z"],"self rules skipped")
        try rejects("depth guard") { try NativePluginActorScope.withActor(.plugin("p1")) { try NativePluginActorScope.withActor(.plugin("p2")) { try NativePluginActorScope.withActor(.plugin("p3")) { try NativePluginActorScope.withActor(.plugin("p4")) { _=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Deep")],actor:"plugin:p4") } } } } }
        var completions:[String]=[]
        try db.transaction {
            db.deferUntilTransactionEnds(onCommit:{completions.append("outer-commit")},onRollback:{completions.append("outer-rollback")})
            do { try db.transaction { db.deferUntilTransactionEnds(onCommit:{completions.append("inner-commit")},onRollback:{completions.append("inner-rollback")});throw NativePluginError(message:"fixture rollback") } } catch {}
            try check(completions.isEmpty,"callbacks postponed past nested rollback")
        }
        try check(completions==["outer-commit","inner-rollback"],"nested rollback callback after outer commit")
        let count=try db.jobs(events:["plugin/after"]).count
        try rejects("outer rollback") { try db.transaction { _=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Rolled back")],actor:identity.id);throw NativePluginError(message:"rollback") } }
        try check(try db.jobs(events:["plugin/after"]).count==count && db.page("crm_Accounts",fields:[],equal:["name":.text("Rolled back")]).total==0,"after outbox rolls back with outer record")
        try sql(db,"CREATE TRIGGER fixture_after_failure BEFORE INSERT ON native_outbox WHEN NEW.event='plugin/after' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        let accepted=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Queue failed, row saved")],actor:identity.id)
        try check(try db.get("crm_Accounts",key:["id":accepted["id"]]) != nil,"after enqueue failure does not undo record")
        try check(try db.page("PluginLog",fields:[],equal:["message":.text("Failed to enqueue after hook")]).total==1,"enqueue failure logged after transaction")
        try sql(db,"DROP TRIGGER fixture_after_failure")
        let local=NativePluginStore(db:db,pluginId:first.id,clock:{now})
        try local.forRecord(.account,created["id"].string).set("local",["data":1]);try local.set("history",["keep":true]);try db.remove(created,actor:identity.id)
        try check(try local.forRecord(.account,created["id"].string).get("local")==nil && local.get("history") != nil,"hard delete cleans record scopes, preserves globals")
        try local.set("cap",String(repeating:"x",count:256*1024-2));try rejects("store UTF8 cap") { try local.set("over",String(repeating:"x",count:256*1024-1)) }
        try check(try local.claim("lease",ms:1000),"first claim");try check(try !local.claim("lease",ms:1000),"claim excluded before expiry")
        let later=NativePluginStore(db:db,pluginId:first.id,clock:{now.addingTimeInterval(1)})
        try check(try later.claim("lease",ms:1000),"claim equality boundary")
        try local.set("broken",["until":"bad"]);try rejects("malformed claim") { _=try local.claim("broken",ms:1) }
        try host.install(secret.id,actor:admin,settings:[:],secrets:["apiKey":"fixture-secret-must-not-leak"])
        let secretState=try host.state(secret.id)!;try check(secretState["secrets"].string.hasPrefix("fixture-key-") && !secretState["settings"].string.contains("fixture-secret"),"opaque secrets only")
        try host.saveSettings(secret.id,actor:admin,settings:[:],secrets:["apiKey":""])
        let context=try host.context(secret,actor:admin);try check(context.secrets["apiKey"] as? String=="fixture-secret-must-not-leak","blank secret preserves stored key")
        context.log("warn","failure fixture-secret-must-not-leak",["key":"fixture-secret-must-not-leak"])
        let logs=try db.page("PluginLog",fields:["message","context"],equal:["pluginId":.text(secret.id)]).rows
        try check(!logs.contains { $0["message"].string.contains("fixture-secret-must-not-leak") || $0["context"].string.contains("fixture-secret-must-not-leak") },"secrets redacted from persistent logs")
        try check(try !NativePluginJSON.text(host.export(secret.id,actor:admin)).contains("fixture-secret-must-not-leak"),"export excludes secrets")
        try await host.uninstall(secret.id,actor:admin);try check(secretsMemory.isEmpty,"uninstall cleans immutable secret refs")
        try sql(db,"CREATE TRIGGER fixture_install_failure BEFORE INSERT ON native_outbox WHEN NEW.event='plugin/installed' BEGIN SELECT RAISE(ABORT,'fixture'); END")
        try rejects("install enqueue failure") { try host.install(secret.id,actor:admin,settings:[:],secrets:["apiKey":"fixture-secret"]) }
        try check(try host.state(secret.id)==nil && secretsMemory.isEmpty,"failed installation state/secret rollback")
        try sql(db,"DROP TRIGGER fixture_install_failure")
        try host.setEnabled(first.id,actor:admin,enabled:false);try host.setEnabled(second.id,actor:admin,enabled:false)
        let representative=try db.insert("Users",values:["v":.integer(0),"name":.text("Rep"),"email":.text("rep@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let owned=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Protected"),"company_id":.text("123"),"assigned_to":.text(identity.id)],actor:identity.id)
        try host.install(NativeAccountProtection.id,actor:admin,settings:[:],secrets:[:])
        let install=try db.jobs(events:["plugin/installed"]).first { $0.payload["pluginId"]==NativeAccountProtection.id }!
        _=try await host.runJob(install)
        let protection=NativePluginStore(db:db,pluginId:NativeAccountProtection.id,clock:{now})
        try db.transaction {
            try rejects("blocking rule") { _=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Blocked duplicate"),"company_id":.text("123")],actor:representative["id"].string) }
            try check(try protection.list("notice:").isEmpty,"refusal notice waits for outer completion")
        }
        try check(try protection.list("notice:").count==1 && db.page("crm_Accounts",fields:[],equal:["name":.text("Blocked duplicate")]).total==0,"refusal notice persists after rejected record rollback")
        try rejects("outer rejection rollback") { try db.transaction { try rejects("nested rejection") { _=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("Blocked twice"),"company_id":.text("123")],actor:representative["id"].string) };throw NativePluginError(message:"outer fail") } }
        try check(try protection.list("notice:").count==2,"refusal notice survives outer rollback")
        try rejects("representative ownership") { _=try db.update(owned,changes:["assigned_to":representative["id"]],actor:representative["id"].string) }
        let unreadable=NativePluginData(db:db,pluginId:"limited",permissions:["accounts:write"])
        try rejects("read permission") { _=try unreadable.get("accounts",owned["id"].string) }
        let directory=NativePluginData(db:db,pluginId:"directory",permissions:["users:read","accounts:read"])
        try check(try directory.get("users",identity.id)?["password"]==nil,"users password omitted")
        try rejects("password filter") { _=try directory.find("users",["where":["password":["not":NSNull()]]]) }
        try rejects("relation include via filter") { _=try directory.find("accounts",["where":["assigned_to_user":["is":[:]]]]) }
        _=try NativeRecordMutationScope.$bypassHooks.withValue(true) { try db.setDeleted(owned,deleted:true,actor:identity.id) }
        try check(try directory.find("accounts",["where":["id":owned["id"].string]]).count==1,"plugin find includes deleted records")
        try check(try directory.find("accounts",["where":["name":["equals":"pRoTeCtEd","mode":"insensitive"]]]).count==1,"case insensitive scalar query")
        try check(try directory.find("accounts",["take":0]).isEmpty,"zero take")
        try check(try directory.find("accounts",["take":-1,"orderBy":["name":"asc"]]).count==1,"negative take")
        try check(NativePluginCronSchedule.matches("0 6 * * *",at:NativePluginJSON.date("2026-01-01T06:00:00Z")) && !NativePluginCronSchedule.matches("*/5 * * * *",at:NativePluginJSON.date("2026-01-01T06:01:00Z")),"cron UTC matching")
        try host.enqueueDueCrons(try NativePluginJSON.date("2026-01-01T06:00:00Z"));let cronCount=try db.jobs(events:["plugin/cron"]).count;try host.enqueueDueCrons(try NativePluginJSON.date("2026-01-01T06:00:59Z"))
        try check(try db.jobs(events:["plugin/cron"]).count==cronCount && cronCount==2,"cron enqueue once per minute")
        return checks
    }
}
