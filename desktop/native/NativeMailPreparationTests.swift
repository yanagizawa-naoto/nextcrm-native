import Foundation
import Darwin

private final class PreparationCredentials:InvoiceMailCredentialStore {
    func load(interactive:Bool)throws->InvoiceMailAccount?{.init(from:"test@example.invalid",apiKey:"synthetic")}
    func save(_ account:InvoiceMailAccount)throws{}
    func remove()throws{}
}
private actor PreparationGate {
    var entered=false,ended=0
    private var continuation:CheckedContinuation<Void,Never>?
    func suspend()async{entered=true;await withCheckedContinuation{continuation=$0}}
    func release(){continuation?.resume();continuation=nil}
    func finish(){ended+=1}
}
@main enum NativeMailPreparationTests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{FileHandle.standardError.write(Data(("FAIL preparation: "+label+"\n").utf8));throw NativeDBError.message("FAIL preparation: "+label)};checks+=1}
    static func db(_ root:URL,_ resources:URL)throws->NativeDatabase{try .init(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))}
    static func entries(_ root:URL)throws->[String]{let path=root.appendingPathComponent(NativeMailPreparationFiles.namespace);if !FileManager.default.fileExists(atPath:path.path){return []};return try FileManager.default.contentsOfDirectory(atPath:path.path).filter{$0 != ".lock"}}
    static func drain(_ db:NativeDatabase,page:Int=64)throws->(removed:Int,live:Int,preserved:Int,pages:Int){let cursor=try NativeMailPreparationFiles.Recovery(db:db);var result=(removed:0,live:0,preserved:0,pages:0);while true{let p=try cursor.step(maximumEntries:page);result.removed+=p.removed;result.live+=p.live;result.preserved+=p.preserved;result.pages+=1;try check(p.examined<=page,"bounded cursor");if p.finished || p.busy{return result};guard result.pages<1000 else{throw NativeDBError.conflict}}}
    static func response(_ request:URLRequest)->(Data,HTTPURLResponse){(Data("{\"id\":\"10000000-0000-4000-8000-000000000001\"}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)}
    static func main()async{do{let resources=URL(fileURLWithPath:CommandLine.arguments[1]);if CommandLine.arguments.contains("--child"){try await child(resources);return};try await run(resources)}catch{FileHandle.standardError.write(Data("Preparation tests (\(checks) checks): \(error)\n".utf8));exit(1)}}
    static func child(_ resources:URL)async throws {
        let parent=URL(fileURLWithPath:CommandLine.arguments[2]),phase=CommandLine.arguments[3]
        func ready(_ value:[String:String])throws{try JSONEncoder().encode(value).write(to:parent.appendingPathComponent("ready.json"),options:.atomic)}
        if phase=="plugin-live" {
            let root=parent.appendingPathComponent("workspace"),database=try db(root,resources)
            let mail=NativePluginsMail(root:root,store:PreparationCredentials(),request:{request,file in
                try ready(["root":root.path,"file":file.path]);while true{pause()};return response(request)
            })
            try await mail.send(to:"target@example.invalid",subject:"合成",text:"未送信の合成通知");withExtendedLifetime(database){}
        }else{
            let fixture=try ReportMailFixture(resources:resources,parent:parent),schedule=try fixture.create(format:"both"),job=try fixture.job(schedule)
            try ready(["root":fixture.root.path,"job":job.id])
            let worker=ReportMailWorker(db:fixture.db,account:{fixture.credentials},request:fixture.transport.request,clock:{fixture.clock.now},preparationCheckpoint:{point in
                if point==(phase.hasPrefix("committed-") ? "committed":phase){kill(getpid(),SIGKILL)}
            })
            _ = try await worker.runNext();throw NativeDBError.message("child did not reach checkpoint")
        }
    }
    static func run(_ resources:URL)async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Preparation-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:root)}
        try await plugin(resources,base:root)
        try publication(resources,base:root)
        try await crashes(resources,base:root)
        try await stopping(resources,base:root)
        try await reportStopping(resources,base:root)
        // Existing NativeReportMailTests remains in its separate production runner.
        let result:[String:Any]=["checks":checks,"actualSIGKILLPhases":9,"actualPluginLiveProcess":true,"realProviderCalls":0,"realKeychainCalls":0]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),encoding:.utf8)!)
    }
    static func plugin(_ resources:URL,base:URL)async throws {
        let root=base.appendingPathComponent("plugin"),database=try db(root,resources);var file:URL?,calls=0
        let mail=NativePluginsMail(root:root,store:PreparationCredentials(),request:{request,body in
            calls+=1;file=body;let page=try drain(database)
            try check(page.live==1 && FileManager.default.fileExists(atPath:body.path),"actual plugin request lifetime protects body")
            let json=try JSONSerialization.jsonObject(with:Data(contentsOf:body)) as! [String:Any]
            try check(json["text"] as? String=="本文😀" && request.value(forHTTPHeaderField:"Idempotency-Key")?.hasPrefix("nextcrm/plugin/")==true,"plugin body and idempotency contract unchanged")
            return response(request)
        })
        try await mail.send(to:"target@example.invalid",subject:"合成",text:"本文😀")
        try check(calls==1 && !FileManager.default.fileExists(atPath:file!.path) && entries(root).isEmpty,"plugin ordinary success cleans complete owned preparation")
        let fail=NativePluginsMail(root:root,store:PreparationCredentials(),request:{_,body in file=body;throw CancellationError()})
        do{try await fail.send(to:"target@example.invalid",subject:"合成",text:"取消");throw NativeDBError.conflict}catch let error as MailSendError{try check(error.retryable && !error.review,"existing transport cancellation classification preserved")}
        try check(try !FileManager.default.fileExists(atPath:file!.path) && entries(root).isEmpty,"plugin cancelled request cleans after callback exits")
        // Only the newly leased namespace is considered. Unknown child data and
        // legacy locations are not adopted from their lack of DB references.
        var held:NativeMailPreparationFiles.Lease?=try NativeMailPreparationFiles.create(.plugin,root:root)
        let heldURL=held!.url;try Data("unknown".utf8).write(to:heldURL.appendingPathComponent("unrelated"));held=nil
        let legacy=root.appendingPathComponent("report-staging");try FileManager.default.createDirectory(at:legacy,withIntermediateDirectories:true);try Data("legacy".utf8).write(to:legacy.appendingPathComponent("keep"))
        for i in 0..<150{try FileManager.default.createDirectory(at:root.appendingPathComponent(NativeMailPreparationFiles.namespace).appendingPathComponent("unknown-\(i)"),withIntermediateDirectories:true)}
        var abandoned:NativeMailPreparationFiles.Lease?=try NativeMailPreparationFiles.create(.plugin,root:root)
        let reclaim=abandoned!.url;_ = try InvoiceMail.prepareText(root:reclaim,id:abandoned!.id,from:"a@example.invalid",to:"b@example.invalid",subject:"合成",message:"回収")
        try Data().write(to:reclaim.appendingPathComponent("hold"));abandoned=nil
        try FileManager.default.removeItem(at:reclaim.appendingPathComponent("hold"))
        let scan=try drain(database,page:17)
        try check(scan.pages>8 && scan.removed==1 && scan.preserved==151 && Data(contentsOf:heldURL.appendingPathComponent("unrelated"))==Data("unknown".utf8),"cursor crosses retained first pages without deleting unknown entries")
        try check(try Data(contentsOf:legacy.appendingPathComponent("keep"))==Data("legacy".utf8),"legacy staging is outside ownership")
    }
    static func publication(_ resources:URL,base:URL)throws {
        let root=base.appendingPathComponent("publication"),database=try db(root,resources)
        func prepare(uppercase:Bool=false)throws->(NativeMailPreparationFiles.Lease,InvoiceMailBody,NativeJob){let lease=try NativeMailPreparationFiles.create(.report,root:root),body=try InvoiceMail.prepareText(root:lease.url,id:lease.id,from:"a@example.invalid",to:"b@example.invalid",subject:"合成",message:"公開前本文")
            _=try database.enqueue("reports.scheduled",payload:[:],id:uppercase ? UUID().uuidString:UUID().uuidString.lowercased());let job=try database.claimJob(events:["reports.scheduled"])!;return (lease,body,job)}
        enum Rollback:Error{case expected}
        do{let (lease,body,job)=try prepare(uppercase:true);let final=try InvoiceMail.bodyURL(root:root,id:job.id)
            do{try database.transaction{try database.transaction{try lease.publish(body,job:job,db:database);try database.recordJobResult(job,result:["sha256":body.sha256,"bytes":String(body.bytes)])}
                try check(FileManager.default.fileExists(atPath:final.path),"nested publication exists until outer outcome")
                let held=try drain(database);try check(held.live==1,"same-process live producer protects tentative publication")
                throw Rollback.expected}}catch Rollback.expected{}
            try check(!FileManager.default.fileExists(atPath:final.path) && database.job(id:job.id)?.result["sha256"]==nil,"outer rollback unlinks only newly published inode and reverts DB reference")
        }
        try check(try entries(root).isEmpty,"resolved rollback releases owned attachment/body directory")
        do{let (lease,body,job)=try prepare();let final=try InvoiceMail.bodyURL(root:root,id:job.id),sentinel=Data("new owner body".utf8)
            do{try database.transaction{try lease.publish(body,job:job,db:database);try FileManager.default.removeItem(at:final);try sentinel.write(to:final);throw Rollback.expected}}catch Rollback.expected{}
            try check(try Data(contentsOf:final)==sentinel,"rollback never removes replacement final inode")
        }
        let kept=try drain(database);try check(kept.preserved==1,"unknown replacement keeps intent for operator review")
    }
    static func crashes(_ resources:URL,base:URL)async throws {
        for phase in ["plugin-live","created","exported","body","intent","linked","recorded","committed","committed-terminal","committed-missing"] {
            let parent=base.appendingPathComponent("crash-"+phase);try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            let process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=[resources.path,parent.path,phase,"--child"];try process.run();defer{if process.isRunning{kill(process.processIdentifier,SIGKILL);process.waitUntilExit()}}
            let ready=parent.appendingPathComponent("ready.json");let deadline=Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath:ready.path),process.isRunning,Date()<deadline{try await Task.sleep(nanoseconds:10_000_000)}
            guard FileManager.default.fileExists(atPath:ready.path)else{process.terminate();throw NativeDBError.message("child ready timeout")}
            let state=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:ready)),root=URL(fileURLWithPath:state["root"]!)
            if phase=="plugin-live" {
                let database=try db(root,resources),live=try drain(database)
                try check(live.live==1 && FileManager.default.fileExists(atPath:state["file"]!),"actual other process live plugin lease prevents cleanup")
                kill(process.processIdentifier,SIGSTOP)
                try check(try drain(database).live==1,"stopped process retains lock; no TTL guesses")
                kill(process.processIdentifier,SIGKILL)
            }
            process.waitUntilExit();try check(process.terminationReason == .uncaughtSignal && process.terminationStatus==SIGKILL,"actual owned SIGKILL checkpoint "+phase)
            let database=try db(root,resources),job=try state["job"].flatMap{try database.job(id:$0)}
            let final=try state["job"].map{try InvoiceMail.bodyURL(root:root,id:$0)},bytes=try final.flatMap{FileManager.default.fileExists(atPath:$0.path) ? try Data(contentsOf:$0):nil}
            if phase=="committed-terminal" || phase=="committed-missing" {
                let final=final!,job=job!,leaf=try entries(root).first!,directory=root.appendingPathComponent(NativeMailPreparationFiles.namespace).appendingPathComponent(leaf),stage=directory.appendingPathComponent("mail-outbox/"+leaf+".json"),staged=try Data(contentsOf:stage)
                try check(staged==bytes,"intent stage is the exact published body")
                var pin:Int32 = -1
                if phase=="committed-terminal"{pin=open(directory.appendingPathComponent(".lease").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC);guard pin>=0,flock(pin,LOCK_EX|LOCK_NB)==0 else{throw NativeDBError.conflict}}
                else{try FileManager.default.removeItem(at:final)}
                var calls=0
                let worker=ReportMailWorker(db:database,account:{.init(from:"reports@example.invalid",apiKey:"report-test-key")},request:{request,_ in calls+=1;return response(request)},clock:{ISO8601DateFormatter().date(from:"2026-11-19T01:02:00Z")!})
                _ = try await worker.runNext()
                if pin>=0{flock(pin,LOCK_UN);close(pin)}
                let after=try database.job(id:job.id)!,cleanup=try drain(database)
                if phase=="committed-terminal" {
                    try check(calls==1 && after.status=="done" && !FileManager.default.fileExists(atPath:final.path),"actual retry worker completes and removes final before prep is recoverable")
                    try check(cleanup.removed==1 && entries(root).isEmpty,"known terminal missing-final preparation is reclaimed with shared C predicate")
                }else {
                    try check(calls==0 && after.status=="failed" && after.result["sha256"]==job.result["sha256"],"actual retry refuses missing published body without external send")
                    try check(cleanup.preserved==1 && cleanup.removed==0 && Data(contentsOf:stage)==staged,"nonterminal missing final retains last exact stage copy")
                }
                try check(try database.job(id:job.id)==after,"terminal/held recovery never rewrites actual worker result")
                continue
            }
            let recovered=try drain(database)
            try check(recovered.removed==1 && entries(root).isEmpty,"dead new-format preparation reclaimed at "+phase)
            if let job,let final {
                if phase=="committed"{try check(job.result["sha256"] != nil && Data(contentsOf:final)==bytes,"committed pending request keeps exact final body")}
                else{try check(job.result["sha256"]==nil && !FileManager.default.fileExists(atPath:final.path),"unpublished crash rolls back reference and removes own linked file only")}
                try check(try database.job(id:job.id)==job,"recovery never changes job/retry/receipt state")
                if phase=="linked" || phase=="committed" {
                    var calls=0,sent:Data?
                    let now=ISO8601DateFormatter().date(from:"2026-11-19T01:02:00Z")!
                    let worker=ReportMailWorker(db:database,account:{.init(from:"reports@example.invalid",apiKey:"report-test-key")},request:{request,file in calls+=1;sent=try Data(contentsOf:file);return response(request)},clock:{now})
                    _ = try await worker.runNext()
                    try check(try calls==1 && database.job(id:job.id)?.status=="done","same-ID report resumes after "+phase+" crash")
                    if phase=="committed"{try check(sent==bytes,"committed crash resume sends byte-exact frozen body")}
                }
            }
        }
    }
    static func stopping(_ resources:URL,base:URL)async throws {
        let root=base.appendingPathComponent("stop"),database=try db(root,resources),gate=PreparationGate();var body:URL?
        let identity=try CRMService.bootstrap(database,resources:resources.appendingPathComponent("../../prisma"))
        let mail=NativePluginsMail(root:root,store:PreparationCredentials(),request:{request,file in body=file;await gate.suspend();return response(request)})
        var definition=NativePluginDefinition(id:"preparation-test",name:"合成通知",version:"0.1.0",sdk:"^0.2.0",description:"",permissions:["notify"])
        definition.events=[.init(event:"fixture/notification",handler:{_,context in try await context.notify(.init(userIds:[identity.id],subject:"停止",text:"join"))})]
        let host=try NativePluginHost(db:database,definitions:[definition],sendNotification:{try await mail.send(to:$0,subject:$1,text:$2)},transport:{_,_ in throw NativeDBError.conflict})
        _=try database.insert("InstalledPlugin",values:["id":.text(definition.id),"version":.text(definition.version),"status":.text("ENABLED"),"settings":.text("{}")],actor:identity.id)
        host.attach();let jobID=try database.enqueue("plugin/event-dispatch",payload:["pluginId":definition.id,"event":"fixture/notification","data":"{}"])
        let runtime=NativePluginsRuntime(host:host)
        await runtime.start();let deadline=Date().addingTimeInterval(5)
        while !(await gate.entered),Date()<deadline{try await Task.sleep(nanoseconds:10_000_000)}
        let entered=await gate.entered;try check(entered,"actual PluginRuntime/Host/Context/adapter reaches callback")
        let first=Task{await runtime.stop();await gate.finish()},second=Task{await runtime.stop();await gate.finish()}
        try await Task.sleep(nanoseconds:30_000_000);let ended=await gate.ended
        try check(ended==0 && FileManager.default.fileExists(atPath:body!.path) && drain(database).live==1,"actual plugin stop callers wait; accepted callback retains live body")
        first.cancel();await gate.release();await first.value;await second.value
        let all=await gate.ended;try check(all==2 && entries(root).isEmpty,"caller cancellation does not abandon plugin cleanup or drain")
        let snapshot=await runtime.snapshot();try check(!snapshot.running && !snapshot.working && database.job(id:jobID)?.status=="retry","actual plugin runtime closes acceptance and retains retry state")
        await runtime.wake();try await Task.sleep(nanoseconds:10_000_000);try check(try entries(root).isEmpty,"stopped plugin owner accepts no new preparation")
    }
    final class ExportGate {
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        func awaitEntry()->Bool{entered.wait(timeout:.now()+5) == .success}
        func block(){entered.signal();release.wait()}
    }
    static func reportStopping(_ resources:URL,base:URL)async throws {
        let f=try ReportMailFixture(resources:resources,parent:base),schedule=try f.create(format:"csv"),job=try f.job(schedule),gate=ExportGate(),ended=PreparationGate()
        let worker=f.worker(export:{snapshot,section,format,url,title in
            let count=try NativeReportExport.write(snapshot,section:section,format:format,to:url,title:title);gate.block();return count
        })
        let runner=await MainActor.run{InvoiceJobRunner(db:f.db,events:[NativeReportQueue.event],runNext:{try await worker.runNext()})}
        await MainActor.run{runner.kick()};let entered=await Task.detached{gate.awaitEntry()}.value;try check(entered,"actual report exporter reaches cancellation-ignoring callback")
        let first=Task{@MainActor in await runner.stopAndDrain();await ended.finish()},second=Task{@MainActor in await runner.stopAndDrain();await ended.finish()}
        try await Task.sleep(nanoseconds:30_000_000);let early=await ended.ended
        try check(early==0 && drain(f.db).live==1,"report stop retains live export until callback really exits")
        first.cancel();gate.release.signal();await first.value;await second.value
        let all=await ended.ended;try check(all==2 && entries(f.root).isEmpty && f.transport.bodies.isEmpty,"actual report cancellation joins export then cleans without send")
        try check(try f.db.job(id:job.id)?.status=="retry","cancelled report remains retryable with no lost published body")
    }
}
