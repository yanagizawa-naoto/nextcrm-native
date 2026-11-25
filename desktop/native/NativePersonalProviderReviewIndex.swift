import Foundation
import SQLite3

/// SQLite's empty-name temporary database is private to this connection and
/// automatically removed on close. No named application file/schema is created.
final class NativePersonalProviderReviewIndex {
    #if PERSONAL_PROVIDER_REVIEW_TESTING
    static var didReadRowForTesting:(()->Void)?
    private static let liveLock=NSLock()
    private static var liveCount=0
    static var liveForTesting:Int{liveLock.lock();defer{liveLock.unlock()};return liveCount}
    #endif
    private let db:OpaquePointer
    private let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init()throws {
        var value:OpaquePointer?
        let code=sqlite3_open_v2("",&value,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOMUTEX|SQLITE_OPEN_PRIVATECACHE,nil)
        guard code==SQLITE_OK,let value else{if let value{sqlite3_close(value)};throw NativeDBError.message("確認一覧の一時領域を開けませんでした。")};db=value
        do{try exec("PRAGMA cache_size=-256; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; PRAGMA cache_spill=ON; PRAGMA journal_mode=MEMORY; CREATE TABLE entries(position INTEGER PRIMARY KEY,id TEXT NOT NULL UNIQUE,event TEXT NOT NULL,state TEXT NOT NULL,sha TEXT NOT NULL);")}
        catch{sqlite3_close(db);throw error}
        #if PERSONAL_PROVIDER_REVIEW_TESTING
        Self.liveLock.lock();Self.liveCount+=1;Self.liveLock.unlock()
        #endif
    }
    deinit{
        sqlite3_close(db)
        #if PERSONAL_PROVIDER_REVIEW_TESTING
        Self.liveLock.lock();Self.liveCount-=1;Self.liveLock.unlock()
        #endif
    }
    private func fail()->Error {NativeDBError.message("旧処理の確認一覧を読み込めませんでした。画面を開き直してください。")}
    private func exec(_ text:String)throws{guard sqlite3_exec(db,text,nil,nil,nil)==SQLITE_OK else{throw fail()}}
    private func statement(_ sql:String,_ values:[String]=[])throws->OpaquePointer {
        var raw:OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&raw,nil)==SQLITE_OK,let raw else{throw fail()}
        do{for(i,value) in values.enumerated(){guard sqlite3_bind_text(raw,Int32(i+1),value,-1,transient)==SQLITE_OK else{throw fail()}};return raw}catch{sqlite3_finalize(raw);throw error}
    }
    func build(_ cursor:NativeRestoreActivationPlanCursor)throws {
        try exec("BEGIN")
        do {
            var count:Int64=0
            while let(entry,hash)=try cursor.next(){
                #if PERSONAL_PROVIDER_REVIEW_TESTING
                Self.didReadRowForTesting?()
                #endif
                try Task.checkCancellation()
                guard entry.model=="native_outbox" else{continue}
                guard ["job","terminalReceipt"].contains(entry.kind) else{throw fail()}
                guard let id=entry.key,let event=entry.event,entry.count==1 else{throw fail()}
                count+=1
                let s=try statement("INSERT INTO entries VALUES(?,?,?,?,?)",[String(count),id,event,entry.state ?? "unknown",hash]);defer{sqlite3_finalize(s)}
                guard sqlite3_step(s)==SQLITE_DONE else{throw fail()}
            }
            // next()==nil is the original cursor's complete hash/count check.
            try Task.checkCancellation();try exec("COMMIT")
        }catch{try? exec("ROLLBACK");throw error}
    }
    func page(offset:Int)throws->NativePersonalProviderReview.Page {
        try Task.checkCancellation()
        let count=try statement("SELECT COUNT(*) FROM entries");defer{sqlite3_finalize(count)}
        guard sqlite3_step(count)==SQLITE_ROW else{throw fail()};let total=Int(sqlite3_column_int64(count,0))
        let s=try statement("SELECT position,id,event,state,sha FROM entries ORDER BY position LIMIT 100 OFFSET ?",[String(offset)]);defer{sqlite3_finalize(s)}
        var result:[NativePersonalProviderReview.Row]=[]
        while true{try Task.checkCancellation();let code=sqlite3_step(s);if code==SQLITE_DONE{break};guard code==SQLITE_ROW else{throw fail()}
            func text(_ n:Int32)->String{sqlite3_column_text(s,n).map{String(cString:$0)} ?? ""}
            result.append(.init(position:sqlite3_column_int64(s,0),id:text(1),event:text(2),restoredState:text(3),planSHA256:text(4)))
        };return .init(rows:result,total:total)
    }
    func contains(_ row:NativePersonalProviderReview.Row)throws->Bool {
        let s=try statement("SELECT 1 FROM entries WHERE position=? AND id=? AND event=? AND state=? AND sha=?",[String(row.position),row.id,row.event,row.restoredState,row.planSHA256]);defer{sqlite3_finalize(s)}
        return sqlite3_step(s)==SQLITE_ROW
    }
}
