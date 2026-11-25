import Foundation
import PDFKit

private final class ReportMailClock {var now=ISO8601DateFormatter().date(from:"2026-11-19T00:01:00Z")!}
private final class ReportMailTransport {
    var bodies:[Data]=[],keys:[String]=[],status=200
    var hook:(()throws->Void)?
    let receipt=UUID().uuidString.lowercased()
    func request(_ query:URLRequest,_ file:URL)async throws->(Data,HTTPURLResponse) {
        bodies.append(try Data(contentsOf:file));keys.append(query.value(forHTTPHeaderField:"Idempotency-Key") ?? "")
        try hook?()
        return (try JSONSerialization.data(withJSONObject:status==200 ? ["id":receipt] : ["name":"test_failure"]),HTTPURLResponse(url:query.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}
private final class ReportMailFixture {
    let db:NativeDatabase,service:CRMService,root:URL,clock=ReportMailClock(),transport=ReportMailTransport()
    var credentials=InvoiceMailAccount(from:"reports@example.invalid",apiKey:"report-test-key")
    init(resources:URL,parent:URL)throws {
        root=parent.appendingPathComponent(UUID().uuidString)
        db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
    }
    func create(category:NativeReportCategory = .sales,format:String="both",name:String="月次の営業レポート",service:CRMService?=nil)throws->NativeReportSchedule {
        let service=service ?? self.service
        let config=try NativeReportConfigurations(service:service).save(name:name,category:category,filters:.init(json:"{\"from\":\"2026-11-01\",\"to\":\"2026-11-30\",\"currency\":\"JPY\"}"),shared:false)
        return try NativeReportSchedules(service:service).create(configID:config.id,settings:.init(expression:"* * * * *",recipients:["one@example.invalid","two@example.invalid"],format:format,timeZone:"Asia/Tokyo"),now:clock.now.addingTimeInterval(-60))
    }
    func job(_ schedule:NativeReportSchedule)throws->NativeJob {try db.job(id:db.reportScheduleState("job",id:schedule.id)!)!}
    func worker(export:ReportMailWorker.Export?=nil)->ReportMailWorker {
        if let export {return .init(db:db,account:{self.credentials},request:transport.request,clock:{self.clock.now},export:export)}
        return .init(db:db,account:{self.credentials},request:transport.request,clock:{self.clock.now})
    }
    func user(_ role:String="user")throws->CRMService {
        let row=try db.insert("Users",values:["name":.text("担当者"),"email":.text(UUID().uuidString+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:service.identity.id)
        return CRMService(db:db,identity:.init(id:row["id"].string,role:role,partnerAccountID:nil))
    }
}

@main enum NativeReportMailTests {
    static func main()async {do{try await run()}catch{FileHandle.standardError.write(Data("Report mail: \(error)\n".utf8));exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ReportMail-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var checks=0
        func check(_ value:@autoclosure()throws->Bool,_ name:String)throws {guard try value()else{throw NativeDBError.message("FAIL report mail: "+name)};checks+=1}
        func rejects(_ name:String,_ run:()throws->Void)throws {do{try run()}catch{checks+=1;return};throw NativeDBError.message("FAIL report mail accepted: "+name)}
        func fixture()throws->ReportMailFixture {try .init(resources:resources,parent:root)}
        func clean(_ f:ReportMailFixture)throws->Bool {try !FileManager.default.fileExists(atPath:f.root.appendingPathComponent("report-staging").path) || FileManager.default.contentsOfDirectory(atPath:f.root.appendingPathComponent("report-staging").path).isEmpty}
        let longName=String(repeating:"日本語の営業レポート・長い保存名😀",count:10)
        for category in NativeReportCategory.allCases where category != .overview {
            let f=try fixture(),schedule=try f.create(category:category,format:category == .sales ? "both" : category == .accounts ? "pdf" : "csv",name:category == .sales ? longName : "月次レポート"),job=try f.job(schedule)
            let ran=try await f.worker().runNext();try check(ran,"claimed scheduled occurrence")
            let done=try f.db.job(id:job.id)!
            try check(done.status=="done" && done.result["providerID"]==f.transport.receipt,"receipt persisted and completed for "+category.rawValue)
            try check(f.transport.keys==["nextcrm/report/"+job.id],"stable report idempotency namespace")
            let json=try JSONSerialization.jsonObject(with:f.transport.bodies[0]) as! [String:Any],attachments=json["attachments"] as! [[String:String]]
            try check(json["to"] as? [String]==["one@example.invalid","two@example.invalid"],"all recipients included")
            try check(attachments.count==(category == .sales ? 2 : 1),"requested attachment count")
            try check(attachments.allSatisfy{($0["filename"] ?? "").hasPrefix(category.rawValue+"-report.")},"original category filenames")
            if category == .sales {
                let pdf=Data(base64Encoded:attachments[1]["content"]!)!,document=PDFDocument(data:pdf)!
                let plain=(document.string ?? "").components(separatedBy:.whitespacesAndNewlines).joined()
                try check(plain.contains(longName),"long saved title wraps completely in PDF")
                try check(plain.contains("該当するデータはありません。") && document.pageCount==1,"wrapped heading leaves table and empty state readable")
                let out=resources.appendingPathComponent("../artifacts/native-report-mail");try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
                try pdf.write(to:out.appendingPathComponent("定期レポート・長い表題.pdf"))
            }
            try check(try f.db.reportScheduleRecord(schedule.id)["lastSentAt"].string==ISO8601DateFormatter().string(from:f.clock.now),"lastSentAt records acceptance only")
            try check(try !FileManager.default.fileExists(atPath:InvoiceMail.bodyURL(root:f.root,id:job.id).path) && clean(f),"success removes body and staging")
            let idle=try await f.worker().runNext();try check(!idle && f.transport.bodies.count==1,"no duplicate immediate send")
        }
        // A retry keeps the exact already-authorized snapshot even if ordinary
        // source data changes. Configuration/identity changes are fenced below.
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule),worker=f.worker()
            f.transport.status=500;_ = try await worker.runNext()
            try check(try f.db.job(id:job.id)?.status=="retry" && f.db.reportScheduleRecord(schedule.id)["lastSentAt"] == .null,"failure does not acknowledge schedule")
            _ = try f.db.insert("crm_Opportunities",values:["createdBy":.text(f.service.identity.id),"created_on":.text("2026-11-19T00:00:00Z"),"status":.text("ACTIVE"),"budget":.text("0")],actor:f.service.identity.id)
            f.clock.now.addTimeInterval(6);f.transport.status=200;_ = try await worker.runNext()
            try check(f.transport.bodies.count==2 && f.transport.bodies[0]==f.transport.bodies[1] && f.transport.keys[0]==f.transport.keys[1],"retry uses frozen bytes and same id")
            try check(try f.db.job(id:job.id)?.status=="done" && f.db.reportJobs(ownerID:nil,scheduleID:schedule.id).total==2,"retry completes without duplicate successor")
            let fresh=try f.db.reportScheduleRecord(schedule.id)
            try f.db.acknowledgeReportDelivery(job,acceptedAt:f.clock.now.addingTimeInterval(-300))
            try check(try f.db.reportScheduleRecord(schedule.id).revision==fresh.revision,"older receipt cannot move lastSentAt backward")
        }
        for reason in ["inactive","banned","unshared","users-role"] {
            let f=try fixture(),owner=try f.user(reason=="users-role" ? "manager" : "user")
            let schedule:NativeReportSchedule
            if reason=="unshared" {
                let config=try NativeReportConfigurations(service:f.service).save(name:"共有",category:.sales,filters:.init(json:"{}"),shared:true)
                schedule=try NativeReportSchedules(service:owner).create(configID:config.id,settings:.init(expression:"* * * * *",recipients:["one@example.invalid"],format:"csv",timeZone:"Asia/Tokyo"),now:f.clock.now.addingTimeInterval(-60))
                _ = try NativeReportConfigurations(service:f.service).share(config,enabled:false)
            } else {
                schedule=try f.create(category:reason=="users-role" ? .users : .sales,format:"csv",service:owner)
                let user=try f.db.get("Users",key:["id":.text(owner.identity.id)])!
                _ = try f.db.update(user,changes:reason=="inactive" ? ["userStatus":.text("INACTIVE")] : reason=="banned" ? ["banned":.integer(1)] : ["role":.text("user")],actor:f.service.identity.id)
            }
            let job=try f.job(schedule);_ = try await f.worker().runNext()
            try check(try f.db.job(id:job.id)?.result["outcome"]=="skipped" && f.transport.bodies.isEmpty,"fresh owner/access check "+reason)
            try check(try f.db.reportJobs(ownerID:nil,scheduleID:schedule.id).total==2,"temporarily inaccessible owner retains next occurrence")
        }
        for reason in ["key","role","configuration","missing-body","expired"] {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule),worker=f.worker()
            f.transport.status=500;_ = try await worker.runNext();f.clock.now.addTimeInterval(6)
            switch reason {
            case "key":f.credentials = .init(from:f.credentials.from,apiKey:"changed-test-key")
            case "role":let user=try f.db.get("Users",key:["id":.text(f.service.identity.id)])!;_ = try f.db.update(user,changes:["role":.text("user")],actor:f.service.identity.id)
            case "configuration":let config=try NativeReportConfigurations(service:f.service).load(schedule.record["reportConfigId"].string);_ = try NativeReportConfigurations(service:f.service).share(config,enabled:true)
            case "missing-body":try FileManager.default.removeItem(at:InvoiceMail.bodyURL(root:f.root,id:job.id))
            default:f.clock.now.addTimeInterval(24*3600)
            }
            _ = try await worker.runNext();let held=try f.db.job(id:job.id)!
            try check(held.status=="needs_review" && held.canReviewMail && f.transport.bodies.count==1,"ambiguous retry stopped after "+reason)
            let blocked=try await worker.runNext();try check(!blocked,"review blocks successor "+reason)
        }
        do {
            let f=try fixture(),schedule=try f.create(format:"both"),job=try f.job(schedule)
            f.transport.hook={let config=try NativeReportConfigurations(service:f.service).load(schedule.record["reportConfigId"].string);try NativeReportConfigurations(service:f.service).delete(config)}
            _ = try await f.worker().runNext()
            try check(try f.db.job(id:job.id)?.status=="done" && f.db.get("crm_Report_Schedule",key:["id":.text(schedule.id)])==nil,"in-flight acceptance survives config cascade")
            try check(try f.db.nextReportJobDate(now:f.clock.now)==nil,"deleted schedule has no timer")
        }
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),original=try f.job(schedule)
            var claimed=try f.db.claimReportJob(now:f.clock.now)!;_ = try NativeReportQueue.advance(claimed,db:f.db,now:f.clock.now)
            claimed=try f.db.markJobDeliveryStarted(claimed,now:f.clock.now)
            try f.db.recordJobResult(claimed,result:["providerID":f.transport.receipt,"acceptedAt":ISO8601DateFormatter().string(from:f.clock.now),"outcome":"sent"])
            try f.db.failJob(claimed,message:"local crash",retryAt:f.clock.now)
            let current=try f.db.reportScheduleRecord(schedule.id);_ = try f.db.update(current,changes:["cronExpression":.text("broken")],actor:f.service.identity.id)
            f.clock.now.addTimeInterval(24*3600)
            _ = try await f.worker().runNext()
            try check(try f.db.job(id:original.id)?.status=="done" && f.transport.bodies.isEmpty,"stored receipt recovery bypasses broken settings and expired dedup window")
            try check(try f.db.reportScheduleRecord(schedule.id)["lastSentAt"].string==claimed.payload["occurrence"],"recovery retains original acceptance time")
        }
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule),owner=try f.user()
            f.transport.status=500;_ = try await f.worker().runNext();f.clock.now.addTimeInterval(24*3600);_ = try await f.worker().runNext()
            let review=try f.db.job(id:job.id)!
            try rejects("unrelated user review"){try owner.reviewMailJob(review,outcome:.accepted,providerID:f.transport.receipt,note:"確認",now:f.clock.now)}
            try f.service.reviewMailJob(review,outcome:.accepted,providerID:f.transport.receipt,note:"送信サービスで受付を確認",now:f.clock.now)
            try check(try f.db.job(id:job.id)?.result["reviewedBy"]==f.service.identity.id && f.db.reportScheduleRecord(schedule.id)["lastSentAt"] != .null,"accepted manual review acknowledges and audits")
            try rejects("stale review"){try f.service.reviewMailJob(review,outcome:.notSent,providerID:"",note:"確認",now:f.clock.now)}
        }
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule)
            f.transport.status=500;_ = try await f.worker().runNext();let review=try f.db.job(id:job.id)!
            try NativeReportSchedules(service:f.service).delete(schedule.record)
            try f.service.reviewMailJob(review,outcome:.unknown,providerID:"",note:"削除後も結果不明",now:f.clock.now)
            try check(try f.db.job(id:job.id)?.result["outcome"]=="unconfirmed","deleted schedule history remains reviewable")
        }
        // A stale exporter must never publish or remove a reclaimed worker's body.
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule)
            var reclaimed:NativeJob?
            let sentinel=Data("new lease body".utf8)
            let worker=f.worker(export:{snapshot,section,format,url,title in
                let rows=try NativeReportExport.write(snapshot,section:section,format:format,to:url,title:title)
                reclaimed=try f.db.claimReportJob(now:f.clock.now.addingTimeInterval(3601))
                let file=try InvoiceMail.bodyURL(root:f.root,id:job.id);try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true);try sentinel.write(to:file)
                return rows
            })
            _ = try await worker.runNext()
            try check(try reclaimed != nil && f.db.requireJobLease(reclaimed!).id==job.id,"exporter lease can be reclaimed")
            try check(try Data(contentsOf:InvoiceMail.bodyURL(root:f.root,id:job.id))==sentinel && f.transport.bodies.isEmpty,"stale exporter preserves new worker body")
            try check(try clean(f),"stale exporter removes own staging")
        }
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule)
            let worker=f.worker(export:{snapshot,section,format,url,title in
                let rows=try NativeReportExport.write(snapshot,section:section,format:format,to:url,title:title)
                try NativeReportSchedules(service:f.service).delete(schedule.record);return rows
            })
            _ = try await worker.runNext()
            try check(try f.db.job(id:job.id)?.status=="cancelled" && f.transport.bodies.isEmpty && clean(f),"delete during preparation fences send and cleans staging")
        }
        do {
            let f=try fixture(),schedule=try f.create(format:"csv"),job=try f.job(schedule),worker=f.worker()
            let cancelled=Task.detached {withUnsafeCurrentTask{$0?.cancel()};return try await worker.runNext()};_ = try await cancelled.value
            try check(try f.db.job(id:job.id)?.status=="retry" && f.transport.bodies.isEmpty,"shutdown cancellation remains retryable without sending")
        }
        do {
            let f=try fixture();f.clock.now=Date()
            let schedule=try f.create(format:"csv"),job=try f.job(schedule),worker=f.worker()
            let runner=await MainActor.run {InvoiceJobRunner(db:f.db,events:[NativeReportQueue.event],nextDate:{try f.db.nextReportJobDate(now:f.clock.now)},runNext:{try await worker.runNext()})}
            await MainActor.run {runner.kick();runner.kick()}
            let deadline=Date().addingTimeInterval(15)
            while Date()<deadline {
                if await MainActor.run(body:{!runner.isRunning && runner.nextWake != nil}) {break}
                try await Task.sleep(nanoseconds:10_000_000)
            }
            let state=await MainActor.run {()->(Bool,Date?) in let state=(runner.isRunning,runner.nextWake);runner.stop();return state}
            try check(try !state.0 && f.db.job(id:job.id)?.status=="done" && f.transport.bodies.count==1,"actual runner coalesces wake calls and delivers once")
            try check(state.1.map{$0>f.clock.now}==true,"actual runner rests until next future report occurrence")
        }
        print("{\"suite\":\"NativeReportMail\",\"checks\":\(checks)}")
    }
}
