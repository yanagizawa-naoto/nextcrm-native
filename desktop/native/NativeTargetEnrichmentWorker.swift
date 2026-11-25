import Foundation

actor NativeTargetEnrichmentWorker {
    typealias Report = NativeContactEnrichmentWorker.Report
    typealias Review = (NativeTargetEnrichmentContext, String, String, @escaping Report) async throws -> NativeEnrichmentOutput
    typealias Agent = (NativeTargetEnrichmentContext, String, NativeE2BConnection, @escaping Report) async throws -> NativeTargetAgentOutput
    private enum Response { case review(NativeEnrichmentOutput), agent(NativeTargetAgentOutput) }
    private struct Skip: Error { let message: String }
    private let db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment, clock: () -> Date
    private let review: Review, agent: Agent, reviewTimeout: UInt64, agentTimeout: UInt64
    private var active = false
    private var cancelRequest: (id: String, cancel: () -> Void)?
    init(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(), clock: @escaping () -> Date = Date.init,
         reviewTimeout: UInt64 = 90_000_000_000, agentTimeout: UInt64 = 300_000_000_000, review: @escaping Review, agent: @escaping Agent) {
        self.db = db; self.store = store; self.environment = environment; self.clock = clock
        self.review = review; self.agent = agent; self.reviewTimeout = reviewTimeout; self.agentTimeout = agentTimeout
    }
    func cancel(_ id: String) { if cancelRequest?.id == id { cancelRequest?.cancel() } }
    private func owner(_ job: NativeJob) throws -> NativeTargetEnrichmentService {
        guard let id = job.payload["actorID"], let user = try db.get("Users", key: ["id": .text(id)]) else { throw Skip(message: "情報補完を予約した利用者を確認できません。") }
        return .init(service: .init(db: db, identity: .init(id: id, role: user["role"].string, partnerAccountID: user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string)), store: store, environment: environment, clock: clock)
    }
    private func history(_ job: NativeJob) throws -> NativeRecord {
        _ = try db.requireJobLease(job)
        guard NativeTargetEnrichment.events.contains(job.event), job.payload["enrichmentId"] == job.id,
              let row = try db.get(NativeTargetEnrichment.model, key: ["id": .text(job.id)]), row["targetId"].string == job.payload["targetId"],
              row["triggeredBy"].string == job.payload["actorID"], ["PENDING", "RUNNING"].contains(row["status"].string) else { throw NativeDBError.conflict }
        return row
    }
    private func current(_ job: NativeJob, service: NativeTargetEnrichmentService) throws -> (target: NativeRecord, contact: NativeRecord?) {
        try Task.checkCancellation(); _ = try history(job)
        guard let mode = job.payload["mode"].flatMap(NativeTargetEnrichment.Mode.init(rawValue:)),
              (mode == .contact) == (job.event == NativeTargetEnrichment.contactEvent) else { throw NativeDBError.conflict }
        let parent: NativeRecord
        do { parent = try service.target(job.payload["targetId"] ?? "", mcp: job.payload["mcpOrigin"] != nil) }
        catch { throw Skip(message: "営業対象が削除されたか、利用者の権限が変更されています。") }
        guard try NativeTargetEnrichment.identity(parent) == job.payload["identity"] else { throw Skip(message: "検索時から営業対象の氏名・会社・連絡先が変更されています。情報補完をやり直してください。") }
        if mode == .contact {
            guard try db.isLatestTargetContactJob(job) else { throw Skip(message: "この担当者には新しい情報補完が予約されています。") }
            let row: NativeRecord
            do { row = try service.contact(job.payload["contactId"] ?? "", targetID: parent["id"].string, mcp: job.payload["mcpOrigin"] != nil) }
            catch { throw Skip(message: "担当者が削除されたか、営業対象との関連が変更されています。") }
            guard try NativeTargetEnrichment.identity(row) == job.payload["contactIdentity"] else { throw Skip(message: "検索時から担当者の氏名・連絡先が変更されています。情報補完をやり直してください。") }
            return (parent, row)
        }
        return (parent, nil)
    }
    private func progress(_ value: NativeContactEnrichmentWorker.Progress, job: NativeJob, service: NativeTargetEnrichmentService, credentials: NativeTargetEnrichmentCredentials) throws {
        try db.transaction {
            _ = try current(job, service: service); try service.requireCurrent(credentials); try db.renewJobLease(job, now: clock(), seconds: 360)
            var state = try db.requireJobLease(job).result
            state["message"] = String(value.message.prefix(4000)); state["messageType"] = value.kind.rawValue
            state["sourceURL"] = value.sourceURL.map { String($0.prefix(8000)) }
            state["progressSequence"] = String((Int(state["progressSequence"] ?? "0") ?? 0) + 1)
            try db.recordJobResult(job, result: state)
        }
        db.notifyAIProgress()
    }
    private func request(_ job: NativeJob, context: NativeTargetEnrichmentContext, service: NativeTargetEnrichmentService, credentials: NativeTargetEnrichmentCredentials) async throws -> Response {
        let review = self.review, agent = self.agent, timeout = job.payload["mode"] == "review" ? reviewTimeout : agentTimeout
        let task = Task {
            try await withThrowingTaskGroup(of: Response.self) { group in
                group.addTask {
                    let report: Report = { try await self.progress($0, job: job, service: service, credentials: credentials) }
                    let result: Response
                    switch credentials {
                    case let .review(openai, firecrawl): result = .review(try await review(context, openai.key, firecrawl.key, report))
                    case let .agent(anthropic, connection): result = .agent(try await agent(context, anthropic.key, connection, report))
                    }
                    try Task.checkCancellation(); return result
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw NativeAIError(message: job.payload["mode"] == "review" ? "情報補完が90秒以内に完了しませんでした。" : "企業・担当者の取得が5分以内に完了しませんでした。", retryable: true)
                }
                defer { group.cancelAll() }; guard let result = try await group.next() else { throw CancellationError() }; return result
            }
        }
        cancelRequest = (job.id, { task.cancel() }); defer { cancelRequest = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    /// Returns nil for identifier collisions or a contact edited after the
    /// request started. Such contacts are counted in the result, never merged.
    private func upsert(_ candidate: NativeTargetAgentOutput.Contact, parent: NativeRecord, snapshot: String, written: inout [String: Int64], actor: String) throws -> NativeRecord? {
        guard let key = candidate.upsertKey else { return nil }
        let existing = try db.page(NativeTargetEnrichment.contactModel, fields: [], equal: ["targetId": parent["id"], key.name: .text(key.value)], limit: 1).rows.first
        let otherName = key.name == "email" ? "linkedinUrl" : "email", otherValue = key.name == "email" ? candidate.linkedinUrl : candidate.email
        if let otherValue, let other = try db.page(NativeTargetEnrichment.contactModel, fields: [], equal: ["targetId": parent["id"], otherName: .text(otherValue)], limit: 1).rows.first,
           other["id"] != existing?["id"] { return nil }
        var values: [String: SQLValue] = ["enrichStatus": .text(candidate.complete ? "COMPLETED" : "PENDING"), "enrichedAt": candidate.complete ? .text(NativeContactEnrichment.stamp(clock())) : .null]
        let row: NativeRecord
        if let existing {
            let id = existing["id"].string
            let revision = try written[id] ?? db.targetContactSnapshotRevision(id, snapshot: snapshot)
            guard revision == existing.revision else { return nil }
            for (name, value) in [("name", candidate.name), ("title", candidate.title), ("linkedinUrl", candidate.linkedinUrl)] { if let value { values[name] = .text(value) } }
            row = try db.update(existing, changes: values, actor: actor, action: "target_contact_enrichment")
        } else {
            values.merge(["targetId": parent["id"], "name": candidate.name.map(SQLValue.text) ?? .null, "email": candidate.email.map(SQLValue.text) ?? .null,
                          "title": candidate.title.map(SQLValue.text) ?? .null, "linkedinUrl": candidate.linkedinUrl.map(SQLValue.text) ?? .null,
                          "phone": candidate.phone.map(SQLValue.text) ?? .null, "source": .text("enriched")]) { _, new in new }
            row = try db.insert(NativeTargetEnrichment.contactModel, values: values, actor: actor)
        }
        written[row["id"].string] = row.revision; return row
    }
    private func finish(_ response: Response, job: NativeJob, initial: (target: NativeRecord, contact: NativeRecord?), fields: [NativeEnrichmentField], snapshot: String?, service: NativeTargetEnrichmentService, credentials: NativeTargetEnrichmentCredentials?, alreadyComplete: Bool = false) throws {
        try db.transaction {
            let fresh = try current(job, service: service), entry = try history(job)
            if let credentials { try service.requireCurrent(credentials) }
            let actor = service.service.identity.id, isMCP = job.payload["mcpOrigin"] != nil
            var state = try db.requireJobLease(job).result, stored: String, status = "COMPLETED", error: String?, applied: [String] = []
            if alreadyComplete { state["skipReason"] = "already_complete"; state["message"] = "役職とLinkedInは登録済みのため、取得を省略しました。"; state["messageType"] = "info" }
            switch response {
            case let .review(raw):
                let result = try raw.validated(for: fields); stored = try NativeContactEnrichment.json(result)
                status = result.status == .completed ? "COMPLETED" : result.status == .skipped ? "SKIPPED" : "FAILED"; error = result.error
            case let .agent(raw):
                let result = try raw.validated(); stored = try NativeContactEnrichment.json(result)
                if let person = fresh.contact, let before = initial.contact {
                    let matched = result.matchingContact(person)
                    var changes: [String: SQLValue] = ["enrichStatus": .text("COMPLETED"), "enrichedAt": .text(NativeContactEnrichment.stamp(clock()))]
                    for (name, value) in [("title", matched?.title), ("linkedinUrl", matched?.linkedinUrl), ("phone", matched?.phone)] {
                        if let value, !value.isEmpty, NativeAIEnvironment.trim(before[name].string).isEmpty, person[name] == before[name] { changes[name] = .text(value); applied.append(name) }
                    }
                    _ = try db.update(person, changes: changes, actor: actor, action: "target_contact_enrichment")
                    state["matchedContact"] = matched == nil ? "false" : "true"
                } else {
                    guard let snapshot else { throw NativeDBError.conflict }
                    var changes: [String: SQLValue] = [:], parent = fresh.target, written: [String: Int64] = [:], pending = Set<String>(), saved = 0, skipped = 0
                    for (name, value) in result.eligibleTargetFields(Set(fields.map(\.name))) {
                        if NativeAIEnvironment.trim(initial.target[name].string).isEmpty, parent[name] == initial.target[name] { changes[name] = .text(value) }
                    }
                    if !changes.isEmpty {
                        applied = changes.keys.sorted(); if !isMCP { changes["updatedBy"] = .text(actor) }
                        parent = try db.update(parent, changes: changes, actor: actor, action: "target_enrichment")
                    }
                    for candidate in result.contacts {
                        guard let contact = try upsert(candidate, parent: parent, snapshot: snapshot, written: &written, actor: actor) else { skipped += 1; continue }
                        saved += 1
                        if contact["enrichStatus"] == .text("PENDING") { pending.insert(contact["id"].string) } else { pending.remove(contact["id"].string) }
                    }
                    for id in pending.sorted() {
                        let contact = try service.contact(id, targetID: parent["id"].string, mcp: isMCP)
                        _ = try service.enqueue(parent, fields: [], mode: .contact, force: true, batch: job.payload["batchID"] ?? job.id, contact: contact, mcpOrigin: job.payload["mcpOrigin"])
                    }
                    state["contactsFound"] = String(result.contacts.count); state["contactsSaved"] = String(saved)
                    state["contactsSkipped"] = String(skipped); state["contactsQueued"] = String(pending.count)
                }
            }
            _ = try db.update(entry, changes: ["status": .text(status), "result": isMCP ? .null : .text(stored), "error": error.map(SQLValue.text) ?? .null], actor: actor)
            state["outcome"] = status.lowercased(); state["fieldsApplied"] = try NativeContactEnrichment.json(applied.sorted())
            if status == "FAILED" { try db.recordJobResult(job, result: state); try db.failJob(job, message: error ?? "情報補完を完了できませんでした。") }
            else { try db.finishJob(job, result: state, now: clock()) }
        }
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard let job = try db.claimJob(events: NativeTargetEnrichment.events, now: clock(), leaseSeconds: 360) else { return false }
        var snapshot: String?; defer { if let snapshot { try? db.discardTargetContactSnapshot(snapshot) }; db.notifyAIProgress() }
        do {
            let service = try owner(job)
            if job.event == NativeTargetEnrichment.bulkEvent { try service.fanoutMCP(job); return true }
            let isMCP = job.payload["mcpOrigin"] != nil
            guard let mode = job.payload["mode"].flatMap(NativeTargetEnrichment.Mode.init(rawValue:)) else { throw NativeDBError.conflict }
            let fields = try NativeContactEnrichment.decode([NativeEnrichmentField].self, job.payload["fields"] ?? "")
            if mode == .contact { guard fields.isEmpty else { throw NativeDBError.conflict } } else if isMCP { guard fields.allSatisfy({ $0.mcpRequested == true }) else { throw NativeDBError.conflict }; try NativeEnrichmentField.validate(fields) } else { try NativeTargetEnrichment.validate(fields) }
            let effectiveFields = isMCP && mode != .contact ? NativeTargetEnrichment.fields(NativeTargetEnrichment.automaticNames) : fields
            let initial = try db.transaction { () -> (target: NativeRecord, contact: NativeRecord?) in
                var rows = try current(job, service: service); let entry = try history(job)
                guard try NativeContactEnrichment.decode([String].self, entry["fields"].string) == (mode == .contact ? ["title", "linkedinUrl", "phone"] : fields.map(\.name)) else { throw NativeDBError.conflict }
                _ = try db.update(entry, changes: ["status": .text("RUNNING"), "error": .null], actor: service.service.identity.id)
                if let contact = rows.contact { rows.contact = try db.update(contact, changes: ["enrichStatus": .text("RUNNING")], actor: service.service.identity.id) }
                return rows
            }
            db.notifyAIProgress()
            if let contact = initial.contact, !contact["title"].string.isEmpty, !contact["linkedinUrl"].string.isEmpty {
                try finish(.agent(.init(target: [:], contacts: [], confidence: [:])), job: job, initial: initial, fields: fields, snapshot: nil, service: service, credentials: nil, alreadyComplete: true)
                return true
            }
            let credentials = try service.credentials(mode)
            if mode != .contact {
                guard !initial.target["company"].string.isEmpty || !initial.target["email"].string.isEmpty else { throw Skip(message: isMCP ? "No email or company on target" : "会社名とメールアドレスが登録されていません。") }
                if mode != .review, job.payload["force"] != "true" {
                    let recent = try db.page(NativeTargetEnrichment.model, fields: [], filter: .every([.equal("targetId", initial.target["id"]), .equal("status", .text("COMPLETED")), isMCP ? .all : .not(.arrayContains("fields", "title")),
                        .compareDate("createdAt", .greater, NativeContactEnrichment.stamp(clock().addingTimeInterval(-7 * 86400)))]), limit: 1)
                    if recent.total > 0 { throw Skip(message: isMCP ? "Enriched within last 7 days" : "過去7日以内に情報補完が完了しているため省略しました。") }
                }
            }
            try db.transaction {
                _ = try current(job, service: service); try service.requireCurrent(credentials); try db.renewJobLease(job, now: clock(), seconds: 360)
                if mode != .review && mode != .contact { snapshot = try db.snapshotTargetContacts(initial.target["id"].string) }
            }
            func optional(_ value: SQLValue) -> String? { value == .null ? nil : value.string }
            let context = NativeTargetEnrichmentContext(email: initial.contact.flatMap { optional($0["email"]) } ?? optional(initial.target["email"]),
                company: optional(initial.target["company"]), website: optional(initial.target["company_website"]),
                name: initial.contact.map { $0["name"].string } ?? [initial.target["first_name"].string, initial.target["last_name"].string].filter { !$0.isEmpty }.joined(separator: " "), fields: effectiveFields, mode: mode)
            let response: Response
            let hasCompany = !NativeAIEnvironment.trim(context.company ?? "").isEmpty || NativeTargetEnrichment.domain(website: context.website, email: nil) != nil
            let hasPersonalFields = NativeTargetEnrichment.reviewFields(fields).contains { $0.subject == .person }
            if mode == .review, !hasCompany, !hasPersonalFields, let email = context.email, !email.isEmpty, let reason = NativeEnrichmentSkipList().reason(email) {
                response = .review(.init(enrichments: [:], status: .skipped, error: reason))
            } else { response = try await request(job, context: context, service: service, credentials: credentials) }
            try finish(response, job: job, initial: initial, fields: effectiveFields, snapshot: snapshot, service: service, credentials: credentials)
        } catch {
            guard (try? db.requireJobLease(job)) != nil else { return true }
            try db.transaction {
                _ = try db.requireJobLease(job)
                let skip = error as? Skip, limit = job.event == NativeTargetEnrichment.contactEvent ? 3 : 4
                let retry = skip == nil && (error is CancellationError || (job.attempts < limit && ((error as? NativeAIError)?.retryable == true || { if case NativeDBError.conflict = error { return true }; return false }())))
                let message = skip?.message ?? NativeContactEnrichment.message(error), status = skip != nil ? "SKIPPED" : retry ? "PENDING" : "FAILED"
                if let entry = try db.get(NativeTargetEnrichment.model, key: ["id": .text(job.id)]), entry["targetId"].string == job.payload["targetId"], entry["triggeredBy"].string == job.payload["actorID"] {
                    _ = try db.update(entry, changes: ["status": .text(status), "error": .text(message)], actor: job.payload["actorID"] ?? "enrichment-worker")
                }
                if job.event == NativeTargetEnrichment.contactEvent, try db.isLatestTargetContactJob(job),
                   let contact = try db.get(NativeTargetEnrichment.contactModel, key: ["id": .text(job.payload["contactId"] ?? "")]),
                   contact["targetId"].string == job.payload["targetId"], try NativeTargetEnrichment.identity(contact) == job.payload["contactIdentity"] {
                    _ = try db.update(contact, changes: ["enrichStatus": .text(status)], actor: job.payload["actorID"] ?? "enrichment-worker")
                }
                if skip != nil { try db.finishJob(job, result: ["outcome": "skipped", "reason": message], now: clock()) }
                else { try db.failJob(job, message: message, retryAt: retry ? clock().addingTimeInterval(min(300, 5 * pow(2, Double(min(job.attempts - 1, 6))))) : nil) }
            }
        }
        return true
    }
}
