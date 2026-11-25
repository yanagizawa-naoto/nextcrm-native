import Foundation

@main enum NativeLegacyFidelityTests {
    final class Capture {var currencies:[String]=[],revenues:[Double]=[],requests=0}
    struct Case: Decodable {
        let name:String,bundle:String,destination:String,actor:String,invoiceID:String,lineID:String,scheduleID:String
        let expectedCurrency:String,expectedRevenue:Double,filtersJSON:String,billingJSON:String
    }
    struct Outcome:Encodable {let name:String,currency:String,revenue:Double,checks:Int,mismatches:[String],importStatus:String}
    static func main() async {
        do {try await run()} catch {FileHandle.standardError.write(Data("NativeLegacyFidelityTests: \(error)\n".utf8));exit(1)}
    }
    static func run() async throws {
        guard CommandLine.arguments.count==4 else {throw NativeDBError.message("resources cases output")}
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        var outcomes:[Outcome]=[]
        for item in cases {
            var checks=0,mismatches:[String]=[]
            func check(_ test:@autoclosure () throws -> Bool,_ label:String)throws {guard try test() else {throw NativeDBError.message(item.name+": "+label)};checks+=1}
            func rejects(_ label:String,_ work:()throws->Void)throws {do {try work()} catch {checks+=1;return};throw NativeDBError.message(label+" accepted")}
            let destination=URL(fileURLWithPath:item.destination)
            let result=NativeMigrationImport().prepare(bundleURL:URL(fileURLWithPath:item.bundle),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:destination)
            try check(result.status == .prepared || result.status == .preparedWithGaps,"prepare rejected: \(result.diagnostics)")
            try check(!result.applicationRestored && !result.workersStarted && !result.keychainWritten,"preparation side effects")
            let sealed=destination.appendingPathComponent("candidate.sqlite"),before=try Data(contentsOf:sealed)
            let consumer=destination.deletingLastPathComponent().appendingPathComponent(item.name+"-consumer.sqlite")
            try FileManager.default.copyItem(at:sealed,to:consumer)
            let db=try NativeDatabase(url:consumer,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let service=CRMService(db:db,identity:.init(id:item.actor,role:"admin",partnerAccountID:nil))
            try service.authenticated();checks+=1
            let invoice=try db.get("Invoices",key:["id":.text(item.invoiceID)])!
            for (key,value) in ["currency":"USD","baseCurrency":"CZK","fxRateToBase":"22.12345678","subtotal":"100.00","vatTotal":"8.25","grandTotal":"108.25","balanceDue":"108.25","issueDate":"2024-02-20T09:00:00.123456Z"] {
                try check(invoice[key].string==value,"historical invoice \(key)")
            }
            try check(invoice["billingSnapshot"].string==item.billingJSON,"billing snapshot bytes")
            let line=try db.get("Invoice_LineItems",key:["id":.text(item.lineID)])!
            try check(line["taxRateSnapshot"].string=="8.25","tax snapshot")
            try check(line["lineVat"].string=="8.25" && line["lineTotal"].string=="108.25","stored line amounts")
            let tax=try db.get("Invoice_TaxRates",key:["id":line["taxRateId"]])!
            try check(tax["rate"].string=="20.00","current tax intentionally differs")
            let store=NativeReportConfigurations(service:service),config=try store.load("legacy-config")
            try check(config.record["filters"].string==item.filtersJSON,"source filters byte preserved")
            let expectedParameters=try JSONDecoder().decode([String:String].self,from:Data(item.filtersJSON.utf8))
            try check(config.filters.parameters==expectedParameters,"filters read without mutation")
            try check(config.filters.parameters["currency"]==nil,"no invented saved currency")
            let currency=try config.filters.currency,period=try config.filters.period()
            let report=try NativeReports(service:service).build(.sales,filters:period,currency:currency)
            guard let revenue=report.metrics.first(where:{$0.id=="revenue"}).flatMap({Double($0.value)}) else {throw NativeDBError.message("revenue metric missing")}
            if currency != item.expectedCurrency {mismatches.append("currency \(currency) != source \(item.expectedCurrency)")} else {checks+=1}
            if revenue != item.expectedRevenue {mismatches.append("revenue \(revenue) != source \(item.expectedRevenue)")} else {checks+=1}
            let schedule=try db.get("crm_Report_Schedule",key:["id":.text(item.scheduleID)])!
            try check(schedule["reportConfigId"].string==config.id,"schedule relation")
            try check(schedule["cronExpression"].string=="0 9 * * *","source cron exact")
            try check(schedule["lastSentAt"].string=="2024-02-20T09:00:00.123456Z","lastSentAt microseconds")
            try check(schedule["recipients"].string=="[\"recipient@example.test\"]","recipient JSON exact")
            try check(schedule["format"].string=="csv" && schedule["isActive"] == .integer(1),"schedule flags")
            try check(try db.reportScheduleTimeZone(item.scheduleID)==nil,"timezone not invented")
            try rejects("unconfirmed migrated timezone"){_ = try NativeReportSchedules.decode(schedule,db:db,confirmedTimeZone:true)}
            try check(try NativeReportSchedules(service:service).history().total==0,"native history not invented")
            let clone=try store.duplicate(config,name:"検証用複製")
            try check(clone.filters.parameters==expectedParameters,"duplicate preserves source filters")
            try check(try store.load(clone.id).filters.currency==currency,"duplicate resolves same fallback")
            let shared=try store.share(config,enabled:false)
            try check(shared.filters.parameters==expectedParameters,"share preserves source filters")
            let explicit=try NativeReportSavedFilters(period:period,currency:"USD",retaining:expectedParameters)
            let explicitSaved=try store.save(name:"通貨を明示",category:.sales,filters:explicit,shared:false)
            try check(try store.load(explicitSaved.id).filters.currency=="USD","explicit native currency wins")
            // Real scheduler/worker/export path on the isolated copy; transport
            // is injected and never creates a socket or reads credentials.
            let clock=ISO8601DateFormatter().date(from:"2024-02-21T09:00:00Z")!,capture=Capture()
            let schedules=NativeReportSchedules(service:service)
            let loadedSchedule=try schedules.load(item.scheduleID)
            let confirmed=try schedules.update(loadedSchedule,settings:.init(expression:"* * * * *",recipients:["recipient@example.test"],format:"csv",timeZone:"Asia/Tokyo"),isActive:true,now:clock.addingTimeInterval(-60))
            let jobID=try db.reportScheduleState("job",id:confirmed.id)!
            let worker=ReportMailWorker(db:db,account:{.init(from:"test@example.invalid",apiKey:"synthetic-only")},request:{request,file in
                capture.requests+=1
                guard (try Data(contentsOf:file)).count>0 else {throw NativeDBError.message("empty fake transport body")}
                return (Data("{\"id\":\"00000000-0000-0000-0000-000000000099\"}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            },clock:{clock},export:{snapshot,section,format,url,title in
                capture.currencies.append(snapshot.currency)
                capture.revenues.append(Double(snapshot.metrics.first{$0.id=="revenue"}!.value)!)
                return try NativeReportExport.write(snapshot,section:section,format:format,to:url,title:title)
            })
            let ran=try await worker.runNext()
            try check(ran && capture.requests==1,"fake worker exported and delivered")
            try check(capture.currencies==[currency] && capture.revenues==[revenue],"worker/export uses resolved saved currency")
            try check(try db.job(id:jobID)?.result["outcome"]=="sent","fake worker receipt persisted")
            do {
                let key:[String:SQLValue]=["key":.text("default_currency")]
                if let setting=try db.get("crm_SystemSettings",key:key) {_ = try db.update(setting,changes:["value":.text("CZK")],actor:item.actor)}
                else {_ = try db.insert("crm_SystemSettings",values:["key":.text("default_currency"),"value":.text("CZK")],actor:item.actor)}
                try check(try store.load(config.id).filters.currency=="CZK","reopen reads changed system default")
                try check(try store.load(explicitSaved.id).filters.currency=="USD","explicit currency unaffected by default change")
                let setting=try db.get("crm_SystemSettings",key:key)!
                _ = try db.update(setting,changes:["value":.text("USDXYZ")],actor:item.actor)
                try rejects("invalid default not truncated into valid code"){_ = try store.load(config.id).filters.currency}
                try check(try store.load(explicitSaved.id).filters.currency=="USD","explicit currency ignores invalid default")
                if item.name == "default-CZK" {
                    let values=["USD","JPY","CZK","USD\n","USD\r\n","USD\nBAD","USD\r\nBAD","USDXYZ","USD"+String(repeating:"X",count:512),"US","usd","ＵＳＤ"]
                    for (index,value) in values.enumerated() {
                        let valid=["USD","JPY","CZK"].contains(value)
                        let current=try db.get("crm_SystemSettings",key:key)!
                        _ = try db.update(current,changes:["value":.text(value)],actor:item.actor)
                        if valid {try check(try store.load(config.id).filters.currency==value,"three-byte default accepted")}
                        else {try rejects("default currency byte boundary \(index)"){_ = try store.load(config.id).filters.currency}}
                        let raw=String(decoding:try JSONEncoder().encode(["currency":value]),as:UTF8.self)
                        let filters=try NativeReportSavedFilters(json:raw)
                        let saved=try store.save(name:"通貨境界 \(index)",category:.sales,filters:filters,shared:false)
                        if valid {try check(try store.load(saved.id).filters.currency==value,"three-byte saved currency accepted")}
                        else {try rejects("saved currency byte boundary \(index)"){_ = try store.load(saved.id).filters.currency}}
                    }
                }
            }
            try check(try Data(contentsOf:sealed)==before,"sealed candidate unchanged")
            outcomes.append(.init(name:item.name,currency:currency,revenue:revenue,checks:checks,mismatches:mismatches,importStatus:result.status.rawValue))
        }
        try JSONEncoder().encode(outcomes).write(to:URL(fileURLWithPath:CommandLine.arguments[3]),options:.atomic)
        print("LegacyFidelity: \(outcomes.count) cases, \(outcomes.reduce(0){$0+$1.checks}) checks, \(outcomes.reduce(0){$0+$1.mismatches.count}) mismatches")
        guard outcomes.allSatisfy({$0.mismatches.isEmpty}) else {throw NativeDBError.message("Migrated report currency differs from executed original source")}
    }
}
