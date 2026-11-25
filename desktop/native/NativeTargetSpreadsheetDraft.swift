import Foundation
import SQLite3
import Darwin

/// Caller holds this object until all accepted read/commit/export work has joined.
/// Row counts grow on disk; publication to CRM is a separate transaction.
final class NativeTargetSpreadsheetDraft {
    enum Value { case text(String), integer(Int64), null }
    let directory: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var rowCount: Int64 = 0
    private let ownsDirectory: Bool
    init(directory external: URL? = nil) throws {
        ownsDirectory = external == nil
        var pattern = Array((FileManager.default.temporaryDirectory.path + "/NextCRMTargetSpreadsheet-XXXXXX").utf8CString)
        if let external { directory = external } else {
            guard mkdtemp(&pattern) != nil else { throw NativeTargetSpreadsheetFailure(message: "読み込み用の作業場所を作成できません。") }
            directory = URL(fileURLWithPath: String(cString: pattern), isDirectory: true)
        }
        let file = directory.appendingPathComponent("draft.sqlite")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { if ownsDirectory { try? FileManager.default.removeItem(at: directory) }; throw NativeTargetSpreadsheetFailure(message: "読み込み用の作業ファイルを作成できません。") }
        close(fd)
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
            throw NativeTargetSpreadsheetFailure(message: "表の作業データを開けません。")
        }
        do {
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=OFF; PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;")
            try execute("CREATE TABLE headers(position INTEGER PRIMARY KEY,name TEXT NOT NULL); CREATE TABLE rows(position INTEGER PRIMARY KEY,json TEXT NOT NULL); CREATE TABLE shared(position INTEGER PRIMARY KEY,text TEXT NOT NULL,rich INTEGER NOT NULL); CREATE TABLE formats(id INTEGER PRIMARY KEY,code TEXT NOT NULL); CREATE TABLE styles(position INTEGER PRIMARY KEY,format INTEGER NOT NULL); CREATE TABLE cells(row INTEGER NOT NULL,col INTEGER NOT NULL,kind TEXT NOT NULL,raw TEXT NOT NULL,style INTEGER NOT NULL,formula INTEGER NOT NULL,rich INTEGER NOT NULL,PRIMARY KEY(row,col)); CREATE TABLE merges(first_row INTEGER,last_row INTEGER,first_col INTEGER,last_col INTEGER); CREATE TABLE raw_rows(position INTEGER PRIMARY KEY); CREATE TABLE hyperlinks(row INTEGER,col INTEGER,PRIMARY KEY(row,col)); CREATE TABLE notes(position INTEGER PRIMARY KEY,message TEXT NOT NULL);")
        } catch { sqlite3_close(db); db = nil; if ownsDirectory { try? FileManager.default.removeItem(at: directory) }; throw error }
    }
    func closeDatabase() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close_v2(db); self.db = nil }
    }
    deinit {
        closeDatabase()
        if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
    }
    private var failure: NativeTargetSpreadsheetFailure { .init(message: "表の作業データを読み書きできません。") }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure }
        do {
            for (i, value) in values.enumerated() {
                let index = Int32(i + 1), code: Int32
                switch value {
                case .integer(let number): code = sqlite3_bind_int64(result, index, number)
                case .null: code = sqlite3_bind_null(result, index)
                case .text(let text):
                    let raw = Array(text.utf8) + [0]
                    guard raw.count - 1 <= Int(Int32.max) else { throw NativeTargetSpreadsheetFailure(message: "1つのセルがSQLiteの文字数上限を超えています。") }
                    code = raw.withUnsafeBytes { sqlite3_bind_text(result, index, $0.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count - 1), transient) }
                }
                guard code == SQLITE_OK else { throw failure }
            }
            return result
        } catch { sqlite3_finalize(result); throw error }
    }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        lock.lock(); defer { lock.unlock() }
        if values.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure }; return
        }
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure }
    }
    func each(_ sql: String, _ values: [Value] = [], _ visit: ([String?]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }; guard code == SQLITE_ROW else { throw failure }
            let row: [String?] = (0..<sqlite3_column_count(statement)).map { i in
                guard let pointer = sqlite3_column_text(statement, i) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self)
            }
            try visit(row)
        }
    }
    func one(_ sql: String, _ values: [Value] = []) throws -> String? {
        var result: String?; try each(sql, values) { if result == nil { result = $0.first ?? nil } }; return result
    }
    func setHeaders(_ headers: [String]) throws {
        try execute("DELETE FROM headers")
        for (position, name) in headers.enumerated() { try execute("INSERT INTO headers VALUES(?,?)", [.integer(Int64(position)), .text(name)]) }
    }
    func headers(offset: Int = 0) throws -> [(Int,String)] {
        var result: [(Int,String)] = []
        try each("SELECT position,name FROM headers ORDER BY position LIMIT 100 OFFSET ?", [.integer(Int64(max(0,offset)))]) { result.append((Int($0[0]!)!, $0[1]!)) }
        return result
    }
    func allHeaders() throws -> [String] {
        var result: [String] = []; try each("SELECT name FROM headers ORDER BY position") { result.append($0[0]!) }; return result
    }
    func append(_ row: NativeTargetSpreadsheetRow) throws {
        guard rowCount < Int64.max else { throw failure }
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        try execute("INSERT INTO rows VALUES(?,?)", [.integer(rowCount), .text(json)]); rowCount += 1
    }
    func rows(after: Int64 = -1, _ body: (Int64,NativeTargetSpreadsheetRow) throws -> Void) throws {
        try each("SELECT position,json FROM rows WHERE position>? ORDER BY position LIMIT 100", [.integer(after)]) { row in
            try body(Int64(row[0]!)!, JSONDecoder().decode(NativeTargetSpreadsheetRow.self, from: Data(row[1]!.utf8)))
        }
    }
    /// Pin/copy once before parser detection passes, without modifying selected file.
    func copySource(_ url: URL, checkpoint: () throws -> Void) throws -> URL {
        let source = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw NativeTargetSpreadsheetFailure(message: "選択したファイルを開けません。") }
        defer { close(source) }
        var initial = stat(); guard fstat(source, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else { throw NativeTargetSpreadsheetFailure(message: "通常のCSVまたはExcelファイルを選んでください。") }
        let output = directory.appendingPathComponent(url.lastPathComponent.lowercased().hasSuffix(".xlsx") ? "source.xlsx" : "source.csv")
        let fd = open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure }; defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 65_536), copied: Int64 = 0
        while true {
            try checkpoint(); let count = Darwin.read(source, &bytes, bytes.count)
            if count == 0 { break }; if count < 0 { if errno == EINTR { continue }; throw failure }
            var sent = 0
            while sent < count {
                try checkpoint(); let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), count - sent) }
                if n < 0 && errno == EINTR { continue }; guard n > 0 else { throw failure }; sent += n
            }
            copied += Int64(count)
        }
        var final = stat()
        guard fstat(source, &final) == 0, initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
              copied == initial.st_size, initial.st_size == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec, initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else {
            throw NativeTargetSpreadsheetFailure(message: "読み込み中に元のファイルが変更されました。選択し直してください。")
        }
        try checkpoint(); return output
    }
}
