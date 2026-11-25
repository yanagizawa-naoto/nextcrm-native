import Foundation
import SQLite3

extension InvoiceMailTests {
    static func crmTaskMailTests() async throws {
        let startChecks = checks; let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CRMTaskMail-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        func user(_ name: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:"user",partnerAccountID:nil))
        }
        let owner = try user("owner"),assignee = try user("assignee"),watcher = try user("watcher"),stranger = try user("stranger")
        let account = try owner.save(CRMModule.find("crm_Accounts")!,original:nil,input:["name":.text("CRM通知の検証会社")])
        let parent = CRMTaskParent(model:account.model,id:account["id"].string)
        func refreshed(_ row: NativeRecord, database: NativeDatabase? = nil) throws -> NativeRecord { try (database ?? db).get(row.model,key:db.key(for:row))! }
        func task(_ title: String, assigned: CRMService? = nil) throws -> NativeRecord {
            try owner.saveCRMTask(parent:parent,original:nil,input:["title":.text(title),"content":.text("メール本文に複製しない説明"),"priority":.text("medium"),"user":.text((assigned ?? assignee).identity.id)])
        }
        func jobs(_ task: NativeRecord) throws -> [NativeJob] { try admin.crmTaskJobs(taskID:task["id"].string) }
        func updateUser(_ user: CRMService, _ changes: [String:SQLValue]) throws { _ = try db.update(db.get("Users",key:["id":.text(user.identity.id)])!,changes:changes,actor:identity.id) }
        func sql(_ statement: String) throws {
            var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.message("test SQL open") }; defer { sqlite3_close(c) }
            guard sqlite3_exec(c,statement,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }
        }
        var now = Date(timeIntervalSince1970:1_800_000_000.25); var calls = 0; var code = 200; var bodies: [Data] = []; var keys: [String] = []
        var configured = true; var credentials = InvoiceMailAccount(from:"crm@example.invalid",apiKey:"fake-crm-key")
        var duringSend: (() throws -> Void)?; let provider = UUID().uuidString.lowercased()
        let request: ResendMailClient.Request = { query,file in
            calls += 1; bodies.append(try Data(contentsOf:file)); keys.append(query.value(forHTTPHeaderField:"Idempotency-Key")!)
            try duringSend?()
            return (try JSONSerialization.data(withJSONObject:code == 200 ? ["id":provider] : ["name":"fake_error"]),HTTPURLResponse(url:query.url!,statusCode:code,httpVersion:nil,headerFields:code == 503 ? ["Retry-After":"20"] : nil)!)
        }
        func worker(_ database: NativeDatabase = db) -> CRMTaskMailWorker { CRMTaskMailWorker(db:database,account:{guard configured else { throw NativeDBError.message("検証用の設定未登録") };return credentials},request:request,clock:{now}) }
        let worker1 = worker()
        func drain(_ worker: CRMTaskMailWorker = worker1) async throws { var count = 0;while try await worker.runNext() { count += 1; if count > 300 { throw NativeDBError.message("CRM task queue did not settle") } } }
        func body() throws -> [String:Any] { try JSONSerialization.jsonObject(with:bodies.last!) as! [String:Any] }
        var watchers: [NativeRecord] = []
        for s in [owner,assignee,watcher] { watchers.append(try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":.text(s.identity.id)],actor:identity.id)) }
        let first = try task("最初の日本語CRMタスク"); let notices = try jobs(first)
        try check(notices.count == 2 && Set(notices.compactMap{$0.payload["recipientId"]}) == Set([assignee.identity.id,watcher.identity.id]),"creator excluded and overlapping watcher deduplicated")
        try check(notices.allSatisfy{$0.payload["content"] == nil},"large task body not duplicated into notices")
        try check(try watcher.crmTaskJobs(taskID:first["id"].string).count == 1,"readonly watcher sees own delivery only")
        try rejects("unrelated job access") { _ = try stranger.crmTaskJobAccess(notices[0].id) }
        try await drain()
        try check(calls == 2 && notices.allSatisfy{(try? db.job(id:$0.id)?.status) == "done"},"both intended recipients accepted by fake transport")
        let json = try body(); let text = json["text"] as! String
        try check((json["subject"] as! String) == "新しいCRMタスク：最初の日本語CRMタスク" && text.contains("ownerさん"),"Japanese CRM notification")
        try check(!text.contains("メール本文に複製しない"),"source email template omits full task body")
        try check(keys.allSatisfy{$0.hasPrefix("nextcrm/crm-task/")},"distinct stable mail namespace")
        let link = try NativeCRMTaskLink(taskID:first["id"].string)
        try check(text.contains(link.string) && NativeCRMTaskLink(text:link.string) == link,"correct CRM route replaces original assignee's project route")
        try check(try watcher.crmTaskFromLink(link).task["id"] == first["id"],"link requires current CRM read access")
        try rejects("unrelated CRM link") { _ = try stranger.crmTaskFromLink(link) }
        for invalid in [link.string+"?x=1",link.string+"#x",link.string+"/",link.string.replacingOccurrences(of:"crm-tasks/",with:"crm-tasks:7/"),"https://crm-tasks/"+link.taskID,"nextcrm-native://u:p@crm-tasks/"+link.taskID,"nextcrm-native://crm-tasks/%2F"+link.taskID,"nextcrm-native://crm-tasks/not-a-uuid","nextcrm-native://tasks/"+link.taskID] { try rejects("malformed or wrong-type link") { _ = try NativeCRMTaskLink(text:invalid) } }
        try check(notices.allSatisfy{!FileManager.default.fileExists(atPath:(try? InvoiceMail.bodyURL(root:root,id:$0.id).path) ?? "")},"completed bodies removed")
        for row in watchers { try db.remove(row,actor:identity.id,action:"unwatch") }
        let own = try task("本人には通知しない",assigned:owner)
        try check(try jobs(own).isEmpty,"self assignment sends no notification")
        var edited = try owner.saveCRMTask(original:first,input:["title":.text("編集だけでは新規通知しない")])
        edited = try assignee.setCRMTaskStatus(edited,status:"COMPLETE")
        _ = try owner.addCRMTaskComment(taskID:first["id"].string,comment:"CRMコメントには元仕様の通知なし")
        try check(try jobs(edited).count == 2,"status edit and comment do not invent source notifications")
        // Retry/restart must keep exact frozen content and idempotency key.
        let retryTask = try task("再試行するタスク"); let retry = try jobs(retryTask)[0]
        code = 503; try await drain(); let frozen = bodies.last!; let frozenKey = keys.last!
        try check(try db.job(id:retry.id)?.status == "retry" && db.job(id:retry.id)?.deliveryStartedAt != nil,"transient failure durably retried")
        _ = try owner.saveCRMTask(original:retryTask,input:["title":.text("通知予約後の編集")])
        now += 21; code = 200; try await drain(worker(second))
        try check(bodies.last == frozen && keys.last == frozenKey && (try db.job(id:retry.id))?.attempts == 2,"restart preserves body and key")
        // Current recipients and access are rechecked before delivery.
        let reassigned = try task("担当者変更で中止");let reassignedJob = try jobs(reassigned)[0]
        _ = try owner.saveCRMTask(original:reassigned,input:["user":.text(owner.identity.id)])
        let beforeSkip = calls;try await drain()
        try check(calls == beforeSkip && (try db.job(id:reassignedJob.id))?.result["outcome"] == "skipped","reassignment skips old recipient")
        let banned = try task("宛先停止で中止");let bannedJob = try jobs(banned)[0]
        try updateUser(assignee,["banned":.integer(1)]);try await drain()
        try check(calls == beforeSkip && (try db.job(id:bannedJob.id))?.result["outcome"] == "skipped","banned recipient not sent")
        try updateUser(assignee,["banned":.integer(0)])
        let email = try task("宛先メール変更で中止");let emailJob = try jobs(email)[0]
        try updateUser(assignee,["email":.text("changed@example.invalid")]);try await drain()
        try check(calls == beforeSkip && (try db.job(id:emailJob.id))?.result["outcome"] == "skipped","changed email not substituted into old notification")
        try updateUser(assignee,["email":.text("assignee@example.invalid")])
        let w = try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":.text(watcher.identity.id)],actor:identity.id)
        let unwatched = try task("ウォッチ解除",assigned:owner);let unwatchedJob = try jobs(unwatched)[0]
        try db.remove(w,actor:identity.id,action:"unwatch");try await drain()
        try check(calls == beforeSkip && (try db.job(id:unwatchedJob.id))?.result["outcome"] == "skipped","unwatched recipient omitted")
        let deleted = try task("タスク削除で中止");let deletedJob = try jobs(deleted)[0]
        try owner.deleteCRMTask(deleted);try await drain()
        try check(calls == beforeSkip && (try db.job(id:deletedJob.id))?.result["outcome"] == "skipped","deleted task notice not sent")
        // Revocation after an ambiguous send must require review, not retry anew.
        let ambiguous = try task("送信結果不明");let uncertain = try jobs(ambiguous)[0]
        code = 500;try await drain();let afterAmbiguous = calls
        _ = try owner.saveCRMTask(original:ambiguous,input:["user":.text(owner.identity.id)])
        now += 60;try await drain()
        let review = try db.job(id:uncertain.id)!
        try check(review.status == "needs_review" && calls == afterAmbiguous,"revoked retry retained for manual review")
        try owner.reviewMailJob(review,outcome:.unknown,providerID:"",note:"架空送信の結果不明を記録",now:now)
        try check((try db.job(id:review.id))?.status == "done" && calls == afterAmbiguous,"manual review never sends again")
        try check(!FileManager.default.fileExists(atPath:try InvoiceMail.bodyURL(root:root,id:review.id).path),"review removes frozen body")
        // A saved receipt is authoritative even if credential/access state changes.
        code = 200;let receiptTask = try task("受付結果を復旧");let receiptJob = try jobs(receiptTask)[0]
        try sql("CREATE TRIGGER fail_crm_notice_done BEFORE UPDATE ON native_outbox WHEN NEW.event LIKE 'crm.task_%' AND NEW.status='done' BEGIN SELECT RAISE(ABORT,'fake completion failure'); END")
        try await drain(); let afterReceipt = calls
        try check((try db.job(id:receiptJob.id))?.result["providerID"] == provider && (try db.job(id:receiptJob.id))?.status == "retry","receipt stored before failed local completion")
        try sql("DROP TRIGGER fail_crm_notice_done");configured = false;try updateUser(assignee,["banned":.integer(1)]);now += 60
        try await drain(worker(second))
        try check((try db.job(id:receiptJob.id))?.status == "done" && calls == afterReceipt,"receipt recovery bypasses new external sends and credentials")
        configured = true;try updateUser(assignee,["banned":.integer(0)])
        let missing = try task("送信設定なし");let missingJob = try jobs(missing)[0];configured = false;try await drain()
        try check((try db.job(id:missingJob.id))?.status == "failed" && calls == afterReceipt,"missing settings fail locally")
        configured = true;try owner.retryCRMTaskJob(missingJob.id,now:now);try await drain()
        try check((try db.job(id:missingJob.id))?.status == "done","manual retry after configuring sender")
        let cancel = try task("通知の取消");let cancelJob = try jobs(cancel)[0];try owner.cancelCRMTaskJob(cancelJob.id);let beforeCancel = calls;try await drain()
        try check(calls == beforeCancel && (try db.job(id:cancelJob.id))?.status == "cancelled","cancelled job not delivered")
        let credentialTask = try task("認証情報の変更");let credentialJob = try jobs(credentialTask)[0];code = 500;try await drain();let beforeCredential = calls
        credentials = InvoiceMailAccount(from:"crm@example.invalid",apiKey:"different-fake-key");now += 60;try await drain()
        try check(calls == beforeCredential && (try db.job(id:credentialJob.id))?.status == "needs_review","changed credential during retry requires review")
        try owner.reviewMailJob(db.job(id:credentialJob.id)!,outcome:.notSent,providerID:"",note:"架空送信サービスで未送信を確認",now:now)
        code = 200
        let race = try task("二つのワーカー");let raceJob = try jobs(race)[0];let beforeRace = calls
        let competing = worker(second)
        async let a = worker1.runNext();async let b = competing.runNext();let results = try await [a,b]
        try check(results.filter{$0}.count == 1 && calls == beforeRace+1 && (try db.job(id:raceJob.id))?.status == "done","separate workers claim one delivery")
        // Delete the parent during an in-flight accepted request: finish its receipt.
        let inFlight = try task("受付中の権限変更");let inFlightJob = try jobs(inFlight)[0]
        duringSend = { _ = try second.setDeleted(refreshed(account,database:second),deleted:true,actor:identity.id) }
        try await drain();duringSend = nil
        try check((try db.job(id:inFlightJob.id))?.status == "done","accepted request completed despite in-flight parent deletion")
        _ = try db.setDeleted(refreshed(account),deleted:false,actor:identity.id)
        // Recipient enumeration and history both exceed a single SQL page.
        try db.transaction { for i in 0..<104 { let s = try user("watcher-\(i)");_ = try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":.text(s.identity.id)],actor:identity.id) } }
        let many = try task("105人への通知");let p1 = try admin.crmTaskJobs(taskID:many["id"].string);let p2 = try admin.crmTaskJobs(taskID:many["id"].string,offset:100)
        try check(p1.count == 100 && p2.count == 5 && Set((p1+p2).compactMap{$0.payload["recipientId"]}).count == 105,"bounded105 recipient enumeration/history")
        let beforeMany = calls;try await drain();try check(calls == beforeMany+105,"all105 recipients sent exactly once via fake transport")
        try check(try db.integrityCheck(),"mail fixture integrity")
        print("CRM task notifications: \(checks-startChecks) checks passed; fake transport only")
    }
}
