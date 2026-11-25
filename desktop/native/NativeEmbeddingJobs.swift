import Foundation
import CryptoKit

enum NativeEmbeddingJobs {
    static let backfill = "crm/backfill.requested"
    static let kinds: [NativeEmbeddingKind] = [.account, .contact, .lead, .opportunity, .email, .document]
    static func event(_ kind: NativeEmbeddingKind) -> String { kind == .document ? NativeDatabase.documentAIEvent : kind == .email ? "email/embed-email" : "crm/\(kind.rawValue).saved" }
    static let events = kinds.map(event) + [backfill]
    static func kind(_ event: String) -> NativeEmbeddingKind? { kinds.first { self.event($0) == event } }
    static func pointer(_ actor: String) -> String { "ai.backfill.job." + actor }
    static func title(_ event: String) -> String {
        if event == backfill { return "CRM・メール・文書の全件作成" }
        switch kind(event) { case .account: return "取引先"; case .contact: return "連絡先"; case .lead: return "リード"; case .opportunity: return "商談"; case .email: return "メール"; case .document: return "文書の要約・分類・検索"; default: return "検索データ" }
    }
    static func message(_ error: Error) -> String {
        if let error = error as? NativeAIError { return error.message }
        if error is CancellationError { return "AI検索データの作成を中断しました。次回起動時に再開します。" }
        if case NativeDBError.conflict = error { return "処理中にデータ・権限・APIキーが変更されました。最新の状態で再実行します。" }
        return "AI検索データを作成できませんでした。設定と対象データを確認してください。"
    }
}

struct NativeEmbeddingInput {
    let record: NativeRecord, text: String, hash: String, legacyMailHash: String?
}

extension CRMService {
    func embeddingScope(_ kind: NativeEmbeddingKind) -> RecordFilter {
        var filters = [scope(kind.parent, write: kind == .document), kind.visibleParent]
        if kind == .email {
            filters.append(.any([("EmailsToContacts", "crm_Contacts", "contactId"), ("EmailsToAccounts", "crm_Accounts", "accountId")].map { table, model, key in
                .relation(model: table, local: "id", foreign: "emailId", matching: .relation(model: model, local: key, foreign: "id", matching: .every([scope(model), .equal("deletedAt", .null)])))
            }))
        }
        return .every(filters)
    }
    func embeddingInput(_ kind: NativeEmbeddingKind, id: String) throws -> NativeEmbeddingInput? {
        try db.transaction {
            try authenticated()
            let fields: [String]
            switch kind {
            case .account: fields = ["name", "description", "email"]
            case .contact: fields = ["first_name", "last_name", "position", "email"]
            case .lead: fields = ["firstName", "lastName", "description"]
            case .opportunity: fields = ["name", "description", "sales_stage"]
            case .email: fields = ["subject", "bodyText", "fromEmail", "emailAccountId", "userId"]
            default: throw NativeAIError(message: "文書の検索データは文書処理から作成してください。")
            }
            guard let row = try db.keysetPage(kind.parent, fields: fields, filter: .every([embeddingScope(kind), .equal("id", .text(id))]), limit: 1).first else { return nil }
            var values = fields.prefix(kind == .email ? 3 : fields.count).map { row[$0] == .null ? nil : row[$0].string }
            if kind == .opportunity {
                let stage = row["sales_stage"] == .null ? nil : try db.get("crm_Opportunities_Sales_Stages", key: ["id": row["sales_stage"]])
                values[2] = stage?["name"].string
            }
            let text = NativeEmbeddingVector.text(values)
            var legacy: String?
            if kind == .email {
                // Pending native mail jobs used Foundation's whitespace set.
                // Validate that handoff while storing the original JS text hash.
                var digest = SHA256(), any = false
                for value in values.compactMap({ $0 }) where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if any { digest.update(data: Data([32])) }; digest.update(data: Data(value.utf8)); any = true
                }
                legacy = digest.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return NativeEmbeddingInput(record: row, text: text, hash: NativeEmbeddingVector.hash(text), legacyMailHash: legacy)
        }
    }
    @discardableResult func requestEmbeddingBackfill(now: Date = Date()) throws -> String {
        try db.transaction {
            try authenticated()
            if let id = try db.metadata(NativeEmbeddingJobs.pointer(identity.id)), let job = try db.job(id: id), job.event == NativeEmbeddingJobs.backfill,
               job.payload["actorID"] == identity.id, ["pending", "running", "retry"].contains(job.status) { return id }
            let id = try db.enqueue(NativeEmbeddingJobs.backfill, payload: ["actorID": identity.id], now: now)
            try db.setMetadata(NativeEmbeddingJobs.pointer(identity.id), value: id); return id
        }
    }
    func embeddingJobs(offset: Int = 0) throws -> (rows: [NativeJob], total: Int) {
        try authenticated(); return try db.aiJobs(events: NativeEmbeddingJobs.events, actorID: identity.id, offset: offset)
    }
    func retryEmbeddingJob(_ expected: NativeJob) throws {
        try db.transaction {
            try authenticated()
            guard NativeEmbeddingJobs.events.contains(expected.event), expected.payload["actorID"] == identity.id else { throw NativeDBError.conflict }
            try db.retryAIJob(expected, events: NativeEmbeddingJobs.events)
        }
    }
    func cancelEmbeddingJob(_ expected: NativeJob) throws {
        try db.transaction {
            try authenticated()
            guard NativeEmbeddingJobs.events.contains(expected.event), expected.payload["actorID"] == identity.id, try db.job(id: expected.id) == expected else { throw NativeDBError.conflict }
            try db.cancelAIJob(expected, events: NativeEmbeddingJobs.events)
            if expected.event == NativeDatabase.documentAIEvent {
                if let id = expected.payload["documentId"], try db.documentAIJob(id) == expected.id,
                   let row = try db.keysetPage("Documents", fields: ["key", "content_hash"], filter: .every([scope("Documents", write: true), .equal("id", .text(id)), .equal("parent_document_id", .null)]), limit: 1).first,
                   row["key"].string == expected.payload["key"], row["content_hash"].string == expected.payload["contentHash"], try (db.documentProcessingJob(row) ?? "") == expected.payload["sourceJob"] {
                    _ = try db.patchDocumentAI(row, changes: ["processing_status": .text("READY"), "processing_error": .null], actor: identity.id)
                }
                try db.discardCancelledDocumentAI(expected)
            }
        }
    }
}
