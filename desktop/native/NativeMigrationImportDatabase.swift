import Foundation
import SQLite3
import Darwin

final class NativeMigrationImportDatabase {
    private var db:OpaquePointer?;private let descriptor:Int32
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init(descriptor:Int32,sql:String)throws {
        self.descriptor=descriptor
        guard sqlite3_open_v2("/dev/fd/\(descriptor)",&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOMUTEX|SQLITE_OPEN_PRIVATECACHE,nil)==SQLITE_OK else {if let db{sqlite3_close(db)};db=nil;throw failure}
        do {
            try exec("PRAGMA journal_mode=MEMORY; PRAGMA synchronous=FULL; PRAGMA cache_size=-1024; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA foreign_keys=ON;")
            try exec(sql)
            try exec("CREATE TABLE _migration_assets(id TEXT PRIMARY KEY NOT NULL,sha256 TEXT NOT NULL,local_path TEXT,descriptor_json TEXT NOT NULL); CREATE INDEX _migration_assets_hash ON _migration_assets(sha256);")
            guard try one("PRAGMA journal_mode") == .text(Data("memory".utf8)),case let .integer(pages)?=try one("PRAGMA page_count"),case let .integer(size)?=try one("PRAGMA page_size"),pages>0,size>0,pages<=16*1024*1024/size else {throw NativeMigrationFailure("candidate.journal_limit","新規schemaのjournal容量が検査上限を超えています。")}
            // A new, empty schema is the entire pre-transaction database.
            // MEMORY journal can hold its original pages only; subsequently
            // allocated data pages have no before-image and are not journalled.
            try exec("BEGIN; PRAGMA defer_foreign_keys=ON;")
        } catch {sqlite3_close(db);db=nil;throw error}
    }
    deinit {if let db{sqlite3_close(db)}}
    private var failure:NativeMigrationFailure {.init("candidate.sqlite","候補DBの制約・読書きに失敗しました。候補全体を回収します。")}
    func exec(_ sql:String)throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw failure}}
    static func quote(_ s:String)->String {"\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
    private func prepare(_ sql:String,_ values:[NativeMigrationImportValue])throws->OpaquePointer {
        var pointer:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&pointer,nil)==SQLITE_OK,let s=pointer else {throw failure}
        do {for (i,value) in values.enumerated(){let n=Int32(i+1),code:Int32
            switch value {
            case .null:code=sqlite3_bind_null(s,n)
            case .integer(let value):code=sqlite3_bind_int64(s,n,value)
            case .real(let value):code=sqlite3_bind_double(s,n,value)
            case .text(let value):let terminated=value+Data([0]);code=terminated.withUnsafeBytes{sqlite3_bind_text(s,n,$0.baseAddress!.assumingMemoryBound(to:CChar.self),Int32(value.count),transient)}
            case .blob(let value):code=value.isEmpty ? sqlite3_bind_zeroblob(s,n,0):value.withUnsafeBytes{sqlite3_bind_blob(s,n,$0.baseAddress,Int32($0.count),transient)}
            };guard code==SQLITE_OK else {throw failure}
        };return s} catch {sqlite3_finalize(s);throw error}
    }
    private func read(_ s:OpaquePointer,_ column:Int32)->NativeMigrationImportValue {
        switch sqlite3_column_type(s,column) {
        case SQLITE_NULL:return .null
        case SQLITE_INTEGER:return .integer(sqlite3_column_int64(s,column))
        case SQLITE_FLOAT:return .real(sqlite3_column_double(s,column))
        case SQLITE_BLOB:let size=Int(sqlite3_column_bytes(s,column));return .blob(size==0 ? Data():Data(bytes:sqlite3_column_blob(s,column)!,count:size))
        default:let size=Int(sqlite3_column_bytes(s,column));return .text(size==0 ? Data():Data(bytes:sqlite3_column_text(s,column)!,count:size))
        }
    }
    func row(model:NativeMigrationSchema.Model,values:[NativeMigrationImportValue])throws {
        let columns=model.fields.map{Self.quote($0.column)}.joined(separator:","),names=Self.quote(model.name)
        let insert=try prepare("INSERT INTO \(names)(\(columns)) VALUES(\(values.map{_ in "?"}.joined(separator:",")))",values);defer{sqlite3_finalize(insert)}
        guard sqlite3_step(insert)==SQLITE_DONE else {throw failure}
        let keys=model.primaryKey.map{name in model.fields.firstIndex(where:{$0.name==name})!}
        let predicate=keys.map{Self.quote(model.fields[$0].column)+"=?"}.joined(separator:" AND ")
        let select=try prepare("SELECT \(columns) FROM \(names) WHERE \(predicate)",keys.map{values[$0]});defer{sqlite3_finalize(select)}
        guard sqlite3_step(select)==SQLITE_ROW else {throw failure}
        for (i,value) in values.enumerated(){guard read(select,Int32(i))==value else {throw NativeMigrationFailure("candidate.readback","候補DBのscalar値が入力と一致しません。")}}
        guard sqlite3_step(select)==SQLITE_DONE else {throw failure}
    }
    func one(_ sql:String,_ values:[NativeMigrationImportValue]=[])throws->NativeMigrationImportValue? {
        let s=try prepare(sql,values);defer{sqlite3_finalize(s)};let next=sqlite3_step(s);if next==SQLITE_DONE{return nil};guard next==SQLITE_ROW else {throw failure};return read(s,0)
    }
    func asset(id:String,hash:String,path:String?,raw:Data)throws {
        let s=try prepare("INSERT INTO _migration_assets VALUES(?,?,?,?)",[.text(Data(id.utf8)),.text(Data(hash.utf8)),path.map{.text(Data($0.utf8))} ?? .null,.text(raw)]);defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_DONE else {throw failure}
    }
    func finish()throws {
        guard try one("PRAGMA foreign_key_check")==nil else {throw NativeMigrationFailure("candidate.foreign_key","候補DBに参照整合性エラーがあります。")}
        try exec("COMMIT")
        guard try one("PRAGMA integrity_check") == .text(Data("ok".utf8)) else {throw NativeMigrationFailure("candidate.integrity","候補DBの整合性検査に失敗しました。")}
        guard try one("PRAGMA journal_mode=DELETE") == .text(Data("delete".utf8)) else {throw failure}
        guard sqlite3_close(db)==SQLITE_OK else {throw failure};db=nil
        guard fsync(descriptor)==0 else {throw failure}
    }
}
