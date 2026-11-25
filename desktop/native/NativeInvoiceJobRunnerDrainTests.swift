import Foundation

private actor RunnerDrainGate {
    private var entered=false,opened=false
    private var arrivals:[CheckedContinuation<Void,Never>]=[],waiters:[CheckedContinuation<Void,Never>]=[]
    func hold() async {
        entered=true;arrivals.forEach{$0.resume()};arrivals=[]
        if !opened{await withCheckedContinuation{waiters.append($0)}}
    }
    func wait() async {if !entered{await withCheckedContinuation{arrivals.append($0)}}}
    func release(){opened=true;waiters.forEach{$0.resume()};waiters=[]}
}
private actor RunnerDrainWorker {
    let db:NativeDatabase,event:String,folder:URL,mode:String,gates:[String:RunnerDrainGate]
    var calls=0,active=0,maximumActive=0
    init(db:NativeDatabase,event:String,folder:URL,mode:String="complete",gates:[String:RunnerDrainGate]=[:]){self.db=db;self.event=event;self.folder=folder;self.mode=mode;self.gates=gates}
    func runNext() async throws -> Bool {
        calls += 1
        guard var job=try db.claimJob(events:[event],leaseSeconds:3600) else{return false}
        active += 1;maximumActive=max(maximumActive,active);defer{active -= 1}
        job=try db.markJobDeliveryStarted(job)
        if let gate=gates[job.payload["index"] ?? ""]{await gate.hold()}
        if mode == "cancel"{try Task.checkCancellation()}
        if mode == "error"{throw NativeDBError.message("synthetic transport failed")}
        // Deliberately uncooperative transport completion: cancellation must not
        // let a drain return before these real SQLite and file effects finish.
        try db.transaction {
            try db.finishJob(job,result:["receipt":"synthetic-"+job.id])
            let effects=Int(try db.metadata("runner.effects") ?? "0") ?? 0
            try db.setMetadata("runner.effects",value:String(effects+1))
        }
        try Data(job.id.utf8).write(to:folder.appendingPathComponent(job.payload["index"]!+".receipt"))
        return true
    }
    func snapshot()->(Int,Int,Int){(calls,active,maximumActive)}
}

@main enum NativeInvoiceJobRunnerDrainTests {
    static var checks=0
    @MainActor static func check(_ value:Bool,_ label:String)throws{guard value else{throw NativeDBError.message("FAIL "+label)};checks += 1}
    @MainActor static func settle() async throws{try await Task.sleep(nanoseconds:30_000_000)}
    @MainActor static func until(_ label:String,_ condition:()->Bool) async throws {
        let end=Date().addingTimeInterval(4)
        while !condition(){guard Date()<end else{throw NativeDBError.message("TIMEOUT "+label)};try await Task.sleep(nanoseconds:5_000_000)}
    }
    @MainActor static func run(_ resources:URL) async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRMRunnerDrain-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:base)}
        func database(_ name:String)throws->(NativeDatabase,URL){let folder=base.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return(try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),folder)}
        func queue(_ db:NativeDatabase,_ event:String,_ index:String,at:Date?=nil)throws->String{try db.enqueue(event,payload:["index":index],runAt:at)}

        do {
            let (db,folder)=try database("drain"),event="runner.drain",gate=RunnerDrainGate()
            let one=try queue(db,event,"1"),two=try queue(db,event,"2")
            let worker=RunnerDrainWorker(db:db,event:event,folder:folder,gates:["1":gate])
            let runner=InvoiceJobRunner(db:db,events:[event],runNext:{try await worker.runNext()})
            var processed=0,errors=0,firstDone=false,secondDone=false
            runner.onError={_ in errors += 1}
            let observer=NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main){note in if note.userInfo?["database"] as? String == db.url.path{processed += 1}}
            defer{NotificationCenter.default.removeObserver(observer)}
            runner.kick();await gate.wait()
            let first=Task{@MainActor in await runner.stopAndDrain();firstDone=true}
            try await settle();first.cancel()
            let second=Task{@MainActor in await runner.stopAndDrain();secondDone=true}
            for _ in 0..<10{runner.kick();NotificationCenter.default.post(name:NativeDatabase.jobsDidChange,object:nil,userInfo:["database":db.url.path])}
            try await settle()
            try check(!firstDone && !secondDone && runner.isStopped && runner.isRunning,"concurrent drains and cancelled caller await real transport")
            try check(try db.job(id:one)?.status == "running" && db.job(id:two)?.status == "pending","stopping does not rewrite running or queued jobs")
            try check(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("1.receipt").path),"no invented completion before transport releases")
            await gate.release();await first.value;await second.value
            try check(firstDone && secondDone && !runner.isRunning && runner.isStopped && runner.nextWake == nil,"both drains complete only after task and timers settle")
            try check(try db.job(id:one)?.status == "done" && db.job(id:two)?.status == "pending","only in-flight completion is retained")
            try check(FileManager.default.fileExists(atPath:folder.appendingPathComponent("1.receipt").path),"drain includes last file I/O")
            try check(processed==0 && errors==0,"stopped generation emits no stale completion or failure callbacks")
            let ticks=try db.metadata("runner.effects");try await settle()
            try check(try db.metadata("runner.effects")==ticks,"no database effects after drained stop")
            let restarted=await runner.restartAfterDrain();try check(restarted && !runner.isStopped,"explicit restart reopens after drain")
            try await until("restart completes second job"){(try? db.job(id:two)?.status)=="done" && !runner.isRunning}
            let three=try queue(db,event,"3")
            try await until("notification observer restored"){(try? db.job(id:three)?.status)=="done" && !runner.isRunning}
            try check(try db.metadata("runner.effects")=="3" && processed==2,"restart restores notification wake with exactly-once local work")
            await runner.stopAndDrain();try check((await worker.snapshot()).2==1,"no overlapping runNext calls")
        }
        for mode in ["cancel","error"] {
            let(db,folder)=try database(mode),event="runner."+mode,gate=RunnerDrainGate(),id=try queue(db,event,"1")
            let worker=RunnerDrainWorker(db:db,event:event,folder:folder,mode:mode,gates:["1":gate]),runner=InvoiceJobRunner(db:db,events:[event],runNext:{try await worker.runNext()})
            var errors=0;runner.onError={_ in errors += 1};runner.kick();await gate.wait();let original=try db.job(id:id)
            let drain=Task{@MainActor in await runner.stopAndDrain()};try await settle();await gate.release();await drain.value
            try check(try db.job(id:id)==original,"lease, unknown delivery and result survive stopped "+mode)
            try check(errors==0 && runner.nextWake==nil && !runner.isRunning,"cancel/error after stop cannot schedule retry "+mode)
            try check(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("1.receipt").path),"failed transport is not reported complete "+mode)
        }
        for latest in ["stop","restart","cancelRestart"] {
            let(db,folder)=try database(latest),event="runner."+latest,firstGate=RunnerDrainGate(),secondGate=RunnerDrainGate()
            let one=try queue(db,event,"1"),two=try queue(db,event,"2")
            let worker=RunnerDrainWorker(db:db,event:event,folder:folder,gates:["1":firstGate,"2":secondGate]),runner=InvoiceJobRunner(db:db,events:[event],runNext:{try await worker.runNext()})
            runner.kick();await firstGate.wait()
            let older=Task{@MainActor in await runner.restartAfterDrain()};try await settle()
            let newer:Task<Bool,Never>?
            if latest == "cancelRestart"{older.cancel();newer=nil}else{newer=Task{@MainActor in await runner.restartAfterDrain()};try await settle()}
            let stopper:Task<Void,Never>?=latest == "stop" ? Task{@MainActor in await runner.stopAndDrain()}:nil
            try await settle();try check((await worker.snapshot()).2==1,"restart waits previous generation "+latest)
            await firstGate.release();let oldResult=await older.value,newResult=await newer?.value
            try check(!oldResult,"superseded/cancelled restart cannot reopen runner "+latest)
            if latest == "restart" {
                try check(newResult==true,"newest restart wins")
                await secondGate.wait();try check(runner.isRunning && !runner.isStopped,"old completion cannot clear replacement task")
                let drain=Task{@MainActor in await runner.stopAndDrain()};try await settle();await secondGate.release();await drain.value
                try check(try db.job(id:one)?.status=="done" && db.job(id:two)?.status=="done","serial generations preserve actual results")
            }else {
                await stopper?.value
                try check(runner.isStopped && !runner.isRunning && newResult != true,"last stop or cancelled restart remains stopped")
                try check(try db.job(id:two)?.status=="pending","losing restart cannot claim next job")
            }
            try check((await worker.snapshot()).2==1,"never overlap across restart/stop race "+latest)
            await runner.stopAndDrain()
        }
        do {
            let(db,folder)=try database("timer"),event="runner.timer"
            let first=try queue(db,event,"1",at:Date().addingTimeInterval(0.2)),worker=RunnerDrainWorker(db:db,event:event,folder:folder)
            let runner=InvoiceJobRunner(db:db,events:[event],runNext:{try await worker.runNext()});runner.kick()
            try await until("future timer scheduled"){runner.nextWake != nil}
            try check(try db.job(id:first)?.status=="pending","future job remains pending until due")
            try await until("due timer executes"){(try? db.job(id:first)?.status)=="done" && !runner.isRunning && runner.nextWake==nil}
            let second=try queue(db,event,"2",at:Date().addingTimeInterval(0.15))
            try await until("second timer scheduled"){runner.nextWake != nil};await runner.stopAndDrain()
            try await Task.sleep(nanoseconds:220_000_000)
            try check(try db.job(id:second)?.status=="pending" && runner.nextWake==nil,"cancelled timer never restarts stopped runner")
            try check(await runner.restartAfterDrain(),"explicit restart after cancelled timer")
            try await until("explicit restart executes pending"){(try? db.job(id:second)?.status)=="done" && !runner.isRunning}
            await runner.stopAndDrain();try check(try db.metadata("runner.effects")=="2","due scheduling still completes exactly twice")
        }
        do {
            let(db,folder)=try database("failure"),event="runner.failure",id=try queue(db,event,"1")
            let worker=RunnerDrainWorker(db:db,event:event,folder:folder,mode:"error"),runner=InvoiceJobRunner(db:db,events:[event],runNext:{try await worker.runNext()})
            var failures=0;runner.onError={_ in failures += 1};runner.kick()
            try await until("live failure retry"){failures==1 && runner.nextWake != nil}
            try check((runner.nextWake?.timeIntervalSinceNow ?? 0)>25,"normal failure retains 30 second retry")
            await runner.stopAndDrain();try check(try db.job(id:id)?.status=="running" && runner.nextWake==nil,"stop cancels retry without cancelling durable job")
        }
        print("Invoice runner drain: \(checks) checks passed")
    }
    static func main() async {do{try await run(URL(fileURLWithPath:CommandLine.arguments[1]))}catch{fputs("\(error)\n",stderr);exit(1)}}
}
