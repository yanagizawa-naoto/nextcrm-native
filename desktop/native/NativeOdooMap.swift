import Foundation

/// Odoo JSON uses `false` for absent many-to-one fields; keep it distinct from JSON null.
enum NativeOdooMap {
    typealias Row = [String: Any]
    static let null = NSNull()
    static let whitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    static let partnerFields = ["id","name","is_company","company_registry","vat","street","street2","city","zip","state_id","country_id","email","phone","mobile","function","user_id","parent_id","type","active","customer_rank","write_date","property_product_pricelist"]
    static let variantFieldNames = ["id","display_name","default_code","description_sale","type","active","sale_ok","lst_price","standard_price","currency_id","taxes_id","uom_id","categ_id","product_tmpl_id","write_date"]
    static let ruleFields = ["id","applied_on","product_tmpl_id","product_id","categ_id","min_quantity","date_start","date_end","compute_price","fixed_price","percent_price","base","base_pricelist_id","price_discount","price_markup","price_surcharge","price_round","price_min_margin","price_max_margin","write_date"]
    static func string(_ value: Any?) -> String { NativePluginJSON.string(value) }
    static func truth(_ value: Any?) -> Bool { NativePluginJSON.truthy(value) }
    static func coalesce(_ value: Any?, _ fallback: Any) -> Any { value == nil || value is NSNull ? fallback : value! }
    static func or(_ value: Any?, _ fallback: Any) -> Any { truth(value) ? value! : fallback }
    static func clean(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: whitespace); return text.isEmpty ? nil : text
    }
    static func id(_ value: Any?) -> Double? {
        guard let values=value as? [Any],let first=values.first else { return nil }
        return NativePluginJSON.number(first)
    }
    static func label(_ value: Any?) -> Any? { (value as? [Any]).flatMap { $0.count > 1 ? $0[1] : nil } }
    static func replace(_ value: String, _ pattern: String, _ replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    static func words(_ value: String) -> [String] { value.components(separatedBy: whitespace).filter { !$0.isEmpty } }
    static func normalizeNumber(_ country: String?, _ raw: String?) -> String? {
        guard let raw else { return nil }
        let n = raw.components(separatedBy: whitespace).joined().uppercased()
        guard !n.isEmpty else { return nil }
        if country?.uppercased() == "CZ", n.range(of: #"^[0-9]{1,8}$"#, options: .regularExpression) != nil { return String(repeating:"0",count:8-n.count)+n }
        return n
    }
    static func normalizeVAT(_ value: String?) -> String? { normalizeNumber(nil,value) }
    static func accountFields(_ p: Row, countries: [String:String], defaultCountry: String) -> Row {
        let street = [clean(p["street"]), clean(p["street2"])].compactMap { $0 }.joined(separator:", ")
        return ["name": clean(p["name"]) ?? "Odoo #"+string(p["id"]),
                "company_id":clean(p["company_registry"]) as Any? ?? null, "vat":clean(p["vat"]) as Any? ?? null,
                "billing_street":street.isEmpty ? null : street as Any,
                "billing_city":clean(p["city"]) as Any? ?? null, "billing_postal_code":clean(p["zip"]) as Any? ?? null,
                "billing_state":label(p["state_id"]) ?? null,
                "billing_country":id(p["country_id"]).flatMap { countries[string($0)] } ?? defaultCountry,
                "email":clean(p["email"]) as Any? ?? null,"office_phone":clean(p["phone"]) ?? clean(p["mobile"]) as Any? ?? null]
    }
    static func splitName(_ name: String) -> Row {
        var parts=words(name); let last=parts.popLast() ?? "", first=parts.joined(separator:" ")
        return ["first_name":first.isEmpty ? null : first as Any,"last_name":last]
    }
    static func contactFields(_ p: Row) -> Row {
        var result=splitName(clean(p["name"]) ?? "Odoo #"+string(p["id"]))
        for (out,input) in [("email","email"),("office_phone","phone"),("mobile_phone","mobile"),("position","function")] { result[out]=clean(p[input]) as Any? ?? null }
        return result
    }
    static func changedFields(_ current: Row, _ next: Row) -> Row {
        next.filter { key,value in !(value is NSNull) && !strictEqual(current[key] ?? null,value) }
    }
    static func strictEqual(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull { return b is NSNull }
        if let a=NativePluginJSON.boolean(a) { return NativePluginJSON.boolean(b) == a }
        if let a=NativePluginJSON.number(a),let b=NativePluginJSON.number(b) { return a == b }
        if let a=a as? String,let b=b as? String { return a.utf16.elementsEqual(b.utf16) }
        return false // Separate JSON objects are distinct JavaScript references.
    }
    static func number(_ value: Any?) -> Double {
        guard let value else { return .nan }; if value is NSNull { return 0 }
        if let b=NativePluginJSON.boolean(value) { return b ? 1:0 }
        if let n=NativePluginJSON.number(value) { return n }
        let text=string(value).trimmingCharacters(in:whitespace)
        if text.isEmpty { return 0 }
        if ["Infinity","+Infinity"].contains(text) { return .infinity }; if text == "-Infinity" { return -.infinity }
        for (prefix,radix) in [("0x",16),("0b",2),("0o",8)] where text.lowercased().hasPrefix(prefix) {
            let digits=String(text.dropFirst(2)); guard !digits.isEmpty else { return .nan }
            var result=0.0
            for ch in digits.utf8 { let digit = ch >= 48 && ch <= 57 ? Int(ch-48) : ch >= 65 && ch <= 70 ? Int(ch-65)+10 : ch >= 97 && ch <= 102 ? Int(ch-97)+10 : radix
                guard digit < radix else { return .nan }; result=result*Double(radix)+Double(digit)
            }; return result
        }
        guard text.range(of:#"^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil else { return .nan }
        return Double(text) ?? .nan
    }
    /// JavaScript Number.toFixed rounds the exact IEEE-754 value. Multiplying a
    /// Double by 100 first would incorrectly turn e.g. 2.675 into 2.68.
    static func fixed(_ value:Double,digits:Int)->String {
        precondition((0...8).contains(digits))
        guard value.isFinite,abs(value)<1e21 else { return NativePluginJSON.numberString(value) }
        let bits=abs(value).bitPattern,encoded=Int((bits>>52)&0x7ff),mantissa=(bits&0x000f_ffff_ffff_ffff)|(encoded == 0 ? 0:1<<52)
        let exponent=(encoded == 0 ? -1022:encoded-1023)-52,scale=UInt64(pow(10.0,Double(digits)))
        var (high,low)=mantissa.multipliedFullWidth(by:scale)
        if exponent>=0 {
            if exponent>0 { high=(high<<exponent)|(low>>(64-exponent));low <<= exponent }
        } else {
            let shift = -exponent
            let round:Bool
            if shift>128 { round=false;high=0;low=0 }
            else if shift==128 { round=(high&(1<<63)) != 0;high=0;low=0 }
            else if shift>=64 { round=shift==64 ? (low&(1<<63)) != 0 : (high&(1<<(shift-65))) != 0;low=high>>(shift-64);high=0 }
            else { round=(low&(1<<(shift-1))) != 0;low=(low>>shift)|(high<<(64-shift));high >>= shift }
            if round { let added=low.addingReportingOverflow(1);low=added.partialValue;if added.overflow { high += 1 } }
        }
        var text=""
        repeat { let q=high/10,r=high%10,part=UInt64(10).dividingFullWidth((r,low));text=String(part.remainder)+text;high=q;low=part.quotient } while high != 0 || low != 0
        if digits>0 { if text.count<=digits { text=String(repeating:"0",count:digits+1-text.count)+text };text.insert(".",at:text.index(text.endIndex,offsetBy:-digits)) }
        return (value<0 ? "-":"")+text
    }
    static func chosenLists(_ text: String) -> [Double] {
        var found=Set<Double>(); return text.components(separatedBy:whitespace.union(CharacterSet(charactersIn:",;"))).filter { !$0.isEmpty }.map(number).filter { $0.isFinite && $0.rounded(.towardZero) == $0 && $0 > 0 && found.insert($0).inserted }
    }
    static func sameAddress(_ a: Row, _ b: Row) -> Bool {
        func norm(_ v:Any?) -> String { words(string(coalesce(v,""))).joined(separator:" ").lowercased() }
        return strictEqual(norm(a["street"]),norm(b["street"])) && strictEqual(norm(a["city"]),norm(b["city"])) && strictEqual(norm(a["zip"]).replacingOccurrences(of:" ",with:""),norm(b["zip"]).replacingOccurrences(of:" ",with:""))
    }
    static func variantFields(_ value: Row, taxRate: ([Double])->String?) -> Row {
        ["name":value["display_name"] ?? null,"sku":or(value["default_code"],null),"description":or(value["description_sale"],null),
         "type":string(value["type"]) == "service" ? "SERVICE":"PRODUCT","status":truth(value["active"]) && truth(value["sale_ok"]) ? "ACTIVE":"ARCHIVED",
         "unit_price":string(value["lst_price"]),"unit_cost":string(value["standard_price"]),"currency":label(value["currency_id"]) ?? "",
         "tax_rate":taxRate((value["taxes_id"] as? [Any] ?? []).map(number)) as Any? ?? null,
         "unit":label(value["uom_id"]) ?? null,"categoryRef":id(value["categ_id"]).map(string) as Any? ?? null]
    }
    static func categoryOrder(_ categories: [Row]) -> [Row] {
        var byID:[Double:Row]=[:]; for row in categories { byID[number(row["id"])]=row }
        func depth(_ row:Row)->Int { var current=row,seen=Set<Double>(),depth=0
            while let parent=id(current["parent_id"]),let next=byID[parent],seen.insert(number(current["id"])).inserted { depth += 1; current=next }; return depth
        }
        return categories.enumerated().sorted { let a=depth($0.element),b=depth($1.element); if a != b { return a < b }; let ai=number($0.element["id"]),bi=number($1.element["id"]); return ai == bi ? $0.offset < $1.offset : ai < bi }.map(\.element)
    }
    static func mapRules(_ items:[Row],variants:[String:[Double]],known:Set<String>) -> Row {
        var rules:[Row]=[],skipped:[Row]=[]
        for item in items {
            guard let compute=["fixed":"FIXED","percentage":"PERCENTAGE","formula":"FORMULA"][string(item["compute_price"])] else { skipped.append(["ruleId":item["id"] ?? null,"reason":"compute_price "+string(item["compute_price"])]);continue }
            guard let base=["list_price":"LIST_PRICE","standard_price":"COST","pricelist":"PRICE_LIST"][string(item["base"])] else { skipped.append(["ruleId":item["id"] ?? null,"reason":"base "+string(item["base"])]);continue }
            func utc(_ value:Any?)->Any { guard truth(value) else { return null }; var s=string(value);if let r=s.range(of:" ") { s.replaceSubrange(r,with:"T") }; return s+"Z" }
            func nonzero(_ value:Any?)->Any { truth(value) ? string(value) : null }
            var common:Row=["minQuantity":string(coalesce(item["min_quantity"],0)),"dateStart":utc(item["date_start"]),"dateEnd":utc(item["date_end"]),"computePrice":compute,
                            "fixedPrice":compute == "FIXED" ? string(item["fixed_price"]) : null,"percentPrice":compute == "PERCENTAGE" ? string(item["percent_price"]) : null,
                            "base":base,"basePriceListRef":base == "PRICE_LIST" ? id(item["base_pricelist_id"]).map(string) as Any? ?? null : null,
                            "priceDiscount":base == "COST" && truth(item["price_markup"]) ? string(-number(item["price_markup"])) : string(coalesce(item["price_discount"],0)),
                            "priceSurcharge":string(coalesce(item["price_surcharge"],0)),"priceRound":nonzero(item["price_round"]),"priceMinMargin":nonzero(item["price_min_margin"]),"priceMaxMargin":nonzero(item["price_max_margin"])]
            common["productRef"]=null;common["categoryRef"]=null;common["externalRef"]=string(item["id"])
            switch string(item["applied_on"]) {
            case "3_global": common["appliesTo"]="ALL";rules.append(common)
            case "2_product_category" where id(item["categ_id"]) != nil: common["appliesTo"]="CATEGORY";common["categoryRef"]=string(id(item["categ_id"])!);rules.append(common)
            case "0_product_variant" where id(item["product_id"]) != nil:
                let ref=string(id(item["product_id"])!); if known.contains(ref) { common["appliesTo"]="PRODUCT";common["productRef"]=ref;rules.append(common) }
            case "1_product" where id(item["product_tmpl_id"]) != nil:
                for v in variants[string(id(item["product_tmpl_id"])!)] ?? [] where known.contains(string(v)) { common["appliesTo"]="PRODUCT";common["productRef"]=string(v);common["externalRef"]=string(item["id"])+":"+string(v);rules.append(common) }
            default: skipped.append(["ruleId":item["id"] ?? null,"reason":"applied_on "+string(item["applied_on"])])
            }
        }
        var variantRules:[String:String]=[:]
        for r in rules where string(r["appliesTo"]) == "PRODUCT" && !string(r["externalRef"]).contains(":") { variantRules[string(r["productRef"])]=string(r["externalRef"]) }
        for r in rules { let ref=string(r["externalRef"]),tid=number(String(ref.split(separator:":")[0]))
            if ref.contains(":"),let v=variantRules[string(r["productRef"])],!skipped.contains(where: { number($0["ruleId"]) == tid }) { skipped.append(["ruleId":tid,"reason":"variant rule \(v) on the same product: the CRM may pick a different rule than Odoo"]) }
        }
        rules=rules.enumerated().sorted { let a=number(String(string($0.element["externalRef"]).split(separator:":")[0])),b=number(String(string($1.element["externalRef"]).split(separator:":")[0])); return a == b ? $0.offset < $1.offset : a < b }.map(\.element)
        return ["rules":rules,"skipped":skipped]
    }
    static func baseRefs(_ items:[Row]) -> [Double] {
        var found=Set<Double>();return items.filter { string($0["base"]) == "pricelist" }.compactMap { id($0["base_pricelist_id"]) }.filter { found.insert($0).inserted }
    }
    static func orderLists(_ deps:[Double:[Double]],maxChain:Double = .infinity) -> Row {
        var order:[Double]=[],state:[Double:String]=[:]
        func visit(_ id:Double)->Bool { if state[id] == "done" { return true };if state[id] == "visiting" || state[id] == "bad" { state[id]="bad";return false }
            state[id]="visiting";let all=(deps[id] ?? []).map(visit);let ok=all.allSatisfy { $0 };state[id]=ok ? "done":"bad";if ok { order.append(id) };return ok
        }
        for id in deps.keys.sorted() { _=visit(id) }
        var chain:[Double:Set<Double>]=[:]
        for id in order { var seen:Set<Double>=[id];for base in deps[id] ?? [] { seen.formUnion(chain[base] ?? []) };chain[id]=seen }
        let deep=order.filter { Double(chain[$0]!.count)>maxChain }.sorted(),exclude=Set(deep)
        return ["order":order.filter { !exclude.contains($0) },"cyclic":state.filter { $0.value == "bad" }.map(\.key).sorted(),"tooDeep":deep]
    }
    static func pickSample(_ rules:[Row],products:[Row],parents:[String:Any],n:Int=20) -> [Row] {
        let sorted=products.enumerated().sorted { let a=number($0.element["ref"]),b=number($1.element["ref"]); return a == b ? $0.offset < $1.offset : a < b }.map(\.element)
        var out:[Row]=[],taken=Set<String>()
        func take(_ ref:String,_ qty:[Double]) { if out.count<n && taken.insert(ref).inserted { out.append(["ref":ref,"quantities":qty]) } }
        func qty(_ r:Row)->[Double] { let m=number(r["minQuantity"]);return m>1 ? [1,m,m-1]:[1] }
        for r in rules where string(r["appliesTo"]) == "PRODUCT" { take(string(r["productRef"]),qty(r)) }
        for r in rules where string(r["appliesTo"]) == "CATEGORY" {
            if let p=sorted.first(where: { p in guard !taken.contains(string(p["ref"])) else { return false };var c=p["categoryRef"] as? String,seen=Set<String>();while let key=c,!key.isEmpty,seen.insert(key).inserted { if key == string(r["categoryRef"]) { return true };c=parents[key] as? String };return false }) { take(string(p["ref"]),qty(r)) }
        }
        if rules.contains(where: { string($0["base"]) == "PRICE_LIST" }),let p=sorted.first(where: { !taken.contains(string($0["ref"])) }) { take(string(p["ref"]),[1]) }
        for p in sorted { take(string(p["ref"]),[1]) };return out
    }
    static func targetStatus(_ sale:Row,moves:[Row])->String {
        let state=string(sale["state"]);if state == "cancel" { return "CANCELLED" };if !["sale","done"].contains(state) { return "SENT" }
        let invoices=moves.filter { string($0["state"]) == "posted" && string($0["move_type"]) == "out_invoice" },live=invoices.filter { string($0["payment_state"]) != "reversed" }
        let invoiced=string(sale["invoice_status"]) == "invoiced" && !invoices.isEmpty
        if invoiced && !live.isEmpty && live.allSatisfy({ ["paid","in_payment"].contains(string($0["payment_state"])) }) { return "PAID" }
        if invoiced { return "INVOICED" };return string(sale["delivery_status"]) == "full" ? "DELIVERED":"CONFIRMED"
    }
    static func invoiceRows(_ moves:[Row])->[Row] {
        moves.filter { string($0["state"]) == "posted" }.map { m in ["number":m["name"] ?? null,"type":m["move_type"] ?? null,"date":or(m["invoice_date"],null),"due":or(m["invoice_date_due"],null),"amount":m["amount_total"] ?? null,"residual":m["amount_residual"] ?? null,"paymentState":m["payment_state"] ?? null] }
    }
    static func note(_ html:Any?,missing:Int,translate:(String,Row)->String)->Any {
        var text=truth(html) ? string(html):""
        text=replace(text,#"(?i)<br\s*/?>"#,"\n");text=replace(text,#"(?i)</p>\s*<p[^>]*>"#,"\n")
        while true { let next=replace(text,#"<[^<>]*>"#,"");if next == text { break };text=next }
        for (from,to) in [("&nbsp;"," "),("&lt;",""),("&gt;",""),("&quot;","\""),("&#39;","'"),("&amp;","&")] { text=text.replacingOccurrences(of:from,with:to) }
        text=replace(replace(text,"[<>]",""),#"\n{2,}"#,"\n").trimmingCharacters(in:whitespace)
        let result=[text,missing != 0 ? translate("orders.linesMissing",["count":missing]):""].filter { !$0.isEmpty }.joined(separator:"\n")
        return result.isEmpty ? null : result as Any
    }
    static func localParts(_ date:Date,zone:String)throws->(day:String,time:String) {
        guard let offset=NativePluginJSON.timeZoneOffset(zone,at:date) else { throw NativePluginError(message:"Invalid time zone specified: "+zone) }
        let local=date.timeIntervalSince1970+Double(offset),day=Int(floor(local/86400)),seconds=Int(floor(local-Double(day)*86400)),civil=NativePluginJSON.civilDay(day)
        let date=String(format:"%d-%02d-%02d",civil.year <= 0 ? 1-civil.year:civil.year,civil.month,civil.day)
        return (date,date+String(format:" %02d:%02d (%@)",seconds/3600,(seconds/60)%60,zone))
    }
}
