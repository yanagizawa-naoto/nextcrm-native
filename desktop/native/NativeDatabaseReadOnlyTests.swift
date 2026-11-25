import Foundation
import SQLite3

@main enum NativeDatabaseReadOnlyTests {
    static var checks = 0
    static let actor = "10000000-0000-0000-0000-000000000001"
    static let account = "20000000-0000-0000-0000-000000000001"
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1; FileHandle.standardError.write(Data(("OK: " + label + "\n").utf8)) }
    static func reject(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NativeDBError.message("DID NOT REJECT: " + label)
    }
    static func rejectWrite(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch NativeDBError.message(let message) where message == "このデータベースは閲覧専用です。" { checks += 1; return }
        throw NativeDBError.message("DID NOT REJECT AS READONLY: " + label)
    }
    static func main() throws {
        let a = CommandLine.arguments, c = URL(fileURLWithPath: a[2]), url = URL(fileURLWithPath: a[3])
        let schema = c.appendingPathComponent("schema.json")
        if a[1] == "initialize" {
            let db = try NativeDatabase(url: url, schemaURL: schema, sqlURL: c.appendingPathComponent("schema.sql"))
            try check(!db.isReadOnly, "writable initializer")
            var hooks = 0; db.beforeRecordWrite = { _,_,_,values,_ in hooks += 1; return values }
            _ = try db.insert("Users", values: ["id": .text(actor), "name": .text("検証管理者"), "email": .text("readonly@example.test"), "role": .text("admin"), "userStatus": .text("ACTIVE")], actor: actor)
            let acc = try db.insert("crm_Accounts", values: ["id": .text(account), "v": .integer(0), "name": .text("検証ＡＢＣ株式会社"), "description": .text("完全一致より長い説明と検索対象😀"), "assigned_to": .text(actor), "annual_revenue": .text("12345678901234567890"), "email": .text("Example@EXAMPLE.test")], actor: actor)
            _ = try db.update(acc, changes: ["office_phone": .text("123")], actor: actor)
            _ = try db.insert("Currency", values: ["code": .text("JPY"), "name": .text("日本円"), "symbol": .text("¥"), "isDefault": .integer(1)], actor: actor)
            _ = try db.insert("Session", values: ["id": .text("session-fixture"), "userId": .text(actor), "token": .text("synthetic-session"), "expiresAt": .text("2099-01-01T00:00:00Z")], actor: actor)
            try db.setMetadata("fixture", value: "unchanged")
            _ = try db.enqueue("fixture", payload: ["id": account], id: "fixture-job")
            try check(hooks == 5, "writable hooks preserved")
            try check(try db.integrityCheck(), "writable FK/integrity")
        } else if a[1] == "reject" {
            try reject("invalid snapshot") { _ = try NativeDatabase(readOnlyURL: url, schemaURL: schema) }
        } else {
            let db = try NativeDatabase(readOnlyURL: url, schemaURL: schema)
            try check(db.isReadOnly, "readonly flag")
            let user = try db.get("Users", key: ["id": .text(actor)])!, acc = try db.get("crm_Accounts", key: ["id": .text(account)])!
            let service = CRMService(db: db, identity: .init(id: actor, role: "admin", partnerAccountID: nil))
            // Synthetic identity is test-only; production host needs fresh
            // session authority. This API neither chooses nor creates an actor.
            try service.authenticated(); checks += 1
            try check(try service.list(CRMModule.find("crm_Accounts")!, search: "abc").total == 1, "authorized CRM list")
            try reject("wrong role") { try CRMService(db: db, identity: .init(id: actor, role: "manager", partnerAccountID: nil)).authenticated() }
            try reject("unknown identity") { try CRMService(db: db, identity: .init(id: "absent", role: "admin", partnerAccountID: nil)).authenticated() }
            try check(user["role"] == .text("admin") && user["userStatus"] == .text("ACTIVE"), "typed enum read")
            try check(acc["v"] == .integer(0) && acc["description"] == .text("完全一致より長い説明と検索対象😀"), "mapped integer and Unicode")
            try check(try db.metadata("fixture") == "unchanged", "metadata read")
            try check(try db.page("crm_Accounts", fields: ["name", "description"], search: "abc", localizedSort: true).total == 1, "normalized list search")
            try check(try db.page("Currency", fields: ["code", "isDefault"]).rows.first?["isDefault"] == .integer(1), "boolean typed list")
            try check(try db.keysetPage("crm_Accounts", fields: ["description"], maximumTextCharacters: ["description": 4]).first?["description"] == .text("完全一致"), "bounded typed page")
            let match = try db.textSearchPage("crm_Accounts", field: "description", query: "検索対象😀", filter: .all)
            try check(match.total == 1 && match.rows.first?["id"] == .text(account), "TEMP-backed full text search")
            try check(try db.textSearchPage("crm_Accounts", field: "description", query: "", filter: .all).total == 1, "TEMP-backed empty search")
            try check(try db.mcpPage("crm_Accounts", fields: ["name"], filter: .all, searchFields: ["name"], query: "株式会社", limit: 10, offset: 0).total == 1, "MCP typed search")
            let workspace = try db.createReportWorkspace()
            try db.aggregateReport(workspace, section: "accounts", recipe: "newAccounts", filter: .all)
            try check(try db.reportPage(workspace, section: "accounts").rows.first?["value"] == .text("1"), "TEMP aggregate report")
            db.removeReportWorkspace(workspace)
            try check(try db.integrityCheck(), "readonly integrity")
            try db.transaction {
                try db.transaction { try check(try db.get("crm_Accounts", key: ["id": .text(account)]) != nil, "nested read transaction") }
                try reject("nested read rollback") { try db.transaction { throw NativeDBError.conflict } }
                try check(try db.metadata("fixture") == "unchanged", "read after rollback")
            }
            var before = 0, after = 0
            db.beforeRecordWrite = { _,_,_,values,_ in before += 1; return values }
            db.afterRecordWrite = { _,_,_,_,_,_ in after += 1 }
            let job = try db.job(id: "fixture-job")!, session = try db.get("Session", key: ["id": .text("session-fixture")])!
            try rejectWrite("claimCalendarOutboundJob before validation/no-op/hook") { _ = try db.claimCalendarOutboundJob() }
            try rejectWrite("retryCalendarOutboundJob before validation/no-op/hook") { _ = try db.retryCalendarOutboundJob(job) }
            try rejectWrite("reviewCalendarOutboundNotApplied before validation/no-op/hook") { _ = try db.reviewCalendarOutboundNotApplied(job, actor: actor, note: "test") }
            try rejectWrite("retryAIJob before validation/no-op/hook") { _ = try db.retryAIJob(job, events: []) }
            try rejectWrite("cancelAIJob before validation/no-op/hook") { _ = try db.cancelAIJob(job, events: []) }
            try rejectWrite("claimJob before validation/no-op/hook") { _ = try db.claimJob(events: []) }
            try rejectWrite("renewJobLease before validation/no-op/hook") { _ = try db.renewJobLease(job) }
            try rejectWrite("markJobDeliveryStarted before validation/no-op/hook") { _ = try db.markJobDeliveryStarted(job) }
            try rejectWrite("finishJob before validation/no-op/hook") { _ = try db.finishJob(job) }
            try rejectWrite("recordJobResult before validation/no-op/hook") { _ = try db.recordJobResult(job, result: [:]) }
            try rejectWrite("failJob before validation/no-op/hook") { _ = try db.failJob(job, message: "test") }
            try rejectWrite("retryJob before validation/no-op/hook") { _ = try db.retryJob(id: job.id) }
            try rejectWrite("cancelJob before validation/no-op/hook") { _ = try db.cancelJob(id: job.id) }
            try rejectWrite("completeReviewedMail before validation/no-op/hook") { _ = try db.completeReviewedMail(job, result: [:], now: Date()) }
            try rejectWrite("setMetadata before validation/no-op/hook") { _ = try db.setMetadata("fixture", value: "bad") }
            try rejectWrite("queueAIKeyCleanup before validation/no-op/hook") { _ = try db.queueAIKeyCleanup(UUID().uuidString, notBefore: Date()) }
            try rejectWrite("clearAIKeyCleanup before validation/no-op/hook") { _ = try db.clearAIKeyCleanup("missing") }
            try rejectWrite("preserveLegacyAccount before validation/no-op/hook") { _ = try db.preserveLegacyAccount(id: "missing", json: "{}") }
            try rejectWrite("enqueue before validation/no-op/hook") { _ = try db.enqueue("test", payload: [:]) }
            try rejectWrite("insert before validation/no-op/hook") { _ = try db.insert("Currency", values: [:], actor: actor) }
            try rejectWrite("update before validation/no-op/hook") { _ = try db.update(acc, changes: [:], actor: actor) }
            try rejectWrite("setDeleted before validation/no-op/hook") { _ = try db.setDeleted(acc, deleted: true, actor: actor) }
            try rejectWrite("moveOrderedLine before validation/no-op/hook") { _ = try db.moveOrderedLine(acc, parentField: "bad", parentID: .null, direction: 1, actor: actor) }
            try rejectWrite("remove before validation/no-op/hook") { _ = try db.remove(acc, actor: actor) }
            try rejectWrite("deleteCRMConfiguration before validation/no-op/hook") { _ = try db.deleteCRMConfiguration(acc, actor: actor) }
            try rejectWrite("deleteAdministrativeUser before validation/no-op/hook") { _ = try db.deleteAdministrativeUser(user, actor: actor) }
            try rejectWrite("reorderProjectItem before validation/no-op/hook") { _ = try db.reorderProjectItem(acc, direction: 1, actor: actor) }
            try rejectWrite("placeProjectTask before validation/no-op/hook") { _ = try db.placeProjectTask(acc, to: .null, before: nil, actor: actor) }
            try rejectWrite("touchAPIToken before validation/no-op/hook") { _ = try db.touchAPIToken(id: "missing", at: "2099-01-01T00:00:00Z") }
            try rejectWrite("refreshBrowserSession before validation/no-op/hook") { _ = try db.refreshBrowserSession(session, expiresAt: "2099-02-01T00:00:00Z", updatedAt: "2099-01-01T00:00:00Z") }
            try rejectWrite("deleteExpiredBrowserSession before validation/no-op/hook") { _ = try db.deleteExpiredBrowserSession(session) }
            try rejectWrite("storeMailSend before validation/no-op/hook") { _ = try db.storeMailSend(jobID: "missing", accountID: "missing", actorID: actor, messageID: "missing", summary: "", mime: Data()) }
            try rejectWrite("releaseMailSendPayload before validation/no-op/hook") { _ = try db.releaseMailSendPayload("missing") }
            try rejectWrite("clearMailDeliveryStarted before validation/no-op/hook") { _ = try db.clearMailDeliveryStarted(job) }
            try rejectWrite("retryMailSend before validation/no-op/hook") { _ = try db.retryMailSend(job) }
            try rejectWrite("reviewMailSend before validation/no-op/hook") { _ = try db.reviewMailSend(job, sent: false, now: Date()) }
            try rejectWrite("removeMailAccount before validation/no-op/hook") { _ = try db.removeMailAccount(acc, actor: actor) }
            try rejectWrite("reserveDocumentProcessing before validation/no-op/hook") { _ = try db.reserveDocumentProcessing(acc, jobID: "missing") }
            try rejectWrite("enqueueDocumentAI before validation/no-op/hook") { _ = try db.enqueueDocumentAI(acc, actor: actor) }
            try rejectWrite("clearDocumentAIStage before validation/no-op/hook") { _ = try db.clearDocumentAIStage(job) }
            try rejectWrite("discardCancelledDocumentAI before validation/no-op/hook") { _ = try db.discardCancelledDocumentAI(job) }
            try rejectWrite("stageDocumentAI before validation/no-op/hook") { _ = try db.stageDocumentAI(job, index: 0, text: "", vector: Data(), result: [:]) }
            try rejectWrite("clearDocumentAIIndex before validation/no-op/hook") { _ = try db.clearDocumentAIIndex("missing") }
            try rejectWrite("patchDocumentAI before validation/no-op/hook") { _ = try db.patchDocumentAI(acc, changes: [:], actor: actor) }
            try rejectWrite("publishDocumentAI before validation/no-op/hook") { _ = try db.publishDocumentAI(job, source: acc, single: false, count: 0, hash: "", changes: [:], actor: actor, result: [:], now: Date()) }
            try rejectWrite("archiveDocumentProcessing before validation/no-op/hook") { _ = try db.archiveDocumentProcessing(from: acc, to: acc) }
            try rejectWrite("saveDocumentProcessing before validation/no-op/hook") { _ = try db.saveDocumentProcessing(acc, jobID: "missing", textBytes: 0, thumbnail: nil, note: "", produce: { _ in before += 1 }) }
            try rejectWrite("putDocumentObject before validation/no-op/hook") { _ = try db.putDocumentObject(bucket: "", key: "", fileKey: "", contentType: "", bytes: 0, sha256: "") }
            try rejectWrite("removeUnreferencedDocumentObjects before validation/no-op/hook") { _ = try db.removeUnreferencedDocumentObjects("missing") }
            try rejectWrite("removeDocumentFamily before validation/no-op/hook") { _ = try db.removeDocumentFamily(acc, actor: actor) }
            try rejectWrite("recordOrderLineCount before validation/no-op/hook") { _ = try db.recordOrderLineCount(acc, before: 0, after: 0, actor: actor) }
            try rejectWrite("stageCampaignAudience before validation/no-op/hook") { _ = try db.stageCampaignAudience(jobID: "", campaignID: "", stepID: "", initial: false, sendTo: "") }
            try rejectWrite("clearCampaignAudience before validation/no-op/hook") { _ = try db.clearCampaignAudience(jobID: "missing") }
            try rejectWrite("queueCampaignSend before validation/no-op/hook") { _ = try db.queueCampaignSend(acc, token: "", actorID: actor, now: Date()) }
            try rejectWrite("unsubscribeCampaign before validation/no-op/hook") { _ = try db.unsubscribeCampaign(token: "missing") }
            try rejectWrite("receiveCampaignEvent before validation/no-op/hook") { _ = try db.receiveCampaignEvent(id: "", providerID: "", kind: "", bodySHA256: "") }
            try rejectWrite("reconcileCampaignEvents before validation/no-op/hook") { _ = try db.reconcileCampaignEvents(providerID: "missing") }
            try rejectWrite("recordCampaignRelayRegistration before validation/no-op/hook") { _ = try db.recordCampaignRelayRegistration(instanceID: "", sendID: "", token: "", providerID: nil) }
            try rejectWrite("clearReportScheduleMetadata before validation/no-op/hook") { _ = try db.clearReportScheduleMetadata("missing") }
            try rejectWrite("clearReportConfigurationScheduleMetadata before validation/no-op/hook") { _ = try db.clearReportConfigurationScheduleMetadata("missing") }
            try rejectWrite("cancelUnstartedReportJobs before validation/no-op/hook") { _ = try db.cancelUnstartedReportJobs() }
            try rejectWrite("claimReportJob before validation/no-op/hook") { _ = try db.claimReportJob() }
            try rejectWrite("acknowledgeReportDelivery before validation/no-op/hook") { _ = try db.acknowledgeReportDelivery(job, acceptedAt: Date()) }
            try check(before == 0 && after == 0, "CRUD denied before all hooks")
            try check(try db.get("crm_Accounts", key: ["id": .text(account)])?["name"] == acc["name"], "row unchanged")
            try check(try db.job(id: job.id) == job, "job unchanged")
            for sql in ["UPDATE main.Users SET name='bad'", "CREATE TABLE main.bad(id TEXT)", "DROP TABLE main.Users", "CREATE INDEX bad ON Users(name)", "ALTER TABLE Users ADD COLUMN bad TEXT", "ATTACH ':memory:' AS bad", "PRAGMA journal_mode=WAL", "PRAGMA user_version=9", "PRAGMA writable_schema=ON", "PRAGMA query_only=OFF", "VACUUM", "CREATE TEMP TRIGGER bad AFTER INSERT ON main.Users BEGIN SELECT 1; END"] {
                try reject("SQL \(sql)") { try db.testOnlySQL(sql) }
            }
            try check(try db.testOnlyScalar("SELECT '10' COLLATE native_decimal < '2' COLLATE native_decimal") == .integer(0), "decimal collation")
            try check(try db.testOnlyScalar("SELECT 'EXAMPLE' COLLATE native_email = 'example'") == .integer(1), "email collation")
            try check(try db.testOnlyScalar("SELECT 'Ａ' COLLATE native_japanese = 'ａ'") == .integer(1), "Japanese collation")
            try check(try db.testOnlyScalar("PRAGMA journal_mode") == .text("delete"), "no WAL promotion")
        }
        print("{\"checks\":\(checks),\"mode\":\"\(a[1])\"}")
    }
}
