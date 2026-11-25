import Foundation
import SQLite3

/// Unsaved edits and transaction staging use a private temporary file. At most 100 rows
/// are decoded at a time; closing the editor discards them without touching business data.
final class InvoiceDraftStore {
    let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-InvoiceDraft-"+UUID().uuidString+".sqlite")
        FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600])
        guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; db = nil; try? FileManager.default.removeItem(at:url); throw NativeDBError.message("編集中の明細を保存する作業領域を開けません。") }
        do { try exec("PRAGMA journal_mode=MEMORY; PRAGMA synchronous=OFF; PRAGMA cache_size=-256; PRAGMA mmap_size=0; CREATE TABLE lines(id TEXT PRIMARY KEY NOT NULL,position INTEGER NOT NULL,json TEXT NOT NULL); CREATE INDEX line_position ON lines(position,id)") }
        catch { sqlite3_close(db); db = nil; try? FileManager.default.removeItem(at:url); throw error }
    }
    deinit { if let db { sqlite3_close_v2(db) }; try? FileManager.default.removeItem(at:url) }
    private func synchronized<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
    private var error: NativeDBError { .message("編集中の明細を処理できません："+(db.map { String(cString:sqlite3_errmsg($0)) } ?? "作業領域が閉じています。")) }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK else { throw error } }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var s: OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&s,nil) == SQLITE_OK, let s else { throw error }
        for (i,v) in values.enumerated() { guard sqlite3_bind_text(s,Int32(i+1),v,-1,transient) == SQLITE_OK else { sqlite3_finalize(s); throw error } }; return s
    }
    private func run(_ sql: String,_ values: [String] = []) throws { let s = try statement(sql,values); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_DONE else { throw error } }
    private func scalar(_ sql: String,_ values: [String] = []) throws -> Int {
        let s = try statement(sql,values); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_ROW else { throw error }; return Int(sqlite3_column_int64(s,0))
    }
    func count() throws -> Int { try synchronized { try scalar("SELECT count(*) FROM lines") } }
    func page(offset: Int = 0) throws -> [InvoiceDraftRow] {
        try synchronized {
            let s = try statement("SELECT json FROM lines ORDER BY position,id LIMIT 100 OFFSET ?",[String(max(0,offset))]); defer { sqlite3_finalize(s) }
            var rows: [InvoiceDraftRow] = []
            while true { let code = sqlite3_step(s); if code == SQLITE_DONE { return rows }; guard code == SQLITE_ROW, let bytes = sqlite3_column_text(s,0) else { throw error }; rows.append(try JSONDecoder().decode(InvoiceDraftRow.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,0))))) }
        }
    }
    @discardableResult func save(input: InvoiceLineInput, quote: InvoiceLineQuote, id: String? = nil) throws -> String {
        try synchronized {
            let key = id ?? UUID().uuidString.lowercased(); let data = try JSONEncoder().encode(InvoiceDraftRow(id:key,input:input,quote:quote)); let json = String(decoding:data,as:UTF8.self)
            if id != nil { try run("UPDATE lines SET json=? WHERE id=?",[json,key]); guard sqlite3_changes(db) == 1 else { throw NativeDBError.conflict } }
            else { try run("INSERT INTO lines VALUES(?,(SELECT COALESCE(MAX(position),-1)+1 FROM lines),?)",[key,json]) }
            return key
        }
    }
    func remove(_ id: String) throws { try synchronized { try run("DELETE FROM lines WHERE id=?",[id]); guard sqlite3_changes(db) == 1 else { throw NativeDBError.conflict } } }
    func move(_ id: String, direction: Int) throws {
        try synchronized {
            guard [-1,1].contains(direction) else { throw NativeDBError.message("移動方向が不正です。") }
            let position = try scalar("SELECT position FROM lines WHERE id=?",[id])
            let s = try statement("SELECT id,position FROM lines WHERE position \(direction < 0 ? "<" : ">") ? ORDER BY position \(direction < 0 ? "DESC" : "ASC") LIMIT 1",[String(position)]); defer { sqlite3_finalize(s) }
            let code = sqlite3_step(s); if code == SQLITE_DONE { return }; guard code == SQLITE_ROW, let ptr = sqlite3_column_text(s,0) else { throw error }
            let otherID = String(cString:ptr); let otherPosition = sqlite3_column_int64(s,1)
            try run("UPDATE lines SET position=CASE WHEN id=? THEN ? ELSE ? END WHERE id IN (?,?)",[id,String(otherPosition),String(position),id,otherID])
        }
    }
    func totals() throws -> InvoiceMath.Total {
        try synchronized {
            var offset = 0; var result = InvoiceMath.Accumulator()
            while true {
                let rows = try page(offset:offset)
                for row in rows { try autoreleasepool { try result.add(row.input.math(rate:row.quote.rate)) } }
                if rows.count < 100 { break }; offset += rows.count
            }
            return try result.total()
        }
    }
}
