import Foundation

@main enum DatabaseTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-DatabaseTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("crm.sqlite")
        func open() throws -> NativeDatabase { try NativeDatabase(url: url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql")) }
        let db = try open()
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw NativeDBError.message("FAIL: \(label)") }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do { try action() } catch { checks += 1; return }
            throw NativeDBError.message("FAIL: \(label) was accepted")
        }
        try check(db.schema.models.count == 92, "all models represented")
        let user = try db.insert("Users", values: ["email": .text("database-test@example.invalid"), "name": .text("確認担当者")], actor: "setup")
        let actor = user["id"].string
        let a = try db.insert("crm_Accounts", values: ["v": .integer(0), "name": .text("株式会社ＡＢＣ 日本語🗾"), "assigned_to": user["id"], "description": .text(String(repeating: "備考", count: 10000))], actor: actor)
        let key = try db.key(for: a)
        try check(a["status"] == .text("Inactive"), "source defaults")
        try check(try db.get(a.model, key: key)?["description"] == a["description"], "long detail preserved")
        let page = try db.page(a.model, fields: ["name"], search: "abc")
        try check(page.total == 1 && page.rows[0]["description"] == .null, "normalized search with lazy details")
        try check(try db.page(a.model, fields: ["name"], search: "' OR 1=1 --").total == 0, "bound search")
        let updated = try db.update(a, changes: ["office_phone": .text("03-0000-1234")], actor: actor)
        try rejects("stale update") { _ = try db.update(a, changes: ["name": .text("競合")], actor: actor) }
        let deleted = try db.setDeleted(updated, deleted: true, actor: actor)
        try check(try db.page(a.model, fields: ["name"]).total == 0, "soft delete hidden")
        try check(try db.page(a.model, fields: ["name"], includeDeleted: true).total == 1, "trash retained")
        let restored = try db.setDeleted(deleted, deleted: false, actor: actor)
        try check(restored["deletedAt"] == .null && restored.revision == 4, "restore with revision")
        try check(try db.auditCount(a.model) == 4, "atomic audit history")
        try rejects("transaction rollback") {
            try db.transaction {
                _ = try db.insert(a.model, values: ["v": .integer(0), "name": .text("ロールバック")], actor: actor)
                throw NativeDBError.message("intentional")
            }
        }
        try check(try db.page(a.model, fields: ["name"]).total == 1 && db.auditCount(a.model) == 4, "rollback includes audit")
        try rejects("foreign key commit failure") { _ = try db.insert(a.model, values: ["v": .integer(0), "name": .text("不正な関連"), "assigned_to": .text(UUID().uuidString)], actor: actor) }
        try check(try db.page(a.model, fields: ["name"]).total == 1 && db.auditCount(a.model) == 4, "failed commit rolls back")
        try rejects("unknown field injection") { _ = try db.insert(a.model, values: ["v": .integer(0), "name); DROP TABLE Users; --": .text("x")], actor: actor) }
        try rejects("invalid enum") { _ = try db.insert("Users", values: ["email": .text("enum@example.invalid"), "role": .text("superuser")], actor: actor) }
        try rejects("wrong number type") { _ = try db.insert(a.model, values: ["v": .text("0"), "name": .text("形式")], actor: actor) }
        try rejects("unique constraint") { _ = try db.insert("Users", values: ["email": user["email"]], actor: actor) }
        let link = try db.insert("AccountWatchers", values: ["account_id": a["id"], "user_id": user["id"]], actor: actor)
        try check(try db.get(link.model, key: db.key(for: link)) != nil, "composite primary key")
        try rejects("duplicate join") { _ = try db.insert(link.model, values: link.values, actor: actor) }
        _ = try db.insert("Currency", values: ["code": .text("JPY"), "name": .text("日本円"), "symbol": .text("¥")], actor: actor)
        let invoice = try db.insert("Invoices", values: ["createdBy": user["id"], "accountId": a["id"], "currency": .text("JPY"), "grandTotal": .text("123456789012.34")], actor: actor)
        try check(invoice["grandTotal"] == .text("123456789012.34"), "exact decimal storage")
        try rejects("decimal double rejected") { _ = try db.update(invoice, changes: ["grandTotal": .real(1.1)], actor: actor) }
        try rejects("decimal overflow") { _ = try db.update(invoice, changes: ["grandTotal": .text("1234567890123.45")], actor: actor) }
        try rejects("decimal excessive scale") { _ = try db.update(invoice, changes: ["grandTotal": .text("1.001")], actor: actor) }
        try rejects("invalid timestamp") { _ = try db.update(invoice, changes: ["dueDate": .text("not-a-date")], actor: actor) }
        try db.transaction {
            do {
                try db.transaction {
                    _ = try db.insert(a.model, values: ["v": .integer(0), "name": .text("内側のみ破棄")], actor: actor)
                    throw NativeDBError.message("nested rollback")
                }
            } catch {}
            _ = try db.insert(a.model, values: ["v": .integer(0), "name": .text("外側は保存")], actor: actor)
        }
        try check(try db.page(a.model, fields: ["name"]).total == 2, "nested savepoint isolation")
        try db.transaction {
            for index in 0..<205 { _ = try db.insert(a.model, values: ["v": .integer(0), "name": .text("ページ検証-\(index)")], actor: actor) }
        }
        let last = try db.page(a.model, fields: ["name"], offset: 200)
        try check(last.total == 207 && last.rows.count == 7, "bounded page")
        try check(try db.page(a.model, fields: ["name"]).rows.count == 100, "first page limit")
        let reopened = try open()
        try check(try reopened.get(invoice.model, key: db.key(for: invoice))?["grandTotal"] == invoice["grandTotal"], "reopen persistence")
        try check(try db.integrityCheck(), "SQLite and relation integrity")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "private file permissions")
        print("{\"ok\":true,\"models\":92,\"checks\":\(checks),\"records\":207}")
    }
}
