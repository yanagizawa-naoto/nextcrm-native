import Foundation
import Darwin

@main enum NativeCredentialArchiveTests {
    static var checks=0
    static func check(_ condition:@autoclosure()throws->Bool,_ label:String)throws {guard try condition() else{fputs("Archive check failed: \(label)\n",stderr);throw NativeMigrationFiles.io};checks+=1}
    static func reject(_ label:String,_ body:()throws->Void)throws {var rejected=false;do{try body()}catch{rejected=true};try check(rejected,label)}
    static func hash(_ url:URL)throws->String{NativeMigrationCodec.hash(try Data(contentsOf:url))}
    static func main() {
        do {
            umask(0o077);let native=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=URL(fileURLWithPath:CommandLine.arguments[2]),root=URL(fileURLWithPath:CommandLine.arguments[3]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let schema=native.appendingPathComponent("schema.json"),sql=native.appendingPathComponent("schema.sql"),manifest=NativeMigrationCodec.hash(Data("synthetic-M06-snapshot-manifest".utf8))
            func fresh(_ name:String)throws->NativeDatabase{let db=try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:schema,sqlURL:sql);try db.setMetadata("migration.operational.manifest",value:manifest);return db}
            let db=try fresh("source"),input=fixture.appendingPathComponent("operational"),sourceSHA=try hash(input.appendingPathComponent("credentials.handoff")),holdSHA=try hash(input.appendingPathComponent("migration-holds.ndjson"))
            var calls=0
            let binding=try NativeCredentialMigrationArchive.install(sourceRoot:input,db:db,expectedManifestSHA256:manifest,authorize:{calls+=1})
            try check(calls==2,"explicit authorization before and at publication")
            let raw=try db.metadata(binding.key)!;try check(try NativeCredentialArchiveBinding.decode(raw,key:binding.key)==binding,"destination-bound inventory published")
            try check(binding.entries==12&&binding.holdsRows==15&&binding.snapshotID=="synthetic-snapshot-1","same snapshot and opaque hold count")
            for file in binding.files {try check(try hash(db.url.deletingLastPathComponent().appendingPathComponent(file.path))==file.sha256,"installed exact ciphertext/holds")}
            let archiveURL=db.url.deletingLastPathComponent().appendingPathComponent(binding.files.first(where:{$0.path.hasSuffix(".handoff")})!.path),holdURL=db.url.deletingLastPathComponent().appendingPathComponent(binding.files.first(where:{$0.path.hasSuffix(".holds")})!.path)
            var original=stat();try check(lstat(archiveURL.path,&original)==0&&original.st_nlink==1&&original.st_mode&0o777==0o400,"immutable private ciphertext inode")
            let backup=root.appendingPathComponent("backup"),back=NativeBackup().prepare(source:db,destinationURL:backup)
            if !back.candidateCreated { fputs("Backup diagnostics: "+back.diagnostics.map(\.code).joined(separator:",")+"\n",stderr) }
            try check(back.candidateCreated&&back.fileCount==2,"actual backup pins both files")
            try check(!back.keychainExported && !back.workersStarted,"backup grants no key or worker authority")
            var after=stat();try check(lstat(archiveURL.path,&after)==0&&after.st_nlink==1&&after.st_ino==original.st_ino,"backup pin does not hardlink or replace owned archive")
            let backupManifestSHA=try hash(backup.appendingPathComponent("snapshot.json")),dest=root.appendingPathComponent("restored"),restore=NativeRestore().prepare(backupURL:backup,schemaURL:schema,sqlURL:sql,destinationURL:dest)
            try check(restore.candidateCreated&&restore.fileCount==2,"actual restore copies both files")
            try check(!restore.activated && !restore.workersStarted && !restore.keychainAccessed,"held restore stays inactive")
            try check(restore.planCounts["credentialArchive"]==1,"restore explicitly lists archive review obligation")
            let readonly=try NativeDatabase(readOnlyURL:dest.appendingPathComponent("crm.sqlite"),schemaURL:schema)
            try check(try readonly.metadata(binding.key)==raw,"held restore keeps original namespace evidence")
            try reject("readonly application reader rejects originals"){try NativeCredentialMigrationArchiveReader.forEach(binding,db:readonly,key:Data(repeating:0,count:32),authorize:{},body:{_,_ in throw NativeMigrationFiles.io})}
            try reject("readonly archive rebind"){_ = try NativeCredentialMigrationArchive.rebind(binding,db:readonly,authorize:{})}
            let target=try NativeDatabase(url:dest.appendingPathComponent("crm.sqlite"),schemaURL:schema,sqlURL:sql),rebound=try NativeCredentialMigrationArchive.rebind(binding,db:target,authorize:{})
            try check(rebound.namespace != binding.namespace&&rebound.files==binding.files,"new namespace rebind changes only destination proof")
            try check(try db.metadata(binding.key)==raw&&hash(backup.appendingPathComponent("snapshot.json"))==backupManifestSHA,"old DB and backup unchanged")
            // Authenticate the restored encrypted archive and read every original,
            // including unknown business JSON and legacy sessions, without activation.
            let f=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("handoff-fixture.json"))) as! [String:Any],ref=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("reference.json"))) as! [String:Any]
            let keyText=ref["handoffKeyHex"] as! String,key=Data(stride(from:0,to:keyText.count,by:2).map{i in let a=keyText.index(keyText.startIndex,offsetBy:i);return UInt8(keyText[a..<keyText.index(a,offsetBy:2)],radix:16)!}),descriptor=try JSONDecoder().decode(NativeCredentialMigrationDescriptor.self,from:JSONSerialization.data(withJSONObject:f["descriptor"]!))
            let encrypted=rebound.files.first(where:{$0.path.hasSuffix(".handoff")})!,reader=try NativeCredentialMigrationEnvelope(root:dest.appendingPathComponent(NativeCredentialArchiveBinding.folder),descriptor:descriptor,key:key,schemaSHA256:rebound.schemaSHA256,snapshotID:rebound.snapshotID,fileName:URL(fileURLWithPath:encrypted.path).lastPathComponent)
            var decoded=0,unknown=false,session=false
            try NativeCredentialMigrationArchiveReader.forEach(rebound,db:target,key:key,authorize:{}) {entry,bytes in decoded+=1;if entry.owner.model=="PluginData"{unknown=String(data:bytes,encoding:.utf8)==" { \"business\" : [1, 2], \"unknownToken\" : \"preserve-synthetic\" }\n"};if entry.owner.model=="Session"{session=String(data:bytes,encoding:.utf8)=="synthetic-session-never-activate"}}
            try check(decoded==12&&unknown&&session,"restored cipher decrypts unknown business/auth originals exactly")
            try reject("old namespace cannot apply after restore"){try NativeCredentialMigrationArchiveReader.forEach(binding,db:target,key:key,authorize:{},body:{_,_ in})}
            var admissions=0,delivered=0
            try reject("per-entry fresh authority"){try NativeCredentialMigrationArchiveReader.forEach(rebound,db:target,key:key,authorize:{admissions+=1;if admissions==3{throw NativeMigrationFiles.io}},body:{_,_ in delivered+=1})}
            try check(delivered==1,"revoked application stops before next plaintext delivery")

            try reject("unsafe filename reader"){_ = try NativeCredentialMigrationEnvelope(root:dest,descriptor:descriptor,key:key,schemaSHA256:rebound.schemaSHA256,snapshotID:rebound.snapshotID,fileName:"../credentials.handoff")}
            let backupAgain=NativeBackup(forceCopyPins:true).prepare(source:target,destinationURL:root.appendingPathComponent("backup-again"));try check(backupAgain.candidateCreated&&backupAgain.fileCount==2,"rebound data can be backed up again by stream-copy path")
            let failure=try fresh("failure");var checksAtFence=0
            try reject("authority revoked at publish"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:failure,expectedManifestSHA256:manifest,authorize:{checksAtFence+=1;if checksAtFence==2{throw NativeMigrationFiles.io}})}
            try check(!FileManager.default.fileExists(atPath:failure.url.deletingLastPathComponent().appendingPathComponent(NativeCredentialArchiveBinding.folder).path),"failed publish cleans only newly owned files")
            let replaced=try fresh("replaced"),replaceFolder=replaced.url.deletingLastPathComponent().appendingPathComponent(NativeCredentialArchiveBinding.folder);var replaceCalls=0,replacement:URL?
            try reject("replacement at publication fence"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:replaced,expectedManifestSHA256:manifest,authorize:{replaceCalls+=1;if replaceCalls==2{let file=try FileManager.default.contentsOfDirectory(at:replaceFolder,includingPropertiesForKeys:nil).first(where:{$0.pathExtension=="handoff"})!;try FileManager.default.removeItem(at:file);try Data("synthetic-foreign-owned-replacement".utf8).write(to:file,options:.withoutOverwriting);replacement=file}})}
            try check(replacement != nil && (try? String(contentsOf:replacement!))=="synthetic-foreign-owned-replacement","failed cleanup retains replacement not owned by attempt")
            let cancelledDB=try fresh("cancel-at-fence");var cancelFlag=false,authCalls=0
            try reject("cancel at publication fence"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:cancelledDB,expectedManifestSHA256:manifest,authorize:{authCalls+=1;if authCalls==2{cancelFlag=true}},cancelled:{cancelFlag})}
            try check(!FileManager.default.fileExists(atPath:cancelledDB.url.deletingLastPathComponent().appendingPathComponent(NativeCredentialArchiveBinding.folder).path),"cancel joins local IO and removes own unpublished files")
            try reject("wrong import snapshot"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:failure,expectedManifestSHA256:String(repeating:"0",count:64),authorize:{})}
            try failure.transaction {try reject("outer transaction refuses IO"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:failure,expectedManifestSHA256:manifest,authorize:{})}}
            try reject("pre-cancelled preservation"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:failure,expectedManifestSHA256:manifest,authorize:{},cancelled:{true})}
            let roSource=try NativeDatabase(readOnlyURL:backup.appendingPathComponent("database.sqlite"),schemaURL:schema)
            try reject("readonly install before file IO"){_ = try NativeCredentialMigrationArchive.install(sourceRoot:input,db:roSource,expectedManifestSHA256:manifest,authorize:{})}
            // Damaged or missing registered archives cause a failed backup, never a
            // successful backup that silently omits encrypted original values.
            let hard=root.appendingPathComponent("owned-extra-link");try FileManager.default.linkItem(at:archiveURL,to:hard)
            try check(!NativeBackup().prepare(source:db,destinationURL:root.appendingPathComponent("hardlink-backup")).candidateCreated,"hardlink archive is refused")
            try FileManager.default.removeItem(at:hard)
            let hidden=holdURL.appendingPathExtension("synthetic-held");try FileManager.default.moveItem(at:holdURL,to:hidden)
            try check(!NativeBackup().prepare(source:db,destinationURL:root.appendingPathComponent("missing-backup")).candidateCreated,"missing held inventory fails preservation")
            try FileManager.default.createSymbolicLink(at:holdURL,withDestinationURL:hidden)
            try check(!NativeBackup().prepare(source:db,destinationURL:root.appendingPathComponent("symlink-backup")).candidateCreated,"symlink held inventory refused")
            try FileManager.default.removeItem(at:holdURL);try FileManager.default.moveItem(at:hidden,to:holdURL)
            let destinationCipher=dest.appendingPathComponent(encrypted.path);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destinationCipher.path);let handle=try FileHandle(forWritingTo:destinationCipher);try handle.seek(toOffset:16);try handle.write(contentsOf:Data([0x7f]));try handle.close()
            try reject("cipher tamper blocks namespace rebind"){_ = try NativeCredentialMigrationArchive.rebind(rebound,db:target,authorize:{})}
            try check(try hash(input.appendingPathComponent("credentials.handoff"))==sourceSHA&&hash(input.appendingPathComponent("migration-holds.ndjson"))==holdSHA,"original operational files unchanged")
            print("{\"checks\":\(checks),\"encryptedEntries\":12,\"backupFiles\":2,\"realKeychain\":false,\"runtimeActivated\":false}")
        }catch{fputs("Credential archive failed after \(checks): \(type(of:error))\n",stderr);if let error=error as? NativeMigrationFailure{fputs(error.code+"\n",stderr)};exit(1)}
    }
}
