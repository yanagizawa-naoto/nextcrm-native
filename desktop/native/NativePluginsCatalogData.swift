import Foundation

extension NativePluginData {
    func all(_ model:String,where predicate:NativePluginRecord) throws -> [NativePluginRecord] {
        var result:[NativePluginRecord]=[],offset=0
        while true { let page=try rawFind(model,["where":predicate,"skip":offset,"take":100]);result += page;if page.count<100 { return result };offset+=page.count }
    }
    private func external(_ model:String,_ ref:String) throws -> NativeRecord? {
        try db.page(model,fields:db.schema.model(model).fields.map(\.name),equal:["source":.text("EXTERNAL"),"externalRef":.text(ref)],includeDeleted:true,limit:1).rows.first
    }
    private func category(_ ref:Any?) throws -> SQLValue {
        guard let ref=ref as? String,!ref.isEmpty else { return .null }
        guard let row=try external("crm_ProductCategories",ref) else { throw NativePluginError(message:"Unknown category ref: "+ref) };return row["id"]
    }
    func upsertExternalCategory(_ ref:String,_ fields:NativePluginRecord) throws -> NativePluginRecord {
        try need("products:write")
        return try NativePluginActorScope.withActor(.plugin(pluginId)) {
            let parent=try category(fields["parentRef"]),old=try external("crm_ProductCategories",ref)
            var value=try values(["name":fields["name"] ?? NSNull()],model:"crm_ProductCategories");value["parentId"]=parent
            let row:NativeRecord
            if let old { value["updatedBy"] = .null;row=try db.update(old,changes:value,actor:"plugin:"+pluginId) }
            else { value["source"] = .text("EXTERNAL");value["externalRef"] = .text(ref);value["createdBy"] = .null;row=try db.insert("crm_ProductCategories",values:value,actor:"plugin:"+pluginId) }
            return ["id":row["id"].string]
        }
    }
    func upsertExternalProduct(_ ref:String,_ fields:NativePluginRecord,_ options:NativePluginRecord=[:]) throws -> NativePluginRecord {
        try need("products:write")
        return try NativePluginActorScope.withActor(.plugin(pluginId)) {
            let categoryId=try category(fields["categoryRef"]),old=try external("crm_Products",ref)
            var filtered=fields;filtered.removeValue(forKey:"categoryRef")
            var value=try values(filtered,model:"crm_Products");value["categoryId"]=categoryId
            if let sku=fields["sku"] as? String,!sku.isEmpty,let clash=try db.page("crm_Products",fields:db.schema.model("crm_Products").fields.map(\.name),equal:["sku":.text(sku)],includeDeleted:true,filter:.not(.every([.equal("source",.text("EXTERNAL")),.equal("externalRef",.text(ref))])),limit:1).rows.first {
                if old == nil,NativePluginJSON.truthy(options["adoptBySku"]),clash["source"] == .text("CRM"),clash["deletedAt"] == .null {
                    value["source"] = .text("EXTERNAL");value["externalRef"] = .text(ref);value["updatedBy"] = .null;value["v"] = .integer((Int64(clash["v"].string) ?? 0)+1)
                    try db.update(clash,changes:value,actor:"plugin:"+pluginId)
                    audit(entity:"product",id:clash["id"].string,action:"updated",changes:[["field":"source","old":"CRM","new":"EXTERNAL (\(pluginId) \(ref))"]])
                    return ["id":clash["id"].string,"created":false,"adopted":true]
                }
                throw NativePluginError(message:"SKU used by a \(clash["source"] == .text("CRM") ? "CRM":"different external") product: \(sku)")
            }
            if let old {
                value["updatedBy"] = .null;value["v"] = .integer((Int64(old["v"].string) ?? 0)+1);try db.update(old,changes:value,actor:"plugin:"+pluginId)
                return ["id":old["id"].string,"created":false]
            }
            value["source"] = .text("EXTERNAL");value["externalRef"] = .text(ref);value["createdBy"] = .null
            let row=try db.insert("crm_Products",values:value,actor:"plugin:"+pluginId)
            audit(entity:"product",id:row["id"].string,action:"created",changes:[pluginTag]);return ["id":row["id"].string,"created":true]
        }
    }
    func replaceExternalPriceList(_ ref:String,_ list:NativePluginRecord,_ rules:[NativePluginRecord]) throws -> NativePluginRecord {
        try need("priceLists:write")
        return try NativePluginActorScope.withActor(.plugin(pluginId)) {
            let old=try external("crm_PriceLists",ref)
            var resolved:[[String:SQLValue]]=[]
            for rule in rules {
                var fields=rule;for key in ["productRef","categoryRef","basePriceListRef","dateStart","dateEnd"] { fields.removeValue(forKey:key) }
                var row=try values(fields,model:"crm_PriceListRules");row["productId"] = .null;row["basePriceListId"] = .null
                for (key,model,target,label) in [("productRef","crm_Products","productId","product"),("basePriceListRef","crm_PriceLists","basePriceListId","base price list")] {
                    if let ref=rule[key] as? String,!ref.isEmpty { guard let related=try external(model,ref) else { throw NativePluginError(message:"Unknown \(label) ref: \(ref)") };row[target]=related["id"] }
                }
                row["categoryId"]=try category(rule["categoryRef"])
                for key in ["dateStart","dateEnd"] {
                    if NativePluginJSON.truthy(rule[key]),let text=rule[key] as? String {
                        guard let parsed=NativeMCPPriceDate.parse(text) else { throw NativePluginError(message:"Invalid time value") };row[key] = .text(parsed)
                    } else { row[key] = .null }
                }
                resolved.append(row)
            }
            return try db.transaction {
                var fields=try values(list,model:"crm_PriceLists");let row:NativeRecord
                if let old { fields["updatedBy"] = .null;row=try db.update(old,changes:fields,actor:"plugin:"+pluginId) }
                else { fields["source"] = .text("EXTERNAL");fields["externalRef"] = .text(ref);fields["createdBy"] = .null;row=try db.insert("crm_PriceLists",values:fields,actor:"plugin:"+pluginId) }
                while true { let page=try db.page("crm_PriceListRules",fields:[],equal:["priceListId":row["id"]]);if page.rows.isEmpty { break };for item in page.rows { try db.remove(item,actor:"plugin:"+pluginId) } }
                let now=clock()
                for (index,var fields) in resolved.enumerated() { fields["priceListId"]=row["id"];fields["createdAt"] = .text(NativePluginJSON.stamp(now.addingTimeInterval(Double(index)/1000)));try db.insert("crm_PriceListRules",values:fields,actor:"plugin:"+pluginId) }
                return ["id":row["id"].string]
            }
        }
    }
    func externalProducts() throws -> [NativePluginRecord] {
        try need("products:read")
        return try all("crm_Products",where:["source":"EXTERNAL","deletedAt":NSNull()]).map { ["id":$0["id"]!,"ref":$0["externalRef"] ?? NSNull(),"status":$0["status"]!] }
    }
    func externalCategories() throws -> [NativePluginRecord] {
        try need("products:read")
        return try all("crm_ProductCategories",where:["source":"EXTERNAL"]).map { row in
            var parent:Any=NSNull()
            if let id=row["parentId"] as? String,let value=try db.get("crm_ProductCategories",key:["id":.text(id)]),value["source"] == .text("EXTERNAL") { parent=value["externalRef"].json }
            return ["id":row["id"]!,"ref":row["externalRef"] ?? NSNull(),"name":row["name"]!,"parentRef":parent]
        }
    }
    func externalPriceLists() throws -> [NativePluginRecord] {
        try need("priceLists:read")
        return try all("crm_PriceLists",where:["source":"EXTERNAL"]).map { ["id":$0["id"]!,"ref":$0["externalRef"] ?? NSNull(),"name":$0["name"]!,"currency":$0["currency"]!,"isActive":$0["isActive"]!] }
    }
    func price(_ input:NativePluginRecord) throws -> NativePluginRecord {
        try need("products:read")
        let service=CRMService(db:db,identity:.init(id:"plugin:"+pluginId,role:"system",partnerAccountID:nil))
        var arguments=input;arguments.removeValue(forKey:"accountId");arguments["date"]=NativePluginJSON.stamp(clock())
        guard arguments["productId"] is String else { throw NativePluginError(message:"Product id is required") }
        arguments["quantity"]=NativePluginJSON.number(input["quantity"]) ?? Double(input["quantity"] as? String ?? "") ?? 1
        let result=try NativeMCPPriceLists.rawPrice(arguments,service:service).result
        let rule=try result.ruleId.flatMap { try db.get("crm_PriceListRules",key:["id":.text($0)]) }
        return ["price":try NativeMCPWire.decimal(result.price),"currency":result.currency,"ruleId":result.ruleId as Any? ?? NSNull(),"ruleBase":rule?["base"].json ?? NSNull()]
    }
}
