import Foundation
import SQLite3

@main enum CampaignMailTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    final class Fixture {
        let root: URL; let resources: URL; let db: NativeDatabase; let service: CRMService
        let campaign: NativeRecord; let target: NativeRecord; let template: NativeRecord
        var sendID = ""; var now = CampaignWorkflow.date(.text("2026-11-14T10:00:00.125Z"))!
        var credentials = InvoiceMailAccount(from:"sender@example.invalid",apiKey:"fake-key")
        var config = try! CampaignMailConfiguration(publicURL:"https://crm.example.invalid/base/")
        var bodies: [Data] = []; var keys: [String] = []; var preflights = 0
        let providerID = UUID().uuidString.lowercased()
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignMail-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            template = try service.saveCampaignTemplate(nil,input:["name":.text("案内"),"subject_default":.text("件名"),"content_html":.text("<h1>{{first_name}} 様</h1><p>日本語😀 <b>ご案内</b></p><table><tr><td>内容</td></tr></table><a href='javascript&colon;evil()'>リンク</a>")])
            target = try db.insert("crm_Targets",values:["last_name":.text("検証"),"first_name":.text("山田<&\""),"email":.text("recipient@example.invalid"),"created_by":.text(service.identity.id)],actor:service.identity.id)
            let list = try db.insert("crm_TargetLists",values:["name":.text("対象"),"created_by":.text(service.identity.id)],actor:service.identity.id)
            _ = try db.insert("TargetsToTargetLists",values:["target_id":target["id"],"target_list_id":list["id"]],actor:service.identity.id)
            let draft = try service.createCampaign(input:["name":.text("テスト"),"from_name":.text("日本語 \"営業\""),"reply_to":.text("reply@example.invalid")],targetListIDs:[list["id"].string],steps:[.init(order:0,templateID:template["id"].string,subject:"{{last_name}} 様へのご案内")])
            campaign = try service.sendCampaignNow(draft,now:now)
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        static func make(_ resources: URL) async throws -> Fixture {
            let f = try Fixture(resources)
            _ = try await CampaignDispatchWorker(db:f.db,clock:{f.now}).runNext()
            f.sendID = try f.db.page("crm_campaign_sends",fields:[]).rows[0]["id"].string
            return f
        }
        func connection() throws -> NativeDatabase { try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        func fresh(_ r: NativeRecord) throws -> NativeRecord { try db.get(r.model,key:db.key(for:r))! }
        func send() throws -> NativeRecord { try db.get("crm_campaign_sends",key:["id":.text(sendID)])! }
        func job() throws -> NativeJob { try db.job(id:sendID)! }
        func bodyURL() throws -> URL { try InvoiceMail.bodyURL(root:root,id:sendID) }
        func worker(connection: NativeDatabase? = nil, ready: ((CampaignMailConfiguration) async throws -> Void)? = nil, request: ResendMailClient.Request? = nil) -> CampaignMailWorker {
            CampaignMailWorker(db:connection ?? db,account:{self.credentials},configuration:{self.config},endpointReady:{_,config in if let ready { try await ready(config) } else { self.preflights += 1 }},request:request ?? {r,u in try self.response(r,u)},clock:{self.now})
        }
        func response(_ request: URLRequest,_ body: URL, status: Int = 200, name: String? = nil) throws -> (Data,HTTPURLResponse) {
            bodies.append(try Data(contentsOf:body)); keys.append(request.value(forHTTPHeaderField:"Idempotency-Key") ?? "")
            return (try JSONSerialization.data(withJSONObject:name.map{["name":$0]} ?? ["id":providerID]),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        }
        func sql(_ text: String) throws {
            var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(c) }
            guard sqlite3_exec(c,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }
        }
        func change(_ record: NativeRecord,_ values: [String:SQLValue]) throws { _ = try db.update(fresh(record),changes:values,actor:service.identity.id) }
    }
    static func main() async { do { try await run() } catch { FileHandle.standardError.write(Data("CampaignMailTests: \(error)\n".utf8)); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        if CommandLine.arguments.contains("--relay-keychain-probe") { try CampaignRelayCredentialsTests.keychainProbe(); return }
        try configurationAndBody()
        try await successAndRetry(resources)
        try await receiptRecovery(resources)
        try await gates(resources)
        try await failures(resources)
        try await sourceBehavior(resources)
        try await CampaignEventTests.run(resources)
        try await CampaignRelaySyncTests.run(resources)
        try await CampaignRelayCredentialsTests.run(resources)
        try await CampaignRuntimeTests.run(resources)
        try await CampaignDeliveryTests.run(resources)
        try await CampaignOperationsTests.run(resources)
        print("CampaignMailTests: \(checks) checks passed; fake transport only")
    }
    static func sourceBehavior(_ resources: URL) async throws {
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/campaign-mail-reference.json"))) as! [String:Any]
        for row in reference["cases"] as! [[String:Any]] {
            let f = try await Fixture.make(resources), name = row["name"] as! String
            try f.change(f.campaign,["status":.text(row["campaignStatus"] as! String),"from_name":.text("日本語営業"),"deletedAt":(row["deleted"] as! Bool) ? .text(try CampaignWorkflow.stamp(f.now)) : .null])
            try f.change(f.send(),["status":.text(row["status"] as! String),"unsubscribed_at":(row["unsubscribed"] as! Bool) ? .text(try CampaignWorkflow.stamp(f.now)) : .null])
            try f.change(f.target,["do_not_email":.integer((row["suppressed"] as! Bool) ? 1 : 0)])
            try f.change(f.template,["content_html":.text("<p>{{first_name}} 様：日本語😀</p>")])
            _ = try await f.worker().runNext()
            try check((f.bodies.count == 1) == (row["sent"] as! Bool),"actual original worker send/skip: "+name)
            if let expected = row["mail"] as? [String:Any], let render = row["render"] as? [String:Any] {
                let actual = try JSONSerialization.jsonObject(with:f.bodies[0]) as! [String:Any]
                try check(actual["subject"] as? String == expected["subject"] as? String && (actual["to"] as? [String])?.first == expected["to"] as? String,"actual original worker subject and recipient")
                try check((actual["html"] as! String).contains(render["contentHtml"] as! String),"actual original merge output survives native renderer")
                try check(actual["reply_to"] as? String == expected["replyTo"] as? String,"SDK replyTo becomes provider reply_to")
                try check((row["options"] as! [String:String])["idempotencyKey"] == "campaign-send/48c35656-2fc6-4a67-b734-aa646e0f4005" && f.keys == ["campaign-send/"+f.sendID],"actual original provider key namespace")
            }
        }
    }
    static func configurationAndBody() throws {
        let mergeTarget = ["first_name":"日本<&\"'😀","email":"{{company}}","company":"会社"]
        for source in ["{{first_name}}", "{{{email}}}", "{{company}}{{email}}", "{{missing}} {{first_name_日本}} {{FIRST_NAME}}", "{{first_name}} {{last_name}} {{position}}", "文字 & 文", "{{incomplete", "{{long_unknown_field}}"] {
            for escaped in [false,true] {
                try check(try CampaignMergeTags.resolveBounded(source,target:mergeTarget,escaped:escaped,maximumBytes:1000) == CampaignMergeTags.resolve(source,target:mergeTarget,escaped:escaped),"bounded merge preserves original single-pass semantics")
            }
        }
        try rejects("merge expansion capped before large intermediate allocation"){_ = try CampaignMergeTags.resolveBounded("{{company}}{{company}}",target:["company":String(repeating:"&",count:20)],escaped:true,maximumBytes:100)}
        try check(try CampaignMergeTags.resolveBounded("{{company}}",target:["company":String(repeating:"&",count:20)],escaped:true,maximumBytes:100).utf8.count == 100,"exact escaped expansion cap")
        for url in ["http://example.invalid","https://user:pass@example.invalid","https://example.invalid/?x=y","https://example.invalid/#x","https://example.invalid:0","relative","file:///tmp/x"] {
            try rejects("public URL "+url){_ = try CampaignMailConfiguration(publicURL:url)}
        }
        let config = try CampaignMailConfiguration(publicURL:"https://example.invalid/base///")
        let id = UUID().uuidString.lowercased(), token = UUID().uuidString.lowercased()
        try check(try config.unsubscribeURL(token:token).absoluteString == "https://example.invalid/base/api/campaigns/unsubscribe?token="+token,"prefix and trailing slashes")
        try rejects("HTTP loopback requires explicit test option"){_ = try CampaignMailConfiguration(publicURL:"http://127.0.0.1:9000")}
        _ = try CampaignMailConfiguration(publicURL:"http://127.0.0.1:9000",allowLoopbackHTTP:true)
        try rejects("test option does not permit arbitrary HTTP"){_ = try CampaignMailConfiguration(publicURL:"http://example.invalid",allowLoopbackHTTP:true)}
        try rejects("bad token"){_ = try config.unsubscribeURL(token:"a&x=y")}
        try rejects("sender header injection"){_ = try CampaignMail.sender(address:"a@example.invalid",name:"a\r\nb")}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignBody-"+id); defer { try? FileManager.default.removeItem(at:root) }
        func prepare(_ html: String, subject: String = "ご案内", sendID: String = id) throws -> CampaignMail.Prepared {
            try CampaignMail.prepare(root:root,id:sendID,address:"a@example.invalid",fromName:"",to:"b@example.invalid",subject:subject,html:html,replyTo:"",token:token,target:[:],configuration:config)
        }
        let body = try prepare("<p>日本語😀</p>")
        try InvoiceMail.verify(body.body.url,sha256:body.body.sha256,bytes:body.body.bytes)
        let bytes = try Data(contentsOf:body.body.url)
        try rejects("immutable body cannot be overwritten"){_ = try prepare("上書き")}
        try check(try Data(contentsOf:body.body.url) == bytes,"exclusive create preserves original bytes")
        let attrs = try FileManager.default.attributesOfItem(atPath:body.body.url.path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,"body mode0600")
        let invalid = UUID().uuidString.lowercased()
        try rejects("malformed deep HTML aborts preparation"){_ = try prepare(String(repeating:"<div>",count:130),sendID:invalid)}
        try check(try !FileManager.default.fileExists(atPath:InvoiceMail.bodyURL(root:root,id:invalid).path),"partial file removed on renderer failure")
        try rejects("subject injection"){_ = try prepare("x",subject:"bad\r\nBcc:x",sendID:invalid)}
        try rejects("blank subject"){_ = try prepare("x",subject:" \t ",sendID:invalid)}
    }
    static func successAndRetry(_ resources: URL) async throws {
        do {
            let f = try await Fixture.make(resources)
            let ran = try await f.worker().runNext(); try check(ran,"worker claimed send")
            try check(f.bodies.count == 1 && f.keys == ["campaign-send/"+f.sendID],"source provider idempotency key")
            let json = try JSONSerialization.jsonObject(with:f.bodies[0]) as! [String:Any], html = json["html"] as! String
            try check(json["to"] as? [String] == ["recipient@example.invalid"],"snapshot recipient")
            try check(json["subject"] as? String == "検証 様へのご案内","merged Japanese subject")
            try check(json["from"] as? String == "\"日本語 \\\"営業\\\"\" <sender@example.invalid>","quoted Japanese sender")
            try check(json["reply_to"] as? String == "reply@example.invalid","provider reply_to field")
            try check(html.contains("山田&lt;&amp;&quot;") && html.contains("日本語😀") && html.contains("<table>"),"merge escaping and original content preserved")
            try check(!html.contains("javascript:") && html.contains("配信停止") && html.contains("lang=\"ja\""),"safe Japanese full mail")
            let unsubscribe = try f.config.unsubscribeURL(token:f.send()["unsubscribe_token"].string).absoluteString
            try check((json["headers"] as? [String:String])?["List-Unsubscribe"] == "<"+unsubscribe+">" && html.contains(unsubscribe),"working endpoint contract in footer and header")
            try check(try f.job().status == "done" && f.send()["status"] == .text("sent") && f.send()["resend_message_id"] == .text(f.providerID),"receipt committed to send and outbox")
            try check(try f.fresh(f.campaign)["status"] == .text("sent"),"initial campaign finishes after delivery")
            try check(try !FileManager.default.fileExists(atPath:f.bodyURL().path),"accepted body removed")
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(request:{r,u in _ = try f.response(r,u); throw URLError(.timedOut)}).runNext()
            let first = try f.job(); try check(first.status == "retry" && first.deliveryStartedAt == f.now,"unknown result retries with first timestamp")
            let original = try Data(contentsOf:f.bodyURL())
            try f.change(f.template,["content_html":.text("変更後の本文")]); try f.change(f.target,["first_name":.text("変更後の名前")])
            f.now.addTimeInterval(30)
            _ = try await f.worker(connection:f.connection()).runNext()
            try check(f.bodies.count == 2 && f.bodies[0] == f.bodies[1] && f.bodies[1] == original,"restart reuses exact bytes despite later template/merge changes")
            try check(f.keys == ["campaign-send/"+f.sendID,"campaign-send/"+f.sendID],"restart reuses provider key")
            try check(try f.job().deliveryStartedAt == first.deliveryStartedAt && f.job().status == "done","restart preserves first delivery time")
        }
    }
    static func receiptRecovery(_ resources: URL) async throws {
        let f = try await Fixture.make(resources)
        _ = try await f.worker(request:{r,u in
            try f.sql("CREATE TRIGGER reject_accept BEFORE UPDATE ON crm_campaign_sends WHEN NEW.status='sent' BEGIN SELECT RAISE(ABORT,'injected local update failure'); END")
            return try f.response(r,u)
        }).runNext()
        try check(try f.job().result["providerID"] == f.providerID && f.job().status == "retry","receipt survives local completion failure")
        let accepted = try f.job().result["acceptedAt"]
        try f.sql("DROP TRIGGER reject_accept")
        try f.change(f.campaign,["status":.text("paused")])
        let user = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!
        try f.change(user,["banned":.integer(1)])
        try f.change(f.send(),["status":.text("delivered"),"opened_at":.text(try CampaignWorkflow.stamp(f.now)),"unsubscribed_at":.text(try CampaignWorkflow.stamp(f.now))])
        f.credentials = .init(from:"changed@example.invalid",apiKey:"")
        f.now.addTimeInterval(25*3600)
        _ = try await f.worker(connection:f.connection(),ready:{_ in throw NativeDBError.conflict}).runNext()
        try check(f.bodies.count == 1 && f.preflights == 1,"receipt recovery bypasses credentials readiness and external resend")
        try check(try f.job().status == "done" && f.send()["status"] == .text("delivered"),"receipt recovery preserves provider delivery state")
        try check(try f.send()["sent_at"].string == accepted && f.send()["opened_at"] != .null && f.send()["unsubscribed_at"] != .null,"receipt recovery preserves first accepted time and tracking")
        try check(try f.fresh(f.campaign)["status"] == .text("paused"),"receipt does not unpause campaign")
    }
    static func gates(_ resources: URL) async throws {
        for gate in ["pause","suppressed","unsubscribe","deleted-target","revoke","superseded","email","template","sender","key","config","expiry"] {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(ready:{_ in
                switch gate {
                case "pause": try f.change(f.campaign,["status":.text("paused")])
                case "suppressed": try f.change(f.target,["do_not_email":.integer(1)])
                case "unsubscribe": try f.change(f.send(),["unsubscribed_at":.text(try CampaignWorkflow.stamp(f.now))])
                case "deleted-target": _ = try f.db.setDeleted(f.fresh(f.target),deleted:true,actor:f.service.identity.id)
                case "revoke": let user = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!; try f.change(user,["banned":.integer(1)])
                case "superseded": try f.db.setMetadata(CampaignWorkflow.runKey(f.campaign["id"].string),value:UUID().uuidString)
                case "email": try f.change(f.target,["email":.text("changed@example.invalid")])
                case "template": try f.service.deleteCampaignTemplate(f.fresh(f.template))
                case "sender": try f.change(f.campaign,["from_name":.text("変更後")])
                case "key": f.credentials = .init(from:f.credentials.from,apiKey:"changed-key")
                case "config": f.config = try CampaignMailConfiguration(publicURL:"https://changed.example.invalid")
                case "expiry": break // No external request yet; readiness delay cannot expire an unstarted send.
                default: break
                }
            }).runNext()
            if gate == "expiry" { try check(f.bodies.count == 1,"first delivery allowed without prior window") }
            else { try check(f.bodies.isEmpty && f.job().deliveryStartedAt == nil,"last gate prevents external request: "+gate) }
            if ["suppressed","unsubscribe","deleted-target"].contains(gate) { try check(try f.fresh(f.campaign)["status"] == .text("sent"),"suppressed last initial recipient does not stall campaign") }
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(ready:{_ in _ = try f.service.pauseCampaign(f.fresh(f.campaign))}).runNext()
            let frozen = try Data(contentsOf:f.bodyURL()); try check(try f.job().result["outcome"] == "skipped","paused prepared job skipped")
            _ = try f.service.resumeCampaign(f.fresh(f.campaign),now:f.now)
            _ = try await CampaignDispatchWorker(db:f.db,clock:{f.now}).runNext()
            _ = try await f.worker().runNext()
            try check(f.bodies == [frozen] && f.keys == ["campaign-send/"+f.sendID],"resume preserves prepared body and identity")
        }
    }
    static func failures(_ resources: URL) async throws {
        for mode in ["expiry","clock-back","key","suppression","missing-body","changed-body","permanent-reject"] {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(request:{r,u in _ = try f.response(r,u); throw URLError(.networkConnectionLost)}).runNext()
            let first = try f.job().deliveryStartedAt
            switch mode {
            case "expiry": f.now.addTimeInterval(23*3600)
            case "clock-back": f.now.addTimeInterval(-60); try f.sql("UPDATE native_outbox SET next_run_at=NULL WHERE event='campaigns/send-step'")
            case "key": f.credentials = .init(from:f.credentials.from,apiKey:"changed-key"); f.now.addTimeInterval(30)
            case "suppression": try f.change(f.target,["do_not_email":.integer(1)]); f.now.addTimeInterval(30)
            case "missing-body": try FileManager.default.removeItem(at:f.bodyURL()); f.now.addTimeInterval(30)
            case "changed-body": try Data("changed".utf8).write(to:f.bodyURL()); f.now.addTimeInterval(30)
            case "permanent-reject": f.now.addTimeInterval(30)
            default: break
            }
            _ = try await f.worker(connection:f.connection(),request:{r,u in try f.response(r,u,status:403,name:"validation_error")}).runNext()
            try check(try f.job().status == "needs_review" && f.job().deliveryStartedAt == first,"ambiguous previous request requires review: "+mode)
            try check(f.bodies.count == (mode == "permanent-reject" ? 2 : 1),"unsafe retry not sent: "+mode)
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(request:{r,u in try f.response(r,u,status:422,name:"validation_error")}).runNext()
            try check(try f.job().status == "failed" && f.send()["status"] == .text("failed"),"first definitive rejection recorded failed")
            try check(try f.fresh(f.campaign)["status"] == .text("sent"),"initial completion includes failed recipient")
        }
        do {
            let f = try await Fixture.make(resources)
            try f.change(f.send(),["status":.text("sending")])
            _ = try await f.worker().runNext()
            try check(try f.job().status == "needs_review" && f.bodies.isEmpty,"legacy sending without native receipt is not resent")
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(request:{r,u in
                try f.change(f.campaign,["status":.text("paused")])
                try f.change(f.target,["do_not_email":.integer(1)])
                return try f.response(r,u)
            }).runNext()
            try check(try f.job().status == "done" && f.send()["resend_message_id"] == .text(f.providerID),"acceptance recorded despite pause/suppression during request")
            try check(try f.fresh(f.campaign)["status"] == .text("paused"),"accepted in-flight send does not restart campaign")
        }
        do {
            let f = try await Fixture.make(resources)
            let worker = f.worker(request:{r,u in try f.response(r,u,status:500,name:"server_error")})
            for _ in 0..<8 { _ = try await worker.runNext(); f.now.addTimeInterval(400) }
            try check(try f.job().status == "needs_review" && f.bodies.count == 8,"unknown retries stop for review at bound")
            try check(Set(f.keys).count == 1 && f.bodies.allSatisfy{$0 == f.bodies[0]},"all retry bodies/keys identical")
            try check(try f.fresh(f.campaign)["status"] == .text("sending"),"unresolved request does not falsely finish initial campaign")
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(ready:{_ in throw MailSendError(message:"endpoint unavailable",retryable:true,review:false)}).runNext()
            try check(try f.job().status == "retry" && f.job().deliveryStartedAt == nil && f.bodies.isEmpty,"unavailable unsubscribe endpoint prevents external delivery")
            let original = try Data(contentsOf:f.bodyURL()); f.now.addTimeInterval(30)
            _ = try await f.worker(connection:f.connection()).runNext()
            try check(f.bodies == [original],"readiness retry reuses frozen body")
        }
        do {
            let f = try await Fixture.make(resources)
            // Expire and reclaim the lease while the first worker is awaiting
            // readiness. Its final DB gate must not issue an external request.
            _ = try await f.worker(ready:{_ in
                f.now.addTimeInterval(301)
                _ = try f.connection().claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)
            }).runNext()
            try check(f.bodies.isEmpty && f.job().deliveryStartedAt == nil,"stale worker fenced after lease reclaim")
            f.now.addTimeInterval(301)
            _ = try await f.worker(connection:f.connection()).runNext()
            try check(f.bodies.count == 1 && f.job().status == "done","new lease safely resumes prepared file")
        }
    }
}
