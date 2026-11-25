import Foundation
import SQLite3

/// No write methods or mutable connection are exposed. This connection exists
/// only during the authority-fenced service call and is closed before return.
final class NativeAdminAuditReader {
    private var handle: OpaquePointer?
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { if let handle { sqlite3_close(handle) }; handle = nil; throw NativeDBError.message("変更履歴を開けません。") }
        sqlite3_busy_timeout(handle, 2000)
        try execute("PRAGMA query_only=ON; PRAGMA cache_size=-1024; PRAGMA mmap_size=0; PRAGMA temp_store=FILE")
    }
    deinit { sqlite3_close(handle) }
    func snapshot<T>(_ body: () throws -> T) throws -> T { try execute("BEGIN"); do { let result = try body(); try execute("COMMIT"); return result } catch { try? execute("ROLLBACK"); throw error } }
    private func execute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message("変更履歴を読み取れません。") } }
    private func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw NativeDBError.message("変更履歴を読み取れません。") }; defer { sqlite3_finalize(statement) }
        for (i, value) in bindings.enumerated() {
            let index = Int32(i + 1), transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self); let code: Int32
            switch value { case .null: code = sqlite3_bind_null(statement,index); case let .text(v): code = sqlite3_bind_text(statement,index,v,-1,transient); case let .integer(v): code = sqlite3_bind_int64(statement,index,v); case let .real(v): code = sqlite3_bind_double(statement,index,v); case .blob: throw NativeDBError.message("履歴の検索条件を確認してください。") }
            guard code == SQLITE_OK else { throw NativeDBError.message("変更履歴の検索条件を確認してください。") }
        }
        var result: [[String: SQLValue]] = []
        while true {
            let code = sqlite3_step(statement); if code == SQLITE_DONE { return result }; guard code == SQLITE_ROW else { throw NativeDBError.message("変更履歴を読み取れません。") }
            var row: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement,i))
                switch sqlite3_column_type(statement,i) { case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement,i)); case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement,i)); case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement,i)); if let p = sqlite3_column_text(statement,i) { row[name] = .text(String(decoding: UnsafeBufferPointer(start: p,count: count),as: UTF8.self)) } else { row[name] = .null }
                default: row[name] = .null }
            }
            result.append(row)
        }
    }
    private func count(_ sql: String, _ bindings: [SQLValue]) throws -> Int { Int(try rows(sql,bindings).first?["count"]?.string ?? "0") ?? 0 }
    private func safe(_ expression: String) -> String {
        let markers = NativeAdminAuditSafety.markers.map { "instr(lower(CAST(\(expression) AS TEXT)),'\($0.replacingOccurrences(of: "'", with: "''"))')>0" }
        let credentialURL = "(instr(CAST(\(expression) AS TEXT),'://')>0 AND instr(substr(CAST(\(expression) AS TEXT),instr(CAST(\(expression) AS TEXT),'://')+3),'@')>0)"
        return "(" + (markers + [credentialURL]).joined(separator: " OR ") + ")"
    }
    private func metadata(_ source: NativeAdminAudit.Source) -> String {
        let actor = source == .local ? "a.actor" : "a.userId"
        let actorName = "CASE WHEN u.name IS NULL THEN CASE WHEN u.id IS NULL THEN 'システム／削除済みの利用者' ELSE '名前未設定の利用者' END WHEN \(safe("u.name")) THEN '非公開の利用者名' ELSE substr(u.name,1,200) END AS actor_name"
        if source == .local { return "SELECT a.id,substr(a.model,1,100) entity,CASE WHEN length(a.record_key)<=2048 THEN a.record_key END record_key,substr(a.action,1,100) action,substr(a.created_at,1,40) created_at,\(actorName) FROM native_audit a LEFT JOIN Users u ON u.id=\(actor)" }
        return "SELECT a.id,substr(a.entityType,1,100) entity,CASE WHEN length(a.entityId)<=200 THEN a.entityId END entity_id,substr(a.action,1,100) action,substr(a.createdAt,1,40) created_at,\(actorName) FROM crm_AuditLog a LEFT JOIN Users u ON u.id=\(actor)"
    }
    private func decode(_ row: [String: SQLValue], source: NativeAdminAudit.Source) -> NativeAdminAudit.Entry {
        let entity = row["entity"]?.string ?? "", model = source == .local ? entity : NativeAdminAudit.entities.first { $0.0 == entity }?.2
        var id = row["entity_id"] == .null ? nil : row["entity_id"]?.string
        if source == .local, let text = row["record_key"]?.string, let key = try? JSONDecoder().decode([String:String].self,from:Data(text.utf8)) { id = key["id"] }
        return .init(source: source,id: row["id"]!.string,entityType: entity,model: model,entityID: id,action: row["action"]?.string ?? "",actorName: row["actor_name"]?.string ?? "システム",createdAt: row["created_at"]?.string ?? "")
    }
    func page(_ filters: NativeAdminAudit.Filters) throws -> NativeAdminAudit.Page {
        let local = filters.source == .local; var clauses: [String] = local ? ["a.model<>'crm_AuditLog'"] : []; var values: [SQLValue] = []
        if let value = filters.entityType, !value.isEmpty { clauses.append(local ? "a.model=?" : "a.entityType=?"); values.append(.text(local ? (NativeAdminAudit.entities.first { $0.0 == value }?.2 ?? value) : value)) }
        if let value = filters.action, !value.isEmpty {
            let mapped = local ? (["created":"create","updated":"update","deleted":"delete","restored":"restore","relation_removed":"unlink","cancelled":"cancel"][value] ?? value) : value
            clauses.append("a.action=?"); values.append(.text(mapped))
        }
        if let value = filters.userID, !value.isEmpty { clauses.append(local ? "a.actor=?" : "a.userId=?"); values.append(.text(value)) }
        let dateColumn = local ? "a.created_at" : "a.createdAt"
        for (date, op) in [(filters.dateFrom, ">="), (filters.dateTo, "<=")] { if let date { clauses.append("julianday(\(dateColumn))\(op)julianday(?)"); values.append(.text(Self.iso(date))) } }
        let clause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let total = try count("SELECT COUNT(*) count FROM \(local ? "native_audit" : "crm_AuditLog") a" + clause,values)
        let result = try rows(metadata(filters.source) + clause + " ORDER BY julianday(\(dateColumn)) DESC,a.rowid DESC LIMIT 50 OFFSET ?",values + [.integer(Int64((filters.page - 1) * 50))])
        return .init(entries: result.map { decode($0,source: filters.source) },total: total,page: filters.page)
    }
    func entry(source: NativeAdminAudit.Source, id: String) throws -> NativeAdminAudit.Entry {
        guard let row = try rows(metadata(source) + " WHERE a.id=?" + (source == .local ? " AND a.model<>'crm_AuditLog'" : ""),[.text(id)]).first else { throw NativeDBError.message("履歴が見つかりません。再読み込みしてください。") }
        return decode(row,source: source)
    }
    func users(search: String, page: Int) throws -> (rows: [NativeAdminAudit.User], total: Int) {
        let whereSQL = " WHERE instr(lower(COALESCE(name,'')),lower(?))>0", values: [SQLValue] = [.text(search)]
        let total = try count("SELECT COUNT(*) count FROM Users" + whereSQL,values)
        let result = try rows("SELECT id,CASE WHEN \(safe("name")) THEN '非公開の利用者名' ELSE substr(COALESCE(name,'名前未設定の利用者'),1,200) END name FROM Users" + whereSQL + " ORDER BY name,id LIMIT 50 OFFSET ?",values + [.integer(Int64((page - 1) * 50))])
        return (result.map { .init(id: $0["id"]!.string,name: $0["name"]!.string) },total)
    }
    func fields(_ entry: NativeAdminAudit.Entry, page: Int) throws -> (rows: [(key: String,index: Int?,attribute: String?)], total: Int, invalid: Bool) {
        if entry.source == .business {
            let base = "WITH entries AS (SELECT CAST(j.key AS INTEGER) position,j.value item FROM crm_AuditLog a,json_each(CASE WHEN json_valid(a.changes) THEN CASE WHEN json_type(a.changes)='array' THEN a.changes ELSE '[]' END ELSE '[]' END) j WHERE a.id=?), fields AS (SELECT position,0 kind,CASE WHEN json_valid(item) THEN json_extract(item,'$.field') END field,NULL attribute FROM entries UNION ALL SELECT position,1 kind,k.key field,k.key attribute FROM entries,json_each(CASE WHEN json_valid(item) THEN item ELSE '{}' END) k WHERE k.key NOT IN ('field','old','new')) "
            let total = try count(base + "SELECT COUNT(*) count FROM fields",[.text(entry.id)])
            let result = try rows(base + "SELECT position,substr(field,1,200) field,substr(attribute,1,200) attribute FROM fields ORDER BY position,kind,field LIMIT 50 OFFSET ?",[.text(entry.id),.integer(Int64((page - 1) * 50))])
            let invalid = try rows("SELECT CASE WHEN changes IS NULL THEN 0 WHEN json_valid(changes) THEN json_type(changes)<>'array' ELSE 1 END invalid FROM crm_AuditLog WHERE id=?",[.text(entry.id)]).first?["invalid"] == .integer(1)
            return (result.map { ($0["field"]?.string ?? "",Int($0["position"]?.string ?? ""),$0["attribute"] == .null ? nil : $0["attribute"]?.string) },total,invalid)
        }

        let body = "WITH r AS (SELECT * FROM native_audit WHERE id=?), keys AS (SELECT j.key FROM r,json_each(CASE WHEN json_valid(r.before_json) THEN r.before_json ELSE '{}' END) j UNION SELECT j.key FROM r,json_each(CASE WHEN json_valid(r.after_json) THEN r.after_json ELSE '{}' END) j) "
        let total = try count(body + "SELECT COUNT(*) count FROM keys",[.text(entry.id)])
        let result = try rows(body + "SELECT substr(key,1,200) field FROM keys ORDER BY key LIMIT 50 OFFSET ?",[.text(entry.id),.integer(Int64((page - 1) * 50))])
        let invalid = try rows("SELECT (before_json IS NOT NULL AND NOT json_valid(before_json)) OR (after_json IS NOT NULL AND NOT json_valid(after_json)) invalid FROM native_audit WHERE id=?",[.text(entry.id)]).first?["invalid"] == .integer(1)
        return (result.map { ($0["field"]?.string ?? "",nil,nil) },total,invalid)
    }
    func value(_ entry: NativeAdminAudit.Entry, field: NativeAdminAudit.Field, side: NativeAdminAudit.Side, offset: Int, allowArray: Bool = false) throws -> NativeAdminAudit.Value {
        let table: String, document: String, path: String; var predicate = "id=?"; var values: [SQLValue] = [.text(entry.id)]
        if entry.source == .business {
            guard let index = field.index, index >= 0 else { throw NativeDBError.message("変更項目を選び直してください。") }
            table = "crm_AuditLog"; document = "changes"
            if let attribute = field.attribute {
                guard attribute == field.key, ["decision","plugin"].contains(attribute) else { return .init(text: "非公開の値",offset: 0,total: 0,protected: true) }
                if side == .before { return .init(text: "未設定",offset: 0,total: 0,protected: false) }
                path = "$[\(index)].\(attribute)"
            } else {
                path = "$[\(index)].\(side == .before ? "old" : "new")"
                predicate += " AND json_extract(CASE WHEN json_valid(changes) THEN changes ELSE '[]' END,?)=?"; values += [.text("$[\(index)].field"),.text(field.key)]
            }
        } else { table = "native_audit"; document = side == .before ? "before_json" : "after_json"; path = "$." }
        let actualPath = entry.source == .business ? path : "$.\"" + field.key.replacingOccurrences(of: "\\",with: "\\\\").replacingOccurrences(of: "\"",with: "\\\"") + "\""
        let arrayDocument = "CASE WHEN json_valid(v) THEN CASE WHEN json_type(v)='array' THEN v ELSE '[]' END ELSE '[]' END"
        let serialized = "CASE WHEN kind='text' AND json_valid(v) THEN CASE WHEN json_type(v)='object' THEN 1 WHEN json_type(v)='array' THEN \(allowArray ? "0" : "1") ELSE 0 END ELSE 0 END"
        let unsafeElements = "EXISTS(SELECT 1 FROM json_each(\(arrayDocument)) element WHERE element.type IN ('object','array') OR \(safe("element.value")))"
        let protected = "kind='object' OR (kind='array' AND \(allowArray ? "0" : "1")) OR \(serialized) OR \(unsafeElements) OR \(safe("v"))"
        let sql = "WITH r AS (SELECT json_extract(CASE WHEN json_valid(\(document)) THEN \(document) ELSE '{}' END,?) v,json_type(CASE WHEN json_valid(\(document)) THEN \(document) ELSE '{}' END,?) kind FROM \(table) WHERE \(predicate)), s AS (SELECT *,\(protected) protected FROM r) SELECT kind,protected,CASE WHEN NOT COALESCE(protected,0) THEN length(CAST(v AS TEXT)) ELSE 0 END total,CASE WHEN NOT COALESCE(protected,0) THEN substr(CAST(v AS TEXT),?,4096) END value FROM s"
        guard let row = try rows(sql,[.text(actualPath),.text(actualPath)] + values + [.integer(Int64(offset + 1))]).first else { throw NativeDBError.message("変更項目を読み直してください。") }
        if row["protected"] == .integer(1) { return .init(text: "非公開の値",offset: 0,total: 0,protected: true) }
        let kind = row["kind"]?.string ?? "", value = row["value"]?.string ?? ""
        return .init(text: kind.isEmpty || kind == "null" ? "未設定" : (kind == "true" ? "はい" : (kind == "false" ? "いいえ" : value)),offset: offset,total: Int(row["total"]?.string ?? "0") ?? 0,protected: false)
    }
    private static func iso(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f.string(from: date) }
}
