import Foundation

/// Application boundary for a preserved archive. A restored old namespace or
/// held read-only workspace cannot expose originals through this entry point.
/// The converter still checks current admin/row CAS when publishing each secret.
enum NativeCredentialMigrationArchiveReader {
    static func forEach(_ binding:NativeCredentialArchiveBinding,db:NativeDatabase,key:Data,authorize:()throws->Void,body:(NativeCredentialMigrationEnvelope.Entry,Data)throws->Void)throws {
        _ = try binding.validated()
        func verify()throws {
            guard !db.isReadOnly else{throw NativeCredentialMigrationFailure.authority}
            try db.transaction {
                try authorize()
                guard binding.namespace==NativeCredentialMigrationEnvelope.hash(Data(db.url.resolvingSymlinksInPath().standardizedFileURL.path.utf8)),binding.schemaSHA256==db.schema.schemaSHA256,
                      try db.metadata("migration.operational.manifest")==binding.importManifestSHA256,let raw=try db.metadata(binding.key),try NativeCredentialArchiveBinding.decode(raw,key:binding.key)==binding else{throw NativeCredentialMigrationFailure.authority}
            }
        }
        try verify()
        let root=db.url.deletingLastPathComponent(),files=try NativeMigrationFiles(root:root)
        for file in binding.files {let measured=try files.read(file.path,maximum:file.bytes,cancelled:{Task.isCancelled}){_ in};guard measured.bytes==file.bytes,measured.sha256==file.sha256 else{throw NativeCredentialMigrationFailure.integrity}}
        let cipher=binding.files.first(where:{$0.path.hasSuffix(".handoff")})!
        let descriptor=NativeCredentialMigrationDescriptor(version:1,handoffID:binding.handoffID,path:"credentials.handoff",entries:Int(binding.entries),bytes:cipher.bytes,sha256:cipher.sha256)
        let reader=try NativeCredentialMigrationEnvelope(root:root.appendingPathComponent(NativeCredentialArchiveBinding.folder),descriptor:descriptor,key:key,schemaSHA256:binding.schemaSHA256,snapshotID:binding.snapshotID,fileName:binding.id+".handoff")
        try reader.forEach {entry,data in try verify();try body(entry,data)}
    }
}
