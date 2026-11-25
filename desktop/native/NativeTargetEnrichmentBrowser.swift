import Foundation

struct NativeTargetEnrichmentHistoryEntry {
    let history: NativeRecord, target: NativeRecord, actorName: String
    var id: String { history["id"].string }
}
struct NativeTargetEnrichmentReading {
    let history: NativeRecord, target: NativeRecord, result: NativeEnrichmentOutput
    let contacts: [NativeTargetAgentOutput.Contact], missingConfidence: Set<String>, notice: String
    var isContact = false, contact: NativeRecord? = nil
    var emptyMessage = "指定した項目の情報は見つかりませんでした。"
    func mapped(_ name: String) -> Bool { isContact ? ["title", "linkedinUrl", "phone"].contains(name) : NativeTargetEnrichment.columns.contains(name) }
    func currentValue(_ name: String) -> String { isContact ? contact.map { $0[name].string } ?? "担当者は削除済み／参照不可" : target[name].string }
}
extension NativeTargetEnrichmentService {
    func readTarget(_ id: String) throws -> NativeRecord {
        try service.authenticated(); try service.assertAccess("crm_Targets", id: id)
        guard let row = try db.get("crm_Targets", key: ["id": .text(id)]), row["deletedAt"] == .null else { throw NativeDBError.conflict }; return row
    }
    func targetsPage(search: String = "", offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try db.transaction {
            try internalAccess()
            return try db.page("crm_Targets", fields: ["first_name", "last_name", "email", "company"], search: search, offset: offset,
                filter: .every([service.scope("crm_Targets"), .equal("deletedAt", .null)]), sort: "last_name", localizedSort: true)
        }
    }
    func contactsPage(targetID: String, search: String = "", offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try db.transaction {
            _ = try readTarget(targetID)
            return try db.page(NativeTargetEnrichment.contactModel, fields: ["targetId", "contactId", "name", "email", "title", "phone", "linkedinUrl", "source", "enrichStatus", "enrichedAt"],
                search: search, equal: ["targetId": .text(targetID)], offset: offset, sort: "name", localizedSort: true)
        }
    }
    @discardableResult func addContact(targetID: String, name: String, email: String, phone: String, linkedinURL: String) throws -> NativeRecord {
        let values = ["name": name, "email": email, "phone": phone, "linkedinUrl": linkedinURL].mapValues(NativeAIEnvironment.trim)
        guard values.values.allSatisfy({ $0.utf8.count <= 65_536 }) else { throw NativeAIError(message: "入力内容が長すぎます。氏名や連絡先を短くしてください。") }
        guard !(values["name"]!.isEmpty && values["email"]!.isEmpty) else { throw NativeAIError(message: "氏名またはメールアドレスを入力してください。") }
        return try db.transaction {
            _ = try target(targetID)
            for key in ["email", "linkedinUrl"] where !values[key]!.isEmpty {
                if try db.page(NativeTargetEnrichment.contactModel, fields: [], equal: ["targetId": .text(targetID), key: .text(values[key]!)], limit: 1).total > 0 {
                    throw NativeAIError(message: "同じメールアドレスまたはLinkedInの担当者が登録済みです。登録済みの行を確認してください。")
                }
            }
            var input = values.mapValues { $0.isEmpty ? SQLValue.null : .text($0) }
            input["targetId"] = .text(targetID); input["source"] = .text("manual"); input["enrichStatus"] = .text("PENDING")
            return try db.insert(NativeTargetEnrichment.contactModel, values: input, actor: service.identity.id)
        }
    }
    func historyPage(targetID: String? = nil, offset: Int = 0) throws -> (rows: [NativeTargetEnrichmentHistoryEntry], total: Int) {
        try db.transaction {
            try service.authenticated(); if let targetID { _ = try readTarget(targetID) }
            let scope = RecordFilter.relation(model: "crm_Targets", local: "targetId", foreign: "id", matching: .every([service.scope("crm_Targets"), .equal("deletedAt", .null)]))
            let page = try db.page(NativeTargetEnrichment.model, fields: ["targetId", "status", "fields", "error", "triggeredBy", "createdAt", "updatedAt"],
                equal: targetID.map { ["targetId": .text($0)] } ?? [:], offset: offset, filter: scope, sort: "createdAt", descending: true)
            let ids = Set(page.rows.map { $0["targetId"].string }), actors = Set(page.rows.map { $0["triggeredBy"].string })
            let targets = try db.page("crm_Targets", fields: ["first_name", "last_name", "company", "email"], filter: .every([service.scope("crm_Targets"), .any(ids.map { .equal("id", .text($0)) })])).rows
            let users = try db.page("Users", fields: ["name"], filter: .any(actors.map { .equal("id", .text($0)) })).rows
            let targetMap = Dictionary(uniqueKeysWithValues: targets.map { ($0["id"].string, $0) }), names = Dictionary(uniqueKeysWithValues: users.map { ($0["id"].string, $0["name"].string) })
            return (page.rows.compactMap { h in targetMap[h["targetId"].string].map { .init(history: h, target: $0, actorName: names[h["triggeredBy"].string] ?? "不明") } }, page.total)
        }
    }
    func readableJob(_ id: String) throws -> NativeJob? {
        try db.transaction {
            guard let history = try db.page(NativeTargetEnrichment.model, fields: ["targetId", "triggeredBy"], equal: ["id": .text(id)], limit: 1).rows.first else { throw NativeDBError.conflict }
            _ = try readTarget(history["targetId"].string)
            guard let job = try db.job(id: id) else { return nil }
            guard NativeTargetEnrichment.events.contains(job.event), job.payload["enrichmentId"] == id,
                  job.payload["actorID"] == history["triggeredBy"].string, job.payload["targetId"] == history["targetId"].string else { throw NativeDBError.conflict }
            return job
        }
    }
    func resultForReading(_ id: String) throws -> NativeTargetEnrichmentReading {
        try db.transaction {
            guard let h = try db.get(NativeTargetEnrichment.model, key: ["id": .text(id)]), h["status"] == .text("COMPLETED") else { throw NativeDBError.conflict }
            let target = try readTarget(h["targetId"].string), job = try readableJob(id)
            if let output = try? NativeContactEnrichment.decode(NativeEnrichmentOutput.self, h["result"].string) {
                guard output.status == .completed else { throw NativeDBError.conflict }
                _ = try output.validated(for: output.enrichments.keys.map { .init(name: $0, displayName: $0, description: "") })
                return .init(history: h, target: target, result: output, contacts: [], missingConfidence: [], notice: "取得時の結果です。現在の値は、その後の編集を含みます。")
            }
            let raw = try NativeContactEnrichment.decode(NativeTargetAgentOutput.self, h["result"].string).validated()
            if let job, job.event == NativeTargetEnrichment.contactEvent {
                let identity = try NativeContactEnrichment.decode([String: String?].self, job.payload["contactIdentity"] ?? "{}")
                let original = NativeRecord(model: NativeTargetEnrichment.contactModel, values: identity.mapValues { $0.map(SQLValue.text) ?? .null }, revision: 0)
                let stored = try db.get(NativeTargetEnrichment.contactModel, key: ["id": .text(job.payload["contactId"] ?? "")])
                let current = stored.flatMap { $0["targetId"] == target["id"] ? $0 : nil }
                let matched = raw.matchingContact(original)
                let pairs = [("title", matched?.title), ("linkedinUrl", matched?.linkedinUrl), ("phone", matched?.phone)].compactMap { name, value -> (String, NativeEnrichmentResult)? in
                    guard let value, !value.isEmpty else { return nil }
                    return (name, .init(field: name, value: .string(value), confidence: 0, source: matched?.source))
                }
                let fields = Dictionary(uniqueKeysWithValues: pairs)
                let applied = (try? NativeContactEnrichment.decode([String].self, job.result["fieldsApplied"] ?? "[]")) ?? []
                let notice = "担当者：\(NativeTargetEnrichmentPresentation.contactName(job))。反映した項目：" + (applied.isEmpty ? "なし" : applied.map { NativeTargetEnrichmentPresentation.label($0) }.joined(separator: "、")) + "。現在の値には、手動入力やその後の編集も含まれます。"
                let empty = job.result["skipReason"] == "already_complete" ? "役職とLinkedInは登録済みのため、調査を省略しました。" : "本人に一致する項目は見つかりませんでした。取得した担当者の候補を確認できます。"
                return .init(history: h, target: target, result: .init(enrichments: fields, status: .completed), contacts: raw.contacts, missingConfidence: Set(fields.keys), notice: notice, isContact: true, contact: current, emptyMessage: empty)
            }
            let results = raw.target.compactMapValues { $0 }.map { name, value in
                (name, NativeEnrichmentResult(field: name, value: .string(value), confidence: raw.confidence[name] ?? 0, source: "自動取得結果（項目ごとの根拠URLは提供されていません）"))
            }
            let applied = (try? NativeContactEnrichment.decode([String].self, job?.result["fieldsApplied"] ?? "[]")) ?? []
            let notice = "自動取得の保存済み結果です。反映した項目：" + (applied.isEmpty ? "なし／記録なし" : applied.map { NativeTargetEnrichmentPresentation.label($0) }.joined(separator: "、")) + "。取得した担当者：\(raw.contacts.count)件。現在の値には、その後の編集も含まれます。"
            return .init(history: h, target: target, result: .init(enrichments: Dictionary(uniqueKeysWithValues: results), status: .completed), contacts: raw.contacts,
                missingConfidence: Set(raw.target.keys.filter { raw.confidence[$0] == nil }), notice: notice)
        }
    }
}
enum NativeTargetEnrichmentPresentation {
    static func contactName(_ job: NativeJob) -> String {
        guard let fields = try? NativeContactEnrichment.decode([String: String?].self, job.payload["contactIdentity"] ?? "{}"), let optional = fields["name"], let name = optional, !name.isEmpty else { return "氏名未登録" }; return name
    }
    static func label(_ name: String, fields: [NativeEnrichmentField] = []) -> String {
        fields.first { $0.name == name }?.displayName ?? NativeTargetEnrichment.presets.first { $0.name == name }?.displayName ?? ["title": "担当者の役職", "linkedinUrl": "担当者のLinkedIn", "phone": "担当者の電話番号"][name] ?? name
    }
    static func mode(_ job: NativeJob?) -> String {
        switch job?.payload["mode"] { case "review": return "確認して反映"; case "contact": return "担当者の空欄に自動反映"; case "bulk": return "一括・空欄に自動反映"; case "automatic": return "空欄に自動反映"; default: return "過去の取得結果" }
    }
}
