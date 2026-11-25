import Foundation
import SQLite3

/// Disposable indexes only. No NativeDatabase initializer, schema bootstrap,
/// production hooks, user DB or Keychain entry is touched.
final class NativeMigrationIndex {
    enum Value {case text(String),blob(Data),integer(Int64),null}
    private var db:OpaquePointer?;private let folder:URL
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init() throws {
        folder=FileManager.default.temporaryDirectory.appendingPathComponent("NativeMigrationPreflight-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            guard sqlite3_open_v2(folder.appendingPathComponent("index.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOMUTEX,nil)==SQLITE_OK else {throw failure}
            try exec("PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; PRAGMA mmap_size=0; PRAGMA journal_mode=DELETE; PRAGMA synchronous=OFF;")
            try exec("CREATE TABLE keys(space TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(space,value)) WITHOUT ROWID; CREATE TABLE refs(space TEXT NOT NULL,value BLOB NOT NULL,model TEXT NOT NULL,row INTEGER NOT NULL,field TEXT NOT NULL); CREATE TABLE cells(owner BLOB PRIMARY KEY NOT NULL,digest TEXT NOT NULL,shape TEXT NOT NULL) WITHOUT ROWID; CREATE TABLE needs(kind TEXT NOT NULL,owner BLOB NOT NULL,model TEXT NOT NULL,row INTEGER NOT NULL,field TEXT NOT NULL,declared INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(kind,owner)) WITHOUT ROWID; CREATE TABLE inventory(kind TEXT NOT NULL,id BLOB NOT NULL,PRIMARY KEY(kind,id)) WITHOUT ROWID;")
        } catch {if let db {sqlite3_close(db)};db=nil;try? FileManager.default.removeItem(at:folder);throw error}
    }
    deinit {if let db {sqlite3_close(db)};try? FileManager.default.removeItem(at:folder)}
    private var failure:NativeMigrationFailure {.init("index.io","検査用一時索引を作成・更新できません。空き容量を確認してください。")}
    private func exec(_ sql:String) throws {guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw failure}}
    private func statement(_ sql:String,_ args:[Value]) throws -> OpaquePointer {
        var statement:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let s=statement else {throw failure}
        do {for (i,value) in args.enumerated(){let n=Int32(i+1),result:Int32
            switch value {
            case .null:result=sqlite3_bind_null(s,n)
            case .integer(let x):result=sqlite3_bind_int64(s,n,x)
            case .text(let x):result=sqlite3_bind_text(s,n,x,-1,transient)
            case .blob(let x):result=x.withUnsafeBytes{sqlite3_bind_blob(s,n,$0.baseAddress,Int32($0.count),transient)}
            };guard result==SQLITE_OK else {throw failure}
        };return s} catch {sqlite3_finalize(s);throw error}
    }
    @discardableResult func write(_ sql:String,_ args:[Value]=[]) throws -> Int {
        let s=try statement(sql,args);defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_DONE else {throw failure};return Int(sqlite3_changes(db))
    }
    func one(_ sql:String,_ args:[Value]=[]) throws -> String? {
        let s=try statement(sql,args);defer{sqlite3_finalize(s)};let step=sqlite3_step(s);if step==SQLITE_DONE{return nil};guard step==SQLITE_ROW else {throw failure};return sqlite3_column_text(s,0).map{String(cString:$0)}
    }
    func locations(_ sql:String,cancelled:()->Bool,visit:(String,Int64,String)throws->Void) throws {
        let s=try statement(sql,[]);defer{sqlite3_finalize(s)}
        while true {if cancelled(){throw CancellationError()};let step=sqlite3_step(s);if step==SQLITE_DONE{return};guard step==SQLITE_ROW,let m=sqlite3_column_text(s,0),let f=sqlite3_column_text(s,2) else {throw failure};try visit(String(cString:m),sqlite3_column_int64(s,1),String(cString:f))}
    }
    func batch(_ body:()throws->Void) throws {try exec("BEGIN");do{try body();try exec("COMMIT")}catch{try? exec("ROLLBACK");throw error}}
    func key(_ space:String,_ value:Data) throws -> Bool {try write("INSERT OR IGNORE INTO keys VALUES(?,?)",[.text(space),.blob(value)])==1}
    func ref(_ space:String,_ value:Data,model:String,row:Int64,field:String) throws {try write("INSERT INTO refs VALUES(?,?,?,?,?)",[.text(space),.blob(value),.text(model),.integer(row),.text(field)])}
    func id(_ kind:String,_ id:String) throws -> Bool {try write("INSERT OR IGNORE INTO inventory VALUES(?,?)",[.text(kind),.blob(Data(id.utf8))])==1}
    func cell(owner:Data,digest:String,shape:String) throws {try write("INSERT OR REPLACE INTO cells VALUES(?,?,?)",[.blob(owner),.text(digest),.text(shape)])}
    func need(_ kind:String,owner:Data,model:String,row:Int64,field:String) throws {try write("INSERT OR IGNORE INTO needs(kind,owner,model,row,field) VALUES(?,?,?,?,?)",[.text(kind),.blob(owner),.text(model),.integer(row),.text(field)])}
    func declare(_ kind:String,owner:Data) throws {try write("UPDATE needs SET declared=declared+1 WHERE kind=? AND owner=?",[.text(kind),.blob(owner)])}
}
