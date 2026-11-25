import Foundation

@main enum NativeReportQueueTests {
    static func main()async {do{try await run()}catch{FileHandle.standardError.write(Data("Report queue: \(error)\n".utf8));exit(1)}}
    static func run()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ReportQueue-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),service=CRMService(db:db,identity:identity),store=NativeReportSchedules(service:service),configs=NativeReportConfigurations(service:service)
        let iso=ISO8601DateFormatter();func date(_ s:String)->Date{iso.date(from:s)!}
        let base=date("2026-11-19T00:00:00Z"),late=date("2026-12-03T00:00:00Z"),next=date("2026-12-07T00:00:00Z")
        let weekly=try NativeReportScheduleSettings(expression:"0 9 * * 1",recipients:["queue@example.invalid"],format:"both",timeZone:"Asia/Tokyo"),daily=try NativeReportScheduleSettings(expression:"0 9 * * *",recipients:["queue@example.invalid"],format:"pdf",timeZone:"Asia/Tokyo"),minute=try NativeReportScheduleSettings(expression:"* * * * *",recipients:["queue@example.invalid"],format:"csv",timeZone:"Asia/Tokyo")
        let config=try configs.save(name:"予約検証",category:.sales,filters:.init(json:"{}"),shared:false)
        var checks=0
        func check(_ value:@autoclosure()throws->Bool,_ name:String)throws {guard try value()else{throw NativeDBError.message("FAIL queue: "+name)};checks+=1}
        func rejects(_ name:String,_ run:()throws->Void)throws {do{try run()}catch{checks+=1;return};throw NativeDBError.message("FAIL queue accepted: "+name)}
        func almost(_ a:Date?,_ b:Date)->Bool{a.map{abs($0.timeIntervalSince(b))<0.01} ?? false}
        func pending(_ id:String)throws->NativeJob {let jobID=try db.reportScheduleState("job",id:id)!;return try db.job(id:jobID)!}
        let schedule=try store.create(configID:config.id,settings:weekly,now:base),initial=try pending(schedule.id)
        try check(initial.status=="pending" && initial.event==NativeReportQueue.event,"native event reserved")
        try check(initial.payload["reportName"]=="予約検証","history identifies report before preparation")
        try check(initial.payload["occurrence"]=="2026-11-23T00:00:00Z","first future wall time")
        try check(try db.claimReportJob(now:base)==nil,"not sent immediately on creation")
        try check(try almost(db.nextReportJobDate(now:base),date("2026-11-23T00:00:00Z")),"single timer targets due slot")
        let overdue=try db.claimReportJob(now:late)!
        try check(overdue.id==initial.id,"oldest missed slot resumed")
        try check(try NativeReportQueue.advance(overdue,db:db,now:late),"reserve successor once")
        try check(try !NativeReportQueue.advance(overdue,db:db,now:late),"repeat advance is idempotent")
        let successor=try pending(schedule.id)
        try check(successor.payload["occurrence"]==iso.string(from:next),"offline gap coalesced to next future occurrence")
        try check(try db.reportJobs(ownerID:identity.id,scheduleID:schedule.id).total==2,"no missed-minute backlog")
        try db.finishJob(overdue,now:late)
        try check(try almost(db.nextReportJobDate(now:late),next),"timer advances after completion")
        let other=try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try other.reportScheduleState("job",id:schedule.id)==successor.id,"reservation survives independent reopen")
        let firstLease=try other.claimReportJob(now:next)!
        try check(try db.claimReportJob(now:next)==nil,"cross-connection claim fenced")
        _ = try NativeReportQueue.advance(firstLease,db:other,now:next)
        let reclaimed=try db.claimReportJob(now:next.addingTimeInterval(301))!
        try check(reclaimed.id==firstLease.id && reclaimed.leaseToken != firstLease.leaseToken,"expired lease reclaimed before later slot")
        try rejects("old lease cannot finish"){try other.finishJob(firstLease,now:next)}
        try check(try !NativeReportQueue.advance(reclaimed,db:db,now:next.addingTimeInterval(301)),"reclaim does not add a second successor")
        try db.finishJob(reclaimed,now:next.addingTimeInterval(301))
        let oldFuture=try pending(schedule.id),changed=try store.update(store.load(schedule.id),settings:daily,isActive:true,now:next.addingTimeInterval(400)),replacement=try pending(schedule.id)
        try check(try db.job(id:oldFuture.id)?.status=="cancelled","edit cancels old future slot")
        try check(oldFuture.payload["generation"] != replacement.payload["generation"],"edit changes generation")
        try check(try NativeReportQueue.current(oldFuture,db:db)==nil,"old generation cannot send")
        let tomorrow=date("2026-12-08T00:00:00Z"),unstarted=try db.claimReportJob(now:tomorrow)!
        let body=try InvoiceMail.prepareText(root:root,id:unstarted.id,from:"from@example.invalid",to:"to@example.invalid",subject:"検証",message:"本文")
        let disabled=try store.update(changed,settings:daily,isActive:false,now:tomorrow)
        try check(try db.job(id:unstarted.id)?.status=="cancelled","disable fences running preparation before external request")
        try rejects("cancelled lease fenced"){_ = try db.requireJobLease(unstarted)}
        for _ in 0..<100 where FileManager.default.fileExists(atPath:body.url.path){try await Task.sleep(nanoseconds:10_000_000)}
        try check(!FileManager.default.fileExists(atPath:body.url.path),"cancelled prepared body removed")
        let enabled=try store.update(disabled,settings:daily,isActive:true,now:tomorrow),reserved=try pending(schedule.id)
        let retained=try InvoiceMail.prepareText(root:root,id:reserved.id,from:"from@example.invalid",to:"to@example.invalid",subject:"保持",message:"本文")
        enum Rollback:Error{case expected}
        do {try db.transaction {_ = try store.update(enabled,settings:daily,isActive:false,now:tomorrow);throw Rollback.expected}}catch Rollback.expected{}
        try await Task.sleep(nanoseconds:50_000_000)
        try check(try db.job(id:reserved.id)?.status=="pending" && FileManager.default.fileExists(atPath:retained.url.path),"outer rollback preserves reservation and body")
        try store.delete(enabled.record)
        try check(try db.reportScheduleState("generation",id:schedule.id)==nil,"delete removes scheduling state")
        try check(try db.job(id:reserved.id)?.status=="cancelled","delete cancels future slot")

        // A review hold blocks its schedule, but another schedule continues.
        let held=try store.create(configID:config.id,settings:minute,now:tomorrow),firstDue=tomorrow.addingTimeInterval(60)
        var attempted=try db.claimReportJob(now:firstDue)!
        _ = try NativeReportQueue.advance(attempted,db:db,now:firstDue)
        attempted=try db.markJobDeliveryStarted(attempted,now:firstDue)
        try db.failJob(attempted,message:"受付結果の確認待ち",needsReview:true)
        let independent=try store.create(configID:config.id,settings:minute,now:tomorrow),secondDue=firstDue.addingTimeInterval(60)
        let free=try db.claimReportJob(now:secondDue)!
        try check(free.payload["scheduleId"]==independent.id,"other schedule runs during review hold")
        _ = try NativeReportQueue.advance(free,db:db,now:secondDue);try db.finishJob(free,now:secondDue)
        try check(try db.claimReportJob(now:secondDue)==nil,"review hold blocks due successor")
        try check(try almost(db.nextReportJobDate(now:secondDue),secondDue.addingTimeInterval(60)),"timer ignores blocked due successor")
        let reviewed=try db.job(id:attempted.id)!
        try db.completeReviewedMail(reviewed,result:["outcome":"not_sent","reviewOutcome":"not_sent"],now:secondDue)
        let resumed=try db.claimReportJob(now:secondDue)!
        try check(resumed.payload["scheduleId"]==held.id,"confirmed outcome unblocks successor")
        _ = try NativeReportQueue.advance(resumed,db:db,now:secondDue)
        let inFlight=try db.markJobDeliveryStarted(resumed,now:secondDue)
        try store.delete(store.load(held.id).record)
        try check(try db.requireJobLease(inFlight).id==inFlight.id,"delete preserves in-flight receipt recovery")
        try check(try NativeReportQueue.current(inFlight,db:db)==nil,"deleted schedule cannot start another send")
        try db.finishJob(inFlight,result:["providerID":UUID().uuidString.lowercased()],now:secondDue)
        try store.delete(store.load(independent.id).record)

        let cascade=try configs.save(name:"連動削除",category:.sales,filters:.init(json:"{}"),shared:false)
        let x=try store.create(configID:cascade.id,settings:daily,now:tomorrow),y=try store.create(configID:cascade.id,settings:daily,now:tomorrow),xJob=try pending(x.id),yJob=try pending(y.id)
        try configs.delete(cascade)
        try check(try db.job(id:xJob.id)?.status=="cancelled" && db.job(id:yJob.id)?.status=="cancelled","config cascade cancels dependent reservations")
        try check(try db.reportScheduleState("generation",id:x.id)==nil && db.reportScheduleState("timezone",id:y.id)==nil,"config cascade cleans metadata")
        var rolledID=""
        do{try db.transaction {rolledID=try store.create(configID:config.id,settings:daily,now:tomorrow).id;throw Rollback.expected}}catch Rollback.expected{}
        try check(try db.get("crm_Report_Schedule",key:["id":.text(rolledID)])==nil && db.reportJobs(ownerID:nil,scheduleID:rolledID).total==0,"create rollback leaves no schedule/job")
        try check(try db.reportScheduleState("generation",id:rolledID)==nil,"create rollback leaves no generation")
        let legacy=try db.insert("crm_Report_Schedule",values:["reportConfigId":.text(config.id),"createdBy":.text(identity.id),"cronExpression":.text("0 9 * * *"),"recipients":.text("[\"x@example.invalid\"]"),"format":.text("csv")],actor:identity.id),generation=UUID().uuidString.lowercased()
        try db.setMetadata("reportSchedule.generation."+legacy["id"].string,value:generation)
        let invalidID=try db.enqueue(NativeReportQueue.event,payload:["scheduleId":legacy["id"].string,"configId":config.id,"ownerId":identity.id,"generation":generation,"occurrence":iso.string(from:tomorrow)],now:tomorrow)
        try rejects("unconfirmed migration timezone cannot schedule delivery"){_ = try NativeReportQueue.current(db.job(id:invalidID)!,db:db)}
        try db.cancelJob(id:invalidID)
        try check(try db.reportJobs(ownerID:"unrelated-user").total==0,"history owner scope")
        try check(try db.nextReportJobDate(now:tomorrow)==nil,"idle queue needs no polling timer")
        let oneOff=try store.create(configID:config.id,settings:daily,now:tomorrow),first=try pending(oneOff.id)
        try store.cancel(first.id,now:tomorrow)
        let afterCancel=try pending(oneOff.id)
        try check(try db.job(id:first.id)?.status=="cancelled" && afterCancel.id != first.id,"cancelling one occurrence preserves recurrence")
        try check(afterCancel.payload["occurrence"]=="2026-12-10T00:00:00Z","one-off cancel skips exactly its calendar occurrence")
        try store.delete(store.load(oneOff.id).record)
        let publicConfig=try configs.save(name:"共有中の名前",category:.sales,filters:.init(json:"{}"),shared:true)
        var owner=try db.insert("Users",values:["name":.text("共有の利用者"),"email":.text("shared-reader@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let reader=CRMService(db:db,identity:.init(id:owner["id"].string,role:"user",partnerAccountID:nil)),owned=try NativeReportSchedules(service:reader).create(configID:publicConfig.id,settings:daily,now:tomorrow)
        try check(try pending(owned.id).payload["reportName"]=="共有中の名前","authorized shared report title recorded")
        let privateConfig=try db.update(publicConfig.record,changes:["name":.text("解除後の非公開の名前"),"isShared":.integer(0)],actor:identity.id)
        let firstPrivate=try db.claimReportJob(now:date("2026-12-09T00:00:00Z"))!
        _ = try NativeReportQueue.advance(firstPrivate,db:db,now:date("2026-12-09T00:00:00Z"));try db.finishJob(firstPrivate)
        try check(try pending(owned.id).payload["reportName"]=="レポート","reservation never discloses renamed private config")
        _ = try db.update(privateConfig,changes:["name":.text("休止中に変更した名前"),"isShared":.integer(1)],actor:identity.id)
        owner=try db.update(owner,changes:["userStatus":.text("INACTIVE")],actor:identity.id)
        let inactive=try db.claimReportJob(now:date("2026-12-10T00:00:00Z"))!
        _ = try NativeReportQueue.advance(inactive,db:db,now:date("2026-12-10T00:00:00Z"))
        try check(try pending(owned.id).payload["reportName"]=="レポート","inactive owner cannot receive updated display metadata")
        try store.delete(store.load(owned.id).record)
        let bodyChecks=try NativeReportMailBodyTests.run(root:root);checks+=bodyChecks
        let cancelledID=UUID().uuidString.lowercased()
        let cancelled=Task.detached {
            withUnsafeCurrentTask{$0?.cancel()}
            return try NativeReportMailBody.prepare(root:root,id:cancelledID,from:"from@example.invalid",to:["one@example.invalid"],subject:"中止",message:"本文",attachments:[.init(filename:"売上.csv",url:root.appendingPathComponent("添付.csv"))])
        }
        do{_ = try await cancelled.value;throw NativeDBError.message("FAIL body cancellation ignored")}catch is CancellationError{checks+=1}
        try check(try !FileManager.default.fileExists(atPath:InvoiceMail.bodyURL(root:root,id:cancelledID).path),"cancel removes staging body")
        print("{\"suite\":\"NativeReportMailBody\",\"checks\":\(bodyChecks+2)}")
        print("{\"suite\":\"NativeReportQueue\",\"checks\":\(checks)}")
    }
}
