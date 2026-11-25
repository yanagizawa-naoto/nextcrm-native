import Foundation
import Darwin
import SQLite3

@main enum PreparationBoundaryTests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value()else{throw NativeDBError.message("FAIL boundary: "+label)};checks+=1}
    static func makeDB(_ root:URL,_ n:URL)throws->NativeDatabase{try .init(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))}
    static func child(_ root:URL,_ mode:String)throws {
        if mode=="lock"{let owner=try NativeMailPreparationFiles.Root(root,create:true);guard flock(owner.lockFD,LOCK_EX|LOCK_NB)==0 else{throw NativeDBError.conflict};try Data("ready".utf8).write(to:root.appendingPathComponent("ready"),options:.atomic);while true{pause()};withExtendedLifetime(owner){} }
        let lease=try NativeMailPreparationFiles.create(.plugin,root:root),body=try InvoiceMail.prepareText(root:lease.url,id:lease.id,from:"a@example.invalid",to:"b@example.invalid",subject:"合成",message:"所有された本文")
        let marker=lease.url.appendingPathComponent(".lease")
        if mode=="future" || mode=="oversize" {
            var value=try JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as! [String:Any];value["version"]=2
            let bytes=mode=="oversize" ? Data(repeating:65,count:5000):try JSONSerialization.data(withJSONObject:value)
            let fd=open(marker.path,O_WRONLY|O_TRUNC|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw NativeDBError.conflict};let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);try file.write(contentsOf:bytes);try file.synchronize();try file.close()
        }
        if mode=="symlink" {try FileManager.default.removeItem(at:body.url);try FileManager.default.createSymbolicLink(at:body.url,withDestinationURL:root.appendingPathComponent("victim"))}
        if mode=="hardlink"{try FileManager.default.linkItem(at:body.url,to:root.appendingPathComponent("linked-copy"))}
        try JSONEncoder().encode(["leaf":lease.url.path,"body":body.url.path]).write(to:root.appendingPathComponent("state.json"),options:.atomic)
        kill(getpid(),SIGKILL);withExtendedLifetime(lease){}
    }
    static func launch(_ n:URL,_ root:URL,_ mode:String)throws->Process {let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=[n.path,root.path,"--child",mode];try p.run();return p}
    static func main()async {do {
        let n=URL(fileURLWithPath:CommandLine.arguments[1]);if CommandLine.arguments.contains("--child"){try child(URL(fileURLWithPath:CommandLine.arguments[2]),CommandLine.arguments.last!);return}
        let base=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-PreparationBoundary-"+UUID().uuidString.lowercased());try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:base)}
        do {let root=base.appendingPathComponent("lock"),db=try makeDB(root,n)
            var lease:NativeMailPreparationFiles.Lease?=try NativeMailPreparationFiles.create(.plugin,root:root)
            let file=try InvoiceMail.prepareText(root:lease!.url,id:lease!.id,from:"a@example.invalid",to:"b@example.invalid",subject:"合成",message:"ロック保持中").url
            let process=try launch(n,root,"lock");defer{if process.isRunning{kill(process.processIdentifier,SIGKILL);process.waitUntilExit()}}
            let ready=root.appendingPathComponent("ready"),deadline=Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath:ready.path),process.isRunning,Date()<deadline{try await Task.sleep(nanoseconds:10_000_000)}
            try check(FileManager.default.fileExists(atPath:ready.path),"actual child holds coordination lock")
            kill(process.processIdentifier,SIGSTOP)
            let start=Date();var busy=false
            do{_ = try NativeMailPreparationFiles.create(.plugin,root:root)}catch is NativeMailPreparationFiles.Busy{busy=true}
            try check(busy && Date().timeIntervalSince(start)<1,"producer returns typed busy promptly while holder SIGSTOPped")
            let cursor=try NativeMailPreparationFiles.Recovery(db:db),page=try cursor.step();try check(page.busy && page.removed==0,"collector also yields without consuming cursor")
            let closeStart=Date();lease=nil
            try check(Date().timeIntervalSince(closeStart)<1 && FileManager.default.fileExists(atPath:file.path),"deinit never blocks on root lock and retains owned content")
            kill(process.processIdentifier,SIGKILL);process.waitUntilExit()
            let after=try cursor.step();try check(after.removed==1 && !FileManager.default.fileExists(atPath:file.path),"same cursor recovers deferred deinit after actual process death")
            var next:NativeMailPreparationFiles.Lease?=try NativeMailPreparationFiles.create(.plugin,root:root);try check(next != nil,"producer succeeds after dead holder unlock");next=nil
        }
        for mode in ["future","oversize","symlink","hardlink"] {
            let root=base.appendingPathComponent(mode),db=try makeDB(root,n);try Data("untouched".utf8).write(to:root.appendingPathComponent("victim"))
            let child=try launch(n,root,mode);child.waitUntilExit();try check(child.terminationReason == .uncaughtSignal && child.terminationStatus==SIGKILL,"owned malformed fixture really loses process lease")
            let state=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:root.appendingPathComponent("state.json"))),leaf=URL(fileURLWithPath:state["leaf"]!)
            let before=try FileManager.default.contentsOfDirectory(atPath:leaf.path).sorted(),page=try NativeMailPreparationFiles.Recovery(db:db).step()
            try check(page.removed==0 && page.preserved==1 && FileManager.default.contentsOfDirectory(atPath:leaf.path).sorted()==before,"unknown/replaced content stays held: "+mode)
            try check(try Data(contentsOf:root.appendingPathComponent("victim"))==Data("untouched".utf8),"no outside target modified: "+mode)
        }
        do {let root=base.appendingPathComponent("readonly"),writable=try makeDB(root,n),child=try launch(n,root,"valid");child.waitUntilExit()
            let state=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:root.appendingPathComponent("state.json"))),body=URL(fileURLWithPath:state["body"]!),bytes=try Data(contentsOf:body)
            // An actual SQLite snapshot into a separate immutable single file;
            // closing a live WAL connection alone is not snapshot sealing.
            let sealed=root.appendingPathComponent("sealed.sqlite");var input:OpaquePointer?,output:OpaquePointer?
            guard sqlite3_open_v2(writable.url.path,&input,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&output)==SQLITE_OK,let copy=sqlite3_backup_init(output,"main",input,"main") else{throw NativeDBError.conflict}
            let copied=sqlite3_backup_step(copy,-1),finished=sqlite3_backup_finish(copy)
            guard copied==SQLITE_DONE,finished==SQLITE_OK,sqlite3_exec(output,"PRAGMA journal_mode=DELETE",nil,nil,nil)==SQLITE_OK else{throw NativeDBError.conflict}
            let closeOut=sqlite3_close(output),closeIn=sqlite3_close(input)
            guard closeOut==SQLITE_OK,closeIn==SQLITE_OK else{throw NativeDBError.conflict}
            var reopened:OpaquePointer?;guard sqlite3_open(sealed.path,&reopened)==SQLITE_OK,sqlite3_exec(reopened,"PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;",nil,nil,nil)==SQLITE_OK,sqlite3_close(reopened)==SQLITE_OK else{throw NativeDBError.conflict}
            // Darwin may leave a closed snapshot's SHM after both owned handles
            // close successfully. No WAL/journal may remain; remove only this
            // exact private fixture sidecar, never any live source sidecar.
            guard !FileManager.default.fileExists(atPath:sealed.path+"-wal"),!FileManager.default.fileExists(atPath:sealed.path+"-journal") else{throw NativeDBError.conflict}
            let shm=sealed.path+"-shm";var shmInfo=stat()
            if lstat(shm,&shmInfo)==0{guard shmInfo.st_mode&S_IFMT==S_IFREG,shmInfo.st_nlink==1,shmInfo.st_uid==geteuid() else{throw NativeDBError.conflict};guard unlink(shm)==0 else{throw NativeDBError.conflict}}
            let readonly=try NativeDatabase(readOnlyURL:sealed,schemaURL:n.appendingPathComponent("schema.json"));var refused=false
            do{_ = try NativeMailPreparationFiles.Recovery(db:readonly)}catch{refused=true}
            try check(refused && Data(contentsOf:body)==bytes,"readonly constructor refuses before opening preparation root")
        }
        let result:[String:Any]=["checks":checks,"actualProcessLock":true,"network":0,"keychain":0]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
    }catch{FileHandle.standardError.write(Data("PreparationBoundary: \(error)\n".utf8));exit(1)}}
}
