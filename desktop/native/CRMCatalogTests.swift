import Foundation

@main enum CRMCatalogTests {
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("CRMCatalogTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Catalog-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
        func user(_ role: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(role),"email":.text(role+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:role,partnerAccountID:nil))
        }
        let manager = try user("manager"); let ordinary = try user("user"); let partner = try user("partner")
        func save(_ model: String,_ fields: [String:SQLValue],_ original: NativeRecord? = nil,_ actor: CRMService? = nil,_ parent: NativeRecord? = nil) throws -> NativeRecord {
            try (actor ?? admin).save(CRMModule.find(model)!,original:original,input:fields,linkedTo:parent)
        }
        func refresh(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        let root = try save("crm_ProductCategories",["name":.text("ソフトウェア"),"isActive":.integer(1)])
        let child = try save("crm_ProductCategories",["name":.text("運用支援"),"parentId":root["id"]])
        try check(try admin.references(root.model,search:"ソフト").total == 1,"category picker Japanese search")
        try rejects("category cycle") { _ = try save(root.model,["parentId":child["id"]],root) }
        try rejects("manager category write") { _ = try save(root.model,["name":.text("denied")],nil,manager) }
        try rejects("category deletion unsupported") { try admin.delete(child) }
        let fields: [String:SQLValue] = ["name":.text("日本語サポート"),"sku":.text("JP-SUPPORT"),"type":.text("SERVICE"),"status":.text("ACTIVE"),"unit_price":.text("100.25"),"unit_cost":.text("40.5"),"currency":.text("JPY"),"categoryId":child["id"],"tax_rate":.text("10"),"is_recurring":.integer(1),"billing_period":.text("MONTHLY")]
        var product = try save("crm_Products",fields,nil,manager)
        try check(product["unit_price"] == .text("100.25") && product["billing_period"] == .text("MONTHLY"),"exact product amounts and recurring period")
        try check(try ordinary.list(CRMModule.find(product.model)!).total == 1,"user catalog read")
        try check(try partner.references(product.model,search:"日本語").total == 1,"partner catalog read")
        try rejects("user product write") { _ = try save(product.model,fields,nil,ordinary) }
        try rejects("partner product create") { _ = try save(product.model,fields,nil,partner) }
        try rejects("duplicate SKU") { _ = try save(product.model,fields) }
        try rejects("required recurring period") { _ = try save(product.model,["billing_period":.null],product) }
        try rejects("negative product price") { _ = try save(product.model,["unit_price":.text("-1")],product) }
        try rejects("protected source") { _ = try save(product.model,["source":.text("EXTERNAL")],product) }
        let original = product; product = try save(product.model,["is_recurring":.integer(0)],product)
        try check(product["billing_period"] == .null && product["v"] == .integer(1),"nonrecurring clears billing period and increments version")
        try rejects("stale product update") { _ = try save(product.model,["unit_price":.text("900")],original) }
        let external = try db.insert("crm_Products",values:fields.merging(["sku":.text("EXTERNAL-1"),"source":.text("EXTERNAL")]) { _,n in n },actor:identity.id)
        try rejects("external update") { _ = try save(external.model,["name":.text("blocked")],external) }
        try rejects("external delete") { try admin.delete(external) }
        let extCategory = try db.insert(root.model,values:["name":.text("外部"),"source":.text("EXTERNAL")],actor:identity.id)
        try rejects("external category parent") { _ = try save(root.model,["parentId":extCategory["id"]],child) }
        let list = try save("crm_PriceLists",["name":.text("標準価格"),"currency":.text("JPY")],nil,manager)
        let special = try save(list.model,["name":.text("特別価格"),"currency":.text("JPY")])
        try rejects("ordinary list writer") { _ = try save(list.model,["name":.text("denied")],list,ordinary) }
        func rule(_ parent: NativeRecord,_ fields: [String:SQLValue],_ original: NativeRecord? = nil) throws -> NativeRecord {
            try save("crm_PriceListRules",["appliesTo":.text("ALL"),"computePrice":.text("FIXED"),"fixedPrice":.text("80"),"minQuantity":.text("0")].merging(fields) { _,n in n },original,nil,parent)
        }
        let fallback = try admin.checkedPrice(productID:product["id"].string,listID:nil,quantity:"1",date:"2026-06-15T00:00:00Z")
        try check(fallback.price == "100.25" && fallback.ruleId == nil,"product fallback")
        let broad = try rule(list,[:]); let category = try rule(list,["appliesTo":.text("CATEGORY"),"categoryId":root["id"],"fixedPrice":.text("70")])
        func price(_ parent: NativeRecord = list,_ quantity: String = "10",_ date: String = "2026-06-15T00:00:00Z") throws -> PricingEngine.Result { try admin.checkedPrice(productID:product["id"].string,listID:parent["id"].string,quantity:quantity,date:date) }
        try check(try price().ruleId == category["id"].string,"ancestor category beats ALL")
        let specific = try rule(list,["appliesTo":.text("PRODUCT"),"productId":product["id"],"fixedPrice":.text("60"),"minQuantity":.text("10")])
        try check(try price().price == "60","product rule threshold inclusive")
        try check(try price(list,"9.9999").price == "70","below quantity threshold")
        let future = try rule(list,["appliesTo":.text("PRODUCT"),"productId":product["id"],"fixedPrice":.text("50"),"minQuantity":.text("20"),"dateStart":.text("2026-06-16T00:00:00Z")])
        try check(try price(list,"20").price == "60","future rule skipped")
        try check(try price(list,"20","2026-06-16T00:00:00Z").price == "50","date starts inclusive")
        try check(try admin.list(.priceRule,linkedTo:list).total == 4,"rules scoped to selected price list")
        let nested = try rule(special,["computePrice":.text("PERCENTAGE"),"percentPrice":.text("10"),"base":.text("PRICE_LIST"),"basePriceListId":list["id"]])
        try check(try price(special).price == "54","nested price list discount")
        try check(nested["fixedPrice"] == .null && nested["priceDiscount"] == .text("0"),"irrelevant fixed/formula fields cleared")
        try rejects("price list reference cycle") { _ = try rule(list,["computePrice":.text("PERCENTAGE"),"percentPrice":.text("10"),"base":.text("PRICE_LIST"),"basePriceListId":special["id"]]) }
        try rejects("rule missing category") { _ = try rule(list,["appliesTo":.text("CATEGORY")]) }
        try rejects("percentage range") { _ = try rule(list,["computePrice":.text("PERCENTAGE"),"percentPrice":.text("100.01")]) }
        try rejects("round zero") { _ = try rule(list,["computePrice":.text("FORMULA"),"priceRound":.text("0")]) }
        try rejects("margin reversed") { _ = try rule(list,["computePrice":.text("FORMULA"),"priceMinMargin":.text("5"),"priceMaxMargin":.text("4")]) }
        try rejects("date range reversed") { _ = try rule(list,["dateStart":.text("2026-06-17T00:00:00Z"),"dateEnd":.text("2026-06-16T00:00:00Z")]) }
        try rejects("no parent list") { _ = try save("crm_PriceListRules",["appliesTo":.text("ALL"),"minQuantity":.text("0")]) }
        try rejects("base list in use") { try admin.delete(list) }
        try admin.setDefaultPriceList(special["id"])
        try check(try ordinary.resolvedPriceList(accountID:nil) == special["id"].string,"instance default resolution")
        try rejects("default list delete") { try admin.delete(special) }
        try rejects("manager cannot set default") { try manager.setDefaultPriceList(list["id"]) }
        let account = try save("crm_Accounts",["name":.text("価格確認株式会社"),"pricelist_id":list["id"]])
        try check(try admin.resolvedPriceList(accountID:account["id"].string) == list["id"].string,"account list overrides instance default")
        try rejects("account scope in resolver") { _ = try ordinary.resolvedPriceList(accountID:account["id"].string) }
        try admin.setDefaultPriceList(.null)
        try check(try admin.resolvedPriceList(accountID:nil) == nil,"default unset")
        let usd = try save(list.model,["name":.text("米ドル"),"currency":.text("USD")])
        try rejects("missing exchange rate") { _ = try price(usd) }
        let rate = try save("ExchangeRate",["fromCurrency":.text("USD"),"toCurrency":.text("JPY"),"rate":.text("150"),"effectiveDate":.text("2026-06-15T00:00:00Z")])
        try check(try PriceDecimal.rounded(PriceDecimal.parse(price(usd).price),scale:2) == Decimal(string:"0.67")!,"inverse rate")
        try rejects("zero exchange rate") { _ = try save(rate.model,["rate":.text("0")],rate) }
        try rejects("manager exchange rate write") { _ = try save(rate.model,["rate":.text("149")],rate,manager) }
        let extList = try db.insert(list.model,values:["name":.text("外部価格表"),"currency":.text("JPY"),"source":.text("EXTERNAL")],actor:identity.id)
        let extRule = try db.insert("crm_PriceListRules",values:["priceListId":extList["id"],"fixedPrice":.text("9")],actor:identity.id)
        try rejects("external list rule insert") { _ = try rule(extList,[:]) }
        try rejects("external list rule update") { _ = try rule(extList,["fixedPrice":.text("10")],extRule) }
        try rejects("external list rule delete") { try admin.delete(extRule) }
        try check(try price(extList).price == "9","external list can calculate")
        let large = try save(list.model,["name":.text("ページ越し価格表"),"currency":.text("JPY")])
        for i in 0..<103 { _ = try rule(large,["minQuantity":.text(String(i)),"fixedPrice":.text(String(200-i))]) }
        try check(try price(large,"102").price == "98","winner across 100-row pages")
        try check(try admin.list(.priceRule,offset:100,linkedTo:large).rows.count == 3,"rule pagination bounded")
        let count = try db.auditCount("crm_PriceListRules")
        try rejects("transaction rollback") { try db.transaction { _ = try rule(list,["fixedPrice":.text("1")]); throw NativeDBError.message("rollback") } }
        try check(try db.auditCount("crm_PriceListRules") == count,"rule audit rolls back")
        let retired = try save("crm_Products",fields.merging(["sku":.text("RETIRED")]) { _,n in n })
        let obsolete = try rule(list,["appliesTo":.text("PRODUCT"),"productId":retired["id"],"minQuantity":.text("999")])
        try admin.delete(retired)
        let repurposed = try rule(list,["appliesTo":.text("ALL"),"productId":retired["id"],"minQuantity":.text("999")],obsolete)
        try check(repurposed["productId"] == .null,"changing target clears obsolete product before relation validation")
        try admin.delete(future); try check(try price(list,"20","2026-06-16T00:00:00Z").price == "60","deleted rule no longer applied")
        try admin.delete(product); try rejects("deleted product calculation") { _ = try price() }
        try rejects("deleted SKU reserved") { _ = try save(product.model,fields) }
        product = try refresh(product); try admin.delete(product,restore:true); product = try refresh(product)
        try check(try price().ruleId == specific["id"].string,"restored product retains rule relations")
        try check(try db.history(broad).count == 1,"rule audit exists")
        try admin.delete(large); try check(try db.page("crm_PriceListRules",fields:[],equal:["priceListId":large["id"]]).total == 0,"unused list delete cascades own rules")
        try rejects("inactive authentication") {
            let user = try db.get("Users",key:["id":.text(ordinary.identity.id)])!; _ = try db.update(user,changes:["banned":.integer(1)],actor:identity.id)
            _ = try ordinary.checkedPrice(productID:product["id"].string,listID:nil,quantity:"1",date:"2026-06-15T00:00:00Z")
        }
        try check(try db.integrityCheck(),"database integrity and FK after catalog workflows")
        print("{\"ok\":true,\"suite\":\"CRMCatalog\",\"checks\":\(checks)}")
    }
}
