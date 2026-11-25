import Foundation

enum NativeReportCategory: String, CaseIterable {
    case overview, sales, leads, accounts, activity, campaigns, users
    var title: String { ["overview":"全体の状況","sales":"売上・商談","leads":"リード・連絡先","accounts":"取引先","activity":"活動・タスク","campaigns":"キャンペーン","users":"利用者"][rawValue]! }
}
struct NativeReportFilters {
    let from: Date, to: Date
    init(from: Date, to: Date) throws {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite, from <= to,
              from.timeIntervalSince1970 >= -62_135_596_800, to.timeIntervalSince1970 < 253_402_300_800 else { throw NativeDBError.message("集計期間の開始日と終了日を確認してください。") }
        self.from = from; self.to = to
    }
    var previous: NativeReportFilters { get throws { try .init(from: from.addingTimeInterval(-to.timeIntervalSince(from)), to: from) } }
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        return f.string(from:date)
    }
    func range(_ field: String) -> RecordFilter {
        .every([.compareDate(field,.greaterOrEqual,Self.timestamp(from)),.compareDate(field,.lessOrEqual,Self.timestamp(to))])
    }
}
struct NativeReportMetric {
    let id: String, title: String, value: String, unit: String
    var previous: String? = nil
    var changePercent: Int? = nil
    var destination: NativeReportCategory? = nil
}
struct NativeReportSection {
    let id: String, title: String, chart: String
    var secondaryTitle: String? = nil
}
struct NativeReportRow {
    let id: Int64, name: String, value: String, secondary: String?
    let truncated: Bool
}

final class NativeReportSnapshot {
    let service: CRMService, token: String, revision: String
    let category: NativeReportCategory, filters: NativeReportFilters, currency: String
    let metrics: [NativeReportMetric], sections: [NativeReportSection], missingRateCount: Int
    init(service: CRMService, token: String, revision: String, category: NativeReportCategory, filters: NativeReportFilters, currency: String, metrics: [NativeReportMetric], sections: [NativeReportSection], missingRateCount: Int) {
        self.service = service; self.token = token; self.revision = revision; self.category = category; self.filters = filters; self.currency = currency
        self.metrics = metrics; self.sections = sections; self.missingRateCount = missingRateCount
    }
    deinit { service.db.removeReportWorkspace(token) }
    func requireCurrent() throws {
        try service.authenticated()
        guard category != .users || service.identity.elevated else { throw NativeDBError.message("利用者のレポートは管理者とマネージャーだけが表示できます。") }
        guard try service.db.reportRevision() == revision else { throw NativeDBError.message("集計後に情報が更新されました。再集計してください。") }
    }
    func page(_ section: String, offset: Int = 0, sort: String = "original", ascending: Bool = true) throws -> (rows:[NativeReportRow],total:Int) {
        try service.db.transaction {
            try requireCurrent(); guard sections.contains(where: { $0.id == section }) else { throw NativeDBError.conflict }
            let page = try service.db.reportPage(token,section:section,offset:offset,sort:sort,ascending:ascending)
            return (page.rows.map { .init(id:Int64($0["id"]!.string)!,name:$0["label"]!.string,value:$0["value"]!.string,secondary:$0["secondary"] == .null ? nil : $0["secondary"]?.string,truncated:$0["truncated"] == .integer(1)) },page.total)
        }
    }
    func labelChunks(rowID: Int64, visit: (Data) throws -> Void) throws {
        try service.db.transaction { try requireCurrent(); try service.db.reportLabelChunks(token,rowID:rowID,visit:visit) }
    }
}

struct NativeReports {
    let service: CRMService
    var now: () -> Date = Date.init
    private var db: NativeDatabase { service.db }
    static func percent(_ value: Int, _ total: Int) -> Int { total > 0 ? Int(floor(Double(value)/Double(total)*100+0.5)) : 0 }
    static func change(_ value: Decimal, _ previous: Decimal) -> Int {
        if previous == 0 { return value > 0 ? 100 : 0 }
        let ratio = NSDecimalNumber(decimal: (value-previous)/previous).doubleValue * 100
        return ratio.isFinite && abs(ratio) < Double(Int.max)-1 ? Int(floor(ratio+0.5)) : 0
    }
    private var liveTasks: RecordFilter {
        .any([.equal("section",.null),.relation(model:"Sections",local:"section",foreign:"id",matching:.relation(model:"Boards",local:"board",foreign:"id",matching:.equal("deletedAt",.null)))])
    }
    private var liveCampaigns: RecordFilter { .every([.equal("deletedAt",.null),.any([.equal("status",.null),.not(.equal("status",.text("deleted")))])]) }
    private func scope(_ model: String, date field: String? = nil, filters: NativeReportFilters? = nil) throws -> RecordFilter {
        var predicates: [RecordFilter] = [model == "Users" ? (service.identity.elevated ? .all : .none) : service.reportScope(model)]
        if try db.schema.model(model).field("deletedAt") != nil { predicates.append(.equal("deletedAt",.null)) }
        if model == "Tasks" { predicates.append(liveTasks) }
        if model == "crm_campaigns" { predicates.append(liveCampaigns) }
        if let field, let filters { predicates.append(filters.range(field)) }
        return .every(predicates)
    }
    private func count(_ model: String, _ filter: RecordFilter) throws -> Int { try Task.checkCancellation(); return try db.page(model,fields:[],filter:filter,limit:1).total }
    private func sendScope(_ filters: NativeReportFilters) -> RecordFilter {
        .every([filters.range("sent_at"),.relation(model:"crm_campaigns",local:"campaign_id",foreign:"id",matching:.every([service.reportScope("crm_campaigns"),liveCampaigns]))])
    }
    private struct Sales {
        var revenue = Decimal(0), pipeline = Decimal(0), won = 0, lost = 0, cycleCount = 0, cycleDays = 0.0, missing = 0
        var average: Decimal { get throws { won == 0 ? 0 : PriceDecimal.rounded(try PriceDecimal.calculate(revenue,"/",Decimal(won))) } }
        var cycle: Int { cycleCount == 0 ? 0 : Int(floor(cycleDays/Double(cycleCount)+0.5)) }
    }
    private func sales(_ filters: NativeReportFilters, currency: String) throws -> Sales {
        let filter = try scope("crm_Opportunities",date:"created_on",filters:filters)
        var result = Sales(), after: String?, rates: [String:Decimal] = [:]
        let plain = ISO8601DateFormatter(), fraction = ISO8601DateFormatter(); fraction.formatOptions.insert(.withFractionalSeconds)
        func date(_ value: SQLValue) -> Date? { fraction.date(from:value.string) ?? plain.date(from:value.string) }
        while true {
            try Task.checkCancellation()
            let page = try db.keysetPage("crm_Opportunities",fields:["budget","currency","status","created_on","close_date"],after:after,filter:filter,maximumTextCharacters:["currency":32])
            for row in page {
                let state = row["status"].string
                if state == "INACTIVE" { result.lost += 1; continue }
                guard state == "CLOSED" || state == "ACTIVE" else { continue }
                let amount = try PriceDecimal.parse(row["budget"] == .null ? "0" : row["budget"].string)
                let from = row["currency"].string.isEmpty ? currency : row["currency"].string
                let rate: Decimal?
                if from == currency { rate = 1 }
                else if let cached = rates[from] { rate = cached }
                else if let record = try db.keysetPage("ExchangeRate",fields:["rate"],filter:.every([.equal("fromCurrency",.text(from)),.equal("toCurrency",.text(currency))]),limit:1).first {
                    rate = try PriceDecimal.parse(record["rate"].string); if rates.count >= 32 { rates.removeAll(keepingCapacity:true) }; rates[from] = rate
                } else { rate = nil; result.missing += 1 }
                let converted = try rate.map { PriceDecimal.rounded(try PriceDecimal.calculate(amount,"*",$0)) } ?? amount
                if state == "CLOSED" {
                    result.won += 1; result.revenue = try PriceDecimal.calculate(result.revenue,"+",converted)
                    if row["close_date"] != .null { result.cycleCount += 1; if let created = date(row["created_on"]), let closed = date(row["close_date"]) { result.cycleDays += closed.timeIntervalSince(created)/86400 } }
                } else { result.pipeline = try PriceDecimal.calculate(result.pipeline,"+",converted) }
            }
            if page.count < 100 { return result }; after = page.last!["id"].string
        }
    }
    func build(_ category: NativeReportCategory, filters: NativeReportFilters, currency: String = "JPY") throws -> NativeReportSnapshot {
        try db.transaction {
            try service.authenticated(); try Task.checkCancellation()
            guard currency.range(of:"^[A-Z]{3}$",options:.regularExpression) != nil else { throw NativeDBError.message("表示通貨を確認してください。") }
            guard category != .users || service.identity.elevated else { throw NativeDBError.message("利用者のレポートは管理者とマネージャーだけが表示できます。") }
            let token = try db.createReportWorkspace(); var keep = false
            defer { if !keep { db.removeReportWorkspace(token) } }
            var metrics: [NativeReportMetric] = [], sections: [NativeReportSection] = [], missing = 0
            func metric(_ id: String, _ title: String, _ value: String, _ unit: String = "") { metrics.append(.init(id:id,title:title,value:value,unit:unit)) }
            func chart(_ id: String, _ title: String, _ kind: String, _ filter: RecordFilter, second: String? = nil) throws {
                try db.aggregateReport(token,section:id,recipe:id,filter:filter); sections.append(.init(id:id,title:title,chart:kind,secondaryTitle:second))
            }
            switch category {
            case .sales:
                let values = try sales(filters,currency:currency); missing = values.missing
                metric("revenue","売上",PriceDecimal.string(values.revenue),currency); metric("pipeline","進行中の商談金額",PriceDecimal.string(values.pipeline),currency)
                metric("avgDeal","平均成約金額",PriceDecimal.string(try values.average),currency); metric("winRate","成約率",String(Self.percent(values.won,values.won+values.lost)),"%")
                metric("cycleLength","平均成約日数",String(values.cycle),"日")
                let f = try scope("crm_Opportunities",date:"created_on",filters:filters)
                try chart("oppsByStage","ステージ別の商談","bar",f); try chart("oppsByMonth","月別の商談","area",f)
            case .leads:
                let leads = try scope("crm_Leads",date:"createdAt",filters:filters), contacts = try scope("crm_Contacts",date:"created_on",filters:filters)
                let total = try count("crm_Leads",leads), converted = try count("crm_Opportunities",scope("crm_Opportunities",date:"created_on",filters:filters))
                metric("conversionRate","商談化率",String(Self.percent(converted,total)),"%"); metric("converted","商談数",String(converted)); metric("leadCount","リード数",String(total))
                try chart("newLeads","月別の新規リード","area",leads); try chart("leadSources","リードの獲得経路","bar",leads)
                try chart("newContacts","月別の新規連絡先","area",contacts); try chart("contactsByAccount","取引先別の連絡先","table",contacts)
            case .accounts:
                let f = try scope("crm_Accounts",date:"createdAt",filters:filters)
                try chart("newAccounts","月別の新規取引先","area",f); try chart("byIndustry","業種別の取引先","bar",f)
                try chart("topByRevenue","年間売上高の上位取引先","table",.every([f,.not(.equal("annual_revenue",.null))]))
                try chart("bySize","従業員数別の取引先","bar",f)
            case .activity:
                let tasks = try scope("Tasks",date:"createdAt",filters:filters), stamp = NativeReportFilters.timestamp(now())
                let overdue = try count("Tasks",.every([scope("Tasks"),.equal("taskStatus",.text("ACTIVE")),.beforeDate("dueDateAt",stamp),.compareDate("dueDateAt",.greaterOrEqual,NativeReportFilters.timestamp(filters.from))]))
                metric("overdueTasks","期限超過のタスク",String(overdue))
                try chart("tasksCreatedCompleted","月別の作成・完了タスク","bar",tasks,second:"完了")
                try chart("tasksByAssignee","担当者別のタスク","bar",tasks); try chart("activitiesByType","種類別の活動","bar",scope("crm_Activities",date:"createdAt",filters:filters))
            case .campaigns:
                let sends = RecordFilter.every([sendScope(filters),.equal("status",.text("sent"))])
                let sent = try count("crm_campaign_sends",sends), opened = try count("crm_campaign_sends",.every([sends,.not(.equal("opened_at",.null))])), clicked = try count("crm_campaign_sends",.every([sends,.not(.equal("clicked_at",.null))]))
                metric("sent","送信数",String(sent)); metric("opened","開封数",String(opened)); metric("clicked","クリック数",String(clicked))
                metric("openRate","開封率",String(Self.percent(opened,sent)),"%"); metric("clickRate","クリック率",String(Self.percent(clicked,sent)),"%")
                let f = try scope("crm_campaigns",date:"created_on",filters:filters)
                try chart("campaignROI","キャンペーン別の送信記録数","bar",.every([f,.any([.equal("status",.text("sent")),.equal("status",.text("sending"))])]))
                try chart("topTemplates","送信記録数の多いテンプレート","bar",f)
                try chart("targetGrowth","対象リストの登録月別・営業対象数","area",scope("crm_TargetLists",date:"created_on",filters:filters))
                for (label,value) in [("Sent",sent),("Opened",opened),("Clicked",clicked)] { try db.insertReportRow(token,section:"performance",label:label,value:String(value)) }
                sections.append(.init(id:"performance",title:"送信・開封・クリック",chart:"table"))
            case .users:
                let active = RecordFilter.equal("userStatus",.text("ACTIVE"))
                metric("totalActive","有効な利用者",String(try count("Users",active)))
                try chart("activeByYear","登録年別の有効な利用者","bar",active)
                let f = filters.range("created_on"); try chart("userGrowth","月別の新規利用者","area",f); try chart("usersByRole","役割別の利用者","pie",f)
            case .overview:
                let previous = try filters.previous
                let currentSales = try sales(filters,currency:currency), oldSales = try sales(previous,currency:currency); missing = currentSales.missing+oldSales.missing
                func comparison(_ id: String, _ title: String, _ current: Decimal, _ old: Decimal, _ destination: NativeReportCategory, unit: String = "") {
                    metrics.append(.init(id:id,title:title,value:PriceDecimal.string(current),unit:unit,previous:PriceDecimal.string(old),changePercent:Self.change(current,old),destination:destination))
                }
                func totals(_ model: String, _ field: String, _ extra: RecordFilter = .all) throws -> (Int,Int) {
                    (try count(model,.every([scope(model,date:field,filters:filters),extra])),try count(model,.every([scope(model,date:field,filters:previous),extra])))
                }
                comparison("totalRevenue","売上",currentSales.revenue,oldSales.revenue,.sales,unit:currency); comparison("pipelineValue","進行中の商談金額",currentSales.pipeline,oldSales.pipeline,.sales,unit:currency)
                let leads = try totals("crm_Leads","createdAt"); comparison("newLeads","新規リード",Decimal(leads.0),Decimal(leads.1),.leads)
                comparison("conversionRate","リードに対する成約率",Decimal(Self.percent(currentSales.won,leads.0)),Decimal(Self.percent(oldSales.won,leads.1)),.sales,unit:"%")
                let contacts = try totals("crm_Contacts","created_on"); comparison("newContacts","新規連絡先",Decimal(contacts.0),Decimal(contacts.1),.leads)
                if service.identity.elevated {
                    let active = RecordFilter.equal("userStatus",.text("ACTIVE")), current = try count("Users",active)
                    let before = try count("Users",.every([active,.compareDate("created_on",.lessOrEqual,NativeReportFilters.timestamp(previous.to))]))
                    comparison("activeUsers","有効な利用者",Decimal(current),Decimal(before),.users)
                }
                let tasks = try totals("Tasks","createdAt",.equal("taskStatus",.text("ACTIVE"))); comparison("openTasks","未完了のタスク",Decimal(tasks.0),Decimal(tasks.1),.activity)
                comparison("campaignsSent","キャンペーン送信記録",Decimal(try count("crm_campaign_sends",sendScope(filters))),Decimal(try count("crm_campaign_sends",sendScope(previous))),.campaigns)
                let accounts = try totals("crm_Accounts","createdAt"); comparison("newAccounts","新規取引先",Decimal(accounts.0),Decimal(accounts.1),.accounts)
                let contracts = try totals("crm_Contracts","endDate"); comparison("contractsExpiring","終了予定の契約",Decimal(contracts.0),Decimal(contracts.1),.accounts)
            }
            try service.authenticated(); try Task.checkCancellation()
            let result = NativeReportSnapshot(service:service,token:token,revision:try db.reportRevision(),category:category,filters:filters,currency:currency,metrics:metrics,sections:sections,missingRateCount:missing)
            keep = true; return result
        }
    }
}
