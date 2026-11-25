import Foundation

extension CRMService {
    func lineParent(_ model: String, original: NativeRecord?, linkedTo: NativeRecord?, write: Bool) throws -> NativeRecord {
        guard let context = LineContext.forModel(model) else { throw NativeDBError.message("明細の種類が不正です。") }
        let id: SQLValue
        if let original {
            guard original.model == model, let current = try db.get(model,key:db.key(for:original)) else { throw NativeDBError.message("明細が見つかりません。") }
            guard current.revision == original.revision else { throw NativeDBError.conflict }; id = current[context.field]
        } else {
            guard linkedTo?.model == context.parentModel else { throw NativeDBError.message("関連する取引先・商談・契約から追加してください。") }; id = linkedTo!["id"]
        }
        try assertAccess(context.parentModel,id:id.string,write:write)
        return try catalogRecord(context.parentModel,id)
    }
    func lineCurrency(_ parent: NativeRecord) -> String { parent["currency"].string.isEmpty ? "EUR" : parent["currency"].string }
    func productLineDraft(_ productID: SQLValue, parent: NativeRecord) throws -> [String:SQLValue] {
        try assertAccess(parent.model,id:parent["id"].string,write:true)
        let product = try catalogRecord("crm_Products",productID)
        guard product["status"] == .text("ACTIVE") else { throw NativeDBError.message("有効な商品を選択してください。") }
        let currency = lineCurrency(parent)
        guard product["currency"].string == currency else {
            throw NativeDBError.message("商品の通貨は\(product["currency"].string)、明細の通貨は\(currency)です。名称と単価を明細の通貨で入力してください。")
        }
        return ["name":product["name"],"sku":product["sku"],"unit_price":product["unit_price"]]
    }
    func recalculateLines(_ parent: NativeRecord, childModel: String, preserveEmpty: Bool = false) throws -> (total: String, count: Int) {
        guard let context = LineContext.forModel(childModel), let totalField = context.totalField else { throw NativeDBError.message("明細の種類が不正です。") }
        var amount = Decimal(0); var count = 0
        while true {
            let page = try db.page(childModel,fields:["line_total","currency"],equal:[context.field:parent["id"]],offset:count)
            for row in page.rows {
                guard row["currency"].string == lineCurrency(parent) else { throw NativeDBError.message("明細の通貨が商談・契約の通貨と一致していません。") }
                amount = try LineItemMath.calculate(amount,"+",PriceDecimal.parse(row["line_total"].string))
            }
            count += page.rows.count; if count >= page.total || page.rows.isEmpty { break }
        }
        let text = PriceDecimal.string(amount)
        if count > 0 || !preserveEmpty { _ = try db.update(parent,changes:[totalField:.text(text),"updatedBy":.text(identity.id)],actor:identity.id,action:"line_total") }
        return (text,count)
    }
    func saveLine(_ module: CRMModule, original: NativeRecord?, input: [String:SQLValue], linkedTo: NativeRecord?) throws -> NativeRecord {
        try authenticated()
        return try db.transaction {
            guard input.keys.allSatisfy({ key in module.fields.contains { $0.key == key } }), let context = LineContext.forModel(module.model) else { throw NativeDBError.message("変更できない項目が含まれています。") }
            let parent = try lineParent(module.model,original:original,linkedTo:linkedTo,write:true)
            var values = input
            func value(_ key: String) -> SQLValue { values[key] ?? original?[key] ?? .null }
            let quantity = value("quantity")
            guard case let .integer(qty) = quantity, qty > 0, qty <= Int32.max else { throw NativeDBError.message("数量は1〜2147483647の整数で入力してください。") }
            values[context.field] = parent["id"]
            if module.model == "crm_AccountProducts" {
                if let original {
                    for key in ["productId","currency"] where value(key) != original[key] { throw NativeDBError.message("登録済みの商品の関連先・通貨は変更できません。取り消して新しく割り当ててください。") }
                } else {
                    let product = try catalogRecord("crm_Products",value("productId"))
                    guard product["status"] == .text("ACTIVE") else { throw NativeDBError.message("有効な商品だけを割り当てできます。") }
                    guard ["ACTIVE","PENDING"].contains(value("status").string) else { throw NativeDBError.message("新しい割当は有効または確認待ちにしてください。") }
                    let currency = try catalogRecord("Currency",value("currency")); guard currency["isEnabled"] == .integer(1) else { throw NativeDBError.message("有効な通貨を選択してください。") }
                    let configured = try db.get("crm_SystemSettings",key:["key":.text("default_currency")])?["value"].string ?? "JPY"
                    let base = configured.isEmpty ? "JPY" : configured
                    values["snapshot_rate"] = currency["code"].string == base ? .text("1") : try db.page("ExchangeRate",fields:["rate"],equal:["fromCurrency":currency["code"],"toCurrency":.text(base)]).rows.first?["rate"] ?? .null
                }
                if value("custom_price") != .null, try PriceDecimal.parse(value("custom_price").string) < 0 { throw NativeDBError.message("特別単価は0以上で入力してください。") }
                guard value("notes").string.count <= 1000 else { throw NativeDBError.message("メモは1000文字以内で入力してください。") }
                let start = try PricingEngine.date(value("start_date").string)
                for key in ["end_date","renewal_date"] where value(key) != .null {
                    guard try PricingEngine.date(value(key).string) > start else { throw NativeDBError.message("終了日・更新日は開始日より後にしてください。") }
                }
                if original == nil || ["ACTIVE","PENDING"].contains(value("status").string) {
                    let duplicate = try db.page(module.model,fields:[],equal:["accountId":parent["id"],"productId":value("productId")],filter:.every([.any([.equal("status",.text("ACTIVE")),.equal("status",.text("PENDING"))]),original.map { .not(.equal("id",$0["id"])) } ?? .all]))
                    guard duplicate.total == 0 else { throw NativeDBError.message("この商品には有効または確認待ちの割当があります。既存の割当を編集してください。") }
                }
            } else {
                if let original {
                    for key in ["productId","sku"] where value(key) != original[key] { throw NativeDBError.message("登録済み明細の商品・商品コードは変更できません。新しい明細として追加してください。") }
                    guard original["currency"].string == lineCurrency(parent) else { throw NativeDBError.message("商談・契約の通貨が変更されています。明細の通貨を確認してください。") }
                } else {
                    if let linkedTo, lineCurrency(linkedTo) != lineCurrency(parent) { throw NativeDBError.conflict }
                    if value("productId") != .null {
                        let product = try catalogRecord("crm_Products",value("productId")); guard product["status"] == .text("ACTIVE") else { throw NativeDBError.message("有効な商品を選択してください。") }
                        if value("name").string.isEmpty { values["name"] = product["name"] }
                        if value("sku").string.isEmpty { values["sku"] = product["sku"] }
                        // An explicit zero remains a free line; only a blank price requests a product default.
                        if value("unit_price").string.isEmpty { values["unit_price"] = try productLineDraft(product["id"],parent:parent)["unit_price"] }
                    }
                    let last = try db.page(module.model,fields:["sort_order"],equal:[context.field:parent["id"]],sort:"sort_order",descending:true).rows.first
                    let order: Int64 = { if case let .integer(n) = last?["sort_order"] { return n+1 }; return 0 }()
                    guard order <= Int32.max else { throw NativeDBError.message("明細の並び順が上限に達しました。") }; values["sort_order"] = .integer(order)
                    values["currency"] = .text(lineCurrency(parent))
                }
                let name = value("name").string.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 255 else { throw NativeDBError.message("明細名は1〜255文字で入力してください。") }; values["name"] = .text(name)
                values["line_total"] = .text(try LineItemMath.total(quantity:qty,price:value("unit_price").string,type:value("discount_type").string,discount:value("discount_value").string))
            }
            values["updatedBy"] = .text(identity.id)
            if original == nil { values["createdBy"] = .text(identity.id) }
            else if case let .integer(version) = original?["v"] { values["v"] = .integer(version+1) }
            let saved = try original.map { try db.update($0,changes:values,actor:identity.id) } ?? db.insert(module.model,values:values,actor:identity.id)
            if context.totalField != nil { _ = try recalculateLines(parent,childModel:module.model) }
            return saved
        }
    }
    func removeLine(_ record: NativeRecord) throws {
        try authenticated()
        try db.transaction {
            let parent = try lineParent(record.model,original:record,linkedTo:nil,write:true)
            if record.model == "crm_AccountProducts" {
                var changes: [String:SQLValue] = ["status":.text("CANCELLED"),"updatedBy":.text(identity.id)]
                if case let .integer(v) = record["v"] { changes["v"] = .integer(v+1) }
                _ = try db.update(record,changes:changes,actor:identity.id,action:"cancel")
            } else {
                try db.remove(record,actor:identity.id,action:"delete")
                // Source retains the previous parent amount after deleting the final line,
                // allowing the user to resume entering a manual opportunity/contract value.
                _ = try recalculateLines(parent,childModel:record.model,preserveEmpty:true)
            }
        }
    }
    func moveLine(_ record: NativeRecord, direction: Int) throws -> Bool {
        try authenticated()
        return try db.transaction {
            let parent = try lineParent(record.model,original:record,linkedTo:nil,write:true)
            guard let context = LineContext.forModel(record.model), context.totalField != nil else { throw NativeDBError.message("この情報は並べ替えできません。") }
            let changed = try db.moveOrderedLine(record,parentField:context.field,parentID:parent["id"],direction:direction,actor:identity.id)
            if changed { _ = try db.update(parent,changes:["updatedBy":.text(identity.id)],actor:identity.id,action:"reorder") }; return changed
        }
    }
    func copyOpportunityLines(to contract: NativeRecord, from opportunityID: String) throws -> Int {
        try authenticated()
        return try db.transaction {
            guard contract.model == "crm_Contracts" else { throw NativeDBError.message("契約を選択してください。") }
            try assertAccess(contract.model,id:contract["id"].string,write:true); try assertAccess("crm_Opportunities",id:opportunityID)
            let target = try catalogRecord(contract.model,contract["id"]); let source = try catalogRecord("crm_Opportunities",.text(opportunityID))
            guard lineCurrency(target) == lineCurrency(source) else { throw NativeDBError.message("商談と契約の通貨が違うためコピーできません。") }
            let model = "crm_ContractLineItems"
            let last = try db.page(model,fields:["sort_order"],equal:["contractId":target["id"]],sort:"sort_order",descending:true).rows.first
            var order: Int64 = { if case let .integer(n) = last?["sort_order"] { return n+1 }; return 0 }(); var count = 0
            let fields = ["productId","name","sku","description","quantity","unit_price","discount_type","discount_value","line_total","currency"]
            while true {
                let page = try db.page("crm_OpportunityLineItems",fields:fields,equal:["opportunityId":source["id"]],offset:count,sort:"sort_order")
                for row in page.rows {
                    guard row["currency"].string == lineCurrency(target), order <= Int32.max else { throw NativeDBError.message("明細の通貨または並び順を確認してください。") }
                    var values = Dictionary(uniqueKeysWithValues:fields.map { ($0,row[$0]) }); values["contractId"] = target["id"]; values["sort_order"] = .integer(order)
                    values["createdBy"] = .text(identity.id); values["updatedBy"] = .text(identity.id)
                    _ = try db.insert(model,values:values,actor:identity.id); order += 1
                }
                count += page.rows.count; if count >= page.total || page.rows.isEmpty { break }
            }
            guard count > 0 else { throw NativeDBError.message("選択した商談には明細がありません。") }
            _ = try recalculateLines(target,childModel:model); return count
        }
    }
    func guardParentLineFields(_ parent: NativeRecord, changes: [String:SQLValue]) throws {
        guard let model = LineContext.childModel(parent.model), let context = LineContext.forModel(model), let field = context.totalField,
              try db.page(model,fields:[],equal:[context.field:parent["id"]]).total > 0 else { return }
        if let currency = changes["currency"], currency != parent["currency"] { throw NativeDBError.message("明細がある間は通貨を変更できません。") }
        if let value = changes[field], try PriceDecimal.parse(value.string) != PriceDecimal.parse(parent[field].string) { throw NativeDBError.message("金額は明細から計算されます。明細を編集してください。") }
    }
}
