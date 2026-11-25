import Foundation

@main enum InvoiceCancelCleanupTests {
    enum Failure:Error {case rollback}
    static var checks=0
    static let now=Date(timeIntervalSince1970:1_800_000_000)
    static func check(_ value:@autoclosure ()throws->Bool,_ label:String)throws{guard try value()else{throw NativeDBError.message("FAIL "+label)};checks+=1}
    struct Fixture {
        let service:CRMService,invoice:NativeRecord,root:URL
        var db:NativeDatabase{service.db}
        func queue()throws->(String,URL,Data){
            let row=try db.get("Invoices",key:["id":invoice["id"]])!
            let id=try service.queueInvoiceEmail(row,from:"sender@example.invalid",to:"recipient@example.invalid",subject:"取消と本文の整合性",message:"再試行に必要な合成本文",now:now)
            let file=try InvoiceMail.bodyURL(root:root,id:id);return(id,file,try Data(contentsOf:file))
        }
    }
    static func fixture(_ resources:URL,_ root:URL)throws->Fixture {
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let actor="bf300000-0000-4000-8000-000000000001"
        _=try db.insert("Users",values:["id":.text(actor),"name":.text("合成管理者"),"email":.text("fixture@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:actor)
        _=try db.insert("Currency",values:["code":.text("JPY"),"name":.text("日本円"),"symbol":.text("¥")],actor:actor)
        let account=try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("合成企業"),"createdBy":.text(actor)],actor:actor)
        let key="invoice-pdfs/"+UUID().uuidString.lowercased()+".pdf",pdf=root.appendingPathComponent(key)
        try FileManager.default.createDirectory(at:pdf.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("%PDF-synthetic fixture bytes; no actual document\n".utf8).write(to:pdf)
        let invoice=try db.insert("Invoices",values:["createdBy":.text(actor),"accountId":account["id"],"currency":.text("JPY"),"status":.text("ISSUED"),"number":.text("FIXTURE-1"),"pdfStorageKey":.text(key)],actor:actor)
        return .init(service:.init(db:db,identity:.init(id:actor,role:"admin",partnerAccountID:nil)),invoice:invoice,root:root)
    }
    static func makeRetry(_ id:String,_ fixture:Fixture)throws {
        let job=try fixture.db.claimJob(events:CRMService.invoiceJobEvents,now:now)!
        try check(job.id==id,"fixture exact job claim")
        try fixture.db.failJob(job,message:"synthetic retry",retryAt:now)
    }
    static func rollback(_ id:String,_ f:Fixture)throws {
        do{try f.db.transaction{try f.service.cancelInvoiceJob(id);throw Failure.rollback}}catch Failure.rollback{return}
        throw NativeDBError.message("rollback fixture did not roll back")
    }
    static func main()async {
        do{
            let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2])
            for retry in [false,true] {
                let f=try fixture(resources,root.appendingPathComponent(retry ? "retry":"pending")),(id,file,bytes)=try f.queue()
                if retry{try makeRetry(id,f)}
                let before=try f.db.job(id:id)!
                try rollback(id,f)
                try check(try f.db.job(id:id)==before,"outer rollback restores exact job row")
                let present=FileManager.default.fileExists(atPath:file.path)
                do {
                    try check(present && (try Data(contentsOf:file))==bytes,"rollback retains exact immutable bytes")
                    if retry {
                        var calls=0
                        let worker=InvoiceJobWorker(db:f.db,apiKey:{"synthetic-key"},request:{request,url in
                            calls+=1;try check(try Data(contentsOf:url)==bytes,"retried send reads original bytes")
                            return(Data("{\"id\":\"bf300000-0000-4000-8000-000000000099\"}".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
                        },clock:{now})
                        _=try await worker.runNext()
                        try check(calls==1 && (try f.db.job(id:id))?.status=="done","rollback preserved actually retryable send")
                        try check(!FileManager.default.fileExists(atPath:file.path),"normal success keeps existing cleanup")
                    }
                }
            }
            try transactionCases(resources,root)
            print("{\"checks\":\(checks),\"externalRequests\":0,\"exit\":0}")
        }catch{fputs("Invoice cancellation cleanup after \(checks): \(error)\n",stderr);exit(1)}
    }
    static func transactionCases(_ resources:URL,_ root:URL)throws {
        let f=try fixture(resources,root.appendingPathComponent("boundaries"))
        let (committed,file,bytes)=try f.queue()
        let sibling=f.root.appendingPathComponent("mail-outbox/unfinished-fixture.json");let untouched=Data("synthetic unfinished fixture".utf8);try untouched.write(to:sibling)
        try f.db.transaction {
            try f.service.cancelInvoiceJob(committed)
            try check(try f.db.job(id:committed)?.status=="cancelled","cancellation visible inside transaction")
            try check(try Data(contentsOf:file)==bytes,"body waits for outer commit")
        }
        try check(!FileManager.default.fileExists(atPath:file.path),"committed cancellation removes its body")
        try check(try Data(contentsOf:sibling)==untouched,"unrelated unfinished fixture untouched")
        let (nested,nestedFile,nestedBytes)=try f.queue()
        try f.db.transaction {
            do{try f.db.transaction{try f.service.cancelInvoiceJob(nested);throw Failure.rollback}}catch Failure.rollback{}
            try check(try f.db.job(id:nested)?.status=="pending","inner rollback restores queued state")
        }
        try check(try Data(contentsOf:nestedFile)==nestedBytes,"outer commit does not execute rolled-back nested cleanup")
        try f.service.cancelInvoiceJob(nested)
        try check(!FileManager.default.fileExists(atPath:nestedFile.path),"standalone cancellation still cleans immediately after commit")
        let (running,runningFile,runningBytes)=try f.queue()
        let claimed=try f.db.claimJob(events:CRMService.invoiceJobEvents,now:now)!
        try check(claimed.id==running,"fixture claims running job")
        do{try f.service.cancelInvoiceJob(running);throw NativeDBError.message("running cancellation accepted")}catch{try check(try f.db.job(id:running)?.status=="running","running cancellation refused")}
        try check(try Data(contentsOf:runningFile)==runningBytes,"live worker body preserved")
        let started=try f.db.markJobDeliveryStarted(claimed,now:now)
        try f.db.failJob(started,message:"unknown",retryAt:now)
        do{try f.service.cancelInvoiceJob(running);throw NativeDBError.message("uncertain cancellation accepted")}catch{try check(try f.db.job(id:running)?.status=="retry","started retry cancellation refused")}
        try check(try Data(contentsOf:runningFile)==runningBytes,"delivery-uncertain retry body preserved")
        let (failed,failedFile,_)=try f.queue()
        let job=try f.db.claimJob(events:CRMService.invoiceJobEvents,now:now)!
        // The uncertain retry can be claimed first; retire only its own lease
        // in this synthetic fixture, never delete its payload.
        if job.id==running {try f.db.failJob(job,message:"fixture unresolved",needsReview:true)}
        let failedJob=job.id==failed ? job:try f.db.claimJob(events:CRMService.invoiceJobEvents,now:now)!
        try check(failedJob.id==failed,"fixture exact failure lease")
        try f.db.failJob(failedJob,message:"not sent")
        try f.service.cancelInvoiceJob(failed)
        try check(!FileManager.default.fileExists(atPath:failedFile.path),"unstarted failed job cleanup maintained")
        let pdfID=try f.db.enqueue("invoice.pdf_requested",payload:["invoiceId":f.invoice["id"].string,"actorId":f.service.identity.id],now:now)
        let pdfSibling=try InvoiceMail.bodyURL(root:f.root,id:pdfID);try untouched.write(to:pdfSibling)
        try f.service.cancelInvoiceJob(pdfID)
        try check(try Data(contentsOf:pdfSibling)==untouched,"PDF event cannot delete a mail-body-shaped sibling")
    }
}
