import Foundation

enum NativeSearchKind: String, CaseIterable, Codable {
    case accounts, contacts, leads, opportunities, projects, tasks, users, documents
    var title: String {
        switch self { case .accounts: return "取引先"; case .contacts: return "連絡先"; case .leads: return "リード"; case .opportunities: return "商談"; case .projects: return "プロジェクト"; case .tasks: return "タスク"; case .users: return "利用者"; case .documents: return "文書" }
    }
    var model: String {
        switch self { case .accounts: return "crm_Accounts"; case .contacts: return "crm_Contacts"; case .leads: return "crm_Leads"; case .opportunities: return "crm_Opportunities"; case .projects: return "Boards"; case .tasks: return "Tasks"; case .users: return "Users"; case .documents: return "Documents" }
    }
    var keywordFields: [String] {
        switch self {
        case .accounts: return ["name", "description", "email"]
        case .contacts: return ["first_name", "last_name", "email"]
        case .leads: return ["firstName", "lastName", "company", "email"]
        case .opportunities: return ["name", "description"]
        case .projects: return ["title", "description"]
        case .tasks: return ["title", "content"]
        case .users: return ["name", "email", "username"]
        case .documents: return ["document_name", "summary", "description"]
        }
    }
    var resultFields: [String] {
        switch self {
        case .accounts: return ["name", "email"]
        case .contacts: return ["first_name", "last_name", "email"]
        case .leads: return ["firstName", "lastName", "company", "email"]
        case .opportunities: return ["name", "status"]
        case .projects: return ["title", "description"]
        case .tasks: return ["title", "taskStatus"]
        case .users: return ["name", "email", "username", "role", "userStatus"]
        case .documents: return ["document_name", "summary"]
        }
    }
    var embeddings: [NativeEmbeddingKind] {
        switch self { case .accounts: return [.account]; case .contacts: return [.contact]; case .leads: return [.lead]; case .opportunities: return [.opportunity]; case .documents: return [.document, .documentChunk]; default: return [] }
    }
}
struct NativeSearchHit: Equatable {
    enum Match: String { case keyword, semantic, both
        var title: String { switch self { case .keyword: return "文字が一致"; case .semantic: return "意味が近い"; case .both: return "文字・意味が一致" } }
    }
    let kind: NativeSearchKind, id: String, title: String, subtitle: String, score: Double, match: Match
    var documentAccountName: String? = nil
    var documentSystemType: String? = nil
}
struct NativeSearchResults {
    enum AIState: Equatable { case disabled, unconfigured, ready, unavailable
        var message: String { switch self { case .disabled: return "文字で検索しました。"; case .unconfigured: return "OpenAIのキーが未設定のため、文字で検索しました。"; case .ready: return "文字と意味で検索しました。"; case .unavailable: return "AI検索を利用できなかったため、文字で検索しました。" } }
    }
    let hits: [NativeSearchHit], aiState: AIState
}

extension CRMService {
    private func searchTextLimits(_ kind: NativeSearchKind) throws -> [String: Int] {
        let model = try db.schema.model(kind.model)
        return Dictionary(uniqueKeysWithValues: kind.resultFields.filter { model.field($0)?.type == "String" }.map { ($0, $0 == "description" && kind == .projects ? 80 : 512) })
    }
    func globalSearchScope(_ kind: NativeSearchKind) -> RecordFilter {
        switch kind {
        case .projects: return scope("Boards")
        case .documents: return .every([scope("Documents"), .equal("parent_document_id", .null)])
        case .tasks:
            return .every([reportScope("Tasks"), .relation(model: "Sections", local: "section", foreign: "id", matching: .relation(model: "Boards", local: "board", foreign: "id", matching: .equal("deletedAt", .null)))])
        default: return reportScope(kind.model)
        }
    }
    static func validateGlobalQuery(_ query: String) throws {
        guard NativeAIEnvironment.trim(query).utf16.count >= 2 else { throw NativeAIError(message: "検索語は2文字以上で入力してください。") }
    }
    /// At most 10 keyword IDs and 10 IDs per vector source are retained. Large
    /// fields stay in SQLite; only bounded title/description previews are read.
    func unifiedSearch(_ query: String, vector: NativeEmbeddingVector? = nil, aiState: NativeSearchResults.AIState = .disabled) throws -> NativeSearchResults {
        try authenticated(); try Self.validateGlobalQuery(query)
        let index = NativeEmbeddingIndex(db: db)
        var output: [NativeSearchHit] = []
        for kind in NativeSearchKind.allCases {
            try Task.checkCancellation(); try authenticated()
            let visibility = globalSearchScope(kind)
            let keyword = try db.keywordIDs(kind.model, fields: kind.keywordFields, query: query, filter: visibility, limit: 10, validate: { try self.authenticated() })
            let keywordIDs = Set(keyword)
            var scores: [String: Double] = [:]
            if let vector {
                for embedding in kind.embeddings {
                    let matches = try index.nearest(embedding, query: vector, parentScope: visibility, limit: 10, validate: { try self.authenticated() })
                    for hit in matches.hits { scores[hit.id] = max(scores[hit.id] ?? -.infinity, hit.similarity) }
                }
            }
            let ordered = keyword + scores.keys.filter { !keywordIDs.contains($0) }.sorted()
            if ordered.isEmpty { continue }
            let hits: [NativeSearchHit] = try db.transaction {
                try Task.checkCancellation(); try authenticated()
                let current = try db.keysetPage(kind.model, fields: kind.resultFields, filter: .every([globalSearchScope(kind), .any(ordered.map { .equal("id", .text($0)) })]), maximumTextCharacters: searchTextLimits(kind))
                let records = Dictionary(uniqueKeysWithValues: current.map { ($0["id"].string, $0) })
                return try ordered.compactMap { id in
                    guard let row = records[id] else { return nil }
                    let text = try searchText(kind, row: row), inKeyword = keywordIDs.contains(id), semanticScore = scores[id] ?? 0
                    return NativeSearchHit(kind: kind, id: id, title: text.0, subtitle: text.1, score: 0.5 * (inKeyword ? 1 : 0) + 0.5 * semanticScore, match: inKeyword && semanticScore > 0 ? .both : inKeyword ? .keyword : .semantic)
                }
            }
            // Preserve keyword-before-extra order for equal scores; ID ordering
            // makes unspecified database ties deterministic across restarts.
            output += hits.enumerated().sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }.prefix(10).map(\.element)
        }
        // Recheck every returned identity after all potentially lengthy scans.
        return try db.transaction {
            try Task.checkCancellation(); try authenticated()
            let visible = try output.filter { hit in try !db.keysetPage(hit.kind.model, fields: [], filter: .every([globalSearchScope(hit.kind), .equal("id", .text(hit.id))]), limit: 1).isEmpty }
            return NativeSearchResults(hits: visible, aiState: aiState)
        }
    }
    /// Original command-palette document candidates: five name/summary keyword
    /// hits first, followed by five full-document vector hits above 0.7.
    /// Chunk vectors and weighted global ranking belong to unifiedSearch().
    func documentCandidateSearch(_ query: String, vector: NativeEmbeddingVector? = nil, aiState: NativeSearchResults.AIState = .disabled) throws -> NativeSearchResults {
        try authenticated(); try Self.validateGlobalQuery(query)
        let scope = globalSearchScope(.documents)
        let keyword = try db.keywordIDs("Documents", fields: ["document_name", "summary"], query: query, filter: scope, limit: 5, validate: { try self.authenticated() })
        let keywordIDs = Set(keyword)
        let semantic = try vector.map { try NativeEmbeddingIndex(db: db).nearest(.document, query: $0, parentScope: scope, limit: 5, minimumSimilarity: 0.7, validate: { try self.authenticated() }).hits } ?? []
        let scores = Dictionary(uniqueKeysWithValues: semantic.map { ($0.id, $0.similarity) })
        // The source's second findMany has no explicit order. Use stable IDs,
        // matching keyword tie ordering, rather than another weighted sort.
        let ordered = keyword + semantic.map(\.id).filter { !keywordIDs.contains($0) }.sorted()
        return try db.transaction {
            try Task.checkCancellation(); try authenticated()
            if ordered.isEmpty { return NativeSearchResults(hits: [], aiState: aiState) }
            let records = try db.keysetPage("Documents", fields: ["document_name", "summary", "document_system_type"], filter: .every([globalSearchScope(.documents), .any(ordered.map { .equal("id", .text($0)) })]), maximumTextCharacters: ["document_name": 512, "summary": 512])
            let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0["id"].string, $0) })
            let hits = try ordered.compactMap { id -> NativeSearchHit? in
                guard let row = indexed[id] else { return nil }
                let text = keywordIDs.contains(id), score = scores[id]
                return NativeSearchHit(kind: .documents, id: id, title: row["document_name"].string, subtitle: row["summary"].string, score: score ?? (text ? 1 : 0), match: text ? (score == nil ? .keyword : .both) : .semantic, documentAccountName: try searchLinkedAccount(row), documentSystemType: row["document_system_type"] == .null ? nil : row["document_system_type"].string)
            }
            return NativeSearchResults(hits: hits, aiState: aiState)
        }
    }
    private func searchLinkedAccount(_ document: NativeRecord) throws -> String? {
        let visibleAccount = RecordFilter.relation(model: "crm_Accounts", local: "account_id", foreign: "id", matching: .every([scope("crm_Accounts"), .equal("deletedAt", .null)]))
        guard let link = try db.page("DocumentsToAccounts", fields: ["account_id"], filter: .every([.equal("document_id", document["id"]), visibleAccount]), limit: 1).rows.first else { return nil }
        return try db.keysetPage("crm_Accounts", fields: ["name"], filter: .every([scope("crm_Accounts"), .equal("id", link["account_id"])]), limit: 1, maximumTextCharacters: ["name": 512]).first?["name"].string
    }
    private func searchText(_ kind: NativeSearchKind, row: NativeRecord) throws -> (String, String) {
        func fallback(_ key: String, _ alternative: String) -> String { row[key] == .null ? alternative : row[key].string }
        switch kind {
        case .accounts: return (row["name"].string, row["email"].string)
        case .contacts: return (NativeAIEnvironment.trim(row["first_name"].string + " " + row["last_name"].string), row["email"].string)
        case .leads:
            return ((!row["firstName"].string.isEmpty || !row["lastName"].string.isEmpty) ? NativeAIEnvironment.trim(row["firstName"].string + " " + row["lastName"].string) : fallback("company", "名称未設定のリード"), fallback("email", row["company"].string))
        case .opportunities: return (row["name"].string, row["status"].string)
        case .projects: return (row["title"].string, String(decoding: Array(row["description"].string.utf16.prefix(80)), as: UTF16.self))
        case .tasks: return (row["title"].string, row["taskStatus"].string)
        case .users: return (fallback("name", fallback("email", "名称未設定の利用者")), row["email"].string)
        case .documents:
            if row["summary"] != .null { return (row["document_name"].string, row["summary"].string) }
            return (row["document_name"].string, try searchLinkedAccount(row) ?? "")
        }
    }
    /// Search navigation must not trust an old result or fetch private user
    /// credentials just to open a directory entry.
    func searchDestination(_ hit: NativeSearchHit) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard let row = try db.keysetPage(hit.kind.model, fields: hit.kind.resultFields, filter: .every([globalSearchScope(hit.kind), .equal("id", .text(hit.id))]), limit: 1, maximumTextCharacters: searchTextLimits(hit.kind)).first else { throw NativeAIError(message: "対象が見つからないか、表示する権限がありません。") }
            return row
        }
    }
}

struct NativeSearchEngine {
    let service: CRMService
    let keys: NativeAIKeys?
    var allowsAI: Bool {keys != nil}
    var generate: NativeEmbeddingWorker.Generate = { try await NativeEmbeddingClient(apiKey: $1).generate($0) }
    var documentCandidates = false
    init(keys:NativeAIKeys,generate:@escaping NativeEmbeddingWorker.Generate = {try await NativeEmbeddingClient(apiKey:$1).generate($0)},documentCandidates:Bool=false) {
        self.service=keys.service;self.keys=keys;self.generate=generate;self.documentCandidates=documentCandidates
    }
    init(service:CRMService,documentCandidates:Bool=false) {
        self.service=service;self.keys=nil;self.documentCandidates=documentCandidates
    }
    func search(_ query: String, useAI: Bool) async throws -> NativeSearchResults {
        try service.authenticated(); try CRMService.validateGlobalQuery(query); try Task.checkCancellation()
        var vector: NativeEmbeddingVector?, state = NativeSearchResults.AIState.disabled
        if useAI,let keys {
            do {
                if let key = try keys.resolve(.openai) {
                    let generated = try await generate(NativeAIEnvironment.trim(query), key.key)
                    try Task.checkCancellation(); try keys.requireCurrent(key); vector = generated; state = .ready
                } else { state = .unconfigured }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); state = .unavailable }
        }
        try service.authenticated(); try Task.checkCancellation()
        return try documentCandidates ? service.documentCandidateSearch(query, vector: vector, aiState: state) : service.unifiedSearch(query, vector: vector, aiState: state)
    }
}
