import Foundation
import Darwin
import CryptoKit

@main struct NativeBackupTests {
    struct Case:Decodable {let name:String,source:String,destination:String;let failAt:String?;let cancelAt:String?;let concurrent:Bool?;let forceCopy:Bool?;let occurrence:Int?;let mutatePinned:Bool?;let documentID:String?;let userID:String?}
    struct Outcome:Encodable {let name:String;let result:NativeBackupResult;let writerCompleted:Bool;let sourceAvatarSingleLinks:Bool}
    static func main()throws {
        guard CommandLine.arguments.count==5 else {fatalError("mode schema sql spec")}
        let schema=URL(fileURLWithPath:CommandLine.arguments[2]),sql=URL(fileURLWithPath:CommandLine.arguments[3])
        if CommandLine.arguments[1]=="initialize" {
            let db=try NativeDatabase(url:URL(fileURLWithPath:CommandLine.arguments[4]),schemaURL:schema,sqlURL:sql);_ = try db.integrityCheck();print("NativeBackup source initialized");return
        }
        let spec=URL(fileURLWithPath:CommandLine.arguments[4]),cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:spec));var outcomes:[Outcome]=[]
        for item in cases {
            let db=try NativeDatabase(url:URL(fileURLWithPath:item.source),schemaURL:schema,sqlURL:sql)
            let lock=NSLock(),done=DispatchSemaphore(value:0);var stopped=false,launched=false,writerCompleted=false,writerError=false,avatarLinks=true;var visits:[String:Int]=[:]
            let backup=NativeBackup(cancelled:{stopped},forceCopyPins:item.forceCopy ?? false,checkpoint:{point in
                visits[point,default:0]+=1
                if point=="snapshotEstablished",item.concurrent==true,!launched {
                    launched=true
                    DispatchQueue.global().async {
                        do {
                            var previous:URL?
                            try db.transaction {
                                try db.setMetadata("backup.left",value:"after");try db.setMetadata("backup.right",value:"after")
                                guard let id=item.documentID,let current=try db.get("Documents",key:["id":.text(id)]) else {throw NativeDBError.conflict}
                                let content=Data("new writer content".utf8),key="native-documents/"+UUID().uuidString.lowercased()+".txt",file=db.url.deletingLastPathComponent().appendingPathComponent(key)
                                try content.write(to:file,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
                                previous=db.url.deletingLastPathComponent().appendingPathComponent(current["key"].string)
                                _ = try db.update(current,changes:["key":.text(key),"document_file_url":.text("nextcrm-local://"+key),"size":.integer(Int64(content.count)),"content_hash":.text(NativeMigrationCodec.hash(content))],actor:item.userID!)
                            }
                            if let previous{try FileManager.default.removeItem(at:previous)}
                            lock.lock();writerCompleted=true;lock.unlock()
                        } catch {lock.lock();writerError=true;lock.unlock()}
                        done.signal()
                    }
                }
                if point=="pinsComplete" {
                    let folder=db.url.deletingLastPathComponent().appendingPathComponent("native-avatars")
                    if let files=try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) {
                        for file in files where !file.lastPathComponent.contains("pending") {var st=stat();if lstat(file.path,&st)==0,st.st_mode&S_IFMT==S_IFREG,st.st_nlink != 1{avatarLinks=false}}
                    }
                }
                if point=="afterFence",item.concurrent==true {guard done.wait(timeout:.now()+10) == .success else {throw NativeMigrationFailure("test.writer","同時writerがfence解放後に完了しません。")}}
                if point=="afterFence",item.mutatePinned==true,let id=item.documentID,let row=try db.get("Documents",key:["id":.text(id)]) {try Data("changed pinned inode".utf8).write(to:db.url.deletingLastPathComponent().appendingPathComponent(row["key"].string))}
                if item.failAt==point,visits[point]==(item.occurrence ?? 1){throw NativeMigrationFailure("test.failure","隔離テストの模擬失敗です。")}
                if item.cancelAt==point,visits[point]==(item.occurrence ?? 1){stopped=true}
            })
            let result=backup.prepare(source:db,destinationURL:URL(fileURLWithPath:item.destination))
            lock.lock();let completed=writerCompleted,failed=writerError;lock.unlock();guard !failed else {fatalError("synthetic writer failed")}
            outcomes.append(.init(name:item.name,result:result,writerCompleted:completed,sourceAvatarSingleLinks:avatarLinks))
            guard !result.applicationRestored,!result.keychainExported,!result.workersStarted else {fatalError("backup activated runtime")}
        }
        var queryChecks=0,queryArmed=false
        let interrupted=try NativeBackupSQLite(path:cases[0].source,readOnly:true,cancelled:{guard queryArmed else{return false};queryChecks+=1;return queryChecks>=3})
        queryArmed=true
        do {_ = try interrupted.first("WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<1000000) SELECT SUM(n) FROM numbers");fatalError("SQLite cancellation not enforced")}
        catch is CancellationError {guard queryChecks>=3 else{fatalError("SQLite cancellation probe failed")}}
        try JSONEncoder().encode(outcomes).write(to:spec.deletingLastPathComponent().appendingPathComponent("results.json"),options:.atomic)
        print("NativeBackupTests: \(outcomes.count) scenarios")
    }
}
