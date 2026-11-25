import Foundation
import Darwin

final class NativeRestore {
    private let cancelled:()->Bool,checkpoint:((String)throws->Void)?
    init(cancelled:@escaping()->Bool={Task.isCancelled},checkpoint:((String)throws->Void)?=nil){self.cancelled=cancelled;self.checkpoint=checkpoint}
    func prepare(backupURL:URL,schemaURL:URL,sqlURL:URL,destinationURL:URL)->NativeRestoreResult {
        var result=NativeRestoreResult(),work:NativeRestoreWorkspace?,db:NativeBackupSQLite?,index:NativeBackupSQLite?,reference:NativeBackupSQLite?,witness:NativeBackupWorkspace?
        var descriptors:[Int32]=[]
        defer{witness=nil;db=nil;index=nil;reference=nil;for fd in descriptors{close(fd)};work=nil}
        func check(_ point:String)throws{if cancelled(){throw CancellationError()};try checkpoint?(point);if cancelled(){throw CancellationError()}}
        func fail(_ code:String,_ message:String)->NativeMigrationFailure{.init("restore."+code,message)}
        func strict<T:Decodable>(_ type:T.Type,_ data:Data,keys:Set<String>?=nil)throws->T {
            guard let object=try NativeMigrationJSON.parse(data).object,keys.map({Set(object.keys)==$0}) ?? true else{throw fail("manifest","manifestの項目が不正です。")}
            do{return try JSONDecoder().decode(type,from:data)}catch{throw fail("manifest","manifestの型・項目を読み取れません。")}
        }
        func line<T:Encodable>(_ value:T,_ fd:Int32)throws{var data=try JSONEncoder().encode(value);guard data.count<=65536 else{throw fail("line_limit","復元metadataが1行の上限を超えています。")};data.append(10);try NativeMigrationImportWorkspace.write(data,to:fd)}
        do {
            try check("beforeRead")
            let source=try NativeMigrationFiles(root:backupURL)
            let raw=try source.data("snapshot.json",maximum:4*1024*1024,cancelled:cancelled)
            let shape=Set(try NativeMigrationJSON.parse(JSONEncoder().encode(NativeBackupResult())).object!.keys)
            let snapshot=try strict(NativeBackupResult.self,raw,keys:shape)
            guard snapshot.formatVersion==1,[NativeBackupStatus.prepared,.preparedWithPending].contains(snapshot.status),snapshot.candidateCreated,!snapshot.applicationRestored,!snapshot.keychainExported,!snapshot.workersStarted,
                  UUID(uuidString:snapshot.snapshotID)?.uuidString.lowercased()==snapshot.snapshotID,
                  snapshot.databaseBytes>0,snapshot.tableCount>0,snapshot.totalRows>=0,snapshot.fileCount>=0,snapshot.totalFileBytes>=0,
                  [snapshot.sourceNamespaceSHA256,snapshot.databaseSHA256,snapshot.filesManifestSHA256,snapshot.tablesManifestSHA256].allSatisfy(NativeMigrationCodec.validHash),
                  Set(snapshot.pending.map(\.rawValue)).count==snapshot.pending.count,
                  snapshot.pending.isEmpty == (snapshot.status == .prepared),snapshot.writeFenceSeconds.isFinite,snapshot.writeFenceSeconds>=0,
                  snapshot.pinnedByLink>=0,snapshot.pinnedByClone>=0,snapshot.copiedUnderFence>=0 else{throw fail("manifest","完了した対応versionのbackup manifestではありません。")}
            result.snapshotID=snapshot.snapshotID;result.sourceNamespaceSHA256=snapshot.sourceNamespaceSHA256;result.databaseSHA256=snapshot.databaseSHA256;result.databaseBytes=snapshot.databaseBytes;result.filesManifestSHA256=snapshot.filesManifestSHA256;result.tablesManifestSHA256=snapshot.tablesManifestSHA256;result.backupManifestSHA256=NativeMigrationCodec.hash(raw);result.inheritedPending=snapshot.pending
            guard schemaURL.isFileURL,sqlURL.isFileURL else{throw fail("schema","offline復元はローカルのtrusted schema resourceだけを使用します。") }
            let schemaData=try Data(contentsOf:schemaURL);guard schemaData.count<=4*1024*1024 else{throw fail("schema","schema resourceが上限を超えています。")}
            let schema=try JSONDecoder().decode(NativeMigrationSchema.self,from:schemaData)
            let sqlData=try Data(contentsOf:sqlURL);guard sqlData.count<=16*1024*1024,let sql=String(data:sqlData,encoding:.utf8),schema.formatVersion==1,NativeMigrationCodec.validHash(schema.schemaSHA256) else{throw fail("schema","対応するtrusted schema resourceがありません。")}
            result.schemaSHA256=schema.schemaSHA256
            try check("beforeDirectory")
            work=try NativeRestoreWorkspace(destination:destinationURL,backup:backupURL);let workspace=work!,out=workspace.output
            try out.put(Data("NextCRM native restore staging; ACTIVATION REVIEW REQUIRED\n".utf8),path:".native-restore-candidate")
            let dbFD=try out.create("crm.sqlite"),indexFD=try out.create("restore-index.sqlite"),referenceFD=try out.create("schema-reference.sqlite"),planFD=try out.create("resume-plan.ndjson")
            descriptors += [dbFD,indexFD,referenceFD,planFD]
            try check("beforeDatabase")
            try NativeRestoreWorkspace.copy(from:source,path:"database.sqlite",to:dbFD,bytes:snapshot.databaseBytes,hash:snapshot.databaseSHA256,cancelled:cancelled,progress:{try check("databaseChunk")})
            db=try NativeBackupSQLite(path:"/dev/fd/\(dbFD)",readOnly:true,descriptor:true,immutable:true,cancelled:cancelled)
            index=try NativeBackupSQLite(path:"/dev/fd/\(indexFD)",readOnly:false,descriptor:true,cancelled:cancelled)
            reference=try NativeBackupSQLite(path:"/dev/fd/\(referenceFD)",readOnly:false,descriptor:true,cancelled:cancelled)
            try index!.exec("CREATE TABLE assets(path TEXT PRIMARY KEY NOT NULL,archive TEXT UNIQUE NOT NULL,bytes INTEGER NOT NULL,hash TEXT NOT NULL);CREATE TABLE tables(name TEXT PRIMARY KEY NOT NULL);CREATE TABLE files(path TEXT PRIMARY KEY NOT NULL,pin TEXT NOT NULL,signature TEXT NOT NULL,bytes INTEGER NOT NULL,expected_hash TEXT)")
            try reference!.exec(sql)
            guard try db!.first("SELECT value FROM native_metadata WHERE key='schemaSHA256'")==schema.schemaSHA256,try db!.first("PRAGMA user_version")=="1",try db!.first("SELECT value FROM native_metadata WHERE key='mail.headerSearch.version'")=="1" else{throw fail("revision","現在のnative schema/revisionに一致しません。専用の移行が必要です。")}
            for model in schema.models {
                guard let expected=try reference!.first("SELECT sql FROM sqlite_master WHERE type='table' AND name=?",[.text(model.name)]),try db!.first("SELECT sql FROM sqlite_master WHERE type='table' AND name=?",[.text(model.name)])==expected else{throw fail("schema","CRMテーブル定義がtrusted schemaと一致しません。")}
                guard try db!.first("SELECT 1 FROM "+NativeBackupSQLite.quote(model.name)+" WHERE _native_revision<1 OR typeof(_native_revision)<>'integer' LIMIT 1")==nil else{throw fail("revision","レコードrevisionが不正です。")}
            }
            try reference!.rows("SELECT name,sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL",cancelled:cancelled){r in
                guard let name=r["name"] ?? nil,let sql=r["sql"] ?? nil,try db!.first("SELECT sql FROM sqlite_master WHERE type='index' AND name=?",[.text(name)])==sql else{throw fail("schema","CRM索引の定義がtrusted schemaと一致しません。")}
            }
            try NativeRestoreSchema.validate(db!)
            guard try db!.first("SELECT 1 FROM native_document_objects WHERE revision<1 OR typeof(revision)<>'integer' LIMIT 1")==nil else{throw fail("revision","文書mappingのrevisionが不正です。")}
            func descriptor(_ path:String,_ hash:String,_ rows:Int64)throws->NativeMigrationManifest.File {
                let measured=try source.read(path,cancelled:cancelled){_ in}
                guard measured.sha256==hash else{throw fail("manifest_hash","metadata manifestのhashが一致しません。")}
                return .init(path:path,rows:rows,bytes:measured.bytes,sha256:hash)
            }
            func keepManifest(_ description:NativeMigrationManifest.File)throws {
                let fd=try out.create(description.path);defer{close(fd)}
                try NativeRestoreWorkspace.copy(from:source,path:description.path,to:fd,bytes:description.bytes,hash:description.sha256,cancelled:cancelled,progress:{try check("manifestChunk")})
            }
            let tables=try descriptor("tables.ndjson",snapshot.tablesManifestSHA256,snapshot.tableCount)
            try keepManifest(tables)
            _ = try source.lines(tables,limit:65536,cancelled:cancelled){data,_ in try autoreleasepool {
                try check("table");let item=try strict(NativeBackupTable.self,data,keys:["name","rows","schemaSHA256"])
                guard item.name.utf8.count<=1024,item.rows>=0,NativeMigrationCodec.validHash(item.schemaSHA256),let definition=try db!.first("SELECT sql FROM sqlite_master WHERE type='table' AND name=?",[.text(item.name)]),NativeMigrationCodec.hash(Data(definition.utf8))==item.schemaSHA256,
                      try db!.first("SELECT COUNT(*) FROM "+NativeBackupSQLite.quote(item.name))==String(item.rows) else{throw fail("table","table定義・行数がmanifestと一致しません。")}
                guard try index!.first("SELECT 1 FROM tables WHERE name=?",[.text(item.name)])==nil else{throw fail("duplicate","table manifestが重複しています。")}
                try index!.write("INSERT INTO tables VALUES(?)",[.text(item.name)]);result.tableCount+=1
                let (total,overflow)=result.totalRows.addingReportingOverflow(item.rows);guard !overflow else{throw fail("count","行数が上限を超えています。")};result.totalRows=total
            }}
            guard result.totalRows==snapshot.totalRows,try db!.first("SELECT COUNT(*) FROM sqlite_master WHERE type='table'")==String(result.tableCount) else{throw fail("table","全table inventoryの件数が一致しません。")}
            guard try db!.first("PRAGMA integrity_check")=="ok",try db!.first("PRAGMA foreign_key_check")==nil else{throw fail("integrity","復元候補DBの整合性検査に失敗しました。")}
            try check("afterDatabase")
            let assets=try descriptor("files.ndjson",snapshot.filesManifestSHA256,snapshot.fileCount)
            try keepManifest(assets)
            _ = try source.lines(assets,limit:65536,cancelled:cancelled){data,_ in try autoreleasepool {
                try check("asset");let item=try strict(NativeBackupFile.self,data,keys:["sourcePath","archivePath","bytes","sha256"])
                _ = try NativeRestoreWorkspace.path(item.sourcePath)
                guard NativeMigrationCodec.matches(#"\Aassets/[0-9a-f]{64}\.blob\z"#,item.archivePath),item.bytes>=0,NativeMigrationCodec.validHash(item.sha256) else{throw fail("asset","添付manifestの型・保存パスが不正です。")}
                guard try index!.first("SELECT 1 FROM assets WHERE path=? OR archive=?",[.text(item.sourcePath),.text(item.archivePath)])==nil else{throw fail("duplicate","添付manifestが重複しています。")}
                try index!.write("INSERT INTO assets VALUES(?,?,?,?)",[.text(item.sourcePath),.text(item.archivePath),.integer(item.bytes),.text(item.sha256)])
                try workspace.copyAsset(item,source:source,cancelled:cancelled,progress:{try check("assetChunk")})
                result.fileCount+=1;let (total,overflow)=result.totalFileBytes.addingReportingOverflow(item.bytes);guard !overflow else{throw fail("count","添付サイズが上限を超えています。")};result.totalFileBytes=total
            }}
            guard result.totalFileBytes==snapshot.totalFileBytes else{throw fail("asset","添付合計サイズがmanifestと一致しません。")}
            try check("beforeReferences")
            // Reuse the exact backup ownership inventory against newly restored files.
            let witnessURL=destinationURL.deletingLastPathComponent().appendingPathComponent("restore-inspection-"+UUID().uuidString.lowercased())
            witness=try NativeBackupWorkspace(sourceURL:destinationURL,destination:witnessURL)
            var owned=NativeBackupResult()
            try NativeBackupInventory(source:db!,index:index!,workspace:witness!,cancelled:cancelled,progress:{try check("reference")}).pinAll(result:&owned)
            guard owned.fileCount==result.fileCount,try index!.first("SELECT 1 FROM files f LEFT JOIN assets a ON a.path=f.path WHERE a.path IS NULL OR a.bytes<>f.bytes OR (f.expected_hash IS NOT NULL AND a.hash<>f.expected_hash) LIMIT 1")==nil else{throw fail("references","DBが参照するファイルと添付inventoryが一致しません。")}
            for flag in [NativeBackupPending.externalFiles,.sourceMetadata,.avatarOriginal] where owned.pending.contains(flag) {
                guard snapshot.pending.contains(flag) else{throw fail("pending","backupの未解決項目がmanifestに記録されていません。")}
            }
            witness=nil
            try check("beforePlan")
            try NativeRestorePlan(db:db!,cancelled:cancelled,emit:{entry in
                try check("planRow");try line(entry,planFD);result.planRows+=1;result.planCounts[entry.kind,default:0]+=1
            }).build()
            guard fsync(planFD)==0 else{throw NativeMigrationFiles.io};result.resumePlanSHA256=try NativeRestoreWorkspace.digest(planFD,cancelled:cancelled).1
            result.stagingNamespaceSHA256=NativeMigrationCodec.hash(Data(destinationURL.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            // Detect changed backup metadata after all dependent reads.
            guard try source.data("snapshot.json",maximum:4*1024*1024,cancelled:cancelled)==raw else{throw fail("changed","処理中にsnapshot manifestが変更されました。")}
            _ = try descriptor("tables.ndjson",snapshot.tablesManifestSHA256,snapshot.tableCount)
            _ = try descriptor("files.ndjson",snapshot.filesManifestSHA256,snapshot.fileCount)
            try check("beforePublish");db=nil;index=nil;reference=nil
            guard unlinkat(out.root,"restore-index.sqlite",0)==0,unlinkat(out.root,"schema-reference.sqlite",0)==0 else{throw NativeMigrationFiles.io}
            result.status = .staged;result.candidateCreated=true
            try out.put(raw,path:"backup-snapshot.json")
            try out.put(JSONEncoder().encode(result),path:"restore.json");try check("afterResult");try workspace.publish()
        } catch is CancellationError {
            result.status = .cancelled;result.candidateCreated=false;result.diagnostics.append(.init(severity:"warning",code:"restore.cancelled",message:"復元候補の作成を中止し、新規ファイルを回収します。",model:nil,row:nil,field:nil))
        } catch {
            result.status = .failed;result.candidateCreated=false
            let failure=(error as? NativeMigrationFailure) ?? .init("restore.failed","復元候補を準備できませんでした。元backupと通常データは変更していません。")
            result.diagnostics.append(.init(severity:"error",code:failure.code,message:failure.message,model:nil,row:nil,field:nil))
        }
        return result
    }
}
