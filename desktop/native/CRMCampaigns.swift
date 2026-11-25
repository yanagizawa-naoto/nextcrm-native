import Foundation

struct CampaignListRow { let record: NativeRecord; let cells: [String] }

extension CRMService {
    func campaign(_ id: String) throws -> NativeRecord {
        try db.transaction {
            try assertAccess("crm_campaigns",id:id)
            guard let record = try db.get("crm_campaigns",key:["id":.text(id)]), record["deletedAt"] == .null, record["status"] != .text("deleted") else { throw NativeDBError.conflict }
            return record
        }
    }
    private func checkedCampaign(_ expected: NativeRecord, editing: Bool = true) throws -> NativeRecord {
        guard expected.model == "crm_campaigns" else { throw NativeDBError.conflict }
        let current = try campaign(expected["id"].string)
        guard current.revision == expected.revision else { throw NativeDBError.conflict }
        guard !editing || current["status"] != .text("sending") else { throw NativeDBError.message("配信中のキャンペーンを変更するには、先に一時停止してください。") }
        return current
    }
    func campaigns(search: String = "", status: String? = nil, offset: Int = 0) throws -> (rows:[CampaignListRow],total:Int) {
        try db.transaction {
            try authenticated()
            if let status, !CampaignWorkflow.states.contains(status) { throw NativeDBError.message("キャンペーンの状態が不正です。") }
            let filter = RecordFilter.every([scope("crm_campaigns"),status.map{.equal("status",.text($0))} ?? .all])
            let page = try db.page("crm_campaigns",fields:["name","status","created_by","scheduled_at","created_on"],search:search,offset:offset,filter:filter,sort:"created_on",descending:true)
            let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"
            let rows = try page.rows.map { r -> CampaignListRow in
                let count = try db.page("crm_campaign_steps",fields:[],equal:["campaign_id":r["id"]],limit:1).total
                let creator = r["created_by"].string.isEmpty ? "—" : try referenceName("Users",id:r["created_by"].string)
                return CampaignListRow(record:r,cells:[r["name"].string,CampaignWorkflow.label(r["status"].string),"\(count)",CampaignWorkflow.date(r["scheduled_at"]).map(f.string) ?? "—",creator])
            }
            return (rows,page.total)
        }
    }
    func createCampaign(input: [String:SQLValue], targetListIDs: [String] = [], steps: [CampaignStepInput] = [], scheduledAt: Date? = nil, now: Date = Date()) throws -> NativeRecord {
        try db.transaction {
            try authenticated(); guard ["admin","manager","user"].contains(identity.role) else { throw NativeDBError.message("キャンペーンを作成する権限がありません。") }
            try CampaignWorkflow.validateHeader(input,current:nil)
            guard Set(targetListIDs).count == targetListIDs.count, Set(steps.map(\.order)).count == steps.count else { throw NativeDBError.message("配信対象または配信手順が重複しています。") }
            if let template = input["template_id"], template != .null { try assertAccess("crm_campaign_templates",id:template.string) }
            for id in targetListIDs { try assertAccess("crm_TargetLists",id:id) }
            for step in steps { try step.validate(); try assertAccess("crm_campaign_templates",id:step.templateID) }
            var values = input; values["v"] = .integer(0); values["status"] = .text("draft"); values["created_by"] = .text(identity.id)
            let record = try db.insert("crm_campaigns",values:values,actor:identity.id)
            for id in targetListIDs { _ = try db.insert("CampaignToTargetLists",values:["campaign_id":record["id"],"target_list_id":.text(id)],actor:identity.id) }
            for step in steps { _ = try db.insert("crm_campaign_steps",values:step.values.merging(["campaign_id":record["id"]]){_,v in v},actor:identity.id) }
            if let scheduledAt {
                for step in steps { guard let item = try db.page("crm_campaign_steps",fields:["delay_days"],equal:["campaign_id":record["id"],"order":.integer(step.order)],limit:1).rows.first else { throw NativeDBError.conflict }; _ = try db.update(item,changes:["scheduled_at":.text(try CampaignWorkflow.stamp(CampaignWorkflow.followUpDate(scheduledAt,days:step.delayDays)))],actor:identity.id) }
                return try scheduleCampaign(record,at:scheduledAt,now:now)
            }
            return record
        }
    }
    func saveCampaign(_ expected: NativeRecord, input: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            let current = try checkedCampaign(expected); try CampaignWorkflow.validateHeader(input,current:current)
            if let template = input["template_id"], template != .null, template != current["template_id"] { try assertAccess("crm_campaign_templates",id:template.string) }
            return try db.update(current,changes:input,actor:identity.id)
        }
    }
    func campaignSteps(_ id: String, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try db.transaction { _ = try campaign(id); return try db.page("crm_campaign_steps",fields:["campaign_id","order","template_id","subject","delay_days","send_to","scheduled_at","sent_at"],equal:["campaign_id":.text(id)],offset:offset,sort:"order") }
    }
    func saveCampaignStep(campaign expected: NativeRecord, original: NativeRecord?, input: CampaignStepInput) throws -> (campaign:NativeRecord,step:NativeRecord) {
        try db.transaction {
            let current = try checkedCampaign(expected); try input.validate()
            let step: NativeRecord
            if let original {
                guard original.model == "crm_campaign_steps", let fresh = try db.get(original.model,key:["id":original["id"]]), fresh["campaign_id"] == current["id"], fresh.revision == original.revision else { throw NativeDBError.conflict }
                if fresh["order"] == .integer(0), input.order != 0, current["status"] != .text("draft") { throw NativeDBError.message("初回配信の手順は、下書きの状態でのみ移動できます。") }
                if fresh["template_id"] != .text(input.templateID) { try assertAccess("crm_campaign_templates",id:input.templateID) }
                step = try db.update(fresh,changes:input.values,actor:identity.id)
            } else {
                try assertAccess("crm_campaign_templates",id:input.templateID)
                step = try db.insert("crm_campaign_steps",values:input.values.merging(["campaign_id":current["id"]]){_,v in v},actor:identity.id)
            }
            return (try db.update(current,changes:[:],actor:identity.id,action:"step_save"),step)
        }
    }
    func deleteCampaignStep(campaign expected: NativeRecord, step: NativeRecord) throws -> NativeRecord {
        try db.transaction {
            let current = try checkedCampaign(expected)
            guard step.model == "crm_campaign_steps", let fresh = try db.get(step.model,key:["id":step["id"]]), fresh["campaign_id"] == current["id"], fresh.revision == step.revision else { throw NativeDBError.conflict }
            if fresh["order"] == .integer(0), current["status"] != .text("draft") { throw NativeDBError.message("初回配信の手順は、下書きの状態でのみ削除できます。") }
            guard try db.page("crm_campaign_sends",fields:[],equal:["step_id":fresh["id"]],limit:1).total == 0 else { throw NativeDBError.message("送信履歴がある配信手順は削除できません。") }
            try db.remove(fresh,actor:identity.id,action:"step_delete")
            return try db.update(current,changes:[:],actor:identity.id,action:"step_delete")
        }
    }
    func campaignTargetLists(_ id: String, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try db.transaction {
            _ = try campaign(id)
            return try db.page("crm_TargetLists",fields:["name","description","deletedAt"],includeDeleted:true,offset:offset,filter:.relation(model:"CampaignToTargetLists",local:"id",foreign:"target_list_id",matching:.equal("campaign_id",.text(id))),sort:"name")
        }
    }
    func campaignAudience(_ id: String, offset: Int = 0) throws -> (rows:[NativeRecord],members:Int,suppressed:Int,withoutEmail:Int,eligible:Int,unique:Int) {
        try db.transaction { _ = try campaign(id); return try db.campaignAudience(campaignID:id,offset:offset) }
    }
    func setCampaignTargetList(campaign expected: NativeRecord, listID: String, enabled: Bool) throws -> NativeRecord {
        try db.transaction {
            let current = try checkedCampaign(expected), key = ["campaign_id":current["id"],"target_list_id":.text(listID)]
            let link = try db.get("CampaignToTargetLists",key:key)
            if enabled { try assertAccess("crm_TargetLists",id:listID); if link == nil { _ = try db.insert("CampaignToTargetLists",values:key,actor:identity.id) } else { return current } }
            else if let link { try db.remove(link,actor:identity.id) } else { return current }
            return try db.update(current,changes:[:],actor:identity.id,action:enabled ? "audience_add" : "audience_remove")
        }
    }
    /// Scheduling persists an atomic command. The campaign runner must be wired
    /// before presenting this as a working delivery feature in the application.
    func scheduleCampaign(_ expected: NativeRecord, at date: Date, now: Date = Date()) throws -> NativeRecord {
        try db.transaction {
            try authenticated(); guard identity.elevated else { throw NativeDBError.message("配信を予約できるのは管理者とマネージャーです。") }
            let current = try checkedCampaign(expected), stamp = try CampaignWorkflow.stamp(date)
            guard let first = try db.page("crm_campaign_steps",fields:["template_id","delay_days"],equal:["campaign_id":current["id"],"order":.integer(0)],limit:1).rows.first else { throw NativeDBError.message("初回配信の手順（順番0）がありません。") }
            _ = try db.update(first,changes:["scheduled_at":.text(stamp)],actor:identity.id)
            let updated = try db.update(current,changes:["status":.text("scheduled"),"scheduled_at":.text(stamp)],actor:identity.id,action:"schedule")
            let token = UUID().uuidString.lowercased(); try db.setMetadata(CampaignWorkflow.runKey(current["id"].string),value:token)
            try db.enqueue(CampaignWorkflow.scheduleEvent,payload:["campaignId":current["id"].string,"scheduledAt":stamp,"runToken":token,"actorId":identity.id],now:now,runAt:date)
            return updated
        }
    }
    func pauseCampaign(_ expected: NativeRecord) throws -> NativeRecord {
        try db.transaction {
            let current = try checkedCampaign(expected,editing:false)
            guard ["scheduled","sending"].contains(current["status"].string) else { throw NativeDBError.message("予約済みまたは配信中のキャンペーンだけ一時停止できます。") }
            let updated = try db.update(current,changes:["status":.text("paused")],actor:identity.id,action:"pause")
            try db.setMetadata(CampaignWorkflow.runKey(current["id"].string),value:UUID().uuidString.lowercased())
            return updated
        }
    }
    func sendCampaignNow(_ expected: NativeRecord, now: Date = Date()) throws -> NativeRecord {
        try beginCampaignDispatch(expected,resuming:false,now:now)
    }
    func resumeCampaign(_ expected: NativeRecord, now: Date = Date()) throws -> NativeRecord {
        try beginCampaignDispatch(expected,resuming:true,now:now)
    }
    private func beginCampaignDispatch(_ expected: NativeRecord, resuming: Bool, now: Date) throws -> NativeRecord {
        try db.transaction {
            try authenticated(); guard identity.elevated else { throw NativeDBError.message("配信・再開できるのは管理者とマネージャーです。") }
            let current = try checkedCampaign(expected), base = try CampaignWorkflow.stamp(now)
            guard (resuming ? ["paused"] : ["draft","scheduled"]).contains(current["status"].string) else { throw NativeDBError.message(resuming ? "一時停止したキャンペーンだけ再開できます。" : "下書きまたは予約済みのキャンペーンだけ配信を開始できます。") }
            guard try db.page("crm_campaign_steps",fields:[],equal:["campaign_id":current["id"],"order":.integer(0)],limit:1).total == 1 else { throw NativeDBError.message("初回配信の手順（順番0）がありません。") }
            var changes: [String:SQLValue] = ["status":.text("sending")]
            if !resuming { changes["scheduled_at"] = .text(base) }
            let updated = try db.update(current,changes:changes,actor:identity.id,action:resuming ? "resume" : "send_now")
            let token = UUID().uuidString.lowercased(); try db.setMetadata(CampaignWorkflow.runKey(current["id"].string),value:token)
            try db.enqueue(CampaignWorkflow.sendEvent,payload:["campaignId":current["id"].string,"runToken":token,"actorId":identity.id,"dispatchAt":base],now:now)
            return updated
        }
    }
    func deleteCampaign(_ expected: NativeRecord) throws {
        try db.transaction {
            let current = try checkedCampaign(expected)
            _ = try db.update(current,changes:["status":.text("deleted"),"deletedAt":.text(try CampaignWorkflow.stamp(Date())),"deletedBy":.text(identity.id)],actor:identity.id,action:"delete")
            try db.setMetadata(CampaignWorkflow.runKey(current["id"].string),value:UUID().uuidString.lowercased())
        }
    }
}
