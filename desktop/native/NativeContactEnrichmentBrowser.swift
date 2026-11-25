import Foundation

struct NativeEnrichmentHistoryEntry {
    let history: NativeRecord, contact: NativeRecord
    let actorName: String
    var id: String { history["id"].string }
}

extension NativeContactEnrichmentService {
    func contactsPage(search: String = "", offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try db.transaction {
            try internalAccess()
            return try db.page("crm_Contacts", fields: ["first_name", "last_name", "email"], search: search, offset: offset,
                               filter: service.scope("crm_Contacts"), sort: "last_name", localizedSort: true)
        }
    }
    func historyPage(contactID: String? = nil, offset: Int = 0) throws -> (rows: [NativeEnrichmentHistoryEntry], total: Int) {
        try db.transaction {
            try service.authenticated()
            if let contactID { try service.assertAccess("crm_Contacts", id: contactID) }
            let scope = RecordFilter.relation(model: "crm_Contacts", local: "contactId", foreign: "id", matching: .every([service.scope("crm_Contacts"), .equal("deletedAt", .null)]))
            let result = try db.page(NativeContactEnrichment.model, fields: ["contactId", "status", "fields", "error", "triggeredBy", "createdAt", "updatedAt"],
                                     equal: contactID.map { ["contactId": .text($0)] } ?? [:], offset: offset, filter: scope, sort: "createdAt", descending: true)
            let contactIDs = Set(result.rows.map { $0["contactId"].string }), actors = Set(result.rows.map { $0["triggeredBy"].string })
            let contacts = try db.page("crm_Contacts", fields: ["first_name", "last_name", "email"], filter: .every([service.scope("crm_Contacts"), .any(contactIDs.map { .equal("id", .text($0)) })])).rows
            let users = try db.page("Users", fields: ["name"], filter: .any(actors.map { .equal("id", .text($0)) })).rows
            let contactMap = Dictionary(uniqueKeysWithValues: contacts.map { ($0["id"].string, $0) }), names = Dictionary(uniqueKeysWithValues: users.map { ($0["id"].string, $0["name"].string) })
            return (result.rows.compactMap { history in contactMap[history["contactId"].string].map { .init(history: history, contact: $0, actorName: names[history["triggeredBy"].string] ?? "不明") } }, result.total)
        }
    }
    func readableJob(_ id: String) throws -> NativeJob? {
        try db.transaction {
            try service.authenticated()
            guard let history = try db.page(NativeContactEnrichment.model, fields: ["contactId", "triggeredBy"], equal: ["id": .text(id)], limit: 1).rows.first else { throw NativeDBError.conflict }
            try service.assertAccess("crm_Contacts", id: history["contactId"].string)
            guard let job = try db.job(id: id) else { return nil }
            guard job.event == NativeContactEnrichment.event, job.payload["enrichmentId"] == id,
                  job.payload["actorID"] == history["triggeredBy"].string,
                  job.payload["contactId"] == history["contactId"].string else { throw NativeDBError.conflict }; return job
        }
    }
    func resultForReading(_ id: String) throws -> NativeContactEnrichmentPreview {
        try db.transaction {
            try service.authenticated()
            guard let history = try db.get(NativeContactEnrichment.model, key: ["id": .text(id)]) else { throw NativeDBError.conflict }
            try service.assertAccess("crm_Contacts", id: history["contactId"].string)
            guard let contact = try db.page("crm_Contacts", fields: ["first_name", "last_name", "email"] + Array(NativeEnrichmentField.contactColumns), equal: ["id": history["contactId"]], filter: service.scope("crm_Contacts"), limit: 1).rows.first else { throw NativeDBError.conflict }
            guard history["status"] == .text("COMPLETED") else { throw NativeAIError(message: "完了した情報補完を選択してください。") }
            let result = try NativeContactEnrichment.decode(NativeEnrichmentOutput.self, history["result"].string)
            guard result.status == .completed else { throw NativeDBError.conflict }
            return .init(history: history, contact: contact, result: result)
        }
    }
}

enum NativeEnrichmentPresentation {
    static let defaults: Set<String> = ["position", "social_linkedin", "website", "description"]
    static func label(_ name: String, fields: [NativeEnrichmentField] = []) -> String {
        NativeEnrichmentField.contactPresets.first { $0.name == name }?.displayName ?? fields.first { $0.name == name }?.displayName ?? name
    }
    static func custom(name: String, description: String, existing: [NativeEnrichmentField]) throws -> NativeEnrichmentField {
        let display = NativeAIEnvironment.trim(name), key = display.lowercased().replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
        guard !key.isEmpty, !existing.contains(where: { $0.name == key }) else { throw NativeAIError(message: "空欄や重複のない項目名を入力してください。") }
        let description = NativeAIEnvironment.trim(description)
        return .init(name: key, displayName: display, description: description.isEmpty ? "この連絡先の「\(display)」を調べてください。" : description)
    }
    static func status(_ history: NativeRecord, job: NativeJob? = nil) -> String {
        if job?.status == "cancelled" { return "取消済み" }; if job?.status == "retry" { return "再試行待ち" }
        switch history["status"].string { case "PENDING": return "待機中"; case "RUNNING": return "実行中"; case "COMPLETED": return "完了"; case "SKIPPED": return "対象外"; default: return "要確認" }
    }
    static func sourceURLs(_ result: NativeEnrichmentResult) -> [URL] {
        let candidates = (result.sourceContext ?? []).map(\.url) + (result.corroboration?.evidence ?? []).map(\.source_url) + (result.source ?? "").components(separatedBy: ", ")
        var seen = Set<String>()
        return candidates.compactMap { value in
            guard let url = URL(string: NativeAIEnvironment.trim(value)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, seen.insert(url.absoluteString).inserted else { return nil }; return url
        }
    }
}
