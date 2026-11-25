import Foundation
import CryptoKit
import SQLite3

enum CampaignEventTests {
    typealias Fixture = CampaignMailTests.Fixture
    static var checks = 0
    // Test-only sharing: each concurrent iteration owns a separate connection;
    // NativeDatabase serializes operations and this box locks error collection.
    final class ConcurrentInbox: @unchecked Sendable {
        let connections: [NativeDatabase]; private let lock = NSLock(); private var failures: [String] = []
        init(_ connections: [NativeDatabase]) { self.connections = connections }
        func run(_ index: Int, body: Data, headers: [String:String], now: Date) {
            do { _ = try CampaignWebhook.receive(db:connections[index],body:body,headers:headers,secret:CampaignEventTests.secret,now:now) }
            catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
        }
        var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return failures.isEmpty }
    }
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL events: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL events accepted: "+label) }
    static let secret = "whsec_"+Data("native-fixture-only-not-a-real-key".utf8).base64EncodedString()
    static func signed(_ body: Data, id: String, now: Date) -> [String:String] {
        let timestamp = String(Int64(floor(now.timeIntervalSince1970)))
        var signed = Data((id+"."+timestamp+".").utf8); signed.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for:signed,using:SymmetricKey(data:Data("native-fixture-only-not-a-real-key".utf8)))
        return ["svix-id":id,"svix-timestamp":timestamp,"svix-signature":"v1,"+Data(mac).base64EncodedString()]
    }
    static func body(_ kind: String,_ providerID: String, fallback: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject:["type":kind,"data":fallback ? ["message_id":providerID] : ["email_id":providerID,"message_id":"<rfc5322@example.invalid>"]],options:[.sortedKeys,.withoutEscapingSlashes])
    }
    @discardableResult static func receive(_ f: Fixture,_ kind: String,_ id: String, providerID: String? = nil, fallback: Bool = false) throws -> String {
        let payload = try body(kind,providerID ?? f.providerID,fallback:fallback)
        return try CampaignWebhook.receive(db:f.db,body:payload,headers:signed(payload,id:id,now:f.now),secret:secret,now:f.now)
    }
    static func scalar(_ f: Fixture,_ sql: String) throws -> String {
        var c: OpaquePointer?; guard sqlite3_open_v2(f.db.url.path,&c,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(c) }
        var s: OpaquePointer?; guard sqlite3_prepare_v2(c,sql,-1,&s,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }; defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW, let text = sqlite3_column_text(s,0) else { return "" }; return String(cString:text)
    }
    static func value(_ input: Any?) -> SQLValue { input == nil || input is NSNull ? .null : .text(input as! String) }
    static func equalDate(_ value: SQLValue,_ expected: Any?) -> Bool {
        if expected == nil || expected is NSNull { return value == .null }
        return CampaignWorkflow.date(value) == CampaignWorkflow.date(.text(expected as! String))
    }
    static func run(_ resources: URL) async throws {
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/campaign-events-reference.json"))) as! [String:Any]
        try signatures(reference)
        try await unsubscribe(resources,reference)
        try await eventStates(resources,reference)
        try await recovery(resources)
        try await http(resources)
        print("CampaignEventTests: \(checks) checks passed; original signatures17/unsubscribe4/events60; no public listener or live webhook")
    }
    static func signatures(_ reference: [String:Any]) throws {
        let now = CampaignWorkflow.date(.text(reference["now"] as! String))!, secret = reference["secret"] as! String
        for item in reference["signatures"] as! [[String:Any]] {
            let result = CampaignWebhook.verify(body:Data((item["body"] as! String).utf8),headers:item["headers"] as! [String:String],secret:secret,now:now)
            try check(result == item["expected"] as! Bool,"actual original signature: "+(item["name"] as! String))
        }
        let payload = Data("{}".utf8), headers = signed(payload,id:"msg_test",now:now)
        try check(!CampaignWebhook.verify(body:payload,headers:headers,secret:"",now:now),"unset signing secret")
        try check(!CampaignWebhook.verify(body:payload,headers:headers,secret:"whsec_bad%",now:now),"invalid secret encoding")
        try check(!CampaignWebhook.verify(body:payload,headers:headers.merging(["SVIX-ID":"msg_other"]){a,_ in a},secret:self.secret,now:now),"ambiguous duplicate header casing")
        try check(!CampaignWebhook.verify(body:Data(repeating:32,count:CampaignWebhook.maximumBodyBytes+1),headers:headers,secret:self.secret,now:now),"oversized body rejected")
        try check(!CampaignWebhook.verify(body:payload,headers:headers.merging(["svix-timestamp":"NaN"]){_,b in b},secret:self.secret,now:now),"malformed timestamp")
        // Independently published Svix manual verification vector.
        let official = ["svix-id":"msg_loFOjxBNrRLzqYUf","svix-timestamp":"1731705121","svix-signature":"v1,rAvfW3dJ/X/qxhsaXPOyyCGmRKsaKWcsNccKXlIktD0="]
        try check(CampaignWebhook.verify(body:Data("{\"event_type\":\"ping\",\"data\":{\"success\":true}}".utf8),headers:official,secret:"whsec_plJ3nmyCDGBKInavdOK15jsl",now:Date(timeIntervalSince1970:1731705121)),"official independent Svix signature vector")
    }
    static func unsubscribe(_ resources: URL,_ reference: [String:Any]) async throws {
        for item in reference["unsubscribes"] as! [[String:Any]] {
            let f = try await Fixture.make(resources), before = item["before"] as! [String:Any], expected = item["after"] as! [String:Any]
            let sourceSend = before["send"] as! [String:Any]
            try f.change(f.send(),["email":.text(sourceSend["email"] as! String),"unsubscribed_at":value(sourceSend["unsubscribed_at"])])
            var targets: [String:NativeRecord] = [:]
            for t in before["targets"] as! [[String:Any]] {
                let values: [String:SQLValue] = ["email":.text(t["email"] as! String),"do_not_email":.integer((t["do_not_email"] as! Bool) ? 1 : 0),"do_not_email_at":value(t["do_not_email_at"])]
                if t["id"] as! String == "original" { try f.change(f.target,values); targets["original"] = try f.fresh(f.target) }
                else { targets[t["id"] as! String] = try f.db.insert("crm_Targets",values:values.merging(["last_name":.text("別名")]){a,_ in a},actor:f.service.identity.id) }
            }
            let token = try f.send()["unsubscribe_token"].string
            let result = try f.db.unsubscribeCampaign(token:token,now:f.now)
            try check(result?.targets == 3 && result?.campaignID == f.campaign["id"].string,"global unsubscribe target ID and case-insensitive email")
            try check(try equalDate(f.send()["unsubscribed_at"],(expected["send"] as! [String:Any])["unsubscribed_at"]),"source first unsubscribe timestamp")
            for t in expected["targets"] as! [[String:Any]] {
                let actual = try f.fresh(targets[t["id"] as! String]!)
                try check(actual["do_not_email"] == .integer((t["do_not_email"] as! Bool) ? 1 : 0) && equalDate(actual["do_not_email_at"],t["do_not_email_at"]),"actual source global suppression: "+(t["id"] as! String))
            }
            let audit = try f.db.auditCount("crm_Targets")+f.db.auditCount("crm_campaign_sends")
            f.now.addTimeInterval(60)
            try check(try f.db.unsubscribeCampaign(token:token,now:f.now)?.targets == 0 && audit == f.db.auditCount("crm_Targets")+f.db.auditCount("crm_campaign_sends"),"repeated unsubscribe has no extra writes")
            try check(try f.db.unsubscribeCampaign(token:UUID().uuidString,now:f.now) == nil,"unknown token leaves data alone")
        }
        do {
            let f = try await Fixture.make(resources)
            for _ in 0..<205 { _ = try f.db.insert("crm_Targets",values:["last_name":.text("別名"),"email":.text("RECIPIENT@example.invalid")],actor:f.service.identity.id) }
            let token = try f.send()["unsubscribe_token"].string
            try check(try f.db.unsubscribeCampaign(token:token,now:f.now)?.targets == 206,"unsubscribe across more than two100-row batches")
            try check(try f.db.page("crm_Targets",fields:[],equal:["do_not_email":.integer(0)]).total == 0,"no alias skipped by update pagination")
            _ = try await f.worker().runNext()
            try check(f.bodies.isEmpty && f.job().result["outcome"] == "skipped","unsubscribe prevents queued mail")
        }
        do {
            let f = try await Fixture.make(resources), token = try f.send()["unsubscribe_token"].string
            let audit = try f.db.auditCount("crm_campaign_sends")
            try f.sql("CREATE TRIGGER refuse_suppression BEFORE UPDATE ON crm_Targets WHEN NEW.do_not_email=1 BEGIN SELECT RAISE(ABORT,'injected suppression failure'); END")
            try rejects("unsubscribe transaction rollback"){_ = try f.db.unsubscribeCampaign(token:token,now:f.now)}
            try check(try f.send()["unsubscribed_at"] == .null && f.fresh(f.target)["do_not_email"] == .integer(0) && f.db.auditCount("crm_campaign_sends") == audit,"failed suppression does not publish confirmation marker or audit")
            try f.sql("DROP TRIGGER refuse_suppression")
            try check(try f.db.unsubscribeCampaign(token:token,now:f.now)?.targets == 1,"same unsubscribe token can retry after rollback")
        }
    }
    static func eventStates(_ resources: URL,_ reference: [String:Any]) async throws {
        let f = try await Fixture.make(resources)
        for (index,row) in (reference["events"] as! [[String:Any]]).enumerated() {
            let before = row["before"] as! [String:Any], after = row["after"] as! [String:Any]
            try f.change(f.send(),["status":.text(before["status"] as! String),"resend_message_id":.text(f.providerID),"error_message":value(before["error_message"]),"opened_at":value(before["opened_at"]),"clicked_at":value(before["clicked_at"])])
            _ = try receive(f,row["kind"] as! String,"msg_matrix_\(index)")
            let send = try f.send()
            try check(send["status"].string == after["status"] as! String && send["error_message"] == value(after["error_message"]),"original event status/error matrix \(index)")
            try check(equalDate(send["opened_at"],after["opened_at"]) && equalDate(send["clicked_at"],after["clicked_at"]),"original first tracking timestamps \(index)")
        }
        try f.change(f.send(),["opened_at":.null])
        _ = try receive(f,"email.opened","msg_legacy_fallback",fallback:true)
        try check(try f.send()["opened_at"] != .null,"legacy message_id fallback")
        let count = try scalar(f,"SELECT COUNT(*) FROM native_campaign_events")
        let payload = Data("{\"type\":\"email.opened\",\"data\":{\"email_id\":\"\",\"message_id\":\"\(f.providerID)\"}}".utf8)
        try check(try CampaignWebhook.receive(db:f.db,body:payload,headers:signed(payload,id:"msg_empty_primary",now:f.now),secret:secret,now:f.now) == "ignored" && scalar(f,"SELECT COUNT(*) FROM native_campaign_events") == count,"empty email_id follows source nullish preference")
    }
    static func recovery(_ resources: URL) async throws {
        do {
            let f = try await Fixture.make(resources), received = f.now
            try check(try receive(f,"email.opened","msg_early_open") == "pending","event before local receipt durably staged")
            try check(try receive(f,"email.delivered","msg_early_delivery") == "pending","early delivered staged")
            f.now.addTimeInterval(60)
            _ = try await f.worker(connection:f.connection()).runNext()
            try check(try f.send()["status"] == .text("delivered") && CampaignWorkflow.date(f.send()["opened_at"]) == received,"restart/receipt commit reconciles early events and original receive time")
            try check(try scalar(f,"SELECT COUNT(*) FROM native_campaign_events WHERE processed_at IS NULL") == "0","early event inbox drained atomically")
            let audit = try f.db.auditCount("crm_campaign_sends")
            try check(try receive(f,"email.opened","msg_early_open") == "duplicate" && f.db.auditCount("crm_campaign_sends") == audit,"duplicate event no repeated audit")
            let payload = try body("email.clicked",f.providerID)
            try rejects("same event ID different signed body"){_ = try CampaignWebhook.receive(db:f.db,body:payload,headers:signed(payload,id:"msg_early_open",now:f.now),secret:secret,now:f.now)}
            try check(try f.send()["clicked_at"] == .null,"conflicting duplicate cannot change tracking")
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(request:{r,u in
                _ = try receive(f,"email.bounced","msg_during_bounce")
                _ = try receive(f,"email.delivered","msg_later_delivery")
                return try f.response(r,u)
            }).runNext()
            try check(try f.send()["status"] == .text("bounced") && f.send()["error_message"] == .text("Bounced") && f.job().status == "done","receipt preserves early bounce and ignores later delivered transition")
        }
        do {
            let f = try await Fixture.make(resources)
            try f.change(f.send(),["status":.text("sent"),"resend_message_id":.text(f.providerID)])
            try f.sql("CREATE TRIGGER refuse_open BEFORE UPDATE ON crm_campaign_sends WHEN NEW.opened_at IS NOT NULL BEGIN SELECT RAISE(ABORT,'injected tracking failure'); END")
            try rejects("event transaction failure"){_ = try receive(f,"email.opened","msg_rollback")}
            try check(try scalar(f,"SELECT COUNT(*) FROM native_campaign_events") == "0" && f.send()["opened_at"] == .null,"failed tracking rolls back inbox insertion")
            try f.sql("DROP TRIGGER refuse_open")
            try check(try receive(f,"email.opened","msg_rollback") == "applied","retry after tracking rollback")
        }
        do {
            let f = try await Fixture.make(resources)
            try f.sql("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) INSERT INTO native_campaign_events(event_id,provider_id,kind,body_sha256,received_at) SELECT 'msg_capacity_'||x,'unknown-'||x,'email.opened',printf('%064d',0),'2020-01-01T00:00:00.000Z' FROM n")
            try rejects("unknown inbox capped"){_ = try receive(f,"email.opened","msg_overflow",providerID:"unrelated")}
            try check(try scalar(f,"SELECT COUNT(*) FROM native_campaign_events") == "10000","capacity failure does not age-delete unknown events")
            try f.change(f.send(),["status":.text("sent"),"resend_message_id":.text(f.providerID)])
            try check(try receive(f,"email.clicked","msg_known_at_capacity") == "applied","known results still process at unknown inbox capacity")
        }
        do {
            let f = try await Fixture.make(resources)
            try f.change(f.send(),["status":.text("sent"),"resend_message_id":.text(f.providerID)])
            _ = try receive(f,"email.opened","msg_retention")
            let opened = try f.send()["opened_at"]; f.now.addTimeInterval(31*86400)
            _ = try receive(f,"email.clicked","msg_after_retention")
            try check(try scalar(f,"SELECT COUNT(*) FROM native_campaign_events WHERE event_id='msg_retention'") == "0","old processed inbox entries pruned")
            _ = try receive(f,"email.opened","msg_retention")
            try check(try f.send()["opened_at"] == opened,"replay after receipt retention preserves first open")
        }
        do {
            let f = try await Fixture.make(resources)
            try f.change(f.send(),["status":.text("sent"),"resend_message_id":.text(f.providerID)])
            let inbox = ConcurrentInbox([try f.connection(),try f.connection()]), payload = try body("email.opened",f.providerID), headers = signed(payload,id:"msg_concurrent",now:f.now), now = f.now
            let audit = try f.db.auditCount("crm_campaign_sends")
            DispatchQueue.concurrentPerform(iterations:2){index in
                inbox.run(index,body:payload,headers:headers,now:now)
            }
            try check(inbox.succeeded && f.db.auditCount("crm_campaign_sends") == audit+1 && scalar(f,"SELECT COUNT(*) FROM native_campaign_events") == "1","concurrent duplicate handlers commit one event/change")
        }
    }
    static func http(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), route = CampaignPublicHTTP(db:f.db,configuration:f.config,webhookSecret:{secret},clock:{f.now})
        let token = try f.send()["unsubscribe_token"].string, link = "/base/api/campaigns/unsubscribe?token="+token
        try check(route.handle(method:"GET",target:link).status == 200,"Japanese unsubscribe public route")
        let response = route.handle(method:"GET",target:link), html = String(decoding:response.body,as:UTF8.self)
        try check(html.contains("配信停止を受け付けました") && html.contains("lang=\"ja\"") && !html.contains(token) && !html.contains("recipient@example.invalid"),"confirmation is Japanese and does not expose recipient/token")
        try check(response.headers["Cache-Control"] == "no-store" && response.headers["Referrer-Policy"] == "no-referrer","unsubscribe response cannot leak bearer token via referrer/cache")
        for target in ["/base/api/campaigns/unsubscribe","/base/api/campaigns/unsubscribe?token=bad",link+"&token="+token,"https://other.invalid"+link,link+"#fragment"] { try check(route.handle(method:"GET",target:target).status == 400,"bad unsubscribe request rejected") }
        try check(route.handle(method:"GET",target:"/base/api/campaigns/unsubscribe?token="+UUID().uuidString).status == 404,"unknown unsubscribe token")
        try check(route.handle(method:"POST",target:link).status == 405 && route.handle(method:"GET",target:"/other").status == 404,"public method/path restrictions")
        let payload = try body("email.opened",f.providerID), headers = signed(payload,id:"msg_http",now:f.now), endpoint = "/base/api/campaigns/webhooks/resend"
        try check(route.handle(method:"POST",target:endpoint,headers:headers,body:payload).status == 200,"signed early event HTTP acceptance")
        try check(route.handle(method:"POST",target:endpoint,headers:[:],body:payload).status == 401,"unsigned webhook rejected")
        let invalid = Data("invalid JSON".utf8)
        try check(route.handle(method:"POST",target:endpoint,headers:signed(invalid,id:"msg_invalid",now:f.now),body:invalid).status == 400,"malformed authenticated JSON rejected")
        try check(route.handle(method:"POST",target:endpoint,body:Data(repeating:0,count:CampaignWebhook.maximumBodyBytes+1)).status == 413,"webhook body cap")
        try f.change(f.target,["do_not_email":.integer(0)])
        try f.change(f.send(),["unsubscribed_at":.null])
        try f.sql("CREATE TRIGGER http_refuse BEFORE UPDATE ON crm_Targets WHEN NEW.do_not_email=1 BEGIN SELECT RAISE(ABORT,'private sqlite details'); END")
        let failure = route.handle(method:"GET",target:link)
        try check(failure.status == 503 && !String(decoding:failure.body,as:UTF8.self).contains("private sqlite details") && f.send()["unsubscribed_at"] == .null,"public failure neither confirms unsubscribe nor leaks DB details")
        try f.sql("DROP TRIGGER http_refuse")
    }
}
