import Foundation

struct GoogleCalendarOutboundDecision: Equatable {
    let action: String
    var reason: String? = nil
    var eventID: String? = nil
}
enum GoogleCalendarOutbound {
    static let event = "calendar/outbound"
    static func decide(action: String,activity: NativeRecord?,mapping: NativeRecord?,hasWriteConnection: Bool,now: Date) throws -> GoogleCalendarOutboundDecision {
        func skip(_ reason: String) -> GoogleCalendarOutboundDecision { .init(action:"skip",reason:reason) }
        guard let activity else { return skip("not-found") }
        guard activity["type"] == .text("meeting") else { return skip("not-a-meeting") }
        if mapping?["source"] == .text("calendly") { return skip("calendly-owned") }
        guard hasWriteConnection else { return skip("no-write-connection") }
        if action == "cancel" || activity["status"] == .text("cancelled") || activity["deletedAt"] != .null {
            return mapping?["source"] == .text("google") ? .init(action:"delete",eventID:mapping?["externalId"].string) : skip("never-pushed")
        }
        guard activity["date"] != .null else { return skip("no-date") }
        let date = try NativeCalendarEvents.date(activity["date"].string)
        if activity["status"] == .text("completed") { return skip("already-completed") }
        guard let mapping, mapping["status"] != .text("cancelled") else { return date < now ? skip("in-the-past") : .init(action:"insert") }
        if date < now, mapping["startAt"] != .null, try NativeCalendarEvents.date(mapping["startAt"].string) == date { return skip("in-the-past") }
        if !organizedBySelf(mapping["rawPayload"].string) { return skip("not-organizer") }
        return .init(action:"patch",eventID:mapping["externalId"].string)
    }
    static func organizedBySelf(_ json: String) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any], let organizer = raw["organizer"], !(organizer is NSNull) else { return true }
        if let value = organizer as? String, value.isEmpty { return true }
        if let value = organizer as? NSNumber, value.doubleValue == 0 { return true }
        guard let object = organizer as? [String:Any], let value = object["self"] as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
    }
    static func body(activity: NativeRecord,email: String?,patch: Bool = false) throws -> [String:Any] {
        let date = try NativeCalendarEvents.date(activity["date"].string)
        let duration = activity["duration"] == .null ? 30 : Double(activity["duration"].string) ?? .nan
        guard duration.isFinite else { throw NativeDBError.message("予定の所要時間が不正です。") }
        var body: [String:Any] = ["summary":activity["title"].string,"start":["dateTime":try NativeCalendarEvents.stamp(date)],"end":["dateTime":try NativeCalendarEvents.stamp(date.addingTimeInterval(duration*60))]]
        if activity["description"] != .null { body["description"] = activity["description"].string }
        if !patch, let email, !email.isEmpty { body["attendees"] = [["email":email]] }; return body
    }
    static func counterparty(db: NativeDatabase,activityID: String) throws -> String? {
        for (type,model,fields) in [("contact","crm_Contacts",["email","personal_email"]),("target","crm_Targets",["email","personal_email","company_email"]),("lead","crm_Leads",["email"])] {
            var offset = 0
            while true {
                let rows = try db.page("crm_ActivityLinks",fields:["entityId"],equal:["activityId":.text(activityID),"entityType":.text(type)],offset:offset,insertionOrderForTies:true).rows
                for link in rows {
                    guard let entity = try db.get(model,key:["id":link["entityId"]]), entity["deletedAt"] == .null else { continue }
                    if let field = fields.first(where:{entity[$0] != .null}), !entity[field].string.isEmpty { return entity[field].string.lowercased() }
                }
                if rows.count < 100 { break }; offset += rows.count
            }
        }
        return nil
    }
}

struct GoogleCalendarPushPlan: Codable {
    let activityID: String, ownerID: String, connectionID: String, accountEmail: String
    let action: String, eventID: String, marker: String
    let activityRevision: Int64
    let mappingID: String?
    let mappingRevision: Int64?
    let start: String, end: String, counterparty: String?, body: String
    var etag: String? = nil
}

extension CRMService {
    func googleCalendarPushPage(offset: Int = 0) throws -> (rows:[(job:NativeJob,title:String)],total:Int) { try authenticated(); return try db.calendarOutboundJobs(ownerID:identity.id,offset:offset) }
    func googleCalendarPushJob(_ id: String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id), job.event == GoogleCalendarOutbound.event, let activityID = job.payload["activity_id"], let activity = try db.get("crm_Activities",key:["id":.text(activityID)]), activity["createdBy"] == .text(identity.id) else { throw NativeDBError.message("カレンダーの反映処理が見つかりません。") }; return job
    }
    func retryGoogleCalendarPush(_ expected: NativeJob) throws {
        try db.transaction { let current = try googleCalendarPushJob(expected.id); guard current == expected else { throw NativeDBError.conflict }; guard try !db.personalPrerequisiteOldJob(current.id) else{throw NativeDBError.message("復元した旧処理は「復元した旧処理の確認」で確認してください。自動再送は行いません。")}; try db.retryCalendarOutboundJob(current) }
    }
    @discardableResult func reviewGoogleCalendarPushNotApplied(_ expected: NativeJob,note: String,now: Date = Date()) throws -> String {
        let text = note.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { throw NativeDBError.message("Googleで未反映と確認した内容を2000文字以内で入力してください。") }
        return try db.transaction {
            let current = try googleCalendarPushJob(expected.id); guard current == expected else { throw NativeDBError.conflict }
            guard try !db.personalPrerequisiteOldJob(current.id) else{throw NativeDBError.message("復元した旧処理は「復元した旧処理の確認」で確認してください。新しい反映処理は自動作成しません。")}
            return try db.reviewCalendarOutboundNotApplied(current,actor:identity.id,note:text,now:now)
        }
    }
    func prepareGoogleCalendarPush(_ job: NativeJob, now: Date) throws -> GoogleCalendarPushPlan? {
        try db.transaction {
            _ = try db.requireJobLease(job); try authenticated()
            guard let id = job.payload["activity_id"], let activity = try db.get("crm_Activities",key:["id":.text(id)]), activity["createdBy"] == .text(identity.id) else { throw NativeDBError.conflict }
            let mapping = try db.calendarOutboundMapping(activityID:id)
            let connection = try db.calendarOutboundConnection(ownerID:identity.id,preferredID:mapping?["connectionId"].string)
            let decision = try GoogleCalendarOutbound.decide(action:job.payload["operation"] ?? "upsert",activity:activity,mapping:mapping,hasWriteConnection:connection != nil,now:now)
            if decision.action == "skip" { try db.finishJob(job,result:["pushed":"false","reason":decision.reason!],now:now); return nil }
            guard let connection else { throw NativeDBError.conflict }
            if ["patch","delete"].contains(decision.action), mapping?["source"] == .text("google"), mapping?["connectionId"] != connection["id"] {
                try db.finishJob(job,result:["pushed":"false","reason":"connection-mismatch"],now:now); return nil
            }
            let email = decision.action == "delete" ? nil : try GoogleCalendarOutbound.counterparty(db:db,activityID:id)
            let body = decision.action == "delete" ? [:] : try GoogleCalendarOutbound.body(activity:activity,email:email,patch:decision.action == "patch")
            let start = (body["start"] as? [String:String])?["dateTime"] ?? mapping?["startAt"].string ?? ""
            let end = (body["end"] as? [String:String])?["dateTime"] ?? mapping?["endAt"].string ?? ""
            let plan = GoogleCalendarPushPlan(activityID:id,ownerID:identity.id,connectionID:connection["id"].string,accountEmail:connection["accountEmail"].string,action:decision.action,eventID:decision.eventID ?? UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:""),marker:job.id,activityRevision:activity.revision,mappingID:mapping?["id"].string,mappingRevision:mapping?.revision,start:start,end:end,counterparty:email,body:try NativeCalendarEvents.json(body))
            try db.recordJobResult(job,result:["plan":String(decoding:try JSONEncoder().encode(plan),as:UTF8.self),"requestOutcome":"prepared"])
            return plan
        }
    }
    /// Remote confirmation is retained before this transaction. Retrying a
    /// mapping failure must never issue the Google mutation a second time.
    func finishGoogleCalendarPush(_ job: NativeJob,plan: GoogleCalendarPushPlan,remote: [String:Any],now: Date) throws {
        try db.transaction {
            let currentJob = try db.requireJobLease(job); try authenticated()
            guard plan.ownerID == identity.id, currentJob.result["requestOutcome"] == "confirmed", let activity = try db.get("crm_Activities",key:["id":.text(plan.activityID)]), activity["createdBy"] == .text(identity.id) else { throw NativeDBError.conflict }
            let matching = try db.page("crm_CalendarEvents",fields:[],equal:["source":.text("google"),"externalId":.text(plan.eventID)],limit:1).rows.first
            if plan.action == "insert" {
                guard remote["id"] as? String == plan.eventID else { throw NativeDBError.conflict }
                let connection = try db.get("CalendarConnection",key:["id":.text(plan.connectionID)])
                if let connection { guard connection["userId"] == .text(identity.id), connection["accountEmail"] == .text(plan.accountEmail) else { throw NativeDBError.conflict } }
                let values: [String:SQLValue] = ["activityId":.text(plan.activityID),"connectionId":connection?["id"] ?? .null,"startAt":.text(plan.start),"endAt":.text(plan.end),"attendeeEmails":.text(try NativeCalendarEvents.json(plan.counterparty.map{[$0]} ?? [])),"status":.text("scheduled"),"rawPayload":.text(try NativeCalendarEvents.json(remote))]
                if let matching, let row = try db.get("crm_CalendarEvents",key:["id":matching["id"]]) {
                    if row["activityId"] != .text(plan.activityID) {
                        guard row["connectionId"] == .text(plan.connectionID), let duplicate = try db.get("crm_Activities",key:["id":row["activityId"]]) else { throw NativeDBError.conflict }
                        _ = try db.update(row,changes:values,actor:identity.id,action:"calendar_push_reconciled")
                        _ = try db.update(duplicate,changes:["deletedAt":.text(try NativeCalendarEvents.stamp(now))],actor:identity.id,action:"calendar_inbound_duplicate_reconciled")
                    }
                } else {
                    _ = try db.insert("crm_CalendarEvents",values:values.merging(["source":.text("google"),"externalId":.text(plan.eventID),"iCalUID":(remote["iCalUID"] as? String).map(SQLValue.text) ?? .null,"createdAt":.text(try NativeCalendarEvents.stamp(now))]){_,v in v},actor:identity.id)
                }
            } else if let matching, let row = try db.get("crm_CalendarEvents",key:["id":matching["id"]]), row["activityId"] == .text(plan.activityID) {
                if plan.action == "delete" { _ = try db.update(row,changes:["status":.text("cancelled")],actor:identity.id,action:"calendar_push_cancelled") }
                else {
                    _ = try db.update(row,changes:["startAt":.text(plan.start),"endAt":.text(plan.end),"attendeeEmails":.text(try NativeCalendarEvents.json(plan.counterparty.map{[$0]} ?? [])),"status":.text("scheduled")],actor:identity.id,action:"calendar_push_updated")
                }
            }
            var result = currentJob.result; result["pushed"] = "true"; result["did"] = plan.action
            try db.finishJob(job,result:result,now:now)
        }
    }
}
