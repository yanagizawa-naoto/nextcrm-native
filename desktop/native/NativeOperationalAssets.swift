import Foundation
import CryptoKit

/// Exact source-field binding prevents an old imported object from shadowing
/// a subsequent ordinary edit. Entries are local preparation metadata only.
enum NativeOperationalAssets {
    struct Mapping:Codable {
        let model:String,id:String,field:String,sourceSHA256:String,local:String,mime:String,bytes:Int64,sha256:String
        let avatarBinding:String?
        let contentBinding:String?
    }
    static func digest(_ value:String)->String{SHA256.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()}
    static func key(model:String,id:String,field:String)->String{"migration.asset.v1."+digest(model+"\0"+id+"\0"+field)}
    static func documentBinding(_ row:NativeRecord)->String{digest(["key","document_file_url","thumbnail_url","content_hash"].map{row[$0] == .null ? "n;":"t"+String(row[$0].string.utf8.count)+":"+row[$0].string}.joined())}
    static func avatarBinding(_ user:NativeRecord)->String {digest(["avatar","image"].map{user[$0] == .null ? "n;":"t"+String(user[$0].string.utf8.count)+":"+user[$0].string}.joined())}
    static func load(_ record:NativeRecord,field:String,db:NativeDatabase)throws->Mapping? {
        guard let raw=try db.metadata(key(model:record.model,id:record["id"].string,field:field)),raw.utf8.count<=8192 else{return nil}
        let map=try JSONDecoder().decode(Mapping.self,from:Data(raw.utf8))
        guard map.model==record.model,map.id==record["id"].string,map.field==field,map.sourceSHA256==digest(record[field].string) else{return nil}
        return map
    }
    static func localReference(_ row:NativeRecord,field:String,db:NativeDatabase)throws->String?{try load(row,field:field,db:db)?.local}
    static func avatar(_ row:NativeRecord,db:NativeDatabase)throws->String? {
        if try db.metadata("migration.avatar.cleared.v1."+row["id"].string)==avatarBinding(row){return nil}
        let field=row["avatar"].string.isEmpty ? "image":"avatar"
        guard let map=try load(row,field:field,db:db),map.avatarBinding==avatarBinding(row) else{return nil};return map.local
    }
    static func avatarReferenced(_ ref:String,db:NativeDatabase)throws->Bool {
        guard let id=try db.metadata("migration.avatar.reverse."+digest(ref)),let row=try db.get("Users",key:["id":.text(id)]) else{return false}
        return try avatar(row,db:db)==ref
    }
    static func save(_ map:Mapping,db:NativeDatabase)throws {
        let raw=String(decoding:try JSONEncoder().encode(map),as:UTF8.self)
        try db.setMetadata(key(model:map.model,id:map.id,field:map.field),value:raw)
        if map.model=="Users"{try db.setMetadata("migration.avatar.reverse."+digest(map.local),value:map.id)}
    }
}
