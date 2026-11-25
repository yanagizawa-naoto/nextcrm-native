import Foundation

extension CRMService {
    static let invoiceHeaderKeys = ["accountId","currency","issueDate","taxableSupplyDate","dueDate","bankName","bankAccount","iban","swift","variableSymbol","publicNotes","internalNotes"]
    static let invoiceCreateKeys = invoiceHeaderKeys + ["type","seriesId","originalInvoiceId"]

    func invoiceCan(_ invoice: NativeRecord, _ action: String) -> Bool {
        InvoiceWorkflow.can(status:invoice["status"].string,creator:invoice["createdBy"].string,action:action,actorID:identity.id,role:identity.role)
    }
    func invoiceAccess(_ record: NativeRecord, action: String? = nil) throws -> NativeRecord {
        guard record.model == "Invoices" else { throw NativeDBError.message("請求書を選択してください。") }
        try assertAccess("Invoices",id:record["id"].string)
        guard let current = try db.get("Invoices",key:["id":record["id"]]) else { throw NativeDBError.message("請求書が見つかりません。") }
        if let action {
            guard current.revision == record.revision else { throw NativeDBError.conflict }
            guard invoiceCan(current,action) else { throw NativeDBError.message("この請求書の状態または利用者では、この操作はできません。") }
        }
        return current
    }
    func invoiceSettings() throws -> NativeRecord? {
        try authenticated(); return try db.page("Invoice_Settings",fields:db.schema.model("Invoice_Settings").fields.map(\.name)).rows.first
    }
    func invoiceRows(_ invoice: NativeRecord, model: String = "Invoice_LineItems", offset: Int = 0) throws -> (rows:[NativeRecord],total:Int) {
        guard ["Invoice_LineItems","Invoice_Payments","Invoice_Activity","Invoice_Attachments"].contains(model) else { throw NativeDBError.message("請求書の一覧の種類が不正です。") }
        let current = try invoiceAccess(invoice)
        return try db.page(model,fields:db.schema.model(model).fields.map(\.name),equal:["invoiceId":current["id"]],offset:offset,sort:model == "Invoice_LineItems" ? "position" : model == "Invoice_Attachments" ? "uploadedAt" : "createdAt",insertionOrderForTies:model == "Invoice_Activity")
    }
    private func storedInvoiceLine(_ row: NativeRecord, invoice: NativeRecord) throws -> InvoiceDraftRow {
        let input = InvoiceLineInput.from(row)
        let rate = row["taxRateSnapshot"] != .null ? row["taxRateSnapshot"].string : invoice["number"] == .null ? try input.taxRateID.flatMap { try db.get("Invoice_TaxRates",key:["id":.text($0)]) }?["rate"].string ?? "0" : "0"
        let quote = InvoiceLineQuote(rate:rate,amounts:.init(lineSubtotal:row["lineSubtotal"].string,lineVat:row["lineVat"].string,lineTotal:row["lineTotal"].string),lineID:row["id"].string)
        return InvoiceDraftRow(id:row["id"].string,input:input,quote:quote)
    }
    /// Read-only viewing never needs a complete editable copy. Check the header
    /// revision and access in the same transaction as the bounded line page.
    func invoiceDisplayPage(_ record: NativeRecord, offset: Int = 0) throws -> (rows:[InvoiceDraftRow],total:Int,offset:Int) {
        try db.transaction {
            let current = try invoiceAccess(record)
            guard current.revision == record.revision else { throw NativeDBError.conflict }
            let start = max(0,offset)
            var page = try invoiceRows(current,offset:start)
            let clamped = min(start,max(0,(max(1,page.total)-1)/100*100))
            if clamped != start { page = try invoiceRows(current,offset:clamped) }
            return (try page.rows.map { try storedInvoiceLine($0,invoice:current) },page.total,clamped)
        }
    }
    func invoiceQuote(_ input: InvoiceLineInput, snapshot: String? = nil, lineID: String? = nil) throws -> InvoiceLineQuote {
        try authenticated()
        guard !input.description.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw NativeDBError.message("明細の品名・内容を入力してください。") }
        if let id = input.productID, try db.get("crm_Products",key:["id":.text(id)]) == nil { throw NativeDBError.message("明細の商品が見つかりません。") }
        let rate: String
        if let snapshot { rate = snapshot }
        else if let id = input.taxRateID {
            guard let tax = try db.get("Invoice_TaxRates",key:["id":.text(id)]) else { throw NativeDBError.message("税率が見つかりません。") }; rate = tax["rate"].string
        } else { rate = "0" }
        let quote = try InvoiceLineQuote(rate:rate,amounts:InvoiceMath.line(input.math(rate:rate)),lineID:lineID)
        try db.validateFieldValues("Invoice_LineItems",quote.values(input,snapshot:snapshot != nil)); return quote
    }
    private func invoiceFields(_ input: [String:SQLValue], creating: Bool) throws -> [String:SQLValue] {
        guard input.keys.allSatisfy((creating ? Self.invoiceCreateKeys : Self.invoiceHeaderKeys).contains) else { throw NativeDBError.message("変更できない請求書の項目が含まれています。") }
        if let id = input["accountId"] { try assertAccess("crm_Accounts",id:id.string,write:true) }
        if let id = input["originalInvoiceId"], id != .null { try assertAccess("Invoices",id:id.string) }
        if let code = input["currency"] { guard code.string.count == 3 else { throw NativeDBError.message("3文字の通貨コードを選択してください。") } }
        if let type = input["type"] { guard InvoiceWorkflow.types.contains(type.string) else { throw NativeDBError.message("請求書の種類が不正です。") } }
        if let id = input["seriesId"], id != .null, try db.get("Invoice_Series",key:["id":id]) == nil { throw NativeDBError.message("採番系列が見つかりません。") }
        try db.validateFieldValues("Invoices",input); return input
    }
    private func invoiceTotals(_ totals: InvoiceMath.Total, paid: String = "0") throws -> [String:SQLValue] {
        let balance = try PriceDecimal.calculate(PriceDecimal.parse(totals.grandTotal),"-",PriceDecimal.parse(paid))
        let values: [String:SQLValue] = ["subtotal":.text(totals.subtotal),"discountTotal":.text(totals.discountTotal),"vatTotal":.text(totals.vatTotal),"grandTotal":.text(totals.grandTotal),"balanceDue":.text(PriceDecimal.string(max(0,balance)))]
        try db.validateFieldValues("Invoices",values); return values
    }
    func invoiceActivity(_ invoice: NativeRecord, action: String, meta: [String:String] = [:]) throws {
        let json = String(decoding:try JSONEncoder().encode(meta),as:UTF8.self)
        _ = try db.insert("Invoice_Activity",values:["invoiceId":invoice["id"],"actorId":.text(identity.id),"action":.text(action),"meta":meta.isEmpty ? .null : .text(json)],actor:identity.id)
    }
    /// Input may page directly from the old invoice. Stage all rows before replacing it.
    func saveInvoice(original: NativeRecord?, header: [String:SQLValue], lines: ((Int) throws -> [InvoiceLineInput])? = nil) throws -> NativeRecord {
        try authenticated()
        return try db.transaction {
            let current = try original.map { try invoiceAccess($0,action:"edit") }
            var fields = try invoiceFields(header,creating:current == nil)
            if current == nil {
                guard fields["accountId"] != nil, fields["currency"] != nil, lines != nil else { throw NativeDBError.message("取引先・通貨・明細を入力してください。") }
                fields["createdBy"] = .text(identity.id); fields["status"] = .text("DRAFT")
            }
            let buffer: InvoiceDraftStore?
            if let lines {
                let staged = try InvoiceDraftStore(); var offset = 0
                while true {
                    let page = try lines(offset); guard page.count <= 100 else { throw NativeDBError.message("明細は100件ずつ処理してください。") }
                    for line in page { try autoreleasepool { _ = try staged.save(input:line,quote:invoiceQuote(line)) } }
                    offset += page.count; if page.count < 100 { break }
                }
                guard try staged.count() > 0 else { throw NativeDBError.message("明細を1行以上追加してください。") }
                fields.merge(try invoiceTotals(staged.totals(),paid:current?["paidTotal"].string ?? "0")) { _,n in n }; buffer = staged
            } else { buffer = nil }
            var invoice = try current ?? db.insert("Invoices",values:fields,actor:identity.id)
            if let buffer {
                if current != nil {
                    while true { let page = try db.page("Invoice_LineItems",fields:[],equal:["invoiceId":invoice["id"]]); if page.rows.isEmpty { break }; for row in page.rows { try db.remove(row,actor:identity.id,action:"invoice_line_replace") } }
                }
                var offset = 0
                while true {
                    let page = try buffer.page(offset:offset)
                    for (index,row) in page.enumerated() { try autoreleasepool {
                        var values = row.quote.values(row.input); values["invoiceId"] = invoice["id"]; values["position"] = .integer(Int64(offset+index))
                        _ = try db.insert("Invoice_LineItems",values:values,actor:identity.id)
                    } }
                    offset += page.count; if page.count < 100 { break }
                }
            }
            if let current { invoice = try db.update(current,changes:fields,actor:identity.id,action:"invoice_update") }
            try invoiceActivity(invoice,action:current == nil ? "CREATED" : "UPDATED"); return invoice
        }
    }
    func makeInvoiceDraft(_ record: NativeRecord) throws -> InvoiceDraftStore {
        try db.transaction {
            let current = try invoiceAccess(record); guard current.revision == record.revision else { throw NativeDBError.conflict }
            let result = try InvoiceDraftStore(); var offset = 0
            while true {
                let page = try invoiceRows(current,offset:offset)
                for row in page.rows { try autoreleasepool {
                    let input = InvoiceLineInput.from(row)
                    let quote: InvoiceLineQuote
                    if current["status"] == .text("DRAFT") { quote = try invoiceQuote(input,lineID:row["id"].string) }
                    else { quote = try storedInvoiceLine(row,invoice:current).quote }
                    try result.save(input:input,quote:quote)
                } }
                offset += page.rows.count; if page.rows.isEmpty || offset >= page.total { break }
            }
            return result
        }
    }
    func invoiceFXContext(_ record: NativeRecord) throws -> (invoice:NativeRecord,settings:NativeRecord) {
        let invoice = try invoiceAccess(record,action:"issue")
        guard let settings = try invoiceSettings() else { throw NativeDBError.message("管理設定の「請求書」で初期設定を行ってください。") }
        return (invoice,settings)
    }
    private func invoiceNumber(seriesID: SQLValue, now: Date) throws -> String {
        guard let series = try db.get("Invoice_Series",key:["id":seriesID]) else { throw NativeDBError.message("請求書の採番系列を設定してください。") }
        let year = OrderNumber.year(now); let reset = series["resetPolicy"] == .text("YEARLY") && series["currentYear"] != .integer(Int64(year))
        guard case let .integer(old) = series["counter"], reset || old < Int32.max else { throw NativeDBError.message("請求書番号の上限に達しています。") }
        let counter = reset ? 1 : old+1; let number = OrderNumber.format(series["prefixTemplate"].string,year:year,counter:counter)
        guard !number.isEmpty, try db.page("Invoices",fields:[],equal:["seriesId":seriesID,"number":.text(number)]).total == 0 else { throw NativeDBError.message("同じ請求書番号が存在します。採番設定を確認してください。") }
        _ = try db.update(series,changes:["counter":.integer(counter),"currentYear":.integer(Int64(year))],actor:identity.id,action:"invoice_allocate")
        return number
    }
    /// Number, current tax rates, billing snapshot, totals and activity are committed together.
    /// PDF creation is intentionally separate: its failure must not un-issue a saved invoice.
    func issueInvoice(_ record: NativeRecord, dates: [String:SQLValue] = [:], fx: InvoiceFXQuote? = nil, now: Date = Date()) throws -> NativeRecord {
        guard dates.keys.allSatisfy(["issueDate","taxableSupplyDate","dueDate"].contains), dates.values.allSatisfy({ $0 != .null }) else { throw NativeDBError.message("発行日・支払期限を確認してください。") }
        return try db.transaction {
            let (invoice,settings) = try invoiceFXContext(record)
            let seriesID = invoice["seriesId"] == .null ? settings["defaultSeriesId"] : invoice["seriesId"]
            let rate: String
            if invoice["currency"] == settings["baseCurrency"] { rate = "1" }
            else {
                guard let fx, fx.from == invoice["currency"].string, fx.to == settings["baseCurrency"].string, fx.settingsRevision == settings.revision else { throw NativeDBError.message("発行する通貨の換算レートを再取得してください。") }
                guard try PriceDecimal.parse(fx.rate) > 0 else { throw NativeDBError.message("換算レートが不正です。") }; rate = fx.rate
            }
            let buffer = try makeInvoiceDraft(invoice); guard try buffer.count() > 0 else { throw NativeDBError.message("明細を1行以上追加してください。") }
            var fields = try invoiceTotals(buffer.totals())
            let issue = dates["issueDate"] ?? .text(ISO8601DateFormatter().string(from:now)); let issueTime = try PricingEngine.date(issue.string)
            guard case let .integer(days) = settings["defaultDueDays"], (1...365).contains(days) else { throw NativeDBError.message("支払期限までの日数を1〜365日で設定してください。") }
            let due = dates["dueDate"] ?? (invoice["dueDate"] != .null ? invoice["dueDate"] : .text(ISO8601DateFormatter().string(from:issueTime.addingTimeInterval(Double(days)*86400))))
            guard let account = try db.get("crm_Accounts",key:["id":invoice["accountId"]]) else { throw NativeDBError.message("請求先が見つかりません。") }
            let keys = ["name":"name","street":"billing_street","city":"billing_city","zip":"billing_postal_code","state":"billing_state","country":"billing_country","vat_id":"vat","registration_id":"company_id"]
            let snapshot = Dictionary(uniqueKeysWithValues:keys.map { ($0.key,account[$0.value].json) })
            fields.merge(["status":.text("ISSUED"),"seriesId":seriesID,"issueDate":issue,"taxableSupplyDate":dates["taxableSupplyDate"] ?? issue,"dueDate":due,"billingSnapshot":.text(String(decoding:try JSONSerialization.data(withJSONObject:snapshot,options:.sortedKeys),as:UTF8.self)),"baseCurrency":settings["baseCurrency"],"fxRateToBase":.text(rate)]) { _,n in n }
            try db.validateFieldValues("Invoices",fields)
            fields["number"] = .text(try invoiceNumber(seriesID:seriesID,now:now))
            var offset = 0
            while true {
                let page = try buffer.page(offset:offset)
                for row in page { try autoreleasepool {
                    guard let id = row.quote.lineID, let live = try db.get("Invoice_LineItems",key:["id":.text(id)]) else { throw NativeDBError.conflict }
                    _ = try db.update(live,changes:row.quote.values(row.input,snapshot:true),actor:identity.id,action:"invoice_tax_snapshot")
                } }
                offset += page.count; if page.count < 100 { break }
            }
            let issued = try db.update(invoice,changes:fields,actor:identity.id,action:"invoice_issue")
            try invoiceActivity(issued,action:"ISSUED"); try db.enqueue("invoice.pdf_requested",payload:["invoiceId":issued["id"].string,"actorId":identity.id])
            return issued
        }
    }
    func cancelInvoice(_ record: NativeRecord) throws -> NativeRecord {
        try db.transaction { let current = try invoiceAccess(record,action:"cancel"); let result = try db.update(current,changes:["status":.text("CANCELLED")],actor:identity.id,action:"invoice_cancel"); try invoiceActivity(result,action:"CANCELLED"); return result }
    }
    func duplicateInvoice(_ record: NativeRecord) throws -> NativeRecord {
        try db.transaction {
            let source = try invoiceAccess(record,action:"duplicate"); try assertAccess("crm_Accounts",id:source["accountId"].string,write:true)
            let keys = ["type","accountId","seriesId","currency","dueDate","publicNotes","internalNotes","bankName","bankAccount","iban","swift","variableSymbol","subtotal","discountTotal","vatTotal","grandTotal"]
            var fields = Dictionary(uniqueKeysWithValues:keys.map { ($0,source[$0]) }); fields.merge(["status":.text("DRAFT"),"createdBy":.text(identity.id),"originalInvoiceId":source["id"],"balanceDue":source["grandTotal"]]) { _,n in n }
            let result = try db.insert("Invoices",values:fields,actor:identity.id); var offset = 0
            while true {
                let page = try invoiceRows(source,offset:offset)
                for row in page.rows { try autoreleasepool {
                    let keys = ["position","productId","description","quantity","unitPrice","discountPercent","taxRateId","lineSubtotal","lineVat","lineTotal"]
                    var line = Dictionary(uniqueKeysWithValues:keys.map { ($0,row[$0]) }); line["invoiceId"] = result["id"]
                    _ = try db.insert("Invoice_LineItems",values:line,actor:identity.id)
                } }
                offset += page.rows.count; if page.rows.isEmpty || offset >= page.total { break }
            }
            try invoiceActivity(result,action:"DUPLICATED",meta:["sourceInvoiceId":source["id"].string]); return result
        }
    }
    func addInvoicePayment(_ record: NativeRecord, amount: String, paidAt: Date, method: String, reference: String? = nil, note: String? = nil) throws -> NativeRecord {
        let amount = try PriceDecimal.parse(amount); let method = method.trimmingCharacters(in:.whitespacesAndNewlines)
        guard amount > 0, !method.isEmpty else { throw NativeDBError.message("入金額は0より大きい金額を入力し、入金方法を選択してください。") }
        return try db.transaction {
            let invoice = try invoiceAccess(record,action:"payment")
            _ = try db.insert("Invoice_Payments",values:["invoiceId":invoice["id"],"amount":.text(PriceDecimal.string(amount)),"paidAt":.text(ISO8601DateFormatter().string(from:paidAt)),"method":.text(method),"reference":reference.map(SQLValue.text) ?? .null,"note":note.map(SQLValue.text) ?? .null,"createdBy":.text(identity.id)],actor:identity.id)
            let paid = try PriceDecimal.calculate(PriceDecimal.parse(invoice["paidTotal"].string),"+",amount)
            let balance = try PriceDecimal.calculate(PriceDecimal.parse(invoice["grandTotal"].string),"-",paid)
            let result = try db.update(invoice,changes:["paidTotal":.text(PriceDecimal.string(paid)),"balanceDue":.text(PriceDecimal.string(max(0,balance))),"status":.text(balance <= 0 ? "PAID" : "PARTIALLY_PAID")],actor:identity.id,action:"invoice_payment")
            try invoiceActivity(result,action:"PAYMENT_ADDED",meta:["amount":PriceDecimal.string(amount),"method":method]); return result
        }
    }
    func deleteInvoicePayment(_ payment: NativeRecord, invoice record: NativeRecord) throws -> NativeRecord {
        try authenticated(); guard identity.role == "admin", payment.model == "Invoice_Payments" else { throw NativeDBError.message("入金の削除は管理者だけが行えます。") }
        return try db.transaction {
            let invoice = try invoiceAccess(record); guard invoice.revision == record.revision, payment["invoiceId"] == invoice["id"], let current = try db.get(payment.model,key:["id":payment["id"]]), current.revision == payment.revision, current["invoiceId"] == invoice["id"] else { throw NativeDBError.conflict }
            let paid = try PriceDecimal.calculate(PriceDecimal.parse(invoice["paidTotal"].string),"-",PriceDecimal.parse(current["amount"].string))
            let balance = try PriceDecimal.calculate(PriceDecimal.parse(invoice["grandTotal"].string),"-",paid)
            var status = invoice["status"].string
            if paid <= 0 { if ["PAID","PARTIALLY_PAID"].contains(status) { status = "ISSUED" } }
            else if balance > 0 { status = "PARTIALLY_PAID" }
            try db.remove(current,actor:identity.id,action:"invoice_payment_delete")
            let result = try db.update(invoice,changes:["paidTotal":.text(PriceDecimal.string(max(0,paid))),"balanceDue":.text(PriceDecimal.string(max(0,balance))),"status":.text(status)],actor:identity.id,action:"invoice_payment_delete")
            try invoiceActivity(result,action:"PAYMENT_DELETED",meta:["paymentId":payment["id"].string,"amount":current["amount"].string]); return result
        }
    }
}
