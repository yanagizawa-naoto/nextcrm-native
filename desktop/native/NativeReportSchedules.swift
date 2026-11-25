import Foundation

enum NativeReportScheduledFormat:String {case csv,pdf,both}

struct NativeReportScheduleSettings {
    let cron:NativeReportCron,recipients:[String],format:NativeReportScheduledFormat,timeZone:TimeZone
    init(expression:String,recipients:[String],format:String,timeZone:String)throws {
        cron=try NativeReportCron(expression)
        guard let type=NativeReportScheduledFormat(rawValue:format),let zone=TimeZone(identifier:timeZone) else {throw NativeDBError.message("出力形式とタイムゾーンを確認してください。")}
        guard (1...50).contains(recipients.count) else {throw NativeDBError.message("宛先を1〜50件指定してください。")}
        var seen=Set<String>(),addresses:[String]=[]
        for value in recipients {let address=try InvoiceMail.mailbox(value);if seen.insert(address.lowercased()).inserted {addresses.append(address)}}
        self.recipients=addresses;self.format=type;self.timeZone=zone
    }
    func next(after date:Date)throws->Date {
        guard let next=try cron.next(after:date,timeZone:timeZone) else {throw NativeDBError.message("指定した条件に合う送信日時が8年以内にありません。日付と曜日を確認してください。")};return next
    }
}

struct NativeReportSchedule {
    let record:NativeRecord,settings:NativeReportScheduleSettings
    var id:String {record["id"].string}
    var isActive:Bool {record["isActive"] == .integer(1)}
}

/// Original ownership rules, with current authentication on every operation.
/// Lists exclude recipient JSON; opening one record preflights its total size.
struct NativeReportSchedules {
    let service:CRMService
    private var db:NativeDatabase {service.db}
    private var scope:RecordFilter {service.identity.elevated ? .all : .equal("createdBy",.text(service.identity.id))}
    func history(scheduleID:String?=nil,offset:Int=0)throws->(rows:[NativeJob],total:Int) {
        try db.transaction {try service.authenticated();return try db.reportJobs(ownerID:service.identity.elevated ? nil : service.identity.id,scheduleID:scheduleID,offset:offset)}
    }
    func retry(_ id:String,now:Date=Date())throws {try db.transaction {_ = try service.reportMailJobAccess(id);try db.retryJob(id:id,now:now)}}
    func cancel(_ id:String,now:Date=Date())throws {
        try db.transaction {let job=try service.reportMailJobAccess(id);try db.cancelJob(id:id);try NativeReportQueue.advanceCancelled(job,db:db,now:now)}
        NativeReportQueue.requestCleanup(db:db)
    }
    func list(offset:Int=0)throws->(rows:[NativeRecord],total:Int) {
        try db.transaction {
            try service.authenticated()
            let page=try db.page("crm_Report_Schedule",fields:[],offset:offset,filter:scope,sort:"createdAt",descending:true)
            let rows=try page.rows.map {row in
                try db.keysetPage("crm_Report_Schedule",fields:["reportConfigId","cronExpression","format","isActive","lastSentAt","createdBy"],filter:.equal("id",row["id"]),limit:1,maximumTextCharacters:["reportConfigId":128,"cronExpression":512,"format":8,"createdBy":64]).first!
            };return(rows,page.total)
        }
    }
    private func access(_ id:String)throws->NativeRecord {
        try service.authenticated()
        guard let row=try db.page("crm_Report_Schedule",fields:["createdBy","isActive"],filter:.every([scope,.equal("id",.text(id))]),limit:1).rows.first else {throw NativeDBError.message("定期送信が見つからないか、操作する権限がありません。")};return row
    }
    func load(_ id:String)throws->NativeReportSchedule {
        try db.transaction {
            _ = try access(id)
            return try Self.decode(db.reportScheduleRecord(id),db:db)
        }
    }
    static func decode(_ record:NativeRecord,db:NativeDatabase,confirmedTimeZone:Bool=false)throws->NativeReportSchedule {
        guard record["recipients"].string.utf8.count<=32_768,let recipients=try? JSONDecoder().decode([String].self,from:Data(record["recipients"].string.utf8)) else {throw NativeDBError.message("保存された宛先を読み込めません。")}
        let stored=try db.reportScheduleTimeZone(record["id"].string)
        guard !confirmedTimeZone || stored != nil else {throw NativeDBError.message("移行した定期送信のタイムゾーンを確認して、設定を保存してください。")}
        return try .init(record:record,settings:.init(expression:record["cronExpression"].string,recipients:recipients,format:record["format"].string,timeZone:stored ?? TimeZone.current.identifier))
    }
    private func readableConfig(_ id:String)throws {
        let configuration=try NativeReportConfigurations(service:service).load(id)
        guard configuration.category != .users || service.identity.elevated else {throw NativeDBError.message("利用者レポートの定期送信には管理者またはマネージャーの権限が必要です。")}
        _ = try configuration.filters.period();_ = try configuration.filters.currency
    }
    private func remember(_ row:NativeRecord,settings:NativeReportScheduleSettings,now:Date)throws {
        let id=row["id"].string,generation=UUID().uuidString.lowercased()
        try db.setMetadata("reportSchedule.timezone."+id,value:settings.timeZone.identifier)
        try db.setMetadata("reportSchedule.generation."+id,value:generation)
        try NativeReportQueue.replace(db:db,schedule:.init(record:row,settings:settings),generation:generation,now:now)
    }
    func create(configID:String,settings:NativeReportScheduleSettings,now:Date=Date())throws->NativeReportSchedule {
        try db.transaction {
            try service.authenticated();try readableConfig(configID);_ = try settings.next(after:now)
            let row=try db.insert("crm_Report_Schedule",values:["reportConfigId":.text(configID),"cronExpression":.text(settings.cron.expression),"recipients":.text(String(decoding:JSONEncoder().encode(settings.recipients),as:UTF8.self)),"format":.text(settings.format.rawValue),"createdBy":.text(service.identity.id)],actor:service.identity.id)
            try remember(row,settings:settings,now:now);return .init(record:row,settings:settings)
        }
    }
    func update(_ expected:NativeReportSchedule,settings:NativeReportScheduleSettings,isActive:Bool,now:Date=Date())throws->NativeReportSchedule {
        let result:NativeReportSchedule=try db.transaction {
            let fresh=try load(expected.id)
            guard fresh.record.revision==expected.record.revision else {throw NativeDBError.conflict}
            if isActive {try readableConfig(fresh.record["reportConfigId"].string);_ = try settings.next(after:now)}
            let row=try db.update(fresh.record,changes:["cronExpression":.text(settings.cron.expression),"recipients":.text(String(decoding:JSONEncoder().encode(settings.recipients),as:UTF8.self)),"format":.text(settings.format.rawValue),"isActive":.integer(isActive ? 1 : 0)],actor:service.identity.id)
            try remember(row,settings:settings,now:now);return .init(record:row,settings:settings)
        }
        NativeReportQueue.requestCleanup(db:db,scheduleID:expected.id);return result
    }
    /// Even an invalid legacy recipient/cron field can be removed from a bounded
    /// list row. Do not deserialize its potentially large JSON just to delete it.
    func delete(_ expected:NativeRecord)throws {
        try db.transaction {
            guard expected.model=="crm_Report_Schedule" else {throw NativeDBError.conflict}
            let fresh=try access(expected["id"].string)
            guard fresh.revision==expected.revision else {throw NativeDBError.conflict}
            try db.cancelUnstartedReportJobs(scheduleID:expected["id"].string)
            try db.remove(fresh,actor:service.identity.id,action:"delete_report_schedule");try db.clearReportScheduleMetadata(expected["id"].string)
        }
        NativeReportQueue.requestCleanup(db:db,scheduleID:expected["id"].string)
    }
}
