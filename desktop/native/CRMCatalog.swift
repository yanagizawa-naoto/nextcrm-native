import Foundation

extension CRMService {
    static let catalogModels = ["crm_Products","crm_ProductCategories","crm_PriceLists","crm_PriceListRules","ExchangeRate"]
    func catalogWrite(_ model: String, original: NativeRecord?) throws {
        try authenticated()
        guard identity.elevated, !["crm_ProductCategories","ExchangeRate"].contains(model) || identity.role == "admin" else { throw NativeDBError.message("この情報を変更する権限がありません。") }
        if let original {
            guard let current = try db.get(model,key:db.key(for:original)), current["deletedAt"] == .null else { throw NativeDBError.message("対象が見つかりません。") }
            guard current.revision == original.revision else { throw NativeDBError.conflict }
            guard current["source"] != .text("EXTERNAL") else { throw NativeDBError.message("外部システムで管理されているため、ここでは変更できません。") }
        }
    }
    func catalogRecord(_ model: String, _ id: SQLValue) throws -> NativeRecord {
        guard let record = try db.get(model,key:[model == "Currency" ? "code" : "id":id]), record["deletedAt"] == .null else { throw NativeDBError.message("関連する情報が見つかりません。") }; return record
    }
    func saveCatalog(_ module: CRMModule, original: NativeRecord?, input: [String:SQLValue], linkedTo: NativeRecord?) throws -> NativeRecord {
        try db.transaction {
            guard Self.catalogModels.contains(module.model), original == nil || original?.model == module.model,
                  input.keys.allSatisfy({ k in module.fields.contains { $0.key == k } }) else { throw NativeDBError.message("変更できない項目が含まれています。") }
            try catalogWrite(module.model,original:original)
            var values = input
            func value(_ k: String) -> SQLValue { values[k] ?? original?[k] ?? .null }
            func decimal(_ k: String, fallback: String = "0") throws -> Decimal { try PriceDecimal.parse(value(k) == .null ? fallback : value(k).string) }
            for field in module.fields {
                if field.required, value(field.key).string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw NativeDBError.message("\(field.label)を入力してください。") }
                if module.model == "crm_PriceListRules" {
                    if field.key == "productId", value("appliesTo") != .text("PRODUCT") { continue }
                    if field.key == "categoryId", value("appliesTo") != .text("CATEGORY") { continue }
                    if field.key == "basePriceListId", value("computePrice") == .text("FIXED") || value("base") != .text("PRICE_LIST") { continue }
                }
                if case let .relation(target) = field.kind, value(field.key) != .null { _ = try catalogRecord(target,value(field.key)) }
            }
            if module.model != "crm_PriceListRules", module.model != "ExchangeRate" {
                let name = value("name").string.trimmingCharacters(in:.whitespacesAndNewlines)
                let limit = module.model == "crm_Products" ? 255 : module.model == "crm_ProductCategories" ? 100 : 200
                guard !name.isEmpty, name.count <= limit else { throw NativeDBError.message("名称は1〜\(limit)文字で入力してください。") }; values["name"] = .text(name)
            }
            if ["crm_Products","crm_PriceLists"].contains(module.model) {
                let currency = try catalogRecord("Currency",value("currency"))
                guard currency["isEnabled"] == .integer(1) else { throw NativeDBError.message("有効な通貨を選択してください。") }
            }
            switch module.model {
            case "crm_Products":
                for key in ["unit_price","unit_cost","tax_rate"] where value(key) != .null {
                    guard try decimal(key) >= 0 else { throw NativeDBError.message("単価・原価・税率は0以上で入力してください。") }
                }
                guard value("sku").string.count <= 100, value("unit").string.count <= 50 else { throw NativeDBError.message("商品コードは100文字、単位は50文字以内で入力してください。") }
                if value("sku").string.isEmpty { values["sku"] = .null }
                else if try db.page(module.model,fields:[],equal:["sku":value("sku")],includeDeleted:true,filter:original.map { .not(.equal("id",$0["id"])) } ?? .all).total > 0 { throw NativeDBError.message("同じ商品コードが登録されています。") }
                if value("is_recurring") == .integer(1) {
                    guard value("billing_period") != .null else { throw NativeDBError.message("継続課金の請求周期を選択してください。") }
                } else { values["billing_period"] = .null }
                if let original, case let .integer(v) = original["v"] { values["v"] = .integer(v+1) }
            case "crm_ProductCategories":
                var parent = value("parentId"); var seen = Set<String>(); if let original { seen.insert(original["id"].string) }
                while parent != .null {
                    guard seen.insert(parent.string).inserted else { throw NativeDBError.message("カテゴリが循環する親は選択できません。") }
                    let row = try catalogRecord(module.model,parent)
                    guard row["source"] != .text("EXTERNAL") else { throw NativeDBError.message("外部管理のカテゴリを親にはできません。") }; parent = row["parentId"]
                }
            case "crm_PriceListRules":
                let parentID = original?["priceListId"] ?? linkedTo?["id"] ?? .null
                guard original != nil || linkedTo?.model == "crm_PriceLists" else { throw NativeDBError.message("価格表からルールを追加してください。") }
                let list = try catalogRecord("crm_PriceLists",parentID); try catalogWrite(list.model,original:list)
                values["priceListId"] = parentID
                let target = value("appliesTo").string; let compute = value("computePrice").string
                guard ["ALL","CATEGORY","PRODUCT"].contains(target), ["FIXED","PERCENTAGE","FORMULA"].contains(compute) else { throw NativeDBError.message("対象と計算方法を選択してください。") }
                if target == "CATEGORY", value("categoryId") == .null { throw NativeDBError.message("対象カテゴリを選択してください。") }
                if target == "PRODUCT", value("productId") == .null { throw NativeDBError.message("対象商品を選択してください。") }
                if compute == "FIXED", value("fixedPrice") == .null { throw NativeDBError.message("固定単価を入力してください。") }
                if compute == "PERCENTAGE" {
                    guard value("percentPrice") != .null, try decimal("percentPrice") >= 0, try decimal("percentPrice") <= 100 else { throw NativeDBError.message("割引率は0〜100で入力してください。") }
                }
                guard try decimal("minQuantity") >= 0 else { throw NativeDBError.message("最低数量は0以上で入力してください。") }
                if value("dateStart") != .null, value("dateEnd") != .null, try PricingEngine.date(value("dateStart").string) > PricingEngine.date(value("dateEnd").string) { throw NativeDBError.message("終了日は開始日以降にしてください。") }
                if compute == "FORMULA" {
                    if value("priceRound") != .null, try decimal("priceRound") <= 0 { throw NativeDBError.message("丸め幅は0より大きい数値にしてください。") }
                    if value("priceMinMargin") != .null, value("priceMaxMargin") != .null, try decimal("priceMinMargin") > decimal("priceMaxMargin") { throw NativeDBError.message("上限加算額は下限加算額以上にしてください。") }
                }
                let base = compute == "FIXED" ? "LIST_PRICE" : value("base").string.isEmpty ? "LIST_PRICE" : value("base").string
                if base == "PRICE_LIST" {
                    guard value("basePriceListId") != .null else { throw NativeDBError.message("基準となる価格表を選択してください。") }
                    var queue = [value("basePriceListId").string]; var seen = Set<String>()
                    while let id = queue.popLast() {
                        guard id != parentID.string else { throw NativeDBError.message("価格表を循環して参照するルールは登録できません。") }
                        if !seen.insert(id).inserted { continue }; _ = try catalogRecord("crm_PriceLists",.text(id))
                        var offset = 0
                        while true {
                            let page = try db.page("crm_PriceListRules",fields:["basePriceListId"],equal:["priceListId":.text(id)],offset:offset,filter:.every([.not(.equal("basePriceListId",.null)),original.map { .not(.equal("id",$0["id"])) } ?? .all]))
                            queue += page.rows.map { $0["basePriceListId"].string }; offset += page.rows.count; if offset >= page.total || page.rows.isEmpty { break }
                        }
                    }
                }
                values["categoryId"] = target == "CATEGORY" ? value("categoryId") : .null; values["productId"] = target == "PRODUCT" ? value("productId") : .null
                values["fixedPrice"] = compute == "FIXED" ? value("fixedPrice") : .null; values["percentPrice"] = compute == "PERCENTAGE" ? value("percentPrice") : .null
                values["base"] = .text(base); values["basePriceListId"] = base == "PRICE_LIST" ? value("basePriceListId") : .null
                for k in ["priceDiscount","priceSurcharge"] { values[k] = compute == "FORMULA" && value(k) != .null ? value(k) : .text("0") }
                for k in ["priceRound","priceMinMargin","priceMaxMargin"] { if compute != "FORMULA" { values[k] = .null } }
            case "ExchangeRate":
                guard value("fromCurrency") != value("toCurrency"), try decimal("rate") > 0 else { throw NativeDBError.message("異なる通貨と、0より大きい換算レートを指定してください。") }
                values["source"] = .text("MANUAL")
            default: break
            }
            let schema = try db.schema.model(module.model)
            if original == nil, schema.field("createdBy") != nil { values["createdBy"] = .text(identity.id) }
            if schema.field("updatedBy") != nil { values["updatedBy"] = .text(identity.id) }
            return try original.map { try db.update($0,changes:values,actor:identity.id) } ?? db.insert(module.model,values:values,actor:identity.id)
        }
    }
    func deleteCatalog(_ record: NativeRecord, restore: Bool) throws {
        try authenticated()
        try db.transaction {
            if restore {
                guard record.model == "crm_Products", identity.role == "admin" else { throw NativeDBError.message("この情報は復元できません。") }
                let current = try db.get(record.model,key:db.key(for:record))
                guard current?["source"] != .text("EXTERNAL") else { throw NativeDBError.message("外部管理の商品は変更できません。") }
                _ = try db.setDeleted(record,deleted:false,actor:identity.id); return
            }
            try catalogWrite(record.model,original:record)
            if record.model == "crm_Products" { _ = try db.setDeleted(record,deleted:true,actor:identity.id); return }
            if record.model == "crm_ProductCategories" { throw NativeDBError.message("カテゴリは編集画面で無効にしてください。") }
            if record.model == "crm_PriceListRules" { let parent = try catalogRecord("crm_PriceLists",record["priceListId"]); try catalogWrite(parent.model,original:parent) }
            if record.model == "crm_PriceLists" {
                for (model,field) in [("crm_Accounts","pricelist_id"),("crm_PriceListRules","basePriceListId"),("crm_Orders","priceListId")] {
                    if try db.page(model,fields:[],equal:[field:record["id"]],includeDeleted:true).total > 0 { throw NativeDBError.message("使用中の価格表は削除できません。必要に応じて無効にしてください。") }
                }
                if try db.get("crm_SystemSettings",key:["key":.text("default_pricelist_id")])?["value"] == record["id"] { throw NativeDBError.message("標準価格表は削除できません。先に標準設定を解除してください。") }
            }
            try db.remove(record,actor:identity.id,action:"delete")
        }
    }
    func setDefaultPriceList(_ id: SQLValue) throws {
        try authenticated(); guard identity.role == "admin" else { throw NativeDBError.message("標準価格表を設定できるのは管理者です。") }
        try db.transaction {
            if id != .null { let list = try catalogRecord("crm_PriceLists",id); guard list["isActive"] == .integer(1) else { throw NativeDBError.message("有効な価格表を選択してください。") } }
            let key: [String:SQLValue] = ["key":.text("default_pricelist_id")]
            if let current = try db.get("crm_SystemSettings",key:key) { _ = try db.update(current,changes:["value":.text(id.string)],actor:identity.id) }
            else { _ = try db.insert("crm_SystemSettings",values:key.merging(["value":.text(id.string)]) { _,new in new },actor:identity.id) }
        }
    }
    func resolvedPriceList(accountID: String?) throws -> String? {
        try authenticated()
        if let accountID {
            try assertAccess("crm_Accounts",id:accountID)
            let account = try catalogRecord("crm_Accounts",.text(accountID))
            if account["pricelist_id"] != .null { return account["pricelist_id"].string }
        }
        let value = try db.get("crm_SystemSettings",key:["key":.text("default_pricelist_id")])?["value"].string ?? ""
        return value.isEmpty ? nil : value
    }
    func checkedPrice(productID: String, listID: String?, quantity: String, date: String) throws -> PricingEngine.Result {
        try authenticated()
        return try db.transaction {
            let p = try catalogRecord("crm_Products",.text(productID)); let q = try PriceDecimal.parse(quantity)
            guard q >= 0 else { throw NativeDBError.message("数量は0以上で入力してください。") }; _ = try PricingEngine.date(date)
            func optional(_ r: NativeRecord,_ k: String) -> String? { r[k] == .null ? nil : r[k].string }
            let product = PricingEngine.Product(id:productID,unitPrice:p["unit_price"].string,unitCost:optional(p,"unit_cost"),currency:p["currency"].string,categoryId:optional(p,"categoryId"))
            var chain: [String] = []; var category = product.categoryId
            while let id = category, chain.count < 20, !chain.contains(id) { chain.append(id); category = try db.get("crm_ProductCategories",key:["id":.text(id)]).flatMap { optional($0,"parentId") } }
            return try PricingEngine.compute(product:product,listID:listID,quantity:q,date:date,resolve:{ id in
                let list = try self.catalogRecord("crm_PriceLists",.text(id)); var winner: PricingEngine.Rule?; var offset = 0
                let fields = try self.db.schema.model("crm_PriceListRules").fields.map(\.name)
                while true {
                    let page = try self.db.page("crm_PriceListRules",fields:fields,equal:["priceListId":.text(id)],offset:offset)
                    for row in page.rows {
                        try autoreleasepool {
                            let data = try JSONSerialization.data(withJSONObject:row.values.mapValues(\.json))
                            let rule = try JSONDecoder().decode(PricingEngine.Rule.self,from:data)
                            if try PricingEngine.applicable(rule,product:product,chain:chain,quantity:q,date:date), try winner == nil || PricingEngine.precedes(rule,winner!,chain:chain) { winner = rule }
                        }
                    }
                    offset += page.rows.count; if offset >= page.total || page.rows.isEmpty { break }
                }
                return (list["currency"].string,winner)
            },rate:{ from,to in
                if from == to { return 1 }
                if let direct = try self.db.page("ExchangeRate",fields:["rate"],equal:["fromCurrency":.text(from),"toCurrency":.text(to)]).rows.first {
                    let r = try PriceDecimal.parse(direct["rate"].string); guard r > 0 else { throw NativeDBError.message("換算レートは0より大きい必要があります。") }; return r
                }
                if let inverse = try self.db.page("ExchangeRate",fields:["rate"],equal:["fromCurrency":.text(to),"toCurrency":.text(from)]).rows.first {
                    let r = try PriceDecimal.parse(inverse["rate"].string); guard r > 0 else { throw NativeDBError.message("換算レートは0より大きい必要があります。") }; return try PriceDecimal.calculate(1,"/",r)
                }
                throw NativeDBError.message("\(from)から\(to)への換算レートが未設定です。通貨レート画面で登録してください。")
            })
        }
    }
}
