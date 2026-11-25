import Foundation

enum NativeEmbeddingKind: String, CaseIterable {
    case account, contact, lead, opportunity, document, documentChunk, email
    var table: String {
        switch self {
        case .account: return "crm_Embeddings_Accounts"
        case .contact: return "crm_Embeddings_Contacts"
        case .lead: return "crm_Embeddings_Leads"
        case .opportunity: return "crm_Embeddings_Opportunities"
        case .document: return "crm_Embeddings_Documents"
        case .documentChunk: return "crm_Document_Chunks"
        case .email: return "EmailEmbedding"
        }
    }
    var parent: String {
        switch self {
        case .account: return "crm_Accounts"
        case .contact: return "crm_Contacts"
        case .lead: return "crm_Leads"
        case .opportunity: return "crm_Opportunities"
        case .document, .documentChunk: return "Documents"
        case .email: return "Email"
        }
    }
    var parentField: String {
        switch self {
        case .account: return "account_id"
        case .contact: return "contact_id"
        case .lead: return "lead_id"
        case .opportunity: return "opportunity_id"
        case .document, .documentChunk: return "document_id"
        case .email: return "emailId"
        }
    }
    var hashField: String { self == .email ? "contentHash" : "content_hash" }
    var dateField: String { self == .email ? "embeddedAt" : "embedded_at" }
    var visibleParent: RecordFilter {
        switch self {
        case .email: return .equal("isDeleted", .integer(0))
        case .document, .documentChunk: return .every([.equal("deletedAt", .null), .equal("parent_document_id", .null)])
        default: return .equal("deletedAt", .null)
        }
    }
}

struct NativeEmbeddingMatches {
    let hits: [NativeEmbeddingHit]
    let scanned: Int
    let malformed: Int
}

/// Storage primitive; callers supply the current actor's parent scope. No
/// authorization decision is inferred from ownership of an embedding row.
struct NativeEmbeddingIndex {
    let db: NativeDatabase

    func existing(_ kind: NativeEmbeddingKind, parentID: String) throws -> NativeRecord? {
        guard kind != .documentChunk else { throw NativeAIError(message: "分割文書には専用の保存処理が必要です。") }
        return try db.keysetPage(kind.table, fields: [kind.parentField, kind.hashField, "embedding", kind.dateField], filter: .equal(kind.parentField, .text(parentID)), limit: 1, maximumBlobBytes: ["embedding": NativeEmbeddingVector.dimensions * 4]).first
    }
    @discardableResult func save(_ kind: NativeEmbeddingKind, source: NativeRecord, vector: NativeEmbeddingVector, contentHash: String, actor: String, now: Date = Date()) throws -> NativeRecord {
        guard kind != .documentChunk, source.model == kind.parent, contentHash.utf8.count == 64, contentHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw NativeAIError(message: "AI検索データの保存先が不正です。")
        }
        return try db.transaction {
            guard let current = try db.keysetPage(source.model, fields: [], filter: .equal("id", source["id"]), includeDeleted: true, limit: 1).first, current.revision == source.revision else { throw NativeDBError.conflict }
            let values: [String: SQLValue] = [kind.parentField: source["id"], "embedding": .blob(vector.bytes), kind.hashField: .text(contentHash), kind.dateField: .text(ISO8601DateFormatter().string(from: now))]
            if let old = try existing(kind, parentID: source["id"].string) { return try db.update(old, changes: values, actor: actor) }
            return try db.insert(kind.table, values: values, actor: actor)
        }
    }
    func nearest(_ kind: NativeEmbeddingKind, query: NativeEmbeddingVector, parentScope: RecordFilter, limit: Int = 10, minimumSimilarity: Double? = nil, validate: () throws -> Void = {}) throws -> NativeEmbeddingMatches {
        if let minimumSimilarity, !minimumSimilarity.isFinite || !(-1...1).contains(minimumSimilarity) { throw NativeAIError(message: "検索の類似度が不正です。") }
        var top = try NativeEmbeddingTopK(limit: limit), after: String?, scanned = 0, malformed = 0
        let scope = RecordFilter.relation(model: kind.parent, local: kind.parentField, foreign: "id", matching: .every([parentScope, kind.visibleParent]))
        while true {
            try Task.checkCancellation(); try validate()
            let count: Int = try autoreleasepool {
                let rows = try db.keysetPage(kind.table, fields: [kind.parentField, "embedding"], after: after, filter: scope, maximumBlobBytes: ["embedding": NativeEmbeddingVector.dimensions * 4])
                for row in rows {
                    try Task.checkCancellation(); scanned += 1
                    guard case let .blob(bytes) = row["embedding"], let value = try? NativeEmbeddingVector(bytes: bytes) else { malformed += 1; continue }
                    let similarity = query.similarity(to: value)
                    if minimumSimilarity == nil || similarity > minimumSimilarity! { top.consider(id: row[kind.parentField].string, similarity: similarity) }
                }
                after = rows.last?["id"].string
                return rows.count
            }
            if count < 100 { break }
        }
        try validate()
        return NativeEmbeddingMatches(hits: top.hits, scanned: scanned, malformed: malformed)
    }
}
