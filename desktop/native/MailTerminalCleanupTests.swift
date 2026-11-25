import Foundation
import SQLite3

@main enum MailTerminalCleanupTests {
    enum Rollback: Error { case expected }
    static var checks = 0
    static var differences: [String] = []
    static let now = Date(timeIntervalSince1970:1_800_000_000)
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func content(_ url: URL) -> Data? { try? Data(contentsOf:url) }
    static func captureDifference(_ value: Bool, _ label: String) { checks += 1; if !value { differences.append(label) } }
    struct Mail {
        let fixture: InvoiceCancelCleanupTests.Fixture
        let id: String, file: URL, bytes: Data
        let cancel: () throws -> Void
    }
    static func queued(_ family: String, resources: URL, root: URL) throws -> Mail {
        let f = try InvoiceCancelCleanupTests.fixture(resources,root)
        let actor = f.service.identity.id
        let id = UUID().uuidString.lowercased()
        var payload: [String:String] = [:]
        var event: String
        var cancel: (() throws -> Void)!
        switch family {
        case "order":
            let account = try f.db.page("crm_Accounts",fields:[]).rows[0]
            let series = try f.db.insert("NumberSeries",values:["name":.text("合成受注番号"),"template":.text("TEST-{####}"),"scope":.text("orders")],actor:actor)
            let order = try f.db.insert("crm_Orders",values:["number":.text("TEST-1"),"seriesId":series["id"],"accountId":account["id"],"currency":.text("JPY"),"createdBy":.text(actor)],actor:actor)
            event = "orders.approval_requested"; payload = ["orderId":order["id"].string,"recipientId":actor]
            cancel = { try f.service.cancelOrderJob(id) }
        case "project":
            event = "projects.task_assigned"; payload = ["taskId":UUID().uuidString.lowercased(),"recipientId":actor]
            cancel = { try f.service.cancelProjectJob(id) }
        case "crmTask":
            event = "crm.task_assigned"; payload = ["taskId":UUID().uuidString.lowercased(),"recipientId":actor]
            cancel = { try f.service.cancelCRMTaskJob(id) }
        case "lead":
            event = "crm.lead_assigned"; payload = ["leadId":UUID().uuidString.lowercased(),"recipientId":actor]
            cancel = { try f.service.cancelLeadJob(id) }
        case "campaign":
            let campaign = try f.db.insert("crm_campaigns",values:["v":.integer(0),"name":.text("合成キャンペーン"),"status":.text("draft"),"created_by":.text(actor)],actor:actor)
            let template = try f.db.insert("crm_campaign_templates",values:["name":.text("合成テンプレート"),"content_html":.text("<p>合成本文</p>"),"content_json":.text("{\"type\":\"doc\",\"content\":[]}"),"created_by":.text(actor)],actor:actor)
            let step = try f.db.insert("crm_campaign_steps",values:["campaign_id":campaign["id"],"order":.integer(0),"template_id":template["id"],"subject":.text("合成本文")],actor:actor)
            let target = try f.db.insert("crm_Targets",values:["last_name":.text("合成顧客"),"email":.text("recipient@example.invalid"),"created_by":.text(actor)],actor:actor)
            let send = try f.db.insert("crm_campaign_sends",values:["id":.text(id),"campaign_id":campaign["id"],"step_id":step["id"],"target_id":target["id"],"email":.text("recipient@example.invalid")],actor:actor)
            event = "campaigns/send-step"; payload = ["sendId":send["id"].string,"campaignId":campaign["id"].string]
            cancel = { try f.service.cancelCampaignMailJob(f.db.job(id:id)!,now:now) }
        default: throw NativeDBError.message("unknown fixture family")
        }
        _ = try f.db.enqueue(event,payload:payload,id:id,now:now)
        let body = try InvoiceMail.prepareText(root:root,id:id,from:"sender@example.invalid",to:"recipient@example.invalid",subject:"合成の送信本文",message:"保存の確定前に削除しない本文")
        return .init(fixture:f,id:id,file:body.url,bytes:try Data(contentsOf:body.url),cancel:cancel)
    }
    static func rollback(_ action: () throws -> Void, in db: NativeDatabase) throws {
        do { try db.transaction { try action(); throw Rollback.expected } }
        catch Rollback.expected { return }
        throw NativeDBError.message("fixture failed to roll back")
    }
    static func cancellation(_ family: String, resources: URL, root: URL) throws {
        let m = try queued(family,resources:resources,root:root)
        let db = m.fixture.db, before = try db.job(id:m.id)!
        try rollback(m.cancel,in:db)
        try check(try db.job(id:m.id) == before,"outer rollback exact job " + family)
        captureDifference(content(m.file) == m.bytes,"outer rollback body " + family)
        // A rolled-back nested cancellation must not run on the outer commit.
        if content(m.file) == nil { try m.bytes.write(to:m.file) }
        try db.transaction { try rollback(m.cancel,in:db) }
        try check(try db.job(id:m.id) == before,"inner rollback exact job " + family)
        captureDifference(content(m.file) == m.bytes,"inner rollback body " + family)
        if content(m.file) == nil { try m.bytes.write(to:m.file) }
        try db.transaction {
            try m.cancel()
            try check(try db.job(id:m.id)?.status == "cancelled","cancel state visible " + family)
            captureDifference(content(m.file) == m.bytes,"wait for outer commit " + family)
        }
        try check(content(m.file) == nil,"committed cancel releases body " + family)
        try check(try db.job(id:m.id)?.status == "cancelled","cancel result retained " + family)
    }
    static func review(_ family: String, outcome: MailReviewOutcome, resources: URL, root: URL) throws {
        let m = try queued(family,resources:resources,root:root), db = m.fixture.db
        let job = try db.job(id:m.id)!
        let claimed = try db.claimJob(events:[job.event],now:now)!
        let started = try db.markJobDeliveryStarted(claimed,now:now)
        try db.failJob(started,message:"synthetic uncertain send",needsReview:true)
        let expected = try db.job(id:m.id)!
        let providerID = outcome == .accepted ? UUID().uuidString.lowercased() : ""
        let action = {
            if family == "campaign" { try m.fixture.service.reviewCampaignMailJob(expected,outcome:outcome,providerID:providerID,note:"合成の確認記録",now:now) }
            else { try m.fixture.service.reviewMailJob(expected,outcome:outcome,providerID:providerID,note:"合成の確認記録",now:now) }
        }
        try rollback(action,in:db)
        try check(try db.job(id:m.id) == expected,"review rollback exact job")
        captureDifference(content(m.file) == m.bytes,"review rollback body " + family + ":" + outcome.rawValue)
        if content(m.file) == nil { try m.bytes.write(to:m.file) }
        try db.transaction {
            try action()
            captureDifference(content(m.file) == m.bytes,"review waits for outer commit " + family + ":" + outcome.rawValue)
        }
        try check(try db.job(id:m.id)?.status == "done","review terminal result retained")
        try check(content(m.file) == nil,"committed review releases body")
    }
    static func guards(resources: URL, root: URL) throws {
        let m = try queued("project",resources:resources,root:root), db = m.fixture.db
        try db.deferTerminalMailBodyCleanup(id:m.id)
        try check(content(m.file) == m.bytes,"pending retains payload")
        let claimed = try db.claimJob(events:["projects.task_assigned"],now:now)!
        try db.deferTerminalMailBodyCleanup(id:m.id)
        try check(content(m.file) == m.bytes,"running retains payload")
        let started = try db.markJobDeliveryStarted(claimed,now:now)
        try db.failJob(started,message:"uncertain",retryAt:now)
        try db.deferTerminalMailBodyCleanup(id:m.id)
        try check(content(m.file) == m.bytes,"uncertain retry retains payload")
        let unrelated = root.appendingPathComponent("mail-outbox/unrelated.json")
        let bytes = Data("other immutable file".utf8); try bytes.write(to:unrelated)
        let pdfID = try db.enqueue("invoice.pdf_requested",payload:[:],now:now)
        let pdfBody = try InvoiceMail.bodyURL(root:root,id:pdfID); try bytes.write(to:pdfBody)
        try db.transaction { try db.cancelJob(id:pdfID); try db.deferTerminalMailBodyCleanup(id:pdfID) }
        try check(content(pdfBody) == bytes,"non-mail job is not eligible")
        try check(content(unrelated) == bytes,"unrelated file remains")
        // Another outer-transaction callback can change a row before this one.
        let n = try queued("lead",resources:resources,root:root.appendingPathComponent("changed"))
        var changed = false
        try n.fixture.db.transaction {
            n.fixture.db.deferUntilTransactionEnds(onCommit:{
                var connection: OpaquePointer?
                guard sqlite3_open_v2(n.fixture.db.url.path,&connection,SQLITE_OPEN_READWRITE,nil) == SQLITE_OK, let connection else { return }
                defer { sqlite3_close(connection) }
                // Only a UUID generated for this isolated fixture is interpolated.
                changed = sqlite3_exec(connection,"UPDATE native_outbox SET result='{\"changed\":\"decision\"}' WHERE id='"+n.id+"'",nil,nil,nil) == SQLITE_OK
            },onRollback:{})
            try n.cancel()
        }
        try check(changed && (try n.fixture.db.job(id:n.id))?.result["changed"] == "decision","second connection changed terminal snapshot")
        try check(content(n.file) == n.bytes,"changed terminal snapshot retains payload")
        let readOnlyRoot = root.appendingPathComponent("readonly")
        let writableRoot = root.appendingPathComponent("readonly-source")
        let readOnlyID = UUID().uuidString.lowercased()
        let readOnlyFile = try InvoiceMail.bodyURL(root:readOnlyRoot,id:readOnlyID)
        do {
            let writable = try NativeDatabase(url:writableRoot.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            _ = try writable.enqueue("reports.scheduled",payload:[:],id:readOnlyID,now:now)
            try writable.cancelJob(id:readOnlyID)
            try FileManager.default.createDirectory(at:readOnlyFile.deletingLastPathComponent(),withIntermediateDirectories:true)
            try bytes.write(to:readOnlyFile)
        }
        // SQLite backup includes any committed WAL pages without relying on
        // deinit timing of notification callbacks retaining the source DB.
        var source: OpaquePointer?, destination: OpaquePointer?
        guard sqlite3_open_v2(writableRoot.appendingPathComponent("crm.sqlite").path,&source,SQLITE_OPEN_READONLY,nil) == SQLITE_OK,
              sqlite3_open_v2(readOnlyRoot.appendingPathComponent("crm.sqlite").path,&destination,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,nil) == SQLITE_OK,
              let source, let destination else { throw NativeDBError.message("readonly fixture open failed") }
        guard let backup = sqlite3_backup_init(destination,"main",source,"main") else { throw NativeDBError.message("readonly fixture backup init failed") }
        let copied = sqlite3_backup_step(backup,-1)
        let finished = sqlite3_backup_finish(backup)
        sqlite3_close(source); sqlite3_close(destination)
        try check(copied == SQLITE_DONE && finished == SQLITE_OK,"sealed fixture SQLite backup")
        let readonly = try NativeDatabase(readOnlyURL:readOnlyRoot.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"))
        var rejected = false
        do { try readonly.deferTerminalMailBodyCleanup(id:readOnlyID) } catch { rejected = true }
        try check(rejected,"readonly snapshot refuses terminal cleanup")
        try check(content(readOnlyFile) == bytes,"readonly snapshot payload unchanged")
    }
    static func main() async {
        do {
            let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = URL(fileURLWithPath:CommandLine.arguments[2])
            for family in ["order","project","crmTask","lead","campaign"] { try cancellation(family,resources:resources,root:root.appendingPathComponent(family)) }
            for family in ["project","campaign"] {
                for outcome: MailReviewOutcome in [.accepted,.notSent,.unknown] { try review(family,outcome:outcome,resources:resources,root:root.appendingPathComponent("review-" + family + "-" + outcome.rawValue)) }
            }
                    try guards(resources:resources,root:root.appendingPathComponent("guards"))
            try check(differences.isEmpty,"all transaction payload checks")
                    print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"differences":differences,"externalRequests":0],options:[.sortedKeys]),as:UTF8.self))
        } catch { fputs("Mail terminal cleanup: \(error)\n",stderr); exit(1) }
    }
}
