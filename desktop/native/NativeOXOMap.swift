import Foundation

/// Pure conversions preserve the source connector's JavaScript semantics.
/// Shared Odoo helpers implement the same number/whitespace primitives.
enum NativeOXOMap {
    typealias Row = NativePluginRecord
    static let null = NSNull(), separator = " / "
    static func string(_ value: Any?) -> String { NativePluginJSON.string(value) }
    static func number(_ value: Any?) -> Double { NativeOdooMap.number(value) }
    static func truth(_ value: Any?) -> Bool { NativePluginJSON.truthy(value) }
    static func coalesce(_ value: Any?, _ fallback: Any) -> Any { value == nil || value is NSNull ? fallback : value! }
    static func clean(_ value: Any?) -> String? { NativeOdooMap.clean(value) }
    static func ref(_ row: Row) -> String { row["odooId"] != nil && !(row["odooId"] is NSNull) ? string(row["odooId"]) : "oxo:" + string(row["id"]) }
    static func countryCode(_ value: Any?) throws -> String? {
        guard truth(value) else { return nil }
        guard let text = value as? String else { throw NativePluginError(message:"name.trim is not a function") }
        let normalized=text.trimmingCharacters(in:NativeOdooMap.whitespace).lowercased()
        return NativeOXOCountries.byName.first{ $0.key.utf16.elementsEqual(normalized.utf16) }?.value
    }
    static func countryName(_ value: Any?) throws -> String? {
        guard truth(value) else { return nil }
        guard let value=value as? String else { throw NativePluginError(message:"code.toUpperCase is not a function") }
        let code=value.uppercased(),units=Array(code.unicodeScalars)
        guard (units.count==2 && units.allSatisfy{(65...90).contains($0.value)}) || (units.count==3 && units.allSatisfy{(48...57).contains($0.value)}) else { throw NativePluginError(message:"invalid_argument") }
        return NativeOXOCountries.names[code] ?? code
    }
    static func accountFields(_ row: Row) throws -> Row {
        var result: Row = ["name":clean(row["name"]) ?? "OXO ERP #"+string(row["id"]),"billing_country":try countryCode(row["country"]) as Any? ?? null]
        for (out,source) in [("company_id","ico"),("vat","dic"),("billing_street","street"),("billing_city","city"),("billing_postal_code","zip"),("email","email"),("office_phone","phone")] { result[out] = clean(row[source]) as Any? ?? null }
        return result
    }
    static func changedFields(_ current: Row, _ next: Row) -> Row { NativeOdooMap.changedFields(current,next) }
    static func normalizeNumber(_ country: String?, _ value: String?) -> String? { NativeOdooMap.normalizeNumber(country,value) }
    static func normalizeVAT(_ value: String?) -> String? { NativeOdooMap.normalizeVAT(value) }
    static func sameAddress(_ a: Row, _ b: Row) -> Bool {
        func norm(_ value:Any?) -> String { NativeOdooMap.words(string(coalesce(value,""))).joined(separator:" ").lowercased() }
        func zip(_ value:Any?) -> String { string(coalesce(value,"")).components(separatedBy:NativeOdooMap.whitespace).joined() }
        return norm(a["street"]).utf16.elementsEqual(norm(b["street"]).utf16) && norm(a["city"]).utf16.elementsEqual(norm(b["city"]).utf16) && zip(a["zip"]).utf16.elementsEqual(zip(b["zip"]).utf16)
    }
    static func chosenLists(_ text: String) -> [Double] { NativeOdooMap.chosenLists(text) }
    static func decimal(_ value: Any?) -> String { NativePluginJSON.numberString(number(NativeOdooMap.fixed(number(value),digits:4))) }
    static func localTime(_ date: String, zone: String) throws -> String {
        let parts = try NativeOdooMap.localParts(NativePluginJSON.date(date),zone:zone)
        return parts.time
    }
    static func exactKey(_ text:String) -> String { Data(text.utf8).base64EncodedString() }
    static func categoryPaths(_ rows: [Row]) -> [(path:String,ref:String)] {
        var byRef:[String:Row]=[:]
        for row in rows { byRef[exactKey(string(row["ref"]))]=row }
        func path(_ row:Row,_ seen:Set<String>) -> String {
            let own=exactKey(string(row["ref"])),name=string(row["name"])
            guard truth(row["parentRef"]),let parent=byRef[exactKey(string(row["parentRef"]))] else{return name}
            let parentKey=exactKey(string(parent["ref"]))
            if seen.contains(parentKey) || parentKey==own{return name}
            var next=seen;next.insert(own);return path(parent,next)+separator+name
        }
        var entries:[(path:String,ref:String)]=[],indices:[String:Int]=[:]
        for row in rows { let name=path(row,[]),encoded=exactKey(name),ref=string(row["ref"])
            if let i=indices[encoded]{entries[i].ref=ref}else{indices[encoded]=entries.count;entries.append((name,ref))}
        };return entries
    }
    static func productFields(_ row: Row, categoryRef: String?, currency: String, current: Row?) -> Row {
        func keep(_ key: String) -> Any { guard let value = current?[key], !(value is NSNull) else { return null }; return string(value) }
        return ["name":row["name"] ?? null,"sku":truth(row["code"]) ? row["code"]! : null,"description":keep("description"),
                "type":string(row["kind"]) == "SERVICE" ? "SERVICE":"PRODUCT","status":truth(row["active"]) && truth(row["saleOk"]) ? "ACTIVE":"ARCHIVED",
                "unit_price":coalesce(row["listPrice"],"0"),"unit_cost":keep("unit_cost"),"currency":currency,"tax_rate":keep("tax_rate"),"unit":row["unit"] ?? null,"categoryRef":categoryRef as Any? ?? null]
    }
    static func sameProduct(_ row: Row?, _ fields: Row, _ link: Row?) -> Bool {
        guard let row, let link else { return false }
        for key in ["name","sku","description","type","status","currency","unit"] {
            let left: Any = ["sku","description","unit"].contains(key) ? coalesce(row[key],null) : row[key] ?? null
            if !NativeOdooMap.strictEqual(left,fields[key] ?? null) { return false }
        }
        for key in ["unit_price","unit_cost","tax_rate"] {
            let a = coalesce(row[key],null), b = coalesce(fields[key],null)
            if a is NSNull || b is NSNull { if !(a is NSNull && b is NSNull) { return false } }
            else if number(a) != number(b) { return false }
        }
        return NativeOdooMap.strictEqual(link["categoryRef"] ?? null,fields["categoryRef"] ?? null)
    }
    static func mapRules(_ rules: [Row], products: [Double:String], templates: [Double:[String]], categoryRef: (String)->String?, listRef:(Double)->String?) -> (rules:[Row],skipped:[Row]) {
        func newer(_ r: Row) -> Double { number(coalesce(r["odooId"],1e9+number(r["id"]))) }
        var out:[Row] = [], skipped:[Row] = []
        for r in rules.enumerated().sorted(by:{ let a=newer($0.element),b=newer($1.element);return a == b ? $0.offset < $1.offset:a < b }).map(\.element) {
            let key = ref(r), base = string(r["base"])
            let baseRef = base == "PRICE_LIST" && !(coalesce(r["basePriceListId"],null) is NSNull) ? listRef(number(r["basePriceListId"])) : nil
            if base == "PRICE_LIST" && baseRef == nil { skipped.append(["ruleId":r["id"] ?? null,"reason":"base list "+string(coalesce(r["basePriceListId"],"-"))+" not imported"]);continue }
            let kind = string(r["kind"])
            var common:Row = ["minQuantity":r["minQty"] ?? null,"dateStart":null,"dateEnd":null,"fixedPrice":kind == "FIXED" ? coalesce(r["fixedPrice"],"0"):null,
                "percentPrice":kind == "PERCENT" ? coalesce(r["percent"],"0"):null,"base":r["base"] ?? null,"basePriceListRef":baseRef as Any? ?? null,
                "priceDiscount":"0","priceSurcharge":"0","priceRound":null,"priceMinMargin":null,"priceMaxMargin":null]
            common["computePrice"] = ["FIXED":"FIXED","PERCENT":"PERCENTAGE"][kind]
            func add(_ type:String,_ product:String?,_ category:String?,_ reference:String) { var next=common;next["appliesTo"]=type;next["productRef"]=product as Any? ?? null;next["categoryRef"]=category as Any? ?? null;next["externalRef"]=reference;out.append(next) }
            switch string(r["appliesTo"]) {
            case "ALL": add("ALL",nil,nil,key)
            case "CATEGORY":
                if truth(r["categoryName"]),let c=categoryRef(string(r["categoryName"])) { add("CATEGORY",nil,c,key) }
                else { skipped.append(["ruleId":r["id"] ?? null,"reason":"category "+string(coalesce(r["categoryName"],"-"))+" not in the CRM"]) }
            default:
                if !(coalesce(r["productId"],null) is NSNull) { if let p=products[number(r["productId"])] { add("PRODUCT",p,nil,key) } }
                else if !(coalesce(r["productTemplateOdooId"],null) is NSNull) { for p in templates[number(r["productTemplateOdooId"])] ?? [] { add("PRODUCT",p,nil,key+":"+p) } }
            }
        }
        return (out,skipped)
    }
    static func orderLists(_ dependencies:[Double:[Double]],maxChain:Double = .infinity) -> Row { NativeOdooMap.orderLists(dependencies,maxChain:maxChain) }
    static func fnv(_ text:String) -> String { var value:UInt32 = 0x811c9dc5;for unit in text.utf16 { value = (value ^ UInt32(unit)) &* 0x01000193 };return String(value,radix:16) }
    static func orderedJSON(_ row:Row,keys:[String]) throws -> String {
        "{" + (try keys.compactMap { key -> String? in guard let value=row[key] else { return nil };return try NativePluginJSON.text(key)+":"+NativePluginJSON.text(value) }).joined(separator:",") + "}"
    }
    static func listHash(name:Any,currency:Any,active:Bool,rules:[Row]) throws -> String {
        let keys=["minQuantity","dateStart","dateEnd","computePrice","fixedPrice","percentPrice","base","basePriceListRef","priceDiscount","priceSurcharge","priceRound","priceMinMargin","priceMaxMargin","appliesTo","productRef","categoryRef","externalRef"]
        return try fnv("{\"name\":"+NativePluginJSON.text(name)+",\"currency\":"+NativePluginJSON.text(currency)+",\"isActive\":"+(active ? "true":"false")+",\"rules\":["+rules.map{try orderedJSON($0,keys:keys)}.joined(separator:",")+"]}")
    }
    static func targetStatus(_ row:Row) -> String? {
        if string(row["state"]) == "cancel" { return "CANCELLED" }
        guard ["sale","done"].contains(string(row["state"])) else { return nil }
        return string(row["delivery"]) == "full" ? "DELIVERED":"CONFIRMED"
    }
    static func linkFrom(_ order:Row,previous:Row,now:Date) -> Row {
        var row:Row = ["belowList":[],"sentAt":NativePluginJSON.stamp(now)]
        row.merge(previous){_,new in new}
        for key in ["number","state","delivery","deliveries"] { row[key]=order[key] }
        row["oxoId"]=order["id"];row["checkedAt"]=NativePluginJSON.stamp(now);row.removeValue(forKey:"missingNotified");return row
    }
    static func crmLines(_ products:[Double:String],_ order:Row) -> (lines:[Row],missing:Int) {
        var result:[Row]=[],missing=0
        for line in order["lines"] as? [Row] ?? [] {
            guard let product=products[number(line["productId"])] else { missing += 1;continue }
            result.append(["productId":product,"quantity":line["quantity"] ?? null,"unitPrice":decimal(number(line["unitPrice"])*(1-number(line["discount"])/100))])
        }
        return (result,missing)
    }
}
