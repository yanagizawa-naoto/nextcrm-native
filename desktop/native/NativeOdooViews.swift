import Foundation

/// Data for native Japanese plugin slots. Rendering and record access checks
/// belong to the host; these functions never contact the remote Odoo service.
enum NativeOdooViews {
    typealias Row = NativePluginRecord
    typealias M = NativeOdooMap
    typealias S = NativeOdooSupport
    static func base(_ ctx:NativePluginContext)->String { M.replace(M.string(ctx.settings["url"]),#"/+$"#,"") }
    static func needsOwner(_ ctx:NativePluginContext)throws->[Row] {
        var out:[Row]=[]
        for entry in try ctx.store.list("account:") { let id=String(entry.key.dropFirst(8));guard let account=try ctx.data.get("accounts",id),(account["deletedAt"] == nil || account["deletedAt"] is NSNull),!M.truth(account["assigned_to"]) else { continue }
            out.append(["accountId":id,"name":M.string(M.coalesce(account["name"],id)),"salesperson":M.coalesce((entry.value as? Row)?["salesperson"],NSNull())])
        };return out
    }
    static func accountPanel(_ ctx:NativePluginContext,id:String)throws->Row? {
        guard let link=try S.stored(ctx,S.key("account",id)) else { return nil };var priceList:Any=NSNull()
        if let list=M.id(link["odooPriceList"]) { priceList=["name":M.label(link["odooPriceList"]) ?? NSNull(),"imported":M.truth(try S.stored(ctx,S.key("pricelist",list))?["isActive"])] }
        return ["partnerId":link["partnerId"] ?? NSNull(),"url":base(ctx)+"/odoo/contacts/"+M.string(link["partnerId"]),"syncedAt":link["syncedAt"] ?? NSNull(),"archived":M.truth(link["archived"]),"notCustomer":M.truth(link["notCustomer"]),"priceList":priceList]
    }
    static func catalog(_ ctx:NativePluginContext)throws->Row {
        let chosen=Set(M.chosenLists(M.string(ctx.settings["priceLists"]))),loaded=try S.stored(ctx,"meta:odooLists");var skipped:[Row]=[]
        for entry in try ctx.store.list("skipped:") { let id=String(entry.key.dropFirst(8)),link=try S.stored(ctx,S.key("pricelist",M.number(id)))
            for item in entry.value as? [Row] ?? [] { skipped.append(["list":link?["name"] ?? id].merging(item) { _,v in v }) }
        }
        let lists=(loaded?["lists"] as? [Row]).map { $0.map { row in row.merging(["chosen":chosen.contains(M.number(row["id"]))]) { _,v in v } } }
        return ["lists":lists as Any? ?? NSNull(),"loadedAt":loaded?["at"] ?? NSNull(),"skipped":skipped,"compare":try ctx.store.get("compare:last") ?? NSNull(),"progress":try ctx.store.get("compare:progress") ?? NSNull(),"queued":["sync":try ctx.store.get("job:sync") != nil,"compare":try ctx.store.get("job:compare") != nil]]
    }
    static func productPanel(_ ctx:NativePluginContext,id:String)throws->Row? {
        guard let product=try ctx.data.get("products",id),M.string(product["source"]) == "EXTERNAL" else { return nil };let odoo=M.number(product["externalRef"])
        guard try ctx.store.get(S.key("product",odoo)) != nil else { return nil };let last=try S.stored(ctx,"meta:lastRun")
        return ["odooId":odoo,"url":base(ctx)+"/web#model=product.product&id="+M.string(odoo)+"&view_type=form","syncedAt":M.truth(last?["ok"]) ? last?["at"] ?? NSNull() : NSNull()]
    }
    static func orderPanel(_ ctx:NativePluginContext,id:String)throws->Row? {
        var link=try S.stored(ctx,S.key("order",id));let status=try ctx.data.get("orders",id)?["status"] as? String
        let waiting=status == "READY" ? try ctx.store.get(S.key("send",id)):nil,failed=status == "SYNC_FAILED" ? try ctx.store.get(S.key("failed",id)):nil
        if link == nil && waiting == nil && failed == nil { return nil }
        if let current=link { link?["url"]=base(ctx)+"/odoo/action-sale.action_orders/"+M.string(current["odooId"]) }
        return ["link":link as Any? ?? NSNull(),"waiting":waiting ?? NSNull(),"failed":failed ?? NSNull()]
    }
    static func orders(_ ctx:NativePluginContext,now:Date)throws->Row {
        let enabled=M.truth(ctx.settings["sendOrders"]),waiting=enabled ? try ctx.data.find("orders",["where":["status":"READY","externalRef":NSNull()],"take":500]).count:0,links=try ctx.store.list("order:")
        let sent=links.filter { entry in guard let link=entry.value as? Row,!M.truth(link["imported"]),let at=try? NativePluginJSON.date(M.string(link["sentAt"])) else { return false };return at>=now.addingTimeInterval(-7*86400) }.count
        var failed:[Row]=[]
        for entry in try ctx.store.list("failed:") { let id=String(entry.key.dropFirst(7)),order=try ctx.data.get("orders",id);failed.append(["orderId":id,"number":M.string(M.coalesce(order?["number"],id))].merging(entry.value as? Row ?? [:]) { _,v in v }) }
        let importFailed=try ctx.store.list("importFailed:").map { ["odooId":M.number(String($0.key.dropFirst(13)))].merging($0.value as? Row ?? [:]) { _,v in v } }
        return ["enabled":enabled,"waiting":waiting,"sent":sent,"failed":failed,"paused":try ctx.store.get("meta:sendPaused") ?? NSNull(),"created":try ctx.store.get("meta:created") ?? [Row](),"imported":["total":links.filter { M.truth(($0.value as? Row)?["imported"]) }.count,"lastRun":try S.stored(ctx,"meta:imported")?["lastRun"] ?? 0,"failed":importFailed]]
    }
    static func accountTab(_ ctx:NativePluginContext,id:String,now:Date)throws->Row? {
        guard let link=try S.stored(ctx,S.key("account",id)) else { return nil };let info=try S.stored(ctx,S.key("customer",id));var orders:[Row]=[]
        for order in try ctx.data.find("orders",["where":["accountId":id],"orderBy":["orderDate":"desc"],"take":500]) {
            let orderID=M.string(order["id"]);guard let l=try S.stored(ctx,S.key("order",orderID)) else { continue }
            orders.append(["orderId":orderID,"number":M.string(order["number"]),"odooName":l["name"] ?? NSNull(),"date":String(M.string(order["orderDate"]).prefix(10)),"total":M.number(order["subtotal"]),"currency":M.string(order["currency"]),"status":M.string(order["status"]),"imported":M.truth(l["imported"])])
            if orders.count == 50 { break }
        }
        let today=try M.localParts(now,zone:M.string(ctx.settings["timeZone"])).day
        var invoices:[Row]=[],owed:[String:Double]=[:],currencyOrder:[String]=[]
        for invoice in info?["invoices"] as? [Row] ?? [] {
            let sign=M.string(invoice["type"]) == "out_refund" ? -1.0:1.0;var value=invoice,overdue=0.0
            if let due=invoice["due"] as? String,!due.isEmpty,due<today,let a=try? NativePluginJSON.date(today),let b=try? NativePluginJSON.date(due) { overdue=(a.timeIntervalSince(b)/86400).rounded() }
            value["sign"]=sign;value["overdueDays"]=overdue;invoices.append(value)
            let currency=M.string(invoice["currency"]);if owed[currency] == nil { currencyOrder.append(currency) };owed[currency]=NativeOdooCustomerInfo.round2((owed[currency] ?? 0)+sign*M.number(invoice["residual"]))
        }
        return ["partnerId":link["partnerId"] ?? NSNull(),"url":base(ctx)+"/odoo/contacts/"+M.string(link["partnerId"]),"at":info?["at"] ?? NSNull(),"orders":orders,"invoices":invoices,"owed":currencyOrder.map { ["currency":$0,"amount":owed[$0]!] },"totals":info?["totals"] ?? [Row]()]
    }
}
