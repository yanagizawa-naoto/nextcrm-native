import Foundation

actor NativeContactEnrichmentWorker {
    struct Progress {
        enum Kind: String { case info, success, warning, agent }
        let message: String, kind: Kind
        var sourceURL: String? = nil
    }
    typealias Report = (Progress) async throws -> Void
    typealias Enrich = (_ email: String, _ fields: [NativeEnrichmentField], _ openai: String, _ firecrawl: String, _ report: @escaping Report) async throws -> NativeEnrichmentOutput
    private let db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment, clock: () -> Date, enrich: Enrich
    private let timeoutNanoseconds: UInt64
    private let skipList: NativeEnrichmentSkipList
    private var active = false
    private var cancelRequest: (id: String, cancel: () -> Void)?
    private struct Skip: Error { let message: String }
    init(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(),
         clock: @escaping () -> Date = Date.init, timeoutNanoseconds: UInt64 = 90_000_000_000,
         skipList: NativeEnrichmentSkipList = NativeEnrichmentSkipList(), enrich: @escaping Enrich) {
        self.db = db; self.store = store; self.environment = environment; self.clock = clock
        self.timeoutNanoseconds = timeoutNanoseconds; self.skipList = skipList; self.enrich = enrich
    }
    func cancel(_ id: String) { if cancelRequest?.id == id { cancelRequest?.cancel() } }
    private func owner(_ job: NativeJob) throws -> NativeContactEnrichmentService {
        guard let id = job.payload["actorID"], let row = try db.get("Users", key: ["id": .text(id)]) else {
            throw Skip(message: "情報補完を予約した利用者を確認できません。")
        }
        let crm = CRMService(db: db, identity: .init(id: id, role: row["role"].string,
            partnerAccountID: row["partnerAccountId"] == .null ? nil : row["partnerAccountId"].string))
        return .init(service: crm, store: store, environment: environment, clock: clock)
    }
    private func history(_ job: NativeJob) throws -> NativeRecord {
        _ = try db.requireJobLease(job)
        guard job.event == NativeContactEnrichment.event, job.id == job.payload["enrichmentId"],
              let history = try db.get(NativeContactEnrichment.model, key: ["id": .text(job.id)]),
              history["contactId"].string == job.payload["contactId"], history["triggeredBy"].string == job.payload["actorID"],
              ["PENDING", "RUNNING"].contains(history["status"].string) else { throw NativeDBError.conflict }
        return history
    }
    private func current(_ job: NativeJob, service: NativeContactEnrichmentService) throws -> NativeRecord {
        try Task.checkCancellation(); _ = try history(job)
        guard let id = job.payload["contactId"], let mode = job.payload["mode"].flatMap(NativeContactEnrichment.Mode.init(rawValue:)) else { throw NativeDBError.conflict }
        let row: NativeRecord
        do { row = try service.contact(id, mode: mode, mcp: job.payload["mcpOrigin"] != nil) }
        catch { throw Skip(message: "連絡先が削除されたか、利用者の権限が変更されています。") }
        guard job.payload["email"] == row["email"].string else { throw Skip(message: "検索時からメールアドレスが変更されています。新しい情報補完を開始してください。") }
        return row
    }
    private func publishProgress(_ value: Progress, job: NativeJob, service: NativeContactEnrichmentService,
                                 openai: NativeAIResolvedKey, firecrawl: NativeAIResolvedKey) throws {
        try db.transaction {
            _ = try current(job, service: service); try service.keys.requireCurrent(openai); try service.keys.requireCurrent(firecrawl)
            try db.renewJobLease(job, now: clock())
            var state = try db.requireJobLease(job).result
            state["message"] = String(value.message.prefix(4000)); state["messageType"] = value.kind.rawValue
            state["sourceURL"] = value.sourceURL.map { String($0.prefix(8000)) }
            state["progressSequence"] = String((Int(state["progressSequence"] ?? "0") ?? 0) + 1)
            try db.recordJobResult(job, result: state)
        }
        db.notifyAIProgress()
    }
    private func request(_ job: NativeJob, email: String, fields: [NativeEnrichmentField], service: NativeContactEnrichmentService,
                         openai: NativeAIResolvedKey, firecrawl: NativeAIResolvedKey) async throws -> NativeEnrichmentOutput {
        let operation = enrich, timeout = timeoutNanoseconds
        let task = Task {
            try await withThrowingTaskGroup(of: NativeEnrichmentOutput.self) { group in
                group.addTask {
                    let result = try await operation(email, fields, openai.key, firecrawl.key) { progress in
                        try await self.publishProgress(progress, job: job, service: service, openai: openai, firecrawl: firecrawl)
                    }
                    try Task.checkCancellation(); return result
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw NativeAIError(message: "情報補完が90秒以内に完了しませんでした。もう一度お試しください。", retryable: true)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }; return result
            }
        }
        cancelRequest = (job.id, { task.cancel() }); defer { cancelRequest = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events: NativeContactEnrichment.events, now: clock()) else { return false }
        defer { db.notifyAIProgress() }
        do {
            let service = try owner(job)
            if job.event == NativeContactEnrichment.bulkEvent { try service.fanoutMCP(job); return true }
            let isMCP = job.payload["mcpOrigin"] != nil
            let fields = try NativeContactEnrichment.decode([NativeEnrichmentField].self, job.payload["fields"] ?? "")
            try NativeEnrichmentField.validate(fields)
            let initial = try db.transaction { () -> NativeRecord in
                let row = try current(job, service: service), entry = try history(job)
                guard try NativeContactEnrichment.decode([String].self, entry["fields"].string) == fields.map(\.name) else { throw NativeDBError.conflict }
                _ = try db.update(entry, changes: ["status": .text("RUNNING"), "error": .null], actor: service.service.identity.id)
                return row
            }
            db.notifyAIProgress()
            // Keep the original missing-key precedence even for a skipped item.
            let credentials = try service.credentials(mcp: isMCP)
            guard !initial["email"].string.isEmpty else { throw Skip(message: isMCP ? "No email on contact" : "メールアドレスが登録されていません。") }
            if isMCP || job.payload["mode"] == NativeContactEnrichment.Mode.bulk.rawValue {
                let recent = try db.page(NativeContactEnrichment.model, fields: [], filter: .every([
                    .equal("contactId", initial["id"]), .equal("status", .text("COMPLETED")),
                    .compareDate("createdAt", .greater, NativeContactEnrichment.stamp(clock().addingTimeInterval(-7 * 86400)))
                ]), limit: 1)
                if recent.total > 0 { throw Skip(message: isMCP ? "Enriched within last 7 days" : "過去7日以内に情報補完が完了しているため省略しました。") }
            }
            try db.transaction {
                _ = try current(job, service: service)
                try service.keys.requireCurrent(credentials.openai); try service.keys.requireCurrent(credentials.firecrawl)
                try db.renewJobLease(job, now: clock())
            }
            let raw: NativeEnrichmentOutput
            if let reason = skipList.reason(initial["email"].string) { raw = .init(enrichments: [:], status: .skipped, error: isMCP ? NativeContactEnrichment.mcpSkipReason(initial["email"].string, domains: skipList.domains) : reason) }
            else {
                do { raw = try await request(job, email: initial["email"].string, fields: fields, service: service,
                                            openai: credentials.openai, firecrawl: credentials.firecrawl) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    guard isMCP else { throw error }
                    // Source AgentEnrichmentStrategy turns provider failures into
                    // error results. Current/lease/key checks still run below.
                    raw = .init(enrichments: [:], status: .error, error: NativeContactEnrichment.message(error))
                }
            }
            let output = try raw.validated(for: fields)
            try db.transaction {
                let row = try current(job, service: service), entry = try history(job)
                try service.keys.requireCurrent(credentials.openai); try service.keys.requireCurrent(credentials.firecrawl)
                var applied: [String] = []
                if isMCP || (output.status == .completed && job.payload["mode"] == NativeContactEnrichment.Mode.bulk.rawValue) {
                    var updates: [String: SQLValue] = [:]
                    for (name, result) in output.enrichments where NativeEnrichmentField.contactColumns.contains(name) && result.value.truthy {
                        // Re-read after the provider awaits. A manual edit wins,
                        // even when it changed the field to another blank value.
                        if NativeAIEnvironment.trim(initial[name].string).isEmpty, row[name] == initial[name] {
                            updates[name] = .text(result.value.text)
                        }
                    }
                    if !updates.isEmpty {
                        applied = updates.keys.sorted(); if !isMCP { updates["updatedBy"] = .text(service.service.identity.id) }
                        _ = try db.update(row, changes: updates, actor: service.service.identity.id, action: "bulk_enrichment")
                        try db.enqueue("crm/contact.saved", payload: ["actorID": service.service.identity.id, "record_id": row["id"].string], now: clock())
                    }
                }
                let status = isMCP || output.status == .completed ? "COMPLETED" : output.status == .skipped ? "SKIPPED" : "FAILED"
                _ = try db.update(entry, changes: ["status": .text(status), "result": .text(NativeContactEnrichment.json(output)),
                    "error": isMCP ? .null : output.error.map(SQLValue.text) ?? .null], actor: service.service.identity.id)
                var state = try db.requireJobLease(job).result
                state["outcome"] = output.status.rawValue; state["fieldsApplied"] = try NativeContactEnrichment.json(applied)
                if !isMCP && output.status == .error {
                    try db.recordJobResult(job, result: state)
                    try db.failJob(job, message: output.error ?? "情報補完を完了できませんでした。")
                } else { try db.finishJob(job, result: state, now: clock()) }
            }
        } catch {
            // A cancellation or a newer lease owns the terminal state. The
            // abandoned request must never rewrite history or publish a result.
            guard (try? db.requireJobLease(job)) != nil else { return true }
            try db.transaction {
                _ = try db.requireJobLease(job)
                let skip = error as? Skip
                let retry = skip == nil && (error is CancellationError ||
                    (job.attempts < 4 && ((error as? NativeAIError)?.retryable == true || { if case NativeDBError.conflict = error { return true }; return false }())))
                let message = skip?.message ?? NativeContactEnrichment.message(error)
                if let entry = try db.get(NativeContactEnrichment.model, key: ["id": .text(job.id)]),
                   entry["contactId"].string == job.payload["contactId"], entry["triggeredBy"].string == job.payload["actorID"] {
                    _ = try db.update(entry, changes: ["status": .text(skip != nil ? "SKIPPED" : retry ? "PENDING" : "FAILED"), "error": .text(message)], actor: job.payload["actorID"] ?? "enrichment-worker")
                }
                if skip != nil { try db.finishJob(job, result: ["outcome": "skipped", "reason": message], now: clock()) }
                else { try db.failJob(job, message: message, retryAt: retry ? clock().addingTimeInterval(min(300, 5 * pow(2, Double(min(job.attempts - 1, 6))))) : nil) }
            }
        }
        return true
    }
}
