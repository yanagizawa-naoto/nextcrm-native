import Foundation
import SQLite3

struct Account: Codable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var email = ""
    var phone = ""
    var website = ""
    var status = "Active"
    var industry = ""
    var owner = "ローカル管理者"
    var street = ""
    var city = ""
    var prefecture = ""
    var postalCode = ""
    var country = "日本"
    var notes = ""
    var createdAt = ""
    var updatedAt = ""
    var sourceJSON = "{}"
    var revision: Int64 = 0

    var statusLabel: String {
        switch status.lowercased() { case "active": return "有効"; case "inactive": return "無効"; default: return status.isEmpty ? "未設定" : status }
    }
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .precomposedStringWithCanonicalMapping
    }
    var searchKey: String { Self.normalized([name, email, phone, website, industry, street, city, prefecture, postalCode].joined(separator: "\n")) }
    func validated() throws -> Account {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { throw StoreError.message("会社名を入力してください。") }
        guard copy.name.count <= 500 else { throw StoreError.message("会社名は500文字以内にしてください。") }
        guard ![name,email,phone,website,status,industry,owner,street,city,prefecture,postalCode,country,notes].contains(where: { $0.contains("\0") }) else {
            throw StoreError.message("使用できない制御文字が含まれています。")
        }
        return copy
    }
}

enum StoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

struct AccountPage {
    let rows: [Account]
    let total: Int
    let page: Int
    let pageSize: Int
}

final class AccountStore {
    private var db: OpaquePointer?
    let fileURL: URL
    static let pageSize = 100
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = "id,name,email,phone,website,status,industry,owner,street,city,prefecture,postal_code,country,notes,created_at,updated_at,source_json,revision"

    init(url: URL) throws {
        fileURL = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let message = errorMessage; if let db { sqlite3_close(db) }; db = nil
            throw StoreError.message(message)
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA cache_size=-512; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;")
            try execute("""
                CREATE TABLE IF NOT EXISTS accounts (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL, phone TEXT NOT NULL,
                    website TEXT NOT NULL, status TEXT NOT NULL, industry TEXT NOT NULL, owner TEXT NOT NULL,
                    street TEXT NOT NULL, city TEXT NOT NULL, prefecture TEXT NOT NULL, postal_code TEXT NOT NULL,
                    country TEXT NOT NULL, notes TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                    source_json TEXT NOT NULL, revision INTEGER NOT NULL,
                    sort_key TEXT NOT NULL, search_key TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS accounts_order ON accounts(sort_key,id);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                PRAGMA user_version=1;
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { if let db { sqlite3_close(db) }; db = nil; throw error }
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    private var errorMessage: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "データベースを開けませんでした。" }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.message(errorMessage) }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw StoreError.message(errorMessage) }
        return result
    }
    private func bind(_ values: [String], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient) == SQLITE_OK else { throw StoreError.message(errorMessage) }
        }
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }
    private func account(_ statement: OpaquePointer) -> Account {
        var row = Account()
        row.id = text(statement, 0); row.name = text(statement, 1); row.email = text(statement, 2)
        row.phone = text(statement, 3); row.website = text(statement, 4); row.status = text(statement, 5)
        row.industry = text(statement, 6); row.owner = text(statement, 7); row.street = text(statement, 8)
        row.city = text(statement, 9); row.prefecture = text(statement, 10); row.postalCode = text(statement, 11)
        row.country = text(statement, 12); row.notes = text(statement, 13); row.createdAt = text(statement, 14)
        row.updatedAt = text(statement, 15); row.sourceJSON = text(statement, 16); row.revision = sqlite3_column_int64(statement, 17)
        return row
    }
    func page(search: String = "", status: String = "", index: Int = 0) throws -> AccountPage {
        var clauses: [String] = []; var values: [String] = []
        let term = Account.normalized(search.trimmingCharacters(in: .whitespacesAndNewlines))
        if !term.isEmpty {
            clauses.append("search_key LIKE ? ESCAPE '\\'")
            values.append("%" + term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%")
        }
        if !status.isEmpty { clauses.append("lower(status)=?"); values.append(status.lowercased()) }
        let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let count = try statement("SELECT count(*) FROM accounts" + filter); defer { sqlite3_finalize(count) }
        try bind(values, to: count)
        guard sqlite3_step(count) == SQLITE_ROW else { throw StoreError.message(errorMessage) }
        let total = Int(sqlite3_column_int64(count, 0))
        let page = max(0, min(index, max(0, (total - 1) / Self.pageSize)))
        // Lists never load notes, addresses or preserved source JSON. Details
        // are fetched only when one record is opened for editing.
        let summaryColumns = "id,name,email,phone,'',status,'',owner,'','','','','','',created_at,updated_at,'{}',revision"
        let query = try statement("SELECT \(summaryColumns) FROM accounts\(filter) ORDER BY sort_key,id LIMIT \(Self.pageSize) OFFSET \(page * Self.pageSize)")
        defer { sqlite3_finalize(query) }; try bind(values, to: query)
        var rows: [Account] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw StoreError.message(errorMessage) }
            rows.append(account(query))
        }
        return AccountPage(rows: rows, total: total, page: page, pageSize: Self.pageSize)
    }
    func get(_ id: String) throws -> Account? {
        let query = try statement("SELECT \(Self.columns) FROM accounts WHERE id=?"); defer { sqlite3_finalize(query) }
        try bind([id], to: query)
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw StoreError.message(errorMessage) }
        return account(query)
    }
    private func values(_ row: Account) -> [String] {
        [row.id,row.name,row.email,row.phone,row.website,row.status,row.industry,row.owner,row.street,row.city,row.prefecture,
         row.postalCode,row.country,row.notes,row.createdAt,row.updatedAt,row.sourceJSON,String(row.revision),Account.normalized(row.name),row.searchKey]
    }
    private func insert(_ row: Account) throws {
        let sql = "INSERT INTO accounts (\(Self.columns),sort_key,search_key) VALUES (\(Array(repeating: "?", count: 20).joined(separator: ",")))"
        let query = try statement(sql); defer { sqlite3_finalize(query) }; try bind(values(row), to: query)
        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.message(errorMessage) }
    }
    @discardableResult func save(_ input: Account) throws -> Account {
        var row = try input.validated()
        let now = ISO8601DateFormatter().string(from: Date())
        row.updatedAt = now
        if row.revision == 0 {
            row.createdAt = now; row.revision = 1; try insert(row)
        } else {
            let prior = row.revision; row.revision += 1
            let assignments = Self.columns.split(separator: ",").dropFirst().map { "\($0)=?" } + ["sort_key=?", "search_key=?"]
            let query = try statement("UPDATE accounts SET \(assignments.joined(separator: ",")) WHERE id=? AND revision=?")
            defer { sqlite3_finalize(query) }
            try bind(Array(values(row).dropFirst()) + [row.id, String(prior)], to: query)
            guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.message(errorMessage) }
            guard sqlite3_changes(db) == 1 else { throw StoreError.message("別の操作で更新されています。編集画面を閉じて、もう一度開いてください。") }
        }
        return row
    }
    /// Initial import only. Never overwrite an account already edited locally.
    @discardableResult func importJSONLines(_ url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try execute("BEGIN IMMEDIATE")
        var count = 0
        do {
            var pending = Data()
            func consume(_ data: Data) throws {
                if data.isEmpty { return }
                let raw = try JSONSerialization.jsonObject(with: data)
                guard let source = raw as? [String: Any], let id = source["id"] as? String, UUID(uuidString: id) != nil else {
                    throw StoreError.message("取引先データのIDが不正です。")
                }
                if try get(id) != nil { return }
                func string(_ key: String) -> String { source[key] as? String ?? "" }
                var row = Account(); row.id = id; row.name = string("name"); row.email = string("email")
                row.phone = string("office_phone"); row.website = string("website"); row.status = string("status")
                row.industry = string("industry_name"); row.owner = string("owner_name"); row.street = string("billing_street")
                row.city = string("billing_city"); row.prefecture = string("billing_state"); row.postalCode = string("billing_postal_code")
                row.country = string("billing_country"); row.notes = string("description"); row.createdAt = string("createdAt")
                row.updatedAt = string("updatedAt").isEmpty ? row.createdAt : string("updatedAt"); row.revision = 1
                row.sourceJSON = String(decoding: data, as: UTF8.self)
                try insert(row); count += 1
            }
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    try consume(pending.subdata(in: pending.startIndex..<newline))
                    pending.removeSubrange(pending.startIndex...newline)
                }
                guard pending.count < 16 * 1024 * 1024 else { throw StoreError.message("1件の取引先データが大きすぎます。") }
            }
            try consume(pending)
            try execute("COMMIT")
            return count
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
