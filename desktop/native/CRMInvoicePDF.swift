import Foundation

extension CRMService {
    func invoicePDFURL(_ record: NativeRecord) throws -> URL {
        let current = try invoiceAccess(record); let key = try NativeOperationalAssets.localReference(current,field:"pdfStorageKey",db:db) ?? current["pdfStorageKey"].string
        guard key.range(of:#"^invoice-pdfs/[a-f0-9-]{36}\.pdf$"#,options:.regularExpression) != nil else { throw NativeDBError.message("このMacで保存したPDFがありません。PDFを作成してください。") }
        let url = db.url.deletingLastPathComponent().appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath:url.path) else { throw NativeDBError.message("PDFファイルが見つかりません。再作成してください。") }; return url
    }
    @discardableResult func generateInvoicePDF(_ record: NativeRecord) throws -> NativeRecord {
        let prepared = try db.transaction { () -> (NativeRecord,InvoiceDraftStore,InvoicePDFData) in
            let invoice = try invoiceAccess(record,action:"pdf")
            guard invoice["number"] != .null, invoice["issueDate"] != .null else { throw NativeDBError.message("発行済みの請求書を選択してください。") }
            let settings = try invoiceSettings()
            guard let account = try db.get("crm_Accounts",key:["id":invoice["accountId"]]) else { throw NativeDBError.message("請求先が見つかりません。") }
            let snapshot = (try? JSONSerialization.jsonObject(with:Data(invoice["billingSnapshot"].string.utf8))) as? [String:Any]
            func customer(_ key: String,_ fallback: String) -> String {
                if let snapshot, let name = snapshot["name"] as? String, !name.isEmpty { return snapshot[key] as? String ?? "" }; return account[fallback].string
            }
            func join(_ items:[String]) -> String { items.filter { !$0.isEmpty }.joined(separator:"\n") }
            func setting(_ key: String) -> String { settings?[key].string ?? "" }
            func payment(_ key: String) -> String { invoice[key] == .null ? setting(key) : invoice[key].string }
            let customerText = join([customer("name","name")+" 御中",customer("zip","billing_postal_code"),customer("state","billing_state")+customer("city","billing_city"),customer("street","billing_street"),customer("country","billing_country"),customer("vat_id","vat").isEmpty ? "" : "登録番号："+customer("vat_id","vat"),customer("registration_id","company_id").isEmpty ? "" : "法人番号："+customer("registration_id","company_id")])
            let supplierText = join([setting("companyName").isEmpty ? "NextCRM" : setting("companyName"),setting("companyZip"),setting("companyCity"),setting("companyAddress"),setting("companyCountry"),setting("companyVatId").isEmpty ? "" : "登録番号："+setting("companyVatId"),setting("companyRegNo").isEmpty ? "" : "法人番号："+setting("companyRegNo"),setting("companyEmail"),setting("companyPhone")])
            let paymentText = join([payment("bankName"),payment("bankAccount"),payment("iban").isEmpty ? "" : "IBAN："+payment("iban"),payment("swift").isEmpty ? "" : "SWIFT："+payment("swift"),invoice["variableSymbol"].string.isEmpty ? "" : "照合番号："+invoice["variableSymbol"].string])
            let titles = ["INVOICE":"請求書","CREDIT_NOTE":"返還請求書","PROFORMA":"仮請求書"]
            let data = InvoicePDFData(title:titles[invoice["type"].string] ?? "請求書",number:invoice["number"].string,currency:invoice["currency"].string,issueDate:String(invoice["issueDate"].string.prefix(10)),dueDate:invoice["dueDate"] == .null ? "未設定" : String(invoice["dueDate"].string.prefix(10)),supplyDate:invoice["taxableSupplyDate"] == .null ? "未設定" : String(invoice["taxableSupplyDate"].string.prefix(10)),customer:customerText,supplier:supplierText,payment:paymentText,publicNotes:invoice["publicNotes"].string,footer:setting("footerText"),subtotal:invoice["subtotal"].string,vat:invoice["vatTotal"].string,total:invoice["grandTotal"].string)
            let staged = try InvoiceDraftStore(); var offset = 0
            while true {
                let page = try invoiceRows(invoice,offset:offset)
                for row in page.rows { try autoreleasepool {
                    let quote = InvoiceLineQuote(rate:row["taxRateSnapshot"] == .null ? "0" : row["taxRateSnapshot"].string,amounts:.init(lineSubtotal:row["lineSubtotal"].string,lineVat:row["lineVat"].string,lineTotal:row["lineTotal"].string))
                    _ = try staged.save(input:InvoiceLineInput.from(row),quote:quote)
                } }
                offset += page.rows.count; if page.rows.isEmpty || offset >= page.total { break }
            }
            return (invoice,staged,data)
        }
        let folder = db.url.deletingLastPathComponent().appendingPathComponent("invoice-pdfs")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let filename = UUID().uuidString.lowercased()+".pdf"; let url = folder.appendingPathComponent(filename)
        let previousURL = try? invoicePDFURL(prepared.0)
        do {
            let renderer = try InvoicePDF(url:url,data:prepared.2); _ = try renderer.render { try prepared.1.page(offset:$0) }
            let result = try db.transaction { () -> NativeRecord in
                let current = try invoiceAccess(prepared.0,action:"pdf")
                let updated = try db.update(current,changes:["pdfStorageKey":.text("invoice-pdfs/"+filename),"pdfGeneratedAt":.text(ISO8601DateFormatter().string(from:Date()))],actor:identity.id,action:"invoice_pdf")
                // The DB may be nested in a caller transaction. Only its final
                // commit releases the former PDF; rollback releases this one.
                db.deferUntilTransactionEnds(onCommit: {
                    if let previousURL, previousURL != url { try? FileManager.default.removeItem(at:previousURL) }
                }, onRollback: { try? FileManager.default.removeItem(at:url) })
                return updated
            }
            return result
        } catch { try? FileManager.default.removeItem(at:url); throw error }
    }
}
