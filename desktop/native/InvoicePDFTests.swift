import Foundation
import PDFKit
import SQLite3

@main enum InvoicePDFTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("InvoicePDFTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]); let output = URL(fileURLWithPath:CommandLine.arguments[2])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-InvoicePDFTests-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:folder) }
        let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        func refresh(_ row: NativeRecord) throws -> NativeRecord { try db.get(row.model,key:db.key(for:row))! }
        let partnerRow = try db.insert("Users",values:["name":.text("外部担当者"),"email":.text("pdf-partner@example.invalid"),"role":.text("partner"),"userStatus":.text("ACTIVE")],actor:identity.id)
        let partner = CRMService(db:db,identity:CRMIdentity(id:partnerRow["id"].string,role:"partner",partnerAccountID:nil))
        var account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("株式会社 日本語の請求先"),"billing_street":.text("発行時の住所1-2-3 さくらビル"),"billing_city":.text("新宿区"),"billing_state":.text("東京都"),"billing_postal_code":.text("160-0000"),"billing_country":.text("日本"),"partnerUserId":partnerRow["id"]],actor:identity.id)
        var rate = try admin.saveInvoiceTaxRate(original:nil,input:["name":.text("消費税8%"),"rate":.text("8")])
        let series = try admin.saveInvoiceSeries(original:nil,input:["name":.text("標準"),"prefixTemplate":.text("請求-{YYYY}-{####}")])
        _ = try admin.saveInvoiceSettings(original:nil,input:["companyName":.text("株式会社 ネイティブ請求書"),"companyAddress":.text("丸の内1-1-1"),"companyCity":.text("東京都千代田区"),"companyZip":.text("100-0000"),"companyCountry":.text("日本"),"companyRegNo":.text("1234567890123"),"companyVatId":.text("T1234567890123"),"companyEmail":.text("billing@example.invalid"),"baseCurrency":.text("JPY"),"defaultSeriesId":series["id"],"defaultDueDays":.integer(30),"bankName":.text("検証銀行 本店営業部"),"bankAccount":.text("普通 1234567　カ）ネイティブ"),"footerText":.text("このPDFは架空データによる表示検証用です。実際の請求には使用しません。")])
        let now = try PricingEngine.date("2026-11-14T00:00:00Z")
        let publicNotes = String(repeating:"備考の日本語文章です。折り返しとページ送りを確認し、内容を省略せず表示します。\n",count:45)+"備考最終マーカー"
        var invoice = try admin.saveInvoice(original:nil,header:["accountId":account["id"],"currency":.text("JPY"),"publicNotes":.text(publicNotes),"internalNotes":.text("PDFに出してはいけない社内秘密マーカー")],lines:{ offset in
            guard offset < 103 else { return [] }
            return (offset..<min(offset+100,103)).map { index in
                let description = index == 0 ? "長い明細の開始\n"+String(repeating:"日本語の詳しいサービス内容です。追加の説明も途中で切り捨てず掲載します。",count:65)+"長い明細の最終マーカー" : "検証明細 \(index+1)　日本語の商品・サービス"
                return InvoiceLineInput(productID:nil,description:description,quantity:index == 102 ? "9999999999.9999" : "1.5",unitPrice:index == 102 ? "0.0001" : "1200.25",discountPercent:index%3 == 0 ? "5" : "0",taxRateID:rate["id"].string)
            }
        })
        try rejects("draft PDF") { _ = try admin.generateInvoicePDF(invoice) }
        invoice = try admin.issueInvoice(invoice,now:now)
        account = try db.update(account,changes:["billing_street":.text("変更後住所は出してはいけない")],actor:identity.id)
        rate = try admin.saveInvoiceTaxRate(original:rate,input:["rate":.text("20")])
        let pdfFolder = folder.appendingPathComponent("invoice-pdfs")
        FileManager.default.createFile(atPath:pdfFolder.path,contents:Data("block directory".utf8))
        try rejects("PDF filesystem failure") { _ = try admin.generateInvoicePDF(invoice) }
        try check(try refresh(invoice)["status"] == .text("ISSUED") && refresh(invoice)["number"] == invoice["number"] && refresh(invoice)["pdfStorageKey"] == .null,"PDF failure does not undo invoice issuance")
        try FileManager.default.removeItem(at:pdfFolder)
        invoice = try admin.generateInvoicePDF(invoice)
        let url = try admin.invoicePDFURL(invoice); guard let document = PDFDocument(url:url), let text = document.string else { throw NativeDBError.message("PDF cannot be read") }
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:output.path) { try FileManager.default.removeItem(at:output) }
        try FileManager.default.copyItem(at:url,to:output)
        let compactText = text.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        print("PDF markers:", ["長い明細の最終マーカー","検証明細103","備考最終マーカー"].map { compactText.contains($0) })
        try check(document.pageCount >= 5,"multi-page invoice")
        try check(text.contains("株式会社 日本語の請求先") && text.contains("発行時の住所1-2-3") && !text.contains("変更後住所"),"PDF uses frozen Japanese billing information")
        try check(compactText.contains("長い明細の最終マーカー") && compactText.contains("検証明細103") && compactText.contains("備考最終マーカー"),"long description, final line and long notes not truncated")
        try check(!text.contains("社内秘密マーカー"),"internal notes are never printed")
        try check(text.contains(invoice["grandTotal"].string) && text.contains("税率 8%"),"frozen tax and stored total printed")
        try check(text.contains("9999999999.9999"),"long numeric value stays on one line")
        try check(try (FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,"private PDF permissions")
        try check(try partner.invoicePDFURL(invoice) == url,"assigned partner can access saved PDF")
        try rejects("partner cannot regenerate") { _ = try partner.generateInvoicePDF(invoice) }
        var raw: OpaquePointer?; guard sqlite3_open(db.url.path,&raw) == SQLITE_OK else { throw NativeDBError.message("test DB") }; defer { sqlite3_close(raw) }
        func sql(_ query: String) throws { guard sqlite3_exec(raw,query,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message("test SQL failed") } }
        try sql("CREATE TRIGGER pdf_metadata_failure BEFORE UPDATE ON Invoices WHEN NEW.pdfStorageKey != OLD.pdfStorageKey BEGIN SELECT RAISE(ABORT,'injected PDF metadata failure'); END")
        try rejects("PDF metadata failure") { _ = try admin.generateInvoicePDF(invoice) }
        try check(try admin.invoicePDFURL(invoice) == url && FileManager.default.contentsOfDirectory(atPath:pdfFolder.path).count == 1,"failed regeneration preserves prior PDF and removes uncommitted output")
        try sql("DROP TRIGGER pdf_metadata_failure")
        invoice = try admin.generateInvoicePDF(invoice)
        let replacement = try admin.invoicePDFURL(invoice)
        try check(replacement != url && !FileManager.default.fileExists(atPath:url.path),"successful regeneration replaces and releases old generated PDF")
        let stale = invoice; invoice = try admin.addInvoicePayment(invoice,amount:"1",paidAt:now,method:"銀行振込")
        try rejects("stale generation") { _ = try admin.generateInvoicePDF(stale) }
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:output.path) { try FileManager.default.removeItem(at:output) }
        try FileManager.default.copyItem(at:replacement,to:output)
        try check(try db.integrityCheck(),"PDF workflow DB integrity")
        print("{\"ok\":true,\"suite\":\"InvoicePDF\",\"checks\":\(checks),\"pages\":\(document.pageCount),\"sample\":\"\(output.path)\"}")
    }
}
