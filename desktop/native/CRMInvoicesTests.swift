import Foundation
import SQLite3

@main enum CRMInvoicesTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    static func main() async {
        do { try run(); try sortTests(); try await fxTests(); print("{\"ok\":true,\"suite\":\"CRMInvoices\",\"checks\":\(checks)}") }
        catch { FileHandle.standardError.write(Data("CRMInvoicesTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-InvoicesTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        func user(_ role: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(role),"email":.text(UUID().uuidString+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:role,partnerAccountID:nil))
        }
        func refresh(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        let owner = try user("user"); let outsider = try user("user"); let manager = try user("manager"); let partner = try user("partner")
        var account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("請求検証株式会社"),"assigned_to":.text(owner.identity.id),"partnerUserId":.text(partner.identity.id),"billing_street":.text("発行時の住所"),"vat":.text("登録番号")],actor:identity.id)
        let otherAccount = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("他社")],actor:identity.id)
        var tax = try admin.saveInvoiceTaxRate(original:nil,input:["name":.text("消費税10%"),"rate":.text("10")])
        var series = try admin.saveInvoiceSeries(original:nil,input:["name":.text("標準採番"),"prefixTemplate":.text("請求-{YYYY}-{####}"),"resetPolicy":.text("YEARLY")])
        let header: [String:SQLValue] = ["accountId":account["id"],"currency":.text("JPY"),"type":.text("INVOICE"),"publicNotes":.text("日本語のご案内\n二行目"),"internalNotes":.text("社内メモ")]
        func line(_ quantity: String = "1.5",_ price: String = "100.25",_ discount: String = "0",_ rate: String? = nil) -> InvoiceLineInput {
            .init(productID:nil,description:"日本語の明細",quantity:quantity,unitPrice:price,discountPercent:discount,taxRateID:rate ?? tax["id"].string)
        }
        func create(_ service: CRMService = owner,_ lines: [InvoiceLineInput]? = nil,_ overrides: [String:SQLValue] = [:]) throws -> NativeRecord {
            let input = lines ?? [line()]
            return try service.saveInvoice(original:nil,header:header.merging(overrides) { _,n in n },lines:{ Array(input.dropFirst($0).prefix(100)) })
        }
        let now = try PricingEngine.date("2026-12-31T23:59:59Z")
        var invoice = try create()
        try check(invoice["number"] == .null && invoice["status"] == .text("DRAFT") && invoice["grandTotal"] == .text("165.42") && invoice["balanceDue"] == .text("165.42"),"draft has exact rounded totals and no allocated number")
        try check(try refresh(series)["counter"] == .integer(0),"creating does not consume number")
        try check(try partner.invoiceRows(invoice).total == 1,"partner reads assigned account invoice")
        try rejects("outsider reads") { _ = try outsider.invoiceRows(invoice) }
        _ = try db.insert("AccountWatchers",values:["account_id":account["id"],"user_id":.text(outsider.identity.id)],actor:identity.id)
        try rejects("account watcher cannot read another creator invoice") { _ = try outsider.invoiceRows(invoice) }
        try rejects("partner edits") { _ = try partner.saveInvoice(original:invoice,header:[:]) }
        try rejects("partner duplicates") { _ = try partner.duplicateInvoice(invoice) }
        let partnerDraft = try create(partner)
        try check(partnerDraft["createdBy"] == .text(partner.identity.id),"source permits account-authorized partner creation")
        try rejects("partner cannot issue own draft") { _ = try partner.issueInvoice(partnerDraft) }
        try rejects("create for unowned account") { _ = try create(owner,nil,["accountId":otherAccount["id"]]) }
        try rejects("empty invoice") { _ = try create(owner,[]) }
        try rejects("protected total injection") { _ = try create(owner,nil,["grandTotal":.text("1")]) }
        try rejects("manager settings") { _ = try manager.saveInvoiceTaxRate(original:nil,input:["name":.text("禁止"),"rate":.text("10")]) }
        try rejects("negative tax") { _ = try admin.saveInvoiceTaxRate(original:nil,input:["name":.text("不正"),"rate":.text("-1")]) }
        try rejects("yearly template lacks year") { _ = try admin.saveInvoiceSeries(original:nil,input:["name":.text("不正"),"prefixTemplate":.text("{####}")]) }
        try rejects("settings absent") { _ = try owner.issueInvoice(invoice,now:now) }
        let settingsInput: [String:SQLValue] = ["baseCurrency":.text("JPY"),"defaultSeriesId":series["id"],"defaultTaxRateId":tax["id"],"defaultDueDays":.integer(14),"companyName":.text("日本語発行会社"),"companyAddress":.text("東京都1-2-3"),"companyCity":.text("新宿区"),"companyZip":.text("160-0000"),"companyCountry":.text("日本"),"companyRegNo":.text("法人番号"),"companyEmail":.text("billing@example.invalid")]
        try rejects("invalid settings days") { _ = try admin.saveInvoiceSettings(original:nil,input:settingsInput.merging(["defaultDueDays":.integer(0)]) { _,n in n }) }
        var settings = try admin.saveInvoiceSettings(original:nil,input:settingsInput)
        try check(settings["companyName"] == .text("日本語発行会社"),"supplier configuration stored")
        try rejects("second singleton settings") { _ = try admin.saveInvoiceSettings(original:nil,input:settingsInput) }
        let stale = invoice
        invoice = try owner.saveInvoice(original:invoice,header:["publicNotes":.text("更新")],lines:{ $0 == 0 ? [line("2","100","10")] : [] })
        try check(invoice["grandTotal"] == .text("198") && invoice["discountTotal"] == .text("20"),"discount applies before line rounding")
        try rejects("stale save") { _ = try owner.saveInvoice(original:stale,header:[:]) }
        try rejects("editing type") { _ = try owner.saveInvoice(original:invoice,header:["type":.text("PROFORMA")]) }
        for (q,p,d) in [("0","1","0"),("-1","1","0"),("1","-1","0"),("1","1","101"),("0.00001","1","0"),("1","10000000000","0"),("9999999999.9999","9999999999.9999","0")] {
            try rejects("invalid precision/range \(q),\(p),\(d)") { _ = try create(owner,[line(q,p,d)]) }
        }
        tax = try admin.saveInvoiceTaxRate(original:tax,input:["rate":.text("8")])
        invoice = try owner.issueInvoice(invoice,now:now)
        try check(invoice["number"] == .text("請求-2026-0001") && invoice["status"] == .text("ISSUED") && invoice["fxRateToBase"] == .text("1"),"issuance allocates number and same currency rate")
        try check(invoice["grandTotal"] == .text("194.4") && invoice["vatTotal"] == .text("14.4"),"issue recalculates current tax")
        try check(try owner.invoiceRows(invoice,model:"Invoice_Activity").rows.map { $0["action"].string } == ["CREATED","UPDATED","ISSUED"],"same-second events preserve insertion order")
        let issuedLine = try owner.invoiceRows(invoice).rows[0]
        try check(issuedLine["taxRateSnapshot"] == .text("8") && issuedLine["lineTotal"] == invoice["grandTotal"],"line amounts and header remain consistent after tax changes")
        try check(invoice["dueDate"] == .text("2027-01-14T23:59:59Z") && invoice["taxableSupplyDate"] == invoice["issueDate"],"default dates")
        account = try db.update(account,changes:["billing_street":.text("変更後の住所")],actor:identity.id)
        tax = try admin.saveInvoiceTaxRate(original:tax,input:["rate":.text("20")])
        let frozen = try owner.makeInvoiceDraft(invoice)
        try check(try frozen.totals().grandTotal == "194.4" && invoice["billingSnapshot"].string.contains("発行時の住所"),"issued tax and billing snapshots do not follow later changes")
        try rejects("issued edit") { _ = try owner.saveInvoice(original:invoice,header:["publicNotes":.text("変更")]) }
        try rejects("issued cancel") { _ = try owner.cancelInvoice(invoice) }
        try rejects("double issue") { _ = try owner.issueInvoice(invoice,now:now) }
        try rejects("delete used series") { try admin.deleteInvoiceConfiguration(try refresh(series)) }
        try rejects("delete used tax") { try admin.deleteInvoiceConfiguration(tax) }
        let duplicate = try owner.duplicateInvoice(invoice)
        try check(duplicate["number"] == .null && duplicate["status"] == .text("DRAFT") && duplicate["paidTotal"] == .text("0") && duplicate["originalInvoiceId"] == invoice["id"] && duplicate["grandTotal"] == invoice["grandTotal"],"duplicate clears legal/payment fields and keeps original link")
        try check(try owner.invoiceRows(duplicate).rows[0]["taxRateSnapshot"] == .null,"duplicate clears frozen tax")
        try check(try owner.cancelInvoice(duplicate)["status"] == .text("CANCELLED"),"cancel draft")
        let bypass = CRMModule(model:"Invoices",title:"請求書",singular:"請求書",entity:"invoice",nameFields:[],columns:[],fields:[EditorField("grandTotal","合計")])
        try rejects("generic save cannot bypass invoice workflow") { _ = try admin.save(bypass,original:invoice,input:["grandTotal":.text("1")]) }
        try rejects("generic delete cannot remove invoice") { try admin.delete(invoice) }
        let stalePaid = invoice
        invoice = try owner.addInvoicePayment(invoice,amount:"50.25",paidAt:now,method:"銀行振込",reference:"振込番号",note:"一部入金")
        try check(invoice["paidTotal"] == .text("50.25") && invoice["balanceDue"] == .text("144.15") && invoice["status"] == .text("PARTIALLY_PAID"),"partial payment exact totals")
        try rejects("stale payment") { _ = try owner.addInvoicePayment(stalePaid,amount:"1",paidAt:now,method:"現金") }
        try rejects("zero payment") { _ = try owner.addInvoicePayment(invoice,amount:"0",paidAt:now,method:"現金") }
        try rejects("payment precision") { _ = try owner.addInvoicePayment(invoice,amount:"0.001",paidAt:now,method:"現金") }
        invoice = try owner.addInvoicePayment(invoice,amount:"200",paidAt:now,method:"現金")
        try check(invoice["paidTotal"] == .text("250.25") && invoice["balanceDue"] == .text("0") && invoice["status"] == .text("PAID"),"overpayment retained and balance clamped")
        let payments = try owner.invoiceRows(invoice,model:"Invoice_Payments").rows
        let overpaid = payments.first { $0["amount"] == .text("200") }!
        try rejects("manager deletes payment") { _ = try manager.deleteInvoicePayment(overpaid,invoice:invoice) }
        invoice = try admin.deleteInvoicePayment(overpaid,invoice:invoice)
        try check(invoice["status"] == .text("PARTIALLY_PAID") && invoice["paidTotal"] == .text("50.25"),"payment delete restores partial balance")
        invoice = try admin.deleteInvoicePayment(payments.first { $0["amount"] == .text("50.25") }!,invoice:invoice)
        try check(invoice["status"] == .text("ISSUED") && invoice["paidTotal"] == .text("0"),"removing all payments restores issued")
        let usd = try create(owner,nil,["currency":.text("USD")])
        try rejects("foreign currency without rate") { _ = try owner.issueInvoice(usd,now:now) }
        try rejects("wrong direction FX") { _ = try owner.issueInvoice(usd,fx:InvoiceFXQuote(from:"JPY",to:"USD",rate:"150",settingsRevision:settings.revision),now:now) }
        let staleSettings = settings; settings = try admin.saveInvoiceSettings(original:settings,input:["companyName":.text("変更した発行会社")])
        try rejects("stale settings FX") { _ = try owner.issueInvoice(usd,fx:InvoiceFXQuote(from:"USD",to:"JPY",rate:"150",settingsRevision:staleSettings.revision),now:now) }
        let fxIssued = try owner.issueInvoice(usd,fx:InvoiceFXQuote(from:"USD",to:"JPY",rate:"150.12345678",settingsRevision:settings.revision),now:now)
        try check(fxIssued["baseCurrency"] == .text("JPY") && fxIssued["fxRateToBase"] == .text("150.12345678"),"foreign currency snapshot without changing invoice currency")
        let nextYear = try owner.issueInvoice(create(),now:PricingEngine.date("2027-01-01T00:00:00Z"))
        try check(nextYear["number"] == .text("請求-2027-0001"),"UTC year reset")
        series = try admin.saveInvoiceSeries(original:refresh(series),input:["resetPolicy":.text("NEVER"),"prefixTemplate":.text("連番-{#####}")])
        let never = try owner.issueInvoice(create(),now:PricingEngine.date("2028-01-01T00:00:00Z"))
        try check(never["number"] == .text("連番-00002"),"NEVER retains counter across years")
        let big = try create(owner,Array(repeating:line("1","0.01"),count:103))
        try check(try owner.invoiceRows(big).rows.count == 100 && owner.invoiceRows(big,offset:100).rows.count == 3 && big["grandTotal"] == .text("1.03"),"103 lines page and aggregate without retaining all rows")
        let displayed = try owner.invoiceDisplayPage(big)
        let displayedLast = try owner.invoiceDisplayPage(big,offset:100)
        try check(displayed.rows.count == 100 && displayed.total == 103 && displayed.offset == 0 && displayedLast.rows.count == 3 && displayedLast.offset == 100,"direct invoice reader bounds first and last pages")
        try check(try displayed.rows.map(\.id) == owner.invoiceRows(big).rows.map { $0["id"].string },"direct reader keeps stored line IDs and ordering")
        try check(try owner.invoiceDisplayPage(big,offset:999).offset == 100 && owner.invoiceDisplayPage(big,offset:-100).offset == 0,"direct reader clamps out-of-range pages")
        try check(try partner.invoiceDisplayPage(big,offset:100).rows.count == 3,"partner can page authorized invoice without editing permission")
        try rejects("direct reader preserves unauthorized denial") { _ = try outsider.invoiceDisplayPage(big) }
        let staged = try owner.makeInvoiceDraft(big); let last = try staged.page(offset:100).last!
        try staged.move(last.id,direction:-1); try check(try staged.page(offset:100)[1].id == last.id,"staged line reorder")
        try staged.remove(last.id); try check(try staged.count() == 102 && owner.invoiceRows(big).total == 103,"unsaved removal isolated")
        let scratch = try autoreleasepool { () throws -> URL in let draft = try InvoiceDraftStore(); let attrs = try FileManager.default.attributesOfItem(atPath:draft.url.path); try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600,"private scratch permissions"); return draft.url }
        try check(!FileManager.default.fileExists(atPath:scratch.path),"scratch removed on deinit")
        var raw: OpaquePointer?; guard sqlite3_open(db.url.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test database") }; defer { sqlite3_close(raw) }
        func sql(_ query: String) throws { guard sqlite3_exec(raw,query,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test SQL: "+String(cString:sqlite3_errmsg(raw))) } }
        let rollback = try create(); let counter = try refresh(series)["counter"]; let audit = try db.auditCount("Invoices")
        try sql("CREATE TRIGGER invoice_fail_issue BEFORE INSERT ON Invoice_Activity WHEN NEW.action='ISSUED' BEGIN SELECT RAISE(ABORT,'injected issuance failure'); END")
        try rejects("issuance failure") { _ = try owner.issueInvoice(rollback,now:now) }
        try check(try refresh(rollback).revision == rollback.revision && refresh(series)["counter"] == counter && db.auditCount("Invoices") == audit && owner.invoiceRows(rollback).rows[0]["taxRateSnapshot"] == .null,"failed issue rolls back number, line, invoice and audit")
        try sql("DROP TRIGGER invoice_fail_issue")
        try sql("CREATE TRIGGER invoice_fail_payment BEFORE INSERT ON Invoice_Activity WHEN NEW.action='PAYMENT_ADDED' BEGIN SELECT RAISE(ABORT,'injected payment failure'); END")
        try rejects("payment failure") { _ = try owner.addInvoicePayment(invoice,amount:"10",paidAt:now,method:"現金") }
        try check(try refresh(invoice).revision == invoice.revision && owner.invoiceRows(invoice,model:"Invoice_Payments").total == 0,"failed payment rolls back cash record and balances")
        try sql("DROP TRIGGER invoice_fail_payment")
        try sql("CREATE TRIGGER invoice_fail_line BEFORE INSERT ON Invoice_LineItems WHEN NEW.description='失敗させる' BEGIN SELECT RAISE(ABORT,'injected line failure'); END")
        var bad = line(); bad.description = "失敗させる"
        try rejects("replacement failure") { _ = try owner.saveInvoice(original:rollback,header:["publicNotes":.text("失敗")],lines:{ _ in [bad] }) }
        try check(try refresh(rollback).revision == rollback.revision && owner.invoiceRows(rollback).rows[0]["description"] == .text("日本語の明細"),"replacement restores original lines")
        try sql("DROP TRIGGER invoice_fail_line")
        series = try db.update(refresh(series),changes:["counter":.integer(1)],actor:identity.id)
        try rejects("duplicate numbering") { _ = try owner.issueInvoice(rollback,now:now) }
        try check(try refresh(series)["counter"] == .integer(1),"duplicate number doesn't consume counter")
        series = try db.update(refresh(series),changes:["counter":.integer(100)],actor:identity.id)
        let secondDB = try NativeDatabase(url:db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")); let second = CRMService(db:secondDB,identity:identity)
        let firstDraft = try create(); let secondDraft = try create(); let lock = NSLock(); let group = DispatchGroup()
        final class Results { var numbers:[String] = []; var errors:[String] = [] }; let result = Results()
        for (service,draft) in [(owner,firstDraft),(second,secondDraft)] {
            group.enter(); DispatchQueue.global().async { defer { group.leave() }
                do { let issued = try service.issueInvoice(draft,now:now); lock.lock(); result.numbers.append(issued["number"].string); lock.unlock() }
                catch { lock.lock(); result.errors.append(error.localizedDescription); lock.unlock() }
            }
        }
        group.wait(); try check(result.errors.isEmpty && Set(result.numbers).count == 2,"two concurrent issuances allocate different numbers")
        let japan = TimeZone(identifier:"Asia/Tokyo")!; let midnightEdge = try PricingEngine.date("2026-12-31T16:30:00Z")
        try check(ISO8601DateFormatter().string(from:InvoiceCalendar.today(midnightEdge,timeZone:japan)) == "2027-01-01T00:00:00Z","Japanese calendar date does not fall back to previous UTC day")
        try check(ISO8601DateFormatter().string(from:InvoiceCalendar.canonical(midnightEdge)) == "2026-12-31T00:00:00Z","imported calendar dates keep their stored day")
        for module in [CRMModule.invoices]+CRMModule.invoiceModules {
            let model = try db.schema.model(module.model)
            try check(module.fields.allSatisfy { model.field($0.key) != nil } && module.columns.flatMap(\.fields).allSatisfy { model.field($0) != nil },"invoice UI fields exist: \(module.model)")
        }
        let page = try owner.list(.invoices,linkedTo:account,matching:.equal("status",.text("DRAFT")))
        try check(!page.rows.isEmpty && page.rows.allSatisfy { $0.record["accountId"] == account["id"] && $0.record["status"] == .text("DRAFT") && $0.cells[0] == "下書き" && $0.cells[3] == "下書き" },"invoice list applies account/state filters and Japanese draft labels")
        try check(try outsider.list(.invoices).total == 0,"invoice navigation does not widen access")
        let numbered = try admin.list(.invoices,search:refresh(firstDraft)["number"].string)
        try check(numbered.rows.count == 1 && numbered.rows[0].record["id"] == firstDraft["id"],"invoice number search finds the issued record")
        let cancelledDraft = try owner.cancelInvoice(create())
        let cancelledRow = try owner.makeInvoiceDraft(cancelledDraft).page()[0]
        try check(cancelledRow.quote.rate == tax["rate"].string && cancelledRow.quote.amounts.lineTotal == cancelledDraft["grandTotal"].string,"cancelled drafts retain amounts and show linked unfrozen tax")
        let directCancelled = try owner.invoiceDisplayPage(cancelledDraft).rows[0]
        try check(directCancelled.quote.rate == cancelledRow.quote.rate && directCancelled.quote.amounts.lineTotal == cancelledRow.quote.amounts.lineTotal,"direct cancelled viewer matches stored amounts and unfrozen tax")
        let historical = try create()
        let historicalIssued = try owner.issueInvoice(historical,now:now)
        let historicalLine = try owner.invoiceRows(historicalIssued).rows[0]
        _ = try db.update(historicalLine,changes:["lineTotal":.text("123.45")],actor:identity.id,action:"test_imported_snapshot")
        let historicalFrozen = try owner.makeInvoiceDraft(historicalIssued).page()[0]
        try check(historicalFrozen.quote.amounts.lineTotal == "123.45","issued invoice viewer preserves stored imported amounts")
        let directHistorical = try owner.invoiceDisplayPage(historicalIssued).rows[0]
        try check(directHistorical.quote.amounts.lineTotal == "123.45" && directHistorical.quote.rate == historicalFrozen.quote.rate,"direct issued viewer preserves imported monetary and tax snapshots")
        let historicalPaid = try owner.addInvoicePayment(historicalIssued,amount:"1",paidAt:now,method:"現金")
        try rejects("direct paging after header revision changed") { _ = try owner.invoiceDisplayPage(historicalIssued) }
        try check(try owner.invoiceDisplayPage(historicalPaid).rows[0].quote.amounts.lineTotal == "123.45","direct reader resumes with refreshed header after payment")
        try check(try db.integrityCheck(),"database integrity")
        struct Reference: Decodable { let status:String; let creator:String; let role:String; let action:String; let allowed:Bool }
        let references = try JSONDecoder().decode([Reference].self,from:Data(contentsOf:resources.appendingPathComponent("build/invoice-workflow-reference.json")))
        for ref in references { guard InvoiceWorkflow.can(status:ref.status,creator:ref.creator,action:ref.action,actorID:"actor",role:ref.role) == ref.allowed else { throw NativeDBError.message("invoice source policy mismatch") } }
        print("{\"ok\":true,\"suite\":\"InvoicePolicyReference\",\"cases\":\(references.count)}")
    }
    static func sortTests() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-InvoiceSortTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
        let a = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("あさひ株式会社")],actor:identity.id)
        let b = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("さくら株式会社")],actor:identity.id)
        let outsider = try db.insert("Users",values:["name":.text("別担当"),"email":.text("sort@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
        // Reverse insertion order and alternating accounts ensure sorting happens
        // before the LIMIT, not merely inside the currently visible page.
        var fixtures: [NativeRecord] = []
        try db.transaction {
            for i in (0..<211).reversed() {
                let cents = String(format:"%02d",i%100)
                let amount = i >= 209 ? "999999999999.\(i == 209 ? "98" : "99")" : "\(i).\(cents)"
                let row = try db.insert("Invoices",values:["createdBy":.text(identity.id),"accountId":(i%2 == 0 ? a : b)["id"],"currency":.text("JPY"),"grandTotal":.text(amount),"number":i == 0 ? .null : .text(String(format:"検証-%03d",i)),"issueDate":i == 0 ? .null : .text("2026-11-14T00:\(String(format:"%02d",i/60)):\(String(format:"%02d",i%60))Z"),"dueDate":i == 0 ? .null : .text("2026-12-01T00:\(String(format:"%02d",i/60)):\(String(format:"%02d",i%60))Z"),"status":.text(i%2 == 0 ? "DRAFT" : "ISSUED")],actor:identity.id)
                fixtures.append(row)
            }
        }
        let ascending = Array(fixtures.reversed())
        func all(_ sort: InvoiceListSort, search: String = "", matching: RecordFilter = .all, linked: NativeRecord? = nil) throws -> [NativeRecord] {
            var records: [NativeRecord] = []; var offset = 0
            repeat {
                let page = try service.list(.invoices,search:search,offset:offset,linkedTo:linked,matching:matching,invoiceSort:sort)
                try check(page.rows.count <= 100,"sorted results bound each decoded page to 100")
                records += page.rows.map(\.record); offset += page.rows.count
                if offset >= page.total { break }
                guard !page.rows.isEmpty else { throw NativeDBError.message("unexpected empty page") }
            } while true
            return records
        }
        for field in [InvoiceListSort.Field.number,.issueDate,.dueDate,.grandTotal] {
            for descending in [false,true] {
                let result = try all(.init(field:field,descending:descending))
                let expected = descending ? Array(ascending.reversed()) : ascending
                try check(result.map { $0["id"] } == expected.map { $0["id"] },"all three pages match global \(field) \(descending), null and exact cents")
            }
        }
        for field in [InvoiceListSort.Field.account,.status] {
            for descending in [false,true] {
                let result = try all(.init(field:field,descending:descending))
                let key = field == .account ? "accountId" : "status"
                let first = field == .account ? a["id"] : .text("DRAFT")
                let second = field == .account ? b["id"] : .text("ISSUED")
                let expected: [SQLValue] = descending ? Array(repeating:second,count:105)+Array(repeating:first,count:106) : Array(repeating:first,count:106)+Array(repeating:second,count:105)
                try check(result.map { $0[key] } == expected && Set(result.map { $0["id"].string }).count == 211,"related name/status globally grouped with stable page ties")
            }
        }
        let filtered = try all(.init(field:.grandTotal,descending:true),matching:.equal("status",.text("DRAFT")),linked:a)
        try check(filtered.count == 106 && filtered.first?["grandTotal"] == .text("999999999999.99"),"account/state filters compose with exact sorted pages")
        let searched = try all(.init(field:.number,descending:false),search:"検証-20")
        try check(searched.count == 10 && searched.first?["number"] == .text("検証-200"),"number search composes with sorting")
        let defaultPage = try service.list(.invoices)
        try check(defaultPage.rows.first?.record["id"] == ascending.last?["id"],"default invoice order is newest issue date first")
        let other = CRMService(db:db,identity:.init(id:outsider["id"].string,role:"user",partnerAccountID:nil))
        for field in InvoiceListSort.Field.allCases { try check(try other.list(.invoices,invoiceSort:.init(field:field,descending:false)).total == 0,"sort \(field) preserves invoice authorization") }
        for (left,right,expected) in [("-000.0","0",0),("01.200","1.2",0),("-10","-2",-1),("0.001","0.01",-1),("9999999999999999.98","9999999999999999.99",-1),("1234567890123456789012345678901234567890.01","1234567890123456789012345678901234567890.02",-1)] {
            let l = Data(left.utf8); let r = Data(right.utf8)
            let comparison = l.withUnsafeBytes { lp in r.withUnsafeBytes { rp in NativeDecimalOrder.compare(lp,rp) } }
            let reverse = r.withUnsafeBytes { rp in l.withUnsafeBytes { lp in NativeDecimalOrder.compare(rp,lp) } }
            try check(comparison == expected && reverse == -expected,"exact signed decimal ordering \(left)/\(right)")
        }
        try rejects("invalid relation sort fields") { _ = try db.page("Invoices",fields:[],relatedSort:.init(model:"crm_Accounts",local:"accountId",foreign:"name",field:"name")) }
        try check(try db.integrityCheck(),"sort fixture integrity")
    }
    static func fxTests() async throws {
        let settings = NativeRecord(model:"Invoice_Settings",values:["baseCurrency":.text("JPY")],revision:8)
        let same = try await InvoiceFXClient.quote(currency:"JPY",settings:settings,request:{ _ in throw NativeDBError.message("network should not run") })
        try check(same.rate == "1","same currency does not request network")
        let quote = try await InvoiceFXClient.quote(currency:"USD",settings:settings,request:{ query in
            guard query.url?.host == "api.frankfurter.app", query.url?.query?.contains("from=USD") == true else { throw NativeDBError.message("unexpected FX URL") }
            return (Data("{\"rates\":{\"JPY\":150.123456789}}".utf8),HTTPURLResponse(url:query.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        try check(quote.rate == "150.12345679" && quote.settingsRevision == 8,"FX response rounds once to database precision")
        for (body,status) in [("{}",200),("{\"rates\":{\"JPY\":-1}}",200),("{\"rates\":{\"JPY\":0.000000001}}",200),("{\"rates\":{\"JPY\":150}}",503)] {
            var refused = false
            do { _ = try await InvoiceFXClient.quote(currency:"USD",settings:settings,request:{ query in (Data(body.utf8),HTTPURLResponse(url:query.url!,statusCode:status,httpVersion:nil,headerFields:nil)!) }) } catch { refused = true }
            try check(refused,"invalid FX response rejected")
        }
    }
}
