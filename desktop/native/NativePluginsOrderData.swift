import Foundation

extension NativePluginData {
    private func orderDay(_ input:Any) throws -> String {
        let value=NativePluginJSON.string(input)
        guard value.range(of:#"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,options:.regularExpression) != nil,let date=try? NativePluginJSON.date(value),NativePluginJSON.stamp(date).hasPrefix(value+"T") else { throw NativePluginError(message:"Invalid orderDate: "+value) }
        return NativePluginJSON.stamp(date)
    }
    private func externalLines(_ input:Any?) throws -> (lines:[[String:SQLValue]],totals:[String:SQLValue]) {
        guard let input=input as? [NativePluginRecord] else { throw NativePluginError(message:"Invalid order lines") }
        var rows:[[String:SQLValue]]=[],subtotal=Decimal(0),vatTotal=Decimal(0)
        for (index,line) in input.enumerated() {
            let id=NativePluginJSON.string(line["productId"])
            guard let product=try db.get("crm_Products",key:["id":.text(id)]),product["deletedAt"] == .null else { throw NativePluginError(message:"Product not found: "+id) }
            let quantity=try PriceDecimal.parse(NativePluginJSON.string(line["quantity"])),price=PriceDecimal.rounded(try PriceDecimal.parse(NativePluginJSON.string(line["unitPrice"])))
            let vat=try PriceDecimal.parse(product["tax_rate"] == .null ? "0":product["tax_rate"].string)
            let net=PriceDecimal.rounded(try PriceDecimal.calculate(quantity,"*",price)),tax=PriceDecimal.rounded(try PriceDecimal.calculate(PriceDecimal.calculate(net,"*",vat),"/",100))
            let total=PriceDecimal.rounded(try PriceDecimal.calculate(net,"+",tax))
            rows.append(["position":.integer(Int64(index)),"productId":product["id"],"productName":product["name"],"sku":product["sku"],"unit":product["unit"],"quantity":.text(PriceDecimal.string(quantity)),"listPrice":.text(PriceDecimal.string(price)),"priceRuleId":.null,"unitPrice":.text(PriceDecimal.string(price)),"unitPriceOverridden":.integer(0),"vatRate":.text(PriceDecimal.string(vat)),"lineSubtotal":.text(PriceDecimal.string(net)),"lineVat":.text(PriceDecimal.string(tax)),"lineTotal":.text(PriceDecimal.string(total))])
            subtotal=try PriceDecimal.calculate(subtotal,"+",net);vatTotal=try PriceDecimal.calculate(vatTotal,"+",tax)
        }
        return (rows,["subtotal":.text(PriceDecimal.string(PriceDecimal.rounded(subtotal))),"vatTotal":.text(PriceDecimal.string(PriceDecimal.rounded(vatTotal))),"grandTotal":.text(PriceDecimal.string(PriceDecimal.rounded(try PriceDecimal.calculate(subtotal,"+",vatTotal))))])
    }
    private func allocatePluginOrderNumber() throws -> (number:String,series:SQLValue) {
        guard let series=try db.page("NumberSeries",fields:db.schema.model("NumberSeries").fields.map(\.name),equal:["scope":.text("order"),"isDefault":.integer(1),"active":.integer(1)],sort:"createdAt",limit:1).rows.first else { throw NativePluginError(message:"noSeries") }
        let year=OrderNumber.year(clock()),reset=series["resetPolicy"] == .text("YEARLY") && series["currentYear"] != .integer(Int64(year))
        let old=Int64(series["counter"].string) ?? 0
        guard reset || old<Int32.max else { throw NativePluginError(message:"integer out of range") }
        let counter=reset ? 1:old+1;try db.update(series,changes:["counter":.integer(counter),"currentYear":.integer(Int64(year))],actor:"plugin:"+pluginId)
        return (OrderNumber.format(series["template"].string,year:year,counter:counter),series["id"])
    }
    func createOrder(_ input:NativePluginRecord) throws -> NativePluginRecord {
        try need("orders:write")
        let status=NativePluginJSON.string(input["status"])
        guard ["SENT","CONFIRMED","DELIVERED","INVOICED","PAID","CANCELLED"].contains(status) else { throw NativePluginError(message:"Plugins cannot create an order as "+status) }
        let date=try input["orderDate"].map(orderDay),accountId=NativePluginJSON.string(input["accountId"])
        guard let account=try db.get("crm_Accounts",key:["id":.text(accountId)]),account["deletedAt"] == .null else { throw NativePluginError(message:"Account not found: "+accountId) }
        let quoted=try externalLines(input["lines"])
        let defaultCurrency=try db.get("crm_SystemSettings",key:["key":.text("default_currency")])?["value"].string
        let currency=(input["currency"] as? String) ?? ((defaultCurrency ?? "").isEmpty ? "JPY":defaultCurrency!)
        let order=try NativePluginActorScope.withActor(.plugin(pluginId)) { try db.transaction {
            let numbered=try allocatePluginOrderNumber()
            var header:[String:SQLValue]=["number":.text(numbered.number),"seriesId":numbered.series,"source":.text("EXTERNAL"),"externalRef":(input["externalRef"] as? String).map(SQLValue.text) ?? .null,"status":.text(status),"accountId":account["id"],"ownerId":account["assigned_to"],"priceListId":.null,"currency":.text(currency),"note":(input["note"] as? String).map(SQLValue.text) ?? .null]
            if let date { header["orderDate"] = .text(date) };header.merge(quoted.totals) { _,new in new }
            let order=try db.insert("crm_Orders",values:header,actor:"plugin:"+pluginId)
            for var line in quoted.lines { line["orderId"]=order["id"];try db.insert("crm_OrderLines",values:line,actor:"plugin:"+pluginId) }
            return order
        } }
        audit(entity:"order",id:order["id"].string,action:"created",changes:[pluginTag]);emitSaved(.order,id:order["id"].string)
        return try record(order)
    }
    func updateOrder(_ id:String,_ input:NativePluginRecord) throws -> NativePluginRecord {
        try need("orders:write")
        guard let order=try db.get("crm_Orders",key:["id":.text(id)]) else { throw NativePluginError(message:"Order not found: "+id) }
        if (NativePluginJSON.truthy(input["lines"]) || input["orderDate"] != nil) && order["source"] != .text("EXTERNAL") { throw NativePluginError(message:"Plugins may replace lines or set the order date on only EXTERNAL orders") }
        let to=input["status"] as? String,moving=to.map { !$0.isEmpty && $0 != order["status"].string } ?? false
        if moving,!OrderWorkflow.canPluginSet(status:order["status"].string,to:to!) { throw NativePluginError(message:"Plugins cannot set \(to!) on a \(order["status"].string) order") }
        var extra:NativePluginRecord=[:]
        for key in ["externalRef","note"] { extra[key]=input[key] }
        if let date=input["orderDate"] { extra["orderDate"]=try orderDay(date) }
        let quoted=try NativePluginJSON.truthy(input["lines"]) ? externalLines(input["lines"]):nil
        if !moving && extra.isEmpty && quoted == nil { emitSaved(.order,id:id);return try record(order) }
        var patch=try values(extra,model:"crm_Orders");if let quoted { patch.merge(quoted.totals) { _,new in new } }
        if moving { patch["status"] = .text(to!);patch["updatedBy"] = .null }
        try NativePluginActorScope.withActor(.plugin(pluginId)) { try db.transaction {
            guard let latest=try db.get("crm_Orders",key:["id":order["id"]]),!moving || latest["status"] == order["status"] else { throw NativePluginError(message:"changed") }
            try db.update(latest,changes:patch,actor:"plugin:"+pluginId)
            if let quoted {
                while true { let page=try db.page("crm_OrderLines",fields:[],equal:["orderId":order["id"]]);if page.rows.isEmpty { break };for row in page.rows { try db.remove(row,actor:"plugin:"+pluginId) } }
                for var line in quoted.lines { line["orderId"]=order["id"];try db.insert("crm_OrderLines",values:line,actor:"plugin:"+pluginId) }
            }
        } }
        if moving { audit(entity:"order",id:id,action:"updated",changes:[["field":"status","old":order["status"].string,"new":to!,"plugin":pluginId]]) }
        let fields=["externalRef","note","orderDate"].filter { extra[$0] != nil }+(quoted == nil ? []:["lines"])
        if !fields.isEmpty { audit(entity:"order",id:id,action:"updated",changes:fields.map { ["field":$0,"plugin":pluginId] }) }
        emitSaved(.order,id:id)
        // Write permission is sufficient; do not accidentally add orders:read.
        let row=try db.get("crm_Orders",key:["id":order["id"]]) ?? order
        var result=try record(row);result["lines"]=try all("crm_OrderLines",where:["orderId":id]);return result
    }
}
