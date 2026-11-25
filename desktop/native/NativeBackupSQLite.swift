import Foundation
import SQLite3

final class NativeBackupSQLite {
    let connection:OpaquePointer
    private var closed=false
    private final class Cancellation {let check:()->Bool;init(_ check:@escaping()->Bool){self.check=check}}
    private let cancellation:Cancellation
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    enum Value {case null,text(String),integer(Int64)}
    init(path:String,readOnly:Bool,descriptor:Bool=false,immutable:Bool=false,cancelled:@escaping()->Bool={false})throws {
        cancellation=Cancellation(cancelled)
        var pointer:OpaquePointer?
        let flags=(readOnly ? SQLITE_OPEN_READONLY:SQLITE_OPEN_READWRITE)|SQLITE_OPEN_NOMUTEX|SQLITE_OPEN_PRIVATECACHE|(descriptor ? 0:SQLITE_OPEN_NOFOLLOW)|(immutable ? SQLITE_OPEN_URI:0)
        let openedPath=immutable ? "file:"+path+"?immutable=1":path
        let code=sqlite3_open_v2(openedPath,&pointer,flags,nil)
        guard code==SQLITE_OK,let pointer else {if let pointer{sqlite3_close(pointer)};throw NativeMigrationFailure("backup.sqlite_open","snapshot用DBを開けません。")}
        connection=pointer
        sqlite3_progress_handler(pointer,1000,{opaque in
            guard let opaque else{return 0}
            return Unmanaged<Cancellation>.fromOpaque(opaque).takeUnretainedValue().check() ? 1:0
        },Unmanaged.passUnretained(cancellation).toOpaque())
        do {
            guard sqlite3_create_collation_v2(pointer,"native_decimal",SQLITE_UTF8,nil,{_,ac,a,bc,b in NativeDecimalOrder.compare(UnsafeRawBufferPointer(start:a,count:Int(ac)),UnsafeRawBufferPointer(start:b,count:Int(bc)))},nil)==SQLITE_OK,
                  sqlite3_create_collation_v2(pointer,"native_japanese",SQLITE_UTF8,nil,{_,ac,a,bc,b in
                    let lhs=String(decoding:UnsafeRawBufferPointer(start:a,count:Int(ac)),as:UTF8.self),rhs=String(decoding:UnsafeRawBufferPointer(start:b,count:Int(bc)),as:UTF8.self)
                    return Int32(lhs.compare(rhs,options:.caseInsensitive,locale:Locale(identifier:"ja_JP")).rawValue)
                  },nil)==SQLITE_OK,
                  sqlite3_create_collation_v2(pointer,"native_email",SQLITE_UTF8,nil,{_,ac,a,bc,b in
                    let lhs=String(decoding:UnsafeRawBufferPointer(start:a,count:Int(ac)),as:UTF8.self).lowercased(),rhs=String(decoding:UnsafeRawBufferPointer(start:b,count:Int(bc)),as:UTF8.self).lowercased()
                    return lhs==rhs ? 0:lhs<rhs ? -1:1
                  },nil)==SQLITE_OK else {throw failure}
            sqlite3_busy_timeout(pointer,250)
            try exec("PRAGMA cache_size=-1024; PRAGMA mmap_size=0; PRAGMA temp_store=FILE;")
            if !readOnly {try exec("PRAGMA journal_mode=MEMORY; PRAGMA synchronous=FULL;")}
        } catch {sqlite3_close(pointer);closed=true;throw error}
    }
    deinit{if !closed{sqlite3_progress_handler(connection,0,nil,nil);sqlite3_close(connection)}}
    private var failure:Error {
        if cancellation.check(){return CancellationError()}
        return NativeMigrationFailure("backup.sqlite","snapshot DBの読書き・整合性を確認できません（SQLite \(sqlite3_extended_errcode(connection))）。")
    }
    func exec(_ sql:String)throws {guard sqlite3_exec(connection,sql,nil,nil,nil)==SQLITE_OK else {throw failure}}
    private func statement(_ sql:String,_ values:[Value])throws->OpaquePointer {
        var s:OpaquePointer?;guard sqlite3_prepare_v2(connection,sql,-1,&s,nil)==SQLITE_OK,let s else {throw failure}
        do{for (i,v) in values.enumerated(){let n=Int32(i+1),code:Int32;switch v{case .null:code=sqlite3_bind_null(s,n);case .integer(let x):code=sqlite3_bind_int64(s,n,x);case .text(let x):code=sqlite3_bind_text(s,n,x,-1,transient)};guard code==SQLITE_OK else {throw failure}};return s}catch{sqlite3_finalize(s);throw error}
    }
    func rows(_ sql:String,_ values:[Value]=[],cancelled:()->Bool={false},visit:([String:String?])throws->Void)throws {
        let s=try statement(sql,values);defer{sqlite3_finalize(s)}
        while true {if cancelled(){throw CancellationError()};let code=sqlite3_step(s);if code==SQLITE_DONE{return};guard code==SQLITE_ROW else {throw failure}
            try autoreleasepool{var row:[String:String?]=[:];for i in 0..<sqlite3_column_count(s){let name=String(cString:sqlite3_column_name(s,i));row[name] = .some(sqlite3_column_type(s,i)==SQLITE_NULL ? nil:sqlite3_column_text(s,i).map{String(cString:$0)})};try visit(row)}
        }
    }
    func first(_ sql:String,_ values:[Value]=[])throws->String? {let s=try statement(sql,values);defer{sqlite3_finalize(s)};let code=sqlite3_step(s);if code==SQLITE_DONE{return nil};guard code==SQLITE_ROW else {throw failure};return sqlite3_column_text(s,0).map{String(cString:$0)}}
    func write(_ sql:String,_ values:[Value]=[])throws {let s=try statement(sql,values);defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_DONE else {throw failure}}
    func exists(_ table:String)throws->Bool {try first("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",[.text(table)]) != nil}
    static func quote(_ value:String)->String {"\""+value.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
    func backup(to destination:NativeBackupSQLite,cancelled:()->Bool,progress:()throws->Void)throws {
        guard let copy=sqlite3_backup_init(destination.connection,"main",connection,"main") else {throw failure}
        var finished=false;defer{if !finished{sqlite3_backup_finish(copy)}}
        var busy=0
        while true {
            if cancelled(){throw CancellationError()};try progress()
            let code=sqlite3_backup_step(copy,128)
            if code==SQLITE_DONE{break}
            if code==SQLITE_BUSY || code==SQLITE_LOCKED {busy+=1;guard busy<100 else {throw NativeMigrationFailure("backup.busy","snapshot DBのコピー待ちが上限を超えました。")};Thread.sleep(forTimeInterval:0.01);continue}
            guard code==SQLITE_OK else {throw failure};busy=0
        }
        let code=sqlite3_backup_finish(copy);finished=true;guard code==SQLITE_OK else {throw failure}
    }
}
