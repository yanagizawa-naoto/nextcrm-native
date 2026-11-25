import Foundation

extension NativeOXOConnector {
    final class CustomerRun {
        let dry:Bool,now:Date
        var counts:Row=Dictionary(uniqueKeysWithValues:["linked","number","vat","name","created","updated","conflicts","skipped","failed"].map{($0,0 as Any)})
        var rows:[String:[Row]]=["name":[],"created":[],"conflicts":[]],claimed:[String:Double]=[:]
        init(dry:Bool,now:Date) { self.dry=dry;self.now=now }
        func add(_ k:String,_ row:Row) { if (rows[k]?.count ?? 0)<200 { rows[k,default:[]].append(row) } }
        func count(_ k:String) { counts[k]=(counts[k] as? Int ?? 0)+1 }
    }
    func matchAccount(_ id:Double,_ f:Row,_ claimed:[String:Double]) throws -> Row {
        if let linked=try stored(key("customer",id)),let account=try ctx.data.get("accounts",M.string(linked["accountId"])),account["deletedAt"] == nil || account["deletedAt"] is NSNull { return ["kind":"linked","accountId":linked["accountId"]!] }
        func pick(_ rows:[Row],_ reason:String) throws -> Row? {
            guard !rows.isEmpty else { return nil };let ids=rows.map{M.string($0["id"])}
            if rows.count>1 { return ["kind":"conflict","reason":reason,"candidates":ids] }
            let owner=try claimed[ids[0]] ?? stored(key("account",ids[0]))?["customerId"].map(M.number)
            if let owner,owner != id { return ["kind":"conflict","reason":"linked","candidates":ids] }
            return ["kind":reason,"accountId":ids[0]]
        }
        let country=M.coalesce(f["billing_country"],ctx.settings["defaultCountry"] ?? "CZ") as? String
        if let number=M.normalizeNumber(country,f["company_id"] as? String) {
            let raw=Array(Set([M.string(f["company_id"]),number,number.replacingOccurrences(of:"^0+",with:"",options:.regularExpression)]))
            let rows=try ctx.data.find("accounts",["where":["deletedAt":M.null,"company_id":["in":raw]]]).filter{M.normalizeNumber(country,$0["company_id"] as? String)?.utf16.elementsEqual(number.utf16)==true}
            if let m=try pick(rows,"number") { return m }
        }
        if let vat=M.normalizeVAT(f["vat"] as? String) {
            let rows=try ctx.data.find("accounts",["where":["deletedAt":M.null,"vat":["in":Array(Set([M.string(f["vat"]),vat,vat.lowercased()]))]]]).filter{M.normalizeVAT($0["vat"] as? String)?.utf16.elementsEqual(vat.utf16)==true}
            if let m=try pick(rows,"vat") { return m }
        }
        if M.truth(f["billing_postal_code"]) {
            func zip(_ v:Any?) -> String { M.string(M.coalesce(v,"")).components(separatedBy:NativeOdooMap.whitespace).joined() }
            let rows=try ctx.data.find("accounts",["where":["deletedAt":M.null,"name":["equals":f["name"] ?? "","mode":"insensitive"]]]).filter{zip($0["billing_postal_code"]).utf16.elementsEqual(zip(f["billing_postal_code"]).utf16)}
            if let m=try pick(rows,"name") { return m }
        }
        return ["kind":"new"]
    }
    func syncCustomer(_ r:CustomerRun,_ customer:Row) throws {
        let id=M.number(customer["id"])
        if !M.truth(customer["active"]) {
            let link=try stored(key("customer",id))
            if !r.dry {
                try ctx.store.delete(key("conflict",id))
                if let link,var previous=try stored(key("account",link["accountId"])) { previous["inactive"]=true;previous["syncedAt"]=stamp(r.now);try ctx.store.set(key("account",link["accountId"]),previous) }
            }
            r.count("skipped");return
        }
        let fields=try M.accountFields(customer),match=try matchAccount(id,fields,r.claimed),kind=M.string(match["kind"])
        if kind == "conflict" {
            r.count("conflicts");var row:Row=["customerId":id,"name":fields["name"]!,"reason":match["reason"]!,"candidates":match["candidates"]!];r.add("conflicts",row)
            if !r.dry { row["foundAt"]=stamp(r.now);row["customer"]=customer;try ctx.store.set(key("conflict",id),row) };return
        }
        if !r.dry { try ctx.store.delete(key("conflict",id)) }
        let accountID:String
        if kind == "new" {
            r.count("created");r.add("created",["customerId":id,"name":fields["name"]!]);if r.dry { return }
            var input=fields;input["billing_country"]=M.coalesce(fields["billing_country"],ctx.settings["defaultCountry"] ?? "CZ");input["assigned_to"]=M.null;input["status"]="Active"
            accountID=M.string(try ctx.data.create(.account,input)["id"])
        } else {
            accountID=M.string(match["accountId"]);r.count(kind)
            if kind == "name" { r.add("name",["customerId":id,"name":fields["name"]!,"accountId":accountID]) }
            r.claimed[accountID]=id
            let diff=try M.changedFields(ctx.data.get("accounts",accountID) ?? [:],fields)
            if !diff.isEmpty { r.count("updated");if !r.dry { _ = try ctx.data.update(.account,accountID,diff) } }
            if r.dry { return }
        }
        r.claimed[accountID]=id;try ctx.store.set(key("customer",id),["accountId":accountID])
        try ctx.store.set(key("account",accountID),["customerId":id,"syncedAt":stamp(r.now),"priceListId":customer["priceListId"] ?? M.null,"addresses":(customer["addresses"] as? [Row] ?? []).filter{M.truth($0["active"])}])
    }
    func syncCustomers(_ run:CustomerRun) async throws -> String? {
        var (top,params)=try since("customers");let fresh=try await client.all("/customers",params);var done=Set<Double>()
        func guarded(_ customer:Row) throws {
            let id=M.number(customer["id"]);guard done.insert(id).inserted else { return }
            do { try Task.checkCancellation();try syncCustomer(run,customer);if !run.dry { try ctx.store.delete(key("retry",id)) } }
            catch { try cancelled(error);run.count("failed");ctx.log("error","Customer \(M.string(id)) failed: "+message(error),["customerId":id]);if !run.dry { try ctx.store.set(key("retry",id),["customer":customer]) } }
        }
        for (i,customer) in fresh.enumerated() { if let at=customer["updatedAt"] as? String,top == nil || at>top! { top=at };try guarded(customer);if (i+1)%100==0 { try keepLock() } }
        for entry in try entries("conflict:")+entries("retry:") { try guarded(entry.value["customer"] as? Row ?? [:]) }
        return top
    }
}
