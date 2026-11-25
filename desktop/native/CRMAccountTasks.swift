import Foundation

struct CRMTaskParent: Equatable {
    let model: String; let id: String
    var field: String? { model == "crm_Accounts" ? "account" : model == "crm_Opportunities" ? "opportunity_id" : nil }
}
enum CRMTaskSort: String, CaseIterable { case createdAt, title, dueDateAt, priority, taskStatus
    var label: String { switch self { case .createdAt: return "作成日"; case .title: return "タスク名"; case .dueDateAt: return "期限"; case .priority: return "優先度"; case .taskStatus: return "状態" } }
}
struct CRMTaskQuery {
    var parent: CRMTaskParent?
    var assigneeID: String?
    var search = ""
    var status: String?
    var priority: String?
    var sort: CRMTaskSort = .createdAt
    var descending = true
}
struct CRMTaskAccess { let task: NativeRecord; let canEdit: Bool; let canDelete: Bool }
struct CRMTaskSummary { let record: NativeRecord; let cells: [String]; let canEdit: Bool; let canDelete: Bool }

extension CRMService {
    static let crmTaskJobEvents = ["crm.task_assigned","crm.task_watched"]
    private func crmTaskRecord(_ id: String, write: Bool = false, deletion: Bool = false, expected: NativeRecord? = nil) throws -> NativeRecord {
        try assertAccess("crm_Accounts_Tasks",id:id,write:write,deletion:deletion)
        guard let task = try db.get("crm_Accounts_Tasks",key:["id":.text(id)]) else { throw NativeDBError.conflict }
        if let expected { guard expected.model == task.model, expected["id"] == task["id"], expected.revision == task.revision else { throw NativeDBError.conflict } }
        return task
    }
    private func crmTaskParent(_ parent: CRMTaskParent, write: Bool) throws -> NativeRecord {
        guard parent.field != nil else { throw NativeDBError.message("タスクの作成先は取引先または商談を選択してください。") }
        try assertAccess(parent.model,id:parent.id,write:write)
        guard let record = try db.get(parent.model,key:["id":.text(parent.id)]), record["deletedAt"] == .null else { throw NativeDBError.conflict }
        return record
    }
    func crmTaskAccess(_ id: String) throws -> CRMTaskAccess {
        try db.transaction {
            let task = try crmTaskRecord(id)
            return CRMTaskAccess(task:task,canEdit:(try? assertAccess(task.model,id:id,write:true)) != nil,
                canDelete:(try? assertAccess(task.model,id:id,write:true,deletion:true)) != nil)
        }
    }
    func crmTaskPage(_ query: CRMTaskQuery, offset: Int = 0) throws -> (rows:[CRMTaskSummary],total:Int) {
        try db.transaction {
            try authenticated()
            var filters = [scope("crm_Accounts_Tasks")]
            if let parent = query.parent { _ = try crmTaskParent(parent,write:false); filters.append(.equal(parent.field!,.text(parent.id))) }
            if let assignee = query.assigneeID { filters.append(.equal("user",.text(assignee))) }
            if let status = query.status {
                guard CRMModule.projectStates.contains(where:{$0.0 == status}) else { throw NativeDBError.message("状態の条件が不正です。") }
                filters.append(.equal("taskStatus",.text(status)))
            }
            if let priority = query.priority {
                guard CRMModule.crmTaskPriorities.contains(where:{$0.0 == priority}) else { throw NativeDBError.message("優先度の条件が不正です。") }
                filters.append(.equal("priority",.text(priority)))
            }
            // A list page never loads task bodies, tags or comment arrays.
            let page = try db.page("crm_Accounts_Tasks",fields:["title","user","dueDateAt","priority","taskStatus","account","opportunity_id","createdBy","createdAt"],search:query.search,offset:offset,filter:.every(filters),sort:query.sort.rawValue,descending:query.descending,localizedSort:true)
            var names: [String:String] = [:]
            let format = DateFormatter(); format.locale = Locale(identifier:"ja_JP"); format.dateFormat = "yyyy/MM/dd HH:mm"
            let iso = ISO8601DateFormatter(); let fractions = ISO8601DateFormatter(); fractions.formatOptions.insert(.withFractionalSeconds)
            let rows = try page.rows.map { task -> CRMTaskSummary in
                let id = task["user"].string
                if names[id] == nil { names[id] = id.isEmpty ? "未割り当て" : try referenceName("Users",id:id) }
                let date = fractions.date(from:task["dueDateAt"].string) ?? iso.date(from:task["dueDateAt"].string)
                let priority = CRMModule.crmTaskPriorities.first { $0.0 == task["priority"].string }?.1 ?? task["priority"].string
                let cells = [task["title"].string,names[id]!,date.map(format.string) ?? "未設定",priority,CRMModule.projectLabel(task["taskStatus"].string)]
                return CRMTaskSummary(record:task,cells:cells,canEdit:(try? assertAccess(task.model,id:task["id"].string,write:true)) != nil,canDelete:(try? assertAccess(task.model,id:task["id"].string,write:true,deletion:true)) != nil)
            }
            return (rows,page.total)
        }
    }
    private func crmTaskText(_ value: SQLValue, label: String, limit: Int) throws -> SQLValue {
        guard case let .text(text) = value, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf16.count <= limit else { throw NativeDBError.message("\(label)は1〜\(limit)文字で入力してください。") }
        return .text(text)
    }
    /// Parent scope is checked on creation. Subsequent edits use the CRM-task
    /// creator/assignee policy, independent of the account owner's authority.
    func saveCRMTask(parent: CRMTaskParent? = nil, original: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard input.keys.allSatisfy({["title","content","user","priority","dueDateAt"].contains($0)}) else { throw NativeDBError.message("変更できないタスク項目が含まれています。") }
            let current = try original.map { try crmTaskRecord($0["id"].string,write:true,expected:$0) }
            if let current, let parent { guard let field = parent.field, current[field] == .text(parent.id) else { throw NativeDBError.message("タスクの関連先が一致しません。") } }
            if current == nil { guard let parent else { throw NativeDBError.message("タスクを作成する取引先または商談を選択してください。") }; _ = try crmTaskParent(parent,write:true) }
            var values = input
            values["title"] = try crmTaskText(input["title"] ?? current?["title"] ?? .null,label:"タスク名",limit:255)
            // Preserve longer legacy bodies on unrelated edits; enforce the
            // original form's 500 UTF-16-unit limit on newly entered content.
            if current == nil || input["content"] != nil && input["content"] != current?["content"] {
                values["content"] = try crmTaskText(input["content"] ?? .null,label:"内容",limit:500)
            }
            let priority = input["priority"] ?? current?["priority"] ?? .text("medium")
            guard CRMModule.crmTaskPriorities.contains(where:{$0.0 == priority.string}) || current?["priority"] == priority else { throw NativeDBError.message("優先度を選択してください。") }
            values["priority"] = priority
            let assigned = identity.role == "partner" ? .text(identity.id) : input["user"] ?? current?["user"] ?? .text(identity.id)
            if current == nil || assigned != current?["user"] {
                guard let user = try db.get("Users",key:["id":assigned]),user["userStatus"] == .text("ACTIVE"),user["banned"] != .integer(1),["admin","manager","user","partner"].contains(user["role"].string) else { throw NativeDBError.message("有効な担当者を選択してください。") }
            }
            values["user"] = assigned; values["updatedBy"] = .text(identity.id)
            if let current { return try db.update(current,changes:values,actor:identity.id) }
            values["v"] = .integer(0); values["createdBy"] = .text(identity.id); values["taskStatus"] = .text("ACTIVE")
            values[parent!.field!] = .text(parent!.id)
            // Explicitly omitted deadlines stay unset instead of the schema's now().
            values["dueDateAt"] = input["dueDateAt"] ?? .null
            let task = try db.insert("crm_Accounts_Tasks",values:values,actor:identity.id)
            try enqueueCRMTaskNotices(task)
            return task
        }
    }
    func setCRMTaskStatus(_ expected: NativeRecord, status: String) throws -> NativeRecord {
        try db.transaction {
            guard CRMModule.projectStates.contains(where:{$0.0 == status}) else { throw NativeDBError.message("タスクの状態が不正です。") }
            let task = try crmTaskRecord(expected["id"].string,write:true,expected:expected)
            return try db.update(task,changes:["taskStatus":.text(status),"updatedBy":.text(identity.id)],actor:identity.id)
        }
    }
    func crmTaskComments(taskID: String, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try db.transaction {
            try assertAccess("crm_Accounts_Tasks",id:taskID)
            return try db.page("tasksComments",fields:["comment","createdAt","user","assigned_crm_account_task"],equal:["assigned_crm_account_task":.text(taskID)],offset:offset,sort:"createdAt",descending:true,insertionOrderForTies:true)
        }
    }
    func addCRMTaskComment(taskID: String, comment: String) throws -> NativeRecord {
        try db.transaction {
            _ = try crmTaskRecord(taskID,write:true)
            guard !comment.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeDBError.message("コメントを入力してください。") }
            return try db.insert("tasksComments",values:["v":.integer(0),"assigned_crm_account_task":.text(taskID),"comment":.text(comment),"user":.text(identity.id)],actor:identity.id)
        }
    }
    func deleteCRMTask(_ expected: NativeRecord) throws {
        try db.transaction {
            let task = try crmTaskRecord(expected["id"].string,write:true,deletion:true,expected:expected)
            for (model,field) in [("tasksComments","assigned_crm_account_task"),("DocumentsToCrmAccountsTasks","crm_accounts_task_id")] {
                while true {
                    let rows = try db.page(model,fields:try db.schema.model(model).fields.map(\.name),equal:[field:task["id"]]).rows
                    if rows.isEmpty { break }
                    for row in rows { try db.remove(row,actor:identity.id,action:"delete") }
                }
            }
            try db.remove(task,actor:identity.id,action:"delete")
        }
    }
    private func enqueueCRMTaskNotices(_ task: NativeRecord) throws {
        let actor = try db.page("Users",fields:["name"],equal:["id":.text(identity.id)]).rows.first
        func enqueue(_ id: String, event: String) throws {
            guard id != identity.id, !id.isEmpty, let user = try db.page("Users",fields:["email"],equal:["id":.text(id)]).rows.first,!user["email"].string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
            try db.enqueue(event,payload:["taskId":task["id"].string,"accountId":task["account"].string,"opportunityId":task["opportunity_id"].string,
                "recipientId":id,"recipientEmail":user["email"].string,"actorId":identity.id,"actorName":actor?["name"].string ?? "担当者","taskTitle":task["title"].string])
        }
        let assigned = task["user"].string
        try enqueue(assigned,event:"crm.task_assigned")
        // A recipient who is both assignee and watcher receives one notice.
        if task["account"] != .null {
            var offset = 0
            while true {
                let page = try db.page("AccountWatchers",fields:["user_id"],equal:["account_id":task["account"]],offset:offset,filter:.not(.equal("user_id",.text(assigned))))
                for row in page.rows { try enqueue(row["user_id"].string,event:"crm.task_watched") }
                offset += page.rows.count; if page.rows.isEmpty || offset >= page.total { break }
            }
        }
    }
}
