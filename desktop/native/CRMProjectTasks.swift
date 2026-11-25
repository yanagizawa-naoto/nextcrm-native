import Foundation

enum ProjectTaskScope: Equatable { case readable, assigned(String), deadlines }
enum ProjectTaskDue: String, CaseIterable { case all, overdue, week
    var label: String { switch self { case .all: return "期限すべて"; case .overdue: return "期限超過"; case .week: return "本日から7日未満" } }
}
enum ProjectTaskSort: String, CaseIterable { case createdAt, title, dueDateAt, priority, taskStatus
    var label: String { switch self { case .createdAt: return "作成日"; case .title: return "タスク名"; case .dueDateAt: return "期限"; case .priority: return "優先度"; case .taskStatus: return "状態" } }
}
struct ProjectTaskQuery {
    var scope: ProjectTaskScope = .readable
    var due: ProjectTaskDue = .all
    var search = ""
    var statuses: [String] = []
    var priorities: [String] = []
    var sort: ProjectTaskSort = .createdAt
    var descending = true
}
struct ProjectTaskAccess {
    let task: NativeRecord; let board: NativeRecord?
    let canEdit: Bool; let canChangeStatus: Bool; let canReadComments: Bool
}
struct ProjectTaskSummary {
    let record: NativeRecord; let cells: [String]
    let canEdit: Bool; let canChangeStatus: Bool; let canReadComments: Bool; let boardID: String?
}
struct ProjectTaskPage { let rows: [ProjectTaskSummary]; let total: Int }
struct ProjectDeadlineRange {
    let now: Date; let start: Date; let end: Date
    init(now: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = timeZone
        self.now = now; start = calendar.startOfDay(for:now); end = calendar.date(byAdding:.day,value:7,to:start)!
    }
    static func stamp(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f.string(from:date) }
    var weekFilter: RecordFilter { .every([.compareDate("dueDateAt",.greater,Self.stamp(start)),.compareDate("dueDateAt",.less,Self.stamp(end))]) }
}

extension CRMService {
    private var liveProjectTask: RecordFilter {
        .relation(model:"Sections",local:"section",foreign:"id",matching:.relation(model:"Boards",local:"board",foreign:"id",matching:.equal("deletedAt",.null)))
    }
    private func projectTaskFilter(_ query: ProjectTaskQuery, now: Date, timeZone: TimeZone) throws -> RecordFilter {
        try authenticated()
        guard identity.elevated || identity.role == "user" else { throw NativeDBError.message("タスクを表示する権限がありません。") }
        guard query.statuses.allSatisfy({ s in CRMModule.projectStates.contains { $0.0 == s } }),
              query.priorities.allSatisfy({ p in CRMModule.projectPriorities.contains { $0.0 == p } }) else { throw NativeDBError.message("タスクの絞り込み条件が不正です。") }
        let access: RecordFilter
        switch query.scope {
        case .readable: access = scope("Tasks")
        case let .assigned(id):
            guard identity.elevated || id == identity.id else { throw NativeDBError.message("他の利用者の担当タスクを表示する権限がありません。") }
            access = .equal("user",.text(id))
        case .deadlines: access = identity.elevated ? .all : .equal("user",.text(identity.id))
        }
        var filters: [RecordFilter] = [liveProjectTask,access]
        if !query.statuses.isEmpty { filters.append(.any(query.statuses.map { .equal("taskStatus",.text($0)) })) }
        if !query.priorities.isEmpty { filters.append(.any(query.priorities.map { .equal("priority",.text($0)) })) }
        if query.due != .all {
            // Preserve getTasksPastDue's inclusive "now" and exclusive week bounds.
            // Today's earlier deadlines therefore intentionally appear in both lists.
            filters.append(.not(.equal("taskStatus",.text("COMPLETE"))))
            let range = ProjectDeadlineRange(now:now,timeZone:timeZone)
            filters.append(query.due == .overdue ? .compareDate("dueDateAt",.lessOrEqual,ProjectDeadlineRange.stamp(now)) : range.weekFilter)
        }
        return .every(filters)
    }
    /// Assigned tasks expose the task's own fields, as getUserTasks does. This
    /// grants no access to the private board, comments, documents, or full edits.
    func projectTaskOverview(_ taskID: String) throws -> ProjectTaskAccess {
        try db.transaction {
            try authenticated()
            guard identity.elevated || identity.role == "user" else { throw NativeDBError.message("タスクを表示する権限がありません。") }
            let own: RecordFilter = identity.role == "user" ? .equal("user",.text(identity.id)) : .none
            guard try db.page("Tasks",fields:[],filter:.every([.equal("id",.text(taskID)),liveProjectTask,.any([scope("Tasks"),own])])).total == 1,
                  let task = try db.get("Tasks",key:["id":.text(taskID)]),
                  let section = try db.get("Sections",key:["id":task["section"]]),
                  let board = try db.get("Boards",key:["id":section["board"]]) else { throw NativeDBError.message("対象が見つからないか、表示する権限がありません。") }
            let readable = (try? assertAccess("Boards",id:board["id"].string)) != nil
            let editable = readable && (identity.elevated || board["user"] == .text(identity.id))
            return ProjectTaskAccess(task:task,board:readable ? board : nil,canEdit:editable,canChangeStatus:editable || task["user"] == .text(identity.id),canReadComments:readable)
        }
    }
    func projectTaskPage(_ query: ProjectTaskQuery, offset: Int = 0, now: Date = Date(), timeZone: TimeZone = .current) throws -> ProjectTaskPage {
        try db.transaction {
            let filter = try projectTaskFilter(query,now:now,timeZone:timeZone)
            let fields = ["title","user","dueDateAt","priority","taskStatus","section","createdAt"]
            let page = try db.page("Tasks",fields:fields,search:query.search,offset:offset,filter:filter,sort:query.sort.rawValue,descending:query.descending,localizedSort:true)
            // Only the current page's small relationship projections are cached.
            var boards: [String:NativeRecord] = [:]; var sectionBoards: [String:String] = [:]; var names: [String:String] = [:]; var readable: [String:Bool] = [:]
            let date = DateFormatter(); date.locale = Locale(identifier:"ja_JP"); date.timeZone = timeZone; date.dateFormat = "yyyy/MM/dd HH:mm"
            let iso = ISO8601DateFormatter(); let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
            let rows = try page.rows.map { task -> ProjectTaskSummary in
                let sectionID = task["section"].string
                let boardID: String
                if let cached = sectionBoards[sectionID] { boardID = cached }
                else { guard let section = try db.get("Sections",key:["id":task["section"]]) else { throw NativeDBError.conflict }; boardID = section["board"].string; sectionBoards[sectionID] = boardID }
                let board: NativeRecord
                if let cached = boards[boardID] { board = cached }
                else { guard let found = try db.page("Boards",fields:["user"],equal:["id":.text(boardID)]).rows.first else { throw NativeDBError.conflict }; board = found; boards[boardID] = found }
                let canRead: Bool
                if let cached = readable[boardID] { canRead = cached }
                else { canRead = (try? assertAccess("Boards",id:boardID)) != nil; readable[boardID] = canRead }
                let canEdit = canRead && (identity.elevated || board["user"] == .text(identity.id))
                let userID = task["user"].string
                if names[userID] == nil { names[userID] = userID.isEmpty ? "未割り当て" : try referenceName("Users",id:userID) }
                let parsed = fractional.date(from:task["dueDateAt"].string) ?? iso.date(from:task["dueDateAt"].string)
                let cells = [task["title"].string,names[userID]!,parsed.map(date.string) ?? "未設定",CRMModule.projectLabel(task["priority"].string),CRMModule.projectLabel(task["taskStatus"].string)]
                return ProjectTaskSummary(record:task,cells:cells,canEdit:canEdit,canChangeStatus:canEdit || task["user"] == .text(identity.id),canReadComments:canRead,boardID:canRead ? boardID : nil)
            }
            return ProjectTaskPage(rows:rows,total:page.total)
        }
    }
    func createProjectTaskInBoard(_ boardID: String, input: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            try assertAccess("Boards",id:boardID,write:true)
            guard let section = try projectSections(boardID).rows.first else { throw NativeDBError.message("このプロジェクトにセクションを追加してからタスクを作成してください。") }
            return try saveProjectTask(sectionID:section["id"].string,original:nil,input:input)
        }
    }
}
