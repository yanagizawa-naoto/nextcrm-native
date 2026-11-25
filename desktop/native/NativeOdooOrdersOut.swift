import Foundation

enum NativeOdooOrdersOut {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    static func remember(_ ctx:NativePluginContext,now:Date,kind:String,id:Double,name:String,number:String)throws {
        let old=try ctx.store.get("meta:created") as? [Row] ?? []
        try ctx.store.set("meta:created",Array(([["at":NativePluginJSON.stamp(now),"kind":kind,"odooId":id,"name":name,"orderNumber":number]]+old).prefix(20)))
    }
    static func priceList(_ ctx:NativePluginContext,_ client:NativeOdooClient,order:Row,partnerID:Double) async throws -> (id:Double,currency:Double) {
        var id:Double?=nil
        if M.truth(order["priceListId"]) { for entry in try ctx.store.list("pricelist:") where M.strictEqual((entry.value as? Row)?["priceListId"] ?? NSNull(),order["priceListId"]!) { id=M.number(String(entry.key.dropFirst(10))) } }
        if id == nil || id == 0 { id=M.id(try await client.rows("res.partner","read",["ids":[partnerID],"fields":["property_product_pricelist"]]).first?["property_product_pricelist"]) }
        guard let id,id != 0 else { throw NativeOdooError.final(ctx.t("orders.noPriceList")) }
        let list=try await client.rows("product.pricelist","read",["ids":[id],"fields":["currency_id"]]).first,code=M.label(list?["currency_id"]) ?? ""
        guard M.strictEqual(code,order["currency"] ?? NSNull()) else { throw NativeOdooError.final(ctx.t("orders.currency",["order":M.string(order["currency"]),"list":code])) }
        return (id,M.id(list?["currency_id"]) ?? 0)
    }
    static func sameLines(_ client:NativeOdooClient,saleID:Double,want:[Row]) async throws -> Bool {
        let rows=try await client.rows("sale.order.line","search_read",["domain":[["order_id","=",saleID],["display_type","=",false]],"fields":["product_id","product_uom_qty","price_unit"]])
        func key(_ p:Double,_ q:Double,_ u:Double)->String { M.string(p)+"|"+M.fixed(q,digits:4)+"|"+M.fixed(u,digits:2) }
        let have=rows.map { key(M.id($0["product_id"]) ?? 0,M.number($0["product_uom_qty"]),M.number($0["price_unit"])) }.sorted()
        let want=want.map { key(M.number($0["product_id"]),M.number($0["product_uom_qty"]),M.number($0["price_unit"])) }.sorted()
        return have.joined(separator:",") == want.joined(separator:",")
    }
    static func send(_ ctx:NativePluginContext,_ client:NativeOdooClient,order:Row,now:Date) async throws {
        let id=M.string(order["id"]),number=M.string(order["number"]),lines=order["lines"] as? [Row] ?? []
        guard let account=try ctx.data.get("accounts",M.string(order["accountId"])),M.truth(account["name"]) else { throw NativeOdooError.final(ctx.t("orders.noAccount")) }
        var odooLines:[Row]=[]
        for line in lines {
            let product=try ctx.data.get("products",M.string(line["productId"])),ref=M.string(product?["source"]) == "EXTERNAL" ? M.number(product?["externalRef"]):.nan
            guard ref.isFinite,ref != 0,try ctx.store.get(S.key("product",ref)) != nil else { throw NativeOdooError.final(ctx.t("orders.notOdooProduct",["product":M.string(M.coalesce(line["sku"],line["productName"] ?? NSNull()))])) }
            odooLines.append(["product_id":ref,"product_uom_qty":M.number(line["quantity"]),"price_unit":M.number(line["unitPrice"])])
        }
        let user=try await NativeOdooPartners.salesperson(ctx,client,ownerID:order["ownerId"] as? String)
        let customer=try await NativeOdooPartners.customer(ctx,client,account:account,user:user,now:now),partner=M.number(customer["partnerId"])
        if M.truth(customer["created"]) { try remember(ctx,now:now,kind:"customer",id:partner,name:M.string(account["name"]),number:number) }
        let seller:Any
        if M.truth(user) { seller=user }
        else { seller=M.id(try await client.rows("res.partner","read",["ids":[partner],"fields":["user_id"]]).first?["user_id"]) as Any? ?? false }
        let shipping=try await NativeOdooPartners.delivery(ctx,client,partnerID:partner,order:order)
        if M.truth(shipping["created"]) { try remember(ctx,now:now,kind:"delivery",id:M.number(shipping["shippingId"]),name:M.string(account["name"]),number:number) }
        let list=try await priceList(ctx,client,order:order,partnerID:partner)
        var sale=try await client.rows("sale.order","search_read",["domain":[["origin","=",number],["state","!=","cancel"]],"fields":["id","name"],"limit":1]).first
        if let existing=sale {
            guard try await sameLines(client,saleID:M.number(existing["id"]),want:odooLines) else { throw NativeOdooError.final(ctx.t("orders.otherLines",["name":existing["name"] ?? NSNull()])) }
        } else {
            let owner=try (order["ownerId"] as? String).flatMap { try ctx.data.get("users",$0) }
            let note=[owner?["name"],order["note"]].filter(M.truth).map(M.string).joined(separator:"\n")
            let day:Any
            if M.truth(order["requestedDeliveryDate"]) { day=String(NativePluginJSON.stamp(try NativePluginJSON.date(M.string(order["requestedDeliveryDate"]))).prefix(10))+" 00:00:00" } else { day=false }
            let values:Row=["partner_id":partner,"partner_shipping_id":shipping["shippingId"] ?? NSNull(),"pricelist_id":list.id,"origin":number,"user_id":seller,"commitment_date":day,"note":note.isEmpty ? false : note as Any,"order_line":odooLines.map { [0,0,$0] as [Any] }]
            guard let saleID=try await client.ids("sale.order","create",["vals_list":[values]],once:true).first else { throw NativePluginError(message:"Odoo returned no order identifier") }
            let row=try await client.rows("sale.order","read",["ids":[saleID],"fields":["name"]]).first
            sale=["id":saleID,"name":row?["name"] ?? M.string(saleID)]
        }
        let saleID=M.number(sale?["id"]),saleName=sale?["name"] ?? M.string(saleID),stamp=NativePluginJSON.stamp(now)
        _=try ctx.data.updateOrder(id,["status":"SENT","externalRef":M.string(saleID)])
        let link:Row=["odooId":saleID,"name":saleName,"state":"draft","sentAt":stamp,"total":NSNull(),"totalDiffers":false,"priceDiffs":[Row](),"deliveries":[Row](),"invoices":[Row](),"created":(M.truth(customer["created"]) ? ["customer"]:[])+(M.truth(shipping["created"]) ? ["delivery"]:[]),"checkedAt":stamp]
        // Commit both indexes before the optional remote price check can suspend.
        try ctx.store.set(S.key("order",id),link);try ctx.store.set(S.key("odooOrder",saleID),["orderId":id]);try ctx.store.delete(S.key("send",id))
        var diffs:[Row]=[]
        for (i,line) in odooLines.enumerated() {
            do { let price=try await client.price(pricelistID:list.id,currencyID:list.currency,productID:M.number(line["product_id"]),quantity:M.number(line["product_uom_qty"]))
                if abs(price-M.number(line["price_unit"]))>1 { diffs.append(["sku":M.string(M.coalesce(lines[i]["sku"],lines[i]["productName"] ?? NSNull())),"crm":line["price_unit"]!,"odoo":price]) }
            } catch { ctx.log("warn","Price check failed: "+NativeOdooError.message(error)) }
        }
        if !diffs.isEmpty { var current=try S.stored(ctx,S.key("order",id)) ?? link;current["priceDiffs"]=diffs;try ctx.store.set(S.key("order",id),current) }
        ctx.log("info","Order \(number) sent to Odoo as \(M.string(saleName))",["orderId":id,"odooId":saleID])
    }
    static func failed(_ ctx:NativePluginContext,order:Row,error:Error,now:Date) async throws -> String {
        let id=M.string(order["id"]),number=M.string(order["number"]),reason=NativeOdooError.message(error),kind=(error as? NativeOdooError)?.final == true ? "final":NativeOdooError.kind(error),stamp=NativePluginJSON.stamp(now)
        var previous=try S.stored(ctx,S.key("send",id)) ?? ["attempts":0,"lastError":NSNull(),"waitingSince":NSNull()]
        if kind == "unreachable" || kind == "denied" {
            let since=M.coalesce(previous["waitingSince"],stamp),wait=(try? NativePluginJSON.date(M.string(since))).map { now.timeIntervalSince($0) } ?? .nan
            let stuck=kind == "unreachable" && !M.truth(previous["stuckNotified"]) && wait>86400
            previous["lastError"]=reason;previous["waitingSince"]=since;if stuck { previous["stuckNotified"]=true }
            try ctx.store.set(S.key("send",id),previous);ctx.log("warn","Order \(number) waits for Odoo: \(reason)",["orderId":id])
            if stuck { await S.tell(ctx,.init(roles:["admin"],subject:ctx.t("mail.stuckSubject",["number":number]),text:ctx.t("mail.stuckText",["number":number,"since":try S.localTime(ctx,M.string(since)),"error":reason]))) }
            if kind == "denied",try ctx.store.get("meta:sendPaused") == nil { try ctx.store.set("meta:sendPaused",["at":stamp,"reason":reason]);await S.tell(ctx,.init(roles:["admin"],subject:ctx.t("mail.pausedSubject"),text:ctx.t("mail.pausedText",["error":reason]))) }
            return kind
        }
        let attempts=kind == "final" ? 5:M.number(previous["attempts"])+1
        if attempts<5 { previous["attempts"]=attempts;previous["lastError"]=reason;try ctx.store.set(S.key("send",id),previous);ctx.log("warn","Order \(number): Odoo refused attempt \(M.string(attempts)) of 5: \(reason)",["orderId":id]);return "refused" }
        do { _=try ctx.data.updateOrder(id,["status":"SYNC_FAILED"]) } catch { ctx.log("warn","Order \(number): "+NativeOdooError.jsString(error)) }
        try ctx.store.set(S.key("failed",id),["reason":reason,"at":stamp]);try ctx.store.delete(S.key("send",id));ctx.log("error","Order \(number) could not be sent: \(reason)",["orderId":id])
        await S.tell(ctx,.init(roles:["admin"],subject:ctx.t("mail.orderFailedSubject",["number":number]),text:ctx.t("mail.orderFailedText",["number":number,"error":reason])))
        return kind == "final" ? "final":"refused"
    }
    static func sendable(_ order:Row?)->Bool { order?["status"] as? String == "READY" && !M.truth(order?["externalRef"]) }
    static func sendOrder(_ ctx:NativePluginContext,_ client:NativeOdooClient,orderID:String,now:Date) async throws -> String {
        guard M.truth(ctx.settings["sendOrders"]),try ctx.store.get("meta:sendPaused") == nil else { return "skipped" }
        guard try sendable(ctx.data.get("orders",orderID)) else { return "skipped" }
        if M.truth(ctx.settings["dryRun"]) { let order=try ctx.data.get("orders",orderID);ctx.log("info","Dry run: would send order",["orderId":orderID,"number":order?["number"] ?? NSNull()]);return "skipped" }
        let key=S.key("sending",orderID);guard try ctx.store.claim(key,ms:30*60_000) else { return "skipped" }
        return try await S.cleanup(ctx,key:key) {
            guard let order=try ctx.data.get("orders",orderID),sendable(order) else { return "skipped" }
            try ctx.store.delete(S.key("failed",orderID))
            let result:String
            do { try await send(ctx,client,order:order,now:now);result="sent" }
            catch is CancellationError { throw CancellationError() }
            catch { result=try await failed(ctx,order:order,error:error,now:now) }
            return result
        }
    }
    static func sweep(_ ctx:NativePluginContext,_ client:NativeOdooClient,now:Date) async throws -> Int {
        guard M.truth(ctx.settings["sendOrders"]),!M.truth(ctx.settings["dryRun"]) else { return 0 }
        let rows=try ctx.data.find("orders",["where":["status":"READY","externalRef":NSNull()],"orderBy":["createdAt":"asc"],"take":200])
        let waiting=Set(try ctx.store.list("send:").map { String($0.key.dropFirst(5)) }),queue=rows.filter { !waiting.contains(M.string($0["id"])) }+rows.filter { waiting.contains(M.string($0["id"])) }
        var tried=0
        for row in queue { tried += 1;let result=try await sendOrder(ctx,client,orderID:M.string(row["id"]),now:now);if ["unreachable","denied"].contains(result) { break } };return tried
    }
    static func onUpdated(_ input:NativePluginAfterInput,_ ctx:NativePluginContext) async throws {
        if let order=try ctx.data.get("orders",input.recordId) {
            if M.string(order["status"]) != "READY" { try ctx.store.delete(S.key("send",input.recordId)) }
            if M.string(order["status"]) != "SYNC_FAILED" { try ctx.store.delete(S.key("failed",input.recordId)) }
        }
        _=try await sendOrder(ctx,.json(ctx),orderID:input.recordId,now:ctx.clock())
    }
}
