import Foundation

enum CampaignLaunchAction: String, CaseIterable {
    case sendNow, schedule, resume
    var title: String { switch self { case .sendNow:return "今すぐ送信"; case .schedule:return "日時を指定して予約"; case .resume:return "送信を再開" } }
    var confirmationTitle: String { switch self { case .sendNow:return "送信内容の確認"; case .schedule:return "予約内容の確認"; case .resume:return "送信再開の確認" } }
    func permits(_ status: String) -> Bool {
        switch self { case .sendNow:return ["draft","scheduled"].contains(status); case .schedule:return ["draft","scheduled","paused","sent"].contains(status); case .resume:return status == "paused" }
    }
}
struct CampaignLaunchSummary { let campaign: NativeRecord; let candidates: Int; let suppressed: Int; let withoutEmail: Int; let steps: Int }
struct CampaignSynchronizationStatus { let configured: Bool; let latest: NativeJob?; let lastSuccess: String? }

extension CRMService {
    func campaignLaunchSummary(_ expected: NativeRecord, action: CampaignLaunchAction) throws -> CampaignLaunchSummary {
        try db.transaction {
            try authenticated(); guard identity.elevated else { throw NativeDBError.message("送信・予約・再開ができるのは管理者とマネージャーです。") }
            let current = try campaign(expected["id"].string)
            guard expected.model == "crm_campaigns", expected.revision == current.revision else { throw NativeDBError.conflict }
            guard action.permits(current["status"].string) else { throw NativeDBError.message("キャンペーンの状態が変わっています。再読み込みしてください。") }
            guard let first = try db.page("crm_campaign_steps",fields:["template_id"],equal:["campaign_id":current["id"],"order":.integer(0)],limit:1).rows.first else { throw NativeDBError.message("初回配信の手順（順番0）を追加してください。") }
            try assertAccess("crm_campaign_templates",id:first["template_id"].string)
            let audience = try campaignAudience(current["id"].string)
            let steps = try db.page("crm_campaign_steps",fields:[],equal:["campaign_id":current["id"]],limit:1).total
            return .init(campaign:current,candidates:audience.unique,suppressed:audience.suppressed,withoutEmail:audience.withoutEmail,steps:steps)
        }
    }
    /// Recheck permissions and the exact campaign after awaited readiness. No
    /// network operation holds a SQLite transaction or starts an outgoing mail.
    func launchCampaign(_ expected: NativeRecord, action: CampaignLaunchAction, at date: Date?, readiness: () async throws -> Void, now: @escaping () -> Date = Date.init) async throws -> NativeRecord {
        _ = try campaignLaunchSummary(expected,action:action)
        if action == .schedule { guard let date, date > now() else { throw NativeDBError.message("予約日時は現在より後の日時を指定してください。") } }
        try Task.checkCancellation(); try await readiness(); try Task.checkCancellation()
        return try db.transaction {
            _ = try campaignLaunchSummary(expected,action:action)
            try Task.checkCancellation()
            switch action {
            case .sendNow:return try sendCampaignNow(expected,now:now())
            case .resume:return try resumeCampaign(expected,now:now())
            case .schedule:
                guard let date, date > now() else { throw NativeDBError.message("確認中に予約日時を過ぎました。日時を指定し直してください。") }
                return try scheduleCampaign(expected,at:date,now:now())
            }
        }
    }
    func campaignSynchronizationStatus(_ id: String) throws -> CampaignSynchronizationStatus {
        try db.transaction {
            _ = try campaign(id)
            let binding = try CampaignRelayBinding.load(db:db)
            let job = try db.metadata(CampaignRelayJobs.pointer).flatMap{try db.job(id:$0)}
            guard job == nil || job?.event == CampaignRelayJobs.event else { throw NativeDBError.conflict }
            return .init(configured:binding != nil,latest:job,lastSuccess:try db.metadata(CampaignRelayJobs.lastSuccess))
        }
    }
    func synchronizeCampaignResults(_ id: String, now: Date = Date()) throws {
        try db.transaction {
            _ = try campaign(id)
            guard identity.elevated else { throw NativeDBError.message("送信結果を同期できるのは管理者とマネージャーです。") }
            guard try CampaignRelayJobs.request(db:db,now:now) != nil else { throw NativeDBError.message("キャンペーンの受信窓口を設定してください。") }
        }
    }
    func campaignDispatchJobAccess(_ id: String) throws -> NativeJob {
        try authenticated(); guard identity.elevated else { throw NativeDBError.message("配信予約を操作できるのは管理者とマネージャーです。") }
        guard let job = try db.job(id:id), CampaignWorkflow.dispatchEvents.contains(job.event), let campaignID = job.payload["campaignId"] else { throw NativeDBError.message("配信予約が見つかりません。") }
        _ = try campaign(campaignID); return job
    }
    func campaignDispatchJobs(_ id: String, offset: Int = 0) throws -> (rows:[NativeJob],total:Int,activeRunToken:String?) {
        try db.transaction {
            let current = try campaign(id)
            let token = ["scheduled","sending","sent"].contains(current["status"].string) ? try db.metadata(CampaignWorkflow.runKey(id)) : nil
            return (try db.jobs(events:CampaignWorkflow.dispatchEvents,campaignID:id,offset:offset),try db.campaignJobCount(id,events:CampaignWorkflow.dispatchEvents),token)
        }
    }
    func retryCampaignDispatchJob(_ expected: NativeJob, now: Date = Date()) throws {
        try db.transaction {
            let current = try campaignDispatchJobAccess(expected.id)
            guard current == expected, let id = current.payload["campaignId"], try db.metadata(CampaignWorkflow.runKey(id)) == current.payload["runToken"] else { throw NativeDBError.conflict }
            let c = try campaign(id)
            guard ["scheduled","sending","sent"].contains(c["status"].string),
                  let actorID = current.payload["actorId"], let actor = try db.get("Users",key:["id":.text(actorID)]), ["admin","manager"].contains(actor["role"].string) else { throw NativeDBError.message("キャンペーンの状態と、予約した利用者の権限を確認してください。") }
            let owner = CRMService(db:db,identity:.init(id:actorID,role:actor["role"].string,partnerAccountID:nil)); _ = try owner.campaign(id)
            try db.retryJob(id:current.id,now:now)
        }
    }
    /// Cancelling a fanout also pauses its campaign: some recipient jobs may
    /// already exist. Rotating the run token fences all remaining old work.
    func cancelCampaignDispatchJobAndPause(_ expected: NativeJob) throws {
        try db.transaction {
            let current = try campaignDispatchJobAccess(expected.id)
            guard current == expected, let id = current.payload["campaignId"], try db.metadata(CampaignWorkflow.runKey(id)) == current.payload["runToken"] else { throw NativeDBError.conflict }
            let c = try campaign(id)
            guard ["scheduled","sending","sent"].contains(c["status"].string) else { throw NativeDBError.message("現在の配信予約は取り消せません。") }
            try db.cancelJob(id:current.id,result:current.result.merging(["cancelledBy":identity.id,"outcome":"cancelled"]){_,v in v})
            _ = try db.update(c,changes:["status":.text("paused")],actor:identity.id,action:"campaign_dispatch_cancelled")
            try db.setMetadata(CampaignWorkflow.runKey(id),value:UUID().uuidString.lowercased())
            try db.clearCampaignAudience(jobID:current.id)
        }
    }
}
