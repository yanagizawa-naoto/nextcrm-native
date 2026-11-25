import Foundation
import SQLite3

/// Disposable per-message part index. Text and image payloads are enumerated
/// one at a time; neither leaf count nor attachment count creates a RAM array.
final class NativeMailMIMESpool {
    struct Part { let text:String, html:Bool, root:Bool, alternative:Bool }
    private let ownership:NativeMailTemporaryFiles.Lease
    private var database:OpaquePointer?
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private(set) var hasPlain=false,hasHTML=false
    init(temporaryRoot:URL=FileManager.default.temporaryDirectory)throws {
        ownership=try NativeMailTemporaryFiles.create(.mime,base:temporaryRoot)
        guard sqlite3_open_v2(ownership.url.path,&database,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            if let database{sqlite3_close(database)};database=nil;throw NativeMailResponseFile.fileError
        }
        do {try execute("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-256; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; CREATE TABLE parts(seq INTEGER PRIMARY KEY, text TEXT NOT NULL, html INTEGER NOT NULL, root INTEGER NOT NULL, alternative INTEGER NOT NULL); CREATE TABLE images(cid TEXT PRIMARY KEY, type TEXT NOT NULL, encoding TEXT NOT NULL, payload BLOB NOT NULL, url TEXT); BEGIN")}
        catch {sqlite3_close_v2(database);database=nil;throw error}
    }
    deinit{if let database{sqlite3_close_v2(database)}}
    private func execute(_ sql:String)throws{guard sqlite3_exec(database,sql,nil,nil,nil)==SQLITE_OK else{throw NativeMailResponseFile.fileError}}
    private func prepare(_ sql:String)throws->OpaquePointer {
        var result:OpaquePointer?;guard sqlite3_prepare_v2(database,sql,-1,&result,nil)==SQLITE_OK,let result else{throw NativeMailResponseFile.fileError};return result
    }
    private func bind(_ value:String,_ statement:OpaquePointer,_ index:Int32)throws {
        let code=value.withCString{sqlite3_bind_text64(statement,index,$0,UInt64(value.utf8.count),transient,UInt8(SQLITE_UTF8))}
        guard code==SQLITE_OK else{throw NativeMailResponseFile.fileError}
    }
    private func string(_ statement:OpaquePointer,_ index:Int32)throws->String {
        let count=Int(sqlite3_column_bytes(statement,index));guard let bytes=sqlite3_column_text(statement,index) else{if count==0{return ""};throw NativeMailResponseFile.fileError}
        return String(decoding:UnsafeBufferPointer(start:bytes,count:count),as:UTF8.self)
    }
    func append(_ part:Part)throws {
        try Task.checkCancellation()
        if part.html{hasHTML=true}else{hasPlain=true}
        guard !part.text.isEmpty else{return}
        let s=try prepare("INSERT INTO parts(text,html,root,alternative) VALUES(?,?,?,?)");defer{sqlite3_finalize(s)}
        try bind(part.text,s,1);sqlite3_bind_int(s,2,part.html ? 1:0);sqlite3_bind_int(s,3,part.root ? 1:0);sqlite3_bind_int(s,4,part.alternative ? 1:0)
        guard sqlite3_step(s)==SQLITE_DONE else{throw NativeMailResponseFile.fileError}
    }
    func appendImage(cid:String,type:String,encoding:String,payload:Data)throws {
        try Task.checkCancellation();let s=try prepare("INSERT OR IGNORE INTO images(cid,type,encoding,payload) VALUES(?,?,?,?)");defer{sqlite3_finalize(s)}
        try bind(cid,s,1);try bind(type,s,2);try bind(encoding,s,3)
        let code=payload.isEmpty ? sqlite3_bind_zeroblob(s,4,0) : payload.withUnsafeBytes{sqlite3_bind_blob64(s,4,$0.baseAddress,UInt64($0.count),transient)}
        guard code==SQLITE_OK,sqlite3_step(s)==SQLITE_DONE else{throw NativeMailResponseFile.fileError}
    }
    func finish()throws{try Task.checkCancellation();try execute("COMMIT")}
    func forEach(_ body:(Part)throws->Void)throws {
        let s=try prepare("SELECT text,html,root,alternative FROM parts ORDER BY seq");defer{sqlite3_finalize(s)}
        while true {
            try Task.checkCancellation();let code=sqlite3_step(s);if code==SQLITE_DONE{return};guard code==SQLITE_ROW else{throw NativeMailResponseFile.fileError}
            try autoreleasepool{try body(.init(text:string(s,0),html:sqlite3_column_int(s,1) != 0,root:sqlite3_column_int(s,2) != 0,alternative:sqlite3_column_int(s,3) != 0))}
        }
    }
    func imageURL(cid:String,decode:(Data,String)throws->Data)throws->String? {
        try Task.checkCancellation();let s=try prepare("SELECT type,encoding,payload,url FROM images WHERE cid=?");defer{sqlite3_finalize(s)};try bind(cid,s,1)
        let code=sqlite3_step(s);if code==SQLITE_DONE{return nil};guard code==SQLITE_ROW else{throw NativeMailResponseFile.fileError}
        if sqlite3_column_type(s,3) != SQLITE_NULL{return try string(s,3)}
        let payload=sqlite3_column_blob(s,2).map{Data(bytes:$0,count:Int(sqlite3_column_bytes(s,2)))} ?? Data()
        let type=try string(s,0),encoding=try string(s,1),url="data:"+type+";base64,"+(try decode(payload,encoding)).base64EncodedString()
        let update=try prepare("UPDATE images SET url=? WHERE cid=?");defer{sqlite3_finalize(update)};try bind(url,update,1);try bind(cid,update,2)
        guard sqlite3_step(update)==SQLITE_DONE else{throw NativeMailResponseFile.fileError};return url
    }
}
