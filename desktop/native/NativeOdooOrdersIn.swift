import Foundation

enum NativeOdooOrdersIn {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    static let inputFields=["id","name","state","partner_id","origin","date_order","currency_id","note","write_date","amount_total","amount_untaxed","delivery_status","invoice_status","invoice_ids","picking_ids"]
    static let lineFields=["order_id","product_id","product_uom_qty","price_unit","discount","display_type","is_downpayment"]
    static func linked(_ ctx:NativePluginContext)throws->[(Double,String)] {
        try ctx.store.list("partner:").map { (M.number(String($0.key.dropFirst(8))),M.string(($0.value as? Row)?["accountId"])) }
    }
    static func confirmed(_ client:NativeOdooClient,partnerIDs:[Double]) async throws -> [Row] {
        if partnerIDs.isEmpty { return [] };let fields=try await client.availableFields("sale.order",inputFields)
        return try await client.rows("sale.order","search_read",["domain":[["state","in",["sale","done"]],["partner_id.commercial_partner_id","in",partnerIDs]],"fields":fields,"order":"id asc"]).map { var row=$0;row["invoice_ids"]=M.coalesce(row["invoice_ids"],[Double]());row["picking_ids"]=M.coalesce(row["picking_ids"],[Double]());return row }
    }
    static func commercial(_ client:NativeOdooClient,partnerIDs:[Double]) async throws -> [Double:Double] {
        var seen=Set<Double>();let ids=partnerIDs.filter { seen.insert($0).inserted };if ids.isEmpty { return [:] }
        var result:[Double:Double]=[:]
        for row in try await client.rows("res.partner","read",["ids":ids,"fields":["commercial_partner_id"]]) { let id=M.number(row["id"]);result[id]=M.id(row["commercial_partner_id"]) ?? id };return result
    }
    static func readLines(_ client:NativeOdooClient,orderIDs:[Double]) async throws -> [Row] {
        if orderIDs.isEmpty { return [] };let fields=try await client.availableFields("sale.order.line",lineFields)
        return try await client.rows("sale.order.line","search_read",["domain":[["order_id","in",orderIDs]],"fields":fields,"order":"id asc"])
    }
    static func crmLines(_ ctx:NativePluginContext,_ lines:[Row])throws->(lines:[Row],missing:Int) {
        var out:[Row]=[],missing=0
        for line in lines {
            guard !M.truth(line["display_type"]),!M.truth(line["is_downpayment"]),let product=M.id(line["product_id"]) else { continue }
            guard let link=try S.stored(ctx,S.key("product",product)) else { missing += 1;continue }
            out.append(["productId":link["productId"] ?? NSNull(),"quantity":line["product_uom_qty"] ?? NSNull(),"unitPrice":M.number(line["price_unit"])*(1-M.number(M.or(line["discount"],0))/100)])
        };return (out,missing)
    }
    static func ensureProducts(_ ctx:NativePluginContext,_ client:NativeOdooClient,lines:[Row]) async throws {
        var ids:[Double]=[],seen=Set<Double>()
        for line in lines {
            guard !M.truth(line["display_type"]),!M.truth(line["is_downpayment"]),let id=M.id(line["product_id"]),seen.insert(id).inserted else { continue }
            if try ctx.store.get(S.key("product",id)) == nil { ids.append(id) }
        }
        if ids.isEmpty { return };let fields=try await client.availableFields("product.product",M.variantFieldNames),variants=try await client.rows("product.product","read",["ids":ids,"fields":fields])
        var taxIDs:[Double]=[],seenTax=Set<Double>()
        for v in variants { for id in v["taxes_id"] as? [Double] ?? [] where seenTax.insert(id).inserted { taxIDs.append(id) } }
        var taxes:[Double:String]=[:]
        if !taxIDs.isEmpty { for row in try await client.rows("account.tax","read",["ids":taxIDs,"fields":["amount","amount_type"]]) where M.string(row["amount_type"]) == "percent" { taxes[M.number(row["id"])]=M.string(row["amount"]) } }
        for variant in variants {
            let f=M.variantFields(variant) { $0.count == 1 ? taxes[$0[0]]:nil },id=M.number(variant["id"])
            do {
                let result=try ctx.data.upsertExternalProduct(M.string(id),f,["adoptBySku":true])
                if M.truth(result["adopted"]) { ctx.log("info","Took over CRM product \(M.string(f["sku"])) (\(M.string(f["name"])))",["odooId":id,"productId":result["id"] ?? NSNull()]) }
                try ctx.store.set(S.key("product",id),["productId":result["id"] ?? NSNull(),"tmplId":M.id(variant["product_tmpl_id"]) as Any? ?? NSNull(),"categoryRef":f["categoryRef"] ?? NSNull()])
            } catch { ctx.log("warn","Product \(M.string(variant["display_name"])) from an imported order not created: "+NativeOdooError.message(error),["odooId":id]) }
        }
    }
    static func note(_ ctx:NativePluginContext,_ html:Any?,missing:Int)->Any { M.note(html,missing:missing,translate: { ctx.t($0,$1) }) }
    static func indexLinks(_ ctx:NativePluginContext,now:Date)throws {
        if try ctx.store.get("meta:indexed") != nil { return }
        for entry in try ctx.store.list("order:") {
            guard let link=entry.value as? Row,M.truth(link["odooId"]),try ctx.store.get(S.key("odooOrder",link["odooId"]!)) == nil else { continue }
            try ctx.store.set(S.key("odooOrder",link["odooId"]!),["orderId":String(entry.key.dropFirst(6))])
        };try ctx.store.set("meta:indexed",["at":NativePluginJSON.stamp(now)])
    }
    static func importOrders(_ ctx:NativePluginContext,_ client:NativeOdooClient,dry:Bool,now:Date,orders:[Row],commercial:[Double:Double],linked:[Double:String]) async throws -> Int {
        if !dry { try indexLinks(ctx,now:now) }
        var known=Set(try ctx.store.list("odooOrder:").map { M.number(String($0.key.dropFirst(10))) });known.formUnion(try ctx.store.list("order:").map { M.number(($0.value as? Row)?["odooId"]) })
        let failed=Set(try ctx.store.list("importFailed:").map { M.number(String($0.key.dropFirst(13))) }),fresh=orders.filter { !known.contains(M.number($0["id"])) },batch=Array((fresh.filter { !failed.contains(M.number($0["id"])) }+fresh.filter { failed.contains(M.number($0["id"])) }).prefix(200))
        if batch.isEmpty { return 0 }
        let lines=try await readLines(client,orderIDs:batch.map { M.number($0["id"]) });if !dry { try await ensureProducts(ctx,client,lines:lines) }
        let moveIDs=batch.flatMap { $0["invoice_ids"] as? [Double] ?? [] }
        let moves=moveIDs.isEmpty ? [] : try await client.rows("account.move","search_read",["domain":[["id","in",moveIDs]],"fields":NativeOdooOrdersStatus.moveFields])
        var imported=0
        for sale in batch {
            let id=M.number(sale["id"])
            do {
                if M.truth(sale["origin"]),let mine=try ctx.data.find("orders",["where":["number":sale["origin"]!,"source":"CRM"],"take":1]).first {
                    if !dry { try ctx.store.set(S.key("odooOrder",id),["orderId":mine["id"] ?? NSNull()]) };continue
                }
                guard let partner=M.id(sale["partner_id"]),let account=linked[commercial[partner] ?? partner] else { continue };let partnerID=commercial[partner] ?? partner
                let mapped=try crmLines(ctx,lines.filter { M.id($0["order_id"]) == id }),mine=moves.filter { (sale["invoice_ids"] as? [Double] ?? []).contains(M.number($0["id"])) },status=M.targetStatus(sale,moves:mine)
                if dry { ctx.log("info","Dry run: would import Odoo order "+M.string(sale["name"]),["accountId":account,"lines":mapped.lines.count,"status":status]);continue }
                var fields:Row=["accountId":account,"externalRef":M.string(id),"status":status,"orderDate":String(M.string(sale["date_order"]).prefix(10)),"note":note(ctx,sale["note"],missing:mapped.missing),"lines":mapped.lines]
                if let currency=M.label(sale["currency_id"]) { fields["currency"]=currency }
                let row=try ctx.data.find("orders",["where":["source":"EXTERNAL","externalRef":M.string(id)],"take":1]).first ?? ctx.data.createOrder(fields),orderID=M.string(row["id"]),stamp=NativePluginJSON.stamp(now)
                var link:Row=["odooId":id,"name":sale["name"] ?? NSNull(),"state":sale["state"] ?? NSNull(),"sentAt":stamp,"total":sale["amount_total"] ?? NSNull(),"totalDiffers":row["grandTotal"] != nil && abs(M.number(sale["amount_total"])-M.number(row["grandTotal"]))>1,
                              "priceDiffs":[Row](),"deliveries":[Row](),"invoices":M.invoiceRows(mine),"created":[String](),"checkedAt":stamp,"imported":true,"partnerId":partnerID,"writeDate":sale["write_date"] ?? NSNull(),"missing":mapped.missing]
                if ["PAID","CANCELLED"].contains(status) { link["done"]=true }
                try ctx.store.set(S.key("order",orderID),link);try ctx.store.set(S.key("odooOrder",id),["orderId":orderID]);try ctx.store.delete(S.key("importFailed",id));imported += 1
            } catch {
                if (error as? NativeOdooError)?.authentication == true { throw error }
                let reason=NativeOdooError.message(error);ctx.log("warn","Odoo order \(M.string(sale["name"])) not imported: \(reason)",["odooId":id])
                if !dry { try ctx.store.set(S.key("importFailed",id),["name":sale["name"] ?? NSNull(),"reason":reason,"at":NativePluginJSON.stamp(now)]) }
            }
        };return imported
    }
    static func sync(_ ctx:NativePluginContext,_ client:NativeOdooClient,dry:Bool,now:Date) async throws -> Int {
        let links=try linked(ctx);if links.isEmpty { return 0 }
        let orders=try await confirmed(client,partnerIDs:links.map(\.0)),owners=try await commercial(client,partnerIDs:orders.compactMap { M.id($0["partner_id"]) })
        let count=try await importOrders(ctx,client,dry:dry,now:now,orders:orders,commercial:owners,linked:Dictionary(uniqueKeysWithValues:links))
        try await NativeOdooCustomerInfo.sync(ctx,client,dry:dry,now:now,linked:links,orders:orders,commercial:owners)
        if !dry { try ctx.store.set("meta:imported",["lastRun":count]) };return count
    }
}
