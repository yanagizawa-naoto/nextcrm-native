import Foundation

actor NativeDocumentAIWorker {
    typealias Summary = (_ excerpt: String, _ apiKey: String) async throws -> String?
    typealias Classify = (_ name: String, _ summary: String?, _ excerpt: String, _ apiKey: String) async throws -> String
    private let db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment, clock: () -> Date
    private let generate: NativeEmbeddingWorker.Generate, summarize: Summary, classify: Classify
    private var pendingRequests: [String: () -> Void] = [:]
    private struct Skip: Error { let reason: String }
    init(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment, clock: @escaping () -> Date = Date.init,
         generate: @escaping NativeEmbeddingWorker.Generate = { try await NativeEmbeddingClient(apiKey: $1).generate($0, allowWhitespace: true) },
         summarize: @escaping Summary = { try await NativeOpenAIChatClient(apiKey: $1).summary(excerpt: $0) },
         classify: @escaping Classify = { try await NativeOpenAIChatClient(apiKey: $3).classification(name: $0, summary: $1, excerpt: $2) }) {
        self.db = db; self.store = store; self.environment = environment; self.clock = clock
        self.generate = generate; self.summarize = summarize; self.classify = classify
    }
    private func current(_ job: NativeJob, service: CRMService) throws -> NativeRecord {
        try Task.checkCancellation(); _ = try db.requireJobLease(job); try service.authenticated()
        guard let id = job.payload["documentId"], try db.documentAIJob(id) == job.id,
              let row = try db.keysetPage("Documents", fields: ["document_name", "key", "content_hash", "summary", "document_system_type"],
                                         filter: .every([service.scope("Documents", write: true), .equal("id", .text(id)), .equal("parent_document_id", .null)]), limit: 1).first,
              row["key"].string == job.payload["key"], row["content_hash"].string == job.payload["contentHash"],
              try (db.documentProcessingJob(row) ?? "") == job.payload["sourceJob"], try db.documentTextPage(id).ready else { throw Skip(reason: "文書・抽出結果・権限が変更されています。") }
        if let source = job.payload["sourceJob"], !source.isEmpty, try db.job(id: source)?.status != "done" { throw Skip(reason: "文書の再処理が予約されています。") }
        if let parent = job.payload["backfillID"] {
            guard let batch = try db.job(id: parent), batch.event == NativeEmbeddingJobs.backfill, batch.payload["actorID"] == service.identity.id, batch.status != "cancelled" else { throw Skip(reason: "全件作成が取り消されています。") }
        }
        return row
    }
    private static func summaryHash(_ value: SQLValue) -> String { NativeEmbeddingVector.hash((value == .null ? "null:" : "text:") + value.string) }
    func cancelRequest(_ jobID: String) { pendingRequests[jobID]?() }
    private func request<T>(_ job: NativeJob, _ action: @escaping () async throws -> T) async throws -> T {
        let task = Task { let value = try await action(); try Task.checkCancellation(); return value }
        pendingRequests[job.id] = { task.cancel() }; defer { pendingRequests.removeValue(forKey: job.id) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    private func markFailure(_ job: NativeJob, message: String, retry: Bool, status: String? = nil) throws {
        // Cancellation must still durably update state, so this path validates
        // ownership and generation without Task.checkCancellation().
        guard let id = job.payload["documentId"], try db.documentAIJob(id) == job.id,
              let actor = job.payload["actorID"], let user = try db.get("Users", key: ["id": .text(actor)]) else { return }
        let service = CRMService(db: db, identity: .init(id: actor, role: user["role"].string, partnerAccountID: user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        guard (try? service.authenticated()) != nil,
              let row = try db.keysetPage("Documents", fields: ["key", "content_hash"], filter: .every([service.scope("Documents", write: true), .equal("id", .text(id)), .equal("parent_document_id", .null)]), limit: 1).first,
              row["key"].string == job.payload["key"], row["content_hash"].string == job.payload["contentHash"], try (db.documentProcessingJob(row) ?? "") == job.payload["sourceJob"] else { return }
        _ = try db.patchDocumentAI(row, changes: ["processing_status": .text(status ?? (retry ? "PENDING" : "FAILED")), "processing_error": .text(message)], actor: actor)
    }
    func process(_ job: NativeJob) async throws {
        do {
            guard let actor = job.payload["actorID"], let user = try db.get("Users", key: ["id": .text(actor)]) else { throw Skip(reason: "文書処理を予約した利用者を確認できません。") }
            let service = CRMService(db: db, identity: .init(id: actor, role: user["role"].string, partnerAccountID: user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
            let initial = try db.transaction { try current(job, service: service) }, id = initial["id"].string
            let reader = NativeDocumentAIText(db: db, documentID: id)
            let inspection = try reader.inspect { _ = try self.current(job, service: service) }
            let keys = NativeAIKeys(service: service, store: store, environment: environment, clock: clock)
            if inspection.utf16Count == 0 {
                try db.transaction {
                    let fresh = try current(job, service: service); try db.clearDocumentAIIndex(id); try db.clearDocumentAIStage(job)
                    _ = try db.patchDocumentAI(fresh, changes: ["processing_status": .text("READY"), "processing_error": .null], actor: actor)
                    try db.finishJob(job, result: ["outcome": "empty", "enriched": "false"], now: clock())
                }; return
            }
            guard let key = try keys.resolve(.openai) else {
                try db.transaction {
                    let fresh = try current(job, service: service); try db.clearDocumentAIStage(job)
                    _ = try db.patchDocumentAI(fresh, changes: ["processing_status": .text("READY"), "processing_error": .null], actor: actor)
                    try db.finishJob(job, result: ["outcome": "unconfigured", "enriched": "false"], now: clock())
                }; return
            }
            var state = job.result
            let originalSingle = inspection.utf16Count <= NativeDocumentAIText.singleLimit
            if state["format"] != "1" || state["hash"] != inspection.hash || state["name"] != initial["document_name"].string {
                state = ["format": "1", "hash": inspection.hash, "utf16Count": String(inspection.utf16Count), "name": initial["document_name"].string,
                         "single": originalSingle ? "true" : "false", "summaryBefore": Self.summaryHash(initial["summary"]), "typeBefore": initial["document_system_type"].string,
                         "part": "0", "offset": "0", "chunks": "0"]
                try db.transaction { _ = try current(job, service: service); try keys.requireCurrent(key); try db.clearDocumentAIStage(job); try db.recordJobResult(job, result: state) }
            }
            var single = originalSingle && state["tokenFallback"] != "true"
            guard let part = Int(state["part"] ?? ""), let offset = Int(state["offset"] ?? ""), var count = Int(state["chunks"] ?? ""),
                  count >= 0, state["single"] == (single ? "true" : "false"), try db.stagedDocumentAICount(job) == count else { throw NativeAIError(message: "文書AI処理の再開位置が不正です。文書を再処理してください。") }
            var cursor = NativeDocumentAICursor(part: part, offset: offset)
            func validate() throws -> NativeRecord {
                let fresh = try current(job, service: service)
                guard fresh["document_name"].string == state["name"] else { throw NativeDBError.conflict }
                try keys.requireCurrent(key); try db.renewJobLease(job, now: clock()); return fresh
            }
            try db.transaction { let fresh = try validate(); _ = try db.patchDocumentAI(fresh, changes: ["processing_status": .text("PROCESSING"), "processing_error": .null], actor: actor) }
            db.notifyAIProgress()
            while state["embeddingsDone"] != "true" {
                _ = try db.transaction { try validate() }
                let window = try reader.window(from: cursor, limit: single ? NativeDocumentAIText.singleLimit : NativeDocumentAIText.windowSize, overlap: single ? 0 : NativeDocumentAIText.overlap)
                guard !window.text.isEmpty, !single || window.final else { throw NativeDBError.conflict }
                let vector: NativeEmbeddingVector
                do { vector = try await request(job) { [generate] in try await generate(window.text, key.key) } }
                catch {
                    // The original 32000-character approximation can exceed the
                    // provider's token limit for Japanese. Persist a one-time
                    // switch to bounded chunks only after an input rejection.
                    guard single, inspection.utf16Count > NativeDocumentAIText.windowSize,
                          let failure = error as? NativeAIError, let status = failure.status,
                          [400, 413, 422].contains(status) else { throw error }
                    try db.transaction {
                        _ = try validate(); try db.clearDocumentAIStage(job)
                        single = false; count = 0; cursor = .init()
                        state["single"] = "false"; state["tokenFallback"] = "true"
                        state["part"] = "0"; state["offset"] = "0"; state["chunks"] = "0"; state["embeddingsDone"] = "false"
                        try db.recordJobResult(job, result: state)
                    }
                    db.notifyAIProgress(); continue
                }
                cursor = window.next; count += 1
                state["part"] = String(cursor.part); state["offset"] = String(cursor.offset); state["chunks"] = String(count); state["embeddingsDone"] = window.final ? "true" : "false"
                try db.transaction { _ = try validate(); try db.stageDocumentAI(job, index: count - 1, text: window.text, vector: vector.bytes, result: state) }
                db.notifyAIProgress()
            }
            if state["summaryDone"] != "true" {
                _ = try db.transaction { try validate() }
                let excerpt = try reader.window(from: .init(), limit: 12_000).text
                let summary = try await request(job) { [summarize] in try await summarize(excerpt, key.key) }
                guard (summary?.utf8.count ?? 0) <= NativeEmbeddingClient.maximumResponseBytes else { throw NativeAIError(message: "文書の要約が大きすぎます。") }
                state["summary"] = summary; state["summaryDone"] = "true"
                try db.transaction { _ = try validate(); try db.recordJobResult(job, result: state) }
                db.notifyAIProgress()
            }
            if state["categoryDone"] != "true" {
                _ = try db.transaction { try validate() }
                let excerpt = try reader.window(from: .init(), limit: 4000).text
                let name = state["name"]!, summary = state["summary"]
                let category = try await request(job) { [classify] in try await classify(name, summary, excerpt, key.key) }
                guard ["RECEIPT", "CONTRACT", "OFFER", "OTHER"].contains(category) else { throw NativeAIError(message: "文書の分類結果が不正です。") }
                state["category"] = category; state["categoryDone"] = "true"
                try db.transaction { _ = try validate(); try db.recordJobResult(job, result: state) }
                db.notifyAIProgress()
            }
            try db.transaction {
                let fresh = try validate()
                var changes: [String: SQLValue] = ["processing_status": .text("READY"), "processing_error": .null]
                if Self.summaryHash(fresh["summary"]) == state["summaryBefore"] { changes["summary"] = state["summary"].map(SQLValue.text) ?? .null }
                if fresh["document_system_type"].string == state["typeBefore"] { changes["document_system_type"] = .text(state["category"]!) }
                let result = ["outcome": "enriched", "enriched": "true", "chunks": String(count), "single": single ? "true" : "false", "contentHash": inspection.hash]
                try db.publishDocumentAI(job, source: fresh, single: single, count: count, hash: inspection.hash, changes: changes, actor: actor, result: result, now: clock())
            }
        } catch {
            guard (try? db.requireJobLease(job)) != nil else { return }
            try db.transaction {
                _ = try db.requireJobLease(job)
                if let skip = error as? Skip {
                    try markFailure(job, message: skip.reason, retry: false, status: "READY")
                    if (try? db.documentAIJob(job.payload["documentId"] ?? "")) == job.id { try db.clearDocumentAIStage(job) }
                    try db.finishJob(job, result: ["outcome": "skipped", "reason": skip.reason], now: clock()); return
                }
                let retry: Bool
                if error is CancellationError { retry = true }
                else if case NativeDBError.conflict = error { retry = job.attempts < 4 }
                else { retry = (error as? NativeAIError)?.retryable == true && job.attempts < 4 }
                let message = NativeEmbeddingJobs.message(error)
                try markFailure(job, message: message, retry: retry)
                try db.failJob(job, message: message, retryAt: retry ? clock().addingTimeInterval(min(300, 5 * pow(2, Double(min(job.attempts - 1, 6))))) : nil)
            }
        }
    }
}
