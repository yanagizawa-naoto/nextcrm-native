import Foundation

extension CRMService {
    /// Original Kanban quick add, with native fresh authorization and atomic
    /// parent update. Existing sparse ordering uses max(position)+1 to append.
    @discardableResult
    func quickAddProjectTask(boardID: String, section expected: NativeRecord) throws -> NativeRecord {
        try db.transaction {
            try assertAccess("Boards",id:boardID,write:true)
            guard expected.model == "Sections",
                  let section = try db.get("Sections",key:["id":expected["id"]]),
                  section.revision == expected.revision, section["board"] == .text(boardID) else { throw NativeDBError.conflict }
            return try saveProjectTask(sectionID:section["id"].string,original:nil,input:["title":.text("タスクを追加"),"content":.text(""),"priority":.text("normal"),"user":.text(identity.id)])
        }
    }
}
