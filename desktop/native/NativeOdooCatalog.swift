import Foundation

enum NativeOdooCatalog {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    static func odooTime(_ date:Date)->String { String(NativePluginJSON.stamp(date).prefix(19)).replacingOccurrences(of:"T",with:" ") }
    static func fromOdoo(_ time:String)throws->Date { try NativePluginJSON.date(time.replacingOccurrences(of:" ",with:"T")+"Z") }
    static func sameProduct(_ row:Row?,fields:Row,link:Row)->Bool {
        guard let row else { return false }
        for key in ["name","type","status","currency"] where !M.strictEqual(row[key] ?? NSNull(),fields[key] ?? NSNull()) { return false }
        for key in ["sku","description","unit"] where !M.strictEqual(M.coalesce(row[key],NSNull()),fields[key] ?? NSNull()) { return false }
        for key in ["unit_price","unit_cost","tax_rate"] {
            let a=row[key],b=fields[key]
            if a == nil || a is NSNull || b == nil || b is NSNull { if !(a == nil || a is NSNull) || !(b == nil || b is NSNull) { return false } }
            else if M.number(a) != M.number(b) { return false }
        };return M.strictEqual(link["categoryRef"] ?? NSNull(),fields["categoryRef"] ?? NSNull())
    }
    static func unique(_ ids:[Double])->[Double] { var seen=Set<Double>();return ids.filter { seen.insert($0).inserted } }
    static func sync(_ ctx:NativePluginContext,_ client:NativeOdooClient,dry:Bool,now:Date) async throws -> Row {
        var counts:Row=["categories":0,"productsCreated":0,"productsUpdated":0,"productsFailed":0,"listsReplaced":0,"listsMissing":[Double](),"accountLists":0]
        func increment(_ key:String) { counts[key]=(counts[key] as? Int ?? 0)+1 }
        let cursor=try S.stored(ctx,"meta:catalogCursor")?["at"] as? String,since=try cursor.map { odooTime(try fromOdoo($0).addingTimeInterval(-120)) }
        var top=cursor
        func seen(_ value:Any?) { guard let value=value as? String else { return };if top == nil || value>top! { top=value } }
        let cats=M.categoryOrder(try await client.rows("product.category","search_read",["domain":[Any](),"fields":["id","name","parent_id"]]))
        for cat in cats {
            increment("categories");if dry { continue };let parent=M.id(cat["parent_id"]).map { M.string($0) } as Any? ?? NSNull()
            let result=try ctx.data.upsertExternalCategory(M.string(cat["id"]),["name":cat["name"] ?? NSNull(),"parentRef":parent]);try ctx.store.set(S.key("category",cat["id"] ?? NSNull()),["categoryId":result["id"] ?? NSNull(),"parentRef":parent])
        }
        let fields=try await client.availableFields("product.product",M.variantFieldNames),retry=try ctx.store.list("retryProduct:").map { M.number(String($0.key.dropFirst(13))) }
        let domain:[Any]=since.map { ["|","|",["write_date",">",$0],["product_tmpl_id.write_date",">",$0],["id","in",retry]] } ?? [["sale_ok","in",[true,false]]]
        var taxes:[Double:Any]=[:],offset=0
        while true {
            let rows=try await client.rows("product.product","search_read",["domain":domain,"fields":fields,"limit":200,"offset":offset,"order":"id asc","context":["active_test":false]])
            let missing=unique(rows.flatMap { $0["taxes_id"] as? [Double] ?? [] }).filter { taxes[$0] == nil }
            if !missing.isEmpty { for tax in try await client.rows("account.tax","read",["ids":missing,"fields":["amount","amount_type"]]) { taxes[M.number(tax["id"])]=M.string(tax["amount_type"]) == "percent" ? M.string(tax["amount"]) : NSNull() } }
            for row in rows {
                seen(row["write_date"]);let id=M.number(row["id"]),known=try S.stored(ctx,S.key("product",id))
                if known == nil && !(M.truth(row["sale_ok"]) && M.truth(row["active"])) { continue }
                let mapped=M.variantFields(row) { $0.count == 1 ? taxes[$0[0]] as? String:nil }
                if let known,try ctx.store.get(S.key("retryProduct",id)) == nil,try sameProduct(ctx.data.get("products",M.string(known["productId"])),fields:mapped,link:known) { continue }
                if dry { increment(known == nil ? "productsCreated":"productsUpdated");ctx.log("info","Dry run: would \(known == nil ? "create":"update") product",mapped.merging(["odooId":id]) { _,v in v });continue }
                do {
                    let result=try ctx.data.upsertExternalProduct(M.string(id),mapped,["adoptBySku":true])
                    if M.truth(result["adopted"]) { ctx.log("info","Took over CRM product \(M.string(mapped["sku"])) (\(M.string(mapped["name"])))",["odooId":id,"productId":result["id"] ?? NSNull()]) }
                    increment(M.truth(result["created"]) ? "productsCreated":"productsUpdated")
                    try ctx.store.set(S.key("product",id),["productId":result["id"] ?? NSNull(),"tmplId":M.id(row["product_tmpl_id"]) as Any? ?? NSNull(),"categoryRef":mapped["categoryRef"] ?? NSNull()]);try ctx.store.delete(S.key("retryProduct",id))
                } catch { increment("productsFailed");ctx.log("error","Product \(M.string(id)) failed: "+NativeOdooError.message(error),["odooId":id]);try ctx.store.set(S.key("retryProduct",id),Row()) }
            }
            if rows.count<200 { break };offset += 200
        }
        let productsChanged=(counts["productsCreated"] as! Int)+(counts["productsUpdated"] as! Int)>0,chosen=M.chosenLists(M.string(ctx.settings["priceLists"]))
        var lists:[Double:Row]=[:],items:[Double:[Row]]=[:],frontier=unique(chosen+(try ctx.store.list("pricelist:")).map { M.number(String($0.key.dropFirst(10))) })
        while !frontier.isEmpty {
            let rows=try await client.rows("product.pricelist","search_read",["domain":[["id","in",frontier]],"fields":["id","name","currency_id","active","write_date"],"context":["active_test":false]])
            for id in frontier where !rows.contains(where: { M.number($0["id"]) == id }) && chosen.contains(id) { var missing=counts["listsMissing"] as! [Double];missing.append(id);counts["listsMissing"]=missing;ctx.log("warn","Odoo price list \(M.string(id)) not found") }
            let ruleFields=try await client.availableFields("product.pricelist.item",M.ruleFields)
            let found=rows.isEmpty ? [] : try await client.rows("product.pricelist.item","search_read",["domain":[["pricelist_id","in",rows.map { $0["id"] ?? NSNull() }]],"fields":ruleFields+["pricelist_id"],"context":["active_test":false]])
            for row in rows { let id=M.number(row["id"]);lists[id]=row;items[id]=found.filter { M.id($0["pricelist_id"]) == id } }
            frontier=unique(rows.flatMap { M.baseRefs(items[M.number($0["id"])] ?? []) }).filter { lists[$0] == nil }
        }
        let deps=lists.mapValues { row in M.baseRefs(items[M.number(row["id"])] ?? []).filter { lists[$0] != nil } },ordered=M.orderLists(deps,maxChain:11)
        for id in ordered["cyclic"] as! [Double] { ctx.log("warn","Price list \(M.string(id)) skipped: its base lists form a cycle") }
        for id in ordered["tooDeep"] as! [Double] { ctx.log("warn","Price list \(M.string(id)) skipped: it builds on more than 10 other lists") }
        let known=Set(try ctx.data.externalProducts().map { M.string($0["ref"]) });var variants:[String:[Double]]=[:]
        for entry in try ctx.store.list("product:") { if let link=entry.value as? Row,M.truth(link["tmplId"]) { variants[M.string(link["tmplId"]),default:[]].append(M.number(String(entry.key.dropFirst(8)))) } }
        var listIDs:[Double:String]=[:],firstImport=false
        for id in ordered["order"] as! [Double] {
            let list=lists[id]!,its=items[id]!,previous=try S.stored(ctx,S.key("pricelist",id)),active=chosen.contains(id) && M.truth(list["active"])
            let changed=previous == nil || cursor == nil || M.string(list["write_date"])>(cursor ?? "") || its.contains { M.string($0["write_date"])>(cursor ?? "") } || M.number(previous?["ruleCount"]) != Double(its.count) || productsChanged || NativePluginJSON.boolean(previous?["isActive"]) != active
            if let missing=M.baseRefs(its).first(where: { lists[$0] == nil || (listIDs[$0] == nil && !dry) }) { ctx.log("warn","Price list \(M.string(id)) skipped: base list \(M.string(missing)) is not available");continue }
            for item in its { seen(item["write_date"]) };seen(list["write_date"])
            let mapped=M.mapRules(its,variants:variants,known:known),rules=mapped["rules"] as! [Row],skipped=mapped["skipped"] as! [Row]
            if !dry { try ctx.store.set(S.key("skipped",id),skipped) }
            if let previous,!changed { listIDs[id]=M.string(previous["priceListId"]);continue }
            if previous == nil { firstImport=true };increment("listsReplaced")
            if dry { ctx.log("info","Dry run: would replace price list",["odooId":id,"name":list["name"] ?? NSNull(),"rules":rules.count,"skipped":skipped.count]);continue }
            let result=try ctx.data.replaceExternalPriceList(M.string(id),["name":list["name"] ?? NSNull(),"currency":M.label(list["currency_id"]) ?? "","isActive":active],rules),listID=M.string(result["id"])
            listIDs[id]=listID;try ctx.store.set(S.key("pricelist",id),["priceListId":listID,"name":list["name"] ?? NSNull(),"ruleCount":its.count,"syncedAt":NativePluginJSON.stamp(now),"isActive":active])
        }
        var accounts=try ctx.store.list("account:").map { (key:$0.key,link:$0.value as? Row ?? [:]) }
        let stale=accounts.indices.filter { firstImport || accounts[$0].link["odooPriceList"] == nil }
        for offset in stride(from:0,to:stale.count,by:200) {
            let chunk=Array(stale[offset..<min(offset+200,stale.count)]),rows=try await client.rows("res.partner","read",["ids":chunk.map { accounts[$0].link["partnerId"] ?? NSNull() },"fields":["property_product_pricelist"]])
            for index in chunk { let value=rows.first { M.number($0["id"]) == M.number(accounts[index].link["partnerId"]) }?["property_product_pricelist"];accounts[index].link["odooPriceList"]=M.or(value,NSNull());if !dry { try ctx.store.set(accounts[index].key,accounts[index].link) } }
        }
        for account in accounts {
            guard let odoo=M.id(account.link["odooPriceList"]),odoo != 0,chosen.contains(odoo),let listID=listIDs[odoo] else { continue }
            let id=String(account.key.dropFirst(8));guard let row=try ctx.data.get("accounts",id),row["pricelist_id"] as? String != listID else { continue };increment("accountLists")
            if !dry { _=try ctx.data.update(.account,id,["pricelist_id":listID]) }
        }
        if !dry,let top,!top.isEmpty { try ctx.store.set("meta:catalogCursor",["at":top]) };return counts
    }
}
