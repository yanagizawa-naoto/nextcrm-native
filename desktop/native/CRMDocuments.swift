import Foundation

struct DocumentLink {
    let model: String; let id: String
    var junction: (model: String, field: String)? {
        switch model {
        case "crm_Accounts": return ("DocumentsToAccounts","account_id")
        case "crm_Contacts": return ("DocumentsToContacts","contact_id")
        case "crm_Leads": return ("DocumentsToLeads","lead_id")
        case "crm_Opportunities": return ("DocumentsToOpportunities","opportunity_id")
        case "Tasks": return ("DocumentsToTasks","task_id")
        case "crm_Accounts_Tasks": return ("DocumentsToCrmAccountsTasks","crm_accounts_task_id")
        default: return nil
        }
    }
}
struct DocumentQuery {
    var search = ""; var systemType: String?; var processing: String?; var favourites = false
    var linkedTo: DocumentLink?
    var id: String?
}

extension CRMService {
    static let documentSummaryFields = ["document_name","document_file_mimeType","size","version","date_created","createdAt","created_by_user","assigned_user","document_system_type","processing_status","favourite","parent_document_id","key"]
    private func documentDisplayRows(_ rows: [NativeRecord]) throws -> [NativeRecord] {
        guard let bucket=try db.metadata("document.storage.bucket") else { return rows }
        return try rows.map { row in
            guard let object=try db.documentObject(bucket:bucket,key:row["key"].string) else { return row }
            var values=row.values;values["size"] = .integer(object.bytes);values["document_file_mimeType"] = .text(object.contentType)
            return NativeRecord(model:row.model,values:values,revision:row.revision)
        }
    }
    private func documentWriter() throws {
        try authenticated(); guard identity.elevated || identity.role == "user" else { throw NativeDBError.message("文書を変更する権限がありません。") }
    }
    private func documentRoot(_ id: String, write: Bool = false, expected: NativeRecord? = nil) throws -> NativeRecord {
        try assertAccess("Documents",id:id,write:write)
        guard let record = try db.get("Documents",key:["id":.text(id)]), record["parent_document_id"] == .null else { throw NativeDBError.message("履歴の版は変更できません。現在の文書を開いてください。") }
        if let expected { guard expected.model == "Documents", expected["id"] == record["id"], expected.revision == record.revision else { throw NativeDBError.conflict } }
        return record
    }
    private func documentName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 500, !name.contains("\0") else { throw NativeDBError.message("文書名は1〜500文字で入力してください。") }; return name
    }
    private func documentParent(_ link: DocumentLink, write: Bool) throws -> (model: String, field: String) {
        guard let junction = link.junction else { throw NativeDBError.message("この項目には文書を関連付けられません。") }
        try assertAccess(link.model,id:link.id,write:write); return junction
    }
    func documentPage(_ query: DocumentQuery = DocumentQuery(), offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try db.transaction {
            try authenticated(); var conditions: [RecordFilter] = [scope("Documents"),.equal("parent_document_id",.null)]
            if let id = query.id { conditions.append(.equal("id", .text(id))) }
            if let type = query.systemType { conditions.append(.equal("document_system_type",.text(type))) }
            if let processing = query.processing { conditions.append(.equal("processing_status",.text(processing))) }
            if query.favourites { conditions.append(.equal("favourite",.integer(1))) }
            if let link = query.linkedTo {
                let junction = try documentParent(link,write:false)
                conditions.append(.relation(model:junction.model,local:"id",foreign:"document_id",matching:.equal(junction.field,.text(link.id))))
            }
            let page=try db.page("Documents",fields:Self.documentSummaryFields,search:query.search,offset:offset,filter:.every(conditions),sort:"date_created",descending:true)
            return (try documentDisplayRows(page.rows),page.total)
        }
    }
    func documentStorageBytes() throws -> Int64 { try db.transaction { try authenticated(); return try db.documentStorageBytes(filter:scope("Documents")) } }
    func documentVersions(_ id: String, offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try db.transaction {
            let imported=try hasImportedDocumentProof(id)
            if imported {_ = try importedDocumentAuthorize(id)}else{_ = try documentRoot(id)}
            let page=try db.page("Documents",fields:Self.documentSummaryFields,includeDeleted:imported,offset:offset,filter:.any([.equal("id",.text(id)),.equal("parent_document_id",.text(id))]),sort:"version",descending:true)
            return (try documentDisplayRows(page.rows),page.total)
        }
    }
    func documentRecord(_ id: String) throws -> NativeRecord {
        try db.transaction { if try hasImportedDocumentProof(id){return try importedDocumentRecord(id)};try assertAccess("Documents",id:id); guard let record = try db.get("Documents",key:["id":.text(id)]) else { throw NativeDBError.conflict }; return record }
    }
    func documentTextMetadata(_ id: String) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard let row = try db.keysetPage("Documents", fields: ["document_name", "summary", "document_system_type", "processing_status", "processing_error"],
                filter: .every([scope("Documents"), .equal("id", .text(id)), .equal("deletedAt", .null)]), limit: 1).first else { throw NativeDBError.message("文書が削除されたか、閲覧権限がありません。") }
            return row
        }
    }
    func duplicateDocument(hash: String) throws -> NativeRecord? {
        try db.transaction {
            try documentWriter()
            guard hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeDBError.message("文書の照合情報が不正です。") }
            return try db.page("Documents",fields:Self.documentSummaryFields,equal:["content_hash":.text(hash)],filter:scope("Documents"),sort:"createdAt",descending:true).rows.first
        }
    }
    func stageDocument(_ source: URL, cancelled: () -> Bool = { false }, progress: (Int64,Int64) -> Void = { _,_ in }) throws -> NativeDocumentStaging {
        try documentWriter()
        return try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent()).stage(source,cancelled:cancelled,progress:progress)
    }
    /// File I/O has already completed outside the database lock. Only the
    /// atomic publication and metadata/junction/outbox commit happen here.
    func commitDocument(_ staged: NativeDocumentStaging, name: String? = nil, replacing expected: NativeRecord? = nil, linkedTo: DocumentLink? = nil) throws -> NativeRecord {
        do {
        let saved = try db.transaction { () -> NativeRecord in
            try documentWriter()
            let current = try expected.map { try documentRoot($0["id"].string,write:true,expected:$0) }
            if current != nil && linkedTo != nil { throw NativeDBError.message("版の追加では関連先を変更できません。") }
            let junction = try linkedTo.map { try documentParent($0,write:true) }
            let title = try documentName(name ?? current?["document_name"].string ?? staged.name)
            var values: [String:SQLValue] = ["document_name":.text(title),"key":.text(staged.key),"document_file_url":.text("nextcrm-local://"+staged.key),
                "size":.integer(staged.bytes),"document_file_mimeType":.text(staged.mimeType),"content_hash":.text(staged.sha256),
                "processing_status":.text("PENDING"),"processing_error":.null,"content_text":.null,"summary":.null,"thumbnail_url":.null]
            let document: NativeRecord
            if let current {
                guard let version = Int64(current["version"].string), version > 0, version < Int64(Int32.max) else { throw NativeDBError.message("文書の版番号が不正または上限に達しています。") }
                // Legacy web versions may already contain the current file.
                let archived = try db.page("Documents",fields:[],equal:["parent_document_id":current["id"],"version":current["version"],"key":current["key"]],includeDeleted:true).total > 0
                if !archived {
                    var snapshot = current.values; snapshot.removeValue(forKey:"id"); snapshot["parent_document_id"] = current["id"]
                    if let file = try? NativeDocumentFiles.resolve(current,db:db),file.mappingRevision>0 {
                        // A version is immutable even if an older signed PUT
                        // later replaces the former logical object key.
                        snapshot["key"] = .text(file.fileKey);snapshot["document_file_url"] = .text("nextcrm-local://"+file.fileKey)
                        snapshot["size"] = file.bytes <= Int64(Int32.max) ? .integer(file.bytes) : .null
                        snapshot["content_hash"] = .text(file.sha256);snapshot["document_file_mimeType"] = .text(file.contentType)
                        if file.bytes>Int64(Int32.max) { try db.putDocumentObject(bucket:file.bucket,key:file.fileKey,fileKey:file.fileKey,contentType:file.contentType,bytes:file.bytes,sha256:file.sha256) }
                    }
                    let archive = try db.insert("Documents",values:snapshot,actor:identity.id)
                    try db.archiveDocumentProcessing(from:current,to:archive)
                }
                values["version"] = .integer(version+1)
                document = try db.update(current,changes:values,actor:identity.id,action:"document_version")
                if current["key"] != document["key"] { try db.enqueue("documents.file_cleanup",payload:["key":current["key"].string]) }
            } else {
                values["v"] = .integer(0); values["createdBy"] = .text(identity.id); values["created_by_user"] = .text(identity.id)
                values["assigned_user"] = .text(identity.id); values["visibility"] = .text("private"); values["description"] = .text("")
                document = try db.insert("Documents",values:values,actor:identity.id)
                if let link = linkedTo, let junction { _ = try db.insert(junction.model,values:["document_id":document["id"],junction.field:.text(link.id)],actor:identity.id) }
            }
            let job = try db.enqueue("document/uploaded",payload:["documentId":document["id"].string,"key":staged.key,"contentHash":staged.sha256,"actorId":identity.id])
            try db.reserveDocumentProcessing(document,jobID:job)
            try staged.publish(in:db.url.deletingLastPathComponent())
            return document
        }
            staged.retainAfterCommit(); return saved
        } catch { staged.discard(); throw error }
    }
    func updateDocument(_ expected: NativeRecord, changes: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            try documentWriter(); let current = try documentRoot(expected["id"].string,write:true,expected:expected)
            guard changes.keys.allSatisfy({ ["document_name","description","document_type","document_system_type","assigned_user","visibility","tags","favourite"].contains($0) }) else { throw NativeDBError.message("変更できない文書項目が含まれています。") }
            var values = changes
            if let title = values["document_name"] { values["document_name"] = .text(try documentName(title.string)) }
            if let visibility = values["visibility"], !["private","public"].contains(visibility.string) { throw NativeDBError.message("公開範囲を選択してください。") }
            if let id = values["assigned_user"], id != .null {
                guard let user = try db.get("Users",key:["id":id]), ["admin","manager","user"].contains(user["role"].string), user["userStatus"] == .text("ACTIVE"), user["banned"] != .integer(1) else { throw NativeDBError.message("有効な内部利用者を選択してください。") }
            }
            return try db.update(current,changes:values,actor:identity.id)
        }
    }
    func retryDocumentProcessing(_ expected: NativeRecord) throws {
        try db.transaction {
            try documentWriter(); let current = try documentRoot(expected["id"].string,write:true,expected:expected)
            let file = try NativeDocumentFiles.resolve(current,db:db)
            let pending = try db.update(current,changes:["processing_status":.text("PENDING"),"processing_error":.null],actor:identity.id,action:"document_retry")
            let job = try db.enqueue("document/uploaded",payload:["documentId":pending["id"].string,"key":pending["key"].string,"contentHash":file.sha256,"actorId":identity.id,"fileKey":file.fileKey,"mappingRevision":String(file.mappingRevision),"bucket":file.bucket])
            try db.reserveDocumentProcessing(pending,jobID:job)
        }
    }
    func documentExtractedText(_ id: String, part: Int = 0, thumbnail: Bool = false) throws -> (text: String, parts: Int, bytes: Int64, thumbnail: Data?, note: String, ready: Bool) {
        try db.transaction {
            if try hasImportedDocumentProof(id){_ = try importedDocumentAuthorize(id)}else{try assertAccess("Documents",id:id)}
            let result=try db.documentTextPage(id,part:part,includeThumbnail:thumbnail)
            guard thumbnail,result.thumbnail==nil,let row=try db.keysetPage("Documents",fields:["key","document_file_url","thumbnail_url","content_hash"],filter:.equal("id",.text(id)),limit:1).first else{return result}
            return (result.text,result.parts,result.bytes,try NativeOperationalAssets.thumbnail(row,db:db),result.note,result.ready)
        }
    }
    func setDocumentLink(_ expected: NativeRecord, to link: DocumentLink, linked: Bool) throws {
        try db.transaction {
            try documentWriter(); let document = try documentRoot(expected["id"].string,write:true,expected:expected)
            let junction = try documentParent(link,write:true)
            let key = ["document_id":document["id"],junction.field:SQLValue.text(link.id)]
            let existing = try db.get(junction.model,key:key)
            if linked && existing == nil { _ = try db.insert(junction.model,values:key,actor:identity.id) }
            if !linked, let existing { try db.remove(existing,actor:identity.id) }
            if link.model == "Tasks", let task = try db.get("Tasks",key:["id":.text(link.id)]) { _ = try db.update(task,changes:["updatedBy":.text(identity.id)],actor:identity.id) }
            _ = try db.update(document,changes:[:],actor:identity.id,action:linked ? "document_link" : "document_unlink")
        }
    }
    func changeDocumentTypes(_ expected: [NativeRecord], systemType: String) throws {
        try db.transaction {
            try documentWriter()
            guard db.schema.enums["DocumentSystemType"]?.contains(systemType) == true else { throw NativeDBError.message("文書の区分を選択してください。") }
            for row in expected { _ = try documentRoot(row["id"].string,write:true,expected:row) }
            for row in expected { _ = try updateDocument(row,changes:["document_system_type":.text(systemType)]) }
        }
    }
    func deleteDocuments(_ expected: [NativeRecord]) throws {
        try db.transaction {
            try documentWriter()
            for row in expected { _ = try documentRoot(row["id"].string,write:true,expected:row) }
            for row in expected { try db.removeDocumentFamily(row,actor:identity.id) }
        }
    }
    func documentFile(_ id: String) throws -> URL {
        // Authorization is checked both before and after potentially slow
        // filesystem verification, without holding the database during I/O.
        let (snapshot,resolved) = try db.transaction { () -> (NativeRecord,NativeDocumentResolvedFile) in let row=try documentRecord(id);return(row,try NativeDocumentFiles.resolve(row,db:db)) }
        let file = try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent()).verifiedURL(key:resolved.fileKey,bytes:resolved.bytes,sha256:resolved.sha256)
        try db.transaction {
            let current = try documentRecord(id)
            guard current.revision == snapshot.revision else { throw NativeDBError.conflict }
            try NativeDocumentFiles.requireCurrent(resolved,document:current,db:db)
        }; return file
    }
    func exportDocument(_ id: String, to destination: URL, replace: Bool = false) throws {
        guard !db.isReadOnly else { throw NativeDBError.message("閲覧専用のデータから書き出しは実行できません。") }
        try requireDocumentExportTransactionBoundary()
        let data = db.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard target != data, !target.hasPrefix(data+"/") else { throw NativeDBError.message("CRMのデータフォルダ以外の保存先を選択してください。") }
        let (snapshot,resolved) = try db.transaction { () -> (NativeRecord,NativeDocumentResolvedFile) in let row=try documentRecord(id);return(row,try NativeDocumentFiles.resolve(row,db:db)) }
        try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent()).export(key:resolved.fileKey,bytes:resolved.bytes,sha256:resolved.sha256,to:destination,replace:replace,registry:try documentExportRegistry()) { publish in
            try db.transaction {
                let current = try documentRecord(id); guard current.revision == snapshot.revision else { throw NativeDBError.conflict }
                try NativeDocumentFiles.requireCurrent(resolved,document:current,db:db);try publish()
            }
        }
    }
}

actor DocumentFileCleanupWorker {
    static let events = ["documents.file_cleanup"]
    let db: NativeDatabase
    init(db: NativeDatabase) { self.db = db }
    func recoverAbandonedFiles(olderThan: Date = Date().addingTimeInterval(-86400)) throws -> Int {
        try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent()).recoverAbandonedFiles(olderThan:olderThan,cancelled:{Task.isCancelled}) { key,staging,remove in
            try db.transaction {
                if staging { try remove() }
                else if try !db.documentFileIsReferenced(key) { try remove() }
            }
        }
    }
    @discardableResult func runNext() throws -> Bool {
        guard let job = try db.claimJob(events:Self.events) else { return false }
        do {
            try db.transaction {
                _ = try db.requireJobLease(job)
                guard let key = job.payload["key"] else { throw NativeDBError.message("文書ファイルの削除情報がありません。") }
                let mappedFiles = try db.removeUnreferencedDocumentObjects(key)
                let isPhysical = (try? NativeDocumentFiles.fileName(for:key)) != nil
                if !mappedFiles.isEmpty {
                    // Commit removal of the logical pointers before unlinking
                    // any bytes. A later failure must never roll a mapping
                    // back to a physical file that was already removed.
                    for file in Set(mappedFiles + (isPhysical ? [key] : [])) { try db.enqueue("documents.file_cleanup",payload:["key":file]) }
                    try db.finishJob(job,result:["outcome":"queued"]);return
                }
                if !isPhysical {
                    try db.finishJob(job,result:["outcome":try db.documentLogicalKeyIsReferenced(key) ? "referenced" : "external_storage"]);return
                }
                if try db.documentFileIsReferenced(key) { try db.finishJob(job,result:["outcome":"referenced"]);return }
                try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent()).removeUnreferenced(key:key)
                try db.finishJob(job,result:["outcome":"removed"])
            }
        } catch { try db.failJob(job,message:error.localizedDescription,retryAt:job.attempts < 8 ? Date().addingTimeInterval(30) : nil) }
        return true
    }
}
