import Foundation
import SQLite3

extension InvoiceMailTests {
    static func jobReviewTests() throws {
        let initial = checks
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailReview-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open()
        func fixtureSQL(_ sql: String) throws {
            var handle: OpaquePointer?; guard sqlite3_open(db.url.path,&handle) == SQLITE_OK else { throw NativeDBError.message("fixture open") }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle,sql,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("fixture SQL: "+String(cString:sqlite3_errmsg(handle))) }
        }
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db:db,identity:identity)
        func user(_ name: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:"user",partnerAccountID:nil))
        }
        let owner = try user("owner"); let stranger = try user("stranger")
        let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("送信結果の検証会社"),"createdBy":.text(owner.identity.id),"assigned_to":.text(owner.identity.id)],actor:identity.id)
        let series = try admin.saveInvoiceSeries(original:nil,input:["name":.text("標準"),"prefixTemplate":.text("CHK-{YYYY}-{####}")])
        _ = try admin.saveInvoiceSettings(original:nil,input:["companyName":.text("架空会社"),"companyAddress":.text("架空1-1"),"companyCity":.text("東京都"),"companyZip":.text("100-0000"),"companyCountry":.text("日本"),"companyRegNo":.text("1234567890123"),"baseCurrency":.text("JPY"),"defaultDueDays":.integer(14),"defaultSeriesId":series["id"]])
        func issue() throws -> NativeRecord {
            let draft = try owner.saveInvoice(original:nil,header:["accountId":account["id"],"currency":.text("JPY")],lines:{ $0 == 0 ? [.init(productID:nil,description:"検証用",quantity:"1",unitPrice:"1000",discountPercent:"0",taxRateID:nil)] : [] })
            let issued = try owner.issueInvoice(draft); _ = try owner.generateInvoicePDF(issued)
            return try db.get("Invoices",key:["id":issued["id"]])!
        }
        var invoice = try issue()
        func refresh() throws -> NativeRecord { try db.get("Invoices",key:["id":invoice["id"]])! }
        let now = Date(timeIntervalSince1970:1_800_000_000)
        func queued() throws -> String { try owner.queueInvoiceEmail(refresh(),from:"sender@example.invalid",to:"recipient@example.invalid",subject:"日本語請求書",message:"確認用です",now:now) }
        func ambiguous(receipt: String? = nil, started: Bool = true, review: Bool = true) throws -> NativeJob {
            let id = try queued(); var claimed = try db.claimJob(events:["invoice.email_requested"],now:now)!
            try check(claimed.id == id,"review fixture claims its intended queued mail")
            if started { claimed = try db.markJobDeliveryStarted(claimed,now:now) }
            if let receipt { try db.recordJobResult(claimed,result:["providerID":receipt]) }
            try db.failJob(claimed,message:"送信サービスの結果が不明です",needsReview:review)
            return try db.job(id:id)!
        }
        func bodyExists(_ job: NativeJob) throws -> Bool { FileManager.default.fileExists(atPath:try InvoiceMail.bodyURL(root:root,id:job.id).path) }
        func resolve(_ job: NativeJob, _ outcome: MailReviewOutcome = .unknown, receipt: String = "", service: CRMService? = nil) throws {
            try (service ?? owner).reviewMailJob(job,outcome:outcome,providerID:receipt,note:"管理画面で処理ID・宛先・件名を確認しました。",now:now.addingTimeInterval(25*3600))
        }
        let unknown = try ambiguous(); let before = try refresh()
        try rejects("unrelated user cannot review mail") { try resolve(unknown,service:stranger) }
        try rejects("empty review evidence rejected") { try owner.reviewMailJob(unknown,outcome:.unknown,providerID:"",note:" \n ") }
        try rejects("oversized review evidence rejected") { try owner.reviewMailJob(unknown,outcome:.unknown,providerID:"",note:String(repeating:"日",count:2001)) }
        try rejects("accepted review needs canonical receipt") { try resolve(unknown,.accepted,receipt:"invalid") }
        try rejects("receipt contradicts unsent choice") { try resolve(unknown,.notSent,receipt:UUID().uuidString) }
        try check(try db.job(id:unknown.id) == unknown && bodyExists(unknown),"rejected reviews preserve job and attachment")
        try resolve(unknown)
        let closedUnknown = try second.job(id:unknown.id)!
        try check(closedUnknown.status == "done" && closedUnknown.result["outcome"] == "unconfirmed" && closedUnknown.result["reviewedBy"] == owner.identity.id,"unknown is explicitly recorded, not represented as sent")
        try check(try refresh().revision == before.revision && refresh()["status"] == .text("ISSUED"),"unknown review does not mutate invoice")
        try check(closedUnknown.payload == unknown.payload && closedUnknown.attempts == unknown.attempts && closedUnknown.deliveryStartedAt == unknown.deliveryStartedAt,"review preserves immutable body hash, attempt count and delivery clock")
        try check(closedUnknown.result["reviewPreviousError"] == unknown.lastError && !bodyExists(unknown),"review keeps prior failure evidence and releases attachment after commit")
        try rejects("review cannot replay or overwrite previous decision") { try resolve(unknown) }
        try rejects("reviewed unknown cannot be retried") { try owner.retryInvoiceJob(unknown.id) }

        let notSent = try ambiguous(); try resolve(notSent,.notSent)
        try check(try second.job(id:notSent.id)?.result["outcome"] == "not_sent" && refresh()["status"] == .text("ISSUED"),"confirmed unsent preserves issued state")
        let noStart = try ambiguous(started:false,review:false)
        try rejects("never-started failure uses ordinary cancel, not review") { try resolve(noStart) }
        try owner.cancelInvoiceJob(noStart.id)
        let pendingID = try queued(); let pending = try db.job(id:pendingID)!
        try rejects("pending mail cannot be reviewed") { try resolve(pending) }
        let running = try db.markJobDeliveryStarted(db.claimJob(events:["invoice.email_requested"],now:now)!,now:now)
        try rejects("running mail cannot be reviewed") { try resolve(running) }
        try db.failJob(running,message:"停止後に確認",needsReview:true); try resolve(db.job(id:pendingID)!)

        let accepted = try ambiguous(); let receipt = UUID().uuidString
        try resolve(accepted,.accepted,receipt:receipt)
        try check(try refresh()["status"] == .text("SENT") && second.job(id:accepted.id)?.result["providerID"] == receipt.lowercased(),"confirmed receipt atomically marks issued invoice sent")
        let activities = try owner.invoiceRows(refresh(),model:"Invoice_Activity").rows.filter { $0["action"] == .text("EMAIL_REVIEWED") }
        try check(activities.count == 4 && activities.contains { $0["meta"].string.contains(accepted.id) },"one review activity per confirmed decision")
        let reused = try ambiguous()
        try rejects("receipt from another job cannot be reused") { try resolve(reused,.accepted,receipt:receipt) }
        try resolve(reused)
        let storedReceipt = UUID().uuidString.lowercased(); let stored = try ambiguous(receipt:storedReceipt)
        try rejects("known acceptance cannot be marked unsent") { try resolve(stored,.notSent) }
        try rejects("known acceptance cannot be marked unknown") { try resolve(stored) }
        try rejects("known receipt cannot be replaced") { try resolve(stored,.accepted,receipt:UUID().uuidString) }
        try resolve(stored,.accepted,receipt:storedReceipt)

        let stale = try ambiguous()
        try fixtureSQL("UPDATE native_outbox SET last_error='別の処理から結果を更新' WHERE id='\(stale.id)'")
        try rejects("stale displayed result cannot overwrite newer state") { try resolve(stale) }
        try resolve(db.job(id:stale.id)!)
        let revoked = try ambiguous(); var userRow = try db.get("Users",key:["id":.text(owner.identity.id)])!
        userRow = try db.update(userRow,changes:["banned":.integer(1)],actor:identity.id)
        try rejects("revoked reviewer cannot finalize mail") { try resolve(revoked) }
        _ = try db.update(userRow,changes:["banned":.integer(0)],actor:identity.id); try resolve(revoked)

        invoice = try issue(); let rollback = try ambiguous(); let unchanged = try refresh()
        try fixtureSQL("CREATE TRIGGER review_test_abort BEFORE INSERT ON Invoice_Activity WHEN NEW.action='EMAIL_REVIEWED' BEGIN SELECT RAISE(ABORT,'fixture abort'); END")
        try rejects("domain audit failure rolls back whole review") { try resolve(rollback,.accepted,receipt:UUID().uuidString) }
        try check(try db.job(id:rollback.id) == rollback && refresh().revision == unchanged.revision && bodyExists(rollback),"failed commit preserves invoice, job and attachment")
        try fixtureSQL("DROP TRIGGER review_test_abort")
        _ = try admin.addInvoicePayment(refresh(),amount:"1000",paidAt:now,method:"Bank Transfer")
        try resolve(rollback,.accepted,receipt:UUID().uuidString)
        try check(try refresh()["status"] == .text("PAID"),"review preserves payment committed while result was unknown")

        invoice = try issue(); let cancelled = try ambiguous()
        // Imported history can contain cancelled issued invoices even though
        // the native cancellation action is restricted to drafts.
        _ = try db.update(refresh(),changes:["status":.text("CANCELLED")],actor:identity.id,action:"historical_fixture")
        try resolve(cancelled,.accepted,receipt:UUID().uuidString)
        try check(try refresh()["status"] == .text("CANCELLED"),"historical acceptance can be reviewed without reverting cancellation")

        let order = try owner.saveOrder(original:nil,accountID:account["id"].string,header:[:],lines:{ _ in [] },submit:false)
        func orderJob() throws -> NativeJob {
            let id = try db.enqueue("orders.approval_decided",payload:["orderId":order["id"].string,"recipientId":owner.identity.id,"decision":"APPROVED"])
            let job = try db.markJobDeliveryStarted(db.claimJob(events:CRMService.orderJobEvents)!)
            try db.failJob(job,message:"応答なし",needsReview:true); return try db.job(id:id)!
        }
        let notice = try orderJob()
        try rejects("unrelated recipient cannot resolve order notification") { try resolve(notice,service:stranger) }
        try resolve(notice,.notSent)
        let elevated = try orderJob(); try resolve(elevated,.accepted,receipt:UUID().uuidString,service:admin)
        try check(try db.get("crm_Orders",key:["id":order["id"]])?.revision == order.revision,"reviewing notices never approves or changes the order")
        try check(try second.job(id:elevated.id)?.result["reviewedBy"] == admin.identity.id,"admin may record result for another recipient")
        try check(try db.nextJobDate(events:["invoice.email_requested"]+CRMService.orderJobEvents) == nil,"review never requeues external mail")
        try check(try db.integrityCheck(),"review suite preserves SQLite integrity")
        print("Mail review: \(checks-initial) checks passed; no external requests")
    }
}
