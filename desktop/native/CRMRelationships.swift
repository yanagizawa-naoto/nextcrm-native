import Foundation

struct CRMConversion {
    let account: NativeRecord; let contact: NativeRecord; let opportunity: NativeRecord?
}

extension CRMService {
    private func active(_ model: String, id: String) throws -> NativeRecord {
        guard let record = try db.get(model,key:["id":.text(id)]), record["deletedAt"] == .null else { throw NativeDBError.message("対象が見つからないか、削除済みです。") }
        return record
    }
    func targetListPage(_ listID: String, candidates: Bool, search: String = "", offset: Int = 0) throws -> (rows: [NativeRecord], total: Int) {
        try assertAccess("crm_TargetLists",id:listID,write:candidates)
        let member = RecordFilter.relation(model:"TargetsToTargetLists",local:"id",foreign:"target_id",matching:.equal("target_list_id",.text(listID)))
        // An authorized list exposes its members' summary, matching getTargetList. Opening or
        // editing a target still checks that target's own scope. Candidates require target access.
        let filter: RecordFilter = candidates ? .every([scope("crm_Targets"),.not(member)]) : member
        return try db.page("crm_Targets",fields:["last_name","first_name","company","email","do_not_email"],search:search,offset:offset,filter:filter,sort:"last_name")
    }
    func allTargetListIDs(_ listID: String, candidates: Bool, search: String) throws -> Set<String> {
        var ids = Set<String>(); var offset = 0
        while true {
            let page = try targetListPage(listID,candidates:candidates,search:search,offset:offset)
            page.rows.forEach { ids.insert($0["id"].string) }; offset += page.rows.count
            if offset >= page.total || page.rows.isEmpty { return ids }
        }
    }
    @discardableResult func addTargets(_ targetIDs: [String], to listID: String) throws -> Int {
        guard !targetIDs.isEmpty else { throw NativeDBError.message("追加する営業対象を選択してください。") }
        return try db.transaction {
            try assertAccess("crm_TargetLists",id:listID,write:true)
            var count = 0
            for id in Set(targetIDs).sorted() {
                let allowed = try db.page("crm_Targets",fields:[],equal:["id":.text(id)],filter:scope("crm_Targets")).total == 1
                if !allowed { continue }
                let key: [String:SQLValue] = ["target_id":.text(id),"target_list_id":.text(listID)]
                if try db.get("TargetsToTargetLists",key:key) == nil { _ = try db.insert("TargetsToTargetLists",values:key,actor:identity.id); count += 1 }
            }
            if count > 0 { _ = try db.update(active("crm_TargetLists",id:listID),changes:["updatedAt":.text(ISO8601DateFormatter().string(from:Date()))],actor:identity.id,action:"members_add") }
            return count
        }
    }
    @discardableResult func removeTargets(_ targetIDs: [String], from listID: String) throws -> Int {
        return try db.transaction {
            try assertAccess("crm_TargetLists",id:listID,write:true)
            var count = 0
            for id in Set(targetIDs).sorted() {
                if let link = try db.get("TargetsToTargetLists",key:["target_id":.text(id),"target_list_id":.text(listID)]) { try db.remove(link,actor:identity.id); count += 1 }
            }
            if count > 0 { _ = try db.update(active("crm_TargetLists",id:listID),changes:["updatedAt":.text(ISO8601DateFormatter().string(from:Date()))],actor:identity.id,action:"members_remove") }
            return count
        }
    }
    func isWatching(_ accountID: String) throws -> Bool {
        try assertAccess("crm_Accounts",id:accountID)
        return try db.get("AccountWatchers",key:["account_id":.text(accountID),"user_id":.text(identity.id)]) != nil
    }
    @discardableResult func setWatching(_ accountID: String, enabled: Bool) throws -> Bool {
        return try db.transaction {
            try assertAccess("crm_Accounts",id:accountID,write:true)
            guard identity.role != "partner" else { throw NativeDBError.message("ウォッチ設定を変更する権限がありません。") }
            let key: [String:SQLValue] = ["account_id":.text(accountID),"user_id":.text(identity.id)]
            let existing = try db.get("AccountWatchers",key:key)
            if enabled && existing == nil { _ = try db.insert("AccountWatchers",values:key,actor:identity.id) }
            else if !enabled, let existing { try db.remove(existing,actor:identity.id) }
            else { return false }
            _ = try db.update(active("crm_Accounts",id:accountID),changes:["updatedBy":.text(identity.id),"updatedAt":.text(ISO8601DateFormatter().string(from:Date()))],actor:identity.id,action:enabled ? "watch" : "unwatch")
            return true
        }
    }
    func setPartner(_ account: NativeRecord, userID: String?) throws -> NativeRecord {
        try authenticated()
        guard identity.elevated, account.model == "crm_Accounts" else { throw NativeDBError.message("外部パートナーを設定できるのは管理者とマネージャーです。") }
        return try db.transaction {
            try assertAccess(account.model,id:account["id"].string,write:true)
            if let id = userID {
                let user = try db.get("Users",key:["id":.text(id)])
                guard user?["role"] == .text("partner"), user?["userStatus"] == .text("ACTIVE"), user?["banned"] == .integer(0) else { throw NativeDBError.message("有効なパートナー利用者を選択してください。") }
            }
            return try db.update(account,changes:["partnerUserId":userID.map(SQLValue.text) ?? .null,"updatedBy":.text(identity.id),"updatedAt":.text(ISO8601DateFormatter().string(from:Date()))],actor:identity.id,action:"partner")
        }
    }
    func convertTarget(_ original: NativeRecord, createOpportunity: Bool) throws -> CRMConversion {
        try authenticated()
        guard original.model == "crm_Targets", identity.role != "partner" else { throw NativeDBError.message("営業対象を変換する権限がありません。") }
        return try db.transaction {
            try assertAccess(original.model,id:original["id"].string,write:true)
            let target = try active(original.model,id:original["id"].string)
            let company = target["company"].string.trimmingCharacters(in:.whitespacesAndNewlines)
            let lastName = target["last_name"].string.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !company.isEmpty || !lastName.isEmpty else { throw NativeDBError.message("変換には会社名または姓が必要です。") }
            let account: NativeRecord; let contact: NativeRecord
            if target["converted_at"] != .null, target["converted_account_id"] != .null, target["converted_contact_id"] != .null {
                account = try active("crm_Accounts",id:target["converted_account_id"].string)
                contact = try active("crm_Contacts",id:target["converted_contact_id"].string)
                try assertAccess(account.model,id:account["id"].string)
                try assertAccess(contact.model,id:contact["id"].string)
            } else {
                guard original.revision == target.revision else { throw NativeDBError.conflict }
                func mapped(_ pairs: [(String,String)]) -> [String:SQLValue] {
                    var values: [String:SQLValue] = [:]
                    for (source,destination) in pairs where target[source] != .null { values[destination] = target[source] }
                    return values
                }
                var accountValues = mapped([("company_email","email"),("company_phone","office_phone"),("company_website","website"),("city","billing_city"),("country","billing_country"),("employees","employees"),("description","description")])
                accountValues.merge(["v":.integer(0),"name":.text(company.isEmpty ? lastName : company),"status":.text("Active"),"createdBy":.text(identity.id)]) { _,new in new }
                account = try db.insert("crm_Accounts",values:accountValues,actor:identity.id)
                var contactValues = mapped([("first_name","first_name"),("email","email"),("personal_email","personal_email"),("mobile_phone","mobile_phone"),("office_phone","office_phone"),("position","position"),("social_linkedin","social_linkedin"),("social_x","social_twitter"),("social_instagram","social_instagram"),("social_facebook","social_facebook")])
                contactValues.merge(["v":.integer(0),"last_name":.text(lastName.isEmpty ? company : lastName),"accountsIDs":account["id"],"createdBy":.text(identity.id)]) { _,new in new }
                contact = try db.insert("crm_Contacts",values:contactValues,actor:identity.id)
                _ = try db.update(target,changes:["converted_at":.text(ISO8601DateFormatter().string(from:Date())),"converted_account_id":account["id"],"converted_contact_id":contact["id"],"updatedBy":.text(identity.id)],actor:identity.id,action:"convert")
                try db.enqueue("crm/account.saved",payload:["record_id":account["id"].string,"actorID":identity.id]); try db.enqueue("crm/contact.saved",payload:["record_id":contact["id"].string,"actorID":identity.id])
            }
            guard createOpportunity else { return CRMConversion(account:account,contact:contact,opportunity:nil) }
            if let existing = try db.page("crm_Opportunities",fields:[],equal:["account":account["id"],"contact":contact["id"]]).rows.first {
                try assertAccess(existing.model,id:existing["id"].string)
                return CRMConversion(account:account,contact:contact,opportunity:try active(existing.model,id:existing["id"].string))
            }
            let stage = try db.page("crm_Opportunities_Sales_Stages",fields:["stage_kind"],sort:"order").rows.first
            guard stage?["stage_kind"] != .text("qualified") else { throw NativeDBError.message("初期の営業段階が承認必須になっています。未承認で開始できる段階を設定してください。") }
            let liveCampaign = RecordFilter.every([.equal("deletedAt",.null),.any([.equal("status",.null),.not(.equal("status",.text("deleted")))])])
            let sent = RecordFilter.every([.equal("target_id",target["id"]),.not(.equal("sent_at",.null)),.relation(model:"crm_campaigns",local:"campaign_id",foreign:"id",matching:liveCampaign)])
            let lastSend = try db.page("crm_campaign_sends",fields:["campaign_id"],filter:sent,sort:"sent_at",descending:true).rows.first
            let now = SQLValue.text(ISO8601DateFormatter().string(from:Date()))
            let opportunity = try db.insert("crm_Opportunities",values:["name":.text((company.isEmpty ? lastName : company) + " — 問い合わせ"),"account":account["id"],"contact":contact["id"],"campaign":lastSend?["campaign_id"] ?? .null,"sales_stage":stage?["id"] ?? .null,"stage_entered_at":now,"assigned_to":.text(identity.id),"createdBy":.text(identity.id),"updatedBy":.text(identity.id),"last_activity_by":.text(identity.id),"last_activity":now,"status":.text("ACTIVE")],actor:identity.id)
            try db.enqueue("crm/opportunity.saved",payload:["record_id":opportunity["id"].string,"actorID":identity.id])
            if let stage { try db.enqueueOpportunityStageChange(recordID:opportunity["id"].string,toStage:stage["id"].string) }
            return CRMConversion(account:account,contact:contact,opportunity:opportunity)
        }
    }
}
