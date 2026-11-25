import Foundation
import SQLite3

@main enum ProjectKanbanTests {
    struct Reference: Decodable {
        struct Row: Decodable { let id: String; let section: String; let position: Int64 }
        struct Case: Decodable { let same: Bool; let src: [String]; let dst: [String]; let moved: String; let before: String?; let expected: [Row] }
        let cases: [Case]
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("ProjectKanbanTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Kanban-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity); var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String, _ work: () throws -> Void) throws { do { try work() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: "+label+" accepted") }
        func sql(_ text: String) throws { var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.conflict }; defer { sqlite3_close(c) }; guard sqlite3_exec(c,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) } }
        func reload(_ record: NativeRecord) throws -> NativeRecord { try db.get(record.model,key:db.key(for:record))! }
        func board(_ title: String) throws -> NativeRecord { try service.saveProject(original:nil,input:["title":.text(title),"description":.text("日本語の説明"),"visibility":.text("private")]) }
        let reference = try JSONDecoder().decode(Reference.self,from:Data(contentsOf:resources.appendingPathComponent("build/kanban-reference.json")))
        for (index,fixture) in reference.cases.enumerated() {
            let project = try board("元コード比較\(index)"); let first = try service.projectSections(project["id"].string).rows[0]
            let second = try service.saveProjectSection(boardID:project["id"].string,original:nil,title:"進行中")
            var records: [String:NativeRecord] = [:]; let sections = ["src":first,"dst":second]
            for (names,section) in [(fixture.src,first),(fixture.dst,second)] {
                for name in names.reversed() { records[name] = try service.saveProjectTask(sectionID:section["id"].string,original:nil,input:["title":.text(name),"content":.text("比較本文😀")]) }
            }
            let page = try service.projectKanban(project["id"].string)
            _ = try service.placeProjectTask(records[fixture.moved]!,in:(fixture.same ? first : second)["id"].string,before:fixture.before.map{records[$0]!},board:page.project)
            for key in ["src","dst"] {
                let rows = try service.projectTasks(sectionID:sections[key]!["id"].string).rows
                try check(rows.map{$0.record["title"].string} == fixture.expected.filter{$0.section == key}.map(\.id),"source action order \(index) \(key)")
                for expected in fixture.expected where expected.section == key { let actual = try reload(records[expected.id]!); try check(actual["position"] == .integer(expected.position) && actual["content"] == .text("比較本文😀"),"position/body \(index) \(expected.id)") }
            }
        }
        let project = try board("大きなボード"); let id = project["id"].string
        var sections = try service.projectSections(id).rows
        try db.transaction { for n in 1..<107 { sections.append(try service.saveProjectSection(boardID:id,original:nil,title:"列\(n)")) } }
        try check(try db.page("Sections",fields:[],equal:["board":project["id"]],limit:999).rows.count == 100,"generic page upper bound")
        var tasks: [NativeRecord] = []
        try db.transaction { for n in 0..<107 { tasks.append(try service.saveProjectTask(sectionID:sections[0]["id"].string,original:nil,input:["title":.text("カード\(n)"),"content":.text(String(repeating:"本文",count:1024)),"dueDateAt":.null])) } }
        var page = try service.projectKanban(id)
        try check(page.columns.count == 3 && page.totalSections == 107 && page.columns[0].rows.count == 100,"bounded columns and rows")
        try check(page.columns[0].rows.allSatisfy{$0.record.values["content"] == nil} && page.project.values["description"] == nil,"large bodies excluded")
        try check(page.columns[0].following?["id"] == tasks[6]["id"],"page boundary anchor")
        let tail = try service.projectKanban(id,taskOffsets:[sections[0]["id"].string:100])
        try check(tail.columns[0].rows.count == 7 && tail.columns[0].following == nil,"last page")
        let lastColumns = try service.projectKanban(id,sectionOffset:105)
        try check(lastColumns.columns.count == 2 && lastColumns.columns[0].section["id"] == sections[105]["id"],"columns beyond first100")
        let clamped = try service.projectKanban(id,sectionOffset:999,taskOffsets:[sections[0]["id"].string:999])
        try check(clamped.sectionOffset == 105,"deleted tail columns clamp")
        try check(try service.projectKanban(id,taskOffsets:[sections[0]["id"].string:999]).columns[0].offset == 100,"deleted tail rows clamp")
        let moving = page.columns[0].rows[0].record
        try check(try service.placeProjectTask(moving,in:sections[0]["id"].string,before:page.columns[0].following,board:page.project),"move to next-page boundary")
        page = try service.projectKanban(id)
        try check(page.columns[0].rows[99].record["id"] == moving["id"] && page.columns[0].following?["id"] == tasks[6]["id"],"insertion before hidden next row")
        let noOpBoard = page.project
        try check(!(try service.placeProjectTask(page.columns[0].rows[99].record,in:sections[0]["id"].string,before:page.columns[0].following,board:page.project)),"adjacent no-op")
        try check(try reload(project).revision == noOpBoard.revision,"no-op leaves revision unchanged")
        try check(!(try service.placeProjectTask(page.columns[0].rows[0].record,in:sections[0]["id"].string,before:page.columns[0].rows[0].record,board:page.project)),"self drop no-op")
        let first = page.columns[0].rows[0].record; let destination = sections[1]["id"].string
        _ = try service.placeProjectTask(first,in:destination,before:nil,board:page.project)
        try check(try service.projectTasks(sectionID:destination).rows[0].record["id"] == first["id"],"empty column accepts move")
        try rejects("stale board") { _ = try service.placeProjectTask(page.columns[0].rows[1].record,in:destination,before:nil,board:page.project) }
        page = try service.projectKanban(id)
        let old = page.columns[0].rows[0].record
        _ = try service.saveProjectTask(sectionID:sections[0]["id"].string,original:try reload(old),input:["title":.text("競合")])
        try rejects("stale task even with fresh board") { _ = try service.placeProjectTask(old,in:destination,before:nil,board:try reload(project)) }
        let secondDB = try open(), competitor = CRMService(db:try open(),identity:identity)
        page = try service.projectKanban(id)
        _ = try competitor.saveProjectSection(boardID:id,original:nil,title:"他の接続で追加")
        try rejects("second connection changed board") { _ = try service.placeProjectTask(page.columns[0].rows[1].record,in:destination,before:nil,board:page.project) }
        try check(try secondDB.get("Boards",key:["id":project["id"]])!.revision > page.project.revision,"WAL second connection sees revision")
        page = try service.projectKanban(id)
        let anchor = try reload(first)
        _ = try db.update(anchor,changes:["title":.text("別経路の更新")],actor:identity.id)
        try rejects("stale anchor independent of board revision") { _ = try service.placeProjectTask(page.columns[0].rows[1].record,in:destination,before:anchor,board:page.project) }
        let foreign = try board("別プロジェクト"), foreignSection = try service.projectSections(foreign["id"].string).rows[0]
        try rejects("cross-board destination") { _ = try service.placeProjectTask(page.columns[0].rows[1].record,in:foreignSection["id"].string,before:nil,board:page.project) }
        try rejects("wrong anchor column") { _ = try service.placeProjectTask(page.columns[0].rows[1].record,in:destination,before:page.columns[0].rows[2].record,board:page.project) }
        try rejects("wrong record model") { _ = try service.placeProjectTask(project,in:destination,before:nil,board:page.project) }
        // Failure after multiple row writes must roll back all rows and audit.
        page = try service.projectKanban(id); let before = page.columns[0].rows.map{$0.record["id"].string}; let audits = try db.auditCount("Tasks")
        try sql("CREATE TRIGGER reject_kanban BEFORE UPDATE ON Tasks WHEN NEW.section='\(destination)' BEGIN SELECT RAISE(ABORT,'simulated write failure'); END")
        try rejects("transaction rollback") { _ = try service.placeProjectTask(page.columns[0].rows[40].record,in:destination,before:nil,board:page.project) }
        try sql("DROP TRIGGER reject_kanban")
        try check(try service.projectKanban(id).columns[0].rows.map{$0.record["id"].string} == before && db.auditCount("Tasks") == audits && reload(project).revision == page.project.revision,"rollback order/audit/board")
        try sql("UPDATE Tasks SET position=9223372036854775807 WHERE section='\(sections[0]["id"].string)'")
        page = try service.projectKanban(id); let duplicateOrder = page.columns[0].rows.map{$0.record["id"].string}; let duplicateMoved = page.columns[0].rows[50].record
        _ = try service.placeProjectTask(duplicateMoved,in:sections[0]["id"].string,before:page.columns[0].rows[0].record,board:page.project)
        try check(try service.projectKanban(id).columns[0].rows.prefix(51).map{$0.record["id"].string} == [duplicateOrder[50]]+Array(duplicateOrder.prefix(50)),"duplicate and extreme positions normalized")
        let allPositions = try db.page("Tasks",fields:["position"],equal:["section":sections[0]["id"]]).rows + db.page("Tasks",fields:["position"],equal:["section":sections[0]["id"]],offset:100).rows
        try check(Set(allPositions.map{$0["position"].string}).count == 106,"unique dense positions across pages")
        func user(_ role: String) throws -> CRMService { let u = try db.insert("Users",values:["email":.text(UUID().uuidString+"@example.invalid"),"name":.text(role),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id); return CRMService(db:db,identity:CRMIdentity(id:u["id"].string,role:role,partnerAccountID:nil)) }
        let reader = try user("user"), partner = try user("partner"), manager = try user("manager")
        _ = try service.setProjectShared(try reload(project),userID:reader.identity.id,shared:true)
        let readerPage = try reader.projectKanban(id)
        try check(!readerPage.writable && readerPage.columns[0].rows.count == 100,"shared read-only board")
        try rejects("shared user move") { _ = try reader.placeProjectTask(readerPage.columns[0].rows[0].record,in:destination,before:nil,board:readerPage.project) }
        try rejects("partner read") { _ = try partner.projectKanban(id) }
        let managerPage = try manager.projectKanban(id)
        try check(managerPage.writable,"manager board write")
        _ = try manager.placeProjectTask(managerPage.columns[0].rows[0].record,in:destination,before:nil,board:managerPage.project)
        _ = try service.setProjectShared(try reload(project),userID:reader.identity.id,shared:false)
        try rejects("fresh revoked access") { _ = try reader.projectKanban(id) }
        let userRecord = try db.get("Users",key:["id":.text(manager.identity.id)])!; _ = try db.update(userRecord,changes:["banned":.integer(1)],actor:identity.id)
        try rejects("banned cached identity") { _ = try manager.projectKanban(id) }
        let persisted = try service.projectKanban(id)
        let reopened = CRMService(db:try open(),identity:identity)
        try check(try reopened.projectKanban(id).columns[0].rows.map{$0.record["id"].string} == persisted.columns[0].rows.map{$0.record["id"].string},"restart preserves exact order")
        try service.delete(try reload(project))
        try rejects("deleted board read") { _ = try service.projectKanban(id) }
        try rejects("deleted board move") { _ = try service.placeProjectTask(persisted.columns[0].rows[0].record,in:destination,before:nil,board:persisted.project) }
        try check(try db.integrityCheck(),"database integrity")
        print("Native kanban: \(checks) checks passed; original action \(reference.cases.count) cases, bounded pages, stale edits and rollback")
    }
}
