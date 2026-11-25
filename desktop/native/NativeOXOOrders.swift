import Foundation

extension NativeOXOConnector {
    func syncOrdersIn(dry:Bool,now:Date) async throws -> Row {
        var (top,params)=try since("orders");let fresh=try await client.all("/orders",params),waiting=try entries("pending:").map{$0.value["order"] as? Row ?? [:]},products=try productMap()
        var imported=0,updated=0,pending=0,seen=Set<Double>()
        for (i,order) in (fresh+waiting).enumerated() {
            try Task.checkCancellation();if (i+1)%100==0 { try keepLock() }
            if i<fresh.count,let at=order["updatedAt"] as? String,top == nil || at>top! { top=at }
            let id=M.number(order["id"]);guard seen.insert(id).inserted else { continue }
            do {
                if M.truth(order["crmNumber"]) { continue }
                let ref=M.ref(order),existing=try ctx.data.find("orders",["where":["externalRef":ref],"take":1]).first
                if existing?["source"] as? String == "CRM" { if !dry { try ctx.store.delete(key("pending",id)) };continue }
                guard let accountID=try stored(key("customer",order["customerId"]))?["accountId"] as? String,!accountID.isEmpty else { pending+=1;if !dry { try ctx.store.set(key("pending",id),["order":order]) };continue }
                let previous=try existing.map{try stored(key("order",$0["id"]))} ?? nil
                if let previous,NativePluginJSON.equal(previous["updatedAt"],order["updatedAt"]) { if !dry { try ctx.store.delete(key("pending",id)) };continue }
                let mapped=M.crmLines(products,order)
                if dry { if existing != nil { updated+=1 } else { imported+=1 };continue }
                let note=[M.string(M.coalesce(order["note"],"")),mapped.missing>0 ? ctx.t("orders.linesMissing",["count":mapped.missing]):""].filter{!$0.isEmpty}.joined(separator:"\n")
                var input:Row=["lines":mapped.lines,"note":note.isEmpty ? M.null:note as Any,"orderDate":String(M.string(order["orderedAt"]).prefix(10))]
                let orderID:String
                if let existing { orderID=M.string(existing["id"]);_ = try ctx.data.updateOrder(orderID,input);updated+=1 }
                else { input["accountId"]=accountID;input["externalRef"]=ref;input["status"]=M.targetStatus(order) ?? "CONFIRMED";input["currency"]=order["currency"];orderID=M.string(try ctx.data.createOrder(input)["id"]);imported+=1 }
                var link=M.linkFrom(order,previous:previous ?? [:],now:now);link["imported"]=true;link["updatedAt"]=order["updatedAt"];link["missing"]=mapped.missing
                try ctx.store.set(key("order",orderID),link);try ctx.store.delete(key("pending",id))
            } catch { try cancelled(error);pending+=1;ctx.log("warn","OXO ERP order \(M.string(order["number"])) not imported: "+message(error),["oxoId":id]);if !dry { try ctx.store.set(key("pending",id),["order":order]) } }
        }
        return ["imported":imported,"updated":updated,"pending":pending,"top":top as Any? ?? M.null]
    }
    func syncOrderStatuses(dry:Bool,now:Date) async throws -> Row {
        let open=try findAll("orders",where:["status":["in":["SENT","CONFIRMED","DELIVERED","INVOICED"]]]).filter{($0["externalRef"] as? String)?.range(of:"^(oxo:)?[0-9]+$",options:.regularExpression) != nil}
        if open.isEmpty { return ["checked":0,"moved":0] }
        var found:[String:Row]=[:]
        for (parameter,isOXO) in [("ids",true),("odooIds",false)] {
            let values=open.filter{M.string($0["externalRef"]).hasPrefix("oxo:")==isOXO}.map{M.number(M.string($0["externalRef"]).replacingOccurrences(of:"oxo:",with:""))}
            for offset in stride(from:0,to:values.count,by:200) {
                let response=try await client.get("/orders",[(parameter,values[offset..<min(offset+200,values.count)].map(M.string).joined(separator:","))]) as? Row ?? [:]
                for order in response["items"] as? [Row] ?? [] { if isOXO { found["oxo:"+M.string(order["id"])]=order } else if !(M.coalesce(order["odooId"],M.null) is NSNull) { found[M.string(order["odooId"])]=order } }
            }
        }
        let rank=["SENT":1,"CONFIRMED":2,"DELIVERED":3,"INVOICED":4,"PAID":5];var moved=0
        for order in open {
            try Task.checkCancellation();let id=M.string(order["id"]),number=M.string(order["number"]),previous=try stored(key("order",id))
            guard let remote=found[M.string(order["externalRef"])] else {
                if dry { continue }
                if !M.truth(previous?["missingNotified"]) { ctx.log("warn","OXO ERP order for \(number) was not found; the CRM keeps \(M.string(order["status"]))",["orderId":id]);await tell(ctx.t("mail.missingSubject",["number":number]),ctx.t("mail.missingText",["number":number])) }
                var link=previous ?? ["oxoId":0,"number":"","state":"","delivery":"none","deliveries":[],"belowList":[],"sentAt":stamp(now),"checkedAt":stamp(now)]
                link["state"]="missing";link["missingNotified"]=true;link["checkedAt"]=stamp(now);try ctx.store.set(key("order",id),link);continue
            }
            let target=M.targetStatus(remote),current=M.string(order["status"]),forward=target != nil && target != current && (target == "CANCELLED" || (rank[target!] ?? 0)>(rank[current] ?? 0))
            if dry { if forward { ctx.log("info","Dry run: would set order status",["orderId":id,"from":current,"to":target!]) };continue }
            if forward { do { _ = try ctx.data.updateOrder(id,["status":target!]);moved+=1 } catch { try cancelled(error);ctx.log("warn","Order \(number): "+message(error),["orderId":id]) } }
            try ctx.store.set(key("order",id),M.linkFrom(remote,previous:previous ?? [:],now:now))
        }
        return ["checked":open.count,"moved":moved]
    }
    static func byPosition(_ order:Row) -> [Row] { (order["lines"] as? [Row] ?? []).enumerated().sorted{let a=M.number(M.coalesce($0.element["position"],0)),b=M.number(M.coalesce($1.element["position"],0));return a == b ? $0.offset<$1.offset:a<b}.map(\.element) }
    /// Swift strings cannot contain isolated surrogate code units. The source's
    /// UTF-16 limits are retained; a split pair is replaced at that invalid edge.
    static func slice(_ text:String,_ limit:Int) -> String { String(decoding:Array(text.utf16.prefix(limit)),as:UTF16.self) }
    func orderBody(_ order:Row) throws -> Row {
        guard let account=try ctx.data.get("accounts",M.string(order["accountId"])),M.truth(account["name"]) else { throw NativeOXOFinalError(message:ctx.t("orders.noAccount")) }
        let link=try stored(key("account",account["id"]));var lines:[Row]=[]
        for line in Self.byPosition(order) {
            guard let product=try stored(key("product",line["productId"])) else { throw NativeOXOFinalError(message:ctx.t("orders.notOxoProduct",["product":M.string(M.coalesce(line["sku"],M.coalesce(line["productName"],line["productId"] ?? M.null)))])) }
            lines.append(["productId":product["oxoId"] ?? M.null,"quantity":M.decimal(line["quantity"]),"unitPrice":M.decimal(line["unitPrice"])])
        }
        var result:Row=["crmNumber":M.string(order["number"]),"currency":M.string(order["currency"]),"lines":lines]
        if let link { result["customerId"]=link["customerId"] }
        else {
            var customer:Row=["name":Self.slice(M.string(account["name"]),200)]
            for (output,input) in [("ico","company_id"),("dic","vat"),("street","billing_street"),("city","billing_city"),("zip","billing_postal_code"),("email","email"),("phone","office_phone")] { customer[output]=M.clean(account[input]) }
            customer["country"]=try M.countryName(M.clean(account["billing_country"]));result["customer"]=customer
        }
        var ship:Row=[:];for (out,field) in [("street","shipping_street"),("city","shipping_city"),("zip","shipping_postal_code")] { ship[out]=M.clean(order[field]) }
        if M.truth(ship["street"]) || M.truth(ship["city"]) {
            if let found=(link?["addresses"] as? [Row] ?? []).first(where:{M.sameAddress($0,ship)}) { result["deliveryAddressId"]=found["id"] }
            else { ship["name"]=Self.slice(M.string(account["name"]),200);ship["country"]=try M.countryName(M.clean(order["shipping_country"]));result["deliveryAddress"]=ship }
        }
        if M.truth(order["priceListId"]) { for entry in try entries("pricelist:") where NativePluginJSON.equal(entry.value["priceListId"],order["priceListId"]) { result["priceListId"]=M.number(String(entry.key.dropFirst(10))) } }
        let owner=try M.truth(order["ownerId"]) ? ctx.data.get("users",M.string(order["ownerId"])):nil
        if M.truth(order["requestedDeliveryDate"]) { result["requestedDate"]=String(stamp(try NativePluginJSON.date(M.string(order["requestedDeliveryDate"]))).prefix(10)) }
        result["note"]=M.clean(order["note"]).map{Self.slice($0,2000)};result["salesRep"]=M.clean(owner?["name"]).map{Self.slice($0,100)};return result
    }
    func linkCustomer(_ accountID:String,_ remote:Row,body:Row,now:Date) throws {
        // Source aliases prev and link, so existing-link address mutations never
        // satisfy its identity inequality and are not persisted by the real store.
        if try stored(key("account",accountID)) != nil { return }
        var link:Row=["customerId":remote["customerId"] ?? M.null,"syncedAt":stamp(now),"priceListId":remote["priceListId"] ?? M.null,"addresses":[Row]()]
        if let sent=body["deliveryAddress"] as? Row,!(M.coalesce(remote["deliveryAddressId"],M.null) is NSNull) {
            var address:Row=["id":remote["deliveryAddressId"]!,"odooId":M.null,"active":true];for k in ["name","street","city","zip","country"] { address[k]=sent[k] ?? M.null };link["addresses"]=[address]
        }
        if try !M.truth(ctx.store.get(key("customer",remote["customerId"]))) { try ctx.store.set(key("customer",remote["customerId"]),["accountId":accountID]) }
        try ctx.store.set(key("account",accountID),link)
    }
    func send(_ order:Row,now:Date) async throws {
        let id=M.string(order["id"]),body=try orderBody(order),answer=try await client.post("/orders",body),remote=answer.body as? Row ?? [:]
        try Task.checkCancellation();_ = try ctx.data.updateOrder(id,["status":"SENT","externalRef":"oxo:"+M.string(remote["id"])])
        let lines=Self.byPosition(order);var below:[String]=[]
        for (i,line) in (remote["lines"] as? [Row] ?? []).enumerated() where M.truth(line["belowList"]) { let own=i<lines.count ? lines[i]:[:];below.append(M.string(M.coalesce(own["sku"],M.coalesce(own["productName"],line["productId"] ?? M.null)))) }
        var stored:Row=["oxoId":remote["id"] ?? M.null,"belowList":below,"sentAt":stamp(now),"checkedAt":stamp(now)];for k in ["number","state","delivery","deliveries"] { stored[k]=remote[k] }
        try ctx.store.set(key("order",id),stored);try linkCustomer(M.string(order["accountId"]),remote,body:body,now:now);try ctx.store.delete(key("send",id))
        ctx.log("info","Order \(M.string(order["number"])) sent to OXO ERP as \(M.string(remote["number"]))",["orderId":id,"oxoId":remote["id"] ?? M.null])
    }
    static func failureKind(_ error:Error) -> String {
        if error is NativeOXOFinalError { return "failed" }
        if let error=error as? NativeOXOError { if error.isAuthentication || error.code == "writes_disabled" { return "paused" };if error.status==0 || error.status==429 || error.status>=500 { return "waiting" } }
        return "failed"
    }
    func failed(_ order:Row,error:Error,now:Date) async throws -> String {
        try cancelled(error);let id=M.string(order["id"]),number=M.string(order["number"]),reason=message(error),kind=Self.failureKind(error)
        if kind != "failed" {
            let previous=try stored(key("send",id)),since=previous?["waitingSince"] as? String ?? stamp(now)
            let elapsed=(try? NativePluginJSON.date(since)).map{now.timeIntervalSince($0)} ?? .nan
            let stuck=kind == "waiting" && !M.truth(previous?["stuckNotified"]) && elapsed>86400
            var state:Row=["lastError":reason,"waitingSince":since];if stuck || M.truth(previous?["stuckNotified"]) { state["stuckNotified"]=true };try ctx.store.set(key("send",id),state)
            ctx.log("warn","Order \(number) waits for OXO ERP: \(reason)",["orderId":id])
            if stuck { await tell(ctx.t("mail.stuckSubject",["number":number]),ctx.t("mail.stuckText",["number":number,"since":try M.localTime(since,zone:M.string(ctx.settings["timeZone"])),"error":reason])) }
            if kind == "paused",try !M.truth(ctx.store.get("meta:sendPaused")) { try ctx.store.set("meta:sendPaused",["at":stamp(now),"reason":reason]);await tell(ctx.t("mail.pausedSubject"),ctx.t("mail.pausedText",["error":reason])) };return kind
        }
        do { _ = try ctx.data.updateOrder(id,["status":"SYNC_FAILED"]) } catch { try cancelled(error);ctx.log("warn","Order \(number): "+message(error)) }
        try ctx.store.set(key("failed",id),["reason":reason,"at":stamp(now)]);try ctx.store.delete(key("send",id));ctx.log("error","Order \(number) could not be sent: \(reason)",["orderId":id])
        await tell(ctx.t("mail.orderFailedSubject",["number":number]),ctx.t("mail.orderFailedText",["number":number,"error":reason]));return "failed"
    }
    static func sendable(_ order:Row?) -> Bool { order?["status"] as? String == "READY" && !M.truth(order?["externalRef"]) }
    func sendOrder(_ id:String,now:Date) async throws -> String {
        if try !M.truth(ctx.settings["sendOrders"]) || M.truth(ctx.settings["dryRun"]) || M.truth(ctx.store.get("meta:sendPaused")) { return "skipped" }
        if !Self.sendable(try ctx.data.get("orders",id)) { return "skipped" }
        guard try ctx.store.claim(key("sending",id),ms:600000) else { return "skipped" }
        do {
            let result:String
            if let order=try ctx.data.get("orders",id),Self.sendable(order) { try ctx.store.delete(key("failed",id));do { try await send(order,now:now);result="sent" } catch { result=try await failed(order,error:error,now:now) } }
            else { result="skipped" }
            try ctx.store.delete(key("sending",id));return result
        } catch { try ctx.store.delete(key("sending",id));throw error }
    }
    func sweepOrders(_ now:Date) async throws -> Int {
        if !M.truth(ctx.settings["sendOrders"]) || M.truth(ctx.settings["dryRun"]) { return 0 }
        let rows=try findAll("orders",where:["status":"READY","externalRef":M.null],orderBy:["createdAt":"asc"]),waiting=Set(try entries("send:").map{String($0.key.dropFirst(5))})
        let queue=rows.filter{!waiting.contains(M.string($0["id"]))}+rows.filter{waiting.contains(M.string($0["id"]))};var tried=0
        for row in queue { if try M.truth(ctx.store.get("meta:sendPaused")) { break };tried+=1;let result=try await sendOrder(M.string(row["id"]),now:now);if ["waiting","paused"].contains(result) { break } };return tried
    }
    func onOrderUpdated(_ input:NativePluginAfterInput) async throws {
        let id=input.recordId
        if let order=try ctx.data.get("orders",id) { if order["status"] as? String != "READY" { try ctx.store.delete(key("send",id)) };if order["status"] as? String != "SYNC_FAILED" { try ctx.store.delete(key("failed",id)) } }
        _ = try await sendOrder(id,now:ctx.clock())
    }
}
