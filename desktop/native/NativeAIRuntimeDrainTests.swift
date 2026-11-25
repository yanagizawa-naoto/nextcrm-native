import Foundation

private actor AIRuntimeDrainGate {
    private var opened=false,entered=0
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func hold() async {entered += 1;if !opened{await withCheckedContinuation{waiters.append($0)}}}
    func count()->Int{entered}
    func release(){opened=true;waiters.forEach{$0.resume()};waiters=[]}
}
@main enum NativeAIRuntimeDrainTests {
    static var checks=0
    @MainActor static func check(_ value:Bool,_ label:String)throws{guard value else{throw NativeDBError.message("FAIL "+label)};checks += 1}
    @MainActor static func wait(_ label:String,_ condition:() async throws -> Bool) async throws {
        let deadline=Date().addingTimeInterval(5)
        while !(try await condition()){guard Date()<deadline else{throw NativeDBError.message("TIMEOUT "+label)};try await Task.sleep(nanoseconds:5_000_000)}
    }
    static func vector()throws->NativeEmbeddingVector{var values=[Float](repeating:0,count:1536);values[0]=1;return try .init(values)}
    static func output(_ name:String)->NativeEnrichmentOutput{.init(enrichments:[name:.init(field:name,value:.string("検証値"),confidence:0.8,source:"https://fixture.invalid")],status:.completed)}
    final class Fixture {
        let root:URL,db:NativeDatabase,service:CRMService,store=NativeAIQAServices()
        let env=NativeAIEnvironment(lookup:{["OPENAI_API_KEY":"qa-openai","FIRECRAWL_API_KEY":"qa-firecrawl","ANTHROPIC_API_KEY":"qa-anthropic","E2B_API_KEY":"qa-e2b"][$0]})
        init(_ resources:URL)throws{
            root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRMAIRuntimeDrain-"+UUID().uuidString.lowercased())
            db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
        }
        deinit{try? FileManager.default.removeItem(at:root)}
        func contact()throws->NativeRecord{try db.insert("crm_Contacts",values:["first_name":.text("確認"),"last_name":.text("連絡先"),"email":.text("qa@example.invalid"),"createdBy":.text(service.identity.id),"v":.integer(0)],actor:service.identity.id)}
        func target()throws->NativeRecord{try db.insert("crm_Targets",values:["first_name":.text("確認"),"last_name":.text("営業先"),"company":.text("試験株式会社"),"email":.text("qa@example.invalid"),"created_by":.text(service.identity.id)],actor:service.identity.id)}
        func account()throws->(NativeRecord,String){let row=try db.insert("crm_Accounts",values:["name":.text("ACCOUNT_GATE"),"createdBy":.text(service.identity.id),"v":.integer(0)],actor:service.identity.id);let id=try db.enqueue(NativeEmbeddingJobs.event(.account),payload:["actorID":service.identity.id,"record_id":row["id"].string]);return(row,id)}
        func document()throws->(NativeRecord,String){
            let text="DOCUMENT_GATE 日本語の文書",actor=service.identity.id
            let row=try db.insert("Documents",values:["document_name":.text("文書.txt"),"document_system_type":.text("OTHER"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("local"),"key":.text(UUID().uuidString),"content_hash":.text(NativeEmbeddingVector.hash(text)),"processing_status":.text("READY"),"summary":.null,"createdBy":.text(actor),"created_by_user":.text(actor),"assigned_user":.text(actor),"visibility":.text("private")],actor:actor)
            let source=try db.enqueue("document/uploaded",payload:["documentId":row["id"].string]);try db.reserveDocumentProcessing(row,jobID:source)
            let claimed=try db.claimJob(events:["document/uploaded"])!
            try db.saveDocumentProcessing(row,jobID:source,textBytes:text.utf8.count,thumbnail:nil,note:""){try $0(text)}
            try db.finishJob(claimed,result:["outcome":"ready"])
            return(row,try db.enqueueDocumentAI(row,actor:actor)!)
        }
    }
    @MainActor static func controls(_ resources:URL) async throws {
        let f=try Fixture(resources),group=NativeRuntimeControlTasks(),one=AIRuntimeDrainGate(),two=AIRuntimeDrainGate()
        var calls=0,returned=false,secondReturned=false
        let accepted=group.performControl(key:"same"){
            calls += 1;await one.hold();try? f.db.setMetadata("control.one",value:"finished")
            try? Data("finished".utf8).write(to:f.root.appendingPathComponent("control-one.txt"))
        }
        var coalesced=true
        for _ in 0..<25{coalesced=group.performControl(key:"same"){calls += 1000} && coalesced}
        try check(accepted && coalesced && group.pendingCount==1,"same key coalesces without losing admitted operation")
        _ = group.performControl(key:"other"){calls += 1;await two.hold();try? f.db.setMetadata("control.two",value:"finished")}
        try await wait("two controls start"){let a=await one.count(),b=await two.count();return a==1 && b==1}
        let drain=Task{@MainActor in await group.closeAndDrain();returned=true},other=Task{@MainActor in await group.closeAndDrain();secondReturned=true}
        try await Task.sleep(nanoseconds:20_000_000);drain.cancel()
        try check(group.isClosed && !group.performControl(key:"late"){calls += 10000},"closed group rejects late callbacks")
        try check(!returned && !secondReturned && group.pendingCount==2,"cancelled caller and parallel drain still join every operation")
        await one.release();try await wait("first control joined"){group.pendingCount==1}
        try check(!returned && !secondReturned,"one completed control cannot hide a second pending control")
        await two.release();await drain.value;await other.value
        try check(calls==2 && returned && secondReturned && group.pendingCount==0,"all admitted controls complete exactly once")
        try check(try f.db.metadata("control.one")=="finished" && f.db.metadata("control.two")=="finished" && FileManager.default.fileExists(atPath:f.root.appendingPathComponent("control-one.txt").path),"control drain includes final SQLite and file writes")

        let reusable=NativeRuntimeControlTasks(),first=AIRuntimeDrainGate(),next=AIRuntimeDrainGate()
        _ = reusable.performControl(key:"key"){await first.hold()}
        try await wait("old key operation starts"){await first.count()==1};await first.release()
        try await wait("old operation releases registration"){reusable.pendingCount==0}
        _ = reusable.performControl(key:"key"){await next.hold();try? f.db.setMetadata("control.reused",value:"finished")}
        try await wait("new same key operation starts"){await next.count()==1}
        try await Task.sleep(nanoseconds:20_000_000)
        try check(reusable.pendingCount==1,"old completion does not erase later same-key operation")
        let last=Task{@MainActor in await reusable.closeAndDrain()};try await Task.sleep(nanoseconds:20_000_000)
        try check(try f.db.metadata("control.reused")==nil && reusable.pendingCount==1,"new same-key operation remains joined")
        await next.release();await last.value;try check(try f.db.metadata("control.reused")=="finished" && reusable.pendingCount==0,"new key generation finishes before drain returns")
        let immediate=NativeRuntimeControlTasks();var lateCalls=0
        _ = immediate.performControl(key:"not-started"){lateCalls += 1};await immediate.closeAndDrain()
        try check(lateCalls==0 && immediate.pendingCount==0,"accepted but not started control is cancelled before executing")
    }
    @MainActor static func notifications(path:String,id:String,count:Int=1){for _ in 0..<count{NotificationCenter.default.post(name:NativeDatabase.aiProgress,object:nil,userInfo:["database":path,"cancelledJob":id])}}
    @MainActor static func contact(_ resources:URL) async throws {
        let f=try Fixture(resources),gate=AIRuntimeDrainGate(),api=NativeContactEnrichmentService(service:f.service,store:f.store,environment:f.env)
        let row=try f.contact(),another=try f.contact()
        let ids=try [api.request(contactIDs:[row["id"].string],fields:NativeEnrichmentField.contactPresets,mode:.review)[0],api.request(contactIDs:[another["id"].string],fields:NativeEnrichmentField.contactPresets,mode:.review)[0]]
        let runtime=NativeContactEnrichmentRuntime(db:f.db,store:f.store,environment:f.env,enrich:{_,_,_,_,_ in await gate.hold();try Data("provider finished".utf8).write(to:f.root.appendingPathComponent("contact-provider.txt"));return output("position")})
        runtime.resume();try await wait("contact provider"){await gate.count()==1}
        try api.cancel(f.db.job(id:ids[0])!);let cancelled=try f.db.job(id:ids[0])
        notifications(path:f.db.url.path,id:ids[0],count:25)
        try check(runtime.pendingControlCount==1,"contact cancellation callbacks are coalesced and tracked")
        notifications(path:f.db.url.path+".other",id:"foreign")
        try check(runtime.pendingControlCount==1,"contact ignores other database control")
        var returned=false;let drain=Task{@MainActor in await runtime.stopAndDrain();returned=true}
        try await Task.sleep(nanoseconds:20_000_000);drain.cancel()
        try check(runtime.isStopped && runtime.isRunning && !returned,"contact waits cancellation-ignoring provider")
        await gate.release();await drain.value
        try check(returned && !runtime.isRunning && runtime.pendingControlCount==0 && runtime.nextWake==nil,"contact drains runner and control tasks")
        try check(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("contact-provider.txt").path),"contact final provider write completed before return")
        try check(try f.db.job(id:ids[0])?.status != "done" && f.db.job(id:ids[1])?.status=="pending","contact cancellation never publishes result or claims next job")
        try check(try f.db.job(id:ids[0])==cancelled && cancelled?.status=="cancelled","contact runtime preserves actual service cancellation and receipt")
        let prior=try f.db.job(id:ids[0]);runtime.resume();notifications(path:f.db.url.path,id:ids[0]);NotificationCenter.default.post(name:NativeAIKeys.didChange,object:nil,userInfo:["database":f.db.url.path])
        try await Task.sleep(nanoseconds:30_000_000)
        let calls=await gate.count();try check(try f.db.job(id:ids[0])==prior && runtime.pendingControlCount==0 && calls==1,"contact terminal stop rejects wake and cancellation callbacks")
    }
    @MainActor static func target(_ resources:URL) async throws {
        let f=try Fixture(resources),gate=AIRuntimeDrainGate(),api=NativeTargetEnrichmentService(service:f.service,store:f.store,environment:f.env)
        let row=try f.target(),another=try f.target()
        let ids=try [api.request(targetIDs:[row["id"].string],fields:NativeTargetEnrichment.fields(NativeTargetEnrichment.automaticNames),mode:.review)[0],api.request(targetIDs:[another["id"].string],fields:NativeTargetEnrichment.fields(NativeTargetEnrichment.automaticNames),mode:.review)[0]]
        let runtime=NativeTargetEnrichmentRuntime(db:f.db,store:f.store,environment:f.env,review:{_,_,_,_ in await gate.hold();try Data("provider finished".utf8).write(to:f.root.appendingPathComponent("target-provider.txt"));return output("industry")},agent:{_,_,_,_ in throw NativeAIError(message:"unexpected fake agent path")})
        runtime.resume();try await wait("target provider"){await gate.count()==1}
        try api.cancel(f.db.job(id:ids[0])!);let cancelled=try f.db.job(id:ids[0])
        notifications(path:f.db.url.path,id:ids[0],count:25);try check(runtime.pendingControlCount==1,"target cancellation callbacks coalesce")
        var returned=false;let drain=Task{@MainActor in await runtime.stopAndDrain();returned=true};try await Task.sleep(nanoseconds:20_000_000);drain.cancel()
        try check(runtime.isStopped && runtime.isRunning && !returned,"target awaits real provider completion")
        await gate.release();await drain.value
        try check(returned && !runtime.isRunning && runtime.pendingControlCount==0 && runtime.nextWake==nil,"target drains all tasks")
        try check(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("target-provider.txt").path),"target joins provider file write")
        try check(try f.db.job(id:ids[0])?.status != "done" && f.db.job(id:ids[1])?.status=="pending","target stop preserves unfinished work")
        try check(try f.db.job(id:ids[0])==cancelled && cancelled?.status=="cancelled","target runtime preserves actual service cancellation")
        let prior=try f.db.job(id:ids[0]);runtime.resume();notifications(path:f.db.url.path,id:ids[0]);NotificationCenter.default.post(name:NativeAIKeys.didChange,object:nil,userInfo:["database":f.db.url.path]);try await Task.sleep(nanoseconds:30_000_000)
        let calls=await gate.count();try check(try f.db.job(id:ids[0])==prior && runtime.pendingControlCount==0 && calls==1,"target terminal stop rejects callbacks")
    }
    @MainActor static func embedding(_ resources:URL) async throws {
        let f=try Fixture(resources),crm=AIRuntimeDrainGate(),document=AIRuntimeDrainGate()
        let (account,accountJob)=try f.account(),(row,docJob)=try f.document()
        let runtime=NativeEmbeddingRuntime(db:f.db,store:f.store,environment:f.env,generate:{text,_ in
            let name:String;if text.contains("ACCOUNT_GATE"){await crm.hold();name="crm"}else{await document.hold();name="document"}
            try Data("provider finished".utf8).write(to:f.root.appendingPathComponent(name+"-provider.txt"));return try vector()
        },summarize:{_,_ in "要約"},classify:{_,_,_,_ in "OTHER"})
        runtime.resume();try await wait("both embedding queues"){let a=await crm.count(),b=await document.count();return a==1 && b==1}
        try f.service.cancelEmbeddingJob(f.db.job(id:docJob)!);let cancelled=try f.db.job(id:docJob)
        notifications(path:f.db.url.path,id:docJob,count:25);try check(runtime.pendingControlCount==1,"document cancellation callback tracked")
        var returned=false;let drain=Task{@MainActor in await runtime.stopAndDrain();returned=true};try await Task.sleep(nanoseconds:20_000_000);drain.cancel()
        try check(runtime.isStopped && runtime.isRunning && !returned,"embedding waits both actual request queues")
        await crm.release();try await Task.sleep(nanoseconds:30_000_000)
        try check(!returned && runtime.isRunning,"CRM completion does not hide still-running document queue")
        await document.release();await drain.value
        try check(returned && !runtime.isRunning && runtime.pendingControlCount==0 && runtime.nextWake==nil,"embedding joins both runners and cancellation controls")
        try check(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("crm-provider.txt").path) && FileManager.default.fileExists(atPath:f.root.appendingPathComponent("document-provider.txt").path),"embedding joins final writes from both providers")
        let index=NativeEmbeddingIndex(db:f.db)
        try check(try index.existing(.account,parentID:account["id"].string)==nil && index.existing(.document,parentID:row["id"].string)==nil,"cancelled embeddings never publish vectors")
        try check(try f.db.job(id:docJob)==cancelled && cancelled?.status=="cancelled","document runtime preserves actual cancellation and staged-result cleanup")
        let before=try [f.db.job(id:accountJob),f.db.job(id:docJob)];runtime.resume();notifications(path:f.db.url.path,id:docJob);NotificationCenter.default.post(name:NativeAIKeys.didChange,object:nil,userInfo:["database":f.db.url.path]);try await Task.sleep(nanoseconds:30_000_000)
        try check(try [f.db.job(id:accountJob),f.db.job(id:docJob)]==before && runtime.pendingControlCount==0,"embedding late callbacks cannot mutate old jobs")
    }
    static func main() async {
        do{let resources=URL(fileURLWithPath:CommandLine.arguments[1]);print("AI drain: controls");try await controls(resources);print("AI drain: contact");try await contact(resources);print("AI drain: target");try await target(resources);print("AI drain: embedding");try await embedding(resources);print("AI runtime drain: \(checks) checks passed")}
        catch{fputs("After \(checks) checks: \(error)\n",stderr);exit(1)}
    }
}
