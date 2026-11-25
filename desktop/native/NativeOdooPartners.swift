import Foundation

enum NativeOdooPartners {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    static func matchAccount(_ ctx:NativePluginContext,partnerID:Double,fields:Row) throws -> Row {
        if let link=try S.stored(ctx,S.key("partner",partnerID)),let id=link["accountId"] as? String,
           let account=try ctx.data.get("accounts",id),account["deletedAt"] == nil || account["deletedAt"] is NSNull { return ["kind":"linked","accountId":id] }
        func pick(_ rows:[Row],_ reason:String)throws->Row? {
            if rows.isEmpty { return nil };let ids=rows.map { M.string($0["id"]) }
            if rows.count>1 { return ["kind":"conflict","reason":reason,"candidates":ids] }
            if let link=try S.stored(ctx,S.key("account",ids[0])),M.number(link["partnerId"]) != partnerID { return ["kind":"conflict","reason":"linked","candidates":ids] }
            return ["kind":reason,"accountId":ids[0]]
        }
        let country=fields["billing_country"] as? String
        if let number=M.normalizeNumber(country,fields["company_id"] as? String) {
            let raw=Array(Set([M.string(fields["company_id"]),number,M.replace(number,#"^0+"#,"")]))
            let rows=try ctx.data.find("accounts",["where":["deletedAt":NSNull(),"company_id":["in":raw]]]).filter { M.normalizeNumber(country,$0["company_id"] as? String) == number }
            if let hit=try pick(rows,"number") { return hit }
        }
        if let vat=M.normalizeVAT(fields["vat"] as? String) {
            let rows=try ctx.data.find("accounts",["where":["deletedAt":NSNull(),"vat":["in":Array(Set([M.string(fields["vat"]),vat]))]]]).filter { M.normalizeVAT($0["vat"] as? String) == vat }
            if let hit=try pick(rows,"vat") { return hit }
        };return ["kind":"new"]
    }
    static func countryID(_ client:NativeOdooClient,_ code:String) async throws -> Any {
        try await client.rows("res.country","search_read",["domain":[["code","=",code.uppercased()]],"fields":["id"],"limit":1]).first?["id"] ?? false
    }
    static func salesperson(_ ctx:NativePluginContext,_ client:NativeOdooClient,ownerID:String?) async throws -> Any {
        guard let ownerID,!ownerID.isEmpty,let owner=try ctx.data.get("users",ownerID),let email=owner["email"] as? String,!email.isEmpty else { return false }
        return try await client.rows("res.users","search_read",["domain":["|",["login","=ilike",email],["email","=ilike",email]],"fields":["id"],"limit":1]).first?["id"] ?? false
    }
    static func link(_ ctx:NativePluginContext,accountID:String,partnerID:Double,list:Any?,now:Date)throws {
        try ctx.store.set(S.key("partner",partnerID),["accountId":accountID])
        try ctx.store.set(S.key("account",accountID),["partnerId":partnerID,"syncedAt":NativePluginJSON.stamp(now),"salesperson":NSNull(),"odooPriceList":M.or(list,NSNull())])
    }
    static func exclusive<T>(_ ctx:NativePluginContext,key:String,_ body:() async throws -> T) async throws -> T {
        guard try ctx.store.claim(key,ms:30*60_000) else { throw NativeOdooError(message:"Another order is creating \(key) in Odoo",status:0) }
        return try await S.cleanup(ctx,key:key,body)
    }
    static func customer(_ ctx:NativePluginContext,_ client:NativeOdooClient,account:Row,user:Any,now:Date) async throws -> Row {
        let accountID=M.string(account["id"])
        if let linked=try S.stored(ctx,S.key("account",accountID)) { return ["partnerId":linked["partnerId"] ?? NSNull(),"created":false] }
        return try await exclusive(ctx,key:"customer:"+accountID) {
            let code=M.string(M.or(account["billing_country"],ctx.settings["defaultCountry"] ?? "CZ")).uppercased(),country=try await countryID(client,code)
            let base:[[Any]]=[["parent_id","=",false],["active","=",true]],number=M.normalizeNumber(code,M.clean(account["company_id"])),vat=M.normalizeVAT(M.clean(account["vat"]))
            var attempts:[(domain:[[Any]],keep:(Row)->Bool)]=[]
            if let number { attempts.append((base+[["company_registry","ilike",M.replace(number,#"^0+"#,"")],["country_id","=",country]], { M.normalizeNumber(code,M.clean($0["company_registry"])) == number })) }
            if let vat { attempts.append((base+[["vat","ilike",M.replace(vat,#"^[A-Z]{2}"#,"")]], { M.normalizeVAT(M.clean($0["vat"])) == vat })) }
            if number == nil && vat == nil { attempts.append((base+[["name","=",account["name"] ?? NSNull()],["country_id","=",country]], { _ in true })) }
            for attempt in attempts {
                let rows=try await client.rows("res.partner","search_read",["domain":attempt.domain,"fields":["id","property_product_pricelist","company_registry","vat"],"order":"id asc"])
                if let p=rows.first(where:attempt.keep) { let id=M.number(p["id"]);try link(ctx,accountID:accountID,partnerID:id,list:p["property_product_pricelist"],now:now);return ["partnerId":id,"created":false] }
            }
            var values:Row=["name":account["name"] ?? NSNull(),"is_company":true,"country_id":country,"customer_rank":1,"user_id":user]
            for (key,input) in [("company_registry","company_id"),("vat","vat"),("street","billing_street"),("city","billing_city"),("zip","billing_postal_code"),("email","email"),("phone","office_phone")] { values[key]=M.clean(account[input]) as Any? ?? false }
            if M.truth(account["pricelist_id"]),let list=try ctx.store.list("pricelist:").first(where: { M.strictEqual(($0.value as? Row)?["priceListId"] ?? NSNull(),account["pricelist_id"]!) }) { values["property_product_pricelist"]=M.number(String(list.key.dropFirst(10))) }
            guard let id=try await client.ids("res.partner","create",["vals_list":[values]],once:true).first else { throw NativePluginError(message:"Odoo returned no customer identifier") }
            let p=try await client.rows("res.partner","read",["ids":[id],"fields":["property_product_pricelist"]]).first
            try link(ctx,accountID:accountID,partnerID:id,list:p?["property_product_pricelist"],now:now);return ["partnerId":id,"created":true]
        }
    }
    static func delivery(_ ctx:NativePluginContext,_ client:NativeOdooClient,partnerID:Double,order:Row) async throws -> Row {
        guard M.clean(order["shipping_street"]) != nil || M.clean(order["shipping_city"]) != nil else { return ["shippingId":partnerID,"created":false] }
        return try await exclusive(ctx,key:S.key("delivery",partnerID)) {
            let want:Row=["street":order["shipping_street"] ?? NSNull(),"city":order["shipping_city"] ?? NSNull(),"zip":order["shipping_postal_code"] ?? NSNull()]
            let rows=try await client.rows("res.partner","search_read",["domain":["|",["id","=",partnerID],"&",["parent_id","=",partnerID],["type","=","delivery"]],"fields":["id","street","city","zip"],"order":"id asc"])
            if let row=rows.first(where: { M.sameAddress($0,want) }) { return ["shippingId":row["id"] ?? NSNull(),"created":false] }
            let country=try await countryID(client,M.string(M.or(order["shipping_country"],ctx.settings["defaultCountry"] ?? "CZ")))
            let values:Row=["parent_id":partnerID,"type":"delivery","street":M.clean(order["shipping_street"]) as Any? ?? false,"city":M.clean(order["shipping_city"]) as Any? ?? false,"zip":M.clean(order["shipping_postal_code"]) as Any? ?? false,"country_id":country]
            guard let id=try await client.ids("res.partner","create",["vals_list":[values]],once:true).first else { throw NativePluginError(message:"Odoo returned no delivery identifier") };return ["shippingId":id,"created":true]
        }
    }
}
