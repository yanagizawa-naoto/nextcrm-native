import Foundation

extension NativeOXOConnector {
    func productMap() throws -> [Double:String] { var out:[Double:String]=[:];for e in try entries("product:") { out[M.number(e.value["oxoId"])]=String(e.key.dropFirst(8)) };return out }
    func syncCatalog(dry:Bool,now:Date) async throws -> (counts:Row,top:String?) {
        var counts:Row=Dictionary(uniqueKeysWithValues:["categoriesMatched","categoriesCreated","productsUpdated","productsCreated","productsFailed","listsReplaced","accountLists"].map{($0,0 as Any)});counts["listsMissing"]=[Double]()
        func count(_ key:String) { counts[key]=(counts[key] as? Int ?? 0)+1 }
        var paths=try Dictionary(uniqueKeysWithValues:M.categoryPaths(ctx.data.externalCategories()).map{(M.exactKey($0.path),$0.ref)}),matched=Set<String>()
        func ensure(_ path:String) throws -> String {
            if let known=paths[M.exactKey(path)] { if !known.hasPrefix("oxo-cat:") { matched.insert(M.exactKey(path)) };return known }
            let cut=path.range(of:M.separator,options:.backwards),hasParent=cut.map{$0.lowerBound>path.startIndex} ?? false
            let parent=try hasParent ? ensure(String(path[..<cut!.lowerBound])):nil,ref="oxo-cat:"+path
            paths[M.exactKey(path)]=ref;count("categoriesCreated")
            if !dry { _ = try ctx.data.upsertExternalCategory(ref,["name":hasParent ? String(path[cut!.upperBound...]):path,"parentRef":parent as Any? ?? M.null]) };return ref
        }
        var (top,params)=try since("products");let fresh=try await client.all("/products",params),retry=try entries("retryProduct:").map{$0.value["product"] as? Row ?? [:]}
        var external:[String:String]=[:];for p in try ctx.data.externalProducts() { external[M.string(p["ref"])]=M.string(p["id"]) }
        var links:[String:Row]=[:],known:[Double:Row]=[:],knownOrder:[Double]=[]
        for e in try entries("product:") { links[String(e.key.dropFirst(8))]=e.value;let id=M.number(e.value["oxoId"]);if known[id]==nil { knownOrder.append(id) };known[id]=["ref":e.value["ref"] ?? M.null,"templateId":e.value["templateId"] ?? M.null] }
        var done=Set<Double>()
        for (i,p) in (fresh+retry).enumerated() {
            try Task.checkCancellation();if (i+1)%100==0 { try keepLock() }
            if i<fresh.count,let at=p["updatedAt"] as? String,top == nil || at>top! { top=at }
            let id=M.number(p["id"]);guard done.insert(id).inserted else { continue }
            let ref=M.ref(p),crmID=external[ref];if crmID == nil && !(M.truth(p["saleOk"]) && M.truth(p["active"])) { continue }
            do {
                let category=try M.truth(p["category"]) ? ensure(M.string(p["category"])):nil
                let current:Row?
                if let crmID { current=try ctx.data.get("products",crmID) }
                else if M.truth(p["code"]) { current=try ctx.data.find("products",["where":["sku":p["code"]!,"source":"CRM","deletedAt":M.null],"take":1]).first } else { current=nil }
                let fields=M.productFields(p,categoryRef:category,currency:M.string(ctx.settings["currency"]),current:current)
                if known[id]==nil { knownOrder.append(id) };known[id]=["ref":ref,"templateId":p["odooTemplateId"] ?? M.null]
                if let crmID,M.sameProduct(current,fields,links[crmID]) { continue }
                if dry { count(crmID == nil ? "productsCreated":"productsUpdated");continue }
                let result=try ctx.data.upsertExternalProduct(ref,fields,["adoptBySku":true]),productID=M.string(result["id"])
                if M.truth(result["adopted"]) { ctx.log("info","Took over CRM product \(M.string(fields["sku"])) (\(M.string(fields["name"])))",["oxoId":id,"productId":productID]) }
                count(M.truth(result["created"]) ? "productsCreated":"productsUpdated");external[ref]=productID
                try ctx.store.set(key("product",productID),["oxoId":id,"ref":ref,"templateId":p["odooTemplateId"] ?? M.null,"categoryRef":category as Any? ?? M.null]);try ctx.store.delete(key("retryProduct",id))
            } catch { try cancelled(error);count("productsFailed");known.removeValue(forKey:id);knownOrder.removeAll{$0==id};ctx.log("error","Product \(M.string(id)) failed: "+message(error),["oxoId":id]);if !dry { try ctx.store.set(key("retryProduct",id),["product":p]) } }
        }
        counts["categoriesMatched"]=matched.count
        let response=try await client.get("/price-lists",[]) as? Row ?? [:];var snapshot:[Double:Row]=[:]
        for l in response["items"] as? [Row] ?? [] { snapshot[M.number(l["id"])]=l }
        let chosen=M.chosenLists(M.string(ctx.settings["priceLists"]));var previous:[Double:Row]=[:],storedOrder:[Double]=[]
        for e in try entries("pricelist:") { let id=M.number(String(e.key.dropFirst(10)));if previous[id]==nil { storedOrder.append(id) };previous[id]=e.value }
        var missing:[Double]=[]
        for id in chosen where snapshot[id]==nil { missing.append(id);ctx.log("warn","OXO ERP price list \(M.string(id)) not found") };counts["listsMissing"]=missing
        var wanted=Set<Double>()
        func want(_ id:Double) { guard let list=snapshot[id],wanted.insert(id).inserted else { return };for rule in list["rules"] as? [Row] ?? [] where M.string(rule["base"]) == "PRICE_LIST" && !(M.coalesce(rule["basePriceListId"],M.null) is NSNull) { want(M.number(rule["basePriceListId"])) } }
        for id in chosen+storedOrder { want(id) }
        var deps:[Double:[Double]]=[:]
        for id in wanted { deps[id]=(snapshot[id]?["rules"] as? [Row] ?? []).filter{M.string($0["base"]) == "PRICE_LIST" && !(M.coalesce($0["basePriceListId"],M.null) is NSNull) && wanted.contains(M.number($0["basePriceListId"]))}.map{M.number($0["basePriceListId"])} }
        let sorted=M.orderLists(deps,maxChain:11)
        for id in sorted["cyclic"] as? [Double] ?? [] { ctx.log("warn","Price list \(M.string(id)) skipped: its base lists form a cycle") }
        for id in sorted["tooDeep"] as? [Double] ?? [] { ctx.log("warn","Price list \(M.string(id)) skipped: it builds on more than 10 other lists") }
        var products:[Double:String]=[:],templates:[Double:[String]]=[:],listRefs:[Double:String]=[:]
        for id in knownOrder { guard let k=known[id] else { continue };let ref=M.string(k["ref"]);products[id]=ref;if !(M.coalesce(k["templateId"],M.null) is NSNull) { templates[M.number(k["templateId"]),default:[]].append(ref) } }
        for id in sorted["order"] as? [Double] ?? [] {
            guard let list=snapshot[id] else { continue };let rules=list["rules"] as? [Row] ?? []
            for rule in rules where M.string(rule["appliesTo"]) == "CATEGORY" && M.truth(rule["categoryName"]) { _ = try ensure(M.string(rule["categoryName"])) }
            let mapped=M.mapRules(rules,products:products,templates:templates,categoryRef:{paths[M.exactKey($0)]},listRef:{listRefs[$0]}),active=chosen.contains(id),ref=M.ref(list)
            let hash=try M.listHash(name:list["name"] ?? M.null,currency:list["currency"] ?? M.null,active:active,rules:mapped.rules);listRefs[id]=ref
            if !dry { try ctx.store.set(key("skipped",id),mapped.skipped) }
            if previous[id]?["hash"] as? String == hash { continue };count("listsReplaced");if dry { continue }
            let fields:Row=["name":list["name"] ?? M.null,"currency":list["currency"] ?? M.null,"isActive":active]
            let result=try ctx.data.replaceExternalPriceList(ref,fields,mapped.rules)
            try ctx.store.set(key("pricelist",id),["priceListId":result["id"] ?? M.null,"ref":ref,"name":list["name"] ?? M.null,"currency":list["currency"] ?? M.null,"hash":hash,"syncedAt":stamp(now),"isActive":active])
        }
        for id in storedOrder { guard var old=previous[id],snapshot[id]==nil,M.truth(old["isActive"]) else { continue };count("listsReplaced");if dry { continue }
            _ = try ctx.data.replaceExternalPriceList(M.string(old["ref"]),["name":old["name"] ?? M.null,"currency":old["currency"] ?? M.null,"isActive":false],[])
            old["isActive"]=false;old["hash"]="";old["syncedAt"]=stamp(now);try ctx.store.set(key("pricelist",id),old)
        }
        for e in try entries("account:") {
            guard !(M.coalesce(e.value["priceListId"],M.null) is NSNull),chosen.contains(M.number(e.value["priceListId"])),let list=try stored(key("pricelist",e.value["priceListId"])) else { continue }
            let id=String(e.key.dropFirst(8));guard let account=try ctx.data.get("accounts",id),!NativePluginJSON.equal(account["pricelist_id"],list["priceListId"]) else { continue }
            count("accountLists");if !dry { _ = try ctx.data.update(.account,id,["pricelist_id":list["priceListId"] ?? M.null]) }
        }
        return (counts,top)
    }
}
