import Foundation

final class RuntimeDrainSecrets:NativeMailSecretStore,GoogleCalendarSecretStore,CalendlySecretStore {
    private let lock = NSLock(); private var values:[String:Data] = [:]
    func load(id:String,interactive:Bool)throws->Data? { lock.lock(); defer{lock.unlock()}; return values[id] }
    func save(id:String,data:Data)throws { lock.lock(); defer{lock.unlock()}; guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data }
    func remove(id:String)throws { lock.lock(); defer{lock.unlock()}; values.removeValue(forKey:id) }
}
/// Deliberately ignores cancellation, so awaiting the task is observable.
final class RuntimeDrainGate:@unchecked Sendable {
    private let lock = NSLock(); private var opened = false, entered = false
    private var waiters:[CheckedContinuation<Void,Never>] = []
    private let semaphore = DispatchSemaphore(value:0)
    var hasEntered:Bool { lock.lock(); defer{lock.unlock()}; return entered }
    func hold() async {
        await withCheckedContinuation { continuation in
            lock.lock(); entered = true
            if opened { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
        }
    }
    func holdSync() throws {
        lock.lock(); entered = true; let ready = opened; lock.unlock()
        if !ready, semaphore.wait(timeout:.now()+20) != .success { throw NativeDBError.message("scan fixture timed out") }
    }
    func release() {
        lock.lock(); opened = true; let pending = waiters; waiters = []; lock.unlock()
        semaphore.signal(); pending.forEach{$0.resume()}
    }
}
private final class RuntimeDrainCounter:@unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count:Int { lock.lock(); defer{lock.unlock()}; return value }
    func add(){lock.lock(); value += 1; lock.unlock()}
}
private actor RuntimeDrainWorker {
    let db:NativeDatabase,event:String,gate:RuntimeDrainGate,folder:URL
    init(db:NativeDatabase,event:String,gate:RuntimeDrainGate,folder:URL){self.db=db;self.event=event;self.gate=gate;self.folder=folder}
    func runNext() async throws -> Bool {
        guard var job = try db.claimJob(events:[event],leaseSeconds:3600) else{return false}
        job = try db.markJobDeliveryStarted(job)
        await gate.hold()
        try db.finishJob(job,result:["receipt":"synthetic-"+job.id])
        try Data(job.id.utf8).write(to:folder.appendingPathComponent(event+".receipt"))
        return true
    }
}
@MainActor private struct RuntimeDrainHarness {
    let resume:()->Void, stop:()->Void, drain:()async->Void
    let scanning:()->Bool,running:()->Bool,stopped:()->Bool,next:()->Date?
    let setError:((@escaping (Error)->Void))->Void
    let instance:AnyObject
}

@main enum NativeRuntimeDrainTests {
    @MainActor static var checks=0
    @MainActor static func check(_ value:Bool,_ label:String)throws {guard value else{throw NativeDBError.message("RuntimeDrain FAIL: "+label)};checks += 1}
    @MainActor static func until(_ label:String,_ condition:()throws->Bool)async throws {
        let deadline=Date().addingTimeInterval(8)
        while try !condition(){guard Date()<deadline else{throw NativeDBError.message("RuntimeDrain TIMEOUT: "+label)};try await Task.sleep(nanoseconds:5_000_000)}
    }
    @MainActor static func settle()async throws {try await Task.sleep(nanoseconds:35_000_000)}
    @MainActor private static func make(_ kind:String,db:NativeDatabase,runners:[InvoiceJobRunner],interval:TimeInterval=0.1,schedule:@escaping (NativeDatabase,Bool)throws->Int)->RuntimeDrainHarness {
        let secrets=RuntimeDrainSecrets()
        switch kind {
        case "mail":
            let r=NativeMailRuntime(db:db,store:secrets,runners:runners,clock:Date.init,interval:interval,enqueueDue:{db,_,_ in try schedule(db,false)})
            return .init(resume:r.resume,stop:r.stop,drain:r.stopAndDrain,scanning:{r.isScanning},running:{r.isRunning},stopped:{r.isStopped},next:{r.nextScan},setError:{r.onError=$0},instance:r)
        case "google":
            let r=GoogleCalendarRuntime(db:db,store:secrets,runner:runners[0],pushRunner:runners[1],clock:Date.init,interval:interval,enqueueDue:{db,_,_ in try schedule(db,false)})
            return .init(resume:r.resume,stop:r.stop,drain:r.stopAndDrain,scanning:{r.isScanning},running:{r.isRunning},stopped:{r.isStopped},next:{r.nextScan},setError:{r.onError=$0},instance:r)
        default:
            let r=CalendlyRuntime(db:db,store:secrets,runner:runners[0],clock:Date.init,interval:interval,enqueueDue:{db,_,_,force in try schedule(db,force)>0})
            return .init(resume:{r.resume(forceSync:true)},stop:r.stop,drain:r.stopAndDrain,scanning:{r.isScanning},running:{r.isRunning},stopped:{r.isStopped},next:{r.nextScan},setError:{r.onError=$0},instance:r)
        }
    }
    @MainActor static func tests(_ resources:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRMRuntimeDrain-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        func database(_ name:String)throws->NativeDatabase {try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))}
        for kind in ["mail","google","calendly"] {
            let count=kind=="mail" ? 3 : kind=="google" ? 2 : 1
            for scanFirst in [true,false] {
                let db=try database(kind+(scanFirst ? "-scan-first":"-scan-last")),folder=db.url.deletingLastPathComponent()
                let scanGate=RuntimeDrainGate(),scanCalls=RuntimeDrainCounter(),gates=(0..<count).map{_ in RuntimeDrainGate()}
                var ids:[String]=[],pending:[String]=[],runners:[InvoiceJobRunner]=[]
                for i in 0..<count {
                    let event="fixture.\(kind).\(i)"
                    ids.append(try db.enqueue(event,payload:[:]))
                    pending.append(try db.enqueue(event,payload:[:]))
                    let worker=RuntimeDrainWorker(db:db,event:event,gate:gates[i],folder:folder)
                    runners.append(InvoiceJobRunner(db:db,events:[event],runNext:{try await worker.runNext()}))
                }
                var h:RuntimeDrainHarness?=make(kind,db:db,runners:runners){db,_ in
                    scanCalls.add();try scanGate.holdSync();try db.setMetadata("scan.completed",value:"yes")
                    try Data("scan receipt".utf8).write(to:folder.appendingPathComponent("scan.receipt"));return 1
                }
                weak var weakRuntime=h!.instance
                defer{scanGate.release();gates.forEach{$0.release()};h?.stop()}
                var errors=0,firstDone=false,secondDone=false
                h!.setError{_ in errors += 1};h!.resume()
                try await until("all active \(kind)"){scanGate.hasEntered && gates.allSatisfy{$0.hasEntered}}
                for _ in 0..<3 {h!.resume()}
                let first=Task{@MainActor [runtime=h!] in await runtime.drain();firstDone=true}
                try await settle();first.cancel()
                let second=Task{@MainActor [runtime=h!] in await runtime.drain();secondDone=true}
                try await settle()
                try check(!firstDone && !secondDone && h!.stopped() && h!.scanning() && h!.running(),kind+" drains await real scan and all I/O despite caller cancellation")
                try check(try ids.allSatisfy{try db.job(id:$0)?.status=="running"} && pending.allSatisfy{try db.job(id:$0)?.status=="pending"},kind+" pending and running records preserved during stop")
                if scanFirst {scanGate.release();try await until("scan settled"){!h!.scanning()};try check(!firstDone && h!.running(),kind+" scan completion cannot bypass runner drain")}
                for (i,gate) in gates.enumerated(){gate.release();try await settle();if i<count-1 {try check(!firstDone,kind+" waits later owned runner \(i+1)")}}
                if !scanFirst {try await until("all workers settled"){!h!.running()};try check(!firstDone && h!.scanning(),kind+" worker completion cannot bypass scan drain");scanGate.release()}
                await first.value;await second.value
                try check(firstDone && secondDone && !h!.scanning() && !h!.running() && h!.next()==nil,kind+" drain includes MainActor cleanup")
                try check(try ids.allSatisfy{try db.job(id:$0)?.status=="done" && db.job(id:$0)?.result["receipt"] != nil} && pending.allSatisfy{try db.job(id:$0)?.status=="pending"},kind+" genuine in-flight receipts retained without resending queued work")
                try check(try db.metadata("scan.completed")=="yes" && Data(contentsOf:folder.appendingPathComponent("scan.receipt"))==Data("scan receipt".utf8),kind+" final scan DB and file effects awaited")
                for _ in 0..<3 {h!.resume();NotificationCenter.default.post(name:InvoiceJobRunner.didProcess,object:nil,userInfo:["database":db.url.path]);NotificationCenter.default.post(name:NativeDatabase.jobsDidChange,object:nil,userInfo:["database":db.url.path])}
                try await Task.sleep(nanoseconds:150_000_000)
                try check(scanCalls.count==1 && errors==0 && h!.next()==nil && !h!.scanning() && !h!.running(),kind+" stopped wake/force/observer/coalesced scan cannot restart")
                try check(try pending.allSatisfy{try db.job(id:$0)?.status=="pending"},kind+" no post-drain database effects")
                h=nil;try await settle();try check(weakRuntime==nil,kind+" callbacks do not retain stopped wrapper")
            }
            // Error callbacks may synchronously stop or launch another scan.
            for stopFromError in [true,false] {
                let db=try database(kind+(stopFromError ? "-error-stop":"-error-resume")),calls=RuntimeDrainCounter()
                let runners=(0..<count).map{i in InvoiceJobRunner(db:db,events:["error.\(i)"],runNext:{false})}
                var h:RuntimeDrainHarness?=make(kind,db:db,runners:runners){_,_ in calls.add();if calls.count==1 {throw NativeDBError.conflict};return 0}
                var errors=0
                h!.setError{_ in errors += 1;if stopFromError {h!.stop()} else {h!.resume()}}
                h!.resume();try await until("reentrant error"){errors==1 && !h!.scanning()}
                await h!.drain();try check(h!.next()==nil && !h!.running(),kind+" reentrant onError cannot install stale timer")
                try check(calls.count==(stopFromError ? 1:2),kind+" callback restart produces only intended scan")
                h=nil
            }
            do {
                let db=try database(kind+"-timer"),calls=RuntimeDrainCounter()
                let runners=(0..<count).map{i in InvoiceJobRunner(db:db,events:["timer.\(i)"],runNext:{false})}
                let h=make(kind,db:db,runners:runners){_,_ in calls.add();return 1}
                h.resume();try await until("timer armed"){h.next() != nil}
                h.stop();await h.drain();let before=calls.count
                try await Task.sleep(nanoseconds:180_000_000)
                try check(calls.count==before && h.next()==nil && !h.scanning(),kind+" synchronous stop followed by drain cancels retained timer")
            }
        }
        // Exercise the ordinary constructors, without any test-only initializer.
        do {
            let db=try database("production-empty"),secrets=RuntimeDrainSecrets()
            let mail=NativeMailRuntime(db:db,store:secrets,makeClient:{_,_ in fatalError("empty mail performed network")},send:{_ in throw NativeDBError.conflict},recoverTemporary:{})
            let google=GoogleCalendarRuntime(db:db,store:secrets,request:{_ in throw NativeDBError.conflict})
            let calendly=CalendlyRuntime(db:db,store:secrets,apiRequest:{_ in throw NativeDBError.conflict},relayRequest:{_ in throw NativeDBError.conflict})
            mail.resume();google.resume();calendly.resume()
            try await until("ordinary constructors idle"){!mail.isScanning && !google.isScanning && !calendly.isScanning && !mail.isRunning && !google.isRunning && !calendly.isRunning}
            try check(mail.nextScan==nil && google.nextScan==nil && calendly.nextScan==nil,"empty ordinary constructors retain no polling timer")
            await mail.stopAndDrain();await google.stopAndDrain();await calendly.stopAndDrain()
            mail.resume();google.resume();calendly.resume(forceSync:true)
            try check(mail.isStopped && google.isStopped && calendly.isStopped && !mail.isScanning && !google.isScanning && !calendly.isScanning,"ordinary constructors use terminal stop")
        }
    }
    static func main() async {
        do {let resources=URL(fileURLWithPath:CommandLine.arguments[1]);try await tests(resources);try await NativeRuntimeWorkerDrainTests.run(resources);print("Runtime wrapper drain: \(checks) checks passed")}
        catch {FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
    }
}
