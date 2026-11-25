import Foundation

extension CRMService {
    static let orderHeaderKeys = ["contactId","shipping_street","shipping_city","shipping_state","shipping_postal_code","shipping_country","requestedDeliveryDate","note"]
    static let orderAddress = ["street","city","state","postal_code","country"]

    func orderCan(_ record: NativeRecord, _ action: String) -> Bool {
        OrderWorkflow.can(status:record["status"].string,source:record["source"].string,creator:record["createdBy"].string,externalRef:record["externalRef"].string,action:action,actorID:identity.id,role:identity.role)
    }
    func orderAccess(_ record: NativeRecord, action: String? = nil) throws -> NativeRecord {
        guard record.model == "crm_Orders" else { throw NativeDBError.message("受注を選択してください。") }
        try assertAccess(record.model,id:record["id"].string)
        guard let current = try db.get(record.model,key:["id":record["id"]]) else { throw NativeDBError.message("受注が見つかりません。") }
        if let action {
            guard current.revision == record.revision else { throw NativeDBError.conflict }
            guard orderCan(current,action) else { throw NativeDBError.message("この受注の状態または利用者では、この操作はできません。") }
        }
        return current
    }
    func orderContext(accountID: String) throws -> OrderPriceContext {
        let listID = try resolvedPriceList(accountID:accountID)
        let list = try listID.flatMap { try db.get("crm_PriceLists",key:["id":.text($0)]) }
        let setting = try db.get("crm_SystemSettings",key:["key":.text("default_currency")])?["value"].string ?? ""
        return OrderPriceContext(listID:list?["id"].string,currency:list?["currency"].string ?? (setting.isEmpty ? "JPY" : setting))
    }
    func orderContext(_ record: NativeRecord) -> OrderPriceContext { OrderPriceContext(listID:record["priceListId"] == .null ? nil : record["priceListId"].string,currency:record["currency"].string) }
    func orderShipping(_ account: NativeRecord) -> [String:SQLValue] {
        let prefix = Self.orderAddress.contains { !account["shipping_"+$0].string.isEmpty } ? "shipping_" : "billing_"
        return Dictionary(uniqueKeysWithValues:Self.orderAddress.map { ("shipping_"+$0,account[prefix+$0]) })
    }
    func orderQuote(_ input: OrderLineInput, context: OrderPriceContext, date: Date = Date()) throws -> OrderLineQuote {
        try authenticated(); guard identity.role != "partner" else { throw NativeDBError.message("受注の価格確認は担当者が行ってください。") }
        return try db.transaction {
            let product = try catalogRecord("crm_Products",.text(input.productID))
            guard product["status"] == .text("ACTIVE") else { throw NativeDBError.message("有効な商品を選択してください。") }
            let quantity = try PriceDecimal.parse(input.quantity)
            guard quantity > 0 else { throw NativeDBError.message("数量は0より大きい数値で入力してください。") }
            try db.validateFieldValues("crm_OrderLines",["quantity":.text(PriceDecimal.string(quantity))])
            let priced = try checkedPrice(productID:input.productID,listID:context.listID,quantity:input.quantity,date:ISO8601DateFormatter().string(from:date))
            var listPrice = try PriceDecimal.parse(priced.price)
            if priced.currency != context.currency {
                var rate: Decimal
                if let direct = try db.page("ExchangeRate",fields:["rate"],equal:["fromCurrency":.text(priced.currency),"toCurrency":.text(context.currency)]).rows.first { rate = try PriceDecimal.parse(direct["rate"].string) }
                else if let inverse = try db.page("ExchangeRate",fields:["rate"],equal:["fromCurrency":.text(context.currency),"toCurrency":.text(priced.currency)]).rows.first {
                    let r = try PriceDecimal.parse(inverse["rate"].string); guard r > 0 else { throw NativeDBError.message("換算レートは0より大きい数値で設定してください。") }; rate = try PriceDecimal.calculate(1,"/",r)
                } else { throw NativeDBError.message("\(priced.currency)から\(context.currency)への換算レートがありません。") }
                guard rate > 0 else { throw NativeDBError.message("換算レートは0より大きい数値で設定してください。") }
                listPrice = try PriceDecimal.calculate(listPrice,"*",rate)
            }
            listPrice = PriceDecimal.rounded(listPrice)
            let override = input.unitPrice.flatMap { $0.isEmpty ? nil : $0 }
            let price = try override.map { PriceDecimal.rounded(try PriceDecimal.parse($0)) } ?? listPrice
            guard price >= 0 else { throw NativeDBError.message("単価は0以上で入力してください。") }
            let q = PriceDecimal.string(quantity); let p = PriceDecimal.string(price); let vat = product["tax_rate"] == .null ? "0" : product["tax_rate"].string
            let amount = try InvoiceMath.line(.init(quantity:q,unitPrice:p,discountPercent:"0",taxRate:vat))
            let result = OrderLineQuote(productId:input.productID,productName:product["name"].string,sku:product["sku"] == .null ? nil : product["sku"].string,unit:product["unit"] == .null ? nil : product["unit"].string,
                                        quantity:q,listPrice:PriceDecimal.string(listPrice),priceRuleId:priced.ruleId,unitPrice:p,unitPriceOverridden:override != nil,vatRate:vat,lineSubtotal:amount.lineSubtotal,lineVat:amount.lineVat,lineTotal:amount.lineTotal)
            try db.validateFieldValues("crm_OrderLines",result.values)
            return result
        }
    }
    func orderHeaders(_ input: [String:SQLValue], accountID: String) throws -> [String:SQLValue] {
        guard input.keys.allSatisfy(Self.orderHeaderKeys.contains) else { throw NativeDBError.message("変更できない受注の項目が含まれています。") }
        var result: [String:SQLValue] = [:]
        for (key,value) in input {
            guard value == .null || { if case .text = value { return true }; return false }() else { throw NativeDBError.message("受注の入力形式が不正です。") }
            let text = value.string.trimmingCharacters(in:.whitespacesAndNewlines)
            result[key] = text.isEmpty ? .null : .text(text)
        }
        if let contact = result["contactId"], contact != .null {
            let row = try catalogRecord("crm_Contacts",contact)
            guard row["accountsIDs"] == .text(accountID) else { throw NativeDBError.message("この取引先に所属する連絡先を選択してください。") }
        }
        if let value = result["requestedDeliveryDate"], value != .null {
            let day = String(value.string.prefix(10)); let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.calendar = Calendar(identifier:.gregorian); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let date = formatter.date(from:day), formatter.string(from:date) == day else { throw NativeDBError.message("納品希望日が正しくありません。") }; result["requestedDeliveryDate"] = .text(day+"T00:00:00Z")
        }
        try db.validateFieldValues("crm_Orders",result); return result
    }
    func orderLines(_ record: NativeRecord, offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        let current = try orderAccess(record)
        return try db.page("crm_OrderLines",fields:db.schema.model("crm_OrderLines").fields.map(\.name),equal:["orderId":current["id"]],offset:offset,sort:"position")
    }
    func makeOrderDraft(_ record: NativeRecord) throws -> OrderDraftStore {
        try db.transaction {
            let order = try orderAccess(record); guard order.revision == record.revision else { throw NativeDBError.conflict }; let result = try OrderDraftStore(); var offset = 0
            while true {
                let page = try orderLines(order,offset:offset)
                for row in page.rows { try autoreleasepool { let quote = OrderLineQuote.from(row); try result.save(input:quote.input,quote:quote) } }
                offset += page.rows.count; if page.rows.isEmpty || offset >= page.total { break }
            }
            return result
        }
    }
    private func allocateOrderNumber(now: Date) throws -> (String,SQLValue) {
        guard let series = try db.page("NumberSeries",fields:db.schema.model("NumberSeries").fields.map(\.name),equal:["scope":.text("order"),"isDefault":.integer(1),"active":.integer(1)],sort:"createdAt").rows.first else { throw NativeDBError.message("有効な受注の採番設定がありません。管理者に確認してください。") }
        let year = OrderNumber.year(now); let reset = series["resetPolicy"] == .text("YEARLY") && series["currentYear"] != .integer(Int64(year))
        guard case let .integer(old) = series["counter"], reset || old < Int32.max else { throw NativeDBError.message("受注番号の上限に達しています。採番設定を変更してください。") }
        let counter = reset ? 1 : old+1; let number = OrderNumber.format(series["template"].string,year:year,counter:counter)
        guard try db.page("crm_Orders",fields:[],equal:["number":.text(number)]).total == 0 else { throw NativeDBError.message("同じ受注番号が存在します。採番の書式を管理者に確認してください。") }
        _ = try db.update(series,changes:["counter":.integer(counter),"currentYear":.integer(Int64(year))],actor:identity.id,action:"allocate")
        return (number,series["id"])
    }
    /// Reprices into a bounded disk buffer before replacing any live lines. The original revision,
    /// number allocation, line snapshots, totals, status, audit and outbox all share one transaction.
    func saveOrder(original: NativeRecord?, accountID: String, header: [String:SQLValue], lines: (Int) throws -> [OrderLineInput], submit: Bool = false, now: Date = Date()) throws -> NativeRecord {
        try authenticated(); guard identity.role != "partner" else { throw NativeDBError.message("パートナー利用者は受注を変更できません。") }
        return try db.transaction {
            let current = try original.map { try orderAccess($0,action:"edit") }
            let oldCount = try current.map { try db.page("crm_OrderLines",fields:[],equal:["orderId":$0["id"]]).total } ?? 0
            if let current { guard current["accountId"] == .text(accountID) else { throw NativeDBError.message("受注の取引先は変更できません。") } }
            else { try assertAccess("crm_Accounts",id:accountID,write:true) }
            guard let account = try db.get("crm_Accounts",key:["id":.text(accountID)]), current != nil || account["deletedAt"] == .null else { throw NativeDBError.message("取引先が見つかりません。") }
            let context = try current.map(orderContext) ?? orderContext(accountID:accountID)
            var fields = try orderHeaders(header,accountID:accountID)
            let buffer = try OrderDraftStore(); var offset = 0; var totals = OrderTotals()
            while true {
                let page = try lines(offset); guard page.count <= 100 else { throw NativeDBError.message("明細は100件ずつ処理してください。") }
                for input in page { try autoreleasepool { let quote = try orderQuote(input,context:context,date:now); try buffer.save(input:input,quote:quote); try totals.add(quote) } }
                offset += page.count; if page.count < 100 { break }
            }
            if submit && totals.count == 0 { throw NativeDBError.message("提出するには明細を1件以上追加してください。") }
            fields.merge(try totals.values()) { _,n in n }; fields["updatedBy"] = .text(identity.id)
            let pending = submit && identity.role == "user" && totals.belowList
            if submit { fields["status"] = .text(pending ? "PENDING_APPROVAL" : "READY"); if pending { fields["approvalRequestedAt"] = .text(ISO8601DateFormatter().string(from:now)) } }
            var order: NativeRecord
            if let current { order = current }
            else {
                let (number,series) = try allocateOrderNumber(now:now)
                fields["number"] = .text(number); fields["seriesId"] = series; fields["accountId"] = .text(accountID); fields["ownerId"] = account["assigned_to"]
                fields["priceListId"] = context.listID.map(SQLValue.text) ?? .null; fields["currency"] = .text(context.currency); fields["createdBy"] = .text(identity.id)
                fields["orderDate"] = .text(String(ISO8601DateFormatter().string(from:now).prefix(10))+"T00:00:00Z")
                for (key,value) in orderShipping(account) where fields[key] == nil { fields[key] = value }
                order = try db.insert("crm_Orders",values:fields,actor:identity.id)
            }
            while true {
                let old = try db.page("crm_OrderLines",fields:[],equal:["orderId":order["id"]])
                if old.rows.isEmpty { break }; for row in old.rows { try db.remove(row,actor:identity.id,action:"replace") }
            }
            offset = 0
            while true {
                let page = try buffer.page(offset:offset)
                for (index,row) in page.enumerated() {
                    try autoreleasepool {
                        var values = row.quote.values; values["orderId"] = order["id"]; values["position"] = .integer(Int64(offset+index))
                        _ = try db.insert("crm_OrderLines",values:values,actor:identity.id)
                    }
                }
                offset += page.count; if page.count < 100 { break }
            }
            if current != nil { order = try db.update(order,changes:fields,actor:identity.id,action:submit ? "order_submit" : "order_save") }
            try db.recordOrderLineCount(order,before:oldCount,after:totals.count,actor:identity.id)
            if pending { try enqueueOrderNotifications(order,decision:nil,note:nil,now:now) }
            return order
        }
    }
    func submitOrder(_ record: NativeRecord, now: Date = Date()) throws -> NativeRecord {
        try db.transaction {
            let current = try orderAccess(record,action:"submit")
            return try saveOrder(original:current,accountID:current["accountId"].string,header:[:],lines:{ offset in try self.orderLines(current,offset:offset).rows.map { OrderLineQuote.from($0).input } },submit:true,now:now)
        }
    }
    func changeOrder(_ record: NativeRecord, action: String, to: String? = nil, note: String? = nil, now: Date = Date()) throws -> NativeRecord {
        try db.transaction {
            let current = try orderAccess(record,action:action); var changes: [String:SQLValue] = ["updatedBy":.text(identity.id)]
            let text = note?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""; let time = ISO8601DateFormatter().string(from:now)
            switch action {
            case "approve": changes.merge(["status":.text("READY"),"approvedBy":.text(identity.id),"approvedAt":.text(time),"approvalNote":text.isEmpty ? .null : .text(text)]) { _,n in n }
            case "reject": guard !text.isEmpty else { throw NativeDBError.message("却下理由を入力してください。") }; changes.merge(["status":.text("DRAFT"),"approvalNote":.text(text),"approvalRequestedAt":.null]) { _,n in n }
            case "withdraw": changes["status"] = .text("DRAFT"); changes["approvalRequestedAt"] = .null
            case "reopen": changes.merge(["status":.text("DRAFT"),"approvalRequestedAt":.null,"approvedBy":.null,"approvedAt":.null]) { _,n in n }
            case "cancel": changes["status"] = .text("CANCELLED")
            case "retry": changes["status"] = .text("READY")
            case "advance": guard let to, OrderWorkflow.next(current["status"].string).contains(to) else { throw NativeDBError.message("移動できる受注状態を選択してください。") }; changes["status"] = .text(to)
            default: throw NativeDBError.message("受注の操作が不正です。")
            }
            let updated = try db.update(current,changes:changes,actor:identity.id,action:"order_"+action)
            if ["approve","reject"].contains(action) { try enqueueOrderNotifications(updated,decision:action == "approve" ? "APPROVED" : "REJECTED",note:text,now:now) }
            return updated
        }
    }
    func deleteOrder(_ record: NativeRecord) throws { try db.transaction { let current = try orderAccess(record,action:"delete"); try db.remove(current,actor:identity.id,action:"delete") } }
    private func enqueueOrderNotifications(_ order: NativeRecord, decision: String?, note: String?, now: Date) throws {
        guard try db.get("crm_SystemSettings",key:["key":.text("orders_approval_emails")])?["value"] != .text("false") else { return }
        var offset = 0
        while true {
            let filter: RecordFilter = decision == nil ? .every([.equal("userStatus",.text("ACTIVE")),.any([.equal("role",.text("admin")),.equal("role",.text("manager"))])]) : .equal("id",order["createdBy"])
            let users = try db.page("Users",fields:["email"],offset:offset,filter:filter)
            for user in users.rows where !user["email"].string.isEmpty {
                try db.enqueue(decision == nil ? "orders.approval_requested" : "orders.approval_decided",payload:["orderId":order["id"].string,"number":order["number"].string,"recipientId":user["id"].string,"recipientEmail":user["email"].string,"actorId":identity.id,"requestedAt":order["approvalRequestedAt"].string,"requestRevision":String(order.revision),"decision":decision ?? "","note":note ?? ""],now:now)
            }
            offset += users.rows.count; if users.rows.isEmpty || offset >= users.total { break }
        }
    }
    func saveOrderSettings(_ original: NativeRecord, name: String, template: String, reset: String, active: Bool, emails: Bool) throws -> NativeRecord {
        try authenticated(); guard identity.role == "admin" else { throw NativeDBError.message("受注の採番設定は管理者が変更してください。") }
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines); let template = template.trimmingCharacters(in:.whitespacesAndNewlines)
        guard original.model == "NumberSeries", original["scope"] == .text("order"), !name.isEmpty, name.count <= 100, !template.isEmpty, template.count <= 60,
              template.range(of:#"\{#+\}"#,options:.regularExpression) != nil, ["YEARLY","NEVER"].contains(reset), reset != "YEARLY" || template.contains("{YYYY}") else { throw NativeDBError.message("名前と採番書式を確認してください。書式には{####}、毎年リセットする場合は{YYYY}も含めてください。") }
        return try db.transaction {
            let result = try db.update(original,changes:["name":.text(name),"template":.text(template),"resetPolicy":.text(reset),"active":.integer(active ? 1 : 0)],actor:identity.id)
            let key = ["key":SQLValue.text("orders_approval_emails")]; let value = SQLValue.text(emails ? "true" : "false")
            if let setting = try db.get("crm_SystemSettings",key:key) { _ = try db.update(setting,changes:["value":value],actor:identity.id) }
            else { _ = try db.insert("crm_SystemSettings",values:key.merging(["value":value]) { _,n in n },actor:identity.id) }
            return result
        }
    }
}
