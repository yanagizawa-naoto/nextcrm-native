import Foundation

struct CampaignDeliveryRow { let send: NativeRecord; let job: NativeJob? }

extension CRMService {
    /// Historical recipients remain readable even if the target was deleted or
    /// its address changed. Access follows the campaign, never a stale UI row.
    func campaignDeliveries(_ id: String, search: String = "", status: String? = nil, offset: Int = 0) throws -> (rows:[CampaignDeliveryRow],total:Int) {
        try db.transaction {
            _ = try campaign(id)
            if let status, !["queued","sending","sent","delivered","bounced","failed"].contains(status) { throw NativeDBError.message("送信状態が不正です。") }
            var equal: [String:SQLValue] = ["campaign_id":.text(id)]
            if let status { equal["status"] = .text(status) }
            let page = try db.page("crm_campaign_sends",fields:["campaign_id","step_id","target_id","email","status","sent_at","opened_at","clicked_at","unsubscribed_at","error_message","resend_message_id"],search:search,equal:equal,offset:offset,sort:"id",descending:true)
            return (try page.rows.map { CampaignDeliveryRow(send:$0,job:try db.job(id:$0["id"].string)) },page.total)
        }
    }
    func campaignJobs(_ id: String, offset: Int = 0) throws -> [NativeJob] {
        try db.transaction { _ = try campaign(id); return try db.jobs(events:CampaignWorkflow.events,campaignID:id,offset:offset) }
    }
    func campaignMailJobAccess(_ id: String) throws -> NativeJob {
        try authenticated()
        guard identity.elevated else { throw NativeDBError.message("メールの再試行・取消・結果確認ができるのは管理者とマネージャーです。") }
        guard let job = try db.job(id:id), job.event == CampaignWorkflow.sendStepEvent, job.payload["sendId"] == id,
              let campaignID = job.payload["campaignId"], let send = try db.get("crm_campaign_sends",key:["id":.text(id)]), send["campaign_id"] == .text(campaignID) else { throw NativeDBError.message("メールまたはキャンペーンが見つかりません。") }
        _ = try campaign(campaignID)
        return job
    }
    func retryCampaignMailJob(_ expected: NativeJob, now: Date = Date()) throws {
        try db.transaction {
            let current = try campaignMailJobAccess(expected.id)
            guard current == expected, let id = current.payload["campaignId"] else { throw NativeDBError.conflict }
            let c = try campaign(id)
            guard ["sending","sent"].contains(c["status"].string), let intent = try db.campaignMailIntent(sendID:current.id),
                  try db.metadata(CampaignWorkflow.runKey(id)) == intent.token else { throw NativeDBError.message("停止・変更されたキャンペーンです。先にキャンペーンの状態を確認してください。") }
            guard current.result["relayProviderIDHint"] == nil else { throw NativeDBError.message("受信窓口に未確認の受付IDがあります。送信結果を確認してください。") }
            try db.retryJob(id:current.id,now:now)
        }
    }
    func cancelCampaignMailJob(_ expected: NativeJob, now: Date = Date()) throws {
        try db.transaction {
            let current = try campaignMailJobAccess(expected.id)
            guard current == expected, let id = current.payload["campaignId"], let send = try db.get("crm_campaign_sends",key:["id":.text(current.id)]) else { throw NativeDBError.conflict }
            guard current.result["providerID"] == nil, current.result["relayProviderIDHint"] == nil,
                  send["resend_message_id"] == .null, ["queued","failed"].contains(send["status"].string) else { throw NativeDBError.message("送信結果を確認する必要があるため取り消せません。") }
            let result = current.result.merging(["cancelledBy":identity.id,"cancelledAt":try CampaignWorkflow.stamp(now),"outcome":"cancelled"]){_,v in v}
            try db.cancelJob(id:current.id,result:result)
            _ = try db.update(send,changes:["status":.text("failed"),"error_message":.text("送信を取り消しました。")],actor:identity.id,action:"campaign_mail_cancelled")
            try CampaignDispatch.finishInitialIfReady(db:db,campaignID:id,actorID:identity.id,now:now)
            try db.deferTerminalMailBodyCleanup(id:expected.id)
        }
    }
    /// This decision is terminal for the permanent send ID. It never creates a
    /// replacement mail; resume/fanout cannot rearm a reviewed recipient.
    func reviewCampaignMailJob(_ expected: NativeJob, outcome: MailReviewOutcome, providerID: String, note: String, now: Date = Date()) throws {
        let memo = note.trimmingCharacters(in:.whitespacesAndNewlines), supplied = providerID.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !memo.isEmpty, memo.count <= 2000, memo.utf8.count <= 8000 else { throw NativeDBError.message("確認した内容を2,000文字以内で記入してください。") }
        let receipt: String?
        if outcome == .accepted {
            guard let id = UUID(uuidString:supplied), id.uuidString.lowercased() == supplied.lowercased() else { throw NativeDBError.message("送信サービスで確認した受付IDを入力してください。") }
            receipt = id.uuidString.lowercased()
        } else {
            guard supplied.isEmpty else { throw NativeDBError.message("受付IDがある場合は「送信サービスの受付を確認」を選択してください。") }; receipt = nil
        }
        try db.transaction {
            let current = try campaignMailJobAccess(expected.id)
            guard current == expected else { throw NativeDBError.conflict }
            guard current.canReviewMail, let campaignID = current.payload["campaignId"], let send = try db.get("crm_campaign_sends",key:["id":.text(current.id)]) else { throw NativeDBError.message("このメールは結果確認で終了できません。実行中の処理は完了を待ってください。") }
            for known in [current.result["providerID"],send["resend_message_id"] == .null ? nil : send["resend_message_id"].string].compactMap({$0}) {
                guard receipt == known.lowercased() else { throw NativeDBError.message("保存済みの受付IDと矛盾する結果は記録できません。") }
            }
            if let receipt, let hint = current.result["relayProviderIDHint"], receipt != hint.lowercased() { throw NativeDBError.message("受信窓口に残る受付IDと異なります。対象のメールを確認してください。") }
            var result = current.result
            result["reviewOutcome"] = outcome.rawValue; result["reviewedBy"] = identity.id
            result["reviewerName"] = try db.get("Users",key:["id":.text(identity.id)])?["name"].string
            result["reviewedAt"] = try CampaignWorkflow.stamp(now); result["reviewNote"] = memo
            result["reviewPreviousStatus"] = current.status; result["reviewPreviousError"] = current.lastError
            if let receipt {
                guard try db.page("crm_campaign_sends",fields:[],equal:["resend_message_id":.text(receipt)],limit:2).rows.allSatisfy({$0["id"] == send["id"]}) else { throw NativeDBError.message("その受付IDは別のメールに記録されています。") }
                result["providerID"] = receipt; result["outcome"] = "sent"
                // This records when acceptance became known, not a fabricated
                // provider delivery time. Earlier saved acceptance wins.
                if result["acceptedAt"] == nil { result["acceptedAt"] = try CampaignWorkflow.stamp(now) }
                var changes: [String:SQLValue] = ["resend_message_id":.text(receipt)]
                if send["sent_at"] == .null { changes["sent_at"] = .text(result["acceptedAt"]!) }
                if !["delivered","bounced"].contains(send["status"].string) { changes["status"] = .text("sent"); changes["error_message"] = .null }
                _ = try db.update(send,changes:changes,actor:identity.id,action:"campaign_mail_review")
                try db.reconcileCampaignEvents(providerID:receipt,now:now)
            } else {
                result["outcome"] = outcome == .notSent ? "not_sent" : "unconfirmed"
                // Both decisions terminate local work. Delivery certainty is
                // retained in reviewOutcome and shown separately in history.
                _ = try db.update(send,changes:["status":.text("failed"),"error_message":.text(outcome == .notSent ? "確認結果：送信されていません。" : "確認結果：送信結果は不明です。")],actor:identity.id,action:"campaign_mail_review")
            }
            try db.completeReviewedMail(current,result:result,now:now)
            try CampaignDispatch.finishInitialIfReady(db:db,campaignID:campaignID,actorID:identity.id,now:now)
            _ = try CampaignRelayJobs.request(db:db,now:now)
            try db.deferTerminalMailBodyCleanup(id:expected.id)
        }
        NotificationCenter.default.post(name:NativeDatabase.jobsDidChange,object:db,userInfo:["database":db.url.path])
    }
}
