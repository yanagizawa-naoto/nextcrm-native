import Foundation
import Darwin
import SQLite3
import CryptoKit

@main enum NativeDocumentExportRetentionTests {
    static var checks=0
    static let user="f3000000-0000-4000-8000-000000000001"
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value() else{throw NativeDBError.message("FAIL "+label)};checks+=1}
    static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("ACCEPTED "+label)}
    static func exists(_ url:URL)->Bool{var st=stat();return lstat(url.path,&st)==0}
    static func directory(_ url:URL)throws{try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
    static func file(_ url:URL,_ data:Data=Data("synthetic bytes".utf8))throws{try data.write(to:url);guard chmod(url.path,0o600)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
    static func service(_ base:URL,_ resources:URL)throws->CRMService {
        let db=try NativeDatabase(url:base.appendingPathComponent("data/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        if try db.get("Users",key:["id":.text(user)])==nil{_ = try db.insert("Users",values:["id":.text(user),"email":.text("export@fixture.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:user)}
        return CRMService(db:db,identity:.init(id:user,role:"admin",partnerAccountID:nil))
    }
    static func tree(_ root:URL)throws->[String:String] {
        var result:[String:String]=[:];let entries=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
        for case let url as URL in entries {var st=stat();guard lstat(url.path,&st)==0 else{throw NativeDataMaintenanceRecoveryFailure.io};if st.st_mode&S_IFMT==S_IFREG {result[String(url.path.dropFirst(root.path.count))]=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()}}
        return result
    }
    static func document(_ s:CRMService,_ base:URL)throws->NativeRecord {
        if let id=try s.db.metadata("fixture.document"),let row=try s.db.get("Documents",key:["id":.text(id)]){return row}
        let input=base.appendingPathComponent("original.txt");try file(input,Data(repeating:65,count:65536))
        let row=try s.commitDocument(s.stageDocument(input));try s.db.setMetadata("fixture.document",value:row["id"].string);return row
    }
    static func hold(_ root:URL)throws->Never {try file(root.appendingPathComponent("ready"));while true{pause()}}
    static func child(_ mode:String,_ base:URL,_ resources:URL)throws {
        let s=try service(base,resources),doc=try document(s,base),selected=base.appendingPathComponent("selected");try directory(selected)
        if mode=="unmarked" {
            let registry=try s.documentExportRegistry(),lease=try registry.recovery.begin();let name="NextCRMMaintenance-"+UUID().uuidString.lowercased()
            try lease.plan(role:.temporary,parentURL:selected,name:name);try directory(selected.appendingPathComponent(name))
            try withExtendedLifetime((registry,lease)){try hold(base)}
        }
        let files=try NativeDocumentFiles(dataRoot:s.db.url.deletingLastPathComponent()),target=selected.appendingPathComponent("completed.txt")
        try files.export(key:doc["key"].string,bytes:Int64(doc["size"].string)!,sha256:doc["content_hash"].string,to:target,replace:false,registry:try s.documentExportRegistry()){publish in if mode=="after"{try publish()};try hold(base)}
    }
    static func launch(_ mode:String,_ root:URL,_ resources:URL)throws->Process {
        let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=[mode,resources.path,root.path];p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.standardError;try p.run()
        let end=Date().addingTimeInterval(8)
        while Date()<end && !exists(root.appendingPathComponent("ready")){guard p.isRunning else{throw NativeDBError.message("child exited")};Thread.sleep(forTimeInterval:0.01)}
        guard exists(root.appendingPathComponent("ready")) else{kill(p.processIdentifier,SIGKILL);p.waitUntilExit();throw NativeDBError.message("child timeout")};return p
    }
    static func killOwned(_ p:Process){if p.isRunning{kill(p.processIdentifier,SIGKILL)};p.waitUntilExit()}
    static func backup(_ from:URL,_ to:URL)throws {
        var src:OpaquePointer?,dst:OpaquePointer?;guard sqlite3_open_v2(from.path,&src,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(to.path,&dst)==SQLITE_OK else{throw NativeDataMaintenanceRecoveryFailure.io};defer{sqlite3_close(src);sqlite3_close(dst)}
        guard let b=sqlite3_backup_init(dst,"main",src,"main") else{throw NativeDataMaintenanceRecoveryFailure.io};guard sqlite3_backup_step(b,-1)==SQLITE_DONE,sqlite3_backup_finish(b)==SQLITE_OK else{throw NativeDataMaintenanceRecoveryFailure.io}
    }
    static func main()async {
        do{let a=CommandLine.arguments,base=URL(fileURLWithPath:a[3]),resources=URL(fileURLWithPath:a[2]);umask(0o077)
            if ["before","after","unmarked"].contains(a[1]) {try child(a[1],base,resources);return}
            try directory(base)
            try await tests(base,resources)
            try JSONSerialization.data(withJSONObject:["checks":checks,"complete":true],options:.sortedKeys).write(to:base.appendingPathComponent("result.json"));print("NativeDocumentExportRetentionTests \(checks)")
        }catch{fputs("\(error)\n",stderr);exit(1)}
    }
    static func tests(_ base:URL,_ resources:URL)async throws {
        for mode in ["before","after"] {
            let root=base.appendingPathComponent(mode);try directory(root);let p=try launch(mode,root,resources);defer{if p.isRunning{killOwned(p)}}
            let s=try service(root,resources),selected=root.appendingPathComponent("selected"),target=selected.appendingPathComponent("completed.txt")
            let live=try s.recoverDocumentExports();try check(live.items.count==1 && live.items[0].status == .live,"live process lease protected")
            try file(selected.appendingPathComponent(".nextcrm-export-not-owned"));let foreign=selected.appendingPathComponent("NextCRMMaintenance-"+UUID().uuidString.lowercased());try directory(foreign);try file(foreign.appendingPathComponent("keep"))
            killOwned(p);try check(p.terminationReason == .uncaughtSignal,"actual SIGKILL")
            let page=try s.recoverDocumentExports();try check(page.items.count==1 && page.items[0].status == .recovered,"crash payload recovered")
            try check(exists(selected.appendingPathComponent(".nextcrm-export-not-owned")) && exists(foreign.appendingPathComponent("keep")),"unregistered siblings preserved")
            try check(exists(target)==(mode=="after"),"only published destination exists")
            if mode=="after"{try check(try Data(contentsOf:target)==Data(repeating:65,count:65536),"published bytes retained after crash")}
            try check(try s.recoverDocumentExports().items.isEmpty,"idempotent journal cleanup")
        }
        let unmarked=base.appendingPathComponent("unmarked");try directory(unmarked);let unmarkedChild=try launch("unmarked",unmarked,resources);killOwned(unmarkedChild)
        let unmarkedService=try service(unmarked,resources),unmarkedPage=try unmarkedService.recoverDocumentExports()
        try check(unmarkedPage.items.first?.status == .pending,"pre-marker crash stays pending")
        let unmarkedFolders=try FileManager.default.contentsOfDirectory(at:unmarked.appendingPathComponent("selected"),includingPropertiesForKeys:nil)
        try check(unmarkedFolders.count==1,"unproven empty folder preserved");try check(try FileManager.default.contentsOfDirectory(at:unmarkedFolders[0],includingPropertiesForKeys:nil).isEmpty,"no payload before durable attach")
        let root=base.appendingPathComponent("normal"),selected=root.appendingPathComponent("selected");try directory(selected);let s=try service(root,resources),doc=try document(s,root),target=selected.appendingPathComponent("日本語.txt")
        try s.exportDocument(doc["id"].string,to:target);try check(try Data(contentsOf:target).count==65536,"normal export");try check(try s.recoverDocumentExports().items.isEmpty,"normal journal finalized")
        try rejects("exclusive collision"){try s.exportDocument(doc["id"].string,to:target)};try check(try Data(contentsOf:target).count==65536,"collision keeps destination")
        try file(target,Data("old".utf8));try s.exportDocument(doc["id"].string,to:target,replace:true);try check(try Data(contentsOf:target).count==65536,"explicit replace")
        try check(try FileManager.default.contentsOfDirectory(at:selected,includingPropertiesForKeys:nil).count==1,"normal only final file")
        var cancelled=false;let registry=try s.documentExportRegistry(cancelled:{cancelled});let stage=try registry.begin(parent:selected)
        let unused=try stage.unusedContentURL(named:"codec.csv");try check(!exists(unused),"codec receives nonexistent path");try file(unused)
        try rejects("codec same path not offered twice"){_ = try stage.unusedContentURL(named:"codec.csv")}
        try rejects("traversal forbidden"){_ = try stage.unusedContentURL(named:"../outside")}
        cancelled=true;try rejects("cancel before publish"){try stage.publish(content:"codec.csv",to:selected.appendingPathComponent("cancelled"),replace:false){try $0()}}
        try stage.finish();try check(!exists(stage.directoryURL),"ordinary cancel cleans staging");try stage.finish();try check(!exists(selected.appendingPathComponent("cancelled")),"cancel final absent")
        // Cancelled Swift task cleanup is awaited rather than inherited by an unstructured writer.
        let started=DispatchSemaphore(value:0),complete=DispatchSemaphore(value:0)
        let t=Task.detached{()throws->URL in let st=try s.documentExportRegistry().begin(parent:selected);let fd=try st.createContent(named:"cancel.bin");close(fd);started.signal();do{try await Task.sleep(nanoseconds:10_000_000_000)}catch{};try st.finish();complete.signal();return st.directoryURL}
        guard started.wait(timeout:.now()+5) == .success else{throw NativeDataMaintenanceRecoveryFailure.io};t.cancel();let cancelledURL=try await t.value;try check(!exists(cancelledURL),"cancelled Task cleanup joins")
        // Changed authority leaves journal pending; no filesystem mutation after loss.
        var pending:NativeExportStaging?=try s.documentExportRegistry().begin(parent:selected);let pendingURL=pending!.directoryURL;let fd=try pending!.createContent(named:"payload");close(fd)
        let userRow=try s.db.get("Users",key:["id":.text(user)])!;_ = try s.db.update(userRow,changes:["userStatus":.text("INACTIVE")],actor:user)
        try rejects("revoked publish"){try pending!.publish(content:"payload",to:selected.appendingPathComponent("revoked"),replace:false){try $0()}}
        try rejects("revoked cleanup"){try pending!.finish()};try check(exists(pendingURL),"revoked lease retained")
        pending=nil;let inactive=try s.db.get("Users",key:["id":.text(user)])!;_ = try s.db.update(inactive,changes:["userStatus":.text("ACTIVE")],actor:user)
        try check(try s.recoverDocumentExports().items.first?.status == .recovered,"later authorized recovery")
        // True immutable readonly opener may read, but cannot create registry or delete a selected temp.
        var held:NativeExportStaging?=try s.documentExportRegistry().begin(parent:selected);let heldURL=held!.directoryURL;let heldFD=try held!.createContent(named:"keep");close(heldFD);held=nil
        let roRoot=base.appendingPathComponent("readonly");try directory(roRoot);let roDB=roRoot.appendingPathComponent("crm.sqlite");try backup(s.db.url,roDB)
        try FileManager.default.copyItem(at:root.appendingPathComponent("data/.native-export-recovery"),to:roRoot.appendingPathComponent(".native-export-recovery"))
        let roBefore=try tree(roRoot)
        let ro=try NativeDatabase(readOnlyURL:roDB,schemaURL:resources.appendingPathComponent("schema.json")),rs=CRMService(db:ro,identity:s.identity)
        try rejects("actual readonly recovery"){_ = try rs.recoverDocumentExports()};try rejects("actual readonly registry creation"){_ = try rs.documentExportRegistry()};try rejects("actual readonly export"){try rs.exportDocument(doc["id"].string,to:selected.appendingPathComponent("readonly.txt"))};try check(exists(heldURL.appendingPathComponent("keep")),"readonly preserves payload")
        try check(try tree(roRoot)==roBefore,"readonly database and registry bytes unchanged")
        try await NativeDocumentExportRecoveryWorker(service:s).recover()
        try check(!exists(heldURL),"startup actor API recovers writable pending stage")
        try check(try s.recoverDocumentExports().items.isEmpty,"startup actor completes journal")
        let cancelledRecovery=Task.detached {try await NativeDocumentExportRecoveryWorker(service:s).recover()};cancelledRecovery.cancel();do{try await cancelledRecovery.value}catch is CancellationError{}
        try check(try s.recoverDocumentExports().items.isEmpty,"cancelled recovery joins without artifacts")
        for kind in ["symlink","root","marker","parent","hardlink","lock"] {
            let sandbox=base.appendingPathComponent("tamper-"+kind),parent=sandbox.appendingPathComponent("selected");try directory(parent);let svc=try service(sandbox,resources)
            var st:NativeExportStaging?=try svc.documentExportRegistry().begin(parent:parent);let location=st!.directoryURL;let fd=try st!.createContent(named:"payload");close(fd)
            let foreign=sandbox.appendingPathComponent("foreign");try file(foreign)
            if kind=="hardlink" {let output=location.appendingPathComponent("payload");unlink(output.path);guard link(foreign.path,output.path)==0 else{throw NativeDataMaintenanceRecoveryFailure.io};try rejects("publish rejects hardlink"){try st!.publish(content:"payload",to:parent.appendingPathComponent("result"),replace:false){try $0()}};try st!.finish();st=nil;try check(try Data(contentsOf:foreign)==Data("synthetic bytes".utf8),"hardlink target retained");continue}
            if kind=="lock" {let reg=sandbox.appendingPathComponent("data/.native-export-recovery");let lock=try FileManager.default.contentsOfDirectory(at:reg,includingPropertiesForKeys:nil).first{$0.lastPathComponent.hasSuffix(".lock") && !$0.lastPathComponent.hasPrefix(".")}!;try FileManager.default.moveItem(at:lock,to:reg.appendingPathComponent("kept-lock"));try file(lock)}
            if kind=="symlink"{guard symlink(foreign.path,location.appendingPathComponent("evil").path)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
            if kind=="root"{try FileManager.default.moveItem(at:location,to:sandbox.appendingPathComponent("moved"));try directory(location);try file(location.appendingPathComponent("foreign"))}
            if kind=="marker"{try file(location.appendingPathComponent(NativeDataMaintenanceRecoveryFiles.marker),Data("{}".utf8))}
            if kind=="parent"{try FileManager.default.moveItem(at:parent,to:sandbox.appendingPathComponent("moved"));try directory(parent);try file(parent.appendingPathComponent("foreign"))}
            try rejects("tampered active publication "+kind){try st!.publish(content:"payload",to:parent.appendingPathComponent("result"),replace:false){try $0()}}
            st=nil;let result=try svc.recoverDocumentExports();try check(result.items.first?.status == .pending,"tampered journal kept "+kind);try check(try Data(contentsOf:foreign)==Data("synthetic bytes".utf8),"foreign bytes preserved "+kind)
        }
        // Callback probe only mutates its private short-lived flag, including
        // callbacks from a rolled-back inner savepoint retained to outer end.
        for rollback in [false,true] {
            enum Rollback:Error{case requested}
            let newTarget=selected.appendingPathComponent(rollback ? "outer-rollback.txt":"outer-commit.txt")
            do {try s.db.transaction {
                try rejects("outer export rejected before FS"){try s.exportDocument(doc["id"].string,to:newTarget)}
                try s.db.transaction {try rejects("nested registry rejected"){_ = try s.documentExportRegistry()}}
                do{try s.db.transaction {try rejects("nested rollback registry rejected"){_ = try s.documentExportRegistry()};throw Rollback.requested}}catch Rollback.requested{}
                if rollback{throw Rollback.requested}
            }}catch Rollback.requested{}
            try check(!exists(newTarget),"outer callbacks never publish")
            try check(try s.recoverDocumentExports().items.isEmpty,"outer callbacks never register cleanup")
        }
        try s.exportDocument(doc["id"].string,to:selected.appendingPathComponent("after-outer.txt"));try check(exists(selected.appendingPathComponent("after-outer.txt")),"post transaction export succeeds")
        try check(try s.db.integrityCheck(),"SQLite FK integrity")
    }
}
