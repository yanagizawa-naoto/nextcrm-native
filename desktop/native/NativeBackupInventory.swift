import Foundation

struct NativeBackupInventory {
    let source:NativeBackupSQLite,index:NativeBackupSQLite,workspace:NativeBackupWorkspace
    let cancelled:()->Bool,progress:()throws->Void
    var forceCopy=false
    func pinAll(result:inout NativeBackupResult)throws {
        func pending(_ value:NativeBackupPending){if !result.pending.contains(value){result.pending.append(value)}}
        func record(_ path:String?,_ size:String?,_ hash:String?)throws {
            guard let path,!path.isEmpty else {return}
            guard ["native-documents/","native-avatars/","invoice-pdfs/","mail-outbox/","native-credential-archives/"].contains(where:{path.hasPrefix($0)}) else {pending(.externalFiles);return}
            let bytes=size.flatMap(Int64.init),sha=hash.flatMap{$0.isEmpty ? nil:$0}
            guard size==nil || (bytes != nil && bytes!>=0),sha.map(NativeMigrationCodec.validHash) ?? true else {throw NativeMigrationFailure("backup.metadata","公開ファイルのサイズ・hash metadataが不正です。")}
            if try index.first("SELECT 1 FROM files WHERE path=?",[.text(path)]) != nil {
                if let bytes,try index.first("SELECT bytes FROM files WHERE path=?",[.text(path)]) != String(bytes) {throw NativeMigrationFailure("backup.metadata","同じファイルのサイズ参照が一致しません。")}
                if let sha {
                    if let previous=try index.first("SELECT expected_hash FROM files WHERE path=?",[.text(path)]),previous != sha {throw NativeMigrationFailure("backup.metadata","同じファイルのhash参照が一致しません。")}
                    try index.write("UPDATE files SET expected_hash=? WHERE path=?",[.text(sha),.text(path)])
                }
                return
            }
            if cancelled(){throw CancellationError()};try progress()
            let pin=try workspace.pin(path,expectedBytes:bytes,expectedSHA:sha,forceCopy:forceCopy,cancelled:cancelled,progress:progress)
            try index.write("INSERT INTO files(path,pin,signature,bytes,expected_hash) VALUES(?,?,?,?,?)",[.text(path),.text(pin.name),.text(pin.signature),.integer(pin.bytes),sha.map(NativeBackupSQLite.Value.text) ?? .null])
            result.fileCount+=1
            if pin.linked {result.pinnedByLink+=1} else if pin.cloned {result.pinnedByClone+=1} else {result.copiedUnderFence+=1;pending(.fileCopyPause)}
        }
        if try source.exists("native_metadata") {
            try source.rows("SELECT key,CASE WHEN length(CAST(value AS BLOB))<=65536 THEN value ELSE NULL END value FROM native_metadata WHERE key LIKE 'migration.credentials.archive.v1.%' ORDER BY key",cancelled:cancelled){row in
                guard let key=row["key"] ?? nil,let raw=row["value"] ?? nil else{throw NativeMigrationFiles.io}
                let binding=try NativeCredentialArchiveBinding.decode(raw,key:key)
                guard try source.first("SELECT value FROM native_metadata WHERE key='schemaSHA256'")==binding.schemaSHA256,
                      try source.first("SELECT value FROM native_metadata WHERE key='migration.operational.manifest'")==binding.importManifestSHA256 else{throw NativeMigrationFailure("backup.credential_binding","暗号化保全情報と取込元snapshotが一致しません。")}
                for file in binding.files {try record(file.path,String(file.bytes),file.sha256)}
            }
        }
        let operational=NativeBackupOperationalAssets(source:source)
        if try source.exists("native_document_objects") {
            try source.rows("SELECT file_key path,bytes,sha256 hash FROM native_document_objects",cancelled:cancelled){row in
                guard let hash=row["hash"] ?? nil,NativeMigrationCodec.validHash(hash),let bytes=(row["bytes"] ?? nil).flatMap(Int64.init),bytes>=0 else {throw NativeMigrationFailure("backup.metadata","文書mappingの公開サイズ・hashが不正です。")}
                try record(row["path"] ?? nil,String(bytes),hash)
            }
        }
        if try source.exists("Documents") {
            let mapping=try source.exists("native_document_objects") && source.exists("native_metadata")
            let gate=mapping ? " AND NOT EXISTS(SELECT 1 FROM native_document_objects o WHERE o.object_key=d.key AND o.bucket=(SELECT value FROM native_metadata WHERE key='document.storage.bucket'))":""
            try source.rows("SELECT key path,size bytes,content_hash hash FROM Documents d WHERE key IS NOT NULL\(gate)",cancelled:cancelled){row in
                let path=row["path"] ?? nil
                if path?.hasPrefix("native-documents/")==true {if (row["hash"] ?? nil)?.isEmpty != false {pending(.sourceMetadata)};try record(path,row["bytes"] ?? nil,row["hash"] ?? nil)}
                else if path?.isEmpty==false {pending(.externalFiles)}
            }
        }
        for (table,field) in [("Invoices","pdfStorageKey"),("Invoice_Attachments","storageKey")] where try source.exists(table) {
            let size=table=="Invoice_Attachments" ? "size":"NULL"
            try source.rows("SELECT id,\(NativeBackupSQLite.quote(field)) path, \(size) bytes FROM \(NativeBackupSQLite.quote(table)) WHERE \(NativeBackupSQLite.quote(field)) IS NOT NULL",cancelled:cancelled){row in
                if let id=row["id"] ?? nil,let map=try operational.mapping(model:table,id:id,field:field,value:row["path"] ?? nil) {
                    try record(map.local,String(map.bytes),map.sha256)
                } else {try record(row["path"] ?? nil,row["bytes"] ?? nil,nil)}
            }
        }
        if try source.exists("ImageUpload"),try source.first("SELECT 1 FROM ImageUpload LIMIT 1") != nil {pending(.externalFiles)}
        if try source.exists("Documents") {
            try source.rows("SELECT key,document_file_url,thumbnail_url FROM Documents",cancelled:cancelled){row in
                for field in ["document_file_url","thumbnail_url"] {
                    if let value=row[field] ?? nil,!value.isEmpty {
                        if value != "nextcrm-local://"+((row["key"] ?? nil) ?? "") {pending(.externalFiles)}
                    }
                }
            }
        }
        if try source.exists("Users") {
            try source.rows("SELECT id,avatar,image FROM Users WHERE avatar IS NOT NULL OR image IS NOT NULL",cancelled:cancelled){row in
                let avatar=row["avatar"] ?? nil,image=row["image"] ?? nil,id=(row["id"] ?? nil) ?? ""
                let mappedAvatar=try operational.avatar(modelID:id,field:"avatar",avatar:avatar,image:image)
                let mappedImage=try operational.avatar(modelID:id,field:"image",avatar:avatar,image:image)
                if let mappedAvatar {try operational.pinAvatar(mappedAvatar,workspace:workspace,record:record)}
                else if let avatar,avatar.hasPrefix("native-avatar:v1:") {
                    let thumbnail="native-avatars/"+avatar.dropFirst("native-avatar:v1:".count)
                    try record(thumbnail,nil,nil)
                    if let original=try workspace.originalAvatar(for:thumbnail){try record(original,nil,nil)}else{pending(.avatarOriginal)}
                }
                else if avatar?.isEmpty==false {pending(.externalFiles)}
                if let mappedImage {try operational.pinAvatar(mappedImage,workspace:workspace,record:record)}
                else if let image,!image.isEmpty {pending(.externalFiles)}
            }
        }
        if try source.exists("native_outbox") {
            let invalid=Int64(try source.first("SELECT COUNT(*) FROM native_outbox WHERE NOT json_valid(payload) OR (result IS NOT NULL AND NOT json_valid(result))") ?? "0") ?? 0
            if invalid>0 {pending(.sourceMetadata)}
            let payload="CASE WHEN json_valid(payload) THEN payload ELSE '{}' END",stored="CASE WHEN json_valid(result) THEN result ELSE '{}' END"
            let hash="COALESCE(json_extract(\(stored),'$.sha256'),json_extract(\(payload),'$.sha256'))",bytes="COALESCE(json_extract(\(stored),'$.bytes'),json_extract(\(payload),'$.bytes'))"
            // A skipped campaign send is resumable with the same job identity and
            // frozen body. It is done only for this dispatch generation; unlike
            // accepted/reviewed/cancelled mail, its body is still a live reference.
            let resumableCampaign="event='campaigns/send-step' AND status='done' AND json_extract(\(stored),'$.outcome')='skipped'"
            try source.rows("SELECT id,\(hash) hash,\(bytes) bytes FROM native_outbox WHERE (status NOT IN ('done','cancelled') OR (\(resumableCampaign))) AND (\(hash) IS NOT NULL OR \(bytes) IS NOT NULL)",cancelled:cancelled){row in
                guard let id=row["id"] ?? nil,let uuid=UUID(uuidString:id),uuid.uuidString.lowercased()==id,let hash=row["hash"] ?? nil,NativeMigrationCodec.validHash(hash),let bytes=row["bytes"] ?? nil,let count=Int64(bytes),count>=0 else {throw NativeMigrationFailure("backup.mail_metadata","保存メールの公開metadataが不正です。")}
                try record("mail-outbox/"+id+".json",bytes,hash)
            }
        }
    }
}
