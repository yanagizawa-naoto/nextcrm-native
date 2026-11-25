import Foundation

enum NativeOdooCompare {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    struct Check { let product:Row,quantity:Double }
    static func run(_ ctx:NativePluginContext,_ client:NativeOdooClient,now:Date) async throws {
        var result:Row=["at":NativePluginJSON.stamp(now),"ok":true,"lists":[Row](),"mismatches":[Row]()],mismatches:[Row]=[],listResults:[Row]=[]
        try ctx.store.set("meta:lock",["until":NativePluginJSON.stamp(now.addingTimeInterval(600))])
        do {
            let products=try ctx.data.externalProducts().filter { M.string($0["status"]) == "ACTIVE" }
            var links:[String:Row]=[:],parents:Row=[:]
            for entry in try ctx.store.list("product:") { links[String(entry.key.dropFirst(8))]=entry.value as? Row }
            for entry in try ctx.store.list("category:") { parents[String(entry.key.dropFirst(9))]=(entry.value as? Row)?["parentRef"] ?? NSNull() }
            let sampleable=try products.map { p -> Row in let ref=M.string(p["ref"]),row=try ctx.data.get("products",M.string(p["id"]));return ["ref":ref,"categoryRef":links[ref]?["categoryRef"] ?? NSNull(),"id":p["id"] ?? NSNull(),"name":M.string(row?["name"] ?? ref),"currency":M.string(row?["currency"] ?? "")] }
            let chosen=M.chosenLists(M.string(ctx.settings["priceLists"])),fields=try await client.availableFields("product.pricelist.item",M.ruleFields)
            var done=0;try ctx.store.set("compare:progress",["done":done,"total":chosen.count])
            for id in chosen {
                guard let link=try S.stored(ctx,S.key("pricelist",id)) else { done += 1;try ctx.store.set("compare:progress",["done":done,"total":chosen.count]);continue }
                guard let list=try await client.rows("product.pricelist","read",["ids":[id],"fields":["currency_id"]]).first else { done += 1;try ctx.store.set("compare:progress",["done":done,"total":chosen.count]);continue }
                let items=try await client.rows("product.pricelist.item","search_read",["domain":[["pricelist_id","=",id]],"fields":fields,"context":["active_test":false]])
                var variants:[String:[Double]]=[:]
                // Preserve store ordering for template expansion and rule tie breaks.
                for entry in try ctx.store.list("product:") { if let l=entry.value as? Row,M.truth(l["tmplId"]) { variants[M.string(l["tmplId"]),default:[]].append(M.number(String(entry.key.dropFirst(8)))) } }
                let mapped=M.mapRules(items,variants:variants,known:Set(sampleable.map { M.string($0["ref"]) })),sample=M.pickSample(mapped["rules"] as! [Row],products:sampleable,parents:parents)
                var checks:[Check]=[]
                for item in sample { if let product=sampleable.first(where: { M.string($0["ref"]) == M.string(item["ref"]) }) { for quantity in item["quantities"] as! [Double] { checks.append(.init(product:product,quantity:quantity)) } } }
                let failed=try await pool(checks,onResult: { mismatches.append($0) }) { check -> Row? in
                    let p=check.product,q=check.quantity,odoo=try await client.price(pricelistID:id,currencyID:M.id(list["currency_id"]) ?? 0,productID:M.number(p["ref"]),quantity:q)
                    let cross = !M.strictEqual(p["currency"] ?? NSNull(),M.label(list["currency_id"]) ?? NSNull()),crm:Row
                    do { crm=try ctx.data.price(["priceListId":link["priceListId"] ?? NSNull(),"productId":p["id"] ?? NSNull(),"quantity":M.string(q)]) }
                    catch { let text=NativeOdooError.message(error);return ["list":link["name"] ?? NSNull(),"product":p["name"] ?? NSNull(),"quantity":q,"crm":"","odoo":M.string(odoo),"diff":"","reason":text.range(of:"exchange rate",options:.caseInsensitive) != nil ? "rate":"rule","error":text] }
                    let diff=M.number(crm["price"])-odoo;if abs(diff)<0.005 { return nil }
                    let converted = !M.truth(crm["ruleId"]) || ["LIST_PRICE","COST"].contains(M.string(crm["ruleBase"]))
                    return ["list":link["name"] ?? NSNull(),"product":p["name"] ?? NSNull(),"quantity":q,"crm":crm["price"] ?? NSNull(),"odoo":M.string(odoo),"diff":M.fixed(diff,digits:2),"reason":converted && cross ? "rate":"rule"]
                }
                listResults.append(["odooId":id,"name":link["name"] ?? NSNull(),"checked":checks.count,"failed":failed]);done += 1;try ctx.store.set("compare:progress",["done":done,"total":chosen.count])
            }
        } catch { result["ok"]=false;result["error"]=NativeOdooError.message(error);ctx.log("error","Compare with Odoo failed: "+NativeOdooError.message(error)) }
        try ctx.store.delete("meta:lock");result["lists"]=listResults;result["mismatches"]=mismatches;try ctx.store.set("compare:last",result)
    }
    /// At most four remote read-only checks are in flight. Results are consumed
    /// in completion order; no mutable result array is shared between tasks.
    static func pool(_ checks:[Check],onResult:(Row)->Void,body:@escaping (Check) async throws -> Row?) async throws -> Int {
        try await withThrowingTaskGroup(of:Row?.self) { group in
            var index=0,failed=0
            for _ in 0..<min(4,checks.count) { let item=checks[index];index += 1;group.addTask { try await body(item) } }
            while let value=try await group.next() { if let value { failed += 1;onResult(value) };if index<checks.count { let item=checks[index];index += 1;group.addTask { try await body(item) } } };return failed
        }
    }
}
