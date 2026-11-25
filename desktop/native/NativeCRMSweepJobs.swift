import Foundation
import CryptoKit

enum NativeCRMSweepJobs {
    static let killScan = "crm.automation.kill.scan", killCheck = "crm.automation.kill.check"
    static let recycleScan = "crm.automation.recycle.scan", recycleApply = "crm.automation.recycle.apply"
    static let killNotice = "crm.automation.kill.notice", recycleNotice = "crm.automation.recycle.notice"
    static let events = [killScan, killCheck, recycleScan, recycleApply], mailEvents = [killNotice, recycleNotice]
    static let recycledListName = "再開対象", recycledLegacyName = "Recycled", maximumAttempts = 5
    struct Environment { init() {} }
    struct Opportunity: Codable {
        let id: String, name: String?, contact: String?, account: String?, entered: String?, assignee: String?
        init(_ row: NativeRecord) {
            func optional(_ key: String) -> String? { row[key] == .null ? nil : row[key].string }
            id = row["id"].string; name = optional("name"); contact = optional("contact"); account = optional("account")
            entered = optional("stage_entered_at"); assignee = optional("assigned_to")
        }
    }
    struct Recipient: Codable { let id: String, email: String }
    static func stamp(_ date: Date) throws -> String { try NativeCRMAutomationDates.stamp(date) }
    static func snapshotKey(_ owner: String, _ kind: String, _ index: Int) -> String {
        "crm.automation.snapshot.v1." + owner + "." + kind + "." + String(format: "%012d", index)
    }
    private static func deterministicID(_ value: String) -> String {
        let h = SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8,8..<12,12..<16,16..<20,20..<32].map { String(h[h.index(h.startIndex,offsetBy:$0.lowerBound)..<h.index(h.startIndex,offsetBy:$0.upperBound)]) }
        return parts.joined(separator: "-")
    }
    static func nextScheduledDate(after now: Date, recycle: Bool) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(bySettingHour: 6, minute: recycle ? 30 : 0, second: 0, of: now)!
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)!
    }
    /// The owning common runtime calls this. First installation reserves the
    /// next real cron; sleeping Macs coalesce a missed daily run into one scan.
    static func enqueueDue(db: NativeDatabase, now: Date) throws -> Date {
        try db.transaction {
            try Task.checkCancellation(); var earliest: Date?
            for (event,recycle) in [(killScan,false),(recycleScan,true)] {
                let key = event + ".next.v1"
                if let raw = try db.metadata(key), !raw.isEmpty {
                    let due = try NativeCRMAutomationDates.parse(raw)
                    if due <= now {
                        let id = deterministicID(event + "/" + raw)
                        if try db.job(id: id) == nil { try db.enqueue(event,payload:["scheduledAt":raw],id:id,now:now) }
                    } else { earliest = earliest.map { min($0,due) } ?? due; continue }
                }
                let next = nextScheduledDate(after: now,recycle:recycle)
                try db.setMetadata(key,value:stamp(next)); earliest = earliest.map { min($0,next) } ?? next
            }
            return earliest!
        }
    }
    private static func latestActivity(_ opp: Opportunity, db: NativeDatabase) throws -> Date? {
        var values: [Date] = []
        if let entered = opp.entered { values.append(try NativeCRMAutomationDates.parse(entered)) }
        var scopes: [RecordFilter] = []
        if let contact = opp.contact { scopes.append(.relation(model:"EmailsToContacts",local:"id",foreign:"emailId",matching:.equal("contactId",.text(contact)))) }
        if let account = opp.account { scopes.append(.relation(model:"EmailsToAccounts",local:"id",foreign:"emailId",matching:.equal("accountId",.text(account)))) }
        if !scopes.isEmpty, let email = try db.mcpPage("Email",fields:["sentAt"],filter:.every([.equal("folder",.text("INBOX")),.equal("isDeleted",.integer(0)),.not(.equal("sentAt",.null)),.any(scopes)]),limit:1,offset:0,order:[("sentAt",true)],includeDeleted:true).rows.first {
            values.append(try NativeCRMAutomationDates.parse(email["sentAt"].string))
        }
        let filter: RecordFilter = .every([.equal("deletedAt",.null),.not(.equal("status",.text("cancelled"))),.relation(model:"crm_ActivityLinks",local:"id",foreign:"activityId",matching:.every([.equal("entityType",.text("opportunity")),.equal("entityId",.text(opp.id))]))])
        if let activity = try db.mcpPage("crm_Activities",fields:["date"],filter:filter,limit:1,offset:0,order:[("date",true)],includeDeleted:true).rows.first { values.append(try NativeCRMAutomationDates.parse(activity["date"].string)) }
        return values.max()
    }
    private static func snapshotKill(db: NativeDatabase, job: NativeJob, now: Date, checkpoint: (String,Int)throws->Void) throws -> Int {
        let settings = try NativeCRMAutomationSettings.load(db), encoder = JSONEncoder()
        let settingsJSON = String(decoding:try encoder.encode(settings),as:UTF8.self)
        let filter: RecordFilter = .every([.equal("status",.text("ACTIVE")),.equal("deletedAt",.null),.relation(model:"crm_Opportunities_Sales_Stages",local:"sales_stage",foreign:"id",matching:.equal("stage_kind",.text("qualified")))])
        var count = 0
        while count < 500 {
            try Task.checkCancellation(); _ = try db.requireJobLease(job)
            let rows = try db.page("crm_Opportunities",fields:["name","contact","account","stage_entered_at","assigned_to"],includeDeleted:true,offset:count,filter:filter,insertionOrderForTies:true,limit:min(100,500-count)).rows
            for row in rows {
                try db.enqueue(killCheck,payload:["scanId":job.id,"opportunity":String(decoding:try encoder.encode(Opportunity(row)),as:UTF8.self),"settings":settingsJSON],now:now)
                count += 1; try checkpoint("killSnapshot",count)
            }
            if rows.count < 100 { break }
        }
        return count
    }
    private static func close(_ job: NativeJob, db: NativeDatabase, now: Date, checkpoint: (String,Int)throws->Void) throws -> Bool {
        guard let json = job.payload["opportunity"],let raw = job.payload["settings"] else { throw NativeDBError.conflict }
        let opp = try JSONDecoder().decode(Opportunity.self,from:Data(json.utf8)),settings = try JSONDecoder().decode(NativeCRMAutomationSettings.self,from:Data(raw.utf8))
        guard let last = try latestActivity(opp,db:db), now.timeIntervalSince(last) >= Double(settings.killAfterDays)*86400 else { return false }
        guard let current = try db.get("crm_Opportunities",key:["id":.text(opp.id)]) else { throw NativeDBError.conflict }
        var changes: [String:SQLValue] = ["status":.text("CLOSED")]
        if let assignee = opp.assignee { changes["updatedBy"] = .text(assignee) }
        _ = try db.update(current,changes:changes,actor:opp.assignee ?? "crm.automation",action:"automation_kill")
        // Original CRM audit is best effort; mandatory native mutation audit is
        // already owned by update. Failure here rolls back only its savepoint.
        let audit: [[String:Any]] = [["field":"status","old":"ACTIVE","new":"CLOSED"],["field":"close_reason","old":NSNull(),"new":"最終顧客対応から\(settings.killAfterDays)日経過したため終了"]]
        try? db.transaction {
            _ = try db.insert("crm_AuditLog",values:["entityType":.text("opportunity"),"entityId":.text(opp.id),"action":.text("updated"),"changes":.text(String(decoding:try JSONSerialization.data(withJSONObject:audit,options:.sortedKeys),as:UTF8.self)),"userId":opp.assignee.map(SQLValue.text) ?? .null],actor:opp.assignee ?? "crm.automation")
        }
        try checkpoint("killUpdated",1)
        if let owner = opp.assignee,let user = try db.keysetPage("Users",fields:["email"],filter:.equal("id",.text(owner)),includeDeleted:true,limit:1).first,!user["email"].string.isEmpty {
            let name = opp.name ?? opp.id,link = try NativeCRMSweepLink(destination:.opportunity,id:opp.id).string
            try db.enqueue(killNotice,payload:["opportunityId":opp.id,"recipientId":owner,"recipientEmail":user["email"].string,"subject":"\(settings.killAfterDays)日間の未対応により商談を終了しました：\(name)","message":"商談「\(name)」は顧客からの反応が\(settings.killAfterDays)日間なかったため、失注として終了しました。\n必要な場合は商談を再開してください。\n\(link)","link":link],now:now)
        }
        return true
    }
    private static func eligible(_ target: NativeRecord, cutoff: String, db: NativeDatabase) throws -> Bool {
        let id = target["id"],recent: RecordFilter = .every([.equal("target_id",id),.any([.compareDate("sent_at",.greater,cutoff),.scalar("status","in",[.text("queued"),.text("sending")],false)])])
        if try !db.keysetPage("crm_campaign_sends",fields:[],filter:recent,includeDeleted:true,limit:1).isEmpty { return false }
        let membership: RecordFilter = .every([.equal("target_id",id),.relation(model:"crm_TargetLists",local:"target_list_id",foreign:"id",matching:.scalar("name","in",[.text(recycledListName),.text(recycledLegacyName)],false))])
        if try !db.page("TargetsToTargetLists",fields:[],includeDeleted:true,filter:membership,limit:1).rows.isEmpty { return false }
        var after: String?
        while true {
            try Task.checkCancellation()
            let sends = try db.keysetPage("crm_campaign_sends",fields:["campaign_id","step_id"],after:after,filter:.every([.equal("target_id",id),.equal("status",.text("sent")),.compareDate("sent_at",.lessOrEqual,cutoff)]),includeDeleted:true)
            for send in sends {
                guard let step = try db.keysetPage("crm_campaign_steps",fields:["order"],filter:.equal("id",send["step_id"]),includeDeleted:true,limit:1).first,
                      let maximum = try db.mcpPage("crm_campaign_steps",fields:["order"],filter:.equal("campaign_id",send["campaign_id"]),limit:1,offset:0,order:[("order",true)],includeDeleted:true).rows.first else { continue }
                if step["order"] == maximum["order"] { return true }
            }
            if sends.count < 100 { return false }; after = sends.last!["id"].string
        }
    }
    private static func snapshotRecycle(db: NativeDatabase, job: NativeJob, now: Date, checkpoint: (String,Int)throws->Void) throws -> [String:String] {
        let settings = try NativeCRMAutomationSettings.load(db),cutoff = try stamp(now.addingTimeInterval(-Double(settings.recycleAfterDays)*86400))
        var after: String?,count = 0
        while true {
            try Task.checkCancellation(); _ = try db.requireJobLease(job)
            let rows = try db.keysetPage("crm_Targets",fields:[],after:after,filter:.every([.equal("do_not_email",.integer(0)),.equal("converted_at",.null),.equal("deletedAt",.null)]),includeDeleted:true)
            for row in rows where try eligible(row,cutoff:cutoff,db:db) {
                try db.setMetadata(snapshotKey(job.id,"recycleTarget",count),value:row["id"].string);count += 1
                try checkpoint("recycleSnapshot",count)
            }
            if rows.count < 100 { break };after = rows.last!["id"].string
        }
        var result = ["recycled":String(count)]
        if count > 0 { result["applyJobId"] = try db.enqueue(recycleApply,payload:["scanId":job.id,"count":String(count)],now:now) }
        return result
    }
    private static func recycle(db: NativeDatabase, job: NativeJob, now: Date, checkpoint: (String,Int)throws->Void) throws -> (Int,String,Int) {
        guard let scan = job.payload["scanId"],let expected = job.payload["count"].flatMap(Int.init),expected > 0 else { throw NativeDBError.conflict }
        let list: NativeRecord
        // New Japanese system list wins when both aliases exist. Within an
        // alias retain original first-row semantics; never rename existing data.
        let current = try db.page("crm_TargetLists",fields:[],includeDeleted:true,filter:.every([.equal("name",.text(recycledListName)),.equal("deletedAt",.null)]),insertionOrderForTies:true,limit:1).rows.first
        let legacy = try current == nil ? db.page("crm_TargetLists",fields:[],includeDeleted:true,filter:.every([.equal("name",.text(recycledLegacyName)),.equal("deletedAt",.null)]),insertionOrderForTies:true,limit:1).rows.first : nil
        if let existing = current ?? legacy { list = existing }
        else { list = try db.insert("crm_TargetLists",values:["name":.text(recycledListName),"created_on":.text(try stamp(now)),"description":.text("自動管理：営業ステップ終了後、再開待ち期間を過ぎても反応のない営業対象です。")],actor:"crm.automation") }
        var after: String?,count = 0
        while true {
            let rows = try db.crmAutomationSnapshotPage(ownerID:scan,kind:"recycleTarget",after:after)
            for row in rows {
                let key: [String:SQLValue] = ["target_id":.text(row.value),"target_list_id":list["id"]]
                if try db.get("TargetsToTargetLists",key:key) == nil { _ = try db.insert("TargetsToTargetLists",values:key,actor:"crm.automation") }
                count += 1;try checkpoint("recycleMembership",count);try Task.checkCancellation();_ = try db.requireJobLease(job)
            }
            if rows.count < 100 { break };after = rows.last!.key
        }
        guard count == expected else { throw NativeDBError.conflict }
        let noticeID = UUID().uuidString.lowercased();var offset = 0,recipients = 0
        while true {
            let users = try db.page("Users",fields:["email"],includeDeleted:true,offset:offset,filter:.every([.equal("role",.text("admin")),.equal("userStatus",.text("ACTIVE"))]),insertionOrderForTies:true).rows
            for user in users where !user["email"].string.isEmpty {
                let value = Recipient(id:user["id"].string,email:user["email"].string)
                try db.setMetadata(snapshotKey(noticeID,"recipient",recipients),value:String(decoding:try JSONEncoder().encode(value),as:UTF8.self));recipients += 1
            }
            if users.count < 100 { break };offset += users.count
        }
        if recipients > 0 {
            let link = try NativeCRMSweepLink(destination:.targetList,id:list["id"].string).string
            try db.enqueue(recycleNotice,payload:["listId":list["id"].string,"count":String(count),"recipientCount":String(recipients),"subject":"\(count)件の営業対象を再開対象に追加しました","message":"営業ステップ終了後も反応のなかった\(count)件を「再開対象」リストに追加しました。\n新しいキャンペーンにこのリストを割り当ててください。\n\(link)","link":link],id:noticeID,now:now)
        }
        return (count,list["id"].string,recipients)
    }
    @discardableResult static func runNext(db: NativeDatabase, environment: Environment = .init(), clock: ()->Date = Date.init,
                                          checkpoint: (String,Int)throws->Void = {_,_ in}) throws -> Bool {
        try Task.checkCancellation();let now = clock()
        guard let job = try db.claimJob(events:events,now:now) else { return false }
        do {
            try db.transaction {
                _ = try db.requireJobLease(job);try Task.checkCancellation()
                guard job.attempts <= maximumAttempts else { throw NativeDBError.message("営業自動処理の再試行回数を超えました。") }
                let result: [String:String]
                switch job.event {
                case killScan: result = ["checked":String(try snapshotKill(db:db,job:job,now:now,checkpoint:checkpoint))]
                case killCheck: result = ["closed":try close(job,db:db,now:now,checkpoint:checkpoint) ? "true":"false"]
                case recycleScan: result = try snapshotRecycle(db:db,job:job,now:now,checkpoint:checkpoint)
                case recycleApply:
                    let applied = try recycle(db:db,job:job,now:now,checkpoint:checkpoint)
                    result = ["recycled":String(applied.0),"listId":applied.1,"recipients":String(applied.2)]
                default: throw NativeDBError.conflict
                }
                try checkpoint("beforeFinish",1);try Task.checkCancellation();_ = try db.requireJobLease(job)
                try db.finishJob(job,result:result,now:clock())
            }
        } catch {
            if let current = try? db.requireJobLease(job) {
                try db.failJob(current,message:error is CancellationError ? "営業自動処理を中断しました。次回再開します。":error.localizedDescription,retryAt:job.attempts < maximumAttempts ? clock().addingTimeInterval(error is CancellationError ? 0:30):nil)
            }
            if error is CancellationError { throw error }
        }
        return true
    }
}
