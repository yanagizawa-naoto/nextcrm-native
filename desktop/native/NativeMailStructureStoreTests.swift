import Foundation

final class FakeNativeMailSecrets:NativeMailSecretStore {
    var values:[String:Data]=[:]
    func load(id:String,interactive:Bool)throws->Data?{values[id]}
    func save(id:String,data:Data)throws{guard values[id]==nil else{throw NativeDBError.conflict};values[id]=data}
    func remove(id:String)throws{values.removeValue(forKey:id)}
}

final class FileMailReceiver:NativeMailReceiving {
    let base:FakeMailReceiver,temp:URL
    var afterBatch:(()throws->Void)?,afterBody:(()throws->Void)?
    var corruptUID:UInt32?,cancelBatch=false,subjectBytes=20,rawBody="Content-Type: text/plain\r\n\r\n本文",fileCalls=0,arrayCalls=0
    init(base:FakeMailReceiver,temp:URL){self.base=base;self.temp=temp}
    func status(mailbox:String)async throws->(validity:UInt32,next:UInt32){try await base.status(mailbox:mailbox)}
    func discover(mailbox:String,validity:UInt32,after:UInt32,through:UInt32,since:Date?)async throws->NativeMailUIDSpool{try await base.discover(mailbox:mailbox,validity:validity,after:after,through:through,since:since)}
    func headers(mailbox:String,validity:UInt32,uids:[UInt32])async throws->[NativeMailIMAPHeader]{arrayCalls += 1;throw NativeMailFailure.invalid("Array header route must not be used")}
    func headerBatch(mailbox:String,validity:UInt32,uids:[UInt32])async throws->NativeMailHeaderBatch {
        fileCalls += 1;let file=try NativeMailResponseFile(temporaryRoot:temp)
        try file.withDescriptor { fd in
            let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:false)
            for uid in uids.reversed() {
                let header=uid==corruptUID ? "Malformed header\r\n\r\n":"Message-ID: <\(mailbox)-\(uid)@fixture.test>\r\nSubject: "+String(repeating:"s",count:subjectBytes)+"\r\nFrom: customer@example.test\r\nTo: owner@example.test\r\n\r\n"
                try handle.write(contentsOf:Data("* 1 FETCH (UID \(uid) BODY[HEADER] {\(header.utf8.count)}\r\n".utf8));try handle.write(contentsOf:Data(header.utf8));try handle.write(contentsOf:Data(")\r\n".utf8))
            }
        }
        try afterBatch?();if cancelBatch{withUnsafeCurrentTask{$0?.cancel()}}
        return .file(.init(file:file),expected:Set(uids))
    }
    func body(mailbox:String,validity:UInt32,uid:UInt32)async throws->NativeMailBody? {
        let file=try NativeMailResponseFile(temporaryRoot:temp),raw=Data(rawBody.utf8)
        try file.withDescriptor{fd in try FileHandle(fileDescriptor:fd,closeOnDealloc:false).write(contentsOf:Data("* 1 FETCH (UID \(uid) BODY[] {\(raw.count)}\r\n".utf8)+raw+Data(")\r\n".utf8))}
        let reply=NativeMailReply(body:Data(),protocolHeaders:Data("* OK [UIDVALIDITY \(validity)] selected\r\n".utf8),serverCode:200,responseBytes:0)
        let result=try NativeMailClient.decodeBodyFile(reply,file:file,validity:validity,uid:uid,temporaryRoot:temp)
        try afterBody?();return result
    }
}

@main enum StoreTests {
    static func main()async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]);var checks=0
        func check(_ value:Bool,_ message:String)throws{guard value else{throw NativeDBError.message(message)};checks += 1}
        func receiver(_ f:MailSyncFixture,count:Int=2)->FileMailReceiver{f.receiver.messages=["INBOX":Array(1...UInt32(count)),"送信済み":[]];return FileMailReceiver(base:f.receiver,temp:f.root)}
        func sync(_ f:MailSyncFixture,_ r:FileMailReceiver)->NativeMailSyncWorker{.init(db:f.db,store:f.secrets,makeClient:{_,_ in r},clock:{f.now})}
        func content(_ f:MailSyncFixture,_ r:FileMailReceiver)->NativeMailContentWorker{.init(db:f.db,store:f.secrets,makeClient:{_,_ in r},clock:{f.now})}
        func runBody(_ f:MailSyncFixture,_ r:FileMailReceiver,job:String)async throws {
            let worker=content(f,r)
            for _ in 0..<3 { _ = try await worker.runNext();if try f.db.job(id:job)?.status != "pending" {return} }
            throw NativeDBError.message("Body fixture queue did not drain")
        }

        do {
            let f=try MailSyncFixture(resources:resources),r=receiver(f,count:34);r.subjectBytes=524_288
            let job=try f.start();_ = try await sync(f,r).runNext()
            try check(try f.db.job(id:job)?.status=="done" && f.rows()==34,"17MiB disk header batch persisted")
            try check(r.arrayCalls==0 && r.fileCalls==1,"worker used streaming header batch")
            try check(try f.cursor()?.uid==34 && f.linkJobs()==34,"batch cursor/follow-ups committed together")
            let rows=try f.db.page("Email",fields:["subject"]).rows
            try check(rows.allSatisfy{$0["subject"].string.utf8.count==524_288},"large subjects not silently emptied")
        }
        do {
            let f=try MailSyncFixture(resources:resources),r=receiver(f);r.corruptUID=2;let job=try f.start();_ = try await sync(f,r).runNext()
            try check(try f.rows()==0 && f.linkJobs()==0,"later invalid header rolled back earlier row and follow-up")
            try check(try f.cursor()?.uid==0 && f.db.job(id:job)?.status=="failed","failed batch did not advance cursor")
        }
        do {
            let f=try MailSyncFixture(resources:resources),r=receiver(f);r.afterBatch={_ = try f.db.update(f.owner,changes:["userStatus":.text("INACTIVE")],actor:"test")};let job=try f.start();_ = try await sync(f,r).runNext()
            try check(try f.rows()==0 && f.linkJobs()==0 && f.db.job(id:job)?.status != "done","fresh actor revocation fences disk batch")
        }
        do {
            let f=try MailSyncFixture(resources:resources),r=receiver(f);r.cancelBatch=true;let job=try f.start(),worker=sync(f,r)
            _ = try await Task.detached{try await worker.runNext()}.value
            try check(try f.rows()==0 && f.cursor()?.uid==0 && f.db.job(id:job)?.status=="retry","cancelled disk batch leaves no rows/cursor")
        }
        let original=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("consumer-reference.json"))) as! [String:Any]
        for c in original["cases"] as! [[String:Any]] {
            let f=try MailSyncFixture(resources:resources),r=receiver(f,count:1);r.rawBody=c["raw"] as! String;_ = try f.start();_ = try await sync(f,r).runNext()
            let row=try f.db.page("Email",fields:[]).rows[0],job=try f.service.requestMailBody(row)!;try await runBody(f,r,job:job);let saved=try f.service.mailMessage(row["id"].string)
            try check(saved["bodyText"] == (c["text"] as? String).map(SQLValue.text) ?? .null,"actual source consumer text saved")
            try check(saved["bodyHtml"] == (c["html"] as? String).map(SQLValue.text) ?? .null,"actual source consumer HTML saved \(c["name"]!)")
            try check(try f.db.job(id:job)?.status=="done" && f.service.mailBodyIsLoaded(saved),"loaded flag and job completed")
        }
        do {
            let f=try MailSyncFixture(resources:resources),r=receiver(f,count:1);_ = try f.start();_ = try await sync(f,r).runNext()
            let row=try f.db.page("Email",fields:[]).rows[0],job=try f.service.requestMailBody(row)!;r.afterBody={_ = try f.db.update(f.owner,changes:["userStatus":.text("INACTIVE")],actor:"test")};try await runBody(f,r,job:job)
            let current=try f.db.get("Email",key:["id":row["id"]])!
            try check(current["bodyText"] == .null && current["bodyHtml"] == .null,"late revocation prevents body save")
            try check(try f.db.metadata("mail.bodyLoaded."+row["id"].string)==nil && f.db.job(id:job)?.status != "done","late failure does not claim loaded success")
        }
        // Only the regressions whose receiving protocol/worker boundary changed.
        let priorSync=try await NativeMailSyncTests.run(resources:resources),priorContent=try await NativeMailContentTests.run(resources:resources)
        let result:[String:Any]=["newChecks":checks,"existingSyncChecks":priorSync,"existingContentChecks":priorContent,"sourceConsumerCases":5,"networkCalls":0,"realKeychain":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("store-result.json"));print("Disk receive/storage: \(checks) new checks")
    }
}
