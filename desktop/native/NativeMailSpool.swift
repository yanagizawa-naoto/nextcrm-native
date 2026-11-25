import Foundation
import SQLite3
import Darwin

/// UID SEARCH may return millions of identifiers in one physical line. Parse
/// it incrementally and let a disk index sort/deduplicate; fetch only 50 at a
/// time. No CRM cursor is published from an incomplete or malformed response.
final class NativeMailUIDSpool {
    private let ownership: NativeMailTemporaryFiles.Lease
    private var database: OpaquePointer?
    init(response: NativeMailResponseFile,after: UInt32,through: UInt32,temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        guard through >= after else { throw NativeMailFailure.malformed }
        ownership = try NativeMailTemporaryFiles.create(.uids,base:temporaryRoot)
        let file = ownership.url
        guard sqlite3_open_v2(file.path,&database,SQLITE_OPEN_READWRITE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw NativeMailResponseFile.fileError
        }
        do {
            try execute("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-256; PRAGMA mmap_size=0; PRAGMA temp_store=FILE; CREATE TABLE uids(uid INTEGER PRIMARY KEY NOT NULL)")
            try execute("BEGIN")
            let statement = try prepare("INSERT OR IGNORE INTO uids(uid) VALUES(?)")
            defer { sqlite3_finalize(statement) }
            try response.withDescriptor { fd in
                guard lseek(fd,0,SEEK_SET) == 0 else { throw NativeMailResponseFile.fileError }
                let input = NativeMailUIDReader(fd:fd)
                try input.parse { uid in
                    guard uid > after, uid <= through else { return }
                    guard sqlite3_bind_int64(statement,1,Int64(uid)) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw NativeMailResponseFile.fileError }
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                }
            }
            try execute("COMMIT")
        } catch {
            // This is a disposable staging DB. Incomplete rows are never
            // returned, even with journaling disabled for the temporary file.
            if let database { sqlite3_close_v2(database) }; database = nil
            throw error
        }
    }
    deinit { if let database { sqlite3_close_v2(database) } } // ownership releases after SQLite closes.
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database,sql,nil,nil,nil) == SQLITE_OK else { throw NativeMailResponseFile.fileError }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw NativeMailResponseFile.fileError }
        return statement
    }
    func page(after: UInt32,limit: Int = 50) throws -> [UInt32] {
        guard (1...50).contains(limit) else { throw NativeMailFailure.malformed }
        let statement = try prepare("SELECT uid FROM uids WHERE uid > ? ORDER BY uid LIMIT ?")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement,1,Int64(after)) == SQLITE_OK, sqlite3_bind_int(statement,2,Int32(limit)) == SQLITE_OK else { throw NativeMailResponseFile.fileError }
        var result:[UInt32] = []
        while true {
            let code = sqlite3_step(statement); if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let uid = UInt32(exactly:sqlite3_column_int64(statement,0)), uid > 0 else { throw NativeMailResponseFile.fileError }
            result.append(uid)
        }
    }
}

private final class NativeMailUIDReader {
    let fd: Int32
    private var buffer = [UInt8](repeating:0,count:16_384)
    private var position = 0, end = 0, bytesRead = 0
    init(fd: Int32) { self.fd = fd }
    private func peek() throws -> UInt8? {
        if position == end {
            try Task.checkCancellation()
            var count: Int
            repeat { count = buffer.withUnsafeMutableBytes { read(fd,$0.baseAddress,$0.count) } } while count < 0 && errno == EINTR
            guard count >= 0 else { throw NativeMailResponseFile.fileError }
            if count == 0 { return nil }
            bytesRead += count
            guard bytesRead <= 268_435_456 else { throw NativeMailFailure.tooLarge }
            position = 0; end = count
        }
        return buffer[position]
    }
    private func take() throws -> UInt8 {
        guard let byte = try peek() else { throw NativeMailFailure.malformed }
        position += 1; return byte
    }
    private func spaces() throws { while let byte = try peek(), byte == 32 || byte == 9 { position += 1 } }
    private func atom(limit: Int = 128) throws -> String {
        var bytes:[UInt8] = []
        while let byte = try peek(), ![9,10,13,32].contains(byte) {
            guard byte >= 33, byte <= 126, bytes.count < limit else { throw NativeMailFailure.malformed }
            bytes.append(byte); position += 1
        }
        guard !bytes.isEmpty else { throw NativeMailFailure.malformed }
        return String(decoding:bytes,as:UTF8.self)
    }
    private func endLine() throws {
        guard try take() == 13, try take() == 10 else { throw NativeMailFailure.malformed }
    }
    private func skip(_ length: Int) throws {
        var remaining = length
        while remaining > 0 {
            guard try peek() != nil else { throw NativeMailFailure.malformed }
            let count = min(remaining,end-position); position += count; remaining -= count
        }
    }
    private func skipResponse(literals: Bool) throws {
        var quoted = false, escaped = false
        var literal:[UInt8]? = nil
        while true {
            let byte = try take()
            if byte == 13 {
                guard try take() == 10, !quoted else { throw NativeMailFailure.malformed }
                if literals, var suffix = literal, suffix.last == 125 {
                    suffix.removeLast(); if suffix.last == 43 { suffix.removeLast() }
                    guard !suffix.isEmpty, suffix.allSatisfy({(48...57).contains($0)}), let length = Int(String(decoding:suffix,as:UTF8.self)), length <= 268_435_456 else { throw NativeMailFailure.malformed }
                    try skip(length); literal = nil; continue
                }
                return
            }
            guard byte != 10, byte != 0 else { throw NativeMailFailure.malformed }
            if escaped { escaped = false; continue }
            if quoted && byte == 92 { escaped = true; continue }
            if byte == 34 { quoted.toggle(); literal = nil; continue }
            if literals && !quoted && byte == 123 { literal = []; continue }
            if literal != nil {
                if literal!.count < 12 && ((48...57).contains(byte) || byte == 43 || byte == 125) { literal!.append(byte) }
                else { literal = nil }
            }
        }
    }
    func parse(_ accept: (UInt32) throws -> Void) throws {
        var found = false, completed = false
        while try peek() != nil {
            guard !completed else { throw NativeMailFailure.malformed }
            let first = try atom(); try spaces(); let second = try atom().uppercased()
            if first == "*" && second == "SEARCH" {
                guard !found else { throw NativeMailFailure.malformed }; found = true
                while true {
                    try spaces()
                    if try peek() == 13 { try endLine(); break }
                    let raw = try atom(limit:10)
                    guard raw.utf8.allSatisfy({(48...57).contains($0)}), let uid = UInt32(raw), uid > 0 else { throw NativeMailFailure.malformed }
                    try accept(uid)
                }
            } else {
                var literals = first == "*" && ["LIST","STATUS"].contains(second)
                if first == "*", UInt32(second) != nil { try spaces(); literals = try atom().uppercased() == "FETCH" }
                try skipResponse(literals:literals)
                if first == "NCRM2" { guard second == "OK" else { throw NativeMailFailure.malformed }; completed = true }
            }
        }
        guard found, completed else { throw NativeMailFailure.malformed }
    }
}
