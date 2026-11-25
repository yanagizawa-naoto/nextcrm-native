import Foundation

actor ProviderDrainGate {
    private var count=0,waiters:[CheckedContinuation<Void,Never>]=[]
    func hold()async{count += 1;await withCheckedContinuation{waiters.append($0)}}
    func entered()->Int{count}
    func releaseOne(){if !waiters.isEmpty{waiters.removeFirst().resume()}}
    func releaseAll(){let old=waiters;waiters=[];old.forEach{$0.resume()}}
}
final class ProviderDrainCount:@unchecked Sendable {
    private let lock=NSLock();private var n=0
    func increment(){lock.lock();n+=1;lock.unlock()}
    var value:Int{lock.lock();defer{lock.unlock()};return n}
}
enum ProviderDrainScope { @TaskLocal static var actor="none" }
@main enum ProviderDrainTests {
    static var checks=0
    static let now=Date(timeIntervalSince1970:1_700_000_000)
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL "+label)};checks+=1}
    static func until(_ label:String,_ body:()async throws->Bool)async throws {
        for _ in 0..<1000 {if try await body(){return};try await Task.sleep(nanoseconds:2_000_000)}
        throw NativeDBError.message("Timeout "+label)
    }
    static func gate(_ gate:ProviderDrainGate,_ count:Int=1)async throws{try await until("gate \(count)"){await gate.entered()>=count}}
    static func fixture(_ root:URL,_ resources:URL)throws->CRMService {
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let id="bf200000-0000-4000-8000-000000000001"
        _=try db.insert("Users",values:["id":.text(id),"name":.text("停止検証"),"email":.text("stop@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:id)
        return .init(db:db,identity:.init(id:id,role:"admin",partnerAccountID:nil))
    }
    static func definition()->NativePluginDefinition{.init(id:"drain-test",name:"Drain",version:"0.1.0",sdk:"^0.2.0",description:"")}
    static func host(_ db:NativeDatabase,_ definition:NativePluginDefinition)throws->NativePluginHost {
        let host=try NativePluginHost(db:db,definitions:[definition],secretStore:.unavailable,clock:{now},sendNotification:{_,_,_ in throw NativeDBError.conflict},transport:{_,_ in throw NativeDBError.conflict})
        host.attach()
        _=try db.insert("InstalledPlugin",values:["id":.text(definition.id),"version":.text(definition.version),"status":.text("ENABLED"),"settings":.text("{}")],actor:"system")
        return host
    }
    static func main()async {
        do {
            let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2])
            try await registry()
            try await pluginWorker(fixture(root.appendingPathComponent("plugin-worker"),resources))
            try await pluginTimer(fixture(root.appendingPathComponent("plugin-timer"),resources))
            try await heartbeat(fixture(root.appendingPathComponent("heartbeat"),resources),cancel:false)
            try await heartbeat(fixture(root.appendingPathComponent("heartbeat-cancel"),resources),cancel:true)
            try await currencyWorker(fixture(root.appendingPathComponent("currency-worker"),resources))
            try await currencyTimer(fixture(root.appendingPathComponent("currency-timer"),resources))
            print("{\"checks\":\(checks),\"scenarios\":7,\"externalRequests\":0,\"exit\":0}")
        }catch{fputs("Provider drain after \(checks): \(error)\n",stderr);exit(1)}
    }
    static func registry()async throws {
        let inherited=NativeProviderRuntimeTasks(),contextCount=ProviderDrainCount()
        await ProviderDrainScope.$actor.withValue("synthetic-actor") {
            let task=inherited.submit {if ProviderDrainScope.actor=="synthetic-actor"{contextCount.increment()}}!
            await task.value
        }
        try check(contextCount.value==1,"original TaskLocal actor context preserved")
        let owner=NativeProviderRuntimeTasks(),gate=ProviderDrainGate(),runs=ProviderDrainCount()
        let task=owner.submit(key:"wake"){runs.increment();await gate.hold()}!
        try await self.gate(gate)
        DispatchQueue.concurrentPerform(iterations:1000){_ in owner.submit(key:"wake"){runs.increment();await gate.hold()}}
        try check(owner.snapshot.pending==1 && owner.snapshot.accepted==1,"1000 notification burst coalesces one admitted Task")
        await gate.releaseOne();try await self.gate(gate,2)
        try check(runs.value==2,"dirty notification is not lost while first iteration runs")
        let closed=owner.close(),done=ProviderDrainCount()
        let join=Task{for task in closed{await task.value};done.increment()};join.cancel()
        try check(owner.submit(key:"wake"){}==nil,"closed callback creates no Task")
        try await Task.sleep(nanoseconds:10_000_000)
        try check(done.value==0,"cancelled join waits cancellation-ignoring callback")
        await gate.releaseOne();await join.value;await task.value
        try check(done.value==1 && owner.snapshot.pending==0 && owner.snapshot.completed==1,"callback truly completed")
        let fresh=NativeProviderRuntimeTasks(),next=fresh.submit{}!;await next.value
        try check(owner.submit{}==nil && fresh.snapshot.completed==1,"old registry cannot reenter fresh run")
    }
    static func pluginWorker(_ service:CRMService)async throws {
        let gate=ProviderDrainGate();var definition=definition()
        definition.onInstall={ctx in await gate.hold();try ctx.store.set("late-effect",true)}
        let host=try host(service.db,definition),job=try service.db.enqueue("plugin/installed",payload:["pluginId":definition.id],now:now)
        let runtime=NativePluginsRuntime(host:host,clock:{now})
        await runtime.start();try await self.gate(gate)
        let owner=await runtime.tasksForTesting,done=ProviderDrainCount()
        let a=Task{await runtime.stop();done.increment()};a.cancel()
        try await until("plugin stopping"){await runtime.stoppingForTesting}
        let b=Task{await runtime.stop();done.increment()},c=Task{await runtime.stop();done.increment()}
        await runtime.start();await runtime.wake()
        NotificationCenter.default.post(name:NativeDatabase.jobsDidChange,object:nil,userInfo:["database":service.db.url.path])
        try await Task.sleep(nanoseconds:15_000_000)
        try check(done.value==0 && !owner.snapshot.accepting,"all concurrent stops wait accepted plugin callback")
        let state=await runtime.snapshot();try check(!state.running && state.working,"start/wake during stop cannot reopen")
        await gate.releaseOne();await a.value;await b.value;await c.value
        try check(done.value==3 && owner.snapshot.pending==0,"all stops return only after worker/observer completion")
        try check(try service.db.job(id:job)?.status=="retry","cancelled plugin keeps persisted retry")
        try check(try NativePluginStore(db:service.db,pluginId:definition.id).get("late-effect")==nil,"ignored-cancel hook cannot publish after lease fence")
        let stopped=await runtime.snapshot();try check(!stopped.running && !stopped.working,"stop returns finalized state")
        try check(owner.submit{}==nil,"old observer run remains closed")
        await runtime.start();let fresh=await runtime.tasksForTesting
        try check(fresh !== owner,"explicit start after joined stop creates new run")
        await runtime.stop();try check(fresh.snapshot.pending==0,"restart immediately stopped and drained")
    }
    static func pluginTimer(_ service:CRMService)async throws {
        let host=try host(service.db,definition()),gate=ProviderDrainGate()
        let runtime=NativePluginsRuntime(host:host,clock:{now},sleep:{_ in await gate.hold()})
        await runtime.start();try await self.gate(gate)
        let owner=await runtime.tasksForTesting
        await runtime.wake();try await self.gate(gate,2)
        try check(owner.snapshot.pending>=2,"cancelled old plugin timer remains tracked after replacing timer property")
        let done=ProviderDrainCount(),a=Task{await runtime.stop();done.increment()}
        try await until("timer stop"){await runtime.stoppingForTesting}
        let b=Task{await runtime.stop();done.increment()};b.cancel()
        await gate.releaseOne();try await Task.sleep(nanoseconds:10_000_000)
        try check(done.value==0,"old timer completion cannot release newer timer")
        await gate.releaseOne();await a.value;await b.value
        try check(done.value==2 && owner.snapshot.pending==0,"plugin cancelled timers actually joined")
    }
    static func heartbeat(_ service:CRMService,cancel:Bool)async throws {
        let callback=ProviderDrainGate(),beat=ProviderDrainGate(),done=ProviderDrainCount();var definition=definition()
        definition.onInstall={_ in await callback.hold()}
        let host=try host(service.db,definition),job=try service.db.enqueue("plugin/installed",payload:["pluginId":definition.id],now:now)
        let work=Task{let result=try await NativePluginJobExecutor.runNext(host:host,clock:{now},heartbeatSleep:{_ in await beat.hold()});done.increment();return result}
        try await gate(callback);try await gate(beat)
        if cancel{work.cancel()};await callback.releaseOne()
        try await Task.sleep(nanoseconds:10_000_000)
        try check(done.value==0,"job executor joins ignored-cancel heartbeat (cancel=\(cancel))")
        await beat.releaseOne();_=try await work.value
        try check(done.value==1,"heartbeat released before executor returns")
        try check(try service.db.job(id:job)?.status=="done","completed callback retains source success even if cancellation was ignored")
    }
    static func currency(_ service:CRMService)throws->NativeCurrencyAdministration {
        for code in ["EUR","JPY"]{_=try service.db.insert("Currency",values:["code":.text(code),"name":.text(code),"symbol":.text(code),"isEnabled":.integer(1)],actor:service.identity.id)}
        let api=NativeCurrencyAdministration(service:service,clock:{now});try api.setECBEnabled(true);return api
    }
    static func response(_ request:URLRequest)->(Data,HTTPURLResponse){(Data("<Cube currency='JPY' rate='160'/ >".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)}
    static func currencyWorker(_ service:CRMService)async throws {
        let api=try currency(service),job=try api.requestECBUpdate(),gate=ProviderDrainGate(),calls=ProviderDrainCount()
        let runtime=NativeCurrencyAdministrationRuntime(db:service.db,transport:{request in calls.increment();await gate.hold();return response(request)},clock:{now})
        await runtime.start();try await self.gate(gate)
        let owner=await runtime.tasksForTesting,done=ProviderDrainCount()
        let a=Task{await runtime.stop();done.increment()};a.cancel()
        try await until("currency stopping"){await runtime.stoppingForTesting}
        let b=Task{await runtime.stop();done.increment()}
        await runtime.start();await runtime.wake()
        NotificationCenter.default.post(name:NativeCurrencyAdministration.settingsDidChange,object:nil,userInfo:["database":service.db.url.path])
        try await Task.sleep(nanoseconds:10_000_000)
        try check(done.value==0 && !owner.snapshot.accepting,"currency stops wait actual transport despite cancellation")
        await gate.releaseOne();await a.value;await b.value
        try check(done.value==2 && owner.snapshot.pending==0 && calls.value==1,"currency transport and observer callbacks joined")
        try check(try service.db.job(id:job)?.status=="retry","currency interrupted fetch kept for retry")
        try check(try service.db.page("ExchangeRate",fields:[]).total==0,"cancelled currency response cannot publish rates")
        try check(owner.submit{}==nil,"old currency callback rejected after stop")
        await runtime.start();let fresh=await runtime.tasksForTesting
        try check(fresh !== owner,"currency explicit restart preserves compatibility")
        let manual=try api.requestECBUpdate();await runtime.wake();try await self.gate(gate,2)
        await gate.releaseOne();try await until("currency normal success"){try service.db.job(id:manual)?.status=="done"}
        await runtime.stop()
        try check(try service.db.page("ExchangeRate",fields:[]).total==2,"normal restarted currency operation persists rates")
        try check(fresh.snapshot.pending==0,"normal run stop joins timer too")
    }
    static func currencyTimer(_ service:CRMService)async throws {
        _=try currency(service);let gate=ProviderDrainGate(),calls=ProviderDrainCount()
        let runtime=NativeCurrencyAdministrationRuntime(db:service.db,transport:{request in calls.increment();return response(request)},clock:{now},sleep:{_ in await gate.hold()})
        await runtime.start();try await self.gate(gate)
        let owner=await runtime.tasksForTesting;await runtime.wake();try await self.gate(gate,2)
        try check(owner.snapshot.pending>=2,"old currency timer retained after wake replacement")
        let done=ProviderDrainCount(),a=Task{await runtime.stop();done.increment()}
        try await until("currency timer stop"){await runtime.stoppingForTesting}
        let b=Task{await runtime.stop();done.increment()}
        await gate.releaseOne();try await Task.sleep(nanoseconds:10_000_000)
        try check(done.value==0,"currency old timer cannot release new timer")
        await gate.releaseOne();await a.value;await b.value
        try check(done.value==2 && owner.snapshot.pending==0 && calls.value==0,"both currency timers joined without network")
    }
}
