import Foundation

enum NativeOdooOrdersStatus {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    typealias Incoming = NativeOdooOrdersIn
    static let saleFields=["id","name","state","delivery_status","invoice_status","amount_total","invoice_ids","picking_ids","partner_id","write_date","note"]
    static let moveFields=["id","name","move_type","state","payment_state","invoice_date","invoice_date_due","amount_total","amount_residual"]
    static let rank=["SENT":1,"CONFIRMED":2,"DELIVERED":3,"INVOICED":4,"PAID":5]
    static let finals:Set<String>=["PAID","CANCELLED"]
    struct Open { let id:String,link:Row,order:Row;var final=false }
    static func linesOwed(_ link:Row)->Bool { M.truth(link["imported"]) && (link["missing"] == nil || M.number(link["missing"])>0) }
    static func sync(_ ctx:NativePluginContext,_ client:NativeOdooClient,dry:Bool,now:Date) async throws -> Row {
        var open:[Open]=[],checked=0,moved=0
        for entry in try ctx.store.list("order:") {
            guard var link=entry.value as? Row else { continue };if M.truth(link["done"]) && !linesOwed(link) { continue }
            let id=String(entry.key.dropFirst(6));guard let order=try ctx.data.get("orders",id) else { continue }
            if finals.contains(M.string(order["status"])) {
                if linesOwed(link) { link["done"]=true;open.append(.init(id:id,link:link,order:order,final:true)) }
                else if !dry && !M.truth(link["done"]) { link["done"]=true;try ctx.store.set(S.key("order",id),link) };continue
            };open.append(.init(id:id,link:link,order:order))
        }
        if open.isEmpty { return ["checked":0,"moved":0] }
        let fields=try await client.availableFields("sale.order",saleFields),sales=try await client.rows("sale.order","search_read",["domain":[["id","in",open.map { $0.link["odooId"] ?? NSNull() }]],"fields":fields])
        var byID:[Double:Row]=[:];for s in sales { byID[M.number(s["id"])]=s }
        let moveIDs=sales.flatMap { $0["invoice_ids"] as? [Double] ?? [] },pickIDs=sales.flatMap { $0["picking_ids"] as? [Double] ?? [] }
        let moves=moveIDs.isEmpty ? [] : try await client.rows("account.move","search_read",["domain":[["id","in",moveIDs]],"fields":moveFields])
        let picks=pickIDs.isEmpty ? [] : try await client.rows("stock.picking","search_read",["domain":[["id","in",pickIDs],["picking_type_code","=","outgoing"]],"fields":["id","name","state","date_done"]])
        let imported=open.filter { M.truth($0.link["imported"]) && byID[M.number($0.link["odooId"])] != nil }
        let commercial=try await Incoming.commercial(client,partnerIDs:imported.compactMap { M.id(byID[M.number($0.link["odooId"])]?["partner_id"]) })
        let changed=imported.filter { !M.strictEqual(byID[M.number($0.link["odooId"])]?["write_date"] ?? NSNull(),$0.link["writeDate"] ?? NSNull()) || $0.link["missing"] == nil || M.number($0.link["missing"])>0 }.map { M.number($0.link["odooId"]) }
        let lines=dry ? [] : try await Incoming.readLines(client,orderIDs:changed)
        if !lines.isEmpty { try await Incoming.ensureProducts(ctx,client,lines:lines) }
        for entry in open {
            checked += 1;let number=M.string(entry.order["number"]),id=M.number(entry.link["odooId"]),stamp=NativePluginJSON.stamp(now)
            guard let sale=byID[id] else {
                if dry { continue }
                if !M.truth(entry.link["missingNotified"]) {
                    ctx.log("warn","Odoo order \(M.string(entry.link["name"])) was not found; the CRM keeps \(M.string(entry.order["status"]))",["orderId":entry.id])
                    await S.tell(ctx,.init(roles:["admin"],subject:ctx.t("mail.missingSubject",["number":number]),text:ctx.t("mail.missingText",["number":number,"name":entry.link["name"] ?? NSNull()])))
                }
                var link=entry.link;link["state"]="missing";link["missingNotified"]=true;link["checkedAt"]=stamp;try ctx.store.set(S.key("order",entry.id),link);continue
            }
            let mine=moves.filter { (sale["invoice_ids"] as? [Double] ?? []).contains(M.number($0["id"])) },target=M.targetStatus(sale,moves:mine),current=M.string(entry.order["status"])
            let forward=target != current && (target == "CANCELLED" || (rank[target] ?? 0)>(rank[current] ?? 0)),back = !forward && target != current ? target:nil
            if let back,back != entry.link["back"] as? String { ctx.log("info","Odoo order \(M.string(entry.link["name"])) went back to \(M.string(sale["state"])); the CRM keeps \(current)",["orderId":entry.id]) }
            var link=entry.link;link["state"]=sale["state"];link["total"]=sale["amount_total"];link["totalDiffers"]=abs(M.number(sale["amount_total"])-M.number(entry.order["grandTotal"]))>1
            link["deliveries"]=picks.filter { (sale["picking_ids"] as? [Double] ?? []).contains(M.number($0["id"])) }.map { ["name":$0["name"] ?? NSNull(),"state":$0["state"] ?? NSNull(),"date":M.or($0["date_done"],NSNull())] }
            link["invoices"]=M.invoiceRows(mine);link["checkedAt"]=stamp;link["back"]=back;link.removeValue(forKey:"missingNotified")
            if M.truth(entry.link["imported"]) && !dry {
                if changed.contains(id) {
                    let mapped=try Incoming.crmLines(ctx,lines.filter { M.id($0["order_id"]) == id })
                    let write = !M.strictEqual(sale["write_date"] ?? NSNull(),entry.link["writeDate"] ?? NSNull()) || entry.link["missing"] == nil || Double(mapped.missing)<M.number(M.coalesce(entry.link["missing"],0))
                    do { if write { _=try ctx.data.updateOrder(entry.id,["lines":mapped.lines,"note":Incoming.note(ctx,sale["note"],missing:mapped.missing)]) };link["writeDate"]=sale["write_date"];link["missing"]=mapped.missing }
                    catch { ctx.log("warn","Order \(number): lines not updated: "+NativeOdooError.message(error),["orderId":entry.id]) }
                }
                if let partner=M.id(sale["partner_id"]),(commercial[partner] ?? partner) != M.number(entry.link["partnerId"]),!M.truth(entry.link["movedNotified"]) {
                    ctx.log("warn","Odoo order \(M.string(entry.link["name"])) now belongs to another customer; the CRM order keeps its account",["orderId":entry.id])
                    await S.tell(ctx,.init(roles:["admin"],subject:ctx.t("mail.movedSubject",["number":number]),text:ctx.t("mail.movedText",["number":number,"name":entry.link["name"] ?? NSNull()])));link["movedNotified"]=true
                }
            }
            if entry.final { if !dry { try ctx.store.set(S.key("order",entry.id),link) };continue }
            if dry { if forward { ctx.log("info","Dry run: would set order status",["orderId":entry.id,"from":current,"to":target]) };continue }
            if forward { do { _=try ctx.data.updateOrder(entry.id,["status":target]);moved += 1;if finals.contains(target) { link["done"]=true } } catch { ctx.log("warn","Order \(number): "+NativeOdooError.message(error),["orderId":entry.id]) } }
            try ctx.store.set(S.key("order",entry.id),link)
        };return ["checked":checked,"moved":moved]
    }
}
