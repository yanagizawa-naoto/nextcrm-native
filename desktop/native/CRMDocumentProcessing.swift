import Foundation

actor DocumentProcessingWorker {
    static let events = ["document/uploaded"]
    typealias Extract = (URL,String,@escaping () throws -> Void) throws -> NativeDocumentExtraction
    private let db: NativeDatabase
    private let extract: Extract
    private let clock: () -> Date
    init(db: NativeDatabase, clock: @escaping () -> Date = Date.init, extract: @escaping Extract = { url,type,checkpoint in try NativeDocumentProcessing.extract(url:url,mimeType:type,checkpoint:checkpoint) }) {
        self.db = db; self.clock = clock; self.extract = extract
    }
    private struct Skipped: Error { let message: String }
    private func current(_ job: NativeJob) throws -> NativeRecord {
        _ = try db.requireJobLease(job)
        guard let id = job.payload["documentId"], let record = try db.get("Documents",key:["id":.text(id)]),
              record["parent_document_id"] == .null, record["deletedAt"] == .null,
              job.payload["key"] == record["key"].string else { throw Skipped(message:"文書が削除または別の版に更新されています。") }
        let file = try NativeDocumentFiles.resolve(record,db:db)
        guard job.payload["contentHash"] == file.sha256 else { throw Skipped(message:"文書ファイルが更新されています。") }
        if let fileKey = job.payload["fileKey"] {
            guard fileKey==file.fileKey,job.payload["mappingRevision"]==String(file.mappingRevision),job.payload["bucket"]==file.bucket else { throw Skipped(message:"文書の保存先が更新されています。") }
        } else if file.mappingRevision>0 { throw Skipped(message:"文書の保存先が更新されています。") }
        if try db.documentProcessingJob(record) == nil { try db.reserveDocumentProcessing(record,jobID:job.id) }
        guard try db.documentProcessingJob(record) == job.id else { throw Skipped(message:"新しい再処理が予約されています。") }
        guard let actor = job.payload["actorId"], let user = try db.get("Users",key:["id":.text(actor)]), ["admin","manager","user"].contains(user["role"].string) else { throw Skipped(message:"文書処理を予約した利用者を確認できません。") }
        let service = CRMService(db:db,identity:CRMIdentity(id:actor,role:user["role"].string,partnerAccountID:nil))
        do { try service.assertAccess("Documents",id:id,write:true) } catch { throw Skipped(message:"文書処理を予約した利用者の権限が失われています。") }
        return record
    }
    private func failure(_ job: NativeJob, message: String, retry: Bool, skipped: Bool = false) throws {
        try db.transaction {
            _ = try db.requireJobLease(job)
            if let id = job.payload["documentId"], let record = try db.get("Documents",key:["id":.text(id)]),
               record["parent_document_id"] == .null, record["key"].string == job.payload["key"],
               (try? NativeDocumentFiles.resolve(record,db:db).sha256) == job.payload["contentHash"], try db.documentProcessingJob(record) == job.id {
                _ = try db.update(record,changes:["processing_status":.text(retry ? "PENDING" : "FAILED"),"processing_error":.text(String(message.prefix(2000)))],actor:job.payload["actorId"] ?? "document-worker",action:"document_processing_failed")
            }
            if skipped { try db.finishJob(job,result:["outcome":"skipped","reason":message],now:clock()) }
            else { try db.failJob(job,message:message,retryAt:retry ? clock().addingTimeInterval(Double(min(300,30*job.attempts))) : nil) }
        }
    }
    @discardableResult func runNext() throws -> Bool {
        guard let job = try db.claimJob(events:Self.events,now:clock()) else { return false }
        do {
            let started = try db.transaction { () -> NativeRecord in
                let record = try current(job)
                return try db.update(record,changes:["processing_status":.text("PROCESSING"),"processing_error":.null],actor:job.payload["actorId"]!,action:"document_processing")
            }
            let files = try NativeDocumentFiles(dataRoot:db.url.deletingLastPathComponent())
            let resolved = try db.transaction { try NativeDocumentFiles.resolve(current(job),db:db) }
            // This was previously enforced by verifiedURL for every native
            // operation. Keep the extraction bound while allowing larger
            // signed uploads, downloads and byte-stream exports.
            guard resolved.bytes<=NativeDocumentFiles.maximumBytes else { throw NativeDBError.message("本文処理は1ファイル64MiB以内に対応しています。原本の閲覧・書き出しは利用できます。") }
            var lastCheck = Date.distantPast; var lastRenew = clock()
            let checkpoint = { [self] in
                if Task.isCancelled { throw CancellationError() }
                if Date().timeIntervalSince(lastCheck) >= 0.5 {
                    try db.transaction {
                        _ = try current(job)
                        if clock().timeIntervalSince(lastRenew) >= 30 { try db.renewJobLease(job,now:clock()); lastRenew = clock() }
                    }; lastCheck = Date()
                }
            }
            let url = try files.verifiedURL(key:resolved.fileKey,bytes:resolved.bytes,sha256:resolved.sha256)
            let result = try extract(url,resolved.contentType,checkpoint)
            try checkpoint()
            _ = try files.verifiedURL(key:resolved.fileKey,bytes:resolved.bytes,sha256:resolved.sha256)
            try db.transaction {
                let latest = try current(job)
                try NativeDocumentFiles.requireCurrent(resolved,document:latest,db:db)
                try db.saveDocumentProcessing(latest,jobID:job.id,textBytes:result.text.bytes,thumbnail:result.thumbnail,note:result.note) { append in
                    try result.text.forEachChunk { text in if Task.isCancelled { throw CancellationError() }; try append(text) }
                }
                var values: [String:SQLValue] = ["processing_status":.text("READY"),"processing_error":.null]
                // An explicit edit while extraction was running takes priority
                // over automatic classification of the earlier filename.
                if latest.revision == started.revision { values["document_system_type"] = .text(NativeDocumentProcessing.classify(filename:latest["document_name"].string)) }
                _ = try db.update(latest,changes:values,actor:job.payload["actorId"]!,action:"document_processed")
                try db.finishJob(job,result:["outcome":"ready","textBytes":String(result.text.bytes),"thumbnail":result.thumbnail == nil ? "false" : "true","enriched":"false","note":result.note],now:clock())
                _ = try db.enqueueDocumentAI(latest, actor: job.payload["actorId"]!, now: clock())
            }
        } catch {
            // Another process may have reclaimed the lease; an old attempt
            // must not change the new attempt's document or outbox state.
            guard (try? db.requireJobLease(job)) != nil else { return true }
            if let skip = error as? Skipped { try failure(job,message:skip.message,retry:false,skipped:true) }
            else if error is CancellationError { try failure(job,message:"文書処理を中断しました。次回起動時に再開します。",retry:true) }
            else { try failure(job,message:error.localizedDescription,retry:job.attempts < 4) }
        }
        return true
    }
}
