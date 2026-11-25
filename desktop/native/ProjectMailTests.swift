import Foundation
import SQLite3

extension InvoiceMailTests {
    static func projectMailTests() async throws {
        let initialChecks = checks; let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ProjectMail-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db:db,identity:identity)
        func user(_ name: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:"user",partnerAccountID:nil))
        }
        let owner = try user("owner"); let assignee = try user("assignee"); let stranger = try user("stranger")
        func board(_ title: String, privateBoard: Bool = false) throws -> NativeRecord {
            try owner.saveProject(original:nil,input:["title":.text(title),"description":.text("通知の架空検証"),"visibility":.text(privateBoard ? "private" : "public")])
        }
        let publicBoard = try board("公開の検証プロジェクト"); let privateBoard = try board("共有しないプロジェクト名",privateBoard:true)
        func refresh(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        func task(_ title: String, board selected: NativeRecord? = nil, assigned: CRMService? = nil) throws -> NativeRecord {
            try owner.createProjectTaskInBoard((selected ?? publicBoard)["id"].string,input:["title":.text(title),"content":.text("メール本文へ複製しないタスクの内容"),"user":.text((assigned ?? assignee).identity.id),"priority":.text("normal")])
        }
        func jobs(_ task: NativeRecord) throws -> [NativeJob] { try admin.projectJobs(taskID:task["id"].string) }
        func updateUser(_ user: CRMService, _ changes: [String:SQLValue], database: NativeDatabase? = nil) throws {
            let database = database ?? db
            _ = try database.update(database.get("Users",key:["id":.text(user.identity.id)])!,changes:changes,actor:identity.id)
        }
        func sql(_ text: String) throws {
            var raw: OpaquePointer?; guard sqlite3_open(db.url.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test SQLite open") }; defer { sqlite3_close(raw) }
            guard sqlite3_exec(raw,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test SQLite SQL") }
        }
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/project-notifications-reference.json"))) as! [String:Any]
        let sourceCases = reference["cases"] as! [[String:Any]]
        func sourceCount(_ name: String) -> Int { (sourceCases.first { $0["case"] as? String == name }!["sends"] as! [Any]).count }
        var now = Date(timeIntervalSince1970:1_800_000_000.25)
        var credentials = InvoiceMailAccount(from:"notifications@example.invalid",apiKey:"fake-project-key")
        var configured = true; var code = 200; var calls = 0; var bodies: [Data] = []; var keys: [String] = []
        var duringSend: (() throws -> Void)?
        let providerID = UUID().uuidString.lowercased()
        let request: ResendMailClient.Request = { query,file in
            calls += 1; bodies.append(try Data(contentsOf:file)); keys.append(query.value(forHTTPHeaderField:"Idempotency-Key")!)
            try duringSend?()
            return (try JSONSerialization.data(withJSONObject:code == 200 ? ["id":providerID] : ["name":"fake_error"]),HTTPURLResponse(url:query.url!,statusCode:code,httpVersion:nil,headerFields:code == 503 ? ["Retry-After":"20"] : nil)!)
        }
        func worker(_ database: NativeDatabase = db) -> ProjectMailWorker {
            ProjectMailWorker(db:database,account:{ guard configured else { throw NativeDBError.message("検証用の設定未登録") }; return credentials },request:request,clock:{now})
        }
        let first = worker()
        func drain(_ w: ProjectMailWorker = first) async throws {
            var count = 0; while try await w.runNext() { count += 1; if count > 300 { throw NativeDBError.message("project worker did not settle") } }
        }
        func lastBody() throws -> [String:Any] { try JSONSerialization.jsonObject(with:bodies.last!) as! [String:Any] }

        var assigned = try task("最初の日本語タスク")
        let originalNotice = try jobs(assigned).first!
        try check(try jobs(assigned).count == sourceCount("create-other"),"creation recipients match original action")
        try check(originalNotice.payload["actorId"] == owner.identity.id && originalNotice.payload["recipientId"] == assignee.identity.id,"event records actor and assignee")
        try check(originalNotice.payload["content"] == nil,"task body is not duplicated in outbox")
        try await drain()
        try check(calls == 1 && (try db.job(id:originalNotice.id))?.result["outcome"] == "sent","assignment delivered once via fake transport")
        let body = try lastBody(); let text = body["text"] as! String
        try check((body["subject"] as? String)?.contains("新しい担当タスク") == true && text.contains("公開の検証プロジェクト"),"Japanese assignment subject and project context")
        try check(!text.contains("メール本文へ複製しない"),"original template semantics omit task content")
        try check(keys.last == "nextcrm/project/"+originalNotice.id,"separate project idempotency namespace")
        let link = try NativeProjectTaskLink(taskID:assigned["id"].string)
        try check(text.contains(link.string) && NativeProjectTaskLink(text:link.string) == link,"native task link round trip in notification")
        for invalid in [link.string+"?delete=1",link.string+"#x",link.string+"/",link.string.replacingOccurrences(of:"tasks/",with:"tasks:7/"),"https://tasks/"+link.taskID,"nextcrm-native://u:p@tasks/"+link.taskID,"nextcrm-native://tasks/%2F"+link.taskID,"nextcrm-native://tasks/not-a-uuid"] {
            try rejects("unsafe task link rejected") { _ = try NativeProjectTaskLink(text:invalid) }
        }
        try check(try owner.projectTaskFromLink(link).task["id"] == assigned["id"],"task link uses current authorized record")
        try check(!FileManager.default.fileExists(atPath:try InvoiceMail.bodyURL(root:root,id:originalNotice.id).path),"accepted assignment body removed")
        let own = try task("自分への割り当て",assigned:owner)
        try check(try jobs(own).count == sourceCount("create-self"),"self assignment does not queue notification")
        assigned = try owner.saveProjectTask(sectionID:assigned["section"].string,original:assigned,input:["title":.text("日本語の更新")])
        try check(try jobs(assigned).filter { $0.event == "projects.task_updated" }.count == sourceCount("update-other"),"update recipient matches original action")
        let countBeforeStatus = try jobs(assigned).count
        assigned = try assignee.setProjectTaskStatus(assigned,status:"COMPLETE")
        try check(try jobs(assigned).count == countBeforeStatus,"status-only action does not invent update email")
        try await drain(); try check((try lastBody()["subject"] as? String)?.contains("タスクを更新") == true,"Japanese update notification")
        try rejects("reader cannot inspect other recipient's jobs") { _ = try stranger.projectJobAccess(originalNotice.id) }
        try check(try owner.projectJobAccess(originalNotice.id).id == originalNotice.id,"project owner can manage task notifications")
        try check(try owner.projectBoardJobs(boardID:publicBoard["id"].string).count == 2,"owner sees project-level notification history")
        try check(try assignee.projectBoardJobs(boardID:publicBoard["id"].string).count == 2,"recipient sees own project-level notifications")
        try check(try stranger.projectBoardJobs(boardID:publicBoard["id"].string).isEmpty,"board reader cannot inspect other recipients' mail")
        try rejects("private board history is denied") { _ = try stranger.projectBoardJobs(boardID:privateBoard["id"].string) }

        let privateTask = try task("担当者だけに見せるタスク",board:privateBoard)
        try await drain(); let privateText = try lastBody()["text"] as! String
        try check(privateText.contains("担当者だけに見せるタスク") && !privateText.contains("共有しないプロジェクト名"),"private assignment does not disclose inaccessible board title")
        try check(try assignee.projectTaskFromLink(NativeProjectTaskLink(taskID:privateTask["id"].string)).board == nil,"private assignee link grants task-only view")
        try rejects("unrelated user cannot follow private task link") { _ = try stranger.projectTaskFromLink(NativeProjectTaskLink(taskID:privateTask["id"].string)) }

        try assignee.watchProject(publicBoard["id"].string,enabled:true)
        let note = "日本語のコメントです。\n<&> 😀"
        let comment = try admin.addProjectComment(taskID:assigned["id"].string,comment:note)
        let commentJobs = try jobs(assigned).filter { $0.payload["commentId"] == comment["id"].string }
        try check(commentJobs.count == sourceCount("comment-watchers-and-creator"),"watcher plus creator match original recipients")
        try check(Set(commentJobs.compactMap { $0.payload["recipientId"] }) == [owner.identity.id,assignee.identity.id],"comment excludes author")
        try await drain(); try check((try lastBody()["text"] as! String).contains(note),"multiline Japanese comment retained")
        try owner.watchProject(publicBoard["id"].string,enabled:true)
        let duplicate = try admin.addProjectComment(taskID:assigned["id"].string,comment:"作成者とウォッチャーの重複")
        let deduplicated = try jobs(assigned).filter { $0.payload["commentId"] == duplicate["id"].string }
        try check(deduplicated.count == 2 && Set(deduplicated.compactMap { $0.payload["recipientId"] }).count == 2,"creator also watching receives one notification")
        try assignee.watchProject(publicBoard["id"].string,enabled:false)
        let beforeUnwatch = calls; try await drain()
        try check(calls == beforeUnwatch+1,"unwatched recipient skipped before sending")
        let skipped = deduplicated.first { $0.payload["recipientId"] == assignee.identity.id }!
        try check(try db.job(id:skipped.id)?.result["outcome"] == "skipped","unwatch decision recorded")
        let largeComment = try admin.addProjectComment(taskID:assigned["id"].string,comment:String(repeating:"長い日本語のメモ。",count:10000))
        let smallJob = try jobs(assigned).first { $0.payload["commentId"] == largeComment["id"].string }!
        try check(try JSONEncoder().encode(smallJob.payload).count < 2000 && smallJob.payload["comment"] == nil,"large comment stored once, jobs retain small identifiers")
        try await drain()

        let retryTask = try task("再試行で同じ内容")
        let retryJob = try jobs(retryTask).first!; code = 503; try await drain()
        let frozen = bodies.last!; let frozenKey = keys.last!
        try check(try db.job(id:retryJob.id)?.status == "retry","transient project delivery persisted for retry")
        try check(try (FileManager.default.attributesOfItem(atPath:InvoiceMail.bodyURL(root:root,id:retryJob.id).path)[.posixPermissions] as! NSNumber).intValue == 0o600,"frozen project body is private")
        _ = try db.update(retryTask,changes:["title":.text("後の変更")],actor:identity.id)
        credentials = .init(from:"changed@example.invalid",apiKey:credentials.apiKey); code = 200; now.addTimeInterval(21)
        try await drain(worker(second))
        try check(bodies.last == frozen && keys.last == frozenKey,"restart retry preserves exact body, sender and idempotency key")
        try check(try db.job(id:retryJob.id)?.status == "done" && db.job(id:retryJob.id)?.attempts == 2,"second connection completes persisted retry")

        let emailTask = try task("宛先変更を検知"); let emailJob = try jobs(emailTask).first!; let beforeEmail = calls
        try updateUser(assignee,["email":.text("new-address@example.invalid")]); try await drain()
        try check(calls == beforeEmail && (try db.job(id:emailJob.id))?.result["outcome"] == "skipped","changed address is not silently substituted")
        try updateUser(assignee,["email":.text("assignee@example.invalid")])
        let bannedTask = try task("利用停止を検知"); let bannedJob = try jobs(bannedTask).first!; let beforeBan = calls
        try updateUser(assignee,["banned":.integer(1)]); try await drain()
        try check(calls == beforeBan && (try db.job(id:bannedJob.id))?.result["outcome"] == "skipped","banned recipient skipped")
        try updateUser(assignee,["banned":.integer(0)])
        let changedTask = try task("担当変更を検知"); let changedJob = try jobs(changedTask).first!; let beforeChange = calls
        _ = try owner.saveProjectTask(sectionID:changedTask["section"].string,original:changedTask,input:["user":.text(owner.identity.id)])
        try await drain(); try check(calls == beforeChange && (try db.job(id:changedJob.id))?.result["outcome"] == "skipped","old assignee notification skipped")
        let moved = try task("移動を検知"); let movedJob = try jobs(moved).first!
        let destination = try owner.projectSections(privateBoard["id"].string).rows[0]
        _ = try owner.moveProjectTask(moved,to:destination["id"].string); try await drain()
        try check(try db.job(id:movedJob.id)?.result["outcome"] == "skipped","notification cannot disclose original board after cross-board move")

        let deleted = try task("削除されたタスク"); let deletedJob = try jobs(deleted).first!; code = 503; try await drain()
        try owner.deleteProjectTask(deleted); code = 200; now.addTimeInterval(21); let beforeDeleted = calls; try await drain()
        let review = try db.job(id:deletedJob.id)!
        try check(review.status == "needs_review" && calls == beforeDeleted,"deleted task after ambiguous send requires review without another request")
        try check(try owner.projectBoardJobs(boardID:publicBoard["id"].string).contains { $0.id == review.id },"deleted task notification remains discoverable from its project")
        try check(try owner.projectJobAccess(review.id).id == review.id,"project owner can manage deleted task notification")
        try rejects("unrelated reader cannot review deleted task mail") { try stranger.reviewMailJob(review,outcome:.unknown,providerID:"",note:"権限のない確認",now:now) }
        try admin.reviewMailJob(review,outcome:.unknown,providerID:"",note:"検証用の送信結果を確認できませんでした。",now:now)
        try check(try db.job(id:review.id)?.status == "done" && db.job(id:review.id)?.result["outcome"] == "unconfirmed","admin can resolve ambiguous mail after task deletion")

        let accepted = try task("受付後の権限変更"); let acceptedJob = try jobs(accepted).first!
        duringSend = { try updateUser(assignee,["banned":.integer(1)],database:second) }
        try await drain(); duringSend = nil
        try check(try db.job(id:acceptedJob.id)?.result["providerID"] == providerID && db.job(id:acceptedJob.id)?.status == "done","accepted receipt persists even when access changes during external await")
        try updateUser(assignee,["banned":.integer(0)])
        let noSettings = try task("設定後に再送"); let settingsJob = try jobs(noSettings).first!; configured = false; let beforeSettings = calls
        try await drain(); try check(calls == beforeSettings && (try db.job(id:settingsJob.id))?.status == "failed","missing credentials never call transport")
        configured = true; try owner.retryProjectJob(settingsJob.id,now:now); try await drain()
        try check(try db.job(id:settingsJob.id)?.status == "done","owner can retry after settings are supplied")

        let changedComment = try admin.addProjectComment(taskID:assigned["id"].string,comment:"変更前のコメント")
        let changedCommentJob = try jobs(assigned).first { $0.payload["commentId"] == changedComment["id"].string }!
        _ = try db.update(changedComment,changes:["comment":.text("更新後の別の内容")],actor:identity.id)
        let beforeCommentChange = calls; try await drain()
        try check(calls == beforeCommentChange && (try db.job(id:changedCommentJob.id))?.result["outcome"] == "skipped","changed comment revision is not substituted into pending mail")
        let deletedComment = try admin.addProjectComment(taskID:assigned["id"].string,comment:"削除するコメント")
        let deletedCommentJob = try jobs(assigned).first { $0.payload["commentId"] == deletedComment["id"].string }!
        try db.remove(deletedComment,actor:identity.id,action:"delete")
        try await drain(); try check(calls == beforeCommentChange && (try db.job(id:deletedCommentJob.id))?.result["outcome"] == "skipped","deleted comment is never sent")
        let forbiddenCount = try admin.projectBoardJobs(boardID:publicBoard["id"].string).count
        try rejects("reader cannot create tasks or enqueue mail") { _ = try stranger.createProjectTaskInBoard(publicBoard["id"].string,input:["title":.text("権限なし"),"user":.text(assignee.identity.id)]) }
        try rejects("reader cannot update task or enqueue mail") { _ = try stranger.saveProjectTask(sectionID:assigned["section"].string,original:try refresh(assigned),input:["title":.text("権限なし")]) }
        try rejects("reader cannot comment or enqueue mail") { _ = try stranger.addProjectComment(taskID:assigned["id"].string,comment:"権限なし") }
        try check(try admin.projectBoardJobs(boardID:publicBoard["id"].string).count == forbiddenCount,"rejected actions leave no notifications")

        let originalCount = try db.page("Tasks",fields:[]).total
        try sql("CREATE TRIGGER fail_project_notice BEFORE INSERT ON native_outbox WHEN NEW.event LIKE 'projects.%' BEGIN SELECT RAISE(ABORT,'test project outbox failure'); END;")
        try rejects("outbox failure rolls back task") { _ = try task("保存ごとロールバック") }
        try check(try db.page("Tasks",fields:[]).total == originalCount,"failed queue leaves no saved task")
        let commentsBefore = try db.page("tasksComments",fields:[],equal:["task":assigned["id"]]).total
        try rejects("outbox failure rolls back comment") { _ = try admin.addProjectComment(taskID:assigned["id"].string,comment:"保存されないコメント") }
        try check(try db.page("tasksComments",fields:[],equal:["task":assigned["id"]]).total == commentsBefore,"failed queue leaves no saved comment")
        try sql("DROP TRIGGER fail_project_notice")

        let manyBoard = try board("105人の通知"); let manyTask = try task("ページ単位の通知",board:manyBoard,assigned:owner)
        try owner.watchProject(manyBoard["id"].string,enabled:true)
        try db.transaction { for i in 0..<104 { let watcher = try user("watcher-\(i)"); try watcher.watchProject(manyBoard["id"].string,enabled:true) } }
        _ = try admin.addProjectComment(taskID:manyTask["id"].string,comment:"100件を超えるウォッチャー")
        let page1 = try admin.projectJobs(taskID:manyTask["id"].string)
        let page2 = try admin.projectJobs(taskID:manyTask["id"].string,offset:100)
        try check(page1.count == 100 && page2.count == 5 && Set((page1+page2).compactMap { $0.payload["recipientId"] }).count == 105,"105 distinct recipients with bounded pages and creator deduplication")
        try check(try owner.projectBoardJobs(boardID:manyBoard["id"].string).count == 100 && owner.projectBoardJobs(boardID:manyBoard["id"].string,offset:100).count == 5,"project history applies the same bounded pagination")
        let beforeMany = calls; try await drain(); try check(calls == beforeMany+105,"all paged recipients delivered once")
        let race = try task("二つのワーカー"); let raceJob = try jobs(race).first!; let beforeRace = calls
        let competing = worker(second)
        async let a = first.runNext(); async let b = competing.runNext()
        let results = try await [a,b]
        try check(results.filter { $0 }.count == 1 && calls == beforeRace+1 && (try db.job(id:raceJob.id))?.status == "done","two workers cannot send the same task notice concurrently")
        let cancelled = try task("通知を取り消す"); let cancelledJob = try jobs(cancelled).first!; try owner.cancelProjectJob(cancelledJob.id); let beforeCancel = calls; try await drain()
        try check(calls == beforeCancel && (try db.job(id:cancelledJob.id))?.status == "cancelled","cancelled notice never sent")
        print("Project notifications: \(checks-initialChecks) checks passed; original action fixtures15; fake transport only")
    }
}
