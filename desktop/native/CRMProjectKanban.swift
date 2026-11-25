import Foundation

struct ProjectKanbanColumn {
    let section: NativeRecord
    let rows: [CRMListRow]
    let total: Int
    let offset: Int
    let following: NativeRecord?
}
struct ProjectKanbanPage {
    let project: NativeRecord
    let writable: Bool
    let columns: [ProjectKanbanColumn]
    let totalSections: Int
    let sectionOffset: Int
}

extension CRMService {
    /// Three columns, each with at most 100 small task projections. Task bodies
    /// and the rest of the board are only read when explicitly requested.
    func projectKanban(_ boardID: String, sectionOffset: Int = 0, taskOffsets: [String:Int] = [:]) throws -> ProjectKanbanPage {
        try db.transaction {
            try assertAccess("Boards",id:boardID)
            guard let board = try db.page("Boards",fields:["title","user"],equal:["id":.text(boardID)]).rows.first else { throw NativeDBError.conflict }
            let writable = (try? assertAccess("Boards",id:boardID,write:true)) != nil
            var start = max(0,sectionOffset)
            var sections = try db.page("Sections",fields:["title","board","position"],equal:["board":.text(boardID)],offset:start,sort:"position",limit:3)
            if sections.rows.isEmpty && start > 0 {
                start = max(0,(max(0,sections.total-1)/3)*3)
                sections = try db.page("Sections",fields:["title","board","position"],equal:["board":.text(boardID)],offset:start,sort:"position",limit:3)
            }
            let columns = try sections.rows.map { section -> ProjectKanbanColumn in
                let id = section["id"].string; var offset = max(0,taskOffsets[id] ?? 0)
                var page = try projectTasks(sectionID:id,offset:offset)
                if page.rows.isEmpty && offset > 0 {
                    offset = max(0,(max(0,page.total-1)/100)*100)
                    page = try projectTasks(sectionID:id,offset:offset)
                }
                let following = offset+page.rows.count < page.total ? try db.page("Tasks",fields:[],equal:["section":section["id"]],offset:offset+page.rows.count,sort:"position",descending:true,limit:1).rows.first : nil
                return ProjectKanbanColumn(section:section,rows:page.rows,total:page.total,offset:offset,following:following)
            }
            return ProjectKanbanPage(project:board,writable:writable,columns:columns,totalSections:sections.total,sectionOffset:start)
        }
    }

    /// `before == nil` appends at the bottom. A drop between paged rows uses
    /// the next row's identity, never a stale absolute index from the client.
    @discardableResult func placeProjectTask(_ expected: NativeRecord, in sectionID: String, before anchor: NativeRecord?, board expectedBoard: NativeRecord) throws -> Bool {
        try db.transaction {
            guard expected.model == "Tasks", expectedBoard.model == "Boards", anchor == nil || anchor?.model == "Tasks" else { throw NativeDBError.conflict }
            try assertAccess("Boards",id:expectedBoard["id"].string,write:true)
            guard let board = try db.get("Boards",key:["id":expectedBoard["id"]]), board.revision == expectedBoard.revision,
                  let task = try db.get("Tasks",key:["id":expected["id"]]), task.revision == expected.revision,
                  let source = try db.get("Sections",key:["id":task["section"]]), source["board"] == board["id"],
                  let destination = try db.get("Sections",key:["id":.text(sectionID)]), destination["board"] == board["id"] else { throw NativeDBError.conflict }
            try assertAccess("Tasks",id:task["id"].string,write:true)
            if let anchor {
                guard let current = try db.get("Tasks",key:["id":anchor["id"]]), current.revision == anchor.revision, current["section"] == destination["id"] else { throw NativeDBError.conflict }
                if current["id"] == task["id"] { return false }
            }
            let changed = try db.placeProjectTask(task,to:destination["id"],before:anchor?["id"],actor:identity.id)
            if changed { _ = try db.update(board,changes:["updatedBy":.text(identity.id)],actor:identity.id) }
            return changed
        }
    }
}
