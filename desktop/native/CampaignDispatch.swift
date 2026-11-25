import Foundation

enum CampaignDispatch {
    /// Sending can finish only after the entire initial cohort has been
    /// materialized, not between two 100-recipient batches.
    static func finishInitialIfReady(db: NativeDatabase, campaignID: String, actorID: String, now: Date) throws {
        try db.transaction {
            guard let campaign = try db.get("crm_campaigns",key:["id":.text(campaignID)]),
                  campaign["deletedAt"] == .null, campaign["status"] == .text("sending"),
                  let token = try db.metadata(CampaignWorkflow.runKey(campaignID)),
                  try db.metadata(CampaignWorkflow.dispatchDoneKey(campaignID)) == token,
                  try !db.campaignInitialWaiting(campaignID) else { return }
            _ = try db.update(campaign,changes:["status":.text("sent"),"sent_at":.text(try CampaignWorkflow.stamp(now))],actor:actorID,action:"initial_dispatch_finished")
        }
    }
}

/// Local dispatch only: snapshots recipients, creates stable delivery jobs, and
/// schedules followups. The mail worker owns external requests and receipts.
actor CampaignDispatchWorker {
    let db: NativeDatabase
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, clock: @escaping () -> Date = Date.init) { self.db = db; self.clock = clock }
    private struct Skip: Error { let reason: String }
    private struct Context { let campaign: NativeRecord; let actorID: String; let token: String }
    private func context(_ job: NativeJob) throws -> Context {
        guard CampaignWorkflow.dispatchEvents.contains(job.event), let id = job.payload["campaignId"],
              let actorID = job.payload["actorId"], let token = job.payload["runToken"],
              UUID(uuidString:id) != nil, UUID(uuidString:token) != nil,
              let campaign = try db.get("crm_campaigns",key:["id":.text(id)]) else { throw Skip(reason:"配信予約またはキャンペーンが見つかりません。") }
        guard campaign["deletedAt"] == .null, campaign["status"] != .text("deleted"), campaign["status"] != .text("paused"),
              try db.metadata(CampaignWorkflow.runKey(id)) == token else { throw Skip(reason:"停止・削除・再予約された配信処理です。") }
        guard let user = try db.get("Users",key:["id":.text(actorID)]), ["admin","manager"].contains(user["role"].string) else { throw Skip(reason:"予約した利用者には現在配信する権限がありません。") }
        let service = CRMService(db:db,identity:CRMIdentity(id:actorID,role:user["role"].string,partnerAccountID:nil))
        do { _ = try service.campaign(id) } catch { throw Skip(reason:"予約した利用者は現在このキャンペーンを操作できません。") }
        return Context(campaign:campaign,actorID:actorID,token:token)
    }
    private func prepare(_ job: NativeJob, context c: Context) throws {
        let initial = job.event != CampaignWorkflow.followUpEvent
        let step: NativeRecord
        if initial {
            guard let first = try db.page("crm_campaign_steps",fields:["campaign_id","order","send_to"],equal:["campaign_id":c.campaign["id"],"order":.integer(0)],limit:1).rows.first else { throw Skip(reason:"初回配信の手順がありません。") }
            step = first
            if job.event == CampaignWorkflow.scheduleEvent {
                guard c.campaign["status"] == .text("scheduled") else { throw Skip(reason:"この予約はすでに開始または変更されています。") }
                _ = try db.update(c.campaign,changes:["status":.text("sending")],actor:c.actorID,action:"scheduled_dispatch_started")
            } else if c.campaign["status"] != .text("sending") { throw Skip(reason:"配信開始の状態が変更されています。") }
        } else {
            guard ["sending","sent"].contains(c.campaign["status"].string), let stepID = job.payload["stepId"],
                  let followup = try db.get("crm_campaign_steps",key:["id":.text(stepID)]), followup["campaign_id"] == c.campaign["id"],
                  let order = Int64(followup["order"].string), order > 0 else { throw Skip(reason:"フォローアップの手順が削除または変更されています。") }
            step = followup
        }
        let base: String
        if job.event == CampaignWorkflow.scheduleEvent { base = job.payload["scheduledAt"] ?? "" }
        else if initial { base = try CampaignWorkflow.stamp(clock()) }
        else { base = job.payload["scheduledAt"] ?? "" }
        guard CampaignWorkflow.date(.text(base)) != nil else { throw NativeDBError.message("配信予約の基準日時が不正です。") }
        let count = try db.stageCampaignAudience(jobID:job.id,campaignID:c.campaign["id"].string,stepID:step["id"].string,initial:initial,sendTo:step["send_to"].string)
        try db.recordJobResult(job,result:["phase":"recipients","stepID":step["id"].string,"baseAt":base,"cursor":"","followupCursor":"0","recipients":String(count),"materialized":"0","followups":"0"])
    }
    /// One transactional batch. Its cursor, send records and outbox inserts
    /// commit together. Tests can simulate a process exit between these commits.
    @discardableResult func advance(_ expected: NativeJob) throws -> Bool {
        try db.transaction {
            let job = try db.requireJobLease(expected), c = try context(job), id = c.campaign["id"].string
            try db.renewJobLease(job,now:clock())
            if job.result["phase"] == nil { try prepare(job,context:c); return false }
            guard let stepID = job.result["stepID"], let step = try db.get("crm_campaign_steps",key:["id":.text(stepID)]), step["campaign_id"] == c.campaign["id"] else { throw Skip(reason:"配信中に手順が削除されています。") }
            var state = job.result
            if state["phase"] == "recipients" {
                let batch = try db.campaignDispatchRecipients(jobID:job.id,after:state["cursor"] ?? "")
                for target in batch {
                    let existing = try db.page("crm_campaign_sends",fields:["campaign_id","step_id","target_id","email","status"],equal:["step_id":.text(stepID),"target_id":.text(target.targetID)],limit:1).rows.first
                    let send = try existing ?? db.insert("crm_campaign_sends",values:["campaign_id":.text(id),"step_id":.text(stepID),"target_id":.text(target.targetID),"email":.text(target.email)],actor:c.actorID)
                    try db.queueCampaignSend(send,token:c.token,actorID:c.actorID,now:clock())
                }
                if let last = batch.last {
                    state["cursor"] = last.targetID; state["materialized"] = String((Int(state["materialized"] ?? "") ?? 0)+batch.count)
                } else {
                    // The original send-now handler takes its followup baseline
                    // after initial fanout. Persist it once, so a later restart
                    // during followup scheduling cannot move those dates again.
                    if job.event == CampaignWorkflow.sendEvent { state["baseAt"] = try CampaignWorkflow.stamp(clock()) }
                    state["phase"] = job.event == CampaignWorkflow.followUpEvent ? "complete" : "followups"
                }
                try db.recordJobResult(job,result:state); return false
            }
            if state["phase"] == "followups" {
                guard let base = CampaignWorkflow.date(.text(state["baseAt"] ?? "")), let after = Int64(state["followupCursor"] ?? "") else { throw NativeDBError.message("配信処理の再開位置が不正です。") }
                let steps = try db.campaignFollowUpSteps(campaignID:id,after:after)
                for step in steps {
                    guard let days = Int64(step["delay_days"].string), days >= 0 else { throw NativeDBError.message("フォローアップの日数が不正です。") }
                    let due = try CampaignWorkflow.followUpDate(base,days:days)
                    try db.enqueue(CampaignWorkflow.followUpEvent,payload:["campaignId":id,"stepId":step["id"].string,"runToken":c.token,"actorId":c.actorID,"scheduledAt":try CampaignWorkflow.stamp(due)],now:clock(),runAt:due)
                }
                if let last = steps.last { state["followupCursor"] = last["order"].string; state["followups"] = String((Int(state["followups"] ?? "") ?? 0)+steps.count) }
                else { state["phase"] = "complete" }
                try db.recordJobResult(job,result:state); return false
            }
            guard state["phase"] == "complete" else { throw NativeDBError.message("配信処理の進行状態が不正です。") }
            if job.event != CampaignWorkflow.followUpEvent { try db.setMetadata(CampaignWorkflow.dispatchDoneKey(id),value:c.token) }
            state["outcome"] = "dispatched"
            try db.finishJob(job,result:state,now:clock()); try db.clearCampaignAudience(jobID:job.id)
            try CampaignDispatch.finishInitialIfReady(db:db,campaignID:id,actorID:c.actorID,now:clock())
            return true
        }
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events:CampaignWorkflow.dispatchEvents,now:clock()) else { return false }
        do {
            while true { try Task.checkCancellation(); if try advance(job) { break }; await Task.yield() }
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if let skip = error as? Skip {
                try db.transaction { try db.finishJob(current,result:current.result.merging(["outcome":"skipped","reason":skip.reason]){_,v in v},now:clock()); try db.clearCampaignAudience(jobID:job.id) }
            } else {
                let retry = current.attempts < 5
                try db.failJob(current,message:error is CancellationError ? "処理を中断しました。保存した位置から再開します。" : error.localizedDescription,retryAt:retry ? clock().addingTimeInterval(min(60,5*pow(2,Double(current.attempts-1)))) : nil)
            }
        }
        return true
    }
}
