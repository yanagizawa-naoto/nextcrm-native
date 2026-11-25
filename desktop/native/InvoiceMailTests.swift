import Foundation
import SQLite3

@main enum InvoiceMailTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label)
    }
    static func main() async {
        do {
            if CommandLine.arguments.contains("--keychain-probe") { try keychainProbe(); print("Keychain probe: \(checks) checks passed; temporary fake credential removed") }
            else if CommandLine.arguments.contains("--order-mail-ui-fixture") { try prepareOrderMailUI() }
            else { try await run(); try await orderMailTests(); try jobReviewTests(); try await projectMailTests(); try await crmTaskMailTests(); print("Invoice mail/jobs: \(checks) checks passed (fake transport only)") }
        }
        catch { FileHandle.standardError.write(Data("InvoiceMailTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-InvoiceMailTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let databaseURL = root.appendingPathComponent("crm.sqlite")
        var raw: OpaquePointer?
        guard sqlite3_open(databaseURL.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test sqlite open") }
        let oldSQL = "CREATE TABLE native_outbox(id TEXT PRIMARY KEY NOT NULL,event TEXT NOT NULL,payload TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,next_run_at TEXT,last_error TEXT); INSERT INTO native_outbox(id,event,payload,created_at) VALUES('legacy','order.notification','{}','2026-01-01T00:00:00Z');"
        guard sqlite3_exec(raw,oldSQL,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("legacy schema setup") }; sqlite3_close(raw)
        func open() throws -> NativeDatabase { try NativeDatabase(url:databaseURL,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open()
        try check(try db.job(id:"legacy")?.status == "pending","old outbox migration preserves rows; reopening is idempotent")
        var now = Date(timeIntervalSince1970:1_800_000_000.25)
        let id = try db.enqueue("test.work",payload:["value":"日本語"],now:now)
        let first = try db.claimJob(events:["test.work"],now:now,leaseSeconds:10)!
        try check(first.id == id && first.attempts == 1 && first.firstAttemptAt == now,"claim records attempt and timestamp")
        try check(try second.claimJob(events:["test.work"],now:now.addingTimeInterval(9)) == nil,"separate connection cannot claim live lease")
        let reclaimed = try second.claimJob(events:["test.work"],now:now.addingTimeInterval(11))!
        try check(reclaimed.leaseToken != first.leaseToken && reclaimed.attempts == 2,"restart reclaims expired lease with new token")
        try rejects("old worker fenced") { try db.finishJob(first) }
        try rejects("transaction rollback") { try db.transaction { try db.finishJob(reclaimed); throw NativeDBError.message("rollback") } }
        try check(try db.job(id:id)?.status == "running","completion rollback preserves lease")
        try second.failJob(reclaimed,message:"retry",retryAt:now.addingTimeInterval(60))
        try check(try db.claimJob(events:["test.work"],now:now.addingTimeInterval(59)) == nil,"scheduled retry not early")
        let retried = try db.claimJob(events:["test.work"],now:now.addingTimeInterval(61))!
        try db.finishJob(retried,result:["value":"ok"])
        try check(try second.job(id:id)?.result["value"] == "ok","durable result visible to reopened connection")
        let cancel = try db.enqueue("test.work",payload:[:]); try db.cancelJob(id:cancel)
        try check(try db.job(id:cancel)?.status == "cancelled","unsent pending work cancellable")
        let delivery = try db.enqueue("test.delivery",payload:[:])
        let sending = try db.markJobDeliveryStarted(db.claimJob(events:["test.delivery"],now:now)!,now:now)
        try db.failJob(sending,message:"unknown")
        try rejects("unknown sent work cannot cancel") { try db.cancelJob(id:delivery) }
        try rejects("dedupe expiry blocks manual retry") { try db.retryJob(id:delivery,now:now.addingTimeInterval(23*3600)) }
        try rejects("clock rollback blocks manual retry") { try db.retryJob(id:delivery,now:now.addingTimeInterval(-1)) }

        // Exercise Base64 boundaries independently of PDF rendering and compare
        // exact decoded bytes, not the implementation's intermediate chunks.
        for count in [1,2,3,49151,49152,49153,200003] {
            let source = root.appendingPathComponent("source.pdf")
            let bytes = Data((0..<count).map { UInt8($0%251) }); try bytes.write(to:source)
            let body = try InvoiceMail.prepare(root:root,id:UUID().uuidString,from:"sender@example.invalid",to:"recipient@example.invalid",subject:"日本語の件名",message:"<script>&\n本文",number:"日/本\\語",pdf:source)
            let json = try JSONSerialization.jsonObject(with:Data(contentsOf:body.url)) as! [String:Any]
            let attachment = (json["attachments"] as! [[String:String]])[0]
            try check(Data(base64Encoded:attachment["content"]!) == bytes,"PDF exact round trip \(count)")
            try check((json["html"] as! String).contains("&lt;script&gt;&amp;<br>"),"HTML escaped")
            try check(attachment["filename"] == "invoice-日_本_語.pdf","safe filename")
            try check((try FileManager.default.attributesOfItem(atPath:body.url.path)[.posixPermissions] as! NSNumber).intValue == 0o600,"private body")
            try InvoiceMail.verify(body.url,sha256:body.sha256,bytes:body.bytes)
            var modified = try Data(contentsOf:body.url); modified[0] ^= 1; try modified.write(to:body.url)
            try rejects("same size tamper detected") { try InvoiceMail.verify(body.url,sha256:body.sha256,bytes:body.bytes) }
            try FileManager.default.removeItem(at:body.url)
        }
        try rejects("multiple recipients rejected") { _ = try InvoiceMail.mailbox("a@example.invalid,b@example.invalid") }
        try rejects("header injection rejected") { _ = try InvoiceMail.mailbox("a@example.invalid\r\nBcc:x@example.invalid") }
        let unicode = "日本語😀e\u{301}\"'\\\t\r\u{0}\u{1f}\n<&>"
        let longMessage = String(repeating:unicode,count:12000)
        let longBody = try InvoiceMail.prepare(root:root,id:UUID().uuidString,from:"sender@example.invalid",to:"recipient@example.invalid",subject:"長い本文",message:longMessage,number:"123",pdf:root.appendingPathComponent("source.pdf"))
        let longJSON = try JSONSerialization.jsonObject(with:Data(contentsOf:longBody.url)) as! [String:Any]
        let expected = longMessage.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;").replacingOccurrences(of:"\n",with:"<br>\n")
        try check((longJSON["html"] as! String).contains("</h1><p>"+expected+"</p><hr>"),"streamed HTML/JSON preserves Unicode and control characters across buffer boundaries")
        try InvoiceMail.verify(longBody.url,sha256:longBody.sha256,bytes:longBody.bytes)
        let oversizeID = UUID().uuidString
        try rejects("expanded HTML exceeding encoded limit rejected") { _ = try InvoiceMail.prepare(root:root,id:oversizeID,from:"sender@example.invalid",to:"recipient@example.invalid",subject:"大きい本文",message:String(repeating:"&",count:8_000_001),number:"123",pdf:root.appendingPathComponent("source.pdf")) }
        try check(!FileManager.default.fileExists(atPath:try InvoiceMail.bodyURL(root:root,id:oversizeID).path),"partial oversize output cleaned")
        let fakeBody = root.appendingPathComponent("fake.json"); try Data("{}".utf8).write(to:fakeBody)
        let providerID = UUID().uuidString.lowercased()
        for (status,name,retry,review) in [(400,"validation_error",false,false),(401,"",false,false),(403,"",false,false),(429,"",true,false),(500,"",true,false),(409,"concurrent_idempotent_requests",true,false),(409,"invalid_idempotent_request",false,true),(302,"",false,false),(413,"",false,false)] {
            do {
                _ = try await ResendMailClient.send(body:fakeBody,jobID:UUID().uuidString,apiKey:"fake-key",request:{ request,_ in
                    let data = try JSONSerialization.data(withJSONObject:["name":name,"message":"SECRET MUST NOT PERSIST"])
                    return (data,HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Retry-After":"12"])!)
                })
                throw NativeDBError.message("unexpected send success")
            } catch let error as MailSendError {
                try check(error.retryable == retry && error.review == review,"HTTP \(status) \(name) classification")
                try check(!error.message.contains("SECRET"),"server response not exposed")
            }
        }
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db:db,identity:identity)
        let user = try db.insert("Users",values:["name":.text("請求担当"),"email":.text("owner@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let owner = CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil))
        try credentialTests(admin:admin,owner:owner)
        let outsider = try db.insert("Users",values:["name":.text("別の担当"),"email":.text("other@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let other = CRMService(db:db,identity:CRMIdentity(id:outsider["id"].string,role:"user",partnerAccountID:nil))
        let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("日本語取引先"),"email":.text("customer@example.invalid"),"createdBy":user["id"]],actor:identity.id)
        let series = try admin.saveInvoiceSeries(original:nil,input:["name":.text("標準"),"prefixTemplate":.text("INV-{YYYY}-{####}")])
        _ = try admin.saveInvoiceSettings(original:nil,input:["companyName":.text("架空の会社"),"companyAddress":.text("丸の内1-1-1"),"companyCity":.text("東京都千代田区"),"companyZip":.text("100-0000"),"companyCountry":.text("日本"),"companyRegNo":.text("1234567890123"),"baseCurrency":.text("JPY"),"defaultDueDays":.integer(14),"defaultSeriesId":series["id"]])
        var invoice = try owner.saveInvoice(original:nil,header:["accountId":account["id"],"currency":.text("JPY")],lines:{ offset in offset == 0 ? [.init(productID:nil,description:"日本語の商品",quantity:"1",unitPrice:"1000",discountPercent:"0",taxRateID:nil)] : [] })
        func refresh() throws -> NativeRecord { try db.get("Invoices",key:["id":invoice["id"]])! }
        try rejects("draft email denied") { _ = try owner.queueInvoiceEmail(invoice,from:"a@example.invalid",to:"b@example.invalid",subject:"請求",message:"本文") }
        invoice = try owner.issueInvoice(invoice)
        var calls = 0; var keys: [String] = []; var bodies: [Data] = []; var responseCode = 200
        var duringSend: (() throws -> Void)?
        var currentKey = "fake-key-never-network"
        let worker = InvoiceJobWorker(db:db,apiKey:{ currentKey },request:{ request,url in
            calls += 1; keys.append(request.value(forHTTPHeaderField:"Idempotency-Key")!); bodies.append(try Data(contentsOf:url))
            try duringSend?()
            let data = try JSONSerialization.data(withJSONObject:responseCode == 200 ? ["id":providerID] : ["name":"internal_error"])
            return (data,HTTPURLResponse(url:request.url!,statusCode:responseCode,httpVersion:nil,headerFields:nil)!)
        },clock:{ now })
        let pdfWorked = try await worker.runNext(); try check(pdfWorked && calls == 0,"PDF job generates without external transport")
        invoice = try refresh(); try check(invoice["pdfStorageKey"] != .null,"PDF job publishes document")
        try check(try db.job(id:"legacy")?.status == "pending","worker does not claim unsupported events")
        let defaults = try owner.invoiceEmailDefaults(invoice)
        try check(defaults.to == "customer@example.invalid" && defaults.message.contains("日本語取引先"),"Japanese defaults use recipient")
        func enqueue(_ service: CRMService = owner) throws -> String { try service.queueInvoiceEmail(refresh(),from:"billing@example.invalid",to:defaults.to,subject:defaults.subject,message:defaults.message,now:now) }
        try rejects("other owner cannot enqueue") { _ = try enqueue(other) }
        let jobID = try enqueue()
        try rejects("other owner cannot inspect jobs") { _ = try other.invoiceJobs(refresh()) }
        try rejects("other owner cannot cancel") { try other.cancelInvoiceJob(jobID) }
        try check(try owner.invoiceJobs(refresh()).contains { $0.id == jobID },"owner sees own invoice queue")
        _ = try await worker.runNext()
        try check(calls == 1 && keys[0] == "nextcrm/invoice/"+jobID,"send uses stable idempotency key")
        try check(try refresh()["status"] == .text("SENT") && db.job(id:jobID)?.status == "done","success atomically marks invoice sent and job done")
        try check(try db.job(id:jobID)?.result["providerID"] == providerID,"provider receipt preserved")
        try check(!FileManager.default.fileExists(atPath:try InvoiceMail.bodyURL(root:root,id:jobID).path),"completed attachment body cleaned")
        let activityCount = try owner.invoiceRows(refresh(),model:"Invoice_Activity").total
        let noWork = try await worker.runNext(); try check(!noWork && calls == 1,"completed job not replayed")
        try check(try owner.invoiceRows(refresh(),model:"Invoice_Activity").total == activityCount,"no duplicate history")

        responseCode = 500; let retryID = try enqueue(); _ = try await worker.runNext()
        try check(try db.job(id:retryID)?.status == "retry","transient failure persisted for retry")
        let tooEarly = try await worker.runNext(); try check(!tooEarly && calls == 2,"backoff enforced")
        // Changing the source PDF cannot change an already queued message.
        _ = try owner.generateInvoicePDF(refresh()); now = now.addingTimeInterval(10); responseCode = 200
        _ = try await worker.runNext()
        try check(calls == 3 && keys[1] == keys[2] && bodies[1] == bodies[2],"retry reuses exact body/key after PDF regeneration")
        try check(try db.job(id:retryID)?.status == "done","retry completes")

        let expiredID = try enqueue(); responseCode = 500; _ = try await worker.runNext(); let beforeExpiry = calls
        now = now.addingTimeInterval(23*3600); _ = try await worker.runNext()
        try check(calls == beforeExpiry && (try db.job(id:expiredID)?.status) == "needs_review","expired unknown outcome never automatically resent")
        responseCode = 200
        let revokedID = try enqueue()
        var currentUser = try db.get("Users",key:["id":user["id"]])!
        currentUser = try db.update(currentUser,changes:["banned":.integer(1)],actor:identity.id)
        _ = try await worker.runNext()
        try check(calls == beforeExpiry && (try db.job(id:revokedID)?.status) == "failed","revoked actor cannot send queued mail")
        _ = try db.update(currentUser,changes:["banned":.integer(0)],actor:identity.id)
        try owner.cancelInvoiceJob(revokedID)

        // An accepted receipt survives process loss and the dedupe deadline.
        let receiptID = try enqueue()
        let accepted = try db.claimJob(events:["invoice.email_requested"],now:now)!
        _ = try db.markJobDeliveryStarted(accepted,now:now)
        try db.recordJobResult(accepted,result:["providerID":providerID])
        now = now.addingTimeInterval(25*3600)
        let restarted = InvoiceJobWorker(db:second,apiKey:{ throw NativeDBError.message("must not read key") },request:{ _,_ in throw NativeDBError.message("must not send") },clock:{ now })
        _ = try await restarted.runNext()
        try check(try db.job(id:receiptID)?.status == "done","durable receipt completes after restart/deadline without sending")

        // A payment committed while sending must not be reverted to SENT.
        let concurrentID = try enqueue()
        duringSend = { _ = try admin.addInvoicePayment(refresh(),amount:"1000",paidAt:now,method:"Bank Transfer") }
        _ = try await worker.runNext(); duringSend = nil
        try check(try refresh()["status"] == .text("PAID") && db.job(id:concurrentID)?.status == "done","concurrent payment preserved on send completion")
        let events = try owner.invoiceRows(refresh(),model:"Invoice_Activity").rows
        try check(events.contains { $0["action"] == .text("SENT") } && events.contains { $0["action"] == .text("EMAIL_SENT") },"original sent/email-sent activity semantics preserved")
        // Poisoned jobs fail individually rather than preventing later claims.
        let malformed = try db.enqueue("invoice.email_requested",payload:[:]); _ = try await worker.runNext()
        try check(try db.job(id:malformed)?.status == "failed","malformed job isolated")
        let changedKeyID = try enqueue(); responseCode = 500; _ = try await worker.runNext()
        let beforeKeyChange = calls; currentKey = "another-account-key"; now = now.addingTimeInterval(30)
        _ = try await worker.runNext()
        try check(calls == beforeKeyChange && (try db.job(id:changedKeyID)?.status) == "needs_review","credential change cannot bypass provider deduplication")
        responseCode = 200
        let revokedDuringID = try enqueue()
        duringSend = {
            let latestUser = try db.get("Users",key:["id":user["id"]])!
            _ = try db.update(latestUser,changes:["banned":.integer(1)],actor:identity.id)
        }
        _ = try await worker.runNext(); duringSend = nil
        try check(try db.job(id:revokedDuringID)?.status == "done","accepted send still recorded if actor revoked during request")
        try await runnerTests(service:admin,invoice:refresh())
    }
}
