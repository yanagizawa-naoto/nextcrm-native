import Foundation
import SQLite3

enum LegacyMigration {
    /// Keeps the v0.1 database and creates a consistent SQLite backup before copying.
    /// Original JSON plus all prototype columns are retained in native_legacy_accounts.
    static func run(source: URL, database: NativeDatabase, actor: CRMIdentity) throws -> Int {
        guard FileManager.default.fileExists(atPath: source.path), try database.metadata("legacyAccountsV1") == nil else { return 0 }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(source.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NativeDBError.message("旧版の取引先データを読み込めません。") }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 5000)
        guard sqlite3_exec(connection, "BEGIN; SELECT count(*) FROM accounts", nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message("旧版の取引先データが不正です。") }
        defer { sqlite3_exec(connection, "ROLLBACK", nil, nil, nil) }
        let backupFolder = source.deletingLastPathComponent().appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backupURL = backupFolder.appendingPathComponent("accounts-v01-\(UUID().uuidString).sqlite")
        var backup: OpaquePointer?
        guard sqlite3_open_v2(backupURL.path, &backup, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw NativeDBError.message("移行前のバックアップを作成できません。") }
        defer { sqlite3_close(backup) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        guard let copy = sqlite3_backup_init(backup, "main", connection, "main") else { throw NativeDBError.message("バックアップを開始できません。") }
        let copied = sqlite3_backup_step(copy, -1); let finished = sqlite3_backup_finish(copy)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else { throw NativeDBError.message("バックアップを完了できません。旧版データは変更していません。") }
        // Reopen so SQLite reads the copied header's journal mode (the source uses WAL).
        guard sqlite3_close(backup) == SQLITE_OK else { throw NativeDBError.message("バックアップを閉じられませんでした。旧版データは変更していません。") }
        backup = nil
        guard sqlite3_open_v2(backupURL.path, &backup, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw NativeDBError.message("バックアップを確認できません。") }
        var mode: OpaquePointer?
        guard sqlite3_prepare_v2(backup, "PRAGMA journal_mode=DELETE", -1, &mode, nil) == SQLITE_OK else { throw NativeDBError.message("バックアップの形式を確定できません。") }
        let modeStep = sqlite3_step(mode)
        let journal = sqlite3_column_text(mode, 0).map { String(cString: $0) }
        sqlite3_finalize(mode)
        guard modeStep == SQLITE_ROW, journal == "delete" else { throw NativeDBError.message("単一ファイルのバックアップを確定できません。旧版データは変更していません。") }
        guard sqlite3_close(backup) == SQLITE_OK else { throw NativeDBError.message("バックアップを閉じられませんでした。") }
        backup = nil
        // Some system SQLite builds retain an unused shared-memory sidecar after leaving WAL.
        let sharedMemory = URL(fileURLWithPath: backupURL.path + "-shm")
        if FileManager.default.fileExists(atPath: sharedMemory.path) { try FileManager.default.removeItem(at: sharedMemory) }
        return try database.transaction {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "SELECT * FROM accounts ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw NativeDBError.message("旧版の取引先を取得できません。") }
            defer { sqlite3_finalize(statement) }
            var count = 0
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw NativeDBError.message("旧版データの読み込み中に失敗しました。") }
                var raw: [String:String] = [:]
                for index in 0..<sqlite3_column_count(statement) {
                    let name = String(cString: sqlite3_column_name(statement, index))
                    raw[name] = sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
                }
                guard let id = raw["id"], UUID(uuidString: id) != nil else { throw NativeDBError.message("旧版データの識別子が不正です。") }
                let preserved = String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), as: UTF8.self)
                try database.preserveLegacyAccount(id: id, json: preserved)
                if try database.get("crm_Accounts", key: ["id":.text(id)]) != nil { continue }
                var values: [String:SQLValue] = ["id":.text(id),"v":.integer(0),"createdBy":.text(actor.id),"assigned_to":.text(actor.id)]
                for (old, new) in ["name":"name","email":"email","phone":"office_phone","website":"website","status":"status","street":"billing_street","city":"billing_city","prefecture":"billing_state","postal_code":"billing_postal_code","country":"billing_country","notes":"description","created_at":"createdAt","updated_at":"updatedAt"] {
                    if let value = raw[old], !value.isEmpty {
                        // The PostgreSQL JSON export omits the offset for Prisma's timestamp fields.
                        // Treat those as UTC, matching Prisma's DateTime interpretation; raw text is archived above.
                        let naiveTimestamp = ["createdAt","updatedAt"].contains(new) && value.range(of:"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,6})?$",options:.regularExpression) != nil
                        values[new] = .text(naiveTimestamp ? value + "Z" : value)
                    }
                }
                if let industry = raw["industry"], !industry.isEmpty {
                    let found = try database.page("crm_Industry_Type", fields: ["name"], equal: ["name":.text(industry)]).rows.first
                    let record = try found ?? database.insert("crm_Industry_Type", values: ["name":.text(industry)], actor: actor.id)
                    values["industry"] = record["id"]
                }
                // Restore additional non-reference scalar fields from the originally copied CRM row.
                if let text = raw["source_json"], let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any] {
                    for field in ["annual_revenue","company_id","employees","fax","member_of","shipping_city","shipping_country","shipping_postal_code","shipping_state","shipping_street","type","vat"] {
                        if let value = json[field] as? String { values[field] = .text(value) }
                    }
                }
                _ = try database.insert("crm_Accounts", values: values, actor: actor.id); count += 1
            }
            try database.setMetadata("legacyAccountsV1", value: backupURL.lastPathComponent)
            return count
        }
    }
}
