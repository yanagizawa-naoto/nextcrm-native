import Foundation

extension CRMService {
    static let projectJobEvents = ["projects.task_assigned","projects.task_updated","projects.task_commented"]
    /// The outbox stores small event metadata, not one copy of a potentially
    /// large task/comment body per watcher. Comments are resolved at delivery.
    private func enqueueProjectNotice(_ event: String, task: NativeRecord, boardID: String, recipientID: String, comment: NativeRecord? = nil) throws {
        guard !recipientID.isEmpty, recipientID != identity.id,
              let recipient = try db.page("Users",fields:["email"],equal:["id":.text(recipientID)]).rows.first,
              !recipient["email"].string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        let board = try db.page("Boards",fields:["title"],equal:["id":.text(boardID)]).rows.first
        let actor = try db.page("Users",fields:["name"],equal:["id":.text(identity.id)]).rows.first
        var payload = ["taskId":task["id"].string,"boardId":boardID,"recipientId":recipientID,"recipientEmail":recipient["email"].string,
                       "actorId":identity.id,"actorName":actor?["name"].string ?? "担当者","taskTitle":task["title"].string,"boardTitle":board?["title"].string ?? "プロジェクト"]
        if let comment { payload["commentId"] = comment["id"].string; payload["commentRevision"] = String(comment.revision) }
        try db.enqueue(event,payload:payload)
    }
}

extension CRMService {
    private func projectRecord(_ model: String, _ id: String, write: Bool = false, expected: NativeRecord? = nil) throws -> NativeRecord {
        try assertAccess(model,id:id,write:write)
        guard let record = try db.get(model,key:["id":.text(id)]) else { throw NativeDBError.conflict }
        if let expected { guard expected.model == model, expected["id"] == record["id"], expected.revision == record.revision else { throw NativeDBError.conflict } }
        return record
    }
    private func projectTitle(_ value: SQLValue, label: String) throws -> SQLValue {
        let text = value.string.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { throw NativeDBError.message("\(label)は1〜500文字で入力してください。") }
        return .text(text)
    }
    private func projectUser(_ id: SQLValue) throws {
        guard let user = try db.get("Users",key:["id":id]), user["userStatus"] == .text("ACTIVE"), user["banned"] != .integer(1),
              ["admin","manager","user"].contains(user["role"].string) else { throw NativeDBError.message("有効な内部利用者を選択してください。") }
    }
    private func touchProject(_ id: SQLValue) throws {
        guard let board = try db.get("Boards",key:["id":id]), board["deletedAt"] == .null else { throw NativeDBError.conflict }
        _ = try db.update(board,changes:["updatedBy":.text(identity.id)],actor:identity.id)
    }
    func saveProject(original: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard identity.elevated || identity.role == "user", input.keys.allSatisfy({ ["title","description","visibility"].contains($0) }) else { throw NativeDBError.message("プロジェクトを変更する権限がありません。") }
            let current = try original.map { try projectRecord("Boards",$0["id"].string,write:true,expected:$0) }
            var values = input
            values["title"] = try projectTitle(input["title"] ?? current?["title"] ?? .null,label:"プロジェクト名")
            let description = input["description"] ?? current?["description"] ?? .null
            guard !description.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeDBError.message("説明を入力してください。") }
            values["description"] = description
            let visibility = input["visibility"] ?? current?["visibility"] ?? .text("private")
            guard ["private","public"].contains(visibility.string) else { throw NativeDBError.message("公開範囲を選択してください。") }
            values["visibility"] = visibility; values["updatedBy"] = .text(identity.id)
            if let current { return try db.update(current,changes:values,actor:identity.id) }
            values["v"] = .integer(0); values["user"] = .text(identity.id); values["createdBy"] = .text(identity.id)
            values["sharedWith"] = .text(String(decoding:try JSONEncoder().encode([identity.id]),as:UTF8.self))
            values["position"] = .integer(Int64(try db.page("Boards",fields:[],includeDeleted:true).total))
            let board = try db.insert("Boards",values:values,actor:identity.id)
            _ = try db.insert("Sections",values:["v":.integer(0),"board":board["id"],"title":.text("未着手"),"position":.integer(0)],actor:identity.id)
            return board
        }
    }
    func setProjectShared(_ expected: NativeRecord, userID: String, shared: Bool) throws -> NativeRecord {
        try db.transaction {
            let board = try projectRecord("Boards",expected["id"].string,write:true,expected:expected)
            if shared { try projectUser(.text(userID)) }
            var users = try JSONDecoder().decode([String].self,from:Data(board["sharedWith"].string.utf8))
            if shared && !users.contains(userID) { users.append(userID) }
            if !shared { users.removeAll { $0 == userID && $0 != board["user"].string } }
            let encoded = String(decoding:try JSONEncoder().encode(users),as:UTF8.self)
            if board["sharedWith"] == .text(encoded) { return board }
            return try db.update(board,changes:["sharedWith":.text(encoded),"updatedBy":.text(identity.id)],actor:identity.id)
        }
    }
    func projectIsWatched(_ boardID: String) throws -> Bool {
        try assertAccess("Boards",id:boardID)
        return try db.get("BoardWatchers",key:["board_id":.text(boardID),"user_id":.text(identity.id)]) != nil
    }
    func watchProject(_ boardID: String, enabled: Bool) throws {
        try db.transaction {
            try assertAccess("Boards",id:boardID)
            let key: [String:SQLValue] = ["board_id":.text(boardID),"user_id":.text(identity.id)]
            if let existing = try db.get("BoardWatchers",key:key) { if !enabled { try db.remove(existing,actor:identity.id) } }
            else if enabled { _ = try db.insert("BoardWatchers",values:key,actor:identity.id) }
        }
    }
    func projectSections(_ boardID: String, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try db.transaction {
            try assertAccess("Boards",id:boardID)
            return try db.page("Sections",fields:["title","board","position"],equal:["board":.text(boardID)],offset:offset,sort:"position")
        }
    }
    func saveProjectSection(boardID: String, original: NativeRecord?, title: String) throws -> NativeRecord {
        try db.transaction {
            _ = try projectRecord("Boards",boardID,write:true)
            let title = try projectTitle(.text(title),label:"セクション名")
            let result: NativeRecord
            if let original {
                let section = try projectRecord("Sections",original["id"].string,write:true,expected:original)
                guard section["board"] == .text(boardID) else { throw NativeDBError.message("プロジェクトが一致しません。") }
                result = try db.update(section,changes:["title":title],actor:identity.id)
            } else {
                result = try db.insert("Sections",values:["v":.integer(0),"title":title,"board":.text(boardID),"position":.integer(try db.nextProjectPosition("Sections",parentID:.text(boardID)))],actor:identity.id)
            }
            try touchProject(.text(boardID)); return result
        }
    }
    func projectTasks(sectionID: String, search: String = "", status: String? = nil, offset: Int = 0) throws -> (rows:[CRMListRow],total:Int) {
        try db.transaction {
            try assertAccess("Sections",id:sectionID)
            return try list(CRMModule.projectTask,search:search,offset:offset,matching:.every([.equal("section",.text(sectionID)),status.map { .equal("taskStatus",.text($0)) } ?? .all]))
        }
    }
    func saveProjectTask(sectionID: String, original: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            let section = try projectRecord("Sections",sectionID,write:true)
            guard input.keys.allSatisfy({ ["title","content","user","priority","dueDateAt"].contains($0) }) else { throw NativeDBError.message("変更できないタスク項目が含まれています。") }
            let current = try original.map { try projectRecord("Tasks",$0["id"].string,write:true,expected:$0) }
            guard current == nil || current?["section"] == section["id"] else { throw NativeDBError.message("セクションが一致しません。移動操作を使用してください。") }
            var values = input
            values["title"] = try projectTitle(input["title"] ?? current?["title"] ?? .null,label:"タスク名")
            let priority = input["priority"] ?? current?["priority"] ?? .text("normal")
            guard CRMModule.projectPriorities.contains(where:{$0.0 == priority.string}) else { throw NativeDBError.message("優先度を選択してください。") }
            values["priority"] = priority
            let assigned = input["user"] ?? current?["user"] ?? .text(identity.id)
            if assigned != .null, assigned != current?["user"] { try projectUser(assigned) }
            values["user"] = assigned; values["updatedBy"] = .text(identity.id)
            let result: NativeRecord
            if let current { result = try db.update(current,changes:values,actor:identity.id) }
            else {
                values["v"] = .integer(0); values["section"] = section["id"]; values["createdBy"] = .text(identity.id)
                values["taskStatus"] = .text("ACTIVE"); values["position"] = .integer(try db.nextProjectPosition("Tasks",parentID:section["id"]))
                result = try db.insert("Tasks",values:values,actor:identity.id)
            }
            try touchProject(section["board"])
            try enqueueProjectNotice(current == nil ? "projects.task_assigned" : "projects.task_updated",task:result,boardID:section["board"].string,recipientID:assigned.string)
            return result
        }
    }
    /// The assignee exception grants status changes only, never content/ownership/move.
    func setProjectTaskStatus(_ expected: NativeRecord, status: String) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard expected.model == "Tasks", CRMModule.projectStates.contains(where:{$0.0 == status}),
                  let task = try db.get("Tasks",key:["id":expected["id"]]), task.revision == expected.revision,
                  let section = try db.get("Sections",key:["id":task["section"]]),
                  let board = try db.get("Boards",key:["id":section["board"]]), board["deletedAt"] == .null else { throw NativeDBError.conflict }
            if !(identity.role == "user" && task["user"] == .text(identity.id)) { try assertAccess("Boards",id:board["id"].string,write:true) }
            let result = try db.update(task,changes:["taskStatus":.text(status),"updatedBy":.text(identity.id)],actor:identity.id)
            try touchProject(board["id"]); return result
        }
    }
    func moveProjectTask(_ expected: NativeRecord, to sectionID: String) throws -> NativeRecord {
        try db.transaction {
            let task = try projectRecord("Tasks",expected["id"].string,write:true,expected:expected)
            let oldSection = try projectRecord("Sections",task["section"].string,write:true)
            let destination = try projectRecord("Sections",sectionID,write:true)
            if destination["id"] == oldSection["id"] { return task }
            let result = try db.update(task,changes:["section":destination["id"],"position":.integer(try db.nextProjectPosition("Tasks",parentID:destination["id"])),"updatedBy":.text(identity.id)],actor:identity.id,action:"reorder")
            try touchProject(oldSection["board"])
            if oldSection["board"] != destination["board"] { try touchProject(destination["board"]) }
            return result
        }
    }
    func reorderProject(_ expected: NativeRecord, direction: Int) throws -> Bool {
        try db.transaction {
            guard ["Sections","Tasks"].contains(expected.model) else { throw NativeDBError.message("並べ替えの種類が不正です。") }
            let item = try projectRecord(expected.model,expected["id"].string,write:true,expected:expected)
            let changed = try db.reorderProjectItem(item,direction:direction,actor:identity.id)
            if changed {
                let boardID = item.model == "Sections" ? item["board"] : try projectRecord("Sections",item["section"].string)["board"]
                try touchProject(boardID)
            }
            return changed
        }
    }
    func projectComments(taskID: String, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        try db.transaction {
            try assertAccess("Tasks",id:taskID)
            return try db.page("tasksComments",fields:["comment","createdAt","user","task"],equal:["task":.text(taskID)],offset:offset,sort:"createdAt",descending:true,insertionOrderForTies:true)
        }
    }
    func addProjectComment(taskID: String, comment: String) throws -> NativeRecord {
        try db.transaction {
            let task = try projectRecord("Tasks",taskID,write:true)
            guard !comment.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeDBError.message("コメントを入力してください。") }
            let section = try projectRecord("Sections",task["section"].string,write:true)
            try watchProject(section["board"].string,enabled:true)
            let result = try db.insert("tasksComments",values:["v":.integer(0),"comment":.text(comment),"task":task["id"],"user":.text(identity.id)],actor:identity.id)
            try touchProject(section["board"])
            let creator = task["createdBy"].string; var offset = 0
            while true {
                let page = try db.page("BoardWatchers",fields:["user_id"],equal:["board_id":section["board"]],offset:offset,
                    filter:.every([.not(.equal("user_id",.text(identity.id))),.not(.equal("user_id",.text(creator)))]))
                for row in page.rows { try enqueueProjectNotice("projects.task_commented",task:task,boardID:section["board"].string,recipientID:row["user_id"].string,comment:result) }
                offset += page.rows.count; if page.rows.isEmpty || offset >= page.total { break }
            }
            try enqueueProjectNotice("projects.task_commented",task:task,boardID:section["board"].string,recipientID:creator,comment:result)
            return result
        }
    }
    private func removeProjectTaskStorage(_ task: NativeRecord) throws {
        for (model,field) in [("tasksComments","task"),("DocumentsToTasks","task_id")] {
            while true {
                let rows = try db.page(model,fields:try db.schema.model(model).fields.map(\.name),equal:[field:task["id"]]).rows
                if rows.isEmpty { break }
                for row in rows { try db.remove(row,actor:identity.id,action:"delete") }
            }
        }
        try db.remove(task,actor:identity.id,action:"delete")
    }
    func deleteProjectTask(_ expected: NativeRecord) throws {
        try db.transaction {
            let task = try projectRecord("Tasks",expected["id"].string,write:true,expected:expected)
            let section = try projectRecord("Sections",task["section"].string,write:true)
            try removeProjectTaskStorage(task); try touchProject(section["board"])
        }
    }
    func deleteProjectSection(_ expected: NativeRecord) throws {
        try db.transaction {
            let section = try projectRecord("Sections",expected["id"].string,write:true,expected:expected)
            while true {
                let rows = try db.page("Tasks",fields:[],equal:["section":section["id"]]).rows
                if rows.isEmpty { break }
                for summary in rows {
                    guard let task = try db.get("Tasks",key:["id":summary["id"]]) else { throw NativeDBError.conflict }
                    try removeProjectTaskStorage(task)
                }
            }
            try db.remove(section,actor:identity.id,action:"delete"); try touchProject(section["board"])
        }
    }
}
