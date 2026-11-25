import Foundation
import Darwin
import CryptoKit

final class NativeBackup {
    private let cancelled:()->Bool,checkpoint:((String)throws->Void)?
    private let forceCopyPins:Bool
    init(cancelled:@escaping ()->Bool={Task.isCancelled},forceCopyPins:Bool=false,checkpoint:((String)throws->Void)?=nil){self.cancelled=cancelled;self.forceCopyPins=forceCopyPins;self.checkpoint=checkpoint}
    func prepare(source:NativeDatabase,destinationURL:URL)->NativeBackupResult {
        var result=NativeBackupResult();var workspace:NativeBackupWorkspace?,reader:NativeBackupSQLite?,index:NativeBackupSQLite?,destination:NativeBackupSQLite?
        var descriptors:[Int32]=[]
        defer{reader=nil;index=nil;destination=nil;for fd in descriptors{close(fd)};workspace=nil}
        func check(_ point:String)throws{if cancelled(){throw CancellationError()};try checkpoint?(point);if cancelled(){throw CancellationError()}}
        func streamDigest(_ fd:Int32)throws->(Int64,String){guard lseek(fd,0,SEEK_SET)==0 else{throw NativeMigrationFiles.io};var hash=SHA256(),bytes:Int64=0;var buffer=[UInt8](repeating:0,count:65536);while true{if cancelled(){throw CancellationError()};let n=Darwin.read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw NativeMigrationFiles.io};if n==0{break};hash.update(data:Data(buffer.prefix(n)));bytes+=Int64(n)};return(bytes,hash.finalize().map{String(format:"%02x",$0)}.joined())}
        func line<T:Encodable>(_ value:T,to fd:Int32)throws{var data=try JSONEncoder().encode(value);data.append(10);try NativeMigrationImportWorkspace.write(data,to:fd)}
        do {
            try check("beforeDirectory")
            workspace=try NativeBackupWorkspace(sourceURL:source.url.deletingLastPathComponent(),destination:destinationURL)
            let work=workspace!,output=work.output
            try output.put(Data("NextCRM native snapshot candidate; NOT RESTORED\n".utf8),path:".native-backup-candidate")
            let indexFD=try output.create("files-index.sqlite");descriptors.append(indexFD)
            index=try NativeBackupSQLite(path:"/dev/fd/\(indexFD)",readOnly:false,descriptor:true,cancelled:cancelled)
            try index!.exec("CREATE TABLE files(path TEXT PRIMARY KEY NOT NULL,pin TEXT NOT NULL,signature TEXT NOT NULL,bytes INTEGER NOT NULL,expected_hash TEXT)")
            let dbFD=try output.create("database.sqlite"),tablesFD=try output.create("tables.ndjson"),filesFD=try output.create("files.ndjson")
            descriptors += [dbFD,tablesFD,filesFD]
            destination=try NativeBackupSQLite(path:"/dev/fd/\(dbFD)",readOnly:false,descriptor:true,cancelled:cancelled)
            result.sourceNamespaceSHA256=NativeMigrationCodec.hash(Data(source.url.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            try check("beforeFence")
            let started=Date()
            try source.transaction {
                try check("insideFence")
                // Source is read-only; NativeDatabase owns the mandatory writer
                // fence. No arbitrary callback may pretend to hold that fence.
                reader=try NativeBackupSQLite(path:source.url.path,readOnly:true,cancelled:cancelled)
                try reader!.exec("BEGIN")
                _ = try reader!.first("SELECT COUNT(*) FROM sqlite_master")
                result.sourceJournalMode=try reader!.first("PRAGMA journal_mode") ?? "unknown"
                try check("snapshotEstablished")
                let inventory=NativeBackupInventory(source:reader!,index:index!,workspace:work,cancelled:cancelled,progress:{try check("pinFile")},forceCopy:forceCopyPins)
                try inventory.pinAll(result:&result)
                try check("pinsComplete")
            }
            result.writeFenceSeconds=Date().timeIntervalSince(started)
            try check("afterFence")
            try reader!.backup(to:destination!,cancelled:cancelled,progress:{try check("databasePage")})
            try check("afterDatabase")
            // SQLite backup preserves WAL header bytes. Reopen this newly completed,
            // private copy immutable so validation needs no sidecars through /dev/fd.
            destination=nil
            destination=try NativeBackupSQLite(path:"/dev/fd/\(dbFD)",readOnly:true,descriptor:true,immutable:true,cancelled:cancelled)
            try reader!.rows("SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name",cancelled:cancelled){row in
                guard let name=row["name"] ?? nil else{throw NativeMigrationFailure("backup.table","table名を確認できません。")}
                let query="SELECT COUNT(*) FROM "+NativeBackupSQLite.quote(name)
                guard let countText=try reader!.first(query),let count=Int64(countText),count>=0,try destination!.first(query)==countText else{throw NativeMigrationFailure("backup.rowcount","元snapshotと候補のtable行数が一致しません。")}
                let sql=row["sql"] ?? nil,other=try destination!.first("SELECT sql FROM sqlite_master WHERE type='table' AND name=?",[.text(name)])
                guard sql==other else{throw NativeMigrationFailure("backup.schema","元snapshotと候補のtable定義が一致しません。")}
                try line(NativeBackupTable(name:name,rows:count,schemaSHA256:NativeMigrationCodec.hash(Data((sql ?? "").utf8))),to:tablesFD)
                result.tableCount+=1;result.totalRows+=count
            }
            guard try destination!.first("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")==String(result.tableCount) else{throw NativeMigrationFailure("backup.tables","候補のtable数が一致しません。")}
            guard try destination!.first("PRAGMA integrity_check")=="ok",try destination!.first("PRAGMA foreign_key_check")==nil else{throw NativeMigrationFailure("backup.integrity","候補DBの整合性検査に失敗しました。")}
            try reader!.exec("ROLLBACK");reader=nil
            destination=nil
            guard fsync(dbFD)==0 else{throw NativeMigrationFiles.io}
            (result.databaseBytes,result.databaseSHA256)=try streamDigest(dbFD)
            try check("beforeFiles")
            try index!.rows("SELECT path,pin,signature,bytes,expected_hash FROM files ORDER BY path",cancelled:cancelled){row in
                guard let path=row["path"] ?? nil,let pin=row["pin"] ?? nil,let signature=row["signature"] ?? nil,let bytes=(row["bytes"] ?? nil).flatMap(Int64.init) else{throw NativeMigrationFailure("backup.index","固定ファイル索引が不正です。")}
                let copied=try work.copyPin(pin,signature:signature,expectedBytes:bytes,expectedSHA:row["expected_hash"] ?? nil,cancelled:cancelled,progress:{try check("fileChunk")})
                try line(NativeBackupFile(sourcePath:path,archivePath:copied.path,bytes:copied.bytes,sha256:copied.sha256),to:filesFD)
                result.totalFileBytes+=copied.bytes
            }
            guard fsync(tablesFD)==0,fsync(filesFD)==0 else{throw NativeMigrationFiles.io}
            result.tablesManifestSHA256=try streamDigest(tablesFD).1;result.filesManifestSHA256=try streamDigest(filesFD).1
            try check("beforePublish")
            index=nil;guard unlinkat(output.root,"files-index.sqlite",0)==0 else{throw NativeMigrationFiles.io};work.removePins()
            result.status = result.pending.isEmpty ? .prepared:.preparedWithPending;result.candidateCreated=true
            try output.put(JSONEncoder().encode(result),path:"snapshot.json");try check("afterResult");try output.publish()
        } catch is CancellationError {
            result.status = .cancelled;result.candidateCreated=false;result.diagnostics.append(.init(severity:"warning",code:"backup.cancelled",message:"snapshotを中止しました。作成途中の候補を回収します。",model:nil,row:nil,field:nil))
        } catch {
            result.status = .failed;result.candidateCreated=false
            let e=(error as? NativeMigrationFailure) ?? NativeMigrationFailure("backup.failed","snapshotを作成できませんでした。元の業務データは変更していません。")
            result.diagnostics.append(.init(severity:"error",code:e.code,message:e.message,model:nil,row:nil,field:nil))
        }
        return result
    }
}
