import Foundation

/// Storage-only projections consumed by native plugin slots; these never call ERP.
extension NativeOXOConnector {
    func needsOwner() throws -> [Row] {
        var result:[Row]=[]
        for entry in try entries("account:") { let id=String(entry.key.dropFirst(8));if let account=try ctx.data.get("accounts",id),(account["deletedAt"] == nil || account["deletedAt"] is NSNull),!M.truth(account["assigned_to"]) { result.append(["accountId":id,"name":M.string(M.coalesce(account["name"],id))]) } };return result
    }
    func panelData(_ id:String) throws -> Any {
        guard let link=try stored(key("account",id)) else { return M.null }
        let list=try !(M.coalesce(link["priceListId"],M.null) is NSNull) ? stored(key("pricelist",link["priceListId"])):nil
        let addresses=(link["addresses"] as? [Row] ?? []).map{a -> Row in let locality=[a["zip"],a["city"]].filter(M.truth).map(M.string).joined(separator:" ");let text=[a["name"],a["street"],locality].filter(M.truth).map(M.string).joined(separator:", ");return ["id":a["id"] ?? M.null,"text":text]}
        let price:Any=link["priceListId"] == nil || link["priceListId"] is NSNull ? M.null:["id":link["priceListId"]!,"name":list?["name"] ?? M.null,"imported":M.truth(list?["isActive"])]
        return ["customerId":link["customerId"] ?? M.null,"syncedAt":link["syncedAt"] ?? M.null,"inactive":M.truth(link["inactive"]),"priceList":price,"addresses":addresses] as Row
    }
    func productPanelData(_ id:String) throws -> Any { guard let link=try stored(key("product",id)) else { return M.null };return ["oxoId":link["oxoId"] ?? M.null,"ref":link["ref"] ?? M.null] }
    func orderPanelData(_ id:String) throws -> Any {
        var link=try stored(key("order",id));let status=try ctx.data.get("orders",id)?["status"] as? String
        let waiting=try status == "READY" ? stored(key("send",id)):nil,failed=try status == "SYNC_FAILED" ? stored(key("failed",id)):nil
        if link == nil && waiting == nil && failed == nil { return M.null }
        if let value=link?["oxoId"] { link?["url"]=M.string(ctx.settings["url"]).replacingOccurrences(of:"/+$",with:"",options:.regularExpression)+"/prodej/"+M.string(value) }
        return ["link":link as Any? ?? M.null,"waiting":waiting as Any? ?? M.null,"failed":failed as Any? ?? M.null]
    }
    func accountTabData(_ id:String) throws -> Any {
        guard let link=try stored(key("account",id)) else { return M.null };var rows:[Row]=[]
        for order in try findAll("orders",where:["accountId":id],orderBy:["orderDate":"desc"]) {
            guard let related=try stored(key("order",order["id"])) else { continue }
            rows.append(["orderId":order["id"] ?? M.null,"number":M.string(order["number"]),"oxoNumber":related["number"] ?? M.null,"date":String(M.string(order["orderDate"]).prefix(10)),"total":M.number(order["subtotal"]),"currency":M.string(order["currency"]),"status":M.string(order["status"]),"delivery":related["delivery"] ?? M.null,"imported":M.truth(related["imported"])])
            if rows.count==50 { break }
        };return ["customerId":link["customerId"] ?? M.null,"orders":rows]
    }
    func catalogData() throws -> Row {
        let chosen=Set(M.chosenLists(M.string(ctx.settings["priceLists"]))),loaded=try stored("meta:oxoLists");var skipped:[Row]=[]
        for entry in try ctx.store.list("skipped:") {
            let id=String(entry.key.dropFirst(8)),link=try stored(key("pricelist",M.number(id)))
            for var rule in entry.value as? [Row] ?? [] { rule["list"]=link?["name"] ?? id;skipped.append(rule) }
        }
        let lists:Any=loaded.map{($0["lists"] as? [Row] ?? []).map{row -> Row in var result=row;result["chosen"]=chosen.contains(M.number(row["id"]));return result}} as Any? ?? M.null
        return ["lists":lists,"loadedAt":loaded?["at"] ?? M.null,"skipped":skipped,"queued":try M.truth(ctx.store.get("job:sync"))]
    }
    func ordersData(_ now:Date) throws -> Row {
        let waiting=try M.truth(ctx.settings["sendOrders"]) ? findAll("orders",where:["status":"READY","externalRef":M.null]).count:0
        let sent=try entries("order:").filter{!M.truth($0.value["imported"]) && ((try? NativePluginJSON.date(M.string($0.value["sentAt"]))) ?? .distantPast)>=now.addingTimeInterval(-604800)}.count
        var failed:[Row]=[]
        for e in try entries("failed:") { let id=String(e.key.dropFirst(7)),order=try ctx.data.get("orders",id);var row:Row=["orderId":id,"number":M.string(M.coalesce(order?["number"],id))];row.merge(e.value){_,new in new};failed.append(row) }
        return ["enabled":ctx.settings["sendOrders"] ?? false,"waiting":waiting,"sent":sent,"failed":failed,"paused":try ctx.store.get("meta:sendPaused") ?? M.null,"pending":try ctx.store.list("pending:").count]
    }
}
