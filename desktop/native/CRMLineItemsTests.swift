import Foundation

@main enum CRMLineItemsTests {
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CRMLineItemsTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Lines-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ test: @autoclosure () throws -> Bool,_ name: String) throws { guard try test() else { throw NativeDBError.message("FAIL: "+name) }; checks += 1 }
        func rejects(_ name: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+name) }
        func user(_ name: String, role: String = "user") throws -> CRMService {
            let r = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:r["id"].string,role:role,partnerAccountID:nil))
        }
        let owner = try user("owner"); let outsider = try user("outsider"); let viewer = try user("viewer"); let partner = try user("partner",role:"partner")
        func save(_ actor: CRMService,_ model: String,_ input: [String:SQLValue],original: NativeRecord? = nil,parent: NativeRecord? = nil) throws -> NativeRecord {
            try actor.save(CRMModule.find(model)!,original:original,input:input,linkedTo:parent)
        }
        func current(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        let account = try save(owner,"crm_Accounts",["name":.text("明細検証")])
        let opportunity = try save(owner,"crm_Opportunities",["name":.text("導入商談"),"account":account["id"],"currency":.text("JPY")])
        let contract = try save(owner,"crm_Contracts",["title":.text("導入契約"),"account":account["id"],"currency":.text("JPY"),"value":.text("0")])
        let product = try save(admin,"crm_Products",["name":.text("日本語サポート"),"sku":.text("JP-SUPPORT"),"type":.text("SERVICE"),"status":.text("ACTIVE"),"unit_price":.text("12500.25"),"currency":.text("JPY")])
        try check(try owner.productLineDraft(product["id"],parent:opportunity)["unit_price"] == .text("12500.25"),"product price snapshot default")
        let lineFields: [String:SQLValue] = ["name":.text("初期導入"),"quantity":.integer(3),"unit_price":.text("12500.25"),"discount_type":.text("PERCENTAGE"),"discount_value":.text("10")]
        func add(_ parent: NativeRecord,_ fields: [String:SQLValue] = [:],actor: CRMService? = nil) throws -> NativeRecord {
            try save(actor ?? owner,LineContext.childModel(parent.model)!,lineFields.merging(fields) { _,n in n },parent:parent)
        }
        var first = try add(opportunity,["productId":product["id"]])
        try check(first["line_total"] == .text("33750.68") && first["sku"] == product["sku"],"discount then half-up line total and sku snapshot")
        try check(try current(opportunity)["expected_revenue"] == first["line_total"],"parent total atomic update")
        _ = try save(admin,"crm_Products",["name":.text("名称変更後"),"unit_price":.text("1")],original:product)
        try check(try current(first)["unit_price"] == .text("12500.25") && current(first)["name"] == .text("初期導入"),"catalog changes do not change saved line snapshot")
        let second = try add(opportunity,["name":.text("定額値引"),"quantity":.integer(1),"unit_price":.text("100"),"discount_type":.text("FIXED"),"discount_value":.text("20")])
        try check(second["line_total"] == .text("80") && second["sort_order"] == .integer(1),"fixed discount and append ordering")
        try check(try current(opportunity)["expected_revenue"] == .text("33830.68"),"sum rounded lines")
        try rejects("unauthorized parent add") { _ = try add(opportunity,actor:outsider) }
        try rejects("unauthorized line read") { _ = try outsider.fullRecord(first) }
        try rejects("unauthorized child list") { _ = try outsider.list(CRMModule.find(first.model)!,linkedTo:opportunity) }
        try rejects("unauthorized update") { _ = try save(outsider,first.model,["quantity":.integer(4)],original:first) }
        try rejects("unauthorized reorder") { _ = try outsider.moveLine(first,direction:1) }
        try rejects("unauthorized remove") { try outsider.delete(first) }
        _ = try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":.text(viewer.identity.id)],actor:identity.id)
        try check(try viewer.list(CRMModule.find(first.model)!,linkedTo:opportunity).total == 2,"account viewer can read related line items")
        try rejects("account viewer cannot write opportunity lines") { _ = try add(opportunity,actor:viewer) }
        try rejects("zero quantity") { _ = try add(opportunity,["quantity":.integer(0)]) }
        try rejects("fractional quantity") { _ = try add(opportunity,["quantity":.text("1.5")]) }
        try rejects("over 100 percent") { _ = try add(opportunity,["discount_value":.text("100.01")]) }
        try rejects("negative discount") { _ = try add(opportunity,["discount_value":.text("-1")]) }
        try rejects("forged parent field") { _ = try add(opportunity,["opportunityId":.text(UUID().uuidString.lowercased())]) }
        try rejects("forged total") { _ = try add(opportunity,["line_total":.text("1")]) }
        let stale = first; first = try save(owner,first.model,["quantity":.integer(4)],original:first)
        try rejects("stale line update") { _ = try save(owner,stale.model,["quantity":.integer(5)],original:stale) }
        try check(try current(opportunity)["expected_revenue"] == .text("45080.9"),"updated quantity reflected in parent")
        try rejects("change linked product") { _ = try save(owner,first.model,["productId":.null],original:first) }
        try rejects("change sku snapshot") { _ = try save(owner,first.model,["sku":.text("changed")],original:first) }
        try rejects("manual amount while lines exist") { _ = try save(owner,opportunity.model,["expected_revenue":.text("1")],original:current(opportunity)) }
        try rejects("currency while lines exist") { _ = try save(owner,opportunity.model,["currency":.text("USD")],original:current(opportunity)) }
        try check(try owner.moveLine(first,direction:1),"move down")
        try check(try owner.list(CRMModule.find(first.model)!,linkedTo:opportunity).rows.first?.record["id"] == second["id"],"reorder changes displayed order")
        try check(try !owner.moveLine(current(first),direction:1),"move at boundary is no-op")
        let legacy = try db.update(try current(first),changes:["sort_order":.integer(0)],actor:identity.id)
        try check(try owner.moveLine(legacy,direction:try owner.list(CRMModule.find(first.model)!,linkedTo:opportunity).rows.first?.record["id"] == legacy["id"] ? 1 : -1),"duplicate legacy positions normalize")
        try check(try db.page(first.model,fields:["sort_order"],equal:["opportunityId":opportunity["id"]],sort:"sort_order").rows.map { $0["sort_order"] } == [.integer(0),.integer(1)],"normalized positions contiguous")
        let lineCount = try db.page(first.model,fields:[],equal:["opportunityId":opportunity["id"]]).total
        let audit = try db.auditCount(first.model)
        try rejects("line overflow rolls back") { _ = try add(opportunity,["quantity":.integer(2147483647),"unit_price":.text("9999999999999999.99"),"discount_value":.text("0")]) }
        try check(try db.page(first.model,fields:[],equal:["opportunityId":opportunity["id"]]).total == lineCount && db.auditCount(first.model) == audit,"failed insert leaves no line or audit")
        _ = try add(contract,["name":.text("既存契約明細"),"quantity":.integer(1),"unit_price":.text("10"),"discount_value":.text("0")])
        try check(try owner.copyOpportunityLines(to:contract,from:opportunity["id"].string) == 2,"copy all lines appended to destination")
        try check(try current(contract)["value"] == .text("45090.9"),"copy recalculates destination total")
        try check(try owner.list(CRMModule.find("crm_ContractLineItems")!,linkedTo:contract).total == 3,"copy retains existing destination line")
        try rejects("copy source read scope") { _ = try outsider.copyOpportunityLines(to:contract,from:opportunity["id"].string) }
        let publicDestination = try save(viewer,"crm_Contracts",["title":.text("閲覧許可からコピー"),"currency":.text("JPY"),"value":.text("0")])
        try check(try viewer.copyOpportunityLines(to:publicDestination,from:opportunity["id"].string) == 2,"source read authority sufficient for copy")
        let usdContract = try save(owner,"crm_Contracts",["title":.text("USD契約"),"currency":.text("USD"),"value":.text("0")])
        try rejects("copy currency mismatch") { _ = try owner.copyOpportunityLines(to:usdContract,from:opportunity["id"].string) }
        let empty = try save(owner,"crm_Opportunities",["name":.text("空商談"),"currency":.text("JPY")])
        try rejects("empty source") { _ = try owner.copyOpportunityLines(to:contract,from:empty["id"].string) }
        let nullCurrency = try save(owner,"crm_Opportunities",["name":.text("旧通貨なし")])
        let eur = try add(nullCurrency,["quantity":.integer(1),"unit_price":.text("1"),"discount_value":.text("0")])
        try check(eur["currency"] == .text("EUR"),"legacy missing currency preserves source EUR fallback")
        try rejects("mismatched product currency auto-fill") { _ = try owner.productLineDraft(product["id"],parent:nullCurrency) }
        let zero = try add(empty,["productId":product["id"],"unit_price":.text("0"),"discount_value":.text("0")])
        try check(zero["line_total"] == .text("0"),"explicit zero price is preserved")
        let defaultPrice = try add(empty,["productId":product["id"],"unit_price":.text(""),"discount_value":.text("0")])
        try check(defaultPrice["unit_price"] == .text("1"),"blank product price gets current catalog price")
        let assignmentInput: [String:SQLValue] = ["productId":product["id"],"quantity":.integer(2),"custom_price":.text("12000.5"),"currency":.text("JPY"),"status":.text("ACTIVE"),"start_date":.text("2026-01-01T00:00:00Z"),"end_date":.text("2027-01-01T00:00:00Z"),"notes":.text("年間契約")]
        var assignment = try save(owner,"crm_AccountProducts",assignmentInput,parent:account)
        try check(assignment["snapshot_rate"] == .text("1") && assignment["custom_price"] == .text("12000.5"),"assignment snapshot and custom price")
        try rejects("duplicate active assignment") { _ = try save(owner,assignment.model,assignmentInput,parent:account) }
        try check(try viewer.list(.assignment,linkedTo:account).total == 1,"account read scopes assignments")
        try rejects("outsider assignment read") { _ = try outsider.list(.assignment,linkedTo:account) }
        try check(try outsider.list(.assignment,linkedTo:product).total == 0,"product reverse list does not expose private accounts")
        try check(try owner.list(.assignment,linkedTo:product).total == 1,"product reverse view visible accounts only")
        try rejects("assignment currency immutable") { _ = try save(owner,assignment.model,["currency":.text("USD"),"quantity":.integer(2)],original:assignment) }
        try rejects("assignment invalid dates") { _ = try save(owner,assignment.model,["quantity":.integer(2),"start_date":.text("2028-01-01T00:00:00Z")],original:assignment) }
        assignment = try save(owner,assignment.model,["quantity":.integer(4),"custom_price":.null,"end_date":.null,"renewal_date":.text("2027-01-02T00:00:00Z")],original:assignment)
        try check(assignment["custom_price"] == .null && assignment["end_date"] == .null,"clear optional assignment fields")
        try owner.delete(assignment); assignment = try current(assignment)
        try check(assignment["status"] == .text("CANCELLED") && db.history(assignment).first?["action"] == .text("cancel"),"cancel keeps assignment and audit")
        let replacement = try save(owner,assignment.model,assignmentInput,parent:account)
        try rejects("reactivation duplicate") { _ = try save(owner,assignment.model,["quantity":.integer(2),"status":.text("ACTIVE")],original:assignment) }
        try owner.delete(replacement)
        let privateAccount = try save(owner,"crm_Accounts",["name":.text("パートナー担当" )])
        _ = try admin.setPartner(privateAccount,userID:partner.identity.id)
        let partnerDeal = try save(partner,"crm_Opportunities",["name":.text("パートナー商談"),"account":privateAccount["id"],"currency":.text("JPY")])
        try check(try add(partnerDeal,actor:partner)["createdBy"] == .text(partner.identity.id),"partner can write assigned opportunity lines")
        let partnerContract = try save(owner,"crm_Contracts",["title":.text("パートナー契約"),"account":privateAccount["id"],"currency":.text("JPY"),"value":.text("0")])
        try rejects("partner contract write denied") { _ = try add(partnerContract,actor:partner) }
        try owner.delete(try current(first)); try check(try current(opportunity)["expected_revenue"] == .text("80"),"remove recalculates remaining lines")
        try owner.delete(try current(second)); try check(try current(opportunity)["expected_revenue"] == .text("80"),"last removal retains manual amount like source")
        _ = try save(owner,opportunity.model,["expected_revenue":.text("100"),"currency":.text("USD")],original:current(opportunity))
        try check(try current(opportunity)["currency"] == .text("USD"),"manual amount and currency editable after all lines removed")
        try rejects("stale new-editor currency") { _ = try add(opportunity) }
        let many = try save(owner,"crm_Opportunities",["name":.text("100件越し"),"currency":.text("JPY")])
        for i in 0..<103 { _ = try add(many,["name":.text("明細\(i)"),"quantity":.integer(1),"unit_price":.text("0.01"),"discount_value":.text("0")]) }
        try check(try current(many)["expected_revenue"] == .text("1.03"),"sum uses all pages with exact decimal")
        let boundary = try owner.list(CRMModule.find(first.model)!,offset:100,linkedTo:many).rows.first!.record
        _ = try owner.moveLine(owner.fullRecord(boundary),direction:-1)
        try check(try owner.list(CRMModule.find(first.model)!,offset:0,linkedTo:many).rows.last?.record["id"] == boundary["id"],"reorder crosses page boundary")
        let manyTarget = try save(owner,"crm_Contracts",["title":.text("複写先"),"currency":.text("JPY"),"value":.text("0")])
        try check(try owner.copyOpportunityLines(to:manyTarget,from:many["id"].string) == 103 && current(manyTarget)["value"] == .text("1.03"),"paged copy and total")
        let before = try db.auditCount("crm_ContractLineItems")
        try rejects("copy rollback") { try db.transaction { _ = try owner.copyOpportunityLines(to:manyTarget,from:many["id"].string); throw NativeDBError.message("rollback") } }
        try check(try db.auditCount("crm_ContractLineItems") == before,"copy audit rolled back")
        try owner.delete(try current(many))
        try rejects("deleted parent line read") { _ = try owner.fullRecord(boundary) }
        try rejects("deleted parent copy") { _ = try owner.copyOpportunityLines(to:manyTarget,from:many["id"].string) }
        let concurrentParent = try save(owner,"crm_Opportunities",["name":.text("同時更新"),"currency":.text("JPY")])
        let anotherDB = try open(); let another = CRMService(db:anotherDB,identity:owner.identity)
        let lock = NSLock(); var failures: [String] = []; let group = DispatchGroup()
        for actor in [owner,another] {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try actor.save(CRMModule.find("crm_OpportunityLineItems")!,original:nil,input:lineFields,linkedTo:concurrentParent) }
                catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
            }
        }
        group.wait()
        try check(failures.isEmpty && (try current(concurrentParent))["expected_revenue"] == .text("67501.36"),"two connections serialize total updates")
        try check(try db.integrityCheck(),"integrity after all line workflows")
        print("{\"ok\":true,\"suite\":\"CRMLineItems\",\"checks\":\(checks)}")
    }
}
