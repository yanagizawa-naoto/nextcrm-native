import Foundation

/// The original project association action changes a task's junction, not the
/// document itself. Document read permission is sufficient for this operation.
/// General document editing, deletion and version guards stay unchanged.
extension CRMService {
    func projectDocumentTask(_ id: String) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard identity.elevated || identity.role == "user",
                  let task = try db.page("Tasks",fields:["user","section"],equal:["id":.text(id)],limit:1).rows.first,
                  let section = try db.page("Sections",fields:["board"],equal:["id":task["section"]],limit:1).rows.first,
                  let board = try db.page("Boards",fields:["user","deletedAt"],equal:["id":section["board"]],limit:1).rows.first,
                  board["deletedAt"] == .null else { throw NativeDBError.message("タスクが見つからないか、関連付けを変更する権限がありません。") }
            // Current native live-parent protection is deliberately retained.
            // The source's assignee shortcut otherwise bypasses board-write.
            if !(identity.role == "user" && task["user"] == .text(identity.id)) {
                try assertAccess("Boards",id:board["id"].string,write:true)
            }
            return task
        }
    }

    @discardableResult
    func setProjectTaskDocumentLink(_ expectedDocument: NativeRecord, task expectedTask: NativeRecord, linked: Bool) throws -> NativeRecord {
        try db.transaction {
            guard expectedDocument.model == "Documents", expectedTask.model == "Tasks" else { throw NativeDBError.conflict }
            let task = try projectDocumentTask(expectedTask["id"].string)
            guard task.revision == expectedTask.revision else { throw NativeDBError.conflict }
            try assertAccess("Documents",id:expectedDocument["id"].string)
            guard let document = try db.page("Documents",fields:[],equal:["id":expectedDocument["id"]],limit:1).rows.first,
                  document.revision == expectedDocument.revision else { throw NativeDBError.conflict }
            let key = ["document_id":document["id"],"task_id":task["id"]]
            let current = try db.get("DocumentsToTasks",key:key)
            if linked {
                guard current == nil else { throw NativeDBError.message("この文書はすでに関連付けられています。再読み込みしてください。") }
                _ = try db.insert("DocumentsToTasks",values:key,actor:identity.id)
            } else {
                guard let current else { throw NativeDBError.message("この文書の関連付けはすでに解除されています。再読み込みしてください。") }
                try db.remove(current,actor:identity.id)
            }
            // Original action updates only the task, never document ownership
            // or content. The same outer transaction owns this update/audit.
            return try db.update(task,changes:["updatedBy":.text(identity.id)],actor:identity.id)
        }
    }
}
