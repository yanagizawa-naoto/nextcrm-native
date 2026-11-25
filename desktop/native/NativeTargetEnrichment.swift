import Foundation

enum NativeTargetEnrichment {
    static let event = "enrich/target.run", contactEvent = "enrich/target.contact.run"
    static let model = "crm_Target_Enrichment", contactModel = "crm_Target_Contact"
    static let bulkEvent = "enrich/targets.bulk"
    static let events = [event, contactEvent, bulkEvent]
    enum Mode: String, Codable { case review, automatic, bulk, contact }
    static let presets: [NativeEnrichmentField] = [
        .init(name: "personal_email", displayName: "個人のメールアドレス", description: "本人の個人用メールアドレス"),
        .init(name: "position", displayName: "役職", description: "本人の勤務先での役職・担当"),
        .init(name: "company", displayName: "会社名", description: "本人の勤務先の会社名"),
        .init(name: "company_website", displayName: "会社のウェブサイト", description: "会社の公式ウェブサイトURL"),
        .init(name: "personal_website", displayName: "個人のウェブサイト", description: "本人のウェブサイトURL"),
        .init(name: "mobile_phone", displayName: "携帯電話番号", description: "本人の携帯電話番号"),
        .init(name: "office_phone", displayName: "勤務先の電話番号", description: "本人の勤務先の電話番号"),
        .init(name: "social_linkedin", displayName: "LinkedIn", description: "本人または会社のLinkedInプロフィールURL"),
        .init(name: "social_x", displayName: "X", description: "本人または会社のXプロフィールURL"),
        .init(name: "social_instagram", displayName: "Instagram", description: "本人または会社のInstagramプロフィールURL"),
        .init(name: "social_facebook", displayName: "Facebook", description: "本人または会社のFacebookページURL"),
        .init(name: "company_email", displayName: "会社のメールアドレス", description: "会社の代表窓口のメールアドレス"),
        .init(name: "company_phone", displayName: "会社の代表電話", description: "会社の代表電話番号"),
        .init(name: "city", displayName: "本社の市区町村", description: "会社の本社がある市区町村"),
        .init(name: "country", displayName: "国・地域", description: "会社の本社がある国・地域"),
        .init(name: "industry", displayName: "業種", description: "会社の業種・事業分野"),
        .init(name: "employees", displayName: "従業員数", description: "会社のおおよその従業員数"),
        .init(name: "description", displayName: "会社の説明", description: "会社の事業内容の概要")
    ]
    static let columns = Set(presets.map(\.name))
    static let personalNames = ["position", "company", "company_website", "social_linkedin", "social_x", "mobile_phone", "office_phone", "personal_website", "personal_email", "social_instagram", "social_facebook"]
    static let companyNames = ["company_website", "industry", "employees", "description", "city", "country", "company_email", "company_phone", "social_linkedin"]
    static let personalDefaults = ["position", "company", "social_linkedin", "company_website"]
    static let companyDefaults = ["industry", "employees", "description", "city", "country", "company_website"]
    static let automaticNames = ["company_website", "industry", "employees", "city", "company_phone", "social_linkedin", "social_x", "description"]
    enum Scenario: String { case personal, company }
    static func fields(_ names: [String], scenario: Scenario = .company) -> [NativeEnrichmentField] {
        names.compactMap { name in
            guard let field = presets.first(where: { $0.name == name }) else { return nil }
            let personal = ["position", "personal_website", "personal_email", "mobile_phone", "office_phone"].contains(name)
                || scenario == .personal && (name == "company" || name.hasPrefix("social_"))
            let subject: NativeEnrichmentField.Subject = personal ? .person : .company
            let social = name.hasPrefix("social_")
            return .init(name: name, displayName: social ? field.displayName + (personal ? "（本人）" : "（会社）") : field.displayName,
                description: social ? (personal ? "本人の" : "会社の公式") + field.displayName + "プロフィールURL" : field.description,
                type: field.type, required: field.required, subject: subject)
        }
    }
    static func reviewFields(_ input: [NativeEnrichmentField]) -> [NativeEnrichmentField] {
        input.map { field in
            guard field.subject == nil else { return field }
            var copy = field
            // Legacy combined presets described the person's social profile.
            copy.subject = fields([field.name], scenario: .personal).first?.subject
            return copy
        }
    }
    static func validate(_ fields: [NativeEnrichmentField]) throws {
        try NativeEnrichmentField.validate(fields)
        guard fields.allSatisfy({ columns.contains($0.name) }) else {
            throw NativeAIError(message: "営業対象で利用できる補完項目を選択してください。")
        }
    }
    static func identity(_ row: NativeRecord) throws -> String {
        let names = row.model == contactModel ? ["targetId", "contactId", "name", "email", "linkedinUrl"] : ["first_name", "last_name", "email", "company", "company_website"]
        return try NativeContactEnrichment.json(Dictionary(uniqueKeysWithValues: names.map { ($0, row[$0] == .null ? nil : row[$0].string) }))
    }
    static func domain(website: String?, email: String?) -> String? {
        // Only a browsable company website is useful to the remote agent.
        if let website, let url = URL(string: website), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty {
            let lower = host.lowercased(); return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        guard let email else { return nil }
        let parts = email.components(separatedBy: "@")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].contains(where: { $0.isWhitespace }),
              !["gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "icloud.com", "aol.com", "protonmail.com", "me.com"].contains(parts[1].lowercased()) else { return nil }
        return parts[1]
    }
}

struct NativeTargetAgentOutput: Codable, Equatable {
    struct Contact: Codable, Equatable {
        var name: String? = nil, email: String? = nil, title: String? = nil, linkedinUrl: String? = nil, phone: String? = nil, source: String? = nil
        var complete: Bool { !(title ?? "").isEmpty && !(linkedinUrl ?? "").isEmpty }
        var upsertKey: (name: String, value: String)? {
            if let email, !NativeAIEnvironment.trim(email).isEmpty { return ("email", email) }
            if let linkedinUrl, !NativeAIEnvironment.trim(linkedinUrl).isEmpty { return ("linkedinUrl", linkedinUrl) }
            return nil
        }
    }
    var target: [String: String?], contacts: [Contact], confidence: [String: Double]
    private enum CodingKeys: String, CodingKey { case target, contacts, confidence }
    init(target: [String: String?], contacts: [Contact], confidence: [String: Double]) { self.target = target; self.contacts = contacts; self.confidence = confidence }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode([String: String?].self, forKey: .target)
        contacts = try values.decodeIfPresent([Contact].self, forKey: .contacts) ?? []
        confidence = try values.decode([String: Double].self, forKey: .confidence)
    }
    func validated() throws -> Self {
        guard target.count <= 128, confidence.count <= 128, contacts.count <= 1000 else { throw NativeAIError(message: "企業情報の取得結果が扱える大きさを超えています。") }
        let strings = target.values.compactMap { $0 } + contacts.flatMap { [$0.name, $0.email, $0.title, $0.linkedinUrl, $0.phone, $0.source].compactMap { $0 } }
        guard confidence.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              strings.allSatisfy({ $0.utf8.count <= 65_536 }),
              try JSONEncoder().encode(self).count <= 2 * 1024 * 1024 else {
            throw NativeAIError(message: "企業情報の取得結果が不正か、扱える大きさを超えています。")
        }
        return self
    }
    func eligibleTargetFields(_ requested: Set<String>) -> [String: String] {
        target.reduce(into: [:]) { result, entry in
            if requested.contains(entry.key), NativeTargetEnrichment.columns.contains(entry.key),
               let value = entry.value, !value.isEmpty, (confidence[entry.key] ?? 1) >= 0.6 { result[entry.key] = value }
        }
    }
    /// Prefer identifiers and exact full names. The original first-name fallback
    /// is retained only when it identifies one candidate without conflicting IDs.
    func matchingContact(_ row: NativeRecord) -> Contact? {
        func name(_ value: String?) -> String { (value ?? "").precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace } }
        func email(_ value: String?) -> String { NativeAIEnvironment.trim(value ?? "").lowercased() }
        func linkedin(_ value: String?) -> String { NativeAIEnvironment.trim(value ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let mail = email(row["email"].string), link = linkedin(row["linkedinUrl"].string), fullName = name(row["name"].string)
        let candidates = contacts.filter { c in
            (mail.isEmpty || email(c.email).isEmpty || email(c.email) == mail) && (link.isEmpty || linkedin(c.linkedinUrl).isEmpty || linkedin(c.linkedinUrl) == link)
        }
        func unique(_ values: [Contact]) -> Contact? { let distinct = values.reduce(into: [Contact]()) { if !$0.contains($1) { $0.append($1) } }; return distinct.count == 1 ? distinct[0] : nil }
        if !mail.isEmpty { let matches = candidates.filter { email($0.email) == mail }; if !matches.isEmpty { return unique(matches) } }
        if !link.isEmpty { let matches = candidates.filter { linkedin($0.linkedinUrl) == link }; if !matches.isEmpty { return unique(matches) } }
        guard !fullName.isEmpty else { return nil }
        let exact = candidates.filter { name($0.name) == fullName }; if !exact.isEmpty { return unique(exact) }
        let first = row["name"].string.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard !first.isEmpty else { return nil }
        return unique(candidates.filter { name($0.name).contains(name(first)) })
    }
}

struct NativeTargetEnrichmentContext {
    let email: String?, company: String?, website: String?, name: String?, fields: [NativeEnrichmentField]
    var mode: NativeTargetEnrichment.Mode = .automatic
    var knownDomain: String? { NativeTargetEnrichment.domain(website: website, email: email) }
}

enum NativeTargetEnrichmentCredentials {
    case review(openai: NativeAIResolvedKey, firecrawl: NativeAIResolvedKey)
    // E2B is an environment setting in the original application, not a fifth
    // Prisma ApiKeys provider. Never persist this secret in jobs or history.
    case agent(anthropic: NativeAIResolvedKey, connection: NativeE2BConnection)
}

struct NativeTargetEnrichmentPreview {
    let history: NativeRecord, target: NativeRecord, result: NativeEnrichmentOutput
}

struct NativeTargetEnrichmentService {
    let service: CRMService, store: NativeAISecretStore
    var environment = NativeAIEnvironment()
    var clock: () -> Date = Date.init
    var db: NativeDatabase { service.db }
    var keys: NativeAIKeys { .init(service: service, store: store, environment: environment, clock: clock) }
    func internalAccess() throws {
        try service.authenticated()
        guard ["user", "manager", "admin"].contains(service.identity.role) else { throw NativeAIError(message: "この利用者は営業対象の情報補完を実行できません。") }
    }
    func target(_ id: String) throws -> NativeRecord { try target(id, mcp: false) }
    func target(_ id: String, mcp: Bool) throws -> NativeRecord {
        try internalAccess(); try service.assertAccess("crm_Targets", id: id, write: true, includeDeleted: mcp)
        guard let row = try db.get("crm_Targets", key: ["id": .text(id)]), mcp || row["deletedAt"] == .null else { throw NativeDBError.conflict }; return row
    }
    func contact(_ id: String, targetID: String) throws -> NativeRecord { try contact(id, targetID: targetID, mcp: false) }
    func contact(_ id: String, targetID: String, mcp: Bool) throws -> NativeRecord {
        _ = try target(targetID, mcp: mcp)
        guard let row = try db.get(NativeTargetEnrichment.contactModel, key: ["id": .text(id)]), row["targetId"] == .text(targetID) else { throw NativeDBError.conflict }; return row
    }
    var e2bSettings: NativeE2BSettings { .init(service: service, store: store, environment: environment, clock: clock) }
    func credentials(_ mode: NativeTargetEnrichment.Mode) throws -> NativeTargetEnrichmentCredentials {
        try internalAccess()
        if mode == .review {
            guard let openai = try keys.resolve(.openai), let firecrawl = try keys.resolve(.firecrawl) else { throw NativeAIError(message: "AI連携の設定でOpenAIとFirecrawlのAPIキーを保存してください。") }
            return .review(openai: openai, firecrawl: firecrawl)
        }
        guard let anthropic = try keys.resolve(.anthropic) else { throw NativeAIError(message: "AI連携の設定でAnthropicのAPIキーを保存してください。") }
        guard let connection = try e2bSettings.resolve() else { throw NativeAIError(message: "企業・担当者の自動取得にはE2Bの接続設定が必要です。AI連携の設定から管理者が保存してください。") }
        return .agent(anthropic: anthropic, connection: connection)
    }
    func requireCurrent(_ credentials: NativeTargetEnrichmentCredentials) throws {
        switch credentials {
        case let .review(openai, firecrawl): try keys.requireCurrent(openai); try keys.requireCurrent(firecrawl)
        case let .agent(anthropic, connection):
            try keys.requireCurrent(anthropic)
            try e2bSettings.requireCurrent(connection)
        }
    }
    @discardableResult func request(targetIDs: [String], fields: [NativeEnrichmentField], mode: NativeTargetEnrichment.Mode, force: Bool = false) throws -> [String] {
        try NativeTargetEnrichment.validate(fields)
        guard mode != .contact, !targetIDs.isEmpty, targetIDs.count <= (mode == .bulk ? 100 : 1), Set(targetIDs).count == targetIDs.count else {
            throw NativeAIError(message: "単件では1件、一括では重複のない1〜100件の営業対象を選択してください。")
        }
        try db.transaction { for id in targetIDs { _ = try target(id) } }
        let resolved = try credentials(mode)
        return try db.transaction {
            try requireCurrent(resolved); let batch = UUID().uuidString.lowercased()
            return try targetIDs.map { id in
                let row = try target(id)
                guard mode != .review || !row["email"].string.isEmpty || !row["company"].string.isEmpty else { throw NativeAIError(message: "メールアドレスまたは会社名を登録してください。") }
                return try enqueue(row, fields: fields, mode: mode, force: force, batch: batch)
            }
        }
    }
    @discardableResult func requestContact(_ contactID: String, targetID: String) throws -> String {
        _ = try contact(contactID, targetID: targetID); let resolved = try credentials(.contact)
        return try db.transaction {
            try requireCurrent(resolved)
            let parent = try target(targetID), row = try contact(contactID, targetID: targetID)
            return try enqueue(parent, fields: [], mode: .contact, force: true, batch: UUID().uuidString.lowercased(), contact: row)
        }
    }
    func enqueue(_ row: NativeRecord, fields: [NativeEnrichmentField], mode: NativeTargetEnrichment.Mode, force: Bool, batch: String, contact: NativeRecord? = nil, mcpOrigin: String? = nil, originalFields: String? = nil, existingHistory: NativeRecord? = nil) throws -> String {
        if mcpOrigin != nil { guard fields.allSatisfy({ !$0.name.contains("\0") }) else { throw NativeDBError.conflict } }
        let history = try existingHistory ?? db.insert(NativeTargetEnrichment.model, values: ["targetId": row["id"], "status": .text("PENDING"),
            "fields": .text(NativeContactEnrichment.json(mode == .contact ? ["title", "linkedinUrl", "phone"] : fields.map(\.name))),
            "triggeredBy": .text(service.identity.id), "createdAt": .text(NativeContactEnrichment.stamp(clock()))], actor: service.identity.id)
        let id = history["id"].string
        var payload = ["actorID": service.identity.id, "targetId": row["id"].string, "enrichmentId": id, "mode": mode.rawValue,
                       "identity": try NativeTargetEnrichment.identity(row), "fields": try NativeContactEnrichment.json(fields), "force": force ? "true" : "false", "batchID": batch]
        payload["mcpOrigin"] = mcpOrigin; payload["mcpFields"] = originalFields
        if let contact { payload["contactId"] = contact["id"].string; payload["contactIdentity"] = try NativeTargetEnrichment.identity(contact) }
        try db.enqueue(mode == .contact ? NativeTargetEnrichment.contactEvent : NativeTargetEnrichment.event, payload: payload, id: id, now: clock())
        return id
    }
    func fanoutMCP(_ job: NativeJob) throws {
        try db.transaction {
            _ = try db.requireJobLease(job); try internalAccess()
            guard job.event == NativeTargetEnrichment.bulkEvent, job.payload["mcpOrigin"] == "bulk", job.payload["actorID"] == service.identity.id else { throw NativeDBError.conflict }
            let ids = try NativeContactEnrichment.decode([String].self, job.payload["ids"] ?? "")
            let fields = try NativeContactEnrichment.decode([NativeEnrichmentField].self, job.payload["fields"] ?? "")
            guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count, !fields.isEmpty, fields.allSatisfy({ $0.mcpRequested == true }) else { throw NativeDBError.conflict }
            for id in ids { _ = try enqueue(target(id, mcp: true), fields: fields, mode: .bulk, force: false, batch: job.id, mcpOrigin: "bulk", originalFields: job.payload["mcpFields"]) }
            try db.finishJob(job, result: ["dispatched": String(ids.count)], now: clock())
        }
    }
    func history(targetID: String, offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        _ = try target(targetID)
        return try db.page(NativeTargetEnrichment.model, fields: ["targetId", "status", "fields", "error", "triggeredBy", "createdAt", "updatedAt"], equal: ["targetId": .text(targetID)], offset: offset, sort: "createdAt", descending: true)
    }
    func preview(_ id: String) throws -> NativeTargetEnrichmentPreview {
        try db.transaction {
            try internalAccess()
            guard let history = try db.get(NativeTargetEnrichment.model, key: ["id": .text(id)]), history["status"] == .text("COMPLETED") else { throw NativeDBError.conflict }
            let row = try target(history["targetId"].string)
            if let job = try db.job(id: id) {
                guard job.event == NativeTargetEnrichment.event, job.payload["mode"] == "review", job.status == "done",
                      job.payload["enrichmentId"] == id, job.payload["actorID"] == history["triggeredBy"].string,
                      job.payload["targetId"] == row["id"].string, try job.payload["identity"] == NativeTargetEnrichment.identity(row) else {
                    throw NativeAIError(message: "検索時から営業対象が変更されたか、自動反映済みの履歴です。確認用の情報補完をやり直してください。")
                }
            }
            let result = try NativeContactEnrichment.decode(NativeEnrichmentOutput.self, history["result"].string)
            guard result.status == .completed else { throw NativeDBError.conflict }
            return .init(history: history, target: row, result: result)
        }
    }
    @discardableResult func apply(_ expected: NativeTargetEnrichmentPreview, selected: Set<String>) throws -> [String] {
        try db.transaction {
            let current = try preview(expected.history["id"].string)
            guard current.history.revision == expected.history.revision, try NativeTargetEnrichment.identity(current.target) == NativeTargetEnrichment.identity(expected.target) else { throw NativeDBError.conflict }
            var changes: [String: SQLValue] = [:]
            for name in selected.sorted() where NativeTargetEnrichment.columns.contains(name) {
                guard let value = current.result.enrichments[name], value.value.truthy else { continue }
                guard current.target[name] == expected.target[name] else { throw NativeDBError.conflict }
                if current.target[name] != .text(value.value.text) { changes[name] = .text(value.value.text) }
            }
            guard !changes.isEmpty else { return [] }; let applied = changes.keys.sorted()
            changes["updatedBy"] = .text(service.identity.id)
            _ = try db.update(current.target, changes: changes, actor: service.identity.id, action: "apply_enrichment")
            return applied
        }
    }
    private func control(_ expected: NativeJob, cancel: Bool) throws -> NativeRecord {
        try internalAccess()
        guard NativeTargetEnrichment.events.contains(expected.event), expected.payload["enrichmentId"] == expected.id, try db.job(id: expected.id) == expected,
              let row = try db.get(NativeTargetEnrichment.model, key: ["id": .text(expected.id)]), row["targetId"].string == expected.payload["targetId"],
              row["triggeredBy"].string == expected.payload["actorID"], service.identity.elevated || row["triggeredBy"] == .text(service.identity.id) else { throw NativeDBError.conflict }
        if !cancel {
            guard expected.payload["actorID"] == service.identity.id, let mode = expected.payload["mode"].flatMap(NativeTargetEnrichment.Mode.init(rawValue:)),
                  try NativeTargetEnrichment.identity(target(row["targetId"].string, mcp: expected.payload["mcpOrigin"] != nil)) == expected.payload["identity"] else { throw NativeDBError.conflict }
            if mode == .contact {
                guard try db.isLatestTargetContactJob(expected), try NativeTargetEnrichment.identity(contact(expected.payload["contactId"] ?? "", targetID: row["targetId"].string, mcp: expected.payload["mcpOrigin"] != nil)) == expected.payload["contactIdentity"] else { throw NativeDBError.conflict }
            }
            _ = try credentials(mode)
        }
        return row
    }
    func cancel(_ expected: NativeJob) throws {
        try db.transaction {
            let row = try control(expected, cancel: true)
            try db.cancelAIJob(expected, events: NativeTargetEnrichment.events)
            _ = try db.update(row, changes: ["status": .text("FAILED"), "error": .text("利用者が取り消しました。")], actor: service.identity.id, action: "cancel_enrichment")
            if expected.event == NativeTargetEnrichment.contactEvent, try db.isLatestTargetContactJob(expected),
               let contact = try db.get(NativeTargetEnrichment.contactModel, key: ["id": .text(expected.payload["contactId"] ?? "")]),
               contact["targetId"] == row["targetId"] {
                _ = try db.update(contact, changes: ["enrichStatus": .text("FAILED")], actor: service.identity.id, action: "cancel_enrichment")
            }
        }
    }
    func retry(_ expected: NativeJob) throws {
        try db.transaction {
            let row = try control(expected, cancel: false)
            try db.retryAIJob(expected, events: NativeTargetEnrichment.events)
            _ = try db.update(row, changes: ["status": .text("PENDING"), "error": .null, "result": .null], actor: service.identity.id, action: "retry_enrichment")
        }
    }
}
