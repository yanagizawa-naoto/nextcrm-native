import Foundation
import SQLite3

@main enum NativeReportsTests {
    static func main() async { do { try await run() } catch { FileHandle.standardError.write(Data("NativeReportsTests: \(error)\n".utf8)); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), fixture = URL(fileURLWithPath:CommandLine.arguments[2])
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as! [String:Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Reports-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String, _ work: () throws -> Void) throws { do { try work() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: "+label+" accepted") }
        func date(_ text: String) -> Date { let f=ISO8601DateFormatter();f.formatOptions.insert(.withFractionalSeconds);return f.date(from:text)! }
        func value(_ raw: Any) -> SQLValue { if raw is NSNull{return .null};if let n=raw as? NSNumber{return .integer(n.int64Value)};return .text(raw as! String) }
        let data=reference["data"] as! [String:[[String:Any]]], users=reference["users"] as! [[String:Any]], adminID=users[0]["id"] as! String
        let order=["Users","Currency","crm_Opportunities_Sales_Stages","crm_Industry_Type","crm_Lead_Sources","crm_Accounts","AccountWatchers","crm_Opportunities","crm_Leads","crm_Contacts","crm_Contracts","ExchangeRate","Boards","Sections","Tasks","crm_Activities","crm_campaign_templates","crm_Targets","crm_campaigns","crm_campaign_steps","crm_campaign_sends","crm_TargetLists","TargetsToTargetLists"]
        try db.transaction {
            for model in order {
                for raw in data[model] ?? [] {
                    var input=raw.mapValues(value)
                    if model == "Users" { input["partnerAccountId"] = .null }
                    do { try db.insert(model,values:input,actor:adminID) } catch { throw NativeDBError.message("Seed \(model): \(error)") }
                }
                if model == "Currency" { for code in ["JPY","USD","EUR","GBP"] { try db.insert("Currency",values:["code":.text(code),"name":.text(code),"symbol":.text(code)],actor:adminID) } }
            }
            for user in users { if let account=user["partnerAccountId"] as? String { let r=try db.get("Users",key:["id":.text(user["id"] as! String)])!;try db.update(r,changes:["partnerAccountId":.text(account)],actor:adminID) } }
        }
        let services=Dictionary(uniqueKeysWithValues:users.map { u -> (String,CRMService) in let id=u["id"] as! String;return (id,CRMService(db:db,identity:.init(id:id,role:u["role"] as! String,partnerAccountID:u["partnerAccountId"] as? String))) })
        let now=date(reference["now"] as! String)
        func decimal(_ x: Any) -> Decimal { Decimal(string:String(describing:x),locale:Locale(identifier:"en_US_POSIX"))! }
        func rows(_ snapshot: NativeReportSnapshot, _ section: String) throws -> [NativeReportRow] {
            var result:[NativeReportRow]=[],offset=0
            while true {let page=try snapshot.page(section,offset:offset);result+=page.rows;offset+=page.rows.count;if offset>=page.total{return result};guard !page.rows.isEmpty else {throw NativeDBError.conflict}}
        }
        for c in reference["cases"] as! [[String:Any]] {
            let category=NativeReportCategory(rawValue:c["category"] as! String)!,service=services[c["user"] as! String]!
            let filters=try NativeReportFilters(from:date(c["from"] as! String),to:date(c["to"] as! String))
            let snapshot=try NativeReports(service:service,now:{now}).build(category,filters:filters,currency:c["currency"] as! String)
            let context="\(service.identity.role)/\(service.identity.id.suffix(2))/\(category.rawValue)/\(c["currency"]!)/\(c["from"]!)"
            let metrics=c["metrics"] as! [String:Any]
            try check(snapshot.metrics.count == (category == .overview ? (service.identity.elevated ? 10 : 9) : metrics.count),context+" metric count")
            for (key,expected) in metrics { let actual=snapshot.metrics.first{$0.id==key};try check(actual != nil && Double(actual!.value) == (expected as! NSNumber).doubleValue,context+" metric \(key): \(actual?.value ?? "missing") != \(expected)") }
            let comparisons=c["comparisons"] as! [[String:Any]]
            for expected in comparisons {
                let key=expected["label"] as! String
                if key == "activeUsers" && !service.identity.elevated {try check(!snapshot.metrics.contains{$0.id==key},context+" directory leak corrected");continue}
                let actual=snapshot.metrics.first{$0.id==key}!
                try check(Double(actual.value)==(expected["value"] as! NSNumber).doubleValue,context+" overview \(key)")
                try check(Double(actual.previous!)==(expected["previousValue"] as! NSNumber).doubleValue,context+" previous \(key)")
                try check(actual.changePercent==expected["changePercent"] as? Int,context+" change \(key)")
                try check(actual.destination?.rawValue==(expected["href"] as! String).components(separatedBy:"/").last,context+" drilldown \(key)")
            }
            let series=c["series"] as! [String:[[String:Any]]],corrections=c["corrections"] as! [String:[[String:Any]]]
            try check(snapshot.sections.count==series.count,context+" series count")
            for (key,original) in series {
                let expected=corrections[key] ?? original,actual=try rows(snapshot,key)
                func canonical(_ name: String,_ n: Decimal,_ secondary: Decimal?) -> String { name+"|"+NSDecimalNumber(decimal:n).stringValue+"|"+(secondary.map{NSDecimalNumber(decimal:$0).stringValue} ?? "") }
                let actualValues=actual.map{canonical($0.name,decimal($0.value),$0.secondary.map(decimal))}
                let expectedValues=expected.map{canonical($0["name"] as! String,decimal($0["Number"] ?? $0["created"]!),$0["completed"].map(decimal))}
                try check(actualValues.sorted()==expectedValues.sorted(),context+" series \(key): \(actualValues) != \(expectedValues)")
                if ["oppsByMonth","newLeads","newContacts","newAccounts","tasksCreatedCompleted","targetGrowth","userGrowth","activeByYear","topByRevenue"].contains(key) {try check(actualValues==expectedValues,context+" ordered \(key)")}
            }
        }
        let admin=services[adminID]!, filters=try NativeReportFilters(from:date("2026-01-01T00:00:00.000Z"),to:now)
        for user in users where !["admin","manager"].contains(user["role"] as! String) {try rejects("user directory denial") {_ = try NativeReports(service:services[user["id"] as! String]!).build(.users,filters:filters)}}
        try rejects("reversed date") {_ = try NativeReportFilters(from:now,to:now.addingTimeInterval(-1))}
        try rejects("invalid date") {_ = try NativeReportFilters(from:Date(timeIntervalSince1970:.nan),to:now)}
        try rejects("currency injection") {_ = try NativeReports(service:admin).build(.sales,filters:filters,currency:"JPY'")}
        var snapshot:NativeReportSnapshot?=try NativeReports(service:admin).build(.sales,filters:filters)
        let token=snapshot!.token
        try rejects("unknown section") {_ = try snapshot!.page("arbitrary")}
        try rejects("sort injection") {_ = try snapshot!.page("oppsByStage",sort:"value; DROP TABLE Users")}
        try rejects("negative page") {_ = try snapshot!.page("oppsByStage",offset:-1)}
        snapshot=nil
        try rejects("snapshot frees temp table") {_ = try db.reportPage(token,section:"oppsByStage")}
        // More groups than one display page, including a full multibyte label
        // which must survive byte streaming without being held by the UI.
        let longLabel=String(repeating:"日本語😀,\"\r\n",count:6000)
        try db.transaction {
            for i in 0..<205 {
                let stage=try db.insert("crm_Opportunities_Sales_Stages",values:["name":.text(i==204 ? longLabel : "検証ステージ\(i)")],actor:adminID)
                try db.insert("crm_Opportunities",values:["name":.text("検証"),"sales_stage":stage["id"],"created_on":.text("2026-10-02T00:00:00.000Z"),"budget":.text("0"),"status":.text("ACTIVE"),"createdBy":.text(adminID)],actor:adminID)
            }
        }
        let paged=try NativeReports(service:admin).build(.sales,filters:filters)
        let first=try paged.page("oppsByStage"), second=try paged.page("oppsByStage",offset:100)
        try check(first.rows.count==100 && second.rows.count==100 && first.total>=205,"bounded group pages")
        try check(Set(first.rows.map{$0.id}).isDisjoint(with:second.rows.map{$0.id}),"page uniqueness")
        let all=try rows(paged,"oppsByStage"),long=all.first{$0.truncated}!
        try check(long.name.unicodeScalars.count==1024,"label display bounded")
        var restored=Data(),chunkCount=0
        try paged.labelChunks(rowID:long.id) {bytes in try check(bytes.count<=16384,"label chunk bound");restored.append(bytes);chunkCount+=1}
        try check(chunkCount>1 && String(data:restored,encoding:.utf8)==longLabel,"lossless full label streaming")
        let numericToken=try db.createReportWorkspace();defer{db.removeReportWorkspace(numericToken)}
        for n in reference["numericCases"] as! [[String:Any]] {
            let account=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("整数解析"),"annual_revenue":.text(n["value"] as! String)],actor:adminID)
            let section=account["id"].string
            try db.aggregateReport(numericToken,section:section,recipe:"topByRevenue",filter:.equal("id",account["id"]))
            let result=try db.reportPage(numericToken,section:section)
            if n["expected"] is NSNull {try check(result.rows.isEmpty,"parseInt invalid \(n["value"]!)")}
            else {try check(result.rows.count==1 && Double(result.rows[0]["value"]!.string)==(n["expected"] as! NSNumber).doubleValue,"parseInt \(n["value"]!)")}
        }
        try rejects("workspace token injection") {_ = try db.reportPage("';DROP TABLE Users",section:"x")}
        try rejects("unknown recipe") {try db.aggregateReport(numericToken,section:"x",recipe:"x",filter:.all)}
        try rejects("mutation invalidates snapshot") {_ = try paged.page("oppsByStage")}
        let fresh=try NativeReports(service:admin).build(.accounts,filters:filters)
        let external=try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try external.insert("crm_Accounts",values:["v":.integer(0),"name":.text("外部変更")],actor:adminID)
        try rejects("other connection invalidates snapshot") {_ = try fresh.page("newAccounts")}
        let revoked=try NativeReports(service:admin).build(.users,filters:filters)
        let adminRecord=try db.get("Users",key:["id":.text(adminID)])!
        let banned=try db.update(adminRecord,changes:["banned":.integer(1)],actor:adminID)
        try rejects("fresh authorization on read") {_ = try revoked.page("userGrowth")}
        try rejects("fresh authorization on build") {_ = try NativeReports(service:admin).build(.overview,filters:filters)}
        try db.update(banned,changes:["banned":.integer(0)],actor:adminID)
        let task=Task.detached {try Task.checkCancellation();return try NativeReports(service:admin).build(.overview,filters:filters)}
        task.cancel()
        do {_ = try await task.value;throw NativeDBError.message("FAIL: cancellation accepted")} catch is CancellationError {checks+=1}
        let afterCancel=try NativeReports(service:admin).build(.sales,filters:filters)
        try check(try afterCancel.page("oppsByStage").total>=205,"database usable after cancel")
        let configurationChecks=try NativeReportConfigurationTests.run(db:db,services:services,resources:resources);checks+=configurationChecks
        checks+=try NativeReportScheduleTests.run(db:db,services:services,resources:resources)
        print("{\"suite\":\"NativeReports\",\"timeZone\":\"\(reference["timeZone"]!)\",\"checks\":\(checks),\"cases\":\((reference["cases"] as! [Any]).count)}")
    }
}
