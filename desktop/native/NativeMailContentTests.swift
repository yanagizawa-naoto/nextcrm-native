import Foundation

enum NativeMailContentTests {
    static func run(resources: URL) async throws -> Int {
        var checks = 0
        func check(_ condition: Bool,_ name: String) throws { guard condition else { throw NativeDBError.message("NativeMailContentTests: "+name) }; checks += 1 }
        func message(_ f:MailSyncFixture,linked:Bool = false) throws -> NativeRecord {
            if linked { _ = try f.db.insert("crm_Contacts",values:["first_name":.text("顧客"),"last_name":.text("担当"),"email":.text("customer@example.test"),"assigned_to":f.owner["id"],"createdBy":f.owner["id"]],actor:f.owner["id"].string) }
            let header = NativeMailIMAPHeader(uid:1,seen:false,headers:try NativeMailMIME.headers(Data("Message-ID: <content@fixture.test>\r\nSubject: ご連絡\r\nFrom: customer@example.test\r\nTo: owner@example.test\r\n\r\n".utf8)))
            let id = try f.service.importMailHeaders(account:f.account(),folder:.inbox,uidValidity:77,headers:[header])[0]
            return try f.service.mailMessage(id)
        }
        func link(_ f:MailSyncFixture,_ row:NativeRecord) throws -> String { try f.db.enqueue(NativeMailJobs.link,payload:["actorID":f.owner["id"].string,"accountID":f.accountID,"emailID":row["id"].string],now:f.now) }
        func worker(_ f:MailSyncFixture,second:Bool = false) -> NativeMailContentWorker { NativeMailContentWorker(db:second ? f.second : f.db,store:f.secrets,makeClient:{_,_ in f.receiver},clock:{f.now}) }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f), id = try link(f,row)
            _ = try await worker(f).runNext()
            try check(try f.db.job(id:id)?.status == "done" && f.receiver.bodyCalls == 0 && f.db.jobs(events:[NativeMailJobs.body,NativeMailJobs.embed]).isEmpty,"unrelated mail stays header-only")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f,linked:true); _ = try link(f,row)
            _ = try await worker(f).runNext(); let body = try f.service.mailBodyJob(row["id"].string)!
            try check(try body.status == "pending" && f.db.jobs(events:[NativeMailJobs.embed]).isEmpty,"linked message queues body before embedding")
            _ = try await worker(f,second:true).runNext()
            let loaded = try f.service.mailMessage(row["id"].string)
            try check(loaded["bodyText"] == .text("本文") && loaded["isRead"] == .integer(0),"background fetch saves Japanese body without marking read")
            try check(try f.db.jobs(events:[NativeMailJobs.embed]).count == 1,"body and embedding handoff committed together")
            _ = try link(f,loaded); _ = try await worker(f).runNext()
            try check(try f.receiver.bodyCalls == 1 && f.db.jobs(events:[NativeMailJobs.embed]).count == 1,"link replay neither refetches body nor duplicates embedding hash")
            try f.service.deleteMailAccount(f.account(),store:f.secrets)
            try check(try f.db.metadata(NativeMailJobs.bodyPointer(row["id"].string)) == nil && f.db.metadata(NativeMailJobs.embedHash(row["id"].string)) == nil,"account cascade cleans content metadata")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f)
            let id = try f.service.requestMailBody(row)!
            try check(try f.service.requestMailBody(row) == id,"foreground requests coalesce")
            f.receiver.afterBody = { _ = try f.service.markMailRead(row); f.receiver.afterBody = nil }
            _ = try await worker(f).runNext(); let loaded = try f.service.mailMessage(row["id"].string)
            try check(loaded["bodyText"] == .text("本文") && loaded["isRead"] == .integer(1),"concurrent read change preserved while body saves")
            try check(try f.db.jobs(events:[NativeMailJobs.embed]).isEmpty,"opening unrelated email never queues AI work")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); let id = try f.service.requestMailBody(row)!
            f.receiver.bodyResult = NativeMailBody(); _ = try await worker(f).runNext()
            try check(try f.db.job(id:id)?.status == "done" && f.service.requestMailBody(f.service.mailMessage(row["id"].string)) == nil,"empty body is loaded exactly once")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); _ = try f.service.requestMailBody(row)
            f.receiver.bodyResult = nil; _ = try await worker(f).runNext()
            try check(try !f.service.mailBodyIsLoaded(f.service.mailMessage(row["id"].string)) && f.service.requestMailBody(row) == nil,"expunged message is absent, not an empty cached body")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); let id = try f.service.requestMailBody(row)!
            f.receiver.afterBody = { try f.service.deleteMailMessage(row); f.receiver.afterBody = nil }
            _ = try await worker(f).runNext()
            try check(try f.service.mailMessage(row["id"].string,includeDeleted:true)["bodyText"] == .null && f.db.job(id:id)?.status == "failed","deletion during fetch prevents body publication")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); let id = try f.service.requestMailBody(row)!
            f.receiver.afterBody = { _ = try f.service.replaceMailPassword(f.account(),password:"synthetic-new",store:f.secrets); f.receiver.afterBody = nil }
            _ = try await worker(f).runNext()
            try check(try f.service.mailMessage(row["id"].string)["bodyText"] == .null && f.db.job(id:id)?.status == "retry","credential change fences body result")
            f.now.addTimeInterval(6); _ = try await worker(f,second:true).runNext()
            try check(try f.service.mailMessage(row["id"].string)["bodyText"] == .text("本文"),"body retry resumes using new credentials")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); let id = try f.service.requestMailBody(row)!
            _ = try f.db.update(f.account(),changes:["imapHost":.text("other.example.test")],actor:"test")
            _ = try await worker(f).runNext()
            try check(try f.receiver.bodyCalls == 0 && f.db.job(id:id)?.status == "retry" && f.service.mailSyncJob(f.accountID) != nil,"changed server forces relocation even with same UIDVALIDITY")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); _ = try f.service.requestMailBody(row)
            f.receiver.validity = 78; _ = try await worker(f).runNext()
            try check(try f.service.mailSyncJob(f.accountID) != nil && f.service.mailMessage(row["id"].string)["bodyText"] == .null,"changed mailbox generation requests header resync")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f,linked:true); _ = try link(f,row); _ = try await worker(f).runNext()
            f.receiver.bodyError = NativeMailFailure.transport(code:28,uploaded:false); _ = try await worker(f).runNext()
            try check(try f.db.jobs(events:[NativeMailJobs.embed]).count == 1,"body failure preserves subject-only embedding handoff")
            f.receiver.bodyError = nil; f.now.addTimeInterval(6); _ = try await worker(f).runNext()
            try check(try f.db.jobs(events:[NativeMailJobs.embed]).count == 2,"successful retry queues changed full-body content hash")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f); let id = try f.service.requestMailBody(row)!
            var replacement: NativeJob?
            f.receiver.afterBody = { replacement = try f.second.claimJob(events:[NativeMailJobs.body],now:f.now.addingTimeInterval(301)); f.receiver.afterBody = nil }
            _ = try await worker(f).runNext()
            try check(try f.service.mailMessage(row["id"].string)["bodyText"] == .null && f.db.job(id:id)?.leaseToken == replacement?.leaseToken,"old body worker cannot publish after lease takeover")
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f,linked:true); _ = try link(f,row); _ = try await worker(f).runNext()
            let body = try f.service.mailBodyJob(row["id"].string)!
            let links = try f.db.page("EmailsToContacts",fields:[],equal:["emailId":row["id"]]).rows
            for item in links { try f.db.remove(item,actor:"test") }
            _ = try await worker(f).runNext()
            try check(try f.receiver.bodyCalls == 0 && f.db.job(id:body.id)?.result["skipped"] == "unlinked","background request rechecks current CRM relevance")
            _ = try f.service.requestMailBody(row); _ = try await worker(f).runNext()
            try check(f.receiver.bodyCalls == 1,"foreground opening can fetch formerly linked mail")
        }
        for mode in ["foreground","background","promoted"] {
            let f = try MailSyncFixture(resources:resources), row = try message(f,linked:true)
            _ = try f.service.linkMailToCRM(row)
            var id:String?
            if mode != "foreground" { id = try f.service.requestMailBody(row,background:true,now:f.now) }
            _ = try f.service.setMailAccountActive(f.account(),active:false)
            if mode != "background" { id = try f.service.requestMailBody(row,now:f.now) }
            _ = try await worker(f).runNext()
            if mode == "background" { try check(try f.receiver.bodyCalls == 0 && f.service.mailMessage(row["id"].string)["bodyText"] == .null,"paused account blocks a queued background body request") }
            else { try check(try f.receiver.bodyCalls == 1 && f.db.job(id:id!)?.status == "done" && f.service.mailMessage(row["id"].string)["bodyText"] == .text("本文"),"paused account permits explicit body retrieval: "+mode) }
        }
        do {
            let f = try MailSyncFixture(resources:resources), row = try message(f)
            _ = try f.service.setMailAccountActive(f.account(),active:false)
            let id = try f.service.requestMailBody(row)!
            f.receiver.afterBody = { _ = try f.service.replaceMailPassword(f.account(),password:"rotated",store:f.secrets); f.receiver.afterBody = nil }
            _ = try await worker(f).runNext()
            try check(try f.db.job(id:id)?.status == "retry" && f.service.mailMessage(row["id"].string)["bodyText"] == .null,"foreground exception preserves credential revision fencing")
        }
        print("NativeMailContentTests: \(checks) checks passed; lazy/background body, CRM relevance, immutable locations, handoff and recovery")
        return checks
    }
}
