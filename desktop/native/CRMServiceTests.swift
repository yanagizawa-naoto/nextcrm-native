import Foundation
import SQLite3

@main enum CRMServiceTests {
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("CRMServiceTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CRMTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func open(_ name: String = "crm.sqlite") throws -> NativeDatabase {
            try NativeDatabase(url: folder.appendingPathComponent(name), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        }
        let db = try open()
        let seeds = resources.appendingPathComponent("../../prisma")
        let identity = try CRMService.bootstrap(db, resources: seeds)
        let admin = CRMService(db: db, identity: identity)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw NativeDBError.message("FAIL: \(label)") }; checks += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: \(label) was accepted")
        }
        func module(_ name: String) -> CRMModule { CRMModule.find("crm_" + name)! }
        func save(_ service: CRMService, _ name: String, _ values: [String: SQLValue], parent: NativeRecord? = nil) throws -> NativeRecord {
            try service.save(module(name), original: nil, input: values, linkedTo: parent)
        }
        func reload(_ record: NativeRecord) throws -> NativeRecord { try db.get(record.model, key: db.key(for: record))! }
        func scalar(_ sql: String, file: URL? = nil) throws -> String {
            var connection: OpaquePointer?; var statement: OpaquePointer?
            guard sqlite3_open_v2((file ?? folder.appendingPathComponent("crm.sqlite")).path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NativeDBError.message("test DB read") }
            defer { sqlite3_finalize(statement); sqlite3_close(connection) }
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw NativeDBError.message("test query \(file?.lastPathComponent ?? "crm.sqlite") \(sql): \(String(cString: sqlite3_errmsg(connection)))") }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        }
        try check(try CRMService.bootstrap(db, resources: seeds).id == identity.id, "bootstrap idempotent")
        try check(try db.page("Currency", fields: []).total == 4, "currency seeds not duplicated")
        for m in CRMModule.all {
            let schema = try db.schema.model(m.model)
            try check(m.fields.allSatisfy { schema.field($0.key) != nil } && m.columns.flatMap(\.fields).allSatisfy { schema.field($0) != nil }, "UI fields exist: \(m.model)")
        }
        func user(_ email: String, role: String = "user") throws -> NativeRecord {
            try db.insert("Users", values: ["name": .text(email), "email": .text(email + "@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE")], actor: identity.id)
        }
        let alice = try user("alice"); let bob = try user("bob"); var partner = try user("partner", role: "partner")
        let manager = try user("manager", role: "manager")
        func service(_ record: NativeRecord) -> CRMService {
            CRMService(db: db, identity: CRMIdentity(id: record["id"].string, role: record["role"].string, partnerAccountID: record["partnerAccountId"] == .null ? nil : record["partnerAccountId"].string))
        }
        let a = service(alice); let b = service(bob)
        let account = try save(a, "Accounts", ["name": .text("日本語株式会社ＡＢＣ"), "status": .text("Active")])
        let other = try save(b, "Accounts", ["name": .text("他の担当者の会社")])
        let contact = try save(admin, "Contacts", ["last_name": .text("山田"), "first_name": .text("太郎"), "accountsIDs": account["id"]])
        let lead = try save(a, "Leads", ["lastName": .text("佐藤"), "accountsIDs": account["id"]])
        var deal = try save(a, "Opportunities", ["name": .text("新規導入"), "account": account["id"], "currency": .text("JPY"), "expected_revenue": .text("123456789.12")])
        let contract = try save(a, "Contracts", ["title": .text("年間契約"), "value": .text("120000.00"), "account": account["id"], "currency": .text("JPY")])
        let target = try save(a, "Targets", ["last_name": .text("鈴木"), "do_not_email": .integer(1), "tags": .text("[\"展示会\",\"東京\"]")])
        let targetList = try save(a, "TargetLists", ["name": .text("東京の営業対象")])
        let activityInput: [String: SQLValue] = ["title": .text("初回打ち合わせ"), "type": .text("meeting"), "date": .text("2026-11-14T01:00:00Z"), "status": .text("scheduled")]
        var activity = try save(admin, "Activities", activityInput, parent: account)
        for record in [account, contact, lead, deal, contract, target, targetList, activity] {
            let list = try admin.list(CRMModule.find(record.model)!)
            try check(list.rows.contains { $0.record["id"] == record["id"] }, "list saved record: \(record.model)")
            try check(try admin.fullRecord(record).values == record.values, "detail roundtrip: \(record.model)")
        }
        try check(target["do_not_email_at"] != .null, "opt out timestamp")
        try check(try a.list(module("Accounts"), search: "abc").total == 1, "Japanese width normalized search")
        try check(try a.list(module("Accounts"), search: "' OR 1=1 --").total == 0, "literal search input")
        try check(try a.fullRecord(contact)["last_name"] == .text("山田"), "linked account grants contact read")
        try rejects("linked account does not grant contact write") { _ = try a.save(module("Contacts"), original: contact, input: ["last_name": .text("不正")]) }
        try rejects("unrelated account hidden") { _ = try a.fullRecord(other) }
        try rejects("forged module rejected") { _ = try a.save(module("Opportunities"), original: account, input: ["name": .text("不正")]) }
        try rejects("protected field rejected") { _ = try a.save(module("Accounts"), original: account, input: ["createdBy": bob["id"]]) }
        try rejects("missing name rejected") { _ = try save(a, "Accounts", ["name": .text("　 ")]) }
        try rejects("unauthorized relation") { _ = try save(a, "Contacts", ["last_name": .text("不正"), "accountsIDs": other["id"]]) }
        _ = try db.insert("AccountWatchers", values: ["account_id": other["id"], "user_id": alice["id"]], actor: identity.id)
        try check(try a.fullRecord(other)["name"] == other["name"], "watcher grants account access")
        try check(try a.list(module("Activities"), linkedTo: account).total == 1, "parent access exposes other author activity")
        try rejects("activity read does not grant write") { _ = try a.save(module("Activities"), original: activity, input: ["title": .text("不正")]) }
        let privateAccount = try save(b, "Accounts", ["name": .text("非公開会社")])
        let eventsBefore = try scalar("SELECT count(*) FROM native_outbox")
        let recordsBefore = try db.page("crm_Activities", fields: []).total
        let auditBefore = try db.auditCount("crm_Activities")
        try rejects("activity link failure") { _ = try save(a, "Activities", activityInput, parent: privateAccount) }
        try check(try db.page("crm_Activities", fields: []).total == recordsBefore && db.auditCount("crm_Activities") == auditBefore && scalar("SELECT count(*) FROM native_outbox") == eventsBefore, "activity and audit and outbox rollback together")
        try rejects("unauthorized activity parent") { _ = try a.list(module("Activities"), linkedTo: privateAccount) }
        activity = try admin.save(module("Activities"), original: activity, input: ["status": .text("cancelled")])
        try check(try scalar("SELECT json_extract(payload,'$.operation') FROM native_outbox WHERE event='calendar/outbound' ORDER BY rowid DESC LIMIT 1") == "cancel", "cancelled meeting queues cancellation")
        let qualified = try db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("提案承認済み"), "stage_kind": .text("qualified")], actor: identity.id)
        try rejects("unapproved qualified stage blocked") { _ = try a.save(module("Opportunities"), original: deal, input: ["sales_stage": qualified["id"]]) }
        deal = try a.approval(deal, decision: "PENDING")
        try rejects("owner cannot approve") { _ = try a.approval(deal, decision: "APPROVED") }
        try rejects("duplicate request") { _ = try a.approval(deal, decision: "PENDING") }
        deal = try service(manager).approval(deal, decision: "APPROVED", note: "条件確認済み")
        deal = try a.save(module("Opportunities"), original: deal, input: ["sales_stage": qualified["id"]])
        try check(deal["stage_entered_at"] != .null && deal["approved_by"] == manager["id"], "approved stage transition")
        try check(try scalar("SELECT count(*) FROM native_outbox WHERE event='crm/opportunity.stage-changed'") == "1", "stage event once")
        let updated = try a.save(module("Accounts"), original: account, input: ["office_phone": .text("03-0000-0001")])
        try rejects("stale form update") { _ = try a.save(module("Accounts"), original: account, input: ["name": .text("古い編集")]) }
        try a.delete(updated)
        try check(try a.list(module("Accounts"), search: "abc").total == 0 && admin.list(module("Accounts"), trash: true).total == 1, "deleted account isolated in trash")
        try rejects("nonadmin restore") { try a.delete(try reload(updated), restore: true) }
        try admin.delete(try reload(updated), restore: true)
        try check(try a.history(reload(updated)).count == 4, "create update delete restore audit")
        let activityHistory = try admin.historyText(activity)
        try check(activityHistory.contains("予定 → 取消") && activityHistory.contains("未設定 → 会議"), "Japanese activity history")
        let dealHistory = try a.historyText(deal)
        try check(dealHistory.contains("承認状況：確認待ち → 承認済み") && dealHistory.contains("未設定 → 提案承認済み"), "approval and relation names in history")
        try rejects("nonadmin trash access") { _ = try a.list(module("Accounts"), trash: true) }
        let ownCompany = try save(admin, "Accounts", ["name": .text("パートナー自身の会社")])
        partner = try db.update(partner, changes: ["partnerAccountId": ownCompany["id"]], actor: identity.id)
        let p = service(partner)
        var partnerAccount = try save(admin, "Accounts", ["name": .text("パートナー担当顧客")])
        partnerAccount = try db.update(partnerAccount, changes: ["partnerUserId": partner["id"]], actor: identity.id)
        try check(try p.fullRecord(ownCompany)["name"] == ownCompany["name"], "partner own company visible")
        try rejects("partner own company readonly") { _ = try p.save(module("Accounts"), original: ownCompany, input: ["name": .text("不正")]) }
        let pc = try save(p, "Contacts", ["last_name": .text("顧客担当"), "accountsIDs": partnerAccount["id"]])
        try check(pc["assigned_to"] == partner["id"], "partner contact assigned to self")
        try rejects("partner delete") { try p.delete(pc) }
        try rejects("partner contract create") { _ = try save(p, "Contracts", ["title": .text("不正"), "value": .text("1"), "account": partnerAccount["id"]]) }
        try rejects("partner unlinked activity") { _ = try save(p, "Activities", activityInput) }
        let pa = try save(p, "Activities", activityInput, parent: partnerAccount)
        _ = try p.save(module("Activities"), original: pa, input: ["title": .text("担当顧客との打合せ")])
        try check(try p.list(module("Activities"), linkedTo: partnerAccount).total == 1, "partner linked activity read and edit")
        try rejects("partner own company activity hidden") { _ = try p.list(module("Activities"), linkedTo: ownCompany) }
        _ = try db.insert("crm_ActivityLinks", values: ["activityId": pa["id"], "entityType": .text("account"), "entityId": privateAccount["id"]], actor: identity.id)
        try rejects("partner mixed-authority links deny edit") { _ = try p.save(module("Activities"), original: reload(pa), input: ["title": .text("不正")]) }
        let roleForgery = CRMService(db: db, identity: CRMIdentity(id: alice["id"].string, role: "admin", partnerAccountID: nil))
        try rejects("forged role") { _ = try roleForgery.list(module("Accounts")) }
        let unknown = CRMService(db: db, identity: CRMIdentity(id: alice["id"].string, role: "unknown", partnerAccountID: nil))
        try rejects("unknown role") { _ = try unknown.list(module("Accounts")) }
        _ = try db.update(alice, changes: ["banned": .integer(1)], actor: identity.id)
        try rejects("banned user") { _ = try a.list(module("Accounts")) }
        let inactive = try db.update(bob, changes: ["userStatus": .text("INACTIVE")], actor: identity.id)
        try rejects("inactive user") { _ = try service(inactive).list(module("Accounts")) }
        try rejects("inactive assignee") { _ = try save(admin, "Accounts", ["name": .text("不正"), "assigned_to": bob["id"]]) }
        try check(try open().get(deal.model, key: db.key(for: deal))?["expected_revenue"] == .text("123456789.12"), "reopen exact amount persistence")
        try check(try db.integrityCheck(), "relation and SQLite integrity")

        // Real v0.1 format, with unknown original fields retained verbatim.
        let legacyURL = folder.appendingPathComponent("accounts.sqlite")
        let old = try AccountStore(url: legacyURL)
        var legacy = Account(); legacy.name = "移行元株式会社"; legacy.industry = "移行業種"; legacy.notes = "日本語メモ\n2行目"; legacy.owner = "元の担当者"
        legacy.sourceJSON = "{\"vat\":\"T1234567890123\",\"unknown_preserved\":\"履歴\"}"
        legacy = try old.save(legacy)
        let oldJSON = try scalar("SELECT source_json FROM accounts", file: legacyURL)
        let naiveID = UUID().uuidString.lowercased()
        let naiveFile = folder.appendingPathComponent("naive-date.jsonl")
        let naiveJSON = "{\"id\":\"\(naiveID)\",\"name\":\"PostgreSQL日時の移行\",\"createdAt\":\"2026-11-14T04:07:35.274\",\"updatedAt\":\"2026-11-14T04:08:35.123456\"}\n"
        try Data(naiveJSON.utf8).write(to:naiveFile)
        _ = try old.importJSONLines(naiveFile)
        let imported = try LegacyMigration.run(source: legacyURL, database: db, actor: identity)
        try check(imported == 2, "legacy migration count")
        let naive = try db.get("crm_Accounts",key:["id":.text(naiveID)])!
        try check(naive["createdAt"] == .text("2026-11-14T04:07:35.274Z") && naive["updatedAt"] == .text("2026-11-14T04:08:35.123456Z"), "PostgreSQL timestamp without timezone import")
        let migrated = try db.get("crm_Accounts", key: ["id": .text(legacy.id)])!
        try check(migrated["name"] == .text(legacy.name) && migrated["description"] == .text(legacy.notes) && migrated["vat"] == .text("T1234567890123"), "legacy mapped values")
        let preserved = try scalar("SELECT original_json FROM native_legacy_accounts WHERE id='\(legacy.id)'")
        try check(preserved.contains("unknown_preserved") && preserved.contains("元の担当者"), "legacy unknown data and owner archived")
        try check(try scalar("SELECT source_json FROM accounts", file: legacyURL) == oldJSON, "source left unchanged")
        try check(try LegacyMigration.run(source: legacyURL, database: db, actor: identity) == 0, "legacy migration idempotent")
        let backups = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        try check(backups.count == 1 && scalar("SELECT source_json FROM accounts", file: backups[0]) == oldJSON, "consistent legacy backup (\(backups.map(\.lastPathComponent)))")
        try check(try scalar("PRAGMA journal_mode", file: backups[0]) == "delete", "portable single file backup")
        let portable = folder.appendingPathComponent("standalone-backup.sqlite")
        try FileManager.default.copyItem(at: backups[0], to: portable)
        try check(try scalar("SELECT source_json FROM accounts", file: portable) == oldJSON, "backup restores with main file alone")
        let rollbackDB = try open("rollback.sqlite")
        let fake = CRMIdentity(id: UUID().uuidString, role: "admin", partnerAccountID: nil)
        try rejects("legacy invalid owner rolls back") { _ = try LegacyMigration.run(source: legacyURL, database: rollbackDB, actor: fake) }
        try check(try rollbackDB.page("crm_Accounts", fields: []).total == 0 && rollbackDB.metadata("legacyAccountsV1") == nil, "migration can retry after rollback")
        print("{\"ok\":true,\"suite\":\"CRMService\",\"checks\":\(checks),\"modules\":8}")
    }
}
