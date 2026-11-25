import Foundation

private final class PluginTestMemory:NativePluginCredentialBacking {
    var values:[String:Data]=[:],removalFails=false,onSave:(()->Void)?
    func load(_ reference:String) throws -> Data? { values[reference] }
    func save(_ reference:String,data:Data) throws { guard values[reference]==nil else { throw NativeDBError.conflict };values[reference]=data;onSave?() }
    func remove(_ reference:String) throws { if removalFails { throw NativeDBError.conflict };values.removeValue(forKey:reference) }
}
private actor PluginTestGate {
    var entered=false,continuation:CheckedContinuation<Void,Never>?
    func wait() async { entered=true;await withCheckedContinuation { continuation=$0 } }
    func release() { continuation?.resume();continuation=nil }
}

@main enum NativePluginsRuntimeTests {
    static var checks=0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws { checks+=1;guard try value() else { throw NativePluginError(message:name) } }
    static func rejects(_ name:String,_ body:() throws -> Void) throws { do { try body() } catch { checks+=1;return };throw NativePluginError(message:"accepted "+name) }
    static func main() async {
        do {
            if CommandLine.arguments.contains("--keychain-probe") {try keychainProbe();return}
            let resources=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try NativePluginJSON.record(String(contentsOf:resources.appendingPathComponent("build/plugins-runtime-reference.json"),encoding:.utf8))
            for scenario in reference["scenarios"] as! [NativePluginRecord] { try await sourceScenario(scenario,resources) }
            try await credentials(resources);try await queue(resources);try await boundaries(resources);try decimals(resources);try await lifecycleRuntime(resources);try NativePluginsRulesTests.run(resources)
            print(try NativePluginJSON.text(["exit":0,"sourceScenarios":(reference["scenarios"] as! [Any]).count,"checks":checks]))
        } catch { print(try! NativePluginJSON.text(["exit":1,"checks":checks,"error":error.localizedDescription]));exit(1) }
    }
    static func fixture(_ resources:URL) throws -> (URL,NativeDatabase,NativePluginActor) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NativePluginRuntime-"+UUID().uuidString)
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        return (root,db,.init(type:.user,userId:identity.id,role:"admin"))
    }
    static func host(_ db:NativeDatabase,_ definitions:[NativePluginDefinition],store:NativePluginSecretStore = .unavailable,clock:@escaping ()->Date=Date.init) throws -> NativePluginHost {
        let host=try NativePluginHost(db:db,definitions:definitions,secretStore:store,clock:clock,sendNotification:{_,_,_ in},transport:{_,_ in throw NativeDBError.conflict});host.attach();return host
    }
    static func seed(_ db:NativeDatabase,_ definition:NativePluginDefinition,status:String="ENABLED") throws {
        try db.insert("InstalledPlugin",values:["id":.text(definition.id),"version":.text(definition.version),"status":.text(status),"settings":.text("{}")],actor:"system")
    }
    static func sourceScenario(_ scenario:NativePluginRecord,_ resources:URL) async throws {
        let (root,db,_)=try fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
        let kind=scenario["kind"] as! String,mode=scenario["mode"] as! String,id="runtime-test"
        var trace:[NativePluginRecord]=[]
        func record(_ label:String,_ ctx:NativePluginContext) throws {
            trace.append(["label":label,"actor":try NativePluginJSON.parse(String(decoding:JSONEncoder().encode(NativePluginActorScope.current!.actor),as:UTF8.self)),"contextActor":try NativePluginJSON.parse(String(decoding:JSONEncoder().encode(ctx.actor),as:UTF8.self))])
            if mode=="failure" { throw NativePluginError(message:"fixture failure") }
        }
        var definition=NativePluginDefinition(id:id,name:"Fixture",version:"0.1.0",sdk:"^0.2.0",description:"")
        definition.crons=[.init(id:"tick",schedule:"*/5 * * * *",handler:{try record("cron",$0)})]
        definition.events=[.init(event:"crm/order.saved",handler:{_,ctx in try record("event",ctx)})]
        definition.afters=[.init(entity:.account,operation:.created,handler:{_,ctx in try record("after1",ctx)}),.init(entity:.account,operation:.updated,handler:{_,ctx in try record("ignored",ctx)}),.init(entity:.account,operation:.created,handler:{_,ctx in try record("after2",ctx)})]
        definition.onInstall={try record("install",$0)}
        let host=try host(db,[definition]);try seed(db,definition,status:mode=="disabled" ? "DISABLED":"ENABLED")
        var payload=["pluginId":id],event="plugin/"+kind
        if kind=="install" {event="plugin/installed"}
        if kind=="cron" {payload["cronId"]="tick"}
        if kind=="event" {event="plugin/event-dispatch";payload["event"]="crm/order.saved";payload["data"]=try NativePluginJSON.text(["source":mode=="self" ? id:"other"])}
        if kind=="after" {payload["input"]=String(decoding:try JSONEncoder().encode(NativePluginAfterInput(entity:.account,operation:.created,recordId:"fixture")),as:UTF8.self)}
        let job=try db.enqueue(event,payload:payload)
        var failed=false;do{_=try await host.runJob(db.job(id:job)!)}catch{failed=true}
        try check(NativePluginJSON.equal(trace,scenario["trace"]),kind+mode+" callback actor/order")
        try check(failed==(scenario["failed"] as! Bool),kind+mode+" failure")
        try check(try host.state(id)?["status"].string==scenario["status"] as? String,kind+mode+" state")
        try check(try db.page("PluginLog",fields:[],equal:["pluginId":.text(id)]).total==(scenario["logCount"] as! NSNumber).intValue,kind+mode+" logs")
        try check(NativePluginJobExecutor.maximumAttempts-1==(scenario["retries"] as! NSNumber).intValue || kind=="install" && scenario["retries"] as? Int==0,kind+mode+" retries")
    }
    static func credentials(_ resources:URL) async throws {
        let (root,db,admin)=try fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
        var now=Date(),definition=NativePluginDefinition(id:"secret-test",name:"Secret",version:"0.1.0",sdk:"^0.2.0",description:"")
        definition.secrets = .init(fields:[.init(key:"key",kind:.string,validate:{($0 as? String)?.isEmpty==false})])
        let memory=PluginTestMemory(),vault=NativePluginCredentialVault(db:db,backing:memory,clock:{now}),host=try host(db,[definition],store:vault.store,clock:{now})
        try host.install(definition.id,actor:admin,settings:[:],secrets:["key":"synthetic-private-value"])
        let installed=try host.state(definition.id)!,first=installed["secrets"].string
        try check(NativePluginCredentialVault.valid(first) && memory.values.count==1,"opaque immutable reference")
        try check(try vault.read(first)["key"] as? String=="synthetic-private-value","vault read")
        now=now.addingTimeInterval(601);_=try vault.cleanup()
        try check(memory.values[first] != nil && (try vault.cleanup()).pending==0,"published disabled-or-enabled reference retained")
        try host.setEnabled(definition.id,actor:admin,enabled:false);try vault.remove(first)
        try check(memory.values[first] != nil,"disabled still references secret")
        try rejects("stale form before Keychain") {try host.saveSettings(definition.id,actor:admin,settings:[:],secrets:["key":"replacement"],expectedRevision:installed.revision)}
        try check(memory.values.count==1,"stale form no orphan")
        try host.saveSettings(definition.id,actor:admin,settings:[:],secrets:["key":""])
        let second=try host.state(definition.id)!["secrets"].string
        try check(first != second && memory.values[first]==nil && memory.values.count==1,"rotation atomically publishes and cleans")
        let orphan=try vault.write(definition.id,["key":"orphan"]);now=now.addingTimeInterval(601);memory.removalFails=true
        let failed=try vault.cleanup();try check(failed.pending>0 && memory.values[orphan] != nil,"failed Keychain delete remains durable")
        memory.removalFails=false;let reopened=NativePluginCredentialVault(db:db,backing:memory,clock:{now});_=try reopened.cleanup()
        try check(memory.values[orphan]==nil && memory.values[second] != nil,"cleanup after reopen preserves published reference")
        memory.onSave={now=now.addingTimeInterval(601)}
        try rejects("expired reservation") {_=try vault.write(definition.id,["key":"late"])}
        try check(memory.values.count==1,"expired write cleaned")
        memory.onSave={try! db.update(db.get("Users",key:["id":.text(admin.userId!)])!,changes:["role":.text("user")],actor:"system")}
        try rejects("authority lost during Keychain") {try host.saveSettings(definition.id,actor:admin,settings:[:],secrets:["key":"forbidden"])}
        try check(try host.state(definition.id)!["secrets"].string==second && memory.values.count==1,"authority loss rollback and cleanup")
        memory.onSave=nil;try db.update(db.get("Users",key:["id":.text(admin.userId!)])!,changes:["role":.text("admin")],actor:"system")
        try await host.uninstall(definition.id,actor:admin);try check(memory.values.isEmpty,"uninstall Keychain cleanup")
        try rejects("legacy ciphertext is never Keychain") {_=try vault.read("old-server-encrypted-secret")}
        let raw=try db.metadata(NativePluginCredentialVault.cleanupKey) ?? ""
        try check(!raw.contains("synthetic") && !raw.contains("forbidden"),"cleanup metadata excludes raw secrets")
    }
    static func queue(_ resources:URL) async throws {
        let (root,db,admin)=try fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
        var now=Date(),calls=0,definition=NativePluginDefinition(id:"queue-test",name:"Queue",version:"0.1.0",sdk:"^0.2.0",description:"",permissions:["accounts:write"])
        definition.events=[.init(event:"fixture/fail",handler:{_,_ in calls+=1;throw NativePluginError(message:"secret-not-in-outbox")})]
        let host=try host(db,[definition],clock:{now});try seed(db,definition)
        let id=try db.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":"fixture/fail","data":"{}"],now:now)
        for attempt in 1...4 {let handled=try await NativePluginJobExecutor.runNext(host:host,clock:{now});try check(handled,"attempt handled");try check(try db.job(id:id)!.attempts==attempt,"durable attempt number");now=now.addingTimeInterval(301)}
        try check(calls==4 && (try db.job(id:id))!.status=="failed","initial plus three retries")
        try check(try !(db.job(id:id)!.lastError ?? "").contains("secret"),"outbox error redaction")
        let gate=PluginTestGate();var after=definition
        after.events=[.init(event:"fixture/gated",handler:{_,ctx in await gate.wait();try ctx.store.set("after-await",true)})]
        let guarded=try self.host(db,[after],clock:{now}),gated=try db.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":"fixture/gated","data":"{}"],now:now)
        let run=Task {try await NativePluginJobExecutor.runNext(host:guarded,clock:{now},leaseSeconds:30)}
        for _ in 0..<1000 {if await gate.entered {break};try await Task.sleep(nanoseconds:1_000_000)}
        let entered=await gate.entered;try check(entered,"callback entered")
        try guarded.setEnabled(definition.id,actor:admin,enabled:false);await gate.release();_=try await run.value
        try check(try NativePluginStore(db:db,pluginId:definition.id).get("after-await")==nil,"disable during await fences write")
        try check(try db.job(id:gated)!.status=="retry","fenced attempt durably released")
        now=now.addingTimeInterval(301);_=try await NativePluginJobExecutor.runNext(host:guarded,clock:{now})
        try check(try db.job(id:gated)!.result["status"]=="skipped","disabled retry acknowledged")
        try guarded.setEnabled(definition.id,actor:admin,enabled:true)
        let dispatch=try db.enqueue("plugin/event",payload:["event":"fixture/gated","data":try NativePluginJSON.text(["source":definition.id])],now:now)
        _=try await NativePluginJobExecutor.runNext(host:guarded,clock:{now});try check(try db.job(id:dispatch)!.status=="done","self event dispatcher finishes")
        let before=try db.jobs(events:["plugin/event-dispatch"]).count
        try check(before==2,"self event has no child job")
        let runtime=NativePluginsRuntime(host:guarded,clock:{now});await runtime.start();await runtime.wake();await runtime.stop()
        let state=await runtime.snapshot();try check(!state.running && !state.working,"runtime stop drains worker")
    }
    private static func wait(_ gate:PluginTestGate) async throws {
        for _ in 0..<1000 { if await gate.entered {return};try await Task.sleep(nanoseconds:1_000_000) }
        throw NativePluginError(message:"gate timeout")
    }
    static func boundaries(_ resources:URL) async throws {
        let (root,db,admin)=try fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
        var now=Date(),definition=NativePluginDefinition(id:"boundary-test",name:"Boundary",version:"0.2.0",sdk:"^0.2.0",description:"")
        let gate=PluginTestGate()
        definition.onInstall={ctx in await gate.wait();try ctx.store.set("install-after-stop",true)}
        var host=try host(db,[definition],clock:{now});try seed(db,definition)
        let job=try db.enqueue("plugin/installed",payload:["pluginId":definition.id],now:now)
        let stopped=Task {try await NativePluginJobExecutor.runNext(host:host,clock:{now},leaseSeconds:30)}
        try await wait(gate);stopped.cancel();await gate.release();_=try await stopped.value
        try check(try host.state(definition.id)?["status"] == .text("ENABLED"),"cancelled install does not disable")
        try check(try NativePluginStore(db:db,pluginId:definition.id).get("install-after-stop")==nil,"cancelled install no late write")
        try check(try db.job(id:job)!.status=="retry","stop releases lease for restart")
        try db.cancelJob(id:job)
        let stolenGate=PluginTestGate();definition.onInstall=nil
        definition.events=[.init(event:"fixture/stolen",handler:{_,ctx in await stolenGate.wait();try ctx.store.set("stolen",true)})]
        host=try self.host(db,[definition],clock:{now})
        let second=try db.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":"fixture/stolen","data":"{}"],now:now)
        let abandoned=Task {try await NativePluginJobExecutor.runNext(host:host,clock:{now},leaseSeconds:0.15)}
        try await wait(stolenGate);now=now.addingTimeInterval(1)
        let replacement=try db.claimJob(events:NativePluginHost.jobEvents,now:now,leaseSeconds:30)!
        try check(replacement.id==second && replacement.attempts==2,"second connection lease reclaim")
        await stolenGate.release();_=try await abandoned.value
        try check(try NativePluginStore(db:db,pluginId:definition.id).get("stolen")==nil,"reclaimed lease rejects abandoned effects")
        try check(try db.requireJobLease(replacement).leaseToken==replacement.leaseToken,"abandoned finish leaves new lease intact")
        try db.finishJob(replacement)
        let uninstallGate=PluginTestGate();definition.onUninstall={_ in await uninstallGate.wait()}
        host=try self.host(db,[definition],clock:{now})
        let removing=Task {try await host.uninstall(definition.id,actor:admin)}
        try await wait(uninstallGate)
        try db.update(db.get("Users",key:["id":.text(admin.userId!)])!,changes:["banned":.integer(1)],actor:"system")
        await uninstallGate.release();var denied=false;do{try await removing.value}catch{denied=true}
        try check(denied && (try host.state(definition.id)) != nil,"fresh authority after uninstall await")
        try db.update(db.get("Users",key:["id":.text(admin.userId!)])!,changes:["banned":.integer(0)],actor:"system")
        let store=NativePluginStore(db:db,pluginId:definition.id,clock:{now})
        for i in 0..<251 {try store.forRecord(.account,"record-\(i/3)").set("key-\(i)",["text":"\u{feff}日本語 \(i)"])}
        try store.set("global",["keep":true])
        let summary=try host.summary(definition.id)
        try check(summary["entries"] as? Int==252 && summary["records"] as? Int==84,"bounded summary crosses pages")
        let destination=root.appendingPathComponent("export.json");try host.exportFile(definition.id,to:destination,actor:admin)
        let exported=try NativePluginJSON.record(String(contentsOf:destination,encoding:.utf8)),original=try host.export(definition.id,actor:admin)
        try check(NativePluginJSON.equal(exported,original),"streamed export matches original all rows and FEFF")
        try rejects("exclusive export destination") {try host.exportFile(definition.id,to:destination,actor:admin)}
        let db2=try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),store2=NativePluginStore(db:db2,pluginId:definition.id,clock:{now})
        let lock=NSLock();var claimed=0,errors=0
        DispatchQueue.concurrentPerform(iterations:16) { index in do {let won=try (index%2==0 ? store:store2).claim("concurrent",ms:1000);lock.lock();if won{claimed+=1};lock.unlock()}catch{lock.lock();errors+=1;lock.unlock()} }
        try check(claimed==1 && errors==0,"concurrent independent DB claim winner")
    }
    static func decimals(_ resources:URL) throws {
        let (root,db,_)=try fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
        let reference=try NativePluginJSON.record(String(contentsOf:resources.appendingPathComponent("build/plugins-decimal-reference.json"),encoding:.utf8)),data=NativePluginData(db:db,pluginId:"decimal-test",permissions:["products:read","products:write"])
        for (i,test) in (reference["cases"] as! [NativePluginRecord]).enumerated() {
            let field=test["field"] as! String,model=test["model"] as! String
            var actual:String?,ok=true
            do {
                if test["kind"] as? String=="product" {
                    let created=try data.upsertExternalProduct("decimal-\(i)",["name":"Decimal \(i)","unit_price":test["input"]!,"currency":"JPY","type":"PRODUCT","status":"ACTIVE","categoryRef":NSNull()])
                    actual=try data.get("products",created["id"] as! String)?["unit_price"] as? String
                } else {actual=try NativeMCPWire.decimal(data.values([field:test["input"]!],model:model)[field]!.string)}
            } catch {ok=false}
            try check(ok==(test["ok"] as! Bool),"decimal storage acceptance \(i)")
            if ok {try check(actual==test["expected"] as? String,"decimal storage result \(i): \(actual ?? "nil")")}
        }
        let value=try data.upsertExternalProduct("filter-boundary",["name":"filter","unit_price":"2.675","currency":"JPY","type":"PRODUCT","status":"ACTIVE","categoryRef":NSNull()])
        try check(try data.find("products",["where":["id":value["id"]!,"unit_price":["equals":"2.675"]]]).isEmpty,"query operands must not be storage-rounded")
    }
    static func lifecycleRuntime(_ resources:URL) async throws {
        let (root,db,admin)=try fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
        var definition=NativePluginDefinition(id:"upgrade-test",name:"Upgrade",version:"0.2.0",sdk:"^0.2.0",description:"")
        definition.onUpgrade={ctx,old in try ctx.store.set("upgraded-from",old)}
        var host=try host(db,[definition]);try seed(db,definition,status:"DISABLED")
        try db.update(host.state(definition.id)!,changes:["version":.text("0.1.0")],actor:"system")
        var runtime=NativePluginsRuntime(host:host);await runtime.start()
        for _ in 0..<1000 {if try host.state(definition.id)?["version"] == .text("0.2.0"){break};try await Task.sleep(nanoseconds:1_000_000)}
        await runtime.stop()
        try check(try host.state(definition.id)?["version"] == .text("0.2.0") && host.state(definition.id)?["status"] == .text("DISABLED"),"runtime owns disabled plugin upgrade")
        try check(try NativePluginStore(db:db,pluginId:definition.id).get("upgraded-from") as? String=="0.1.0","upgrade original version argument")
        let upgradeGate=PluginTestGate();definition.onUpgrade={ctx,_ in await upgradeGate.wait();try ctx.store.set("after-cancel",true)}
        host=try self.host(db,[definition]);try db.update(host.state(definition.id)!,changes:["version":.text("0.1.0"),"status":.text("ENABLED")],actor:"system")
        runtime=NativePluginsRuntime(host:host);await runtime.start();try await wait(upgradeGate)
        let stopping=Task {await runtime.stop()};try await Task.sleep(nanoseconds:20_000_000);await upgradeGate.release();await stopping.value
        try check(try host.state(definition.id)?["version"] == .text("0.1.0") && host.state(definition.id)?["status"] == .text("ENABLED"),"cancel upgrade keeps prior version and status")
        try check(try NativePluginStore(db:db,pluginId:definition.id).get("after-cancel")==nil,"cancelled upgrade fences effects")
        definition.onUpgrade=nil;let heartbeatGate=PluginTestGate()
        definition.events=[.init(event:"heartbeat",handler:{_,ctx in await heartbeatGate.wait();try ctx.store.set("heartbeat",true)})]
        host=try self.host(db,[definition]);let id=try db.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":"heartbeat","data":"{}"])
        let executing=Task {try await NativePluginJobExecutor.runNext(host:host,leaseSeconds:0.15)};try await wait(heartbeatGate)
        try await Task.sleep(nanoseconds:450_000_000)
        let other=try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try other.claimJob(events:NativePluginHost.jobEvents,leaseSeconds:1)==nil,"heartbeat renews across independent DB handles")
        await heartbeatGate.release();_=try await executing.value
        try check(try db.job(id:id)?.status=="done" && NativePluginStore(db:db,pluginId:definition.id).get("heartbeat") as? Bool==true,"renewed worker completes")
        let notifyGate=PluginTestGate();var sent=0
        let users=try (0...1).map {try db.insert("Users",values:["name":.text("Notify \($0)"),"email":.text("plugin\($0)@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE"),"v":.integer(0)],actor:"system")["id"].string}
        definition.permissions=["notify"];definition.events=[.init(event:"notify",handler:{_,ctx in try await ctx.notify(.init(userIds:users,subject:"Fixture",text:"No external mail"))})]
        host=try NativePluginHost(db:db,definitions:[definition],sendNotification:{_,_,_ in sent+=1;await notifyGate.wait()},transport:{_,_ in throw NativeDBError.conflict});host.attach()
        _=try db.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":"notify","data":"{}"])
        let notifying=Task {try await NativePluginJobExecutor.runNext(host:host)};try await wait(notifyGate)
        try host.setEnabled(definition.id,actor:admin,enabled:false);await notifyGate.release();_=try await notifying.value
        try check(sent==1,"disable after first recipient prevents second notification")
    }
    static func keychainProbe() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NativePluginKeychainProbe-"+UUID().uuidString),reference=NativePluginCredentialVault.prefix+UUID().uuidString.lowercased()
        let store=KeychainNativePluginCredentials(databaseURL:root.appendingPathComponent("one.sqlite")),other=KeychainNativePluginCredentials(databaseURL:root.appendingPathComponent("two.sqlite")),bytes=Data("synthetic-local-probe".utf8)
        defer{try? store.remove(reference);try? other.remove(reference)}
        try store.save(reference,data:bytes);try check(try store.load(reference)==bytes,"Keychain write/read")
        try check(try other.load(reference)==nil,"Keychain database namespace")
        try rejects("immutable Keychain reference") {try store.save(reference,data:Data("replacement".utf8))}
        try store.remove(reference);try check(try store.load(reference)==nil,"Keychain removal")
        print(try NativePluginJSON.text(["exit":0,"keychainProbeChecks":checks,"scope":"Dedicated temporary database namespaces only; interaction forbidden; probe credentials removed"]))
    }
}
