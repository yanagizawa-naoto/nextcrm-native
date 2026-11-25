import Foundation
import Darwin
import CryptoKit

/// Pins exact encrypted bytes and nonsecret hold inventory in the destination.
/// The explicit authority callback is required; no identity/session is created.
/// Binding/namespace checks authorize preservation only, never worker startup.
enum NativeCredentialMigrationArchive {
    private static let manifestKey="migration.operational.manifest"
    private final class Boundary {var ended=false}
    private static func writable(_ db:NativeDatabase,_ authorize:()throws->Void)throws {
        guard !db.isReadOnly else{throw NativeMigrationFailure("credential.readonly","閲覧専用データへ認証情報を保存できません。")};try authorize()
    }
    private static func boundary(_ db:NativeDatabase)throws {let p=Boundary();db.deferUntilTransactionEnds(onCommit:{p.ended=true},onRollback:{p.ended=true});guard p.ended else{throw NativeMigrationFailure("credential.transaction","認証情報の保全は取引処理の外で実行してください。")}}
    private static func namespace(_ db:NativeDatabase)->String {NativeMigrationCodec.hash(Data(db.url.resolvingSymlinksInPath().standardizedFileURL.path.utf8))}
    static func install(sourceRoot:URL,db:NativeDatabase,expectedManifestSHA256:String,authorize:()throws->Void,cancelled:()->Bool={Task.isCancelled})throws->NativeCredentialArchiveBinding {
        try boundary(db);try writable(db,authorize)
        guard NativeMigrationCodec.validHash(expectedManifestSHA256),try db.metadata(manifestKey)==expectedManifestSHA256 else{throw NativeMigrationFailure("credential.snapshot","取込元snapshotが一致しません。")}
        let source=try NativeMigrationFiles(root:sourceRoot),report=try source.data("migration-source-report.json",maximum:4*1024*1024,cancelled:cancelled)
        guard let object=try NativeMigrationJSON.parse(report).object,object["schemaSHA256"]?.string==db.schema.schemaSHA256,let snapshot=object["evidence"]?.object?["snapshot"]?.string,
              let handoff=object["credentialHandoff"]?.object,handoff["version"]?.integer==1,handoff["path"]?.string=="credentials.handoff",let hid=handoff["handoffID"]?.string,UUID(uuidString:hid) != nil,
              let bytes=handoff["bytes"]?.integer,bytes>12,let hash=handoff["sha256"]?.string,NativeMigrationCodec.validHash(hash),let count=handoff["entries"]?.integer,count>=0,
              let holds=object["holds"]?.object,holds["path"]?.string=="holds.ndjson",let holdBytes=holds["bytes"]?.integer,holdBytes>=0,let holdHash=holds["sha256"]?.string,NativeMigrationCodec.validHash(holdHash),let rows=holds["rows"]?.integer,rows>=count else{throw NativeMigrationFailure("credential.report","取込元の暗号化保全情報を確認できません。")}
        var captured:Int64=0
        _ = try source.lines(.init(path:"migration-holds.ndjson",rows:rows,bytes:holdBytes,sha256:holdHash),limit:65536,cancelled:cancelled){line,_ in
            guard let item=try NativeMigrationJSON.parse(line).object,let kind=item["kind"]?.string else{throw NativeMigrationFiles.io}
            // Preserve the full M06 hold inventory, including non-credential
            // unresolved jobs/tables/assets. Their pending status never disappears.
            if kind=="jobs" {guard Set(item.keys)==Set(["kind","classification","requiresOriginalSource"]),item["classification"]?.string=="external-inngest-inventory-required",item["requiresOriginalSource"]?.bool==true else{throw NativeMigrationFiles.io};return}
            if kind=="source-table" {guard Set(item.keys)==Set(["kind","table","classification","requiresOriginalSource"]),let table=item["table"]?.string,!table.isEmpty,table.utf8.count<=256,item["classification"]?.string=="unknown-schema-table",item["requiresOriginalSource"]?.bool==true else{throw NativeMigrationFiles.io};return}
            if kind=="asset",item["owner"]==nil {guard Set(item.keys)==Set(["kind","storageKeySHA256","classification","requiresOriginalSource"]),let digest=item["storageKeySHA256"]?.string,NativeMigrationCodec.validHash(digest),item["classification"]?.string=="unknown-owner",item["requiresOriginalSource"]?.bool==true else{throw NativeMigrationFiles.io};return}
            guard let owner=item["owner"]?.object,let modelName=owner["model"]?.string,let model=db.schema.models.first(where:{$0.name==modelName}),let keys=owner["key"]?.object,Set(keys.keys)==Set(model.primaryKey),keys.values.allSatisfy({$0.string != nil}) else{throw NativeMigrationFiles.io}
            if kind=="asset" {guard Set(item.keys)==Set(["kind","owner","classification","requiresOriginalSource"]),modelName=="ImageUpload",Set(owner.keys)==Set(["model","key"]),item["classification"]?.string=="unsupported-image-upload",item["requiresOriginalSource"]?.bool==true else{throw NativeMigrationFiles.io};return}
            guard let field=owner["field"]?.string,model.field(field) != nil else{throw NativeMigrationFiles.io}
            if kind=="object-observation" {
                guard Set(item.keys)==Set(["kind","owner","storageKeySHA256","versionSHA256","etagSHA256","classification","requiresOriginalSource"]),item["requiresOriginalSource"]?.bool==false else{throw NativeMigrationFiles.io};return
            }
            guard Set(item.keys)==Set(["kind","owner","valueSHA256","classification","requiresOriginalSource","handoff"]),["credential","opaque-json","credential-url"].contains(kind),item["requiresOriginalSource"]?.bool==false,
                  let digest=item["valueSHA256"]?.string,NativeMigrationCodec.validHash(digest),let reference=item["handoff"]?.object,reference["version"]?.integer==1,reference["handoffID"]?.string==hid,reference["valueSHA256"]?.string==digest,let entryID=reference["entryID"]?.string,UUID(uuidString:entryID) != nil else{throw NativeMigrationFailure("credential.hold","元の値を暗号化保全していない保留項目があります。")}
            captured+=1
        }
        guard captured==count else{throw NativeMigrationFailure("credential.hold_count","暗号化引継ぎと保留項目の件数が一致しません。")}
        let id=UUID().uuidString.lowercased(),folder=NativeCredentialArchiveBinding.folder,root=try NativeBackupWorkspace.openDirectory(db.url.deletingLastPathComponent());defer{close(root)}
        let made=mkdirat(root,folder,0o700)==0;if !made&&errno != EEXIST{throw NativeMigrationFiles.io}
        let directory=openat(root,folder,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard directory>=0 else{throw NativeMigrationFiles.io};defer{close(directory)}
        var directoryInfo=stat();guard fstat(directory,&directoryInfo)==0,directoryInfo.st_uid==geteuid(),directoryInfo.st_mode&0o077==0 else{throw NativeMigrationFiles.badPath}
        var created:[(String,dev_t,ino_t)]=[],finalized:[(String,NativeMigrationFiles.Fingerprint)]=[],published=false
        defer{if !published {for (name,dev,inode) in created {var s=stat();if fstatat(directory,name,&s,AT_SYMLINK_NOFOLLOW)==0,s.st_dev==dev,s.st_ino==inode{_ = unlinkat(directory,name,0)}};if made{var s=stat();if fstatat(root,folder,&s,AT_SYMLINK_NOFOLLOW)==0,s.st_dev==directoryInfo.st_dev,s.st_ino==directoryInfo.st_ino{_ = unlinkat(root,folder,AT_REMOVEDIR)}}}}
        var descriptors:[NativeCredentialArchiveBinding.File]=[]
        for (input,suffix,size,digest) in [("credentials.handoff","handoff",bytes,hash),("migration-holds.ndjson","holds",holdBytes,holdHash)] {
            if cancelled(){throw CancellationError()};let name=id+"."+suffix,fd=openat(directory,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw NativeMigrationFiles.io}
            do {var s=stat();guard fstat(fd,&s)==0 else{throw NativeMigrationFiles.io};created.append((name,s.st_dev,s.st_ino));var header=Data()
                let actual=try source.read(input,maximum:size,cancelled:cancelled){chunk in if suffix=="handoff",header.count<65548{header.append(chunk.prefix(65548-header.count))};try NativeMigrationImportWorkspace.write(chunk,to:fd)}
                guard actual.bytes==size,actual.sha256==digest,fsync(fd)==0 else{throw NativeMigrationFiles.io}
                if suffix=="handoff" {guard header.count>=12,header.prefix(8)==Data("NCRMSEC1".utf8) else{throw NativeMigrationFiles.io};let length=header[8..<12].reduce(0){($0<<8)|Int($1)};guard length>0,length<=65536,header.count>=12+length,let h=try NativeMigrationJSON.parse(header.subdata(in:12..<(12+length))).object,h["version"]?.integer==1,h["handoffID"]?.string==hid,h["schemaSHA256"]?.string==db.schema.schemaSHA256,h["snapshotID"]?.string==snapshot else{throw NativeMigrationFailure("credential.header","暗号化引継ぎのsnapshotが一致しません。")}}
                let back=try NativeRestoreWorkspace.digest(fd,cancelled:cancelled);guard back.0==size,back.1==digest,fchmod(fd,0o400)==0 else{throw NativeMigrationFiles.io};var final=stat();guard fstat(fd,&final)==0 else{throw NativeMigrationFiles.io};finalized.append((name,.init(final)));close(fd)
            }catch{close(fd);throw error}
            descriptors.append(.init(path:folder+"/"+name,bytes:size,sha256:digest))
        }
        let binding=try NativeCredentialArchiveBinding(version:1,id:id,namespace:namespace(db),schemaSHA256:db.schema.schemaSHA256,snapshotID:snapshot,importManifestSHA256:expectedManifestSHA256,handoffID:hid,entries:count,holdsRows:rows,files:descriptors).validated()
        try db.transaction {try writable(db,authorize);if cancelled(){throw CancellationError()};var current=stat();guard fstatat(root,folder,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==directoryInfo.st_dev,current.st_ino==directoryInfo.st_ino,try db.metadata(manifestKey)==expectedManifestSHA256,try db.metadata(binding.key)==nil,try db.metadata("schemaSHA256")==binding.schemaSHA256,binding.namespace==namespace(db),fsync(directory)==0 else{throw NativeMigrationFiles.io};for (name,fingerprint) in finalized {var value=stat();guard fstatat(directory,name,&value,AT_SYMLINK_NOFOLLOW)==0,NativeMigrationFiles.Fingerprint(value)==fingerprint else{throw NativeMigrationFiles.io}};try db.setMetadata(binding.key,value:String(decoding:JSONEncoder().encode(binding),as:UTF8.self))}
        published=true;return binding
    }
    /// After a held restore, verify bytes first, then explicitly update only the
    /// nonsecret destination binding. This never unlocks a provider or runtime.
    static func rebind(_ expected:NativeCredentialArchiveBinding,db:NativeDatabase,authorize:()throws->Void,cancelled:()->Bool={Task.isCancelled})throws->NativeCredentialArchiveBinding {
        try boundary(db);try writable(db,authorize);_ = try expected.validated()
        let raw=try db.metadata(expected.key);guard let raw,try NativeCredentialArchiveBinding.decode(raw,key:expected.key)==expected,try db.metadata(manifestKey)==expected.importManifestSHA256,db.schema.schemaSHA256==expected.schemaSHA256 else{throw NativeMigrationFiles.io}
        let files=try NativeMigrationFiles(root:db.url.deletingLastPathComponent())
        for file in expected.files {let digest=try files.read(file.path,maximum:file.bytes,cancelled:cancelled){_ in};guard digest.bytes==file.bytes,digest.sha256==file.sha256 else{throw NativeMigrationFiles.io}}
        let next=NativeCredentialArchiveBinding(version:1,id:expected.id,namespace:namespace(db),schemaSHA256:expected.schemaSHA256,snapshotID:expected.snapshotID,importManifestSHA256:expected.importManifestSHA256,handoffID:expected.handoffID,entries:expected.entries,holdsRows:expected.holdsRows,files:expected.files)
        try db.transaction {try writable(db,authorize);if cancelled(){throw CancellationError()};guard try db.metadata(expected.key)==raw,try db.metadata(manifestKey)==expected.importManifestSHA256 else{throw NativeMigrationFiles.io};for file in expected.files {let digest=try files.read(file.path,maximum:file.bytes,cancelled:cancelled){_ in};guard digest.bytes==file.bytes,digest.sha256==file.sha256 else{throw NativeMigrationFiles.io}};try db.setMetadata(expected.key,value:String(decoding:JSONEncoder().encode(next),as:UTF8.self))};return next
    }
}
