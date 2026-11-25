import Foundation
import CryptoKit
import Darwin

/// Prepares a NEW private offline root. No bootstrap, localActor, provider,
/// Keychain, plugin host, hooks or jobs. Activation/credential review is separate.
final class NativeOperationalMigration {
    struct Result:Codable {var status="failed", mapped=0,unresolved=0;var workersStarted=false,credentialsMigrated=false,applicationActivated=false;var pending=["source-provenance","identity","credentials","jobs","startup-review"];var failure:String?}
    private let cancelled:()->Bool,checkpoint:(String)throws->Void
    init(cancelled:@escaping()->Bool={Task.isCancelled},checkpoint:@escaping(String)throws->Void={_ in}){self.cancelled=cancelled;self.checkpoint=checkpoint}
    private func check(_ point:String)throws{if cancelled(){throw CancellationError()};try checkpoint(point);if cancelled(){throw CancellationError()}}
    func prepare(bundle:URL,schema:URL,sql:URL,destination:URL,preservationAdmission:(()throws->Void)?=nil)throws->Result {
        let temp=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory()
        guard let rawParent=realpath(destination.deletingLastPathComponent().path,nil) else{throw NativeMigrationFiles.badPath};defer{free(rawParent)}
        let parent=URL(fileURLWithPath:String(cString:rawParent),isDirectory:true)
        guard let rawSource=realpath(bundle.path,nil) else{throw NativeMigrationFiles.badPath};defer{free(rawSource)}
        let sourcePath=String(cString:rawSource),destinationPath=parent.path+"/"+destination.lastPathComponent
        guard destinationPath != sourcePath,!destinationPath.hasPrefix(sourcePath+"/") else{throw NativeMigrationFiles.badPath}
        guard parent.path==temp.path || parent.path.hasPrefix(temp.path+"/"),destination.lastPathComponent==destination.lastPathComponent.trimmingCharacters(in:.whitespacesAndNewlines),!destination.path.hasPrefix(bundle.path+"/"),destination != bundle else{throw NativeMigrationFailure("operational.destination","新しい隔離一時フォルダを指定してください。")}
        // Reuse pinned exclusive workspace creation and inode-aware rollback.
        let owned=try NativeMigrationImportWorkspace(destination:parent.appendingPathComponent(destination.lastPathComponent),bundle:bundle)
        try owned.makeAssets();try owned.put(Data("offline operational preparation; REVIEW REQUIRED\n".utf8),path:".native-operational-candidate")
        let root=owned.url,importRoot=root.appendingPathComponent("imported")
        var result=Result(),db:NativeDatabase?
        do {
            let imported=NativeMigrationImport(cancelled:cancelled).prepare(bundleURL:bundle,schemaURL:schema,sqlURL:sql,destinationURL:importRoot)
            guard imported.candidateCreated else{let codes=(imported.diagnostics+(imported.preflight?.diagnostics ?? [])).filter{$0.severity=="error"}.prefix(4).map(\.code).joined(separator:",");throw NativeMigrationFailure("operational.import","元bundleを安全に取り込めません。"+(codes.isEmpty ? "" : "（"+codes+"）"))}
            try check("afterImport")
            let bundleFiles=try NativeMigrationFiles(root:bundle)
            let reportData=try bundleFiles.data("export-report.json",maximum:4*1024*1024,cancelled:cancelled)
            guard let report=try NativeMigrationJSON.parse(reportData).object,report["schemaSHA256"]?.string==imported.schemaSHA256,
                  let holdObject=report["holds"],let holds=try? JSONDecoder().decode(NativeMigrationManifest.File.self,from:NativeMigrationImportCodec.json(holdObject)),holds.path=="holds.ndjson" else{throw NativeMigrationFailure("operational.holds","元の保留inventoryがありません。")}
            try owned.put(reportData,path:"migration-source-report.json")
            if let handoff=report["credentialHandoff"]?.object {
                guard preservationAdmission != nil else{throw NativeMigrationFailure("operational.credential_admission","暗号化した元データを新しい保存先へ保全する操作確認が必要です。")}
                guard handoff["version"]?.integer==1,handoff["path"]?.string=="credentials.handoff",
                      let hash=handoff["sha256"]?.string,NativeMigrationCodec.validHash(hash),let bytes=handoff["bytes"]?.integer,bytes>=0,
                      let entries=handoff["entries"]?.integer,entries>=0,let handoffID=handoff["handoffID"]?.string,UUID(uuidString:handoffID) != nil else{throw NativeMigrationFailure("operational.handoff","暗号化引継ぎの宣言が不正です。")}
                try owned.copy("credentials.handoff",from:bundleFiles,to:"credentials.handoff",expectedBytes:bytes,expectedHash:hash,cancelled:cancelled)
                result.pending.append("encrypted-credential-application")
            }

            try owned.copy("holds.ndjson",from:bundleFiles,to:"migration-holds.ndjson",expectedBytes:holds.bytes,expectedHash:holds.sha256,cancelled:cancelled)
            if holds.rows>0{result.pending.append("source-hold-inventory")}
            if imported.pending.contains(.imageObjectInventory){result.pending.append("image-object-inventory")}

            let files=try NativeMigrationFiles(root:importRoot)
            let actual=try files.read("candidate.sqlite",cancelled:cancelled){_ in}
            try owned.copy("candidate.sqlite",from:files,to:"crm.sqlite",expectedBytes:actual.bytes,expectedHash:actual.sha256,cancelled:cancelled)
            db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:schema,sqlURL:sql)
            try db!.setMetadata("migration.operational.state",value:"preparing")
            try db!.setMetadata("migration.operational.manifest",value:NativeMigrationCodec.hash(try files.data("bundle-manifest.json",maximum:4*1024*1024,cancelled:cancelled)))
            if report["credentialHandoff"] != nil {
                guard let preservationAdmission,let sourceManifest=try db!.metadata("migration.operational.manifest") else{throw NativeMigrationFiles.io}
                _ = try NativeCredentialMigrationArchive.install(sourceRoot:root,db:db!,expectedManifestSHA256:sourceManifest,authorize:{try self.check("credentialArchive");try preservationAdmission()},cancelled:cancelled)
            }
            for folder in ["native-documents","invoice-pdfs","native-avatars"]{guard mkdirat(owned.root,folder,0o700)==0 else{throw NativeMigrationFiles.io}}
            let manifest=try JSONDecoder().decode(NativeMigrationManifest.self,from:files.data("bundle-manifest.json",maximum:4*1024*1024,cancelled:cancelled))
            let assetFile=NativeMigrationManifest.File(path:"assets.ndjson",rows:manifest.assets.rows,bytes:manifest.assets.bytes,sha256:manifest.assets.sha256)
            _ = try files.lines(assetFile,limit:8*1024*1024,cancelled:cancelled){data,_ in try autoreleasepool {
                try check("asset")
                guard let raw=try NativeMigrationJSON.parse(data).object,let owners=raw["owners"]?.array else{throw NativeMigrationFiles.io}
                guard let sha=raw["sha256"]?.string,let bytes=raw["bytes"]?.integer,raw["path"] != nil else{result.unresolved+=1;return}
                for owner in owners {
                    guard let ref=owner.object,let model=ref["model"]?.string,let id=ref["key"]?.object?["id"]?.string,let field=ref["field"]?.string,let row=try db!.get(model,key:["id":.text(id.lowercased())]) else{throw NativeMigrationFiles.io}
                    let source="assets/"+sha+".blob",uuid=UUID().uuidString.lowercased();var local="",mime="application/octet-stream",binding:String?
                    if model=="Documents" {
                        local="native-documents/"+uuid+".bin";mime=row["document_file_mimeType"].string
                        try self.copy(files,source:source,to:local,root:owned.root,bytes:bytes,sha:sha)
                        // Archive bucket keeps imported originals referenced without
                        // changing live bucket or hiding the legacy extracted text.
                        _ = try db!.putDocumentObject(bucket:"migration-archive",key:model+":"+id+":"+field,fileKey:local,contentType:mime,bytes:bytes,sha256:sha)
                    } else if model=="Invoices" || model=="Invoice_Attachments" {
                        local="invoice-pdfs/"+uuid+".pdf";mime=model=="Invoices" ? "application/pdf":row["mimeType"].string
                        try self.copy(files,source:source,to:local,root:owned.root,bytes:bytes,sha:sha)
                    } else if model=="Users" {
                        // Preserve exact original and use the same ordinary bounded codec.
                        guard bytes<=Int64(NativeUserAvatarStore.maximumInputBytes) else{result.unresolved+=1;continue}
                        let original=try files.data(source,maximum:NativeUserAvatarStore.maximumInputBytes,cancelled:cancelled)
                        guard NativeMigrationCodec.hash(original)==sha else{throw NativeMigrationFiles.io}
                        let image:(thumbnail:Data,mime:String,extensionName:String)
                        do{image=try NativeUserAvatarStore.migrationImage(original)}catch{result.unresolved+=1;continue}
                        local=NativeUserAvatarStore.prefix+uuid+".png";mime=image.mime;binding=NativeOperationalAssets.avatarBinding(row)
                        try self.put(image.thumbnail,to:"native-avatars/"+uuid+".png",root:owned.root)
                        try self.copy(files,source:source,to:"native-avatars/"+uuid+".original."+image.extensionName,root:owned.root,bytes:bytes,sha:sha)
                    } else {result.unresolved+=1;continue}
                    try NativeOperationalAssets.save(.init(model:model,id:row["id"].string,field:field,sourceSHA256:NativeOperationalAssets.digest(row[field].string),local:local,mime:mime,bytes:bytes,sha256:sha,avatarBinding:binding,contentBinding:model=="Documents" ? NativeOperationalAssets.documentBinding(row):nil),db:db!)
                    result.mapped+=1
                }
            }}
            try check("beforeSearch");try db!.rebuildOperationalMigrationSearch();try NativeMigratedDocuments.recordAll(in:db!)
            try db!.setMetadata("migration.operational.state",value:"review-required")
            try check("beforePublish");try db!.sealOperationalMigration();db=nil
            try Self.finishPrivateSidecars(root:owned.root);try check("afterSeal")
            // Reopen through the ordinary DB first; its close checkpoints WAL.
            var readonly:NativeDatabase?=try NativeDatabase(readOnlyURL:root.appendingPathComponent("crm.sqlite"),schemaURL:schema);readonly=nil;_ = readonly
            result.status=result.unresolved>0 ? "prepared-with-gaps":"prepared-held"
            try owned.put(JSONEncoder().encode(result),path:"operational.json")
            for folder in ["native-documents","invoice-pdfs","native-avatars"]{let fd=openat(owned.root,folder,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw NativeMigrationFiles.io};let status=fsync(fd);close(fd);guard status==0 else{throw NativeMigrationFiles.io}}
            try owned.publish();return result
        } catch {
            if let active=db {
                do{try active.discardOperationalMigrationConnection()}catch{try? owned.publish();throw error}
            }
            db=nil
            for suffix in ["-wal","-shm","-journal"]{var info=stat();if fstatat(owned.root,"crm.sqlite"+suffix,&info,AT_SYMLINK_NOFOLLOW)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==geteuid(),info.st_nlink==1{_ = unlinkat(owned.root,"crm.sqlite"+suffix,0)}}
            // These directories are exclusive descendants created by this call.
            // No arbitrary source path participates in rollback.
            for name in ["native-documents","invoice-pdfs","native-avatars","native-credential-archives","imported"]{Self.removeOwnedDirectory(parent:owned.root,name:name)}
            throw error
        }
    }
    /// SQLite on Darwin can retain an unused SHM after DELETE-mode transition.
    /// Only this new exclusive root, after successful checkpoint + close, may
    /// remove it. Never remove a WAL/journal or a busy/nonregular shared mapping.
    private static func finishPrivateSidecars(root:Int32)throws{
        for suffix in ["-wal","-journal"]{var info=stat();guard fstatat(root,"crm.sqlite"+suffix,&info,AT_SYMLINK_NOFOLLOW) != 0,errno==ENOENT else{throw NativeMigrationFiles.io}}
        let fd=openat(root,"crm.sqlite-shm",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        if fd<0{guard errno==ENOENT else{throw NativeMigrationFiles.io};return};defer{close(fd)}
        var info=stat(),linked=stat(),lock=flock();lock.l_type=Int16(F_WRLCK);lock.l_whence=Int16(SEEK_SET);lock.l_start=0;lock.l_len=0
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==geteuid(),info.st_nlink==1,fcntl(fd,F_SETLK,&lock)==0,
              fstatat(root,"crm.sqlite-shm",&linked,AT_SYMLINK_NOFOLLOW)==0,linked.st_dev==info.st_dev,linked.st_ino==info.st_ino,unlinkat(root,"crm.sqlite-shm",0)==0 else{throw NativeMigrationFiles.io}
    }
    private static func removeOwnedDirectory(parent:Int32,name:String){
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{return};defer{close(fd)}
        var held=stat();guard fstat(fd,&held)==0,let dir=fdopendir(dup(fd)) else{return};defer{closedir(dir)}
        while let entry=readdir(dir){let item=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:1024){String(cString:$0)}};if item=="." || item==".."{continue};var info=stat();guard fstatat(fd,item,&info,AT_SYMLINK_NOFOLLOW)==0 else{continue};if info.st_mode&S_IFMT==S_IFDIR{removeOwnedDirectory(parent:fd,name:item)}else{_ = unlinkat(fd,item,0)}}
        var current=stat();if fstatat(parent,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==held.st_dev,current.st_ino==held.st_ino{_ = unlinkat(parent,name,AT_REMOVEDIR)}
    }
    private func put(_ bytes:Data,to path:String,root:Int32)throws{let fd=try target(path,root:root);defer{close(fd)};try NativeMigrationImportWorkspace.write(bytes,to:fd);guard fsync(fd)==0 else{throw NativeMigrationFiles.io}}
    private func target(_ path:String,root:Int32)throws->Int32 {
        let parts=try NativeMigrationFiles.path(path);guard parts.count==2,["native-documents","invoice-pdfs","native-avatars"].contains(parts[0]) else{throw NativeMigrationFiles.badPath}
        let dir=openat(root,parts[0],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard dir>=0 else{throw NativeMigrationFiles.io};defer{close(dir)}
        let fd=openat(dir,parts[1],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw NativeMigrationFiles.io};return fd
    }
    private func copy(_ source:NativeMigrationFiles,source path:String,to destination:String,root:Int32,bytes:Int64,sha:String)throws{
        let fd=try target(destination,root:root);defer{close(fd)}
        let got=try source.read(path,cancelled:cancelled){try NativeMigrationImportWorkspace.write($0,to:fd)}
        guard got.bytes==bytes,got.sha256==sha,fsync(fd)==0 else{throw NativeMigrationFiles.io}
    }
}
