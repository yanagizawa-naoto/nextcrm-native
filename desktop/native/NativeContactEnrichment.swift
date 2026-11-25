import Foundation

struct NativeEnrichmentField: Codable, Equatable {
    enum Kind: String, Codable { case string, number, boolean, array }
    enum Subject: String, Codable { case person, company }
    let name: String, displayName: String, description: String
    var type: Kind = .string
    var required = false
    // Optional so queued requests from earlier versions continue to decode.
    var subject: Subject? = nil
    // Set only by the internal MCP bridge, never inferred from a requested name.
    var mcpRequested: Bool? = nil
    static let contactPresets: [Self] = [
        .init(name: "position", displayName: "役職", description: "連絡先の勤務先での役職"),
        .init(name: "website", displayName: "会社のウェブサイト", description: "会社の公式ウェブサイトURL"),
        .init(name: "social_linkedin", displayName: "LinkedIn", description: "連絡先または会社のLinkedInプロフィールURL"),
        .init(name: "social_twitter", displayName: "X", description: "連絡先または会社のXプロフィールURL"),
        .init(name: "social_facebook", displayName: "Facebook", description: "連絡先または会社のFacebookページURL"),
        .init(name: "social_instagram", displayName: "Instagram", description: "連絡先または会社のInstagramプロフィールURL"),
        .init(name: "description", displayName: "会社の説明", description: "会社の事業内容の概要"),
        .init(name: "office_phone", displayName: "勤務先の電話番号", description: "会社または勤務先の電話番号"),
        .init(name: "mobile_phone", displayName: "携帯電話番号", description: "連絡先の携帯電話番号")
    ]
    static let contactColumns = Set(contactPresets.map(\.name))
    static func validate(_ fields: [Self]) throws {
        if !fields.isEmpty, fields.allSatisfy({ $0.mcpRequested == true }) { return }
        guard !fields.isEmpty, fields.allSatisfy({ !NativeAIEnvironment.trim($0.name).isEmpty && !NativeAIEnvironment.trim($0.displayName).isEmpty }),
              Set(fields.map(\.name)).count == fields.count else {
            throw NativeAIError(message: "補完する項目を選択してください。同じ項目名は複数指定できません。")
        }
    }
}

/// The original result JSON uses scalar values and arrays of strings. Keep that
/// representation, including false/zero and provenance, in the history record.
enum NativeEnrichmentValue: Codable, Equatable {
    case null, string(String), number(Double), boolean(Bool), array([String])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .boolean(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Double.self), n.isFinite { self = .number(n) }
        else { self = .array(try c.decode([String].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case let .string(v): try c.encode(v)
        case let .number(v): try c.encode(v); case let .boolean(v): try c.encode(v); case let .array(v): try c.encode(v) }
    }
    var truthy: Bool {
        switch self { case .null: return false; case let .string(v): return !v.isEmpty
        case let .number(v): return v != 0 && v.isFinite; case let .boolean(v): return v; case .array: return true }
    }
    var text: String {
        switch self {
        case .null: return "null"
        case let .string(v): return v
        case let .boolean(v): return v ? "true" : "false"
        case let .array(v): return v.joined(separator: ",")
        case let .number(v):
            if v == 0 { return "0" }
            let absolute = abs(v)
            if absolute >= 1e-6 && absolute < 1e21 {
                // Decimal expands Swift's shortest round-trip representation.
                let decimal = Decimal(string: String(v), locale: Locale(identifier: "en_US_POSIX"))
                return decimal.map { NSDecimalNumber(decimal: $0).stringValue } ?? String(v)
            }
            return String(v).replacingOccurrences(of: ".0e", with: "e")
                .replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: "e+0", with: "e+")
        }
    }
}

struct NativeEnrichmentResult: Codable, Equatable {
    struct Source: Codable, Equatable { let url: String, snippet: String }
    struct Corroboration: Codable, Equatable {
        struct Evidence: Codable, Equatable { let value: NativeEnrichmentValue; let source_url: String, exact_text: String; let confidence: Double }
        let evidence: [Evidence], sources_agree: Bool
    }
    let field: String
    let value: NativeEnrichmentValue
    let confidence: Double
    var source: String? = nil
    var sourceContext: [Source]? = nil
    var sourceCount: Int? = nil
    var corroboration: Corroboration? = nil
}

struct NativeEnrichmentOutput: Codable, Equatable {
    enum Status: String, Codable { case completed, error, skipped }
    var enrichments: [String: NativeEnrichmentResult]
    let status: Status
    var error: String? = nil
    func validated(for fields: [NativeEnrichmentField]) throws -> Self {
        let requested = Set(fields.map(\.name))
        guard enrichments.allSatisfy({ key, result in
            requested.contains(key) && result.field == key && result.confidence.isFinite && (0...1).contains(result.confidence)
        }) else { throw NativeAIError(message: "情報補完の応答に、指定していない項目または不正な確信度が含まれています。") }
        var copy = self; copy.enrichments = copy.enrichments.filter { $0.value.value != .null }; return copy
    }
}

enum NativeContactEnrichment {
    static let event = "enrich/contact.run", bulkEvent = "enrich/contacts.bulk", model = "crm_Contact_Enrichment"
    static let events = [event, bulkEvent]
    enum Mode: String, Codable { case review, bulk }
    static func mcpScope(_ service: CRMService, single: Bool) -> RecordFilter {
        if service.identity.elevated { return .all }
        guard service.identity.role == "user" else { return .none }
        let user = SQLValue.text(service.identity.id)
        let owner = RecordFilter.any([.equal("assigned_to", user), .equal("createdBy", user)])
        if single { return owner }
        // Original contactReadScopeWhere does not exclude a deleted linked
        // account. This compatibility scope is confined to MCP requests.
        let account = RecordFilter.any([.equal("assigned_to", user), .equal("createdBy", user),
            .relation(model: "AccountWatchers", local: "id", foreign: "account_id", matching: .equal("user_id", user))])
        return .any([owner, .relation(model: "crm_Accounts", local: "accountsIDs", foreign: "id", matching: account)])
    }
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        guard let parsed = try? JSONDecoder().decode(type, from: Data(value.utf8)) else {
            throw NativeAIError(message: "情報補完の保存内容を読み取れません。新しい処理を開始してください。")
        }; return parsed
    }
    static func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f.string(from: date)
    }
    static func mcpSkipReason(_ email: String, domains: Set<String>) -> String {
        let parts = email.components(separatedBy: "@")
        guard parts.count > 1, !parts[1].isEmpty else { return "Invalid email" }
        let domain = parts[1].lowercased()
        if domains.contains(domain) {
            if ["gmail.com", "yahoo.com", "hotmail.com", "outlook.com", "aol.com", "icloud.com"].contains(domain) { return "Common email provider" }
            return domain.contains("mail") ? "Temporary/free email service" : "Domain in skip list"
        }
        return domain.hasSuffix(".edu") || domain.hasSuffix(".ac.uk") ? "Educational domain" : "Unknown"
    }
    static func message(_ error: Error) -> String {
        if let e = error as? NativeAIError { return e.message }
        if error is CancellationError { return "情報補完を中断しました。次回起動時に再開します。" }
        if case NativeDBError.conflict = error { return "処理中にデータ・権限・APIキーが変更されました。最新の状態で再実行します。" }
        // Do not store arbitrary provider errors, which can contain credentials
        // or raw responses. Provider adapters return a sanitized NativeAIError.
        return "情報補完を完了できませんでした。設定と対象データを確認してください。"
    }
}

struct NativeContactEnrichmentPreview {
    let history: NativeRecord, contact: NativeRecord, result: NativeEnrichmentOutput
}

struct NativeContactEnrichmentService {
    let service: CRMService, store: NativeAISecretStore
    var environment = NativeAIEnvironment()
    var clock: () -> Date = Date.init
    var db: NativeDatabase { service.db }
    var keys: NativeAIKeys { .init(service: service, store: store, environment: environment, clock: clock) }
    func internalAccess() throws {
        try service.authenticated()
        guard ["user", "manager", "admin"].contains(service.identity.role) else { throw NativeAIError(message: "この利用者は情報補完を実行できません。") }
    }
    func contact(_ id: String, mode: NativeContactEnrichment.Mode) throws -> NativeRecord { try contact(id, mode: mode, mcp: false) }
    func contact(_ id: String, mode: NativeContactEnrichment.Mode, mcp: Bool) throws -> NativeRecord {
        try internalAccess()
        // Original bulk authorization includes linked-account read access;
        // single enrichment and explicit application require direct write scope.
        if mcp {
            let scope = RecordFilter.every([NativeContactEnrichment.mcpScope(service, single: mode == .review), .equal("id", .text(id))])
            guard try db.page("crm_Contacts", fields: [], includeDeleted: mode == .review, filter: scope, limit: 1).total == 1 else { throw NativeDBError.conflict }
        } else { try service.assertAccess("crm_Contacts", id: id, write: mode == .review) }
        guard let row = try db.get("crm_Contacts", key: ["id": .text(id)]), (mcp && mode == .review) || row["deletedAt"] == .null else { throw NativeDBError.conflict }; return row
    }
    func credentials() throws -> (openai: NativeAIResolvedKey, firecrawl: NativeAIResolvedKey) { try credentials(mcp: false) }
    func credentials(mcp: Bool) throws -> (openai: NativeAIResolvedKey, firecrawl: NativeAIResolvedKey) {
        if mcp {
            let firecrawl = try keys.resolve(.firecrawl), openai = try keys.resolve(.openai)
            guard let firecrawl, let openai else { throw NativeAIError(message: "NO_API_KEY: configure keys in admin or profile settings") }; return (openai, firecrawl)
        }
        guard let openai = try keys.resolve(.openai), let firecrawl = try keys.resolve(.firecrawl) else {
            throw NativeAIError(message: "AI連携の設定でOpenAIとFirecrawlのAPIキーを保存してください。")
        }; return (openai, firecrawl)
    }
    @discardableResult func request(contactIDs: [String], fields: [NativeEnrichmentField], mode: NativeContactEnrichment.Mode) throws -> [String] {
        try NativeEnrichmentField.validate(fields)
        guard !contactIDs.isEmpty, contactIDs.count <= (mode == .review ? 1 : 100), Set(contactIDs).count == contactIDs.count else {
            throw NativeAIError(message: "単件では1件、一括では重複のない1〜100件の連絡先を選択してください。")
        }
        try db.transaction { for id in contactIDs { _ = try contact(id, mode: mode) } }
        let resolved = try credentials()
        return try db.transaction {
            try keys.requireCurrent(resolved.openai); try keys.requireCurrent(resolved.firecrawl)
            let batchID = UUID().uuidString.lowercased(), now = clock()
            return try contactIDs.map { id in
                let row = try contact(id, mode: mode), email = row["email"].string
                guard mode == .bulk || !email.isEmpty else { throw NativeAIError(message: "連絡先にメールアドレスを登録してから情報補完を実行してください。") }
                let history = try db.insert(NativeContactEnrichment.model, values: [
                    "contactId": .text(id), "status": .text("PENDING"), "fields": .text(NativeContactEnrichment.json(fields.map(\.name))),
                    "triggeredBy": .text(service.identity.id), "createdAt": .text(NativeContactEnrichment.stamp(now))
                ], actor: service.identity.id)
                let historyID = history["id"].string
                try db.enqueue(NativeContactEnrichment.event, payload: ["actorID": service.identity.id, "contactId": id,
                    "enrichmentId": historyID, "mode": mode.rawValue, "email": email, "batchID": batchID,
                    "fields": NativeContactEnrichment.json(fields)], id: historyID, now: now)
                return historyID
            }
        }
    }
    /// Native outbox bridge for the source MCP single/bulk events. The raw field
    /// objects are retained separately from provider/UI metadata.
    @discardableResult func enqueueMCP(_ row: NativeRecord, fields: [NativeEnrichmentField], originalFields: String, single: Bool, batch: String, history: NativeRecord? = nil) throws -> String {
        guard !fields.isEmpty, fields.allSatisfy({ $0.mcpRequested == true && !$0.name.contains("\0") }) else { throw NativeDBError.conflict }
        let entry = try history ?? db.insert(NativeContactEnrichment.model, values: ["contactId": row["id"], "status": .text("PENDING"),
            "fields": .text(NativeContactEnrichment.json(fields.map(\.name))), "triggeredBy": .text(service.identity.id),
            "createdAt": .text(NativeContactEnrichment.stamp(clock()))], actor: service.identity.id)
        let id = entry["id"].string
        try db.enqueue(NativeContactEnrichment.event, payload: ["actorID": service.identity.id, "contactId": row["id"].string, "enrichmentId": id,
            "mode": single ? "review" : "bulk", "email": row["email"].string, "batchID": batch, "mcpOrigin": single ? "single" : "bulk",
            "fields": NativeContactEnrichment.json(fields), "mcpFields": originalFields], id: id, now: clock())
        return id
    }
    func fanoutMCP(_ job: NativeJob) throws {
        try db.transaction {
            _ = try db.requireJobLease(job); try internalAccess()
            guard job.event == NativeContactEnrichment.bulkEvent, job.payload["mcpOrigin"] == "bulk", job.payload["actorID"] == service.identity.id else { throw NativeDBError.conflict }
            let ids = try NativeContactEnrichment.decode([String].self, job.payload["ids"] ?? "")
            let fields = try NativeContactEnrichment.decode([NativeEnrichmentField].self, job.payload["fields"] ?? "")
            guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else { throw NativeDBError.conflict }
            for id in ids { _ = try enqueueMCP(contact(id, mode: .bulk, mcp: true), fields: fields, originalFields: job.payload["mcpFields"] ?? "", single: false, batch: job.id) }
            try db.finishJob(job, result: ["dispatched": String(ids.count)], now: clock())
        }
    }
    func history(contactID: String, offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try internalAccess(); try service.assertAccess("crm_Contacts", id: contactID)
        // Large result JSON is loaded only for the selected history entry.
        return try db.page(NativeContactEnrichment.model, fields: ["contactId", "status", "fields", "error", "triggeredBy", "createdAt", "updatedAt"],
                           equal: ["contactId": .text(contactID)], offset: offset, sort: "createdAt", descending: true)
    }
    func preview(_ id: String) throws -> NativeContactEnrichmentPreview {
        try db.transaction {
            try internalAccess()
            guard let history = try db.get(NativeContactEnrichment.model, key: ["id": .text(id)]) else { throw NativeDBError.conflict }
            let row = try contact(history["contactId"].string, mode: .review)
            guard history["status"] == .text("COMPLETED") else { throw NativeAIError(message: "完了した情報補完を選択してください。") }
            let result = try NativeContactEnrichment.decode(NativeEnrichmentOutput.self, history["result"].string)
            guard result.status == .completed else { throw NativeAIError(message: "この履歴には反映できる取得結果がありません。") }
            if let job = try db.job(id: id), job.event == NativeContactEnrichment.event {
                guard job.status == "done", job.payload["email"] == row["email"].string else { throw NativeAIError(message: "検索時からメールアドレスが変更されています。情報補完をやり直してください。") }
            }
            return .init(history: history, contact: row, result: result)
        }
    }
    @discardableResult func apply(_ expected: NativeContactEnrichmentPreview, selected: Set<String>) throws -> [String] {
        try db.transaction {
            let current = try preview(expected.history["id"].string)
            guard current.history.revision == expected.history.revision, current.contact["email"] == expected.contact["email"] else { throw NativeDBError.conflict }
            var updates: [String: SQLValue] = [:]
            for name in selected.sorted() where NativeEnrichmentField.contactColumns.contains(name) {
                guard let result = current.result.enrichments[name], result.value.truthy else { continue }
                guard current.contact[name] == expected.contact[name] else { throw NativeDBError.conflict }
                let value = SQLValue.text(result.value.text)
                if current.contact[name] != value { updates[name] = value }
            }
            guard !updates.isEmpty else { return [] }
            let applied = updates.keys.sorted()
            updates["updatedBy"] = .text(service.identity.id)
            _ = try db.update(current.contact, changes: updates, actor: service.identity.id, action: "apply_enrichment")
            try db.enqueue("crm/contact.saved", payload: ["actorID": service.identity.id, "record_id": current.contact["id"].string], now: clock())
            return applied
        }
    }
    private func control(_ expected: NativeJob, cancel: Bool) throws -> NativeRecord {
        try internalAccess()
        guard expected.event == NativeContactEnrichment.event, expected.payload["enrichmentId"] == expected.id,
              try db.job(id: expected.id) == expected,
              let history = try db.get(NativeContactEnrichment.model, key: ["id": .text(expected.id)]),
              history["contactId"].string == expected.payload["contactId"], history["triggeredBy"].string == expected.payload["actorID"],
              service.identity.elevated || history["triggeredBy"] == .text(service.identity.id) else { throw NativeDBError.conflict }
        if !cancel {
            // Retrying preserves the original actor; managers cannot turn a
            // retired user's request into an execution under their own key.
            guard expected.payload["actorID"] == service.identity.id,
                  let mode = expected.payload["mode"].flatMap(NativeContactEnrichment.Mode.init(rawValue:)),
                  try contact(history["contactId"].string, mode: mode, mcp: expected.payload["mcpOrigin"] != nil)["email"].string == expected.payload["email"] else { throw NativeDBError.conflict }
        }
        return history
    }
    func cancel(_ expected: NativeJob) throws {
        try db.transaction {
            let row = try control(expected, cancel: true)
            try db.cancelAIJob(expected, events: [NativeContactEnrichment.event])
            _ = try db.update(row, changes: ["status": .text("FAILED"), "error": .text("利用者が取り消しました。")], actor: service.identity.id, action: "cancel_enrichment")
        }
    }
    func retry(_ expected: NativeJob) throws {
        try db.transaction {
            let row = try control(expected, cancel: false); _ = try credentials(mcp: expected.payload["mcpOrigin"] != nil)
            try db.retryAIJob(expected, events: [NativeContactEnrichment.event])
            _ = try db.update(row, changes: ["status": .text("PENDING"), "error": .null, "result": .null], actor: service.identity.id, action: "retry_enrichment")
        }
    }
}
