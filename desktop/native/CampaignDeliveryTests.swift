import Foundation

enum CampaignDeliveryTests {
    typealias Fixture = CampaignMailTests.Fixture
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ message: String) throws {
        guard try condition() else { throw NativeDBError.message("CampaignDelivery FAIL: "+message) }; checks += 1
    }
    static func rejects(_ label: String,_ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw NativeDBError.message("CampaignDelivery accepted: "+label)
    }
    static func uncertain(_ resources: URL) async throws -> Fixture {
        let f = try await Fixture.make(resources)
        _ = try await f.worker(request:{r,u in _ = try f.response(r,u); throw URLError(.timedOut)}).runNext()
        f.now.addTimeInterval(24*3600)
        _ = try await f.worker().runNext()
        try check(try f.job().status == "needs_review", "fixture has uncertain external result")
        return f
    }
    static func run(_ resources: URL) async throws {
        try await decisions(resources)
        try await cancellationAndRetry(resources)
        try await permissionsAndAtomicity(resources)
        try await history(resources)
        try await relayEvidence(resources)
        print("CampaignDeliveryTests: \(checks) checks passed; terminal review, cancellation, paging, real loopback; no external mail")
    }
    static func decisions(_ resources: URL) async throws {
        for outcome in MailReviewOutcome.allCases {
            let f = try await uncertain(resources), original = try f.job(), frozen = try Data(contentsOf:f.bodyURL())
            let provider = outcome == .accepted ? f.providerID.uppercased() : ""
            try f.service.reviewCampaignMailJob(original,outcome:outcome,providerID:provider,note:"サービスの管理画面で処理ID・宛先・件名を確認しました。",now:f.now)
            let finished = try f.job(), send = try f.send()
            try check(finished.status == "done" && finished.result["reviewOutcome"] == outcome.rawValue, "terminal decision retained: "+outcome.rawValue)
            try check(finished.result["reviewedBy"] == f.service.identity.id && finished.result["reviewNote"] != nil && finished.result["reviewPreviousError"] != nil, "review audit retained")
            try check(finished.deliveryStartedAt == original.deliveryStartedAt && finished.result["sha256"] == original.result["sha256"] && !frozen.isEmpty, "first request and body digest retained")
            try check(send["status"] == .text(outcome == .accepted ? "sent" : "failed") && send["resend_message_id"] == (outcome == .accepted ? .text(f.providerID) : .null), "domain review result")
            try check(try f.fresh(f.campaign)["status"] == .text("sent"), "last reviewed initial send completes campaign")
            try check(try !FileManager.default.fileExists(atPath:f.bodyURL().path), "body released after successful review")
            let connection = try f.connection(), service = CRMService(db:connection,identity:f.service.identity)
            try rejects("repeated stale decision"){try service.reviewCampaignMailJob(original,outcome:outcome,providerID:provider,note:"再確認",now:f.now)}
            let intent = try f.db.campaignMailIntent(sendID:f.sendID)!
            try connection.queueCampaignSend(send,token:intent.token,actorID:intent.actorID,now:f.now)
            let ran = try await f.worker(connection:connection).runNext()
            try check(!ran && f.bodies.count == 1 && (try f.job()) == finished, "restart/fanout cannot resend reviewed mail")
        }
        do {
            let f = try await uncertain(resources)
            let stamp = try CampaignWorkflow.stamp(f.now.addingTimeInterval(-10))
            try f.change(f.send(),["status":.text("bounced"),"resend_message_id":.text(f.providerID),"sent_at":.text(stamp),"opened_at":.text(stamp),"unsubscribed_at":.text(stamp),"error_message":.text("bounce")])
            try f.change(f.campaign,["status":.text("paused")])
            let job = try f.job()
            try rejects("known receipt cannot be declared unsent"){try f.service.reviewCampaignMailJob(job,outcome:.notSent,providerID:"",note:"矛盾",now:f.now)}
            try f.service.reviewCampaignMailJob(job,outcome:.accepted,providerID:f.providerID,note:"受付を確認",now:f.now)
            try check(try f.send()["status"] == .text("bounced") && f.send()["opened_at"] == .text(stamp) && f.send()["unsubscribed_at"] == .text(stamp) && f.send()["sent_at"] == .text(stamp) && f.send()["error_message"] == .text("bounce"), "review preserves delivery/tracking timestamps and bounce")
            try check(try f.fresh(f.campaign)["status"] == .text("paused"), "review never unpauses campaign")
        }
        do {
            let f = try await uncertain(resources)
            _ = try f.db.receiveCampaignEvent(id:"review-early-delivery",providerID:f.providerID,kind:"email.delivered",bodySHA256:String(repeating:"a",count:64),now:f.now)
            try f.service.reviewCampaignMailJob(f.job(),outcome:.accepted,providerID:f.providerID,note:"受付を確認",now:f.now)
            try check(try f.send()["status"] == .text("delivered"), "review reconciles earlier provider observation")
        }
    }
    static func cancellationAndRetry(_ resources: URL) async throws {
        do {
            let f = try await Fixture.make(resources), pending = try f.job()
            try f.service.cancelCampaignMailJob(pending,now:f.now)
            let cancelled = try f.job()
            try check(cancelled.status == "cancelled" && cancelled.result["cancelledBy"] == f.service.identity.id && (try f.send()["status"]) == .text("failed"), "recipient cancellation is atomic")
            try check(try f.fresh(f.campaign)["status"] == .text("sent"), "last cancellation finishes initial work")
            let intent = try f.db.campaignMailIntent(sendID:f.sendID)!
            try f.db.queueCampaignSend(f.send(),token:UUID().uuidString,actorID:intent.actorID,now:f.now)
            let ran = try await f.worker().runNext()
            try check(!ran && f.bodies.isEmpty && (try f.job()) == cancelled, "explicit cancellation survives fanout/resume")
            try rejects("cancel stale row"){try f.service.cancelCampaignMailJob(pending,now:f.now)}
            try rejects("retry cancelled"){try f.service.retryCampaignMailJob(cancelled,now:f.now)}
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(ready:{_ in throw CampaignRelayError(message:"一時的な停止",retryable:true)}).runNext()
            let before = try f.job(), bytes = try Data(contentsOf:f.bodyURL())
            try f.service.retryCampaignMailJob(before,now:f.now)
            try rejects("retry changed row"){try f.service.retryCampaignMailJob(before,now:f.now)}
            _ = try await f.worker().runNext()
            try check(f.bodies.count == 1 && f.bodies[0] == bytes && f.keys == ["campaign-send/"+f.sendID], "manual retry retains exact body and permanent ID")
        }
        do {
            let f = try await uncertain(resources), before = try f.job()
            try rejects("cancel uncertain send"){try f.service.cancelCampaignMailJob(before,now:f.now)}
            try rejects("retry expired uncertainty"){try f.service.retryCampaignMailJob(before,now:f.now)}
            try check(try f.job() == before && f.bodies.count == 1, "rejected commands leave unknown result untouched")
        }
        do {
            let f = try await Fixture.make(resources)
            _ = try await f.worker(ready:{_ in throw CampaignRelayError(message:"一時的な停止",retryable:true)}).runNext()
            _ = try f.service.pauseCampaign(f.fresh(f.campaign))
            try rejects("retry paused campaign"){try f.service.retryCampaignMailJob(f.job(),now:f.now)}
            try check(f.bodies.isEmpty, "paused retry makes no request")
        }
    }
    static func permissionsAndAtomicity(_ resources: URL) async throws {
        let f = try await uncertain(resources), expected = try f.job(), send = try f.send(), campaign = try f.fresh(f.campaign)
        let user = try f.db.get("Users",key:["id":.text(f.service.identity.id)])!
        try f.change(user,["role":.text("user")])
        try rejects("stale elevated identity"){try f.service.reviewCampaignMailJob(expected,outcome:.accepted,providerID:f.providerID,note:"確認",now:f.now)}
        let regular = CRMService(db:f.db,identity:.init(id:f.service.identity.id,role:"user",partnerAccountID:nil))
        try rejects("ordinary owner may not confirm mail"){try regular.reviewCampaignMailJob(expected,outcome:.accepted,providerID:f.providerID,note:"確認",now:f.now)}
        try f.change(user,["role":.text("admin"),"banned":.integer(1)])
        try rejects("banned reviewer"){try f.service.reviewCampaignMailJob(expected,outcome:.accepted,providerID:f.providerID,note:"確認",now:f.now)}
        try f.change(user,["banned":.integer(0)])
        for (id,memo) in [("bad","確認"),(f.providerID," "),(f.providerID,String(repeating:"あ",count:2001))] {
            try rejects("invalid review input"){try f.service.reviewCampaignMailJob(expected,outcome:.accepted,providerID:id,note:memo,now:f.now)}
        }
        try f.sql("CREATE TRIGGER reject_review BEFORE UPDATE ON native_outbox WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT,'test failure'); END")
        try rejects("outbox completion failure"){try f.service.reviewCampaignMailJob(expected,outcome:.accepted,providerID:f.providerID,note:"確認",now:f.now)}
        try check(try f.job() == expected && f.send().values == send.values && f.send().revision == send.revision && f.fresh(f.campaign).values == campaign.values && f.fresh(f.campaign).revision == campaign.revision && FileManager.default.fileExists(atPath:f.bodyURL().path), "failed review rolls back send/campaign/outbox and retains body")
        try f.sql("DROP TRIGGER reject_review")
        let otherID = UUID().uuidString.lowercased()
        try f.db.enqueue("invoice.email_requested",payload:[:],id:otherID,now:f.now)
        let other = try f.db.claimJob(events:["invoice.email_requested"],now:f.now)!
        try f.db.finishJob(other,result:["providerID":f.providerID],now:f.now)
        try rejects("receipt owned by another mail"){try f.service.reviewCampaignMailJob(expected,outcome:.accepted,providerID:f.providerID,note:"確認",now:f.now)}
        try check(try f.job() == expected && f.send().values == send.values && f.send().revision == send.revision, "duplicate receipt rollback")
        let second = try f.connection(), reviewer = CRMService(db:second,identity:f.service.identity)
        try reviewer.reviewCampaignMailJob(expected,outcome:.unknown,providerID:"",note:"確認できず終了",now:f.now)
        try rejects("two-connection stale reviewer"){try f.service.reviewCampaignMailJob(expected,outcome:.accepted,providerID:f.providerID,note:"古い画面",now:f.now)}
        try check(try f.job().result["reviewOutcome"] == "unknown", "winning reviewer preserved")
    }
    static func history(_ resources: URL) async throws {
        let f = try await Fixture.make(resources), initial = try f.send()
        try f.db.transaction {
            for index in 0..<204 {
                let target = try f.db.insert("crm_Targets",values:["last_name":.text("履歴\(index)"),"email":.text("history\(index)@example.invalid"),"created_by":.text(f.service.identity.id)],actor:f.service.identity.id)
                let send = try f.db.insert("crm_campaign_sends",values:["campaign_id":initial["campaign_id"],"step_id":initial["step_id"],"target_id":target["id"],"email":target["email"]],actor:f.service.identity.id)
                try f.db.queueCampaignSend(send,token:UUID().uuidString,actorID:f.service.identity.id,now:f.now)
            }
        }
        let pages = try [0,100,200].map{try f.service.campaignDeliveries(f.campaign["id"].string,offset:$0)}
        try check(pages.map{$0.rows.count} == [100,100,5] && pages.allSatisfy{$0.total == 205}, "history SQL bounded to100")
        try check(Set(pages.flatMap{$0.rows.map{$0.send["id"].string}}).count == 205 && pages.allSatisfy{$0.rows.allSatisfy{$0.job?.id == $0.send["id"].string}}, "pages do not repeat and jobs match each recipient")
        try check(try f.service.campaignJobs(f.campaign["id"].string).count == 100, "campaign job history is bounded")
        let filtered = try f.service.campaignDeliveries(f.campaign["id"].string,search:"history203@example.invalid")
        try check(filtered.total == 1 && filtered.rows.count == 1, "history email search")
        try check(try f.service.campaignDeliveries(f.campaign["id"].string,status:"delivered").total == 0, "history status filter")
        try f.change(f.target,["deletedAt":.text(try CampaignWorkflow.stamp(f.now))])
        try check(try f.service.campaignDeliveries(f.campaign["id"].string,search:"recipient@example.invalid").total == 1, "deleted target does not hide historical recipient")
        let other = try f.service.createCampaign(input:["name":.text("別キャンペーン")])
        try check(try f.service.campaignDeliveries(other["id"].string).total == 0 && f.service.campaignJobs(other["id"].string).isEmpty, "campaign scopes cannot leak other history")
    }
    static func relayEvidence(_ resources: URL) async throws {
        for outcome in MailReviewOutcome.allCases {
            let f = try await Fixture.make(resources), server = try CampaignRelaySyncTests.Server(f); defer { server.stop() }
            f.config = try CampaignMailConfiguration(publicURL:server.url.absoluteString,allowLoopbackHTTP:true)
            let client = try server.client(f.db,now:{f.now}), binding = try await CampaignRelayBinding.connect(db:f.db,client:client)
            let sync = try CampaignRelaySync(db:f.db,client:client,binding:binding,clock:{f.now})
            _ = try await client.register([.init(sendId:f.sendID,token:f.send()["unsubscribe_token"].string,providerId:f.providerID)])
            _ = try await f.worker(ready:{config in try await sync.prepareToSend(sendID:f.sendID,configuration:config)}).runNext()
            let job = try f.job()
            try check(job.status == "needs_review" && job.deliveryStartedAt == nil && job.result["providerID"] == nil && job.result["relayProviderIDHint"] == f.providerID && job.result["relayInstanceIDHint"] == binding.instanceID && job.canReviewMail, "signed remote evidence durable and reviewable without invented local request")
            try rejects("remote hint cannot be retried"){try f.service.retryCampaignMailJob(job,now:f.now)}
            try rejects("different provider than signed hint"){try f.service.reviewCampaignMailJob(job,outcome:.accepted,providerID:UUID().uuidString,note:"不一致",now:f.now)}
            try await server.webhook("email.delivered",provider:f.providerID,id:"review-relay-"+outcome.rawValue,now:f.now)
            try await server.unsubscribe(f.send()["unsubscribe_token"].string)
            let connection = try f.connection(), reviewer = CRMService(db:connection,identity:f.service.identity)
            try reviewer.reviewCampaignMailJob(job,outcome:outcome,providerID:outcome == .accepted ? f.providerID : "",note:"外部サービスで確認した内容",now:f.now)
            _ = try await sync.synchronize()
            try check(f.bodies.isEmpty && (try f.send()["resend_message_id"]) == (outcome == .accepted ? .text(f.providerID) : .null), "explicit review never sends/adopts an unconfirmed receipt")
            try check(try f.send()["unsubscribed_at"] != .null && f.fresh(f.target)["do_not_email"] == .integer(1), "terminal review does not block later unsubscribe")
            try check(try f.send()["status"] == .text(outcome == .accepted ? "delivered" : "failed"), "delivery observations apply only to confirmed receipt")
            try check(try f.db.jobs(events:[CampaignRelayJobs.event]).contains{$0.status == "pending"}, "review queues durable synchronization")
        }
    }
}
