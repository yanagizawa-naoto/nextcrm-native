import Foundation
import SQLite3

/// Provider pages are staged on disk before CRM changes. A failed download or
/// expired cursor cannot leave records from an abandoned response in the CRM.
final class GoogleCalendarSpool {
    let directory: URL
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    private let ownership: NativeMailTemporaryFiles.Lease
    init(temporaryRoot:URL=FileManager.default.temporaryDirectory) throws {
        ownership=try NativeMailTemporaryFiles.create(.response,base:temporaryRoot)
        directory=ownership.url.deletingLastPathComponent()
        guard sqlite3_open_v2(ownership.url.path,&handle,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK else {
            if let handle{sqlite3_close(handle)};handle=nil;throw Self.error
        }
        do {try exec("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-256; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; CREATE TABLE events(position INTEGER PRIMARY KEY,payload BLOB NOT NULL); CREATE TABLE pages(token TEXT PRIMARY KEY NOT NULL)")}
        catch {sqlite3_close(handle);handle=nil;throw error}
    }
    deinit {if let handle{sqlite3_close_v2(handle)}} // Lease cleanup follows SQLite close.
    static var error: NativeDBError { .message("カレンダーの同期用作業ファイルを処理できません。空き容量を確認してください。") }
    private func exec(_ sql: String) throws { guard sqlite3_exec(handle,sql,nil,nil,nil) == SQLITE_OK else { throw Self.error } }
    private func statement(_ sql: String) throws -> OpaquePointer { var s: OpaquePointer?; guard sqlite3_prepare_v2(handle,sql,-1,&s,nil) == SQLITE_OK, let s else { throw Self.error }; return s }
    func reset() throws { try exec("DELETE FROM events; DELETE FROM pages") }
    func remember(_ token: String) throws {
        let s = try statement("INSERT OR IGNORE INTO pages(token) VALUES(?)"); defer{sqlite3_finalize(s)}
        guard sqlite3_bind_text(s,1,token,-1,transient) == SQLITE_OK, sqlite3_step(s) == SQLITE_DONE else { throw Self.error }
        guard sqlite3_changes(handle) == 1 else { throw NativeDBError.message("Googleから同じページが繰り返し返されました。同期をやり直してください。") }
    }
    private func appendEvent(_ event:[String:Any])throws {
        try Task.checkCancellation()
        let data=Data(try NativeCalendarEvents.json(event).utf8),s=try statement("INSERT INTO events(payload) VALUES(?)");defer{sqlite3_finalize(s)}
        let bound=data.withUnsafeBytes{sqlite3_bind_blob64(s,1,$0.baseAddress,UInt64(data.count),transient)}
        guard bound==SQLITE_OK,sqlite3_step(s)==SQLITE_DONE else{throw Self.error}
    }
    func append(_ events:[[String:Any]])throws {
        try exec("BEGIN")
        do {for event in events{try autoreleasepool{try appendEvent(event)}};try exec("COMMIT")}
        catch {try? exec("ROLLBACK");throw error}
    }
    /// One completed provider page is staged atomically. Duplicate items keys
    /// replace only this page's staged entries, matching JSON last-key semantics.
    func appendPage(_ response:NativeCalendarResponse)throws->[String:Any] {
        try exec("BEGIN")
        do {
            let s=try statement("SELECT COALESCE(MAX(position),0) FROM events");defer{sqlite3_finalize(s)}
            guard sqlite3_step(s)==SQLITE_ROW else{throw Self.error};let previous=sqlite3_column_int64(s,0)
            let fields=try response.project(array:"items",metadata:["nextPageToken","nextSyncToken","error"],maximumItems:250,begin:{
                let clear=try self.statement("DELETE FROM events WHERE position>?");defer{sqlite3_finalize(clear)}
                sqlite3_bind_int64(clear,1,previous);guard sqlite3_step(clear)==SQLITE_DONE else{throw Self.error}
            },element:{data in
                guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw NativeCalendarResponse.invalid}
                try self.appendEvent(event)
            })
            _ = try GoogleCalendarOAuth.json(JSONSerialization.data(withJSONObject:fields),response:response.response,maximumBytes:Int.max)
            try exec("COMMIT");return fields
        } catch {
            try? exec("ROLLBACK")
            if error is CancellationError || Task.isCancelled{throw CancellationError()}
            if let http=error as? GoogleCalendarHTTPError{throw http}
            // A provider HTTP failure may legitimately contain HTML or broken
            // JSON. Preserve status-based retry/revocation classification.
            if !(200...299).contains(response.response.statusCode) {
                _ = try GoogleCalendarOAuth.json(Data("{}".utf8),response:response.response)
            }
            throw error
        }
    }
    func forEach(_ body: (Data) throws -> Void) throws {
        let s = try statement("SELECT payload FROM events ORDER BY position"); defer{sqlite3_finalize(s)}
        while true {
            let code = sqlite3_step(s); if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_blob(s,0) else { throw Self.error }
            try autoreleasepool { try body(Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,0)))) }
        }
    }
}
