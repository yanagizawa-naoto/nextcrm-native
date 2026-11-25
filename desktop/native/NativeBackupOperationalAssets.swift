import Foundation

/// A snapshot resolves imported references against the same current source
/// scalars as ordinary readers. The original rows and mapping JSON are copied
/// byte-for-byte by SQLite; this only identifies the immutable files to pin.
struct NativeBackupOperationalAssets {
    let source:NativeBackupSQLite
    func mapping(model:String,id:String,field:String,value:String?)throws->NativeOperationalAssets.Mapping? {
        guard try source.exists("native_metadata") else{return nil}
        let key=NativeOperationalAssets.key(model:model,id:id,field:field)
        var raw:String?,found=false
        try source.rows("SELECT CASE WHEN length(CAST(value AS BLOB))<=8192 THEN value END value FROM native_metadata WHERE key=?",[.text(key)],cancelled:{false}){row in found=true;raw=row["value"] ?? nil}
        guard found else{return nil}
        guard let raw,let map=try? JSONDecoder().decode(NativeOperationalAssets.Mapping.self,from:Data(raw.utf8)) else{throw NativeMigrationFailure("backup.operational_metadata","移行添付の対応表を安全に読み取れません。")}
        guard map.model==model,map.id==id,map.field==field,map.sourceSHA256==NativeOperationalAssets.digest(value ?? "") else{return nil}
        guard map.bytes>=0,NativeMigrationCodec.validHash(map.sha256) else{throw NativeMigrationFailure("backup.operational_metadata","移行添付のサイズ・hashが不正です。")}
        return map
    }
    func avatar(modelID:String,field:String,avatar:String?,image:String?)throws->NativeOperationalAssets.Mapping? {
        // This encoding is NativeOperationalAssets.avatarBinding: distinguish
        // SQL NULL from an empty value, and length-prefix the UTF-8 bytes.
        let binding=NativeOperationalAssets.digest([avatar,image].map { value in value.map{"t"+String($0.utf8.count)+":"+$0} ?? "n;" }.joined())
        if try source.first("SELECT value FROM native_metadata WHERE key=?",[.text("migration.avatar.cleared.v1."+modelID)])==binding{return nil}
        guard let map=try mapping(model:"Users",id:modelID,field:field,value:field=="avatar" ? avatar:image),map.avatarBinding==binding else{return nil}
        return map
    }
    func pinAvatar(_ map:NativeOperationalAssets.Mapping,workspace:NativeBackupWorkspace,record:(String?,String?,String?)throws->Void)throws {
        let prefix="native-avatar:v1:"
        guard map.local.hasPrefix(prefix) else{throw NativeMigrationFailure("backup.operational_metadata","移行写真の保存先が不正です。")}
        let thumbnail="native-avatars/"+map.local.dropFirst(prefix.count)
        try record(thumbnail,nil,nil)
        guard let original=try workspace.originalAvatar(for:thumbnail) else{throw NativeMigrationFailure("backup.operational_original","移行写真の元画像が見つかりません。")}
        let extensions=["image/png":"png","image/jpeg":"jpg","image/gif":"gif","image/webp":"webp"]
        guard let ext=extensions[map.mime],original==String(thumbnail.dropLast(4))+".original."+ext else{throw NativeMigrationFailure("backup.operational_original","移行写真の元画像形式が一致しません。")}
        try record(original,String(map.bytes),map.sha256)
    }
}
