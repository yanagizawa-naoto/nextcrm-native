import Foundation

actor NativeEmbeddingWorker {
    typealias Generate = (_ text: String, _ apiKey: String) async throws -> NativeEmbeddingVector
    private let db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment, clock: () -> Date, generate: Generate
    private let documents: NativeDocumentAIWorker
    private let events: [String]
    private var active = false
    private struct Skip: Error { let reason: String }
    init(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(), clock: @escaping () -> Date = Date.init,
         generate: @escaping Generate = { try await NativeEmbeddingClient(apiKey: $1).generate($0, allowWhitespace: true) },
         summarize: @escaping NativeDocumentAIWorker.Summary = { try await NativeOpenAIChatClient(apiKey: $1).summary(excerpt: $0) },
         classify: @escaping NativeDocumentAIWorker.Classify = { try await NativeOpenAIChatClient(apiKey: $3).classification(name: $0, summary: $1, excerpt: $2) },
         events: [String] = NativeEmbeddingJobs.events) {
        self.db = db; self.store = store; self.environment = environment; self.clock = clock; self.generate = generate
        documents = NativeDocumentAIWorker(db: db, store: store, environment: environment, clock: clock, generate: generate, summarize: summarize, classify: classify)
        self.events = NativeEmbeddingJobs.events.filter { events.contains($0) }
    }
    func cancelDocument(_ id: String) async { await documents.cancelRequest(id) }
    private func owner(_ job: NativeJob) throws -> CRMService {
        guard let id = job.payload["actorID"], let row = try db.get("Users", key: ["id": .text(id)]) else {
            throw NativeAIError(message: "旧版の処理で実行者を確認できません。AI検索の処理画面から全件作成を実行してください。")
        }
        let service = CRMService(db: db, identity: .init(id: id, role: row["role"].string, partnerAccountID: row["partnerAccountId"] == .null ? nil : row["partnerAccountId"].string))
        do { try service.authenticated() } catch { throw Skip(reason: "利用者の権限が失われています。") }; return service
    }
    private func lease(_ job: NativeJob) throws {
        try Task.checkCancellation(); _ = try db.requireJobLease(job)
        if let parent = job.payload["backfillID"] {
            guard let batch = try db.job(id: parent), batch.event == NativeEmbeddingJobs.backfill, batch.payload["actorID"] == job.payload["actorID"], batch.status != "cancelled" else { throw Skip(reason: "全件作成が取り消されています。") }
        }
    }
    private func input(_ job: NativeJob, kind: NativeEmbeddingKind, service: CRMService) throws -> NativeEmbeddingInput {
        try lease(job)
        guard let id = job.payload[kind == .email ? "emailID" : "record_id"], let value = try service.embeddingInput(kind, id: id) else { throw Skip(reason: "対象が削除されたか、閲覧権限・CRMとの関連付けが失われています。") }
        if kind == .email {
            guard value.record["emailAccountId"].string == job.payload["accountID"] else { throw Skip(reason: "メールアカウントが変更されています。") }
            if let expected = job.payload["contentHash"] {
                guard expected == value.legacyMailHash else { throw Skip(reason: "新しいメール本文に更新されています。") }
            } else if job.payload["rebuild"] != "true" { throw NativeAIError(message: "メールの検索更新情報を確認できません。全件作成を実行してください。") }
        }
        return value
    }
    private func keys(_ service: CRMService) -> NativeAIKeys { NativeAIKeys(service: service, store: store, environment: environment, clock: clock) }
    private func credential(_ service: CRMService) throws -> NativeAIResolvedKey {
        guard let value = try keys(service).resolve(.openai) else { throw NativeAIError(message: "AI連携の設定でOpenAIのAPIキーを保存してから再実行してください。") }; return value
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events: events, now: clock()) else { return false }
        do {
            let service = try owner(job)
            if job.event == NativeEmbeddingJobs.backfill { try backfill(job, service: service); return true }
            if job.event == NativeDatabase.documentAIEvent { try await documents.process(job); return true }
            guard let kind = NativeEmbeddingJobs.kind(job.event) else { throw NativeDBError.conflict }
            let index = NativeEmbeddingIndex(db: db)
            let initial = try db.transaction { try input(job, kind: kind, service: service) }
            if initial.text.isEmpty {
                try db.transaction {
                    let fresh = try input(job, kind: kind, service: service); guard fresh.hash == initial.hash else { throw NativeDBError.conflict }
                    if let old = try index.existing(kind, parentID: fresh.record["id"].string) { try db.remove(old, actor: service.identity.id, action: "empty_embedding") }
                    try db.finishJob(job, result: ["outcome": "empty"], now: clock())
                }; return true
            }
            let unchanged = try db.transaction { () -> Bool in
                let fresh = try input(job, kind: kind, service: service); guard fresh.hash == initial.hash else { throw NativeDBError.conflict }
                guard let old = try index.existing(kind, parentID: fresh.record["id"].string), old[kind.hashField].string == fresh.hash,
                      case let .blob(bytes) = old["embedding"], (try? NativeEmbeddingVector(bytes: bytes)) != nil else { return false }
                try db.finishJob(job, result: ["outcome": "unchanged", "contentHash": fresh.hash], now: clock()); return true
            }
            if unchanged { return true }
            let key = try credential(service)
            try db.transaction {
                let fresh = try input(job, kind: kind, service: service); guard fresh.hash == initial.hash else { throw NativeDBError.conflict }
                try keys(service).requireCurrent(key); try db.renewJobLease(job, now: clock())
            }
            let vector = try await generate(initial.text, key.key)
            try db.transaction {
                let fresh = try input(job, kind: kind, service: service)
                guard fresh.hash == initial.hash else { throw NativeDBError.conflict }
                try keys(service).requireCurrent(key)
                _ = try index.save(kind, source: fresh.record, vector: vector, contentHash: fresh.hash, actor: service.identity.id, now: clock())
                try db.finishJob(job, result: ["outcome": "embedded", "contentHash": fresh.hash, "model": NativeEmbeddingVector.model], now: clock())
            }
        } catch {
            guard (try? db.requireJobLease(job)) != nil else { return true }
            try db.transaction {
                _ = try db.requireJobLease(job)
                if let skip = error as? Skip { try db.finishJob(job, result: ["outcome": "skipped", "reason": skip.reason], now: clock()); return }
                let retry: Bool
                if error is CancellationError { retry = true }
                else if case NativeDBError.conflict = error { retry = job.attempts < 4 }
                else { retry = (error as? NativeAIError)?.retryable == true && job.attempts < 4 }
                try db.failJob(job, message: NativeEmbeddingJobs.message(error), retryAt: retry ? clock().addingTimeInterval(min(300, 5 * pow(2, Double(min(job.attempts - 1, 6))))) : nil)
            }
        }
        return true
    }
    private func backfill(_ job: NativeJob, service: CRMService) throws {
        let key = try credential(service)
        var state = job.result
        var phase = Int(state["phase"] ?? "0") ?? -1, after = state["after"] ?? "", dispatched = Int(state["dispatched"] ?? "0") ?? -1
        guard (0...NativeEmbeddingJobs.kinds.count).contains(phase), dispatched >= 0 else { throw NativeAIError(message: "検索データの作成位置を確認できません。新しい全件作成を実行してください。") }
        while phase < NativeEmbeddingJobs.kinds.count {
            try Task.checkCancellation()
            let kind = NativeEmbeddingJobs.kinds[phase]
            try autoreleasepool {
                try db.transaction {
                    try lease(job); try service.authenticated(); try keys(service).requireCurrent(key); try db.renewJobLease(job, now: clock())
                    let rows = try db.keysetPage(kind.parent, fields: kind == .document ? ["key", "content_hash"] : kind == .email ? ["emailAccountId"] : [], after: after.isEmpty ? nil : after, filter: service.embeddingScope(kind))
                    for row in rows {
                        if kind == .document {
                            if try db.enqueueDocumentAI(row, actor: service.identity.id, backfillID: job.id, now: clock()) != nil { dispatched += 1 }
                            continue
                        }
                        var payload = ["actorID": service.identity.id, "backfillID": job.id]
                        if kind == .email { payload["emailID"] = row["id"].string; payload["accountID"] = row["emailAccountId"].string; payload["rebuild"] = "true" }
                        else { payload["record_id"] = row["id"].string }
                        try db.enqueue(NativeEmbeddingJobs.event(kind), payload: payload, now: clock()); dispatched += 1
                    }
                    if rows.count < 100 { phase += 1; after = "" } else { after = rows.last!["id"].string }
                    state = ["phase": String(phase), "after": after, "dispatched": String(dispatched)]
                    try db.recordJobResult(job, result: state)
                }
            }
        }
        try db.transaction { try lease(job); try service.authenticated(); state["outcome"] = "queued"; try db.finishJob(job, result: state, now: clock()) }
    }
}
