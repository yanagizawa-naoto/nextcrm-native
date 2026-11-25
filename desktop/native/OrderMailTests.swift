import Foundation
import SQLite3

extension InvoiceMailTests {
    static func prepareOrderMailUI() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        guard let index = CommandLine.arguments.firstIndex(of:"--order-mail-ui-fixture"), CommandLine.arguments.count > index+1 else { throw NativeDBError.message("検証先を指定してください。") }
        let root = URL(fileURLWithPath:CommandLine.arguments[index+1]).resolvingSymlinksInPath().standardizedFileURL
        let allowed = resources.appendingPathComponent("../artifacts/native-order-mail-ui-20261114-v1").standardizedFileURL
        guard root == allowed, (try? String(contentsOf:root.appendingPathComponent(".native-mail-test"),encoding:.utf8)) == "NextCRM isolated mail QA\n" else { throw NativeDBError.message("受注メールの専用検証先を指定してください。") }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let output = try db.transaction { () -> [[String:String]] in
            guard try db.page("Users",fields:[],equal:["email":.text("order-mail-ui@example.invalid")]).total == 0 else { throw NativeDBError.message("受注メール検証データは作成済みです。") }
            let user = try db.insert("Users",values:["name":.text("受注通知の検証担当"),"email":.text("order-mail-ui@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
            let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("受注通知検証株式会社"),"assigned_to":user["id"]],actor:identity.id)
            guard let product = try db.page("crm_Products",fields:[],equal:["sku":.text("JP-CRM-SETUP"),"status":.text("ACTIVE")]).rows.first else { throw NativeDBError.message("検証用の商品がありません。") }
            let service = CRMService(db:db,identity:CRMIdentity(id:user["id"].string,role:"user",partnerAccountID:nil))
            return try ["承認メールの画面確認","却下メールの画面確認"].map { note in
                let order = try service.saveOrder(original:nil,accountID:account["id"].string,header:["note":.text(note)],lines:{ $0 == 0 ? [.init(productID:product["id"].string,quantity:"1",unitPrice:"1.01")] : [] },submit:true)
                return ["id":order["id"].string,"number":order["number"].string,"scenario":note]
            }
        }
        print(String(decoding:try JSONEncoder().encode(output),as:UTF8.self))
    }
    static func orderMailTests() async throws {
        let initialChecks = checks
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-OrderMail-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open()
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db:db,identity:identity)
        func user(_ role: String, _ email: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text("通知検証"),"email":.text(email),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:role,partnerAccountID:nil))
        }
        let owner = try user("user","owner@example.invalid"); let manager = try user("manager","manager@example.invalid")
        let stranger = try user("user","stranger@example.invalid")
        let customer = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("架空の受注会社"),"assigned_to":.text(owner.identity.id)],actor:identity.id)
        let product = try admin.save(.find("crm_Products")!,original:nil,input:["type":.text("PRODUCT"),"name":.text("架空の商品"),"unit_price":.text("100"),"tax_rate":.text("10"),"currency":.text("JPY"),"status":.text("ACTIVE")])
        var now = Date(timeIntervalSince1970:1_800_000_000.25)
        func create(submit: Bool = true) throws -> NativeRecord {
            try owner.saveOrder(original:nil,accountID:customer["id"].string,header:[:],lines:{ $0 == 0 ? [.init(productID:product["id"].string,quantity:"1",unitPrice:"80")] : [] },submit:submit,now:now)
        }
        func refresh(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        func updateUser(_ service: CRMService, _ changes: [String:SQLValue]) throws {
            _ = try db.update(db.get("Users",key:["id":.text(service.identity.id)])!,changes:changes,actor:identity.id)
        }
        func sql(_ value: String) throws {
            var raw: OpaquePointer?; guard sqlite3_open(db.url.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test SQL open") }; defer { sqlite3_close(raw) }
            guard sqlite3_exec(raw,value,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test SQL failure") }
        }
        var account = InvoiceMailAccount(from:"notifications@example.invalid",apiKey:"fake-order-key")
        var settingsAvailable = true; var code = 200; var retryAfter: String?; var calls = 0
        var keys: [String] = []; var bodies: [Data] = []; var duringSend: (() async throws -> Void)?
        let providerID = UUID().uuidString.lowercased()
        let request: ResendMailClient.Request = { query,file in
            calls += 1; keys.append(query.value(forHTTPHeaderField:"Idempotency-Key")!); bodies.append(try Data(contentsOf:file))
            try await duringSend?()
            return (try JSONSerialization.data(withJSONObject:code == 200 ? ["id":providerID] : ["name":"fake_error"]),HTTPURLResponse(url:query.url!,statusCode:code,httpVersion:nil,headerFields:retryAfter.map { ["Retry-After":$0] })!)
        }
        func worker(_ database: NativeDatabase = db) -> OrderMailWorker {
            OrderMailWorker(db:database,account:{ guard settingsAvailable else { throw NativeDBError.message("検証用の設定未登録") }; return account },request:request,clock:{ now })
        }
        let first = worker()
        func drain(_ worker: OrderMailWorker = first) async throws {
            var count = 0
            while try await worker.runNext() { count += 1; if count > 200 { throw NativeDBError.message("test worker did not settle") } }
        }
        var order = try create()
        try deepLinkTests(admin:admin,owner:owner,stranger:stranger,order:order)
        let requests = try admin.orderJobs(order)
        try check(requests.count == 2 && Set(requests.map { $0.payload["recipientId"]! }) == [identity.id,manager.identity.id],"workflow queues each active admin/manager")
        try check(requests.allSatisfy { $0.payload["actorId"] == owner.identity.id && $0.payload["recipientEmail"] != nil },"new events snapshot actor and recipient")
        try check(try owner.orderJobs(order).isEmpty,"creator cannot inspect approver addresses")
        try rejects("unrelated user cannot inspect notification history") { _ = try stranger.orderJobs(order) }
        try await drain()
        try check(calls == 2 && requests.allSatisfy { try db.job(id:$0.id)?.result["outcome"] == "sent" },"request notices delivered once through fake transport")
        let body = try JSONSerialization.jsonObject(with:bodies[0]) as! [String:Any]
        try check((body["subject"] as? String)?.contains("承認依頼") == true && (body["text"] as? String)?.contains("価格表を下回る") == true && body["attachments"] == nil,"Japanese plain notification without attachment")
        try check((body["text"] as! String).contains(try NativeDeepLink(orderID:order["id"].string).string),"approval mail contains native order link")
        try check(keys.allSatisfy { $0.hasPrefix("nextcrm/order/") },"order idempotency namespace")
        try check(try refresh(order)["status"] == .text("PENDING_APPROVAL"),"notification delivery does not change order state")
        try check(requests.allSatisfy { !FileManager.default.fileExists(atPath:try InvoiceMail.bodyURL(root:root,id:$0.id).path) },"accepted body files removed")

        let note = "条件付きで承認します。\n日本語😀e\u{301} <&> \\\""
        order = try manager.changeOrder(order,action:"approve",note:note,now:now)
        let decision = try owner.orderJobs(order).first!
        try check(decision.payload["recipientId"] == owner.identity.id && decision.payload["decision"] == "APPROVED","approval result addressed to creator")
        code = 503; retryAfter = "20"; let beforeRetry = calls
        try await drain()
        try check(try db.job(id:decision.id)?.status == "retry" && calls == beforeRetry+1,"transient order failure schedules retry")
        try check(try db.nextJobDate(events:CRMService.orderJobEvents)!.timeIntervalSince(now) >= 19,"provider retry-after honored")
        let frozenBody = bodies.last!; let frozenKey = keys.last!
        let frozenJSON = try JSONSerialization.jsonObject(with:frozenBody) as! [String:Any]
        try check((frozenJSON["text"] as! String).contains(note),"approval note preserves Japanese, newline and punctuation")
        try check((frozenJSON["text"] as! String).contains(try NativeDeepLink(orderID:order["id"].string).string),"decision mail contains same record link")
        try check(try (FileManager.default.attributesOfItem(atPath:InvoiceMail.bodyURL(root:root,id:decision.id).path)[.posixPermissions] as! NSNumber).intValue == 0o600,"private notification body")
        code = 200; retryAfter = nil; now.addTimeInterval(21)
        account = .init(from:"changed-sender@example.invalid",apiKey:account.apiKey)
        try await drain(worker(second))
        try check(try db.job(id:decision.id)?.status == "done" && db.job(id:decision.id)?.attempts == 2,"separate connection resumes persisted notification")
        try check(bodies.last == frozenBody && keys.last == frozenKey,"retry keeps original sender and exact body/key after settings change")
        try check(try refresh(order)["status"] == .text("READY"),"result delivery preserves order workflow state")

        // The pre-worker schema had only these five payload fields, without an actor.
        let legacy: [String:String] = ["orderId":order["id"].string,"number":order["number"].string,"recipientId":owner.identity.id,"decision":"REJECTED","note":"以前の却下理由\n再申請をお願いします。"]
        func enqueue(_ payload: [String:String] = legacy, _ event: String = "orders.approval_decided") throws -> String { try db.enqueue(event,payload:payload,now:now) }
        let old = try enqueue(); try await drain()
        try check(try db.job(id:old)?.status == "done","legacy queued payload remains deliverable without actorId")
        try check((try JSONSerialization.jsonObject(with:bodies.last!) as! [String:Any])["subject"] as? String == "受注 \(order["number"].string) が却下されました","legacy rejection localized")

        // A prior version may already have frozen a body without a link. An
        // upgrade must deliver those exact bytes, preserving provider deduplication.
        let oldBodyID = try enqueue(); let oldClaim = try db.claimJob(events:CRMService.orderJobEvents,now:now)!
        try check(oldClaim.id == oldBodyID,"legacy frozen-body fixture claimed")
        let oldBody = try InvoiceMail.prepareText(root:root,id:oldBodyID,from:"previous@example.invalid",to:"owner@example.invalid",subject:"旧版の通知",message:"以前の通知本文・リンクなし")
        let oldBytes = try Data(contentsOf:oldBody.url)
        try db.recordJobResult(oldClaim,result:["from":"previous@example.invalid","to":"owner@example.invalid","subject":"旧版の通知","sha256":oldBody.sha256,"bytes":String(oldBody.bytes)])
        try db.failJob(oldClaim,message:"before first request",retryAt:now)
        try await drain(worker(second))
        try check(try db.job(id:oldBodyID)?.status == "done" && db.job(id:oldBodyID)?.result["orderLink"] == nil && bodies.last == oldBytes,"upgrade keeps frozen legacy content instead of appending link")

        let bad = try enqueue(legacy.merging(["decision":"UNKNOWN"]) { _,n in n }); let oldCalls = calls; try await drain()
        try check(try db.job(id:bad)?.status == "failed" && calls == oldCalls,"invalid decision never contacts provider")
        let noSettings = try enqueue(); settingsAvailable = false; try await drain()
        try check(try db.job(id:noSettings)?.status == "failed" && db.job(id:noSettings)?.deliveryStartedAt == nil,"missing settings remains retryable manually without marking delivery")
        settingsAvailable = true; try owner.retryOrderJob(noSettings,now:now); try await drain()
        try check(try db.job(id:noSettings)?.status == "done","creator retries own result notification after settings configured")

        let settings = try db.insert("crm_SystemSettings",values:["key":.text("orders_approval_emails"),"value":.text("false")],actor:identity.id)
        let disabled = try enqueue(); let disabledCalls = calls; try await drain()
        try check(try db.job(id:disabled)?.result["outcome"] == "skipped" && calls == disabledCalls,"disabled notifications skipped before loading key/network")
        _ = try db.update(settings,changes:["value":.text("true")],actor:identity.id)
        var stale = try create(); let staleJobs = try admin.orderJobs(stale); stale = try owner.changeOrder(stale,action:"withdraw",now:now); try await drain()
        try check(staleJobs.allSatisfy { try db.job(id:$0.id)?.result["outcome"] == "skipped" },"withdrawn approval requests do not send stale mail")
        var repeated = try create(); let earlier = try admin.orderJobs(repeated)
        repeated = try owner.changeOrder(repeated,action:"withdraw",now:now)
        repeated = try owner.submitOrder(repeated,now:now)
        try await drain()
        try check(earlier.allSatisfy { try db.job(id:$0.id)?.result["outcome"] == "skipped" },"same-second withdrawal and re-request invalidates old notification by revision")
        var revoked = try create(); let revocationJobs = try admin.orderJobs(revoked)
        try updateUser(manager,["role":.text("user")]); try await drain()
        let managerJob = revocationJobs.first { $0.payload["recipientId"] == manager.identity.id }!
        try check(try db.job(id:managerJob.id)?.result["outcome"] == "skipped","demoted approver is not notified")
        try updateUser(manager,["role":.text("manager")])
        revoked = try manager.changeOrder(revoked,action:"reject",note:"値引きの理由を確認してください。",now:now)
        let rejectedJob = try owner.orderJobs(revoked).first!
        try await drain()
        try check(try db.job(id:rejectedJob.id)?.status == "done" && rejectedJob.payload["decision"] == "REJECTED","actual rejection workflow queues and delivers creator result")
        let banned = try enqueue(); try updateUser(owner,["banned":.integer(1)]); try await drain()
        try check(try db.job(id:banned)?.result["outcome"] == "skipped","banned recipient is not mailed")
        try updateUser(owner,["banned":.integer(0)])
        let changedAddress = try enqueue(legacy.merging(["recipientEmail":"old@example.invalid"]) { _,n in n }); try await drain()
        try check(try db.job(id:changedAddress)?.result["outcome"] == "skipped","event-time address changes require a new notification")
        let cancelled = try enqueue(); try rejects("unrelated user cannot cancel") { try stranger.cancelOrderJob(cancelled) }; try owner.cancelOrderJob(cancelled)
        try check(try db.job(id:cancelled)?.status == "cancelled","recipient can cancel own unsent result")

        code = 500
        let changedKey = try enqueue(); try await drain(); let sentBefore = calls
        account = .init(from:account.from,apiKey:"other-fake-account"); now.addTimeInterval(6); try await drain()
        try check(try db.job(id:changedKey)?.status == "needs_review" && calls == sentBefore,"API account change after attempt blocks duplicate delivery")
        account = .init(from:account.from,apiKey:"fake-order-key")
        let changedRecipient = try enqueue(); try await drain(); try updateUser(owner,["email":.text("new@example.invalid")]); now.addTimeInterval(6); let prior = calls; try await drain()
        try check(try db.job(id:changedRecipient)?.status == "needs_review" && calls == prior,"ambiguous old delivery is not retried to a changed recipient")
        try updateUser(owner,["email":.text("owner@example.invalid")])
        let expired = try enqueue(); try await drain(); now.addTimeInterval(23*3600); let expiryCalls = calls; try await drain()
        try check(try db.job(id:expired)?.status == "needs_review" && calls == expiryCalls,"deduplication expiry never initiates another delivery")
        let clockBack = try enqueue(); try await drain(); try owner.retryOrderJob(clockBack,now:now); now.addTimeInterval(-1); let backCalls = calls; try await drain()
        try check(try db.job(id:clockBack)?.status == "needs_review" && calls == backCalls,"clock rollback stops retries")
        now.addTimeInterval(2)

        let tampered = try enqueue(); try await drain()
        let tamperURL = try InvoiceMail.bodyURL(root:root,id:tampered); var data = try Data(contentsOf:tamperURL); data[0] ^= 1; try data.write(to:tamperURL)
        now.addTimeInterval(6); let beforeTamper = calls; try await drain()
        try check(try db.job(id:tampered)?.status == "failed" && calls == beforeTamper,"modified frozen body is never sent")
        let exhaustion = try enqueue()
        for _ in 0..<8 { try await drain(); now.addTimeInterval(301) }
        try check(try db.job(id:exhaustion)?.status == "needs_review" && db.job(id:exhaustion)?.attempts == 8,"bounded retries end with ambiguous result review")
        code = 200

        // Acceptance is persisted separately. Simulate the local completion write
        // failing, then recover after both the dedupe window and access expire.
        let receipt = try enqueue()
        duringSend = { try sql("CREATE TRIGGER fail_order_mail_done BEFORE UPDATE ON native_outbox WHEN NEW.id='\(receipt)' AND NEW.status='done' BEGIN SELECT RAISE(ABORT,'local completion failure'); END;") }
        try await drain(); duringSend = nil
        try check(try db.job(id:receipt)?.status == "retry" && db.job(id:receipt)?.result["providerID"] == providerID,"receipt survives local completion failure")
        try sql("DROP TRIGGER fail_order_mail_done")
        try updateUser(owner,["banned":.integer(1)]); settingsAvailable = false; now.addTimeInterval(24*3600)
        let receiptCalls = calls; try await drain(worker(second))
        try check(try db.job(id:receipt)?.status == "done" && calls == receiptCalls,"receipt recovery needs no credentials, permission or network")
        settingsAvailable = true; try updateUser(owner,["banned":.integer(0)])

        let fenced = try enqueue()
        duringSend = {
            let reclaimed = try second.claimJob(events:CRMService.orderJobEvents,now:now.addingTimeInterval(301))!
            try second.finishJob(reclaimed,result:["fenced":"new worker owns job"])
        }
        try await drain(); duringSend = nil
        try check(try db.job(id:fenced)?.result == ["fenced":"new worker owns job"],"stale lease cannot overwrite new worker outcome")
        let reentrant = try enqueue(); var nested = true
        duringSend = { nested = try await first.runNext() }; try await drain(); duringSend = nil
        try check(!nested && (try db.job(id:reentrant)?.status) == "done","worker actor allows only one active job")

        let paged = try create(submit:false)
        for i in 0..<105 { _ = try enqueue(legacy.merging(["orderId":paged["id"].string,"recipientId":i%2 == 0 ? owner.identity.id : stranger.identity.id]) { _,n in n }) }
        try check(try admin.orderJobs(paged).count == 100 && admin.orderJobs(paged,offset:100).count == 5,"notification history is bounded to 100 rows")
        try check(try owner.orderJobs(paged).count == 53 && owner.orderJobs(paged).allSatisfy { $0.payload["recipientId"] == owner.identity.id },"recipient filtering happens before pagination")
        for page in [try admin.orderJobs(paged),try admin.orderJobs(paged,offset:100)] { for job in page { try admin.cancelOrderJob(job.id) } }

        let scheduledWorker = worker()
        let runner = await MainActor.run { InvoiceJobRunner(db:db,events:CRMService.orderJobEvents,runNext:{ try await scheduledWorker.runNext() }) }
        await MainActor.run { runner.kick() }
        let notified = try enqueue()
        func awaitDone(_ id: String) async throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline { if try db.job(id:id)?.status == "done" { return }; try await Task.sleep(nanoseconds:25_000_000) }
            throw NativeDBError.message("order runner did not complete")
        }
        try await awaitDone(notified); try await Task.sleep(nanoseconds:100_000_000)
        let idle = await MainActor.run { !runner.isRunning && runner.nextWake == nil }
        try check(idle,"order runner consumes enqueue and has no idle polling timer")
        await MainActor.run { runner.stop() }
        let afterStop = try enqueue(); try await Task.sleep(nanoseconds:100_000_000)
        try check(try db.job(id:afterStop)?.status == "pending","stopped order runner leaves durable work")
        let restarted = await MainActor.run { InvoiceJobRunner(db:second,events:CRMService.orderJobEvents,runNext:{ try await scheduledWorker.runNext() }) }
        await MainActor.run { restarted.kick() }; try await awaitDone(afterStop)
        await MainActor.run { restarted.stop() }
        try check(try db.job(id:afterStop)?.status == "done","restarted order scheduler processes pending work")

        let text = String(repeating:"日本語😀e\u{301}\n\r\t\u{0}\\\"",count:15000)
        let plain = try InvoiceMail.prepareText(root:root,id:UUID().uuidString,from:"from@example.invalid",to:"to@example.invalid",subject:"日本語本文",message:text)
        let decoded = try JSONSerialization.jsonObject(with:Data(contentsOf:plain.url)) as! [String:Any]
        try check(decoded["text"] as? String == text,"streamed plain text roundtrip across chunk boundaries")
        try InvoiceMail.verify(plain.url,sha256:plain.sha256,bytes:plain.bytes)
        try rejects("plain subject injection") { _ = try InvoiceMail.prepareText(root:root,id:UUID().uuidString,from:"from@example.invalid",to:"to@example.invalid",subject:"bad\nheader",message:"") }
        try check(try db.integrityCheck(),"order mail leaves database integrity intact")
        print("Order approval mail: \(checks-initialChecks) checks passed; fake transport only")
    }
}
