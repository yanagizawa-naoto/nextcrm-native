import Foundation

/// Source MCP ownership rules intentionally differ from the document editor.
/// Signing is offline. Its ordinary failure leaves the created row, exactly as
/// the original create-then-presign handler; cancellation still rolls it back.
enum NativeMCPDocuments {
    static let names: Set<String> = ["crm_list_documents", "crm_get_document", "crm_create_document", "crm_get_upload_url", "crm_get_download_url", "crm_link_document", "crm_unlink_document", "crm_delete_document"]
    enum Outcome { case value(Any), signingFailure(Error) }
    static func handlers(storage: NativeMCPDocumentStorage) -> [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, { session, arguments in
                let result = try session.withAccess { try run(name, arguments: arguments, service: $0, storage: storage) }
                switch result { case .value(let value): return value; case .signingFailure(let error): throw error }
            })
        })
    }
    static let links: [String: (table: String, field: String, relation: String, model: String)] = [
        "account": ("DocumentsToAccounts", "account_id", "accounts", "crm_Accounts"),
        "contact": ("DocumentsToContacts", "contact_id", "contacts", "crm_Contacts"),
        "lead": ("DocumentsToLeads", "lead_id", "leads", "crm_Leads"),
        "opportunity": ("DocumentsToOpportunities", "opportunity_id", "opportunities", "crm_Opportunities"),
        "task": ("DocumentsToTasks", "task_id", "tasks", "Tasks"),
    ]
    static func run(_ name: String, arguments: [String: Any], service: CRMService, storage: NativeMCPDocumentStorage) throws -> Outcome {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, actor = service.identity.id, fields = try db.schema.model("Documents").fields.map(\.name)
        func wire(_ row: NativeRecord) throws -> [String: Any] { try NativeMCPWire.record(row, schema: db.schema) }
        func owned(_ id: String, live: Bool = false) throws -> NativeRecord {
            guard let row = try db.page("Documents", fields: fields, equal: ["id": .text(id), "created_by_user": .text(actor)], includeDeleted: !live, limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
        }
        func readable(_ id: String) throws -> NativeRecord { try NativeMCPDocumentAccess.requireRead(id, service: service, fields: fields) }
        func key(_ row: NativeRecord) throws -> String {
            guard row["key"] != .null, !row["key"].string.isEmpty else { throw NativeMCPFailure.validation("Document has no storage key") }; return row["key"].string
        }
        func canLink(_ type: String, _ id: String) throws {
            guard let spec = Self.links[type] else { throw NativeMCPFailure.validation("Invalid entity type: " + type) }
            if type == "task" {
                guard let task = try db.get("Tasks", key: ["id": .text(id)]), task["section"] != .null,
                      let section = try db.get("Sections", key: ["id": task["section"]]),
                      let board = try db.get("Boards", key: ["id": section["board"]]) else { throw NativeMCPFailure.forbidden }
                if service.identity.role == "user" && task["user"] == .text(actor) { return }
                guard board["deletedAt"] == .null, try db.page("Boards", fields: [], equal: ["id": board["id"]], filter: service.scope("Boards", write: true), limit: 1).total == 1 else { throw NativeMCPFailure.forbidden }
                return
            }
            // Account/contact write asserts include soft-deleted rows. Lead
            // and opportunity asserts explicitly require a live row.
            guard try db.page(spec.model, fields: [], equal: ["id": .text(id)], includeDeleted: type == "account" || type == "contact", filter: service.scope(spec.model, write: true), limit: 1).total == 1 else { throw NativeMCPFailure.forbidden }
        }
        switch name {
        case "crm_list_documents":
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            var scope = [NativeMCPDocumentAccess.readScope(service)]
            if let type = arguments["entityType"] as? String, let id = arguments["entityId"] as? String, let spec = Self.links[type] {
                scope.append(.relation(model: spec.table, local: "id", foreign: "document_id", matching: .equal(spec.field, .text(id))))
            }
            let page = try db.mcpPage("Documents", fields: fields, filter: .every(scope), limit: limit, offset: offset)
            return .value(["data": try page.rows.map(wire), "total": page.total, "offset": offset])
        case "crm_get_document":
            let document = try readable(arguments["id"] as! String); var result = try wire(document)
            for spec in Self.links.values {
                var rows: [[String: Any]] = [], offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try db.page(spec.table, fields: db.schema.model(spec.table).fields.map(\.name), equal: ["document_id": document["id"]], offset: offset)
                    rows += try page.rows.map(wire); if page.rows.count < 100 { break }; offset += page.rows.count
                }
                result[spec.relation] = rows
            }
            return .value(["data": result])
        case "crm_create_document":
            let type = arguments["contentType"] as! String
            guard let ext = NativeMCPDocumentStorage.uploadExtensions[type] else { throw NativeMCPFailure.validation("Content type not allowed: " + type) }
            let objectKey = "documents/" + UUID().uuidString.lowercased() + "." + ext
            var values: [String: SQLValue] = ["document_file_mimeType": .text(type), "document_file_url": .text(storage.publicURL + "/" + storage.bucket + "/" + objectKey), "key": .text(objectKey), "created_by_user": .text(actor), "createdBy": .text(actor), "processing_status": .text("PENDING")]
            for field in ["document_name", "description", "visibility"] where arguments[field] != nil {
                guard let text = arguments[field] as? String, !text.contains("\0") else { throw NativeMCPFailure.internalError }; values[field] = .text(text)
            }
            let document = try db.insert("Documents", values: values, actor: actor)
            // Catch only provider signing here: validation, authorization and
            // database failures must throw before this result can commit.
            let url: String
            do { url = try storage.presignPut(objectKey, contentType: type) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); return .signingFailure(error) }
            try Task.checkCancellation()
            var result = try wire(document); result["presignedUrl"] = url; result["expiresIn"] = 600
            return .value(["data": result])
        case "crm_get_upload_url", "crm_get_download_url":
            let upload = name == "crm_get_upload_url", document = try upload ? owned(arguments["id"] as! String) : readable(arguments["id"] as! String)
            let objectKey = try key(document)
            let url = try upload ? storage.presignPut(objectKey, contentType: document["document_file_mimeType"].string) : storage.presignGet(objectKey, expiresIn: 3600)
            try Task.checkCancellation()
            return .value(["data": ["id": document["id"].string, "url": url, "expiresIn": upload ? 600 : 3600]])
        case "crm_link_document", "crm_unlink_document":
            let document = try owned(arguments["document_id"] as! String), type = arguments["entityType"] as! String, entity = arguments["entityId"] as! String
            guard let spec = Self.links[type] else { throw NativeMCPFailure.validation("Invalid entity type: " + type) }
            try canLink(type, entity)
            let key = ["document_id": document["id"], spec.field: SQLValue.text(entity)]
            let unlink = name == "crm_unlink_document"
            if unlink {
                guard let row = try db.get(spec.table, key: key) else { throw NativeMCPFailure.internalError }
                try db.remove(row, actor: actor)
            } else { _ = try db.insert(spec.table, values: key, actor: actor) }
            var result: [String: Any] = ["document_id": document["id"].string, "entityType": type, "entityId": entity]
            if unlink { result["unlinked"] = true }; return .value(["data": result])
        case "crm_delete_document":
            let document = try db.setDeleted(owned(arguments["id"] as! String, live: true), deleted: true, actor: actor)
            return .value(["data": ["id": document["id"].string, "deletedAt": try NativeMCPWire.value(document["deletedAt"], field: db.schema.model("Documents").field("deletedAt")!)]])
        default: throw NativeMCPFailure.internalError
        }
    }
}
