import Foundation

enum NativeMCPProjects {
    static let names: Set<String> = ["projects_list_boards", "projects_get_board", "projects_create_board", "projects_update_board", "projects_delete_board", "projects_create_section", "projects_update_section", "projects_delete_section", "projects_list_tasks", "projects_get_task", "projects_create_task", "projects_update_task", "projects_move_task", "projects_delete_task", "projects_add_comment", "projects_list_comments", "projects_assign_document", "projects_watch_board"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0) } })
        })
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, actor = service.identity.id
        func fields(_ model: String) throws -> [String] { try db.schema.model(model).fields.map(\.name) }
        func wire(_ row: NativeRecord) throws -> [String: Any] { try NativeMCPWire.record(row, schema: db.schema) }
        func raw(_ model: String, _ id: SQLValue) throws -> NativeRecord {
            guard id != .null, let row = try db.get(model, key: ["id": id]) else { throw NativeMCPFailure.notFound }; return row
        }
        func board(_ id: SQLValue, write: Bool = false) throws -> NativeRecord {
            guard id != .null, let row = try db.page("Boards", fields: fields("Boards"), equal: ["id": id], filter: service.scope("Boards", write: write), limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
        }
        func task(_ id: String, write: Bool = false, boardWrite: Bool = false) throws -> NativeRecord {
            let row = try raw("Tasks", .text(id)), section = try raw("Sections", row["section"])
            // Exact original assertCanWriteTask: an assigned internal user may
            // edit/comment/link even without board read/write access. A real
            // parent board must exist. Deletion has the stricter board gate.
            if write && !boardWrite && service.identity.role == "user" && row["user"] == .text(actor) {
                _ = try raw("Boards", section["board"]); return row
            }
            _ = try board(section["board"], write: write || boardWrite); return row
        }
        func input(_ keys: [String]) throws -> [String: SQLValue] {
            var values: [String: SQLValue] = [:]
            for key in keys where arguments[key] != nil {
                guard let text = arguments[key] as? String, !text.contains("\0") else { throw NativeMCPFailure.internalError }; values[key] = .text(text)
            }
            return values
        }
        func pagination() throws -> (limit: Int, offset: Int) {
            (try NativeMCPWire.integer(arguments["limit"], range: 1...100), try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max)))
        }
        func position(_ value: Any) throws -> SQLValue { .integer(Int64(try NativeMCPWire.integer(value, range: -9_007_199_254_740_991...9_007_199_254_740_991))) }
        func nextPosition(_ model: String, parent: SQLValue) throws -> SQLValue {
            let field = model == "Sections" ? "board" : "section"
            let page = try db.mcpPage(model, fields: ["position"], filter: .every([.equal(field, parent), .not(.equal("position", .null))]), limit: 1, offset: 0, order: [("position", true)])
            let last: Int64
            if let row = page.rows.first, case let .integer(value) = row["position"] { last = value } else { last = 0 }
            let (next, overflow) = last.addingReportingOverflow(1000)
            guard !overflow else { throw NativeMCPFailure.internalError }; return .integer(next)
        }
        func all(_ model: String, filter: RecordFilter, order: [(field: String, descending: Bool)]? = nil) throws -> [NativeRecord] {
            var rows: [NativeRecord] = [], offset = 0
            while true {
                try Task.checkCancellation()
                let page: (rows: [NativeRecord], total: Int)
                if let order { page = try db.mcpPage(model, fields: fields(model), filter: filter, limit: 100, offset: offset, order: order) }
                else { page = try db.page(model, fields: fields(model), includeDeleted: true, offset: offset, filter: filter) }
                rows += page.rows; if page.rows.count < 100 { return rows }; offset += page.rows.count
            }
        }
        func dateInput(_ key: String) throws -> SQLValue? {
            guard let text = arguments[key] as? String else { return nil }
            guard let date = NativeMCPWire.canonicalUTC(text) else { throw NativeMCPFailure.internalError }; return .text(date)
        }
        switch name {
        case "projects_list_boards":
            let p = try pagination(), page = try db.mcpPage("Boards", fields: fields("Boards"), filter: service.scope("Boards"), limit: p.limit, offset: p.offset)
            let data = try page.rows.map { row -> [String: Any] in
                var result = try wire(row); result["_count"] = ["sections": try db.page("Sections", fields: [], equal: ["board": row["id"]], limit: 1).total]; return result
            }
            return ["data": data, "total": page.total, "offset": p.offset]
        case "projects_get_board":
            let row = try board(.text(arguments["id"] as! String)); var result = try wire(row)
            result["sections"] = try all("Sections", filter: .equal("board", row["id"]), order: [("position", false)]).map { section -> [String: Any] in
                var data = try wire(section)
                data["tasks"] = try all("Tasks", filter: .every([.equal("section", section["id"]), .not(.equal("taskStatus", .text("COMPLETE")))]), order: [("position", false)]).map(wire)
                return data
            }
            result["watchers"] = try all("BoardWatchers", filter: .equal("board_id", row["id"])).map(wire)
            return ["data": result]
        case "projects_create_board":
            var values = try input(["title", "description", "icon", "visibility"])
            values.merge(["v": .integer(0), "user": .text(actor), "createdBy": .text(actor), "updatedBy": .text(actor)]) { _, new in new }
            return ["data": try wire(db.insert("Boards", values: values, actor: actor))]
        case "projects_update_board":
            let row = try board(.text(arguments["id"] as! String), write: true); var values = try input(["title", "description", "icon", "visibility"]); values["updatedBy"] = .text(actor)
            return ["data": try wire(db.update(row, changes: values, actor: actor))]
        case "projects_delete_board":
            let row = try db.setDeleted(board(.text(arguments["id"] as! String), write: true), deleted: true, actor: actor)
            return ["data": ["id": row["id"].string, "deletedAt": try NativeMCPWire.value(row["deletedAt"], field: db.schema.model("Boards").field("deletedAt")!)]]
        case "projects_create_section":
            let parent = try board(.text(arguments["board"] as! String), write: true)
            var values = try input(["title"]); values.merge(["v": .integer(0), "board": parent["id"], "position": try nextPosition("Sections", parent: parent["id"])]) { _, new in new }
            return ["data": try wire(db.insert("Sections", values: values, actor: actor))]
        case "projects_update_section":
            let row = try raw("Sections", .text(arguments["id"] as! String)); _ = try board(row["board"], write: true)
            var values = try input(["title"]); if let value = arguments["position"] { values["position"] = try position(value) }
            return ["data": try wire(db.update(row, changes: values, actor: actor))]
        case "projects_delete_section":
            let row = try raw("Sections", .text(arguments["id"] as! String)); _ = try board(row["board"], write: true)
            guard try db.page("Tasks", fields: [], equal: ["section": row["id"]], limit: 1).total == 0 else { throw NativeMCPFailure.conflict("Cannot delete section with tasks. Move or delete tasks first.") }
            try db.remove(row, actor: actor, action: "delete"); return ["data": ["id": row["id"].string, "deleted": true]]
        case "projects_list_tasks":
            let p = try pagination()
            var sectionFilters = [RecordFilter.relation(model: "Boards", local: "board", foreign: "id", matching: .every([service.scope("Boards"), .equal("deletedAt", .null)]))]
            if let id = arguments["board"] as? String { sectionFilters.append(.equal("board", .text(id))) }
            var filters = [RecordFilter.relation(model: "Sections", local: "section", foreign: "id", matching: .every(sectionFilters))]
            for (input, field) in [("section", "section"), ("user", "user"), ("status", "taskStatus")] { if let value = arguments[input] as? String { filters.append(.equal(field, .text(value))) } }
            let page = try db.mcpPage("Tasks", fields: fields("Tasks"), filter: .every(filters), limit: p.limit, offset: p.offset)
            return ["data": try page.rows.map(wire), "total": page.total, "offset": p.offset]
        case "projects_get_task":
            let row = try task(arguments["id"] as! String); var result = try wire(row)
            result["comments"] = try db.mcpPage("tasksComments", fields: fields("tasksComments"), filter: .equal("task", row["id"]), limit: 20, offset: 0, order: [("createdAt", true)]).rows.map(wire)
            result["documents"] = try all("DocumentsToTasks", filter: .equal("task_id", row["id"])).map { link -> [String: Any] in
                var data = try wire(link); data["document"] = try wire(raw("Documents", link["document_id"])); return data
            }
            let section = try raw("Sections", row["section"])
            result["assigned_section"] = ["id": section["id"].string, "title": section["title"].string, "board": section["board"].string]
            return ["data": result]
        case "projects_create_task":
            let section = try raw("Sections", .text(arguments["section"] as! String)); _ = try board(section["board"], write: true)
            var values = try input(["title", "content", "priority"])
            values.merge(["v": .integer(0), "section": section["id"], "position": try nextPosition("Tasks", parent: section["id"]), "user": .text(actor), "createdBy": .text(actor), "updatedBy": .text(actor)]) { _, new in new }
            if let date = try dateInput("dueDateAt") { values["dueDateAt"] = date }
            return ["data": try wire(db.insert("Tasks", values: values, actor: actor))]
        case "projects_update_task":
            let row = try task(arguments["id"] as! String, write: true); var values = try input(["title", "content", "priority", "taskStatus"])
            values["updatedBy"] = .text(actor); if let date = try dateInput("dueDateAt") { values["dueDateAt"] = date }
            return ["data": try wire(db.update(row, changes: values, actor: actor))]
        case "projects_move_task":
            let row = try task(arguments["id"] as! String, write: true), section = try raw("Sections", .text(arguments["section"] as! String)); _ = try board(section["board"], write: true)
            var values: [String: SQLValue] = ["section": section["id"], "updatedBy": .text(actor)]
            if let value = arguments["position"] { values["position"] = try position(value) }
            return ["data": try wire(db.update(row, changes: values, actor: actor))]
        case "projects_delete_task":
            let row = try task(arguments["id"] as! String, boardWrite: true)
            // Existing schema cascades comments and document junctions only.
            try db.remove(row, actor: actor, action: "delete"); return ["data": ["id": row["id"].string, "deleted": true]]
        case "projects_add_comment":
            let row = try task(arguments["task"] as! String, write: true); var values = try input(["comment"])
            values.merge(["v": .integer(0), "task": row["id"], "user": .text(actor)]) { _, new in new }
            return ["data": try wire(db.insert("tasksComments", values: values, actor: actor))]
        case "projects_list_comments":
            let row = try task(arguments["task"] as! String), p = try pagination()
            let page = try db.mcpPage("tasksComments", fields: fields("tasksComments"), filter: .equal("task", row["id"]), limit: p.limit, offset: p.offset)
            let data = try page.rows.map { comment -> [String: Any] in
                var data = try wire(comment)
                if let user = try db.page("Users", fields: ["name"], equal: ["id": comment["user"]], limit: 1).rows.first {
                    data["assigned_user"] = ["id": user["id"].string, "name": user["name"] == .null ? NSNull() : user["name"].string] as [String: Any]
                } else { data["assigned_user"] = NSNull() }
                return data
            }
            return ["data": data, "total": page.total, "offset": p.offset]
        case "projects_assign_document":
            let row = try task(arguments["task_id"] as! String, write: true)
            let document = try NativeMCPDocumentAccess.requireRead(arguments["document_id"] as! String, service: service)
            let values = ["task_id": row["id"], "document_id": document["id"]]
            _ = try db.insert("DocumentsToTasks", values: values, actor: actor)
            return ["data": values.mapValues(\.string)]
        case "projects_watch_board":
            let row = try board(.text(arguments["board_id"] as! String)), watching = arguments["watch"] as! Bool
            let key = ["board_id": row["id"], "user_id": SQLValue.text(actor)]
            // Source catches duplicate/missing watcher writes (and their other
            // storage errors), after checking board read authority first.
            try? db.transaction {
                if watching { _ = try db.insert("BoardWatchers", values: key, actor: actor) }
                else if let existing = try db.get("BoardWatchers", key: key) { try db.remove(existing, actor: actor) }
            }
            return ["data": ["board_id": row["id"].string, "watching": watching]]
        default: throw NativeMCPFailure.internalError
        }
    }
}
