import Foundation

/// Durable cron reservations. One future job is linked to each schedule; an
/// overdue reservation creates one successor after now, rather than replaying
/// every missed minute. Delivery retries retain the original UUID and payload.
enum NativeReportQueue {
    static let event="reports.scheduled"
    private static func enqueue(db:NativeDatabase,schedule:NativeReportSchedule,generation:String,after:Date,now:Date)throws->String {
        let due=try schedule.settings.next(after:after)
        // Advancing a reservation is allowed while its owner is inactive or no
        // longer has config access. Even the display name must obey fresh read
        // permissions; never copy a newly private name into that owner's history.
        let owner=schedule.record["createdBy"]
        var name="レポート"
        if let user=try db.keysetPage("Users",fields:["role","userStatus","banned"],filter:.equal("id",owner),limit:1).first,
           user["userStatus"] == .text("ACTIVE"),user["banned"] != .integer(1),["admin","manager","user","partner"].contains(user["role"].string) {
            let scope:RecordFilter=["admin","manager"].contains(user["role"].string) ? .all : .any([.equal("createdBy",owner),.equal("isShared",.integer(1))])
            name=try db.keysetPage("crm_Report_Config",fields:["name"],filter:.every([scope,.equal("id",schedule.record["reportConfigId"])]),limit:1,maximumTextCharacters:["name":256]).first?["name"].string ?? name
        }
        let payload=["scheduleId":schedule.id,"configId":schedule.record["reportConfigId"].string,"ownerId":schedule.record["createdBy"].string,"generation":generation,"occurrence":ISO8601DateFormatter().string(from:due),"reportName":name]
        let id=try db.enqueue(event,payload:payload,now:now,runAt:due)
        try db.setMetadata("reportSchedule.job."+schedule.id,value:id);return id
    }
    static func replace(db:NativeDatabase,schedule:NativeReportSchedule,generation:String,now:Date)throws {
        try db.transaction {
            try db.cancelUnstartedReportJobs(scheduleID:schedule.id)
            if schedule.isActive {_ = try enqueue(db:db,schedule:schedule,generation:generation,after:now,now:now)}
        }
    }
    /// Internal scheduling only; this does not grant data access or permission
    /// to send. The delivery worker separately authenticates the current owner.
    static func current(_ job:NativeJob,db:NativeDatabase)throws->NativeReportSchedule? {
        guard job.event==event,let id=job.payload["scheduleId"],
              let generation=try db.reportScheduleState("generation",id:id),generation==job.payload["generation"],
              try db.page("crm_Report_Schedule",fields:[],filter:.equal("id",.text(id)),limit:1).total==1 else {return nil}
        let row=try db.reportScheduleRecord(id)
        guard row["isActive"] == .integer(1),row["createdBy"].string==job.payload["ownerId"],row["reportConfigId"].string==job.payload["configId"] else {return nil}
        return try NativeReportSchedules.decode(row,db:db,confirmedTimeZone:true)
    }
    @discardableResult static func advance(_ expected:NativeJob,db:NativeDatabase,now:Date)throws->Bool {
        try db.transaction {
            let job=try db.requireJobLease(expected)
            guard let schedule=try current(job,db:db),try db.reportScheduleState("job",id:schedule.id)==job.id else {return false}
            guard let stamp=job.payload["occurrence"],let due=ISO8601DateFormatter().date(from:stamp),let generation=job.payload["generation"] else {throw NativeDBError.message("定期送信の予約日時を確認できません。")}
            _ = try enqueue(db:db,schedule:schedule,generation:generation,after:max(now,due),now:now);return true
        }
    }
    /// Cancelling one future occurrence must not silently stop its recurring
    /// schedule. An older retry already has a successor and needs no new one.
    static func advanceCancelled(_ expected:NativeJob,db:NativeDatabase,now:Date)throws {
        try db.transaction {
            guard let job=try db.job(id:expected.id),job.status=="cancelled",let schedule=try current(job,db:db),try db.reportScheduleState("job",id:schedule.id)==job.id else{return}
            guard let value=job.payload["occurrence"],let due=ISO8601DateFormatter().date(from:value),let generation=job.payload["generation"] else{throw NativeDBError.conflict}
            _ = try enqueue(db:db,schedule:schedule,generation:generation,after:max(now,due),now:now)
        }
    }
    static func cleanupCancelled(db:NativeDatabase,scheduleID:String?=nil,configID:String?=nil) {
        var after=""
        while let ids=try? db.cancelledReportBodyIDs(scheduleID:scheduleID,configID:configID,after:after),!ids.isEmpty {
            for id in ids {try? db.deferTerminalMailBodyCleanup(id:id)}
            after=ids.last!
        }
    }
    static func requestCleanup(db:NativeDatabase,scheduleID:String?=nil,configID:String?=nil) {
        // A caller may own an outer transaction. The other queue waits for the
        // DB lock, then observes its committed outcome before removing a body.
        DispatchQueue.global(qos:.utility).async {cleanupCancelled(db:db,scheduleID:scheduleID,configID:configID)}
    }
}
