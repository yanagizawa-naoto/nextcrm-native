import Foundation

final class FakeMailReceiver: NativeMailReceiving {
    var validity: UInt32 = 77
    var messages:[String:[UInt32]] = ["INBOX":Array(1...120),"送信済み":[1,2]]
    var searches:[(String,UInt32,UInt32,Date?)] = [], batches:[(String,[UInt32])] = []
    var failAt: Int?, failure: Error = NativeMailFailure.transport(code:28,uploaded:false)
    var afterHeaders: ((String,[UInt32]) throws -> Void)?
    var bodyCalls = 0
    var bodyResult: NativeMailBody? = .init(text:"本文"), bodyError: Error?
    var afterBody: (() throws -> Void)?
    func status(mailbox: String) async throws -> (validity:UInt32,next:UInt32) { (validity,(messages[mailbox]?.max() ?? 0)+1) }
    func discover(mailbox: String,validity: UInt32,after: UInt32,through: UInt32,since: Date?) async throws -> NativeMailUIDSpool {
        guard validity == self.validity else { throw NativeMailFailure.mailboxChanged }
        searches.append((mailbox,after,through,since))
        let uids = (messages[mailbox] ?? []).filter{$0 > after && $0 <= through}.reversed().map(String.init).joined(separator:" ")
        let file = try NativeMailResponseFile()
        try file.withDescriptor { fd in try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:Data(("* SEARCH "+uids+"\r\nNCRM2 OK searched\r\n").utf8)) }
        return try NativeMailUIDSpool(response:file,after:after,through:through)
    }
    func headers(mailbox: String,validity: UInt32,uids: [UInt32]) async throws -> [NativeMailIMAPHeader] {
        guard validity == self.validity else { throw NativeMailFailure.mailboxChanged }
        batches.append((mailbox,uids)); if batches.count == failAt { throw failure }
        let result = try uids.map { uid in
            NativeMailIMAPHeader(uid:uid,seen:false,headers:try NativeMailMIME.headers(Data("Message-ID: <\(mailbox == "INBOX" ? "in" : "sent")-\(uid)@fixture.test>\r\nSubject: 日本語 \(uid)\r\nFrom: customer@example.test\r\nTo: owner@example.test\r\n\r\n".utf8)))
        }
        try afterHeaders?(mailbox,uids); return result
    }
    func body(mailbox: String,validity: UInt32,uid: UInt32) async throws -> NativeMailBody? {
        bodyCalls += 1; guard validity == self.validity else { throw NativeMailFailure.mailboxChanged }
        if let bodyError { throw bodyError }; try afterBody?(); return bodyResult
    }
}

final class MailSyncFixture {
    let root: URL, db: NativeDatabase, second: NativeDatabase, owner: NativeRecord, stranger: NativeRecord
    let service: CRMService, secrets = FakeNativeMailSecrets(), receiver = FakeMailReceiver()
    var now = Date(timeIntervalSince1970:1_700_000_000)
    var accountID = ""
    let resources: URL
    init(resources: URL) throws {
        self.resources = resources
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailSyncTests-"+UUID().uuidString)
        db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        second = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        owner = try db.insert("Users",values:["name":.text("所有者"),"email":.text("owner@example.test"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"test")
        stranger = try db.insert("Users",values:["name":.text("別の管理者"),"email":.text("admin@example.test"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"test")
        service = CRMService(db:db,identity:.init(id:owner["id"].string,role:"user",partnerAccountID:nil))
        let settings = NativeMailAccountSettings(label:"仕事",username:"owner@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS),sentFolder:"送信済み")
        accountID = try service.createMailAccount(settings,password:"synthetic-only",store:secrets)["id"].string
    }
    deinit { try? FileManager.default.removeItem(at:root) }
    func account() throws -> NativeRecord { try service.mailAccount(accountID) }
    func start() throws -> String { try service.requestMailSync(account(),now:now) }
    func worker(secondConnection: Bool = false) -> NativeMailSyncWorker {
        NativeMailSyncWorker(db:secondConnection ? second : db,store:secrets,makeClient:{ [unowned self] _,_ in self.receiver },clock:{ [unowned self] in self.now })
    }
    func cursor(_ folder: NativeMailFolder = .inbox) throws -> NativeMailSyncCursor? {
        try db.metadata(NativeMailJobs.cursor(accountID,folder)).map { try JSONDecoder().decode(NativeMailSyncCursor.self,from:Data($0.utf8)) }
    }
    func rows() throws -> Int { try db.page("Email",fields:[]).total }
    func linkJobs() throws -> Int {
        var count = 0
        while true { let page = try db.jobs(events:[NativeMailJobs.link],offset:count); count += page.count; if page.count < 100 { return count } }
    }
}

enum NativeMailSyncTests {
    static func run(resources: URL) async throws -> Int {
        var count = 0
        func check(_ value: Bool,_ name: String) throws {
            guard value else { throw NativeDBError.message("NativeMailSyncTests: "+name) }; count += 1
        }
        do {
            let f = try MailSyncFixture(resources:resources), id = try f.start()
            try check(try f.start() == id,"duplicate manual sync coalesces")
            try check(try await f.worker().runNext(),"claims durable sync")
            try check(try f.db.job(id:id)?.status == "done" && f.rows() == 122,"inbox and sent headers persist")
            try check(f.receiver.batches.allSatisfy{$0.1.count <= 50} && f.receiver.bodyCalls == 0,"header-only bounded batches")
            try check(try f.linkJobs() == 122,"one durable CRM-link job per new message")
            try check(f.receiver.searches.allSatisfy{$0.3 == f.now.addingTimeInterval(-180*86400)},"initial range is 180 days")
            try check(try f.cursor()?.uid == 120 && f.cursor()?.initialSince == nil && f.cursor(.sent)?.uid == 2,"both cursors committed")
            try check(try f.account()["lastSyncedAt"] != .null && f.account()["inboxLastUid"] == .integer(120),"original account watermark updated after success")
            f.receiver.messages["INBOX"]! += [121,122]; f.now.addTimeInterval(900)
            let second = try f.start(); _ = try await f.worker(secondConnection:true).runNext()
            try check(try f.db.job(id:second)?.status == "done" && f.rows() == 124 && f.linkJobs() == 124,"incremental sync without duplicate imports or followups")
            try check(f.receiver.searches.last?.1 == 120 && f.receiver.searches.last?.3 == nil,"incremental range starts at saved UID")
            let calls = f.receiver.batches.count; _ = try f.start(); _ = try await f.worker().runNext()
            try check(f.receiver.batches.count == calls,"unchanged mailbox performs no header/body fetch")
            let admin = CRMService(db:f.db,identity:.init(id:f.stranger["id"].string,role:"admin",partnerAccountID:nil))
            do { _ = try admin.requestMailSync(f.account()); throw NativeMailFailure.malformed }
            catch let error as NativeDBError { try check(error.localizedDescription.contains("メールアカウント"),"other administrator cannot sync private account") }
            try f.service.deleteMailAccount(f.account(),store:f.secrets)
            try check(try f.db.metadata(NativeMailJobs.cursor(f.accountID,.inbox)) == nil && f.db.metadata(NativeMailJobs.syncPointer(f.accountID)) == nil,"account deletion removes sync state")
        }
        do {
            let f = try MailSyncFixture(resources:resources); f.receiver.failAt = 2
            let id = try f.start(); _ = try await f.worker().runNext()
            try check(try f.db.job(id:id)?.status == "retry" && f.rows() == 50 && f.linkJobs() == 50,"failed second page retains atomic first-page import and jobs")
            let firstSince = try f.cursor()?.initialSince
            try check(try f.cursor()?.uid == 50 && f.account()["lastSyncedAt"] == .null,"partial cursor saved without publishing success")
            f.receiver.failAt = nil; f.now.addTimeInterval(6)
            _ = try await f.worker(secondConnection:true).runNext()
            try check(try f.rows() == 122 && f.linkJobs() == 122 && f.db.job(id:id)?.status == "done","new worker/database connection resumes saved progress")
            try check(f.receiver.searches[1].1 == 50 && f.receiver.searches[1].3 == firstSince,"retry keeps initial cutoff and starts after committed page")
        }
        do {
            let f = try MailSyncFixture(resources:resources); f.receiver.failAt = 2
            let id = try f.start(); _ = try await f.worker().runNext()
            f.receiver.validity = 78; f.receiver.failAt = nil; f.now.addTimeInterval(6)
            _ = try await f.worker(secondConnection:true).runNext()
            try check(f.receiver.searches[1].1 == 0,"UIDVALIDITY change resets discovery")
            try check(try f.cursor()?.validity == 78 && f.rows() == 122 && f.linkJobs() == 122 && f.db.job(id:id)?.status == "done","generation reset deduplicates RFC IDs")
            let first = try f.service.mailMessages(accountID:f.accountID,folder:.inbox).rows[0]
            try check(try f.service.mailLocation(f.service.mailMessage(first["id"].string))?.uidValidity == 78,"replayed locations use new generation")
        }
        do {
            let f = try MailSyncFixture(resources:resources), id = try f.start()
            f.receiver.afterHeaders = { _,_ in
                f.receiver.afterHeaders = nil
                let user = try f.second.get("Users",key:["id":f.owner["id"]])!
                _ = try f.second.update(user,changes:["userStatus":.text("INACTIVE")],actor:"test")
            }
            _ = try await f.worker().runNext()
            try check(try f.rows() == 0 && f.linkJobs() == 0 && f.cursor()?.uid == 0,"permission revoked during fetch prevents publication")
            try check(try f.db.job(id:id)?.status == "failed","revoked actor stops sync")
        }
        do {
            let f = try MailSyncFixture(resources:resources), id = try f.start()
            f.receiver.afterHeaders = { _,_ in
                f.receiver.afterHeaders = nil
                _ = try f.service.replaceMailPassword(f.account(),password:"synthetic-new",store:f.secrets)
            }
            _ = try await f.worker().runNext()
            try check(try f.rows() == 0 && f.db.job(id:id)?.status == "retry","credential rotation fences old request result")
            f.now.addTimeInterval(6); _ = try await f.worker().runNext()
            try check(try f.rows() == 122 && f.db.job(id:id)?.status == "done","retry uses current account and credential snapshot")
        }
        do {
            let f = try MailSyncFixture(resources:resources), id = try f.start(); var stolen: NativeJob?
            f.receiver.afterHeaders = { _,_ in f.receiver.afterHeaders = nil; stolen = try f.second.claimJob(events:[NativeMailJobs.sync],now:f.now.addingTimeInterval(301)) }
            _ = try await f.worker().runNext()
            try check(try f.rows() == 0 && f.cursor()?.uid == 0,"stolen lease prevents mail and checkpoint writes")
            try check(try stolen != nil && f.db.job(id:id)?.leaseToken == stolen?.leaseToken && f.db.job(id:id)?.status == "running","old worker cannot fail successor's lease")
        }
        do {
            let f = try MailSyncFixture(resources:resources), id = try f.start()
            f.receiver.afterHeaders = { _,_ in f.receiver.afterHeaders = nil; _ = try f.start() }
            _ = try await f.worker().runNext()
            let following = try f.service.mailSyncJob(f.accountID)!
            try check(following.id != id && following.status == "pending","request during running sync survives completion")
            _ = try await f.worker().runNext()
            try check(try f.linkJobs() == 122 && f.db.job(id:following.id)?.status == "done","coalesced followup completes without duplicate links")
        }
        do {
            let f = try MailSyncFixture(resources:resources), id = try f.start()
            _ = try f.service.setMailAccountActive(f.account(),active:false)
            _ = try await f.worker().runNext()
            try check(try f.db.job(id:id)?.result["skipped"] == "inactive" && f.receiver.searches.isEmpty,"inactive account makes no remote requests")
        }
        do {
            let f = try MailSyncFixture(resources:resources); f.receiver.failAt = 1; f.receiver.failure = NativeMailFailure.transport(code:67,uploaded:false)
            let id = try f.start(); _ = try await f.worker().runNext()
            try check(try f.db.job(id:id)?.status == "failed" && f.rows() == 0,"authentication failure does not retry automatically")
            try check(try f.db.metadata(NativeMailJobs.error(f.accountID))?.contains("パスワード") == true,"sanitized Japanese sync error persists")
        }
        print("NativeMailSyncTests: \(count) checks passed; bounded sync, restart, atomic checkpoints, owner/credential/lease fences")
        return count
    }
}
