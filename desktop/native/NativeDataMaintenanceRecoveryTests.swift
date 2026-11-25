import Foundation
import Darwin

private final class RecoveryGate {var point:String?,action:(()throws->Void)?,cancelled=false,session=true;func hit(_ p:String)throws{if p==point{point=nil;try action?()}}}

private final class RecoveryStartupProbe {
    let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0)
    private let lock=NSLock();private var once=false,result=""
    func hit(_ point:String)throws{
        guard point=="recovery.initializationLock" else{return}
        lock.lock();let wait = !once;once=true;lock.unlock()
        if wait{entered.signal();guard release.wait(timeout:.now()+5) == .success else{throw NativeMigrationFailure("test.timeout","startup checkpoint")}}
    }
    func set(_ value:String){lock.lock();result=value;lock.unlock()}
    var code:String{lock.lock();defer{lock.unlock()};return result}
}

@main struct NativeDataMaintenanceRecoveryTests {
    typealias R=NativeDataMaintenanceRecovery
    typealias F=NativeDataMaintenanceRecoveryFiles
    static var checks=0,scenarios=0,last="start",startupCancellationSeconds=0.0
    static func check(_ condition:@autoclosure()throws->Bool,_ label:String)throws{last=label;guard try condition() else{throw NativeMigrationFailure("test.failed",label)};checks+=1}
    static func directory(_ url:URL)throws{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
    static func file(_ url:URL,_ data:Data=Data("synthetic-preserved-bytes".utf8))throws{try data.write(to:url);guard chmod(url.path,0o600)==0 else{throw NativeMigrationFiles.io}}
    static func exists(_ url:URL)->Bool{var st=stat();return lstat(url.path,&st)==0}
    static func rejects(_ label:String,_ body:()throws->Void)throws{var caught=false;do{try body()}catch{caught=true};try check(caught,label)}
    static func attach(_ lease:NativeDataMaintenanceRecoveryLease,_ parent:URL,_ role:NativeDataMaintenanceRecoveryRole)throws->URL{
        let name=(role == .temporary ? "NextCRMMaintenance-":".nextcrm-pending-")+UUID().uuidString.lowercased(),url=parent.appendingPathComponent(name)
        try lease.plan(role:role,parentURL:parent,name:name);try directory(url);try lease.attach(role:role);try file(url.appendingPathComponent("payload"));return url
    }
    static func main(){do{try run()}catch{fputs("Recovery QA failed at \(last): \(error)\n",stderr);exit(1)}}
    static func run()throws{
        let a=CommandLine.arguments;guard a.count>=4 else{fatalError("mode resources root")}
        let resources=URL(fileURLWithPath:a[2]),base=URL(fileURLWithPath:a[3])
        if a[1]=="registry-holder" {
            let root=try F.directory(base);defer{close(root)}
            let lock=try F.openFile(root,".registry.lock",O_RDWR);defer{close(lock)}
            guard flock(lock,LOCK_EX)==0 else{throw NativeMigrationFiles.io}
            try file(URL(fileURLWithPath:a[4]),Data("ready".utf8));while true{pause()}
        }
        if a[1]=="controller-child" {
            let data=base.appendingPathComponent("data");try directory(data)
            let db=try NativeDatabase(url:data.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let actor=UUID().uuidString.lowercased();try db.insert("Users",values:["id":.text(actor),"email":.text("child@fixture.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"synthetic-child")
            try file(base.appendingPathComponent("actor.txt"),Data(actor.utf8))
            let service=CRMService(db:db,identity:.init(id:actor,role:"admin",partnerAccountID:nil))
            let controller=NativeDataMaintenanceController(service:service,resources:resources,checkpoint:{point in
                if point==a[4]{try file(base.appendingPathComponent("ready.json"),Data("ready".utf8));while true{pause()}}
            })
            let result=controller.perform(kind:.backup,backupURL:nil,destinationURL:base.appendingPathComponent("completed"),operation:.init())
            fputs("Child unexpectedly completed: \(result.message)\n",stderr);exit(2)
        }
        if a[1]=="child" {
            let r=try R(url:base.appendingPathComponent("registry"),authorize:{},mutationFence:{try $0()})
            let lease=try r.begin(),target=try attach(lease,base,.temporary)
            try file(base.appendingPathComponent("ready.json"),JSONSerialization.data(withJSONObject:["id":lease.id,"target":target.path]))
            while true{pause()}
        }
        let dataRoot=base.appendingPathComponent("data");try directory(dataRoot)
        let db=try NativeDatabase(url:dataRoot.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let actor=UUID().uuidString.lowercased();try db.insert("Users",values:["id":.text(actor),"email":.text("recovery@fixture.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"synthetic-recovery")
        let service=CRMService(db:db,identity:.init(id:actor,role:"admin",partnerAccountID:nil)),gate=RecoveryGate()
        let controller=NativeDataMaintenanceController(service:service,resources:resources,sessionCheck:{gate.session})
        func make(_ root:URL)throws->R{try R(url:root,authorize:controller.authorize,mutationFence:{body in try db.transaction{try controller.authorize();try body()}},cancelled:{gate.cancelled},checkpoint:gate.hit)}
        func scenario(_ name:String,_ body:(URL,R)throws->Void)throws{
            scenarios+=1;last=name;let root=base.appendingPathComponent(name);try directory(root);let r=try make(root.appendingPathComponent("registry"));try body(root,r);gate.point=nil;gate.action=nil;gate.cancelled=false;gate.session=true
        }
        try scenario("registry-initialization-lock"){root,_ in
            _ = try controller.recoverStaging() // Create the actual Controller registry before the holder starts.
            let registry=dataRoot.appendingPathComponent(".native-maintenance-recovery"),owner=try Data(contentsOf:registry.appendingPathComponent("owner.json")),ready=root.appendingPathComponent("ready.json")
            let process=Process();process.executableURL=URL(fileURLWithPath:a[0]);process.arguments=["registry-holder",resources.path,registry.path,ready.path];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run()
            defer{if process.isRunning{kill(process.processIdentifier,SIGKILL);process.waitUntilExit()}}
            let deadline=Date().addingTimeInterval(10);while !exists(ready) && process.isRunning && Date()<deadline{usleep(1000)}
            try check(exists(ready),"other process holds initialization lock")
            let started=Date();var busy=false
            do{_ = try controller.recoverStaging()}catch let failure as NativeDataMaintenanceRecoveryFailure{busy=failure.code=="recovery.busy"}
            try check(busy && Date().timeIntervalSince(started)<2,"busy initialization returns without waiting")
            try check(process.isRunning && (try Data(contentsOf:registry.appendingPathComponent("owner.json")))==owner,"busy owner and registry remain untouched")
            let probe=RecoveryStartupProbe(),operation=NativeDataMaintenanceOperation(),c=NativeDataMaintenanceController(service:service,resources:resources,checkpoint:probe.hit)
            let worker=Task.detached{do{_ = try c.recoverStaging(operation:operation);probe.set("unexpected-success")}catch is CancellationError{probe.set("cancelled")}catch{probe.set("unexpected-error")}}
            let waiter=Task{await withTaskCancellationHandler(operation:{await worker.value},onCancel:{_ = operation.cancel();worker.cancel()});probe.done.signal()}
            defer{_ = operation.cancel();worker.cancel();waiter.cancel();probe.release.signal()}
            try check(probe.entered.wait(timeout:.now()+3) == .success,"startup reached held initialization lock")
            let cancellationStarted=Date();_ = operation.cancel();waiter.cancel();probe.release.signal()
            try check(probe.done.wait(timeout:.now()+2) == .success,"cancel and termination await finish within two seconds")
            startupCancellationSeconds=Date().timeIntervalSince(cancellationStarted)
            try check(probe.code=="cancelled" && process.isRunning,"cancellation completes while other process still holds lock")
            kill(process.processIdentifier,SIGKILL);process.waitUntilExit()
            try check(try controller.recoverStaging().items.isEmpty,"recovery can retry after lock owner exits")
        }
        try scenario("normal"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let temp=try attach(lease!,root,.temporary),hidden=try attach(lease!,root,.publication)
            try check(try r.recover().items.first?.status == .live,"same-process independent open honors flock")
            let completed=root.appendingPathComponent("完成済みバックアップ");try lease!.beginPublication(destinationName:completed.lastPathComponent)
            guard rename(hidden.path,completed.path)==0 else{throw NativeMigrationFiles.io};try lease!.didPublish();try lease!.cleanup(role:.temporary);try lease!.finish();lease=nil
            try check(!exists(temp) && exists(completed.appendingPathComponent("payload")),"normal finish preserves published bytes")
            try check(try r.recover().items.isEmpty,"normal journal finalized")
        }
        try scenario("dead"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let temp=try attach(lease!,root,.temporary),hidden=try attach(lease!,root,.publication);lease=nil
            try check(try r.recover().items.first?.status == .recovered,"abandoned process lease recovered")
            try check(!exists(temp) && !exists(hidden),"both unpublished roots removed")
        }
        try scenario("child-live"){root,r in
            let process=Process();process.executableURL=URL(fileURLWithPath:a[0]);process.arguments=["child",resources.path,root.path];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run()
            defer{if process.isRunning{kill(process.processIdentifier,SIGKILL);process.waitUntilExit()}}
            let ready=root.appendingPathComponent("ready.json"),deadline=Date().addingTimeInterval(10)
            while !exists(ready) && process.isRunning && Date()<deadline{usleep(1000)}
            try check(exists(ready),"child lease ready")
            let info=try JSONSerialization.jsonObject(with:Data(contentsOf:ready)) as! [String:String],target=URL(fileURLWithPath:info["target"]!)
            try check(try r.recover().items.first?.status == .live && exists(target),"other-process work retained")
            kill(process.processIdentifier,SIGKILL);process.waitUntilExit()
            let reopened=try make(root.appendingPathComponent("registry"));try check(try reopened.recover().items.first?.status == .recovered && !exists(target),"SIGKILL releases lease; restarted registry recovers")
        }
        for published in [false,true] {
            try scenario(published ? "after-rename":"before-rename"){root,r in
                var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let temp=try attach(lease!,root,.temporary),hidden=try attach(lease!,root,.publication),target=root.appendingPathComponent("completed")
                try lease!.beginPublication(destinationName:target.lastPathComponent)
                if published{guard rename(hidden.path,target.path)==0 else{throw NativeMigrationFiles.io}}
                lease=nil;try check(try r.recover().items.first?.status == .recovered,"publication crash state classified")
                try check(!exists(temp) && !exists(hidden),"unpublished names removed")
                try check(exists(target)==published,"completed destination is never removed")
                if published{try check(try Data(contentsOf:target.appendingPathComponent("payload"))==Data("synthetic-preserved-bytes".utf8),"published bytes exact")}
            }
        }
        try scenario("unrelated-final"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let hidden=try attach(lease!,root,.publication),target=root.appendingPathComponent("existing")
            try lease!.beginPublication(destinationName:target.lastPathComponent);try directory(target);try file(target.appendingPathComponent("important"));lease=nil
            try check(try r.recover().items.first?.status == .recovered && !exists(hidden),"own hidden collision is recoverable")
            try check(exists(target.appendingPathComponent("important")),"unrelated destination untouched")
        }
        try scenario("published-replaced"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let hidden=try attach(lease!,root,.publication),target=root.appendingPathComponent("completed")
            try lease!.beginPublication(destinationName:target.lastPathComponent);try FileManager.default.removeItem(at:hidden);try directory(target);try file(target.appendingPathComponent("keep"));lease=nil
            try check(try r.recover().items.first?.status == .pending,"uncertain publication preserved for review")
            try check(exists(target.appendingPathComponent("keep")),"replacement completed folder untouched")
        }
        try scenario("unregistered"){root,r in
            let lookalike=root.appendingPathComponent(".nextcrm-pending-"+UUID().uuidString.lowercased());try directory(lookalike);try file(lookalike.appendingPathComponent("user-file"))
            try check(try r.recover().items.isEmpty && exists(lookalike.appendingPathComponent("user-file")),"no target-folder pattern scan")
        }
        try scenario("gap"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let name="NextCRMMaintenance-"+UUID().uuidString.lowercased(),target=root.appendingPathComponent(name)
            try lease!.plan(role:.temporary,parentURL:root,name:name);try directory(target);try file(target.appendingPathComponent("keep"));lease=nil
            try check(try r.recover().items.first?.status == .pending && exists(target.appendingPathComponent("keep")),"unmarked creation gap retained")
        }
        try scenario("no-create"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();try lease!.plan(role:.temporary,parentURL:root,name:"NextCRMMaintenance-"+UUID().uuidString.lowercased());lease=nil
            let page=try r.recover();try check(page.items.first?.status == .recovered,"intent before mkdir has nothing to remove")
            try check(page.items.first?.removedDirectories==0 && page.items.first!.message.contains("作業記録"),"bookkeeping-only completion is distinguished")
        }
        for kind in ["root-replaced","parent-replaced","marker-missing","marker-forged","marker-hardlink","file-symlink","root-symlink","root-mode","journal-corrupt","journal-hardlink","lock-replaced","torn-append"] {
            try scenario(kind){root,r in
                var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary),id=lease!.id
                if kind=="lock-replaced" {
                    try FileManager.default.removeItem(at:root.appendingPathComponent("registry/"+id+".lock"));try file(root.appendingPathComponent("registry/"+id+".lock"))
                    try rejects("live lease validates lock inode"){try lease!.cleanup(role:.temporary)}
                    try check(try r.recover().items.first?.status == .pending && exists(target),"replacement lock cannot reclaim live owner")
                    // The orphaned old lock must not authorize a newly-created inode.
                    // Release the old owner before testing the persisted record.
                }
                lease=nil
                let marker=target.appendingPathComponent(F.marker),journal=root.appendingPathComponent("registry/"+id+".journal")
                switch kind {
                case "root-replaced":try FileManager.default.moveItem(at:target,to:root.appendingPathComponent("moved"));try directory(target);try file(target.appendingPathComponent("keep"))
                case "parent-replaced":let moved=base.appendingPathComponent(kind+"-old");try FileManager.default.moveItem(at:root,to:moved);try directory(root)
                case "marker-missing":try FileManager.default.removeItem(at:marker)
                case "marker-forged":try file(marker,Data("{}".utf8))
                case "marker-hardlink":guard link(marker.path,root.appendingPathComponent("outside-marker").path)==0 else{throw NativeMigrationFiles.io}
                case "file-symlink":try FileManager.default.createSymbolicLink(at:target.appendingPathComponent("foreign"),withDestinationURL:db.url)
                case "root-symlink":try FileManager.default.moveItem(at:target,to:root.appendingPathComponent("moved"));try FileManager.default.createSymbolicLink(at:target,withDestinationURL:root.appendingPathComponent("moved"))
                case "root-mode":guard chmod(target.path,0o755)==0 else{throw NativeMigrationFiles.io}
                case "journal-corrupt":try file(journal,Data("{}\n".utf8))
                case "journal-hardlink":guard link(journal.path,root.appendingPathComponent("outside-journal").path)==0 else{throw NativeMigrationFiles.io}
                case "torn-append":let handle=try FileHandle(forWritingTo:journal);try handle.seekToEnd();try handle.write(contentsOf:Data("{\"torn\":".utf8));try handle.close()
                default:break
                }
                if kind=="parent-replaced"{try rejects("registry parent move is rejected"){_ = try r.recover()};return}
                let result=try r.recover()
                if kind=="torn-append"{try check(result.items.first?.status == .recovered && !exists(target),"safe orphan retry "+kind)}
                else{try check(result.items.first?.status == .pending,"changed attempt pending "+kind);try check(exists(target),"changed attempt retained "+kind)}
            }
        }
        try scenario("parent-race"){root,r in
            let parent=root.appendingPathComponent("selected");try directory(parent);var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,parent,.temporary);lease=nil
            gate.point="removeEntry";gate.action={try FileManager.default.moveItem(at:parent,to:root.appendingPathComponent("selected-old"));try directory(parent)}
            try check(try r.recover().items.first?.status == .pending,"parent changed before unlink")
            try check(exists(root.appendingPathComponent("selected-old/"+target.lastPathComponent+"/payload")),"moved root bytes retained at mutation fence")
        }
        try scenario("session-loss"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);lease=nil
            gate.point="removeEntry";gate.action={gate.session=false}
            try rejects("session revoked during cleanup"){_ = try r.recover()};try check(exists(target.appendingPathComponent("payload")),"no unlink after session loss")
            gate.session=true;try check(try r.recover().items.first?.status == .recovered,"regrant resumes retained journal")
        }
        try scenario("admin-loss"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);lease=nil
            guard let user=try db.get("Users",key:["id":.text(actor)]) else{throw NativeDBError.conflict};try db.update(user,changes:["role":.text("user")],actor:"synthetic-recovery")
            try rejects("fresh SQLite admin gate"){_ = try r.recover()};try check(exists(target.appendingPathComponent("payload")),"demotion cannot read or remove attempt")
            guard let now=try db.get("Users",key:["id":.text(actor)]) else{throw NativeDBError.conflict};try db.update(now,changes:["role":.text("admin")],actor:"synthetic-recovery")
            try check(try r.recover().items.first?.status == .recovered,"admin restored cleanup")
        }
        for point in ["cleaning","removeEntry","removeRoot","finish"] {
            try scenario("cancel-"+point){root,r in
                var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);lease=nil
                gate.point=point;gate.action={gate.cancelled=true}
                try rejects("cancel at "+point){_ = try r.recover()};gate.cancelled=false
                try check(try r.recover().items.first?.status == .recovered && !exists(target),"cancel retry "+point)
            }
        }
        try scenario("partial-failure"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);try file(target.appendingPathComponent("another"));lease=nil
            gate.point="removeEntry";gate.action={throw NativeDataMaintenanceRecoveryFailure.io}
            try check(try r.recover().items.first?.status == .failed && exists(target.appendingPathComponent(F.marker)),"failure retains marker and journal")
            try check(try r.recover().items.first?.status == .recovered,"failure retried")
        }
        try scenario("hardlink-pins"){root,r in
            let original=root.appendingPathComponent("original");try file(original)
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);guard link(original.path,target.appendingPathComponent("pin").path)==0 else{throw NativeMigrationFiles.io};lease=nil
            try check(try r.recover().items.first?.status == .recovered,"immutable pins unlinked safely")
            try check(try Data(contentsOf:original)==Data("synthetic-preserved-bytes".utf8),"original hardlink bytes preserved")
        }
        try scenario("large-tree"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary),nested=target.appendingPathComponent("candidate");try directory(nested)
            for i in 0..<2048{try file(nested.appendingPathComponent("f-\(i)"),Data([1,2,3]))};let large=nested.appendingPathComponent("large");try file(large,Data());let out=try FileHandle(forWritingTo:large);let chunk=Data(repeating:0x41,count:65536);for _ in 0..<1024{try out.write(contentsOf:chunk)};try out.close();lease=nil
            try check(try r.recover().items.first?.status == .recovered && !exists(target),"2048 files and 64MiB reclaimed without loading bytes")
        }
        try scenario("controller-roundtrip"){root,_ in
            let backup=root.appendingPathComponent("backup"),restore=root.appendingPathComponent("restore")
            let first=controller.perform(kind:.backup,backupURL:nil,destinationURL:backup,operation:.init())
            try check(first.state == .completed && !first.cleanupPending && exists(backup.appendingPathComponent(F.marker)),"controller backup records and finalizes lease")
            let second=controller.perform(kind:.restore,backupURL:backup,destinationURL:restore,operation:.init())
            try check(second.state == .completed && !second.cleanupPending && second.artifact?.restore?.activated==false,"controller restore accepts completed ownership marker")
            try check(try controller.recoverStaging().items.isEmpty,"normal controller has no stale journal")
            try check(try Data(contentsOf:backup.appendingPathComponent("database.sqlite"))==Data(contentsOf:restore.appendingPathComponent("crm.sqlite")),"registered backup restore database bytes exact")
        }
        try scenario("controller-published-failure"){root,_ in
            var once=true;let c=NativeDataMaintenanceController(service:service,resources:resources,checkpoint:{point in if point=="recovery.published" && once{once=false;throw NativeDataMaintenanceRecoveryFailure.io}})
            let target=root.appendingPathComponent("completed"),result=c.perform(kind:.backup,backupURL:nil,destinationURL:target,operation:.init())
            try check(result.state == .completed && result.cleanupPending && exists(target),"ledger failure after commit never rolls back publication")
            let bytes=try Data(contentsOf:target.appendingPathComponent("database.sqlite")),page=try controller.recoverStaging()
            try check(page.items.count==1 && page.items.first?.status == .recovered,"controller startup reconciles publication intent")
            try check(try Data(contentsOf:target.appendingPathComponent("database.sqlite"))==bytes,"startup preserves completed backup bytes")
        }
        try scenario("controller-cancel"){root,_ in
            let op=NativeDataMaintenanceOperation(),c=NativeDataMaintenanceController(service:service,resources:resources,checkpoint:{point in if point=="commit"{_ = op.cancel()}})
            let target=root.appendingPathComponent("cancelled"),result=c.perform(kind:.backup,backupURL:nil,destinationURL:target,operation:op)
            try check(result.state == .cancelled && !exists(target),"controller cancellation compensates only owned work")
            let page=try controller.recoverStaging();try check(page.items.count==1 && page.items.first?.status == .recovered,"next authorized session finalizes cancellation journal")
        }
        for point in ["beforeCopy","beforeCommit","recovery.published"] {
            try scenario("controller-kill-"+point){root,_ in
                let process=Process();process.executableURL=URL(fileURLWithPath:a[0]);process.arguments=["controller-child",resources.path,root.path,point];process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run()
                defer{
                    if process.isRunning{kill(process.processIdentifier,SIGKILL);process.waitUntilExit()}
                    if let r=try? R(url:root.appendingPathComponent("data/.native-maintenance-recovery"),authorize:{},mutationFence:{try $0()}){_ = try? r.recover()}
                }
                let deadline=Date().addingTimeInterval(20);while !exists(root.appendingPathComponent("ready.json")) && process.isRunning && Date()<deadline{usleep(1000)}
                try check(exists(root.appendingPathComponent("ready.json")),"controller child reached "+point)
                kill(process.processIdentifier,SIGKILL);process.waitUntilExit()
                let childDB=try NativeDatabase(url:root.appendingPathComponent("data/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),childID=try String(contentsOf:root.appendingPathComponent("actor.txt"),encoding:.utf8)
                let childService=CRMService(db:childDB,identity:.init(id:childID,role:"admin",partnerAccountID:nil)),child=NativeDataMaintenanceController(service:childService,resources:resources)
                let page=try child.recoverStaging();try check(page.items.count==1 && page.items[0].status == .recovered,"real controller restart recovered "+point)
                try check(page.items[0].removedDirectories==(point=="beforeCommit" ? 2:1),"actual removal count "+point)
                try check(exists(root.appendingPathComponent("completed"))==(point=="recovery.published"),"real committed destination preserved "+point)
                try check(try child.recoverStaging().items.isEmpty,"restart journal finalized "+point)
            }
        }
        try scenario("unsafe-registration"){root,r in
            let lease=try r.begin();try rejects("reject traversal before filesystem lookup"){try lease.plan(role:.temporary,parentURL:root,name:"../foreign")}
            try rejects("reject unowned name before filesystem lookup"){try lease.plan(role:.temporary,parentURL:root,name:"ordinary-folder")}
            try lease.finish();try check(try r.recover().items.isEmpty,"invalid registration left no target")
        }
        try scenario("empty-cleaning-gap"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);lease=nil
            gate.point="removeRoot";gate.action={throw NativeDataMaintenanceRecoveryFailure.io}
            try check(try r.recover().items.first?.status == .failed,"interrupted final root removal retained")
            try FileManager.default.removeItem(at:target.appendingPathComponent(F.marker))
            try check(try r.recover().items.first?.status == .recovered && !exists(target),"recorded empty cleaning gap finishes safely")
        }
        try scenario("existing-registry-owner"){root,r in
            var lease:NativeDataMaintenanceRecoveryLease?=try r.begin();let target=try attach(lease!,root,.temporary);lease=nil
            let owner=root.appendingPathComponent("registry/owner.json");try file(owner,Data("{}".utf8))
            try rejects("changed registry owner rejected"){_ = try r.recover()};try check(exists(target),"untrusted registry never authorizes deletion")
        }
        try scenario("paged"){root,r in
            for _ in 0..<205{let lease=try r.begin();_ = lease.id}
            var cursor:String?,count=0,pages=0
            repeat{let page=try r.recover(after:cursor,limit:17);try check(page.items.count<=17 && page.items.allSatisfy{$0.status == .recovered},"bounded recovery page");count+=page.items.count;pages+=1;cursor=page.nextCursor}while cursor != nil
            try check(count==205 && pages==13,"all registry entries paged")
        }
        try check(try db.get("Users",key:["id":.text(actor)])?.values["email"] == .text("recovery@fixture.invalid"),"synthetic SQLite remains readable")
        let result:[String:Any]=["ok":true,"checks":checks,"scenarios":scenarios,"startupCancellationSeconds":startupCancellationSeconds,"models":92,"externalTransfers":0,"keychainAccessed":false,"normalDataAccessed":false,"completedArtifactsDeleted":false]
        try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:base.appendingPathComponent("result.json"));print("NativeDataMaintenanceRecoveryTests: \(checks) checks passed")
    }
}
