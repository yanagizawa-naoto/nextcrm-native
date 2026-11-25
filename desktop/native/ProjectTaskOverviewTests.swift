import Foundation

enum ProjectTaskOverviewTests {
    struct Fixture: Decodable {
        struct Row: Decodable { let name: String; let user: String; let taskStatus: String?; let dueDateAt: String? }
        struct Expected: Decodable { let overdue: [String]; let week: [String] }
        let zone: String; let now: String; let start: String; let end: String; let rows: [Row]; let expected: [String:Expected?]
    }
    static func run(resources: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-TaskOverview-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws { guard try condition() else { throw NativeDBError.message("Task overview FAIL: \(name)") }; checks += 1 }
        func rejects(_ name: String, _ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("Task overview FAIL: \(name) accepted") }
        func user(_ name: String, _ role: String) throws -> CRMService {
            let r = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:r["id"].string,role:role,partnerAccountID:nil))
        }
        let actor = try user("担当者","user"), other = try user("他の担当者","user"), manager = try user("管理者","manager"), partner = try user("パートナー","partner")
        let services = ["user":actor,"manager":manager,"admin":admin,"partner":partner]
        let iso = ISO8601DateFormatter(); iso.formatOptions.insert(.withFractionalSeconds)
        let fixtures = try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:resources.appendingPathComponent("build/project-tasks-reference.json")))
        for fixture in fixtures {
            let now = iso.date(from:fixture.now)!, zone = TimeZone(identifier:fixture.zone)!
            let range = ProjectDeadlineRange(now:now,timeZone:zone)
            try check(ProjectDeadlineRange.stamp(range.start) == fixture.start && ProjectDeadlineRange.stamp(range.end) == fixture.end,"original calendar boundaries \(fixture.zone)")
            let board = try admin.saveProject(original:nil,input:["title":.text(fixture.zone),"description":.text("基準の比較")])
            let section = try admin.projectSections(board["id"].string).rows[0]
            try db.transaction {
                for (n,row) in fixture.rows.enumerated() {
                    _ = try db.insert("Tasks",values:["v":.integer(0),"title":.text(row.name),"section":section["id"],"user":.text(row.user == "actor" ? actor.identity.id : other.identity.id),"priority":.text(n%2 == 0 ? "high" : "normal"),"position":.integer(Int64(n)),"taskStatus":row.taskStatus.map(SQLValue.text) ?? .null,"dueDateAt":row.dueDateAt.map(SQLValue.text) ?? .null,"content":.text(String(repeating:"本文を一覧には読み込まない",count:100))],actor:identity.id)
                }
            }
            for (role,service) in services {
                for due in [ProjectTaskDue.overdue,.week] {
                    let query = ProjectTaskQuery(scope:.deadlines,due:due)
                    guard let expected = fixture.expected[role] ?? nil else { try rejects("partner deadline access") { _ = try service.projectTaskPage(query,now:now,timeZone:zone) }; continue }
                    let page = try service.projectTaskPage(query,now:now,timeZone:zone)
                    let names = Set(due == .overdue ? expected.overdue : expected.week)
                    try check(page.total == names.count && Set(page.rows.map { $0.record["title"].string }) == names,"original \(role) \(due) \(fixture.zone)")
                    try check(page.rows.allSatisfy { $0.record.values["content"] == nil },"large body excluded from list")
                }
            }
            try check(try actor.projectTaskPage(ProjectTaskQuery(scope:.readable)).total == 0,"private board absent from readable tasks")
            let mine = try actor.projectTaskPage(ProjectTaskQuery(scope:.assigned(actor.identity.id)))
            try check(mine.total == 40 && mine.rows.allSatisfy { $0.boardID == nil && !$0.canEdit && !$0.canReadComments && $0.canChangeStatus },"own private tasks no parent or comments grant")
            let task = mine.rows[0].record
            let detail = try actor.projectTaskOverview(task["id"].string)
            try check(!detail.task["content"].string.isEmpty && detail.board == nil && !detail.canEdit && detail.canChangeStatus,"own task detail only")
            try rejects("other user private task") { _ = try other.projectTaskOverview(task["id"].string) }
            try rejects("user asks other assignee") { _ = try actor.projectTaskPage(ProjectTaskQuery(scope:.assigned(other.identity.id))) }
            try check(try manager.projectTaskPage(ProjectTaskQuery(scope:.assigned(other.identity.id))).total == 40,"manager selects assignee")
            try rejects("private comments still protected") { _ = try actor.projectComments(taskID:task["id"].string) }
            _ = try actor.setProjectTaskStatus(task,status:"COMPLETE")
            let current = try db.get("Boards",key:["id":board["id"]])!
            try admin.delete(current)
            try check(try actor.projectTaskPage(ProjectTaskQuery(scope:.assigned(actor.identity.id))).total == 0,"deleted board excluded even for assignee")
            try rejects("deleted board detail") { _ = try actor.projectTaskOverview(task["id"].string) }
        }
        let board = try actor.saveProject(original:nil,input:["title":.text("検索・ページ"),"description":.text("検索条件")])
        let section = try actor.projectSections(board["id"].string).rows[0]
        try db.transaction { for n in 0..<205 { _ = try actor.saveProjectTask(sectionID:section["id"].string,original:nil,input:["title":.text(String(format:"日本語-%03d",n)),"priority":.text(n%2 == 0 ? "high" : "low"),"dueDateAt":.null]) } }
        var query = ProjectTaskQuery(scope:.readable); query.sort = .title; query.descending = false
        let first = try actor.projectTaskPage(query), last = try actor.projectTaskPage(query,offset:200)
        try check(first.rows.count == 100 && first.total == 205 && last.rows.count == 5,"205 tasks bounded paging")
        try check(first.rows[0].record["title"] == .text("日本語-000") && last.rows.last?.record["title"] == .text("日本語-204"),"SQL sort across pages")
        query.priorities = ["high"]; query.statuses = ["ACTIVE"]
        try check(try actor.projectTaskPage(query).total == 103,"status and priority filters")
        query.search = "日本語-20"; try check(try actor.projectTaskPage(query).total == 3,"Japanese search composed with filters")
        query.search = "%"; try check(try actor.projectTaskPage(query).total == 0,"literal percent search")
        query.priorities = ["injected"]; try rejects("invalid filter choice") { _ = try actor.projectTaskPage(query) }
        let created = try actor.createProjectTaskInBoard(board["id"].string,input:["title":.text("一覧から追加")])
        try check(created["section"] == section["id"],"global creation uses first ordered section")
        let shared = try actor.setProjectShared(try db.get("Boards",key:["id":board["id"]])!,userID:other.identity.id,shared:true)
        let sharedPage = try other.projectTaskPage(ProjectTaskQuery(scope:.readable))
        try check(sharedPage.total == 206 && sharedPage.rows.allSatisfy { !$0.canEdit && !$0.canChangeStatus && $0.canReadComments && $0.boardID == board["id"].string },"shared read flags")
        _ = try actor.setProjectShared(shared,userID:other.identity.id,shared:false)
        try rejects("revoked sharing on opening stale row") { _ = try other.projectTaskOverview(sharedPage.rows[0].record["id"].string) }
        let userRow = try db.get("Users",key:["id":.text(actor.identity.id)])!
        _ = try db.update(userRow,changes:["banned":.integer(1)],actor:identity.id)
        try rejects("banned actor") { _ = try actor.projectTaskPage(ProjectTaskQuery(scope:.readable)) }
        print("ProjectTaskOverviewTests: \(checks) checks passed; \(fixtures.count) original-action clock/timezone fixtures")
    }
}
