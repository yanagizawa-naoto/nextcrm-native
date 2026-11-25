import Foundation

struct CampaignTemplateRow { let record: NativeRecord; let cells: [String] }

extension CRMService {
    func campaignTemplates(search: String = "", offset: Int = 0, trash: Bool = false) throws -> (rows:[CampaignTemplateRow],total:Int) {
        try db.transaction {
            try authenticated()
            guard !trash || identity.role == "admin" else { throw NativeDBError.message("削除済みテンプレートは管理者のみ表示できます。") }
            let filter = RecordFilter.every([scope("crm_campaign_templates"),trash ? .not(.equal("deletedAt",.null)) : .all])
            let page = try db.page("crm_campaign_templates",fields:["name","subject_default","created_by","updatedAt","deletedAt"],search:search,includeDeleted:trash,offset:offset,filter:filter,sort:"created_on",descending:true)
            var names: [String:String] = [:]
            let format = DateFormatter(); format.locale = Locale(identifier:"ja_JP"); format.dateFormat = "yyyy/MM/dd HH:mm"
            let iso = ISO8601DateFormatter(); let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
            let rows = try page.rows.map { record -> CampaignTemplateRow in
                let id = record["created_by"].string
                if names[id] == nil { names[id] = id.isEmpty ? "—" : try referenceName("Users",id:id) }
                let date = fractional.date(from:record["updatedAt"].string) ?? iso.date(from:record["updatedAt"].string)
                return CampaignTemplateRow(record:record,cells:[record["name"].string,record["subject_default"].string,names[id]!,date.map(format.string) ?? "—"])
            }
            return (rows,page.total)
        }
    }
    func campaignTemplate(_ id: String) throws -> NativeRecord {
        try db.transaction {
            try assertAccess("crm_campaign_templates",id:id)
            guard let record = try db.get("crm_campaign_templates",key:["id":.text(id)]), record["deletedAt"] == .null else { throw NativeDBError.conflict }
            return record
        }
    }
    func saveCampaignTemplate(_ expected: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try db.transaction {
            try authenticated()
            guard ["admin","manager","user"].contains(identity.role), input.keys.allSatisfy({["name","description","subject_default","content_html","content_json"].contains($0)}) else { throw NativeDBError.message("テンプレートを変更する権限がありません。") }
            let current: NativeRecord?
            if let expected {
                guard expected.model == "crm_campaign_templates" else { throw NativeDBError.conflict }
                current = try campaignTemplate(expected["id"].string)
                guard current?.revision == expected.revision else { throw NativeDBError.conflict }
            } else { current = nil }
            var values = input
            for (field,label) in [("name","テンプレート名"),("subject_default","件名")] {
                let value = input[field] ?? current?[field] ?? .null
                guard !value.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeDBError.message(label+"を入力してください。") }
                values[field] = value
            }
            if let body = input["content_json"] {
                guard case let .text(raw) = body, let json = try? JSONSerialization.jsonObject(with:Data(raw.utf8)), json is [String:Any] else { throw NativeDBError.message("本文の編集データが不正です。") }
            }
            if let current { return try db.update(current,changes:values,actor:identity.id) }
            values["content_html"] = values["content_html"] ?? .text("")
            values["content_json"] = values["content_json"] ?? .text("{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}")
            values["created_by"] = .text(identity.id)
            return try db.insert("crm_campaign_templates",values:values,actor:identity.id)
        }
    }
    func deleteCampaignTemplate(_ expected: NativeRecord) throws {
        try db.transaction {
            guard expected.model == "crm_campaign_templates" else { throw NativeDBError.conflict }
            let current = try campaignTemplate(expected["id"].string)
            guard current.revision == expected.revision else { throw NativeDBError.conflict }
            _ = try db.setDeleted(current,deleted:true,actor:identity.id)
        }
    }
    func restoreCampaignTemplate(_ expected: NativeRecord) throws {
        try db.transaction {
            try authenticated()
            guard identity.role == "admin", expected.model == "crm_campaign_templates", let current = try db.get(expected.model,key:["id":expected["id"]]), current.revision == expected.revision, current["deletedAt"] != .null else { throw NativeDBError.conflict }
            _ = try db.setDeleted(current,deleted:false,actor:identity.id)
        }
    }
}

