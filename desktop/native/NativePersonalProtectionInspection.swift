import Foundation

/// Read-only admission of restored protection indexes. Never calls onInstall,
/// invents registrations, normalizes old values, or releases old plugin jobs.
enum NativePersonalProtectionInspection {
    static func valid(host:NativePluginHost)throws->Bool {
        let db=host.db
        guard try !db.personalProtectionStoreOversized(),let definition=host.definition(NativeAccountProtection.id) else{return false}
        let context=try host.context(definition,actor:.system),store=context.store
        var offset=0
        repeat {
            let page=try db.mcpPage("PluginData",fields:["key"],filter:.every([
                .equal("pluginId",.text(NativeAccountProtection.id)),.equal("entityType",.text("")),.equal("entityId",.text(""))]),
                limit:100,offset:offset,order:[("key",false)],includeDeleted:true)
            for row in page.rows {
                try Task.checkCancellation();let key=row["key"].string
                guard ["num:","acct:","reg:","conflict:","hist:"].contains(where:key.hasPrefix) else{continue}
                // Fetch at most one critical value after the bounded key page.
                // Unknown keys do not materialize arbitrary JSON into memory.
                guard let value=(try? store.get(key)) as? NativePluginRecord else{return false}
                func text(_ field:String)->String?{value[field] as? String}
                func date(_ field:String)->Bool{guard let v=text(field) else{return false};return (try? NativePluginJSON.date(v)) != nil}
                if key.hasPrefix("num:") {
                    guard let id=text("accountId"),let account=try context.data.get("accounts",id),!NativePluginJSON.truthy(account["deletedAt"]),
                          NativeAccountProtection.key(account,context)==String(key.dropFirst(4)) else{return false}
                } else if key.hasPrefix("acct:") {
                    guard let expected=text("key"),let account=try context.data.get("accounts",String(key.dropFirst(5))),
                          !NativePluginJSON.truthy(account["deletedAt"]),NativeAccountProtection.key(account,context)==expected else{return false}
                } else if key.hasPrefix("reg:") {
                    guard text("key") != nil,text("ownerId") != nil,date("registeredAt"),date("contactDeadline"),date("protectedUntil") else{return false}
                    if value["baseUntil"] != nil && !date("baseUntil"){return false}
                    if let at=value["contactAt"],!(at is NSNull),!date("contactAt"){return false}
                } else if key.hasPrefix("hist:") {
                    guard date("at") else{return false}
                    for field in ["from","to"] {if let value=value[field],!(value is NSNull),!(value is String){return false}}
                } else {guard text("key") != nil,text("otherAccountId") != nil,date("foundAt") else{return false}}
            }
            offset+=page.rows.count;if page.rows.count<100{break}
        } while true
        offset=0
        repeat {
            let page=try db.mcpPage("crm_Accounts",fields:["company_id","billing_country","assigned_to"],filter:.all,
                limit:100,offset:offset,order:[("id",false)])
            for row in page.rows {
                try Task.checkCancellation();let id=row["id"].string
                let account:NativePluginRecord=["company_id":row["company_id"].string,"billing_country":row["billing_country"].string]
                let indexed=try store.get("acct:"+id) as? NativePluginRecord
                guard let key=NativeAccountProtection.key(account,context) else{if indexed != nil{return false};continue}
                guard let holder=try store.get("num:"+key) as? NativePluginRecord,let holderID=holder["accountId"] as? String else{return false}
                if holderID==id {guard indexed?["key"] as? String==key else{return false}}
                else {
                    guard let conflict=try store.get("conflict:"+id) as? NativePluginRecord,
                          conflict["key"] as? String==key,conflict["otherAccountId"] as? String==holderID else{return false}
                }
                if let reg=try store.get("reg:"+id) as? NativePluginRecord {
                    guard reg["ownerId"] as? String==row["assigned_to"].string,reg["key"] as? String==key else{return false}
                }
            }
            offset+=page.rows.count;if page.rows.count<100{break}
        } while true
        return true
    }
}
