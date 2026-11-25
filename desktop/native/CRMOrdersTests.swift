import Foundation
import SQLite3

@main enum CRMOrdersTests {
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CRMOrdersTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Orders-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
        func user(_ role: String) throws -> CRMService {
            let r = try db.insert("Users",values:["name":.text(role),"email":.text(UUID().uuidString+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:r["id"].string,role:role,partnerAccountID:nil))
        }
        let owner = try user("user"); let manager = try user("manager"); let outsider = try user("user"); let partner = try user("partner")
        func refresh(_ r: NativeRecord) throws -> NativeRecord { try db.get(r.model,key:db.key(for:r))! }
        func save(_ model: String,_ values: [String:SQLValue]) throws -> NativeRecord { try admin.save(CRMModule.find(model)!,original:nil,input:values) }
        let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("受注確認株式会社"),"assigned_to":.text(owner.identity.id),"billing_street":.text("請求先番地"),"billing_city":.text("新宿区"),"billing_country":.text("日本"),"partnerUserId":.text(partner.identity.id)],actor:identity.id)
        let otherAccount = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("別会社")],actor:identity.id)
        let contact = try db.insert("crm_Contacts",values:["v":.integer(0),"first_name":.text("確認"),"last_name":.text("担当"),"accountsIDs":account["id"]],actor:identity.id)
        let wrongContact = try db.insert("crm_Contacts",values:["v":.integer(0),"last_name":.text("別"),"accountsIDs":otherAccount["id"]],actor:identity.id)
        var product = try save("crm_Products",["type":.text("PRODUCT"),"name":.text("受注商品"),"sku":.text("ORDER-JP"),"unit_price":.text("100.25"),"tax_rate":.text("10"),"currency":.text("JPY"),"status":.text("ACTIVE")])
        let list = try save("crm_PriceLists",["name":.text("受注価格"),"currency":.text("JPY")])
        _ = try admin.save(.priceRule,original:nil,input:["appliesTo":.text("ALL"),"minQuantity":.text("3"),"computePrice":.text("FIXED"),"fixedPrice":.text("80")],linkedTo:list)
        try admin.setDefaultPriceList(list["id"])
        let now = try PricingEngine.date("2026-12-31T23:59:59Z")
        func line(_ quantity: String = "1.5",_ price: String? = nil,_ p: NativeRecord? = nil) -> OrderLineInput { OrderLineInput(productID:(p ?? product)["id"].string,quantity:quantity,unitPrice:price) }
        func create(_ actor: CRMService = owner,_ inputs: [OrderLineInput]? = nil,_ header: [String:SQLValue] = [:],_ date: Date? = nil) throws -> NativeRecord {
            let lines = inputs ?? [line()]
            return try actor.saveOrder(original:nil,accountID:account["id"].string,header:header,lines:{ offset in Array(lines.dropFirst(offset).prefix(100)) },now:date ?? now)
        }
        var order = try create(owner,nil,["contactId":contact["id"],"requestedDeliveryDate":.text("2027-01-15")])
        try check(order["number"] == .text("ORD-2026-0001") && order["currency"] == .text("JPY") && order["ownerId"] == .text(owner.identity.id),"number, context and owner snapshot")
        try check(order["subtotal"] == .text("150.38") && order["vatTotal"] == .text("15.04") && order["grandTotal"] == .text("165.42"),"fractional quantity and per-line tax rounding")
        try check(order["shipping_street"] == account["billing_street"] && order["shipping_city"] == account["billing_city"] && order["requestedDeliveryDate"] == .text("2027-01-15T00:00:00Z"),"billing fallback and UTC date")
        try check(try owner.orderLines(order).rows[0]["unitPriceOverridden"] == .integer(0),"follow price list marker")
        try rejects("other account contact") { _ = try create(owner,nil,["contactId":wrongContact["id"]]) }
        try rejects("invalid calendar day") { _ = try create(owner,nil,["requestedDeliveryDate":.text("2027-02-30")]) }
        try rejects("protected header") { _ = try create(owner,nil,["status":.text("PAID")]) }
        try rejects("unauthorized account create") { _ = try create(outsider) }
        try rejects("partner create") { _ = try create(partner) }
        try check(try partner.orderLines(order).total == 1,"assigned partner reads order lines")
        try rejects("partner submit") { _ = try partner.submitOrder(order) }
        try rejects("outsider order read") { _ = try outsider.orderLines(order) }
        _ = try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":.text(outsider.identity.id)],actor:identity.id)
        try check(try outsider.orderLines(order).total == 1,"account watcher reads order")
        try rejects("account viewer not order creator") { _ = try outsider.submitOrder(order) }
        let stale = order
        order = try owner.saveOrder(original:order,accountID:account["id"].string,header:["note":.text(" 更新 "),"shipping_street":.null],lines:{ $0 == 0 ? [line("3")] : [] },now:now)
        try check(order["grandTotal"] == .text("264") && order["note"] == .text("更新") && order["shipping_street"] == .null,"quantity threshold and explicit shipping clear")
        try check(try owner.orderLines(order).rows[0]["listPrice"] == .text("80"),"price list rule applied")
        try rejects("stale draft") { _ = try owner.saveOrder(original:stale,accountID:account["id"].string,header:[:],lines:{ _ in [] }) }
        try rejects("immutable account") { _ = try owner.saveOrder(original:order,accountID:otherAccount["id"].string,header:[:],lines:{ _ in [] }) }
        for qty in ["0","-1","0.00001","10000000000"] { try rejects("invalid quantity "+qty) { _ = try create(owner,[line(qty)]) } }
        try rejects("negative price") { _ = try create(owner,[line("1","-1")]) }
        try rejects("monetary overflow") { _ = try create(owner,[line("9999999999.9999","9999999999999999.99")]) }
        let empty = try create(owner,[])
        try check(try owner.orderLines(empty).total == 0 && empty["grandTotal"] == .text("0"),"empty draft permitted")
        try rejects("no lines submit") { _ = try owner.submitOrder(empty) }
        try owner.deleteOrder(empty); try check(try db.get(empty.model,key:["id":empty["id"]]) == nil,"draft delete")
        var discounted = try create(owner,[line("3","70")])
        discounted = try owner.submitOrder(discounted,now:now)
        try check(discounted["status"] == .text("PENDING_APPROVAL") && discounted["approvalRequestedAt"] != .null,"rep below list requires approval")
        try rejects("manager cannot withdraw another user's submission") { _ = try manager.changeOrder(discounted,action:"withdraw") }
        try rejects("rep cannot approve") { _ = try owner.changeOrder(discounted,action:"approve") }
        try rejects("reject note required") { _ = try manager.changeOrder(discounted,action:"reject",note:" ") }
        let staleApproval = discounted
        discounted = try manager.changeOrder(discounted,action:"reject",note:"値引き理由を確認")
        try check(discounted["status"] == .text("DRAFT") && discounted["approvalRequestedAt"] == .null && discounted["approvalNote"] == .text("値引き理由を確認"),"rejection records note and returns draft")
        discounted = try owner.submitOrder(discounted,now:now)
        try rejects("outdated approval") { _ = try manager.changeOrder(staleApproval,action:"approve") }
        discounted = try manager.changeOrder(discounted,action:"approve",note:"承認")
        try check(discounted["status"] == .text("READY") && discounted["approvedBy"] == .text(manager.identity.id),"manager approves")
        try rejects("ready cannot edit") { _ = try owner.saveOrder(original:discounted,accountID:account["id"].string,header:[:],lines:{ _ in [] }) }
        try rejects("ready cannot delete") { try owner.deleteOrder(discounted) }
        discounted = try owner.changeOrder(discounted,action:"reopen")
        try check(discounted["status"] == .text("DRAFT") && discounted["approvedAt"] == .null && discounted["approvedBy"] == .null && discounted["approvalRequestedAt"] == .null,"reopen clears approval metadata")
        discounted = try owner.submitOrder(discounted,now:now); discounted = try owner.changeOrder(discounted,action:"withdraw")
        try check(discounted["status"] == .text("DRAFT"),"creator withdrawal")
        let free = try create(manager,[line("1","0")])
        var ready = try manager.submitOrder(free,now:now)
        try check(ready["status"] == .text("READY") && ready["grandTotal"] == .text("0"),"manager bypasses approval; zero override preserved")
        try rejects("rep cannot advance") { _ = try owner.changeOrder(ready,action:"advance",to:"SENT") }
        try rejects("backward advance") { _ = try manager.changeOrder(ready,action:"advance",to:"DRAFT") }
        ready = try manager.changeOrder(ready,action:"advance",to:"DELIVERED")
        try check(ready["status"] == .text("DELIVERED"),"forward skipping permitted")
        ready = try manager.changeOrder(ready,action:"advance",to:"PAID")
        try rejects("paid is final") { _ = try admin.changeOrder(ready,action:"cancel") }
        var retry = try create(manager); retry = try db.update(retry,changes:["status":.text("SYNC_FAILED")],actor:identity.id)
        retry = try manager.changeOrder(retry,action:"retry"); try check(retry["status"] == .text("READY"),"retry failed sync")
        retry = try db.update(retry,changes:["externalRef":.text("EXT")],actor:identity.id)
        try rejects("external reference blocks reopen") { _ = try manager.changeOrder(retry,action:"reopen") }
        retry = try manager.changeOrder(retry,action:"cancel"); try check(retry["status"] == .text("CANCELLED"),"manager cancellation")
        var ext = try create(manager); ext = try db.update(ext,changes:["source":.text("EXTERNAL")],actor:identity.id)
        for action in OrderWorkflow.actions { try check(!admin.orderCan(ext,action),"external order read only "+action) }
        try check(try owner.orderLines(ext).total == 1,"external order is readable by account owner")
        let buffer = try admin.makeOrderDraft(order); let countBefore = try admin.orderLines(order).total
        let row = try buffer.page()[0]; let quote = try owner.orderQuote(line("7"),context:owner.orderContext(order),date:now)
        try buffer.save(input:quote.input,quote:quote,id:row.id)
        try check(try admin.orderLines(order).total == countBefore && admin.orderLines(order).rows[0]["quantity"] == .text("3"),"unsaved draft does not touch business data")
        let scratchPath = try autoreleasepool { () throws -> URL in let draft = try OrderDraftStore(); let url = draft.url; try check(FileManager.default.fileExists(atPath:url.path),"private draft exists"); return url }
        try check(!FileManager.default.fileExists(atPath:scratchPath.path),"draft discarded on release")
        let bigInputs = Array(repeating:line("1","0.01"),count:103)
        let big = try create(owner,bigInputs)
        try check(try owner.orderLines(big).total == 103 && owner.orderLines(big,offset:100).rows.count == 3 && big["subtotal"] == .text("1.03"),"103-line bounded save and sum")
        let bigDraft = try owner.makeOrderDraft(big); let last = try bigDraft.page(offset:100).last!
        try bigDraft.move(last.id,direction:-1); try check(try bigDraft.page(offset:100)[1].id == last.id,"draft move")
        try bigDraft.remove(last.id); try check(try bigDraft.count() == 102,"draft remove")
        let originalPrice = product
        product = try db.update(product,changes:["status":.text("DRAFT")],actor:identity.id)
        try rejects("inactive at submit") { _ = try owner.submitOrder(order) }
        try check(try refresh(order).revision == order.revision && owner.orderLines(order).rows[0]["quantity"] == .text("3"),"failed submit preserves lines/version")
        product = try db.update(product,changes:["status":originalPrice["status"],"unit_price":.text("120")],actor:identity.id)
        var reprice = try create(owner,[line("1")]); product = try db.update(product,changes:["unit_price":.text("200")],actor:identity.id)
        reprice = try owner.submitOrder(reprice,now:now)
        try check(try owner.orderLines(reprice).rows[0]["unitPrice"] == .text("200"),"submit reprices current catalog")
        let alternate = try save("crm_PriceLists",["name":.text("別価格表"),"currency":.text("USD")]); _ = try db.update(try refresh(account),changes:["pricelist_id":alternate["id"]],actor:identity.id)
        try check(try owner.orderContext(accountID:account["id"].string).listID == alternate["id"].string && owner.orderContext(order).listID == list["id"].string,"order retains original price context")
        _ = try db.update(try refresh(account),changes:["pricelist_id":.null],actor:identity.id)
        try admin.setDefaultPriceList(.null)
        let usd = try save("crm_Products",["type":.text("PRODUCT"),"name":.text("ドル商品"),"unit_price":.text("10"),"currency":.text("USD"),"status":.text("ACTIVE")])
        try rejects("missing currency rate") { _ = try create(owner,[line("1",nil,usd)]) }
        _ = try save("ExchangeRate",["fromCurrency":.text("USD"),"toCurrency":.text("JPY"),"rate":.text("150"),"effectiveDate":.text("2026-12-31T00:00:00Z")])
        let converted = try create(owner,[line("1",nil,usd)])
        try check(converted["grandTotal"] == .text("1500") && converted["currency"] == .text("JPY"),"fallback product currency converted to order currency")
        let seriesFields = try db.schema.model("NumberSeries").fields.map(\.name)
        var series = try db.page("NumberSeries",fields:seriesFields,equal:["scope":.text("order")]).rows[0]
        let beforeCounter = series["counter"]
        try rejects("settings manager denied") { _ = try manager.saveOrderSettings(series,name:"受注",template:"NEW-{####}",reset:"NEVER",active:true,emails:true) }
        try rejects("yearly requires year in template") { _ = try admin.saveOrderSettings(series,name:"受注",template:"NEW-{####}",reset:"YEARLY",active:true,emails:true) }
        series = try admin.saveOrderSettings(series,name:"受注",template:"ORD-{YYYY}-{####}",reset:"YEARLY",active:false,emails:false)
        try rejects("no active series") { _ = try create() }
        try check(try refresh(series)["counter"] == beforeCounter,"disabled series doesn't consume counter")
        series = try admin.saveOrderSettings(series,name:"受注",template:"ORD-{YYYY}-{####}",reset:"YEARLY",active:true,emails:false)
        let nextYear = try create(owner,nil,[:],PricingEngine.date("2027-01-01T00:00:00Z"))
        try check(nextYear["number"] == .text("ORD-2027-0001"),"yearly reset at UTC midnight")
        series = try refresh(series); series = try admin.saveOrderSettings(series,name:"通し番号",template:"ALL-{#####}",reset:"NEVER",active:true,emails:false)
        let never = try create(owner,nil,[:],PricingEngine.date("2028-01-01T00:00:00Z"))
        try check(never["number"] == .text("ALL-00002"),"NEVER counter doesn't reset")
        // Simulate a changed template reproducing a prior number; counter must roll back.
        series = try refresh(series); series = try db.update(series,changes:["template":.text("ALL-{#####}"),"counter":.integer(1)],actor:identity.id)
        try rejects("duplicate number") { _ = try create(owner,nil,[:],PricingEngine.date("2028-01-02T00:00:00Z")) }
        try check(try refresh(series)["counter"] == .integer(1),"number collision consumes nothing")
        series = try db.update(try refresh(series),changes:["counter":.integer(100)],actor:identity.id)
        // Inject failure in the live insert after staging/pricing: header, old lines, audit and sequence survive unchanged.
        var raw: OpaquePointer?; guard sqlite3_open(db.url.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test DB") }; defer { sqlite3_close(raw) }
        func sql(_ s: String) throws { guard sqlite3_exec(raw,s,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test SQL: "+String(cString:sqlite3_errmsg(raw))) } }
        func scalar(_ sql: String) throws -> Int {
            var s: OpaquePointer?; guard sqlite3_prepare_v2(raw,sql,-1,&s,nil) == SQLITE_OK else { throw NativeDBError.message("test select") }; defer { sqlite3_finalize(s) }
            guard sqlite3_step(s) == SQLITE_ROW else { throw NativeDBError.message("test scalar") }; return Int(sqlite3_column_int64(s,0))
        }
        try check(try scalar("SELECT count(*) FROM native_outbox WHERE event='orders.approval_requested'") == 6,"one queued request per active manager/admin per submission")
        try check(try scalar("SELECT count(*) FROM native_outbox WHERE event='orders.approval_decided'") == 2,"creator decision notifications queued")
        let silent = try create(owner,[line("1","0")]); _ = try owner.submitOrder(silent,now:now)
        try check(try scalar("SELECT count(*) FROM native_outbox WHERE event LIKE 'orders.%'") == 8,"disabled notifications create no events")
        try sql("CREATE TRIGGER order_test_fail BEFORE INSERT ON crm_OrderLines WHEN NEW.quantity='9' BEGIN SELECT RAISE(ABORT,'injected order failure'); END;")
        let beforeAudit = try db.auditCount("crm_Orders"); let beforeOrder = try refresh(order)
        try rejects("draft replacement failure") { _ = try owner.saveOrder(original:beforeOrder,accountID:account["id"].string,header:["note":.text("must roll back")],lines:{ _ in [line("9")] }) }
        try check(try refresh(order).revision == beforeOrder.revision && refresh(order)["note"] == .text("更新") && owner.orderLines(order).rows[0]["quantity"] == .text("3") && db.auditCount("crm_Orders") == beforeAudit,"failed replacement atomic")
        let counterBeforeFailure = try refresh(series)["counter"]
        try rejects("new order failure") { _ = try create(owner,[line("9")]) }
        try check(try refresh(series)["counter"] == counterBeforeFailure && db.auditCount("crm_Orders") == beforeAudit,"failed create rolls back sequence and audit")
        try sql("DROP TRIGGER order_test_fail")
        let secondDB = try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let second = CRMService(db:secondDB,identity:identity)
        let concurrentInput = line("1"); let group = DispatchGroup(); let resultLock = NSLock()
        final class Results { var numbers: [String] = []; var errors: [String] = [] }
        let results = Results()
        for service in [owner,second] {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let saved = try service.saveOrder(original:nil,accountID:account["id"].string,header:[:],lines:{ $0 == 0 ? [concurrentInput] : [] },now:now)
                    resultLock.lock(); results.numbers.append(saved["number"].string); resultLock.unlock()
                } catch { resultLock.lock(); results.errors.append(error.localizedDescription); resultLock.unlock() }
            }
        }
        group.wait()
        try check(results.errors.isEmpty && results.numbers.count == 2 && Set(results.numbers).count == 2,"two concurrent connections allocate unique committed numbers")
        try check(try owner.historyText(try refresh(discounted)).contains("受注の申請を取り下げ") && owner.historyText(order).contains("明細数"),"Japanese order status and line history")
        try rejects("generic form cannot bypass order save") { _ = try owner.save(.orders,original:order,input:["grandTotal":.text("1")]) }
        try owner.deleteOrder(big); try check(try db.page("crm_OrderLines",fields:[],equal:["orderId":big["id"]]).total == 0,"draft deletion cascades lines")
        try check(try db.integrityCheck(),"DB integrity")
        print("{\"ok\":true,\"suite\":\"CRMOrders\",\"checks\":\(checks)}")
    }
}
