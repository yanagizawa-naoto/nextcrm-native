import Foundation
import PDFKit

@main enum NativeReportExportTests {
    static func main()async{do{try await run()}catch{FileHandle.standardError.write(Data("NativeReportExportTests: \(error)\n".utf8));exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ReportExport-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let output=resources.appendingPathComponent("../artifacts/native-reports-export",isDirectory:true);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),service=CRMService(db:db,identity:identity)
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/report-export-reference.json"))) as! [String:Any],rows=reference["rows"] as! [[String:Any]]
        var checks=0
        func check(_ value:@autoclosure()throws->Bool,_ label:String)throws{guard try value()else{throw NativeDBError.message("FAIL export: "+label)};checks+=1}
        func rejects(_ label:String,_ work:()throws->Void)throws{do{try work()}catch{checks+=1;return};throw NativeDBError.message("FAIL export accepted: "+label)}
        try db.transaction {
            for row in rows {
                let stage=try db.insert("crm_Opportunities_Sales_Stages",values:["name":.text(row["name"] as! String)],actor:identity.id)
                for _ in 0..<(row["Number"] as! Int){try db.insert("crm_Opportunities",values:["sales_stage":stage["id"],"created_on":.text("2026-11-15T12:00:00Z"),"status":.text("ACTIVE"),"budget":.text("0"),"createdBy":.text(identity.id)],actor:identity.id)}
            }
        }
        let formatter=ISO8601DateFormatter(),filters=try NativeReportFilters(from:formatter.date(from:"2026-11-01T00:00:00Z")!,to:formatter.date(from:"2026-11-19T23:59:59Z")!)
        let snapshot=try NativeReports(service:service).build(.sales,filters:filters)
        let csv=output.appendingPathComponent("代表レポート.csv"),pdf=output.appendingPathComponent("代表レポート.pdf")
        try check(try NativeReportExport.write(snapshot,section:"oppsByStage",format:.csv,to:csv)==129,"CSV spans database pages")
        let bytes=try Data(contentsOf:csv),text=String(data:bytes,encoding:.utf8)!
        try check(bytes.prefix(3)==Data([0xef,0xbb,0xbf]),"UTF8 BOM for Japanese spreadsheet import")
        for row in rows {let expected="\""+(row["name"] as! String).replacingOccurrences(of:"\"",with:"\"\"")+"\",\"\(row["Number"]!)\"\r\n";try check(text.contains(expected),"full original CSV label/value")}
        try check(try NativeReportExport.write(snapshot,section:"oppsByStage",format:.pdf,to:pdf)==129,"PDF spans result pages")
        let document=PDFDocument(url:pdf)!
        try check(document.pageCount>3,"long label crosses PDF pages")
        let extracted=document.string ?? ""
        try check(extracted.contains("売上・商談")&&extracted.contains("ステージ別の商談")&&extracted.contains("128 日本語の担当チーム128"),"Japanese PDF text and final row")
        try check((1...document.pageCount).allSatisfy{document.page(at:$0-1)?.string?.contains("\($0) ページ")==true},"every page numbered")
        try check(document.page(at:1)?.string?.contains("項目")==true,"continuation table headers")
        for (input,expected) in [("日本語😀\r\n,\"",true),("",true)] {
            var decoder=NativeReportUTF8(),result=""
            for byte in input.utf8 {result+=try decoder.feed(Data([byte]))};result+=try decoder.finish();try check((result==input)==expected,"UTF8 single byte chunk boundaries")
        }
        try rejects("invalid UTF8"){var decoder=NativeReportUTF8();_ = try decoder.feed(Data([0xff]))}
        try rejects("truncated UTF8"){var decoder=NativeReportUTF8();_ = try decoder.feed(Data([0xf0,0x9f]));_ = try decoder.finish()}
        let empty=try NativeReports(service:service).build(.leads,filters:filters),emptyPDF=output.appendingPathComponent("空のレポート.pdf")
        try check(try NativeReportExport.write(empty,section:"newLeads",format:.pdf,to:emptyPDF)==0,"empty report exports")
        try check(PDFDocument(url:emptyPDF)!.string!.contains("該当するデータはありません"),"empty report explanation")
        let token=try db.createReportWorkspace();try db.insertReportRow(token,section:"tasksCreatedCompleted",label:"2026-11",value:"9000000000000000000",secondary:"8999999999999999999")
        let dual=NativeReportSnapshot(service:service,token:token,revision:try db.reportRevision(),category:.activity,filters:filters,currency:"JPY",metrics:[],sections:[.init(id:"tasksCreatedCompleted",title:"月別の作成・完了タスク",chart:"bar",secondaryTitle:"完了")],missingRateCount:0)
        try NativeReportExport.write(dual,section:"tasksCreatedCompleted",format:.pdf,to:output.appendingPathComponent("二系列のレポート.pdf"))
        try NativeReportExport.write(dual,section:"tasksCreatedCompleted",format:.csv,to:output.appendingPathComponent("二系列のレポート.csv"))
        try check(PDFDocument(url:output.appendingPathComponent("二系列のレポート.pdf"))!.string!.contains("完了数"),"secondary series header")
        let original=Data("previous destination".utf8),destination=root.appendingPathComponent("preserved.csv");try original.write(to:destination)
        try rejects("stale export preserves destination"){try NativeReportExport.write(snapshot,section:"oppsByStage",format:.csv,to:destination)}
        try check(try Data(contentsOf:destination)==original,"stale export did not replace")
        try rejects("unknown section"){try NativeReportExport.write(dual,section:"anything",format:.csv,to:destination)}
        let cancelled=try NativeReports(service:service).build(.sales,filters:filters),cancelTarget=root.appendingPathComponent("cancel.pdf");try original.write(to:cancelTarget)
        let task=Task.detached{try NativeReportExport.write(cancelled,section:"oppsByStage",format:.pdf,to:cancelTarget)}
        let deadline=Date().addingTimeInterval(10)
        while try Date()<deadline && !FileManager.default.contentsOfDirectory(atPath:root.path).contains(where:{$0.hasPrefix(".nextcrm-report-")}) {try await Task.sleep(nanoseconds:1_000_000)}
        task.cancel()
        do{_ = try await task.value;throw NativeDBError.message("FAIL export cancellation accepted")}catch is CancellationError{checks+=1}
        try check(try Data(contentsOf:cancelTarget)==original,"cancel preserves existing output")
        try check(try !FileManager.default.contentsOfDirectory(atPath:root.path).contains(where:{$0.hasPrefix(".nextcrm-report-")}),"cancel removes partial output")
        let actual=try NativeReports(service:service).build(.sales,filters:filters),invalid=root.appendingPathComponent("directory");try FileManager.default.createDirectory(at:invalid,withIntermediateDirectories:true)
        try rejects("publish failure"){try NativeReportExport.write(actual,section:"oppsByMonth",format:.csv,to:invalid)}
        try check(try !FileManager.default.contentsOfDirectory(atPath:root.path).contains(where:{$0.hasPrefix(".nextcrm-report-")}),"publish failure cleans private file")
        print("{\"suite\":\"NativeReportExport\",\"checks\":\(checks),\"pdfPages\":\(document.pageCount)}")
    }
}
