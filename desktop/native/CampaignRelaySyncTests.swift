import Foundation
import CryptoKit

enum CampaignRelaySyncTests {
    typealias Fixture = CampaignMailTests.Fixture
    static var checks = 0
    static let key = Data(repeating:7,count:32).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL relay sync: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () async throws -> Void) async throws { do { try await body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL relay sync accepted: "+label) }
    final class Server {
        let process = Process(), output = Pipe(), errors = Pipe()
        private let terminated = DispatchSemaphore(value:0)
        private var stopped = false
        let url: URL
        init(_ f: Fixture) throws {
            process.executableURL = URL(fileURLWithPath:"/usr/bin/env")
            process.arguments = ["node",f.resources.appendingPathComponent("../campaign-relay/native-harness.cjs").standardizedFileURL.path,f.root.appendingPathComponent("receiver.sqlite").path]
            // Async test continuations may change threads between run/stop.
            // Foundation waitUntilExit can strand its run-loop notification;
            // register an explicit completion before launching the child.
            process.terminationHandler = { [terminated] _ in terminated.signal() }
            process.standardOutput = output; process.standardError = errors; try process.run()
            var data = Data()
            while data.count < 4096, let byte = try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty { data.append(byte); if byte[0] == 10 { break } }
            guard let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let port = json["port"] as? Int else {
                if process.isRunning { process.terminate() }; _ = terminated.wait(timeout:.now()+10); throw NativeDBError.message("Local relay failed to start")
            }
            url = URL(string:"http://127.0.0.1:\(port)/crm")!
        }
        func stop() {
            guard !stopped else { return }; stopped = true
            if process.isRunning { process.terminate() }
            precondition(terminated.wait(timeout:.now()+10) == .success,"Local relay failed to exit within10 seconds")
        }
        deinit { stop() }
        func client(_ db: NativeDatabase, now: @escaping () -> Date, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network) throws -> CampaignRelayClient {
            try CampaignRelayClient(baseURL:url,authKey:key,clientID:CampaignRelayBinding.clientID(db:db),allowLoopbackHTTP:true,request:request,clock:now)
        }
        func unsubscribe(_ token: String) async throws {
            var parts = URLComponents(url:url.appendingPathComponent("api/campaigns/unsubscribe"),resolvingAgainstBaseURL:false)!
            parts.queryItems = [.init(name:"token",value:token)]
            let (_,response) = try await CampaignRelayClient.network(URLRequest(url:parts.url!))
            guard response.statusCode == 200 else { throw NativeDBError.message("unsubscribe HTTP failed") }
        }
        func webhook(_ kind: String, provider: String, id: String, now: Date) async throws {
            let body = try JSONSerialization.data(withJSONObject:["type":kind,"data":["email_id":provider]],options:.sortedKeys)
            let stamp = String(Int64(floor(now.timeIntervalSince1970)))
            var signed = Data((id+"."+stamp+".").utf8); signed.append(body)
            let mac = HMAC<SHA256>.authenticationCode(for:signed,using:SymmetricKey(data:Data("relay-fixture-signing-key-not-real".utf8)))
            var request = URLRequest(url:url.appendingPathComponent("api/campaigns/webhooks/resend")); request.httpMethod = "POST"; request.httpBody = body
            request.setValue(id,forHTTPHeaderField:"svix-id"); request.setValue(stamp,forHTTPHeaderField:"svix-timestamp")
            request.setValue("v1,"+Data(mac).base64EncodedString(),forHTTPHeaderField:"svix-signature")
            let (_,response) = try await CampaignRelayClient.network(request)
            guard response.statusCode == 200 else { throw NativeDBError.message("webhook HTTP failed") }
        }
    }
    static func run(_ resources: URL) async throws {
        try await offlineAndAtomic(resources)
        try await pagesAndReceiptRetry(resources)
        try await finalGateAndBinding(resources)
        print("CampaignRelaySyncTests: \(checks) checks passed; real loopback relay, native SQLite, fake outgoing mail only")
    }
    static func offlineAndAtomic(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try Server(f); defer { server.stop() }
        f.config = try CampaignMailConfiguration(publicURL:server.url.absoluteString,allowLoopbackHTTP:true)
        let client = try server.client(f.db,now:{f.now}), binding = try await CampaignRelayBinding.connect(db:f.db,client:client)
        let sync = try CampaignRelaySync(db:f.db,client:client,binding:binding,clock:{f.now})
        let received = f.now
        let worker = f.worker(ready:{ config in try await sync.prepareToSend(sendID:f.sendID,configuration:config) },request:{ request,body in
            try await server.webhook("email.opened",provider:f.providerID,id:"msg_sync_early",now:f.now)
            return try f.response(request,body)
        })
        _ = try await worker.runNext()
        try check(try f.job().status == "done" && f.bodies.count == 1,"send follows actual registered endpoint")
        try check(try f.send()["opened_at"] == .null,"early remote callback awaits native provider mapping")
        f.now = f.now.addingTimeInterval(60)
        let first = try await sync.synchronize()
        try check(first == 1 && (try f.send()["opened_at"]) == .text(try CampaignWorkflow.stamp(received)),"original server time retained after delayed sync")
        try check(try CampaignEventTests.scalar(f,"SELECT processed_at FROM native_campaign_events WHERE event_id='msg_sync_early'") == CampaignWorkflow.stamp(f.now),"processing time is local sync time")
        let duplicate = try f.db.insert("crm_Targets",values:["last_name":.text("別記録"),"email":.text("RECIPIENT@example.invalid"),"created_by":.text(f.service.identity.id)],actor:f.service.identity.id)
        try await server.unsubscribe(f.send()["unsubscribe_token"].string)
        try f.sql("CREATE TRIGGER fail_sync_cursor BEFORE UPDATE ON native_metadata WHEN NEW.key='campaignRelay.binding.v1' BEGIN SELECT RAISE(ABORT,'test cursor failure'); END;")
        try await rejects("cursor commit failure"){_ = try await sync.synchronize()}
        try check(try f.send()["unsubscribed_at"] == .null && f.fresh(f.target)["do_not_email"] == .integer(0) && f.fresh(duplicate)["do_not_email"] == .integer(0),"all suppression rolls back with cursor")
        try check(try CampaignRelayBinding.load(db:f.db)?.cursor == 1,"failed page does not advance cursor")
        try f.sql("DROP TRIGGER fail_sync_cursor")
        let connection = try f.connection(), restarted = try CampaignRelaySync(db:connection,client:client,binding:binding,clock:{f.now})
        let resumed = try await restarted.synchronize()
        try check(resumed == 1 && (try f.fresh(f.target)["do_not_email"]) == .integer(1) && (try f.fresh(duplicate)["do_not_email"]) == .integer(1),"offline click applies globally after native connection restart")
        try check(try f.send()["unsubscribed_at"] == .text(CampaignWorkflow.stamp(received)),"unsubscribe keeps server time")
        let empty = try await restarted.synchronize()
        try check(empty == 0 && f.bodies.count == 1,"duplicate sync cannot send another message")
        // Competing synchronizers must not replay an old page after another
        // connection has atomically committed that page's effects and cursor.
        try await server.webhook("email.clicked",provider:f.providerID,id:"msg_sync_competing",now:received)
        let pending = try await client.events(after:2), targetCursor = pending.cursor!
        try check(pending.events?.count == 1 && targetCursor > 3,"single new event may have a sequence gap")
        var advanced = false
        let competingClient = try server.client(f.db,now:{f.now},request:{ request in
            let response = try await CampaignRelayClient.network(request)
            if request.url!.path.hasSuffix("/events"), !advanced { advanced = true; _ = try await restarted.synchronize() }
            return response
        })
        let competing = try CampaignRelaySync(db:f.db,client:competingClient,binding:binding,clock:{f.now})
        try await rejects("stale page from second connection"){_ = try await competing.synchronize()}
        try check(try CampaignRelayBinding.load(db:f.db)?.cursor == targetCursor && f.send()["clicked_at"] != .null,"winning page effects preserved")
        let recovered = try await competing.synchronize(); try check(recovered == 0,"stale reader resumes from committed cursor")
    }
    static func pagesAndReceiptRetry(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try Server(f); defer { server.stop() }
        f.config = try CampaignMailConfiguration(publicURL:server.url.absoluteString,allowLoopbackHTTP:true)
        let client = try server.client(f.db,now:{f.now}), binding = try await CampaignRelayBinding.connect(db:f.db,client:client)
        let sync = try CampaignRelaySync(db:f.db,client:client,binding:binding,clock:{f.now})
        _ = try await f.worker(ready:{config in try await sync.prepareToSend(sendID:f.sendID,configuration:config)}).runNext()
        var lost = false
        let unreliable = try server.client(f.db,now:{f.now},request:{ request in
            let response = try await CampaignRelayClient.network(request)
            if request.url!.path.hasSuffix("/registrations"), !lost { lost = true; throw URLError(.networkConnectionLost) }; return response
        })
        let retrying = try CampaignRelaySync(db:f.db,client:unreliable,binding:binding,clock:{f.now})
        try await rejects("receipt accepted remotely but response lost"){_ = try await retrying.synchronize()}
        try check(try f.db.campaignRelayReceiptIDs(instanceID:binding.instanceID,publicURL:binding.publicURL,after:"") == [f.sendID],"provider mapping remains pending after lost response")
        _ = try await sync.synchronize()
        try check(try f.db.campaignRelayReceiptIDs(instanceID:binding.instanceID,publicURL:binding.publicURL,after:"").isEmpty && f.bodies.count == 1,"mapping retry does not resend mail")
        let original = try f.send(), intent = try f.db.campaignMailIntent(sendID:f.sendID)!
        var sends: [NativeRecord] = []
        try f.db.transaction {
            for index in 0..<206 {
                let target = try f.db.insert("crm_Targets",values:["last_name":.text("ページ\(index)"),"email":.text("page\(index)@example.invalid"),"created_by":.text(f.service.identity.id)],actor:f.service.identity.id)
                let send = try f.db.insert("crm_campaign_sends",values:["campaign_id":original["campaign_id"],"step_id":original["step_id"],"target_id":target["id"],"email":target["email"]],actor:f.service.identity.id)
                try f.db.queueCampaignSend(send,token:intent.token,actorID:intent.actorID,now:f.now)
                let provider = UUID().uuidString.lowercased()
                try f.change(send,["status":.text("sent"),"resend_message_id":.text(provider),"sent_at":.text(CampaignWorkflow.stamp(f.now))])
                // Isolated fixture only: these represent prior accepted receipts.
                // Use the production leased-result API to make each receipt durable.
                let job = try f.db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:f.now)!
                guard job.id == send["id"].string else { throw NativeDBError.message("Fixture receipt/send mismatch") }
                try f.db.recordJobResult(job,result:["publicURL":binding.publicURL,"providerID":provider,"acceptedAt":CampaignWorkflow.stamp(f.now)])
                try f.db.finishJob(job,result:f.db.requireJobLease(job).result,now:f.now)
                sends.append(try f.fresh(send))
            }
        }
        let page = try f.db.campaignRelayReceiptIDs(instanceID:binding.instanceID,publicURL:binding.publicURL,after:"")
        try check(page.count == 100,"receipt SQL bounded to100")
        _ = try await sync.synchronize()
        try check(try f.db.campaignRelayReceiptIDs(instanceID:binding.instanceID,publicURL:binding.publicURL,after:"").isEmpty,"all206 receipt mappings uploaded across keyset pages")
        for send in sends { try await server.unsubscribe(send["unsubscribe_token"].string) }
        let failID = sends[100]["target_id"].string
        try f.sql("CREATE TRIGGER fail_second_page BEFORE UPDATE ON crm_Targets WHEN OLD.id='\(failID)' BEGIN SELECT RAISE(ABORT,'test second page'); END;")
        try await rejects("later page fails atomically"){_ = try await sync.synchronize()}
        try check(try CampaignRelayBinding.load(db:f.db)?.cursor == 100,"first100 committed before second page failed")
        try check(try f.fresh(sends[99])["unsubscribed_at"] != .null && f.fresh(sends[100])["unsubscribed_at"] == .null && f.fresh(sends[205])["unsubscribed_at"] == .null,"only committed page effects survive")
        try f.sql("DROP TRIGGER fail_second_page")
        let connection = try f.connection(), resumed = try CampaignRelaySync(db:connection,client:client,binding:binding,clock:{f.now})
        let rest = try await resumed.synchronize()
        try check(rest == 106 && (try CampaignRelayBinding.load(db:f.db)?.cursor) == 206,"resume remaining106 without resetting cursor")
        try check(try f.fresh(sends[205])["unsubscribed_at"] != .null && f.bodies.count == 1,"last page applied without outbound messages")
    }
    static func finalGateAndBinding(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), server = try Server(f); defer { server.stop() }
        f.config = try CampaignMailConfiguration(publicURL:server.url.absoluteString,allowLoopbackHTTP:true)
        let client = try server.client(f.db,now:{f.now})
        try f.sql("CREATE TRIGGER fail_bind BEFORE INSERT ON native_metadata WHEN NEW.key='campaignRelay.binding.v1' BEGIN SELECT RAISE(ABORT,'test bind failure'); END;")
        try await rejects("remote bind survives local commit failure"){_ = try await CampaignRelayBinding.connect(db:f.db,client:client)}
        try check(try CampaignRelayBinding.load(db:f.db) == nil,"failed bind writes no partial local identity")
        try f.sql("DROP TRIGGER fail_bind")
        let binding = try await CampaignRelayBinding.connect(db:f.db,client:client)
        try check(try CampaignRelayBinding.clientID(db:f.connection()) == binding.clientID,"permanent client identity survives connection restart")
        let sync = try CampaignRelaySync(db:f.db,client:client,binding:binding,clock:{f.now})
        _ = try await f.worker(ready:{config in
            try await sync.prepareToSend(sendID:f.sendID,configuration:config)
            try await server.unsubscribe(f.send()["unsubscribe_token"].string)
            _ = try await sync.synchronize()
        }).runNext()
        try check(f.bodies.isEmpty && (try f.job().result["outcome"]) == "skipped","final worker gate observes synced opt-out before sending")
        try check(try f.job().deliveryStartedAt == nil,"suppressed mail never starts external request")
        let replacement = try CampaignRelayClient(baseURL:URL(string:"https://different.example.invalid")!,authKey:key,clientID:binding.clientID,request:{_ in throw NativeDBError.message("must not contact replacement")})
        try await rejects("cannot swap established endpoint"){_ = try await CampaignRelayBinding.connect(db:f.db,client:replacement)}
        try check(try CampaignRelayBinding.load(db:f.db)?.instanceID == binding.instanceID,"rejected replacement keeps binding")
        // A provider association not backed by a local receipt requires review;
        // it cannot be adopted as proof, and must not lead to another send.
        let other = try await Fixture.make(resources), otherServer = try Server(other); defer { otherServer.stop() }
        other.config = try CampaignMailConfiguration(publicURL:otherServer.url.absoluteString,allowLoopbackHTTP:true)
        let otherClient = try otherServer.client(other.db,now:{other.now}), otherBinding = try await CampaignRelayBinding.connect(db:other.db,client:otherClient)
        _ = try await otherClient.register([.init(sendId:other.sendID,token:other.send()["unsubscribe_token"].string,providerId:UUID().uuidString.lowercased())])
        let otherSync = try CampaignRelaySync(db:other.db,client:otherClient,binding:otherBinding,clock:{other.now})
        _ = try await other.worker(ready:{config in try await otherSync.prepareToSend(sendID:other.sendID,configuration:config)}).runNext()
        try check(other.bodies.isEmpty && (try other.send()["resend_message_id"]) == .null,"unconfirmed remote receipt is neither adopted nor resent")
    }
}
