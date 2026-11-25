import Foundation
import SQLite3

@main enum CRMProjectsTests {
    static func main() { do { try run(); try ProjectTaskOverviewTests.run(resources:URL(fileURLWithPath:CommandLine.arguments[1])) } catch { FileHandle.standardError.write(Data("CRMProjectsTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ProjectsTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db:db,identity:identity); var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws { guard try condition() else { throw NativeDBError.message("FAIL: \(label)") }; checks += 1 }
        func rejects(_ label: String, _ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: \(label) accepted") }
        func user(_ name: String, _ role: String = "user") throws -> CRMService {
            let record = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:record["id"].string,role:role,partnerAccountID:nil))
        }
        let owner = try user("owner"), reader = try user("reader"), outsider = try user("outsider"), manager = try user("manager","manager"), partner = try user("partner","partner")
        func reload(_ r: NativeRecord) throws -> NativeRecord { try db.get(r.model,key:db.key(for:r))! }
        func sql(_ text: String) throws {
            var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.message("test open") }; defer { sqlite3_close(c) }
            guard sqlite3_exec(c,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }
        }
        func board(_ service: CRMService, _ title: String) throws -> NativeRecord { try service.saveProject(original:nil,input:["title":.text(title),"description":.text("日本語の説明\n2行目"),"visibility":.text("private")]) }
        var project = try board(owner,"東京プロジェクト")
        let id = project["id"].string
        var first = try owner.projectSections(id).rows[0]
        try check(first["title"] == .text("未着手"),"atomic initial section")
        for s in [owner,manager,admin] { try check(try s.list(.projects).total == 1,"owner or elevated reads"); try s.assertAccess("Boards",id:id,write:true); checks += 1 }
        for s in [reader,outsider,partner] { try check(try s.list(.projects).total == 0,"private denied"); try rejects("private child denied") { _ = try s.projectSections(id) } }
        try rejects("partner create") { _ = try board(partner,"拒否") }
        try rejects("generic project save bypass") { _ = try owner.save(.projects,original:project,input:["title":.text("不可")]) }
        project = try owner.setProjectShared(project,userID:reader.identity.id,shared:true)
        try check(try reader.projectSections(id).total == 1,"shared read")
        try rejects("shared edit") { _ = try reader.saveProject(original:project,input:["title":.text("拒否")]) }
        try rejects("shared delete") { try reader.delete(project) }
        try rejects("shared section creation") { _ = try reader.saveProjectSection(boardID:id,original:nil,title:"拒否") }
        try reader.watchProject(id,enabled:true); try reader.watchProject(id,enabled:true)
        project = try owner.setProjectShared(project,userID:reader.identity.id,shared:false)
        try check(try reader.projectSections(id).total == 1 && reader.projectIsWatched(id),"watcher keeps read after unshare")
        try reader.watchProject(id,enabled:false)
        try rejects("unwatch loses read") { _ = try reader.projectSections(id) }
        project = try owner.saveProject(original:project,input:["visibility":.text("public")])
        try check(try outsider.projectSections(id).total == 1,"public read")
        try rejects("public still not editable") { _ = try outsider.saveProjectSection(boardID:id,original:nil,title:"不可") }
        try rejects("partner public denied") { _ = try partner.projectSections(id) }
        try rejects("stale project revision") { _ = try owner.saveProject(original:NativeRecord(model:"Boards",values:project.values,revision:project.revision-1),input:["title":.text("古い")]) }
        var second = try owner.saveProjectSection(boardID:id,original:nil,title:"進行中")
        var task = try owner.saveProjectTask(sectionID:first["id"].string,original:nil,input:["title":.text("日本語の確認"),"content":.text("<p>既存の本文</p>"),"user":.text(reader.identity.id),"dueDateAt":.text("2025-01-01T00:00:00Z")])
        try check(task["createdBy"] == .text(owner.identity.id) && task["user"] == .text(reader.identity.id),"actor not confused with assignee")
        try check(try owner.projectTasks(sectionID:first["id"].string).rows.first?.cells.last == "未完了","Japanese status")
        try rejects("assignee content change") { _ = try reader.saveProjectTask(sectionID:first["id"].string,original:task,input:["title":.text("不可")]) }
        try rejects("assignee delete") { try reader.deleteProjectTask(task) }
        try rejects("assignee move") { _ = try reader.moveProjectTask(task,to:second["id"].string) }
        try rejects("assignee comment") { _ = try reader.addProjectComment(taskID:task["id"].string,comment:"不可") }
        task = try reader.setProjectTaskStatus(task,status:"COMPLETE")
        try check(task["taskStatus"] == .text("COMPLETE"),"assignee complete")
        try rejects("other user complete") { _ = try outsider.setProjectTaskStatus(task,status:"ACTIVE") }
        let oldTask = task; task = try owner.saveProjectTask(sectionID:first["id"].string,original:task,input:["priority":.text("high")])
        try check(task["content"] == .text("<p>既存の本文</p>"),"untouched markup preserved")
        try rejects("stale status") { _ = try reader.setProjectTaskStatus(oldTask,status:"ACTIVE") }
        try rejects("status in full editor bypass") { _ = try owner.saveProjectTask(sectionID:first["id"].string,original:task,input:["taskStatus":.text("ACTIVE")]) }
        try rejects("bad priority") { _ = try owner.saveProjectTask(sectionID:first["id"].string,original:task,input:["priority":.text("invalid")]) }
        try rejects("wrong section") { _ = try owner.saveProjectTask(sectionID:second["id"].string,original:task,input:["title":.text("不可")]) }
        try rejects("invalid due date") { _ = try owner.saveProjectTask(sectionID:first["id"].string,original:task,input:["dueDateAt":.text("invalid")]) }
        try check(try db.page("Tasks",fields:[],filter:.beforeDate("dueDateAt","2026-01-01T00:00:00Z")).total == 1,"SQL date filtering")
        try rejects("invalid date filter field") { _ = try db.page("Tasks",fields:[],filter:.beforeDate("title","2026-01-01")) }
        try rejects("invalid array filter field") { _ = try db.page("Boards",fields:[],filter:.arrayContains("title","x")) }
        let comment = try owner.addProjectComment(taskID:task["id"].string,comment:"確認しました。\n次へ進めます。")
        try check(try outsider.projectComments(taskID:task["id"].string).rows[0]["comment"] == comment["comment"],"public reads comments")
        try check(try owner.projectIsWatched(id),"comment auto watches")
        try rejects("empty comment") { _ = try owner.addProjectComment(taskID:task["id"].string,comment:" \n") }
        task = try owner.moveProjectTask(task,to:second["id"].string)
        try check(try owner.projectTasks(sectionID:first["id"].string).total == 0 && owner.projectTasks(sectionID:second["id"].string).total == 1,"atomic section move")
        let foreign = try board(outsider,"別の非公開プロジェクト"); let foreignSection = try outsider.projectSections(foreign["id"].string).rows[0]
        try rejects("unauthorized destination") { _ = try owner.moveProjectTask(task,to:foreignSection["id"].string) }
        try db.transaction { for n in 0..<104 { _ = try owner.saveProjectTask(sectionID:second["id"].string,original:nil,input:["title":.text("一覧-\(n)")]) } }
        let page = try owner.projectTasks(sectionID:second["id"].string)
        try check(page.total == 105 && page.rows.count == 100,"bounded task page")
        try check(try owner.projectTasks(sectionID:second["id"].string,offset:100).rows.count == 5,"remaining page")
        try check(page.rows.first?.record["title"] == .text("一覧-103"),"new tasks first")
        let top = try owner.fullRecord(page.rows[0].record)
        try check(try owner.reorderProject(top,direction:1),"task moves down")
        try check(try owner.projectTasks(sectionID:second["id"].string).rows[1].record["id"] == top["id"],"new ordering stable")
        try rejects("stale reorder") { _ = try owner.reorderProject(top,direction:1) }
        try sql("UPDATE Tasks SET position=0 WHERE section='\(second["id"].string)'")
        let duplicates = try owner.projectTasks(sectionID:second["id"].string)
        let duplicateTop = try owner.fullRecord(duplicates.rows[0].record)
        try check(try owner.reorderProject(duplicateTop,direction:1),"normalize duplicate legacy positions")
        let positions = try db.page("Tasks",fields:["position"],equal:["section":second["id"]]).rows + db.page("Tasks",fields:["position"],equal:["section":second["id"]],offset:100).rows
        try check(Set(positions.map { $0["position"].string }).count == 105,"all 105 positions normalized")
        try check(try owner.projectTasks(sectionID:second["id"].string).rows[1].record["id"] == duplicateTop["id"],"legacy reorder preserves requested move")
        try sql("UPDATE Tasks SET position=9223372036854775807 WHERE id='\(top["id"].string)'")
        try rejects("position overflow") { _ = try owner.saveProjectTask(sectionID:second["id"].string,original:nil,input:["title":.text("不可")]) }
        try sql("UPDATE Tasks SET position=0 WHERE id='\(top["id"].string)'")
        try rejects("bad reorder direction") { _ = try owner.reorderProject(try reload(top),direction:9) }
        try check(!(try owner.reorderProject(try owner.fullRecord(owner.projectTasks(sectionID:second["id"].string).rows[0].record),direction:-1)),"edge reorder no-op")
        try check(try owner.reorderProject(second,direction:-1),"section moves up")
        second = try reload(second); first = try reload(first)
        try check(try owner.projectSections(id).rows[0]["id"] == second["id"],"section order")
        try rejects("wrong board rename") { _ = try owner.saveProjectSection(boardID:foreign["id"].string,original:second,title:"不可") }
        task = try reload(task)
        try db.transaction { for n in 0..<103 { _ = try owner.addProjectComment(taskID:task["id"].string,comment:"返信-\(n)") } }
        try check(try owner.projectComments(taskID:task["id"].string).rows.count == 100 && owner.projectComments(taskID:task["id"].string,offset:100).rows.count == 4,"comments paged")
        let boardCount = try db.page("Boards",fields:[]).total
        try sql("CREATE TRIGGER fail_project_section BEFORE INSERT ON Sections BEGIN SELECT RAISE(ABORT,'test section failure'); END")
        try rejects("initial section failure rolls back board") { _ = try board(owner,"失敗予定") }
        try sql("DROP TRIGGER fail_project_section")
        try check(try db.page("Boards",fields:[]).total == boardCount,"board rollback")
        try sql("CREATE TRIGGER fail_project_delete BEFORE DELETE ON Tasks WHEN OLD.title='一覧-7' BEGIN SELECT RAISE(ABORT,'test delete failure'); END")
        let beforeAudit = try db.auditCount("Tasks")
        try rejects("section cascading failure") { try owner.deleteProjectSection(second) }
        try sql("DROP TRIGGER fail_project_delete")
        try check(try owner.projectTasks(sectionID:second["id"].string).total == 105 && db.auditCount("Tasks") == beforeAudit,"all task deletions and audits roll back")
        try check(try owner.projectComments(taskID:task["id"].string).total == 104,"comments survive rollback")
        project = try reload(project)
        try owner.delete(project)
        for s in [admin,manager,owner,reader] {
            try rejects("deleted parent hides sections") { _ = try s.projectSections(id) }
            try rejects("deleted parent hides tasks") { _ = try s.fullRecord(task) }
            try rejects("deleted parent status denied") { _ = try s.setProjectTaskStatus(task,status:"ACTIVE") }
        }
        try check(try admin.list(.projects,trash:true).total == 1,"admin trash")
        try rejects("owner restore denied") { try owner.delete(try reload(project),restore:true) }
        try admin.delete(try reload(project),restore:true)
        try check(try owner.projectTasks(sectionID:second["id"].string).total == 105,"restore retains tasks")
        project = try owner.saveProject(original:try reload(project),input:["visibility":.text("private")])
        task = try reader.setProjectTaskStatus(try reload(task),status:"ACTIVE")
        try check(task["taskStatus"] == .text("ACTIVE"),"assignee status on private board")
        try rejects("assignee cannot read private board") { _ = try reader.projectSections(id) }
        try sql("UPDATE Boards SET sharedWith='invalid json' WHERE id='\(id)'")
        try check(try outsider.list(.projects).total == 1,"malformed shared JSON safely denies")
        try sql("UPDATE Boards SET sharedWith='{}' WHERE id='\(id)'")
        try check(try reader.list(.projects).total == 0,"non-array shared JSON safely denies")
        try sql("UPDATE Boards SET sharedWith='[]' WHERE id='\(id)'")
        let document = try db.insert("Documents",values:["document_name":.text("添付文書"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("local-test"),"connected_documents":.text("[]")],actor:identity.id)
        _ = try db.insert("DocumentsToTasks",values:["document_id":document["id"],"task_id":task["id"]],actor:identity.id)
        try owner.deleteProjectTask(task)
        try check(try db.page("tasksComments",fields:[],equal:["task":task["id"]]).total == 0,"task comments deleted in chunks")
        try check(try db.page("DocumentsToTasks",fields:[],equal:["task_id":task["id"]]).total == 0,"task document links removed")
        try check(try db.get("Documents",key:["id":document["id"]]) != nil,"document retained")
        try check(try owner.projectTasks(sectionID:second["id"].string).total == 104,"other tasks retained")
        try owner.deleteProjectSection(second)
        try check(try db.page("Tasks",fields:[],equal:["section":second["id"]]).total == 0,"all section tasks deleted")
        let restarted = CRMService(db:try open(),identity:owner.identity)
        try check(try restarted.projectSections(id).total == 1,"restart persists section deletion")
        try check(try restarted.list(.projects).rows[0].record["title"] == .text("東京プロジェクト"),"restart Japanese project")
        let actor = try db.get("Users",key:["id":.text(owner.identity.id)])!
        _ = try db.update(actor,changes:["banned":.integer(1)],actor:identity.id)
        try rejects("revoked identity") { _ = try owner.projectSections(id) }
        print("CRMProjectsTests: \(checks) checks passed")
    }
}
