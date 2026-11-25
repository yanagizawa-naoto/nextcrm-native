import Foundation

/// Keep the original URL parameter representation, including filters not yet
/// consumed by a particular metric. Loading/saving must not erase those keys.
struct NativeReportSavedFilters {
    let parameters: [String:String]
    private let fallbackCurrency: String
    init(json: String, fallbackCurrency: String = "JPY") throws {
        guard json.utf8.count <= 65_536,
              let value = try? JSONDecoder().decode([String:String].self,from:Data(json.utf8)),
              value.count <= 64 else {throw NativeDBError.message("保存された集計条件を読み込めません。条件の形式とサイズを確認してください。")}
        parameters=value;self.fallbackCurrency=fallbackCurrency
    }
    init(period: NativeReportFilters, currency: String, retaining parameters: [String:String] = [:]) throws {
        var value=parameters
        value["from"]=NativeReportFilters.timestamp(period.from);value["to"]=NativeReportFilters.timestamp(period.to);value["currency"]=currency
        try self.init(json:String(decoding:JSONEncoder().encode(value),as:UTF8.self))
    }
    var json: String { get throws {String(decoding:try JSONEncoder().encode(parameters),as:UTF8.self)} }
    var currency: String {
        get throws {
            let value=parameters["currency"] ?? fallbackCurrency
            guard value.utf8.count == 3, value.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) else {throw NativeDBError.message("保存された表示通貨を確認してください。")}
            return value
        }
    }
    func period(now: Date = Date()) throws -> NativeReportFilters {
        func parse(_ value: String?, fallback: Date) throws -> Date {
            guard let value,!value.isEmpty else {return fallback}
            let fraction=ISO8601DateFormatter();fraction.formatOptions.insert(.withFractionalSeconds)
            if let date=fraction.date(from:value) ?? ISO8601DateFormatter().date(from:value) {return date}
            // JavaScript's YYYY-MM-DD is UTC, regardless of the viewer's zone.
            let plain=DateFormatter();plain.locale=Locale(identifier:"en_US_POSIX");plain.calendar=Calendar(identifier:.gregorian);plain.timeZone=TimeZone(secondsFromGMT:0);plain.dateFormat="yyyy-MM-dd";plain.isLenient=false
            if let date=plain.date(from:value),plain.string(from:date)==value {return date}
            throw NativeDBError.message("保存された集計期間の日付が不正です。")
        }
        let start=Calendar.current.date(byAdding:.day,value:-30,to:now)!
        return try NativeReportFilters(from:parse(parameters["from"],fallback:start),to:parse(parameters["to"],fallback:now))
    }
}

struct NativeReportConfiguration {
    let record: NativeRecord
    let category: NativeReportCategory
    let filters: NativeReportSavedFilters
    var id: String {record["id"].string}
    var name: String {record["name"].string}
}

struct NativeReportConfigurations {
    let service: CRMService
    private var db: NativeDatabase {service.db}
    private var readScope: RecordFilter {
        service.identity.elevated ? .all : .any([.equal("createdBy",.text(service.identity.id)),.equal("isShared",.integer(1))])
    }
    private func category(_ raw: String) throws -> NativeReportCategory {
        guard let category=NativeReportCategory(rawValue:raw),category != .overview else {throw NativeDBError.message("保存されたレポートの種類が不正です。")}
        return category
    }
    private func name(_ value: String) throws -> String {
        let value=value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,value.unicodeScalars.count<=256 else {throw NativeDBError.message("レポート名を1〜256文字で入力してください。")}
        return value
    }
    func list(category: NativeReportCategory? = nil, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try db.transaction {
            try service.authenticated()
            var filters=[readScope]
            if let category {filters.append(.equal("category",.text(category.rawValue)))}
            let page=try db.page("crm_Report_Config",fields:[],offset:offset,filter:.every(filters),sort:"createdAt",descending:true)
            let rows=try page.rows.map { row in
                try db.keysetPage("crm_Report_Config",fields:["name","category","isShared","createdBy","createdAt"],filter:.equal("id",row["id"]),limit:1,maximumTextCharacters:["name":256,"category":32,"createdBy":64]).first!
            }
            return (rows,page.total)
        }
    }
    func load(_ id: String) throws -> NativeReportConfiguration {
        try db.transaction {
            try service.authenticated()
            guard try db.page("crm_Report_Config",fields:[],filter:.every([readScope,.equal("id",.text(id))]),limit:1).total==1 else {throw NativeDBError.message("レポートが見つからないか、閲覧する権限がありません。")}
            let row=try db.reportConfigurationRecord(id)
            // Legacy web configurations normally omit currency: the source page
            // falls back to the migrated system setting when no viewer cookie
            // is available. Keep this fallback separate from stored JSON.
            let setting=try db.keysetPage("crm_SystemSettings",fields:["value"],filter:.equal("key",.text("default_currency")),limit:1,maximumTextCharacters:["value":4]).first?["value"].string ?? ""
            return try .init(record:row,category:category(row["category"].string),filters:NativeReportSavedFilters(json:row["filters"].string,fallbackCurrency:setting.isEmpty ? "JPY" : setting))
        }
    }
    func save(name rawName: String, category: NativeReportCategory, filters: NativeReportSavedFilters, shared: Bool) throws -> NativeReportConfiguration {
        try db.transaction {
            try service.authenticated();_ = try self.category(category.rawValue)
            let row=try db.insert("crm_Report_Config",values:["name":.text(name(rawName)),"category":.text(category.rawValue),"filters":.text(filters.json),"isShared":.integer(shared ? 1 : 0),"createdBy":.text(service.identity.id)],actor:service.identity.id)
            return .init(record:row,category:category,filters:filters)
        }
    }
    private func current(_ expected: NativeReportConfiguration, write: Bool) throws -> NativeReportConfiguration {
        let fresh=try load(expected.id)
        guard fresh.record.revision==expected.record.revision else {throw NativeDBError.conflict}
        guard !write || service.identity.elevated || fresh.record["createdBy"] == .text(service.identity.id) else {throw NativeDBError.message("このレポートを変更する権限がありません。")}
        return fresh
    }
    func duplicate(_ expected: NativeReportConfiguration, name: String) throws -> NativeReportConfiguration {
        try db.transaction {let fresh=try current(expected,write:false);return try save(name:name,category:fresh.category,filters:fresh.filters,shared:false)}
    }
    func share(_ expected: NativeReportConfiguration, enabled: Bool) throws -> NativeReportConfiguration {
        try db.transaction {
            let fresh=try current(expected,write:true),record=try db.update(fresh.record,changes:["isShared":.integer(enabled ? 1 : 0)],actor:service.identity.id)
            return .init(record:record,category:fresh.category,filters:fresh.filters)
        }
    }
    func delete(_ expected: NativeReportConfiguration) throws {
        try db.transaction {let fresh=try current(expected,write:true);try db.cancelUnstartedReportJobs(configID:fresh.id);try db.clearReportConfigurationScheduleMetadata(fresh.id);try db.remove(fresh.record,actor:service.identity.id,action:"delete_report_configuration")}
        NativeReportQueue.requestCleanup(db:db,scheduleID:nil,configID:expected.id)
    }
}
