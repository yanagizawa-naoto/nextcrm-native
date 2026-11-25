import Foundation

@main enum InvoiceUIFixture {
    static func main() {
        do {
            let resources = URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL
            let folder = URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL
            guard folder.resolvingSymlinksInPath() == resources.appendingPathComponent("../artifacts/native-crm-ui-data").standardizedFileURL.resolvingSymlinksInPath() else { throw NativeDBError.message("検証専用の保存先を指定してください。") }
            let db = try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let service = CRMService(db:db,identity:identity)
            let result = try db.transaction { () -> [String:String] in
                guard try db.page("crm_Accounts",fields:[],equal:["name":.text("請求UI検証株式会社")]).total == 0 else { throw NativeDBError.message("請求UI検証データは作成済みです。") }
                let account = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("請求UI検証株式会社"),"assigned_to":.text(identity.id),"billing_city":.text("千代田区"),"billing_street":.text("検証町1-2-3"),"billing_country":.text("日本")],actor:identity.id)
                let tax = try service.saveInvoiceTaxRate(original:nil,input:["name":.text("消費税10%（検証）"),"rate":.text("10"),"active":.integer(1)])
                let series = try service.saveInvoiceSeries(original:nil,input:["name":.text("日本語請求番号（検証）"),"prefixTemplate":.text("請求-{YYYY}-{####}"),"active":.integer(1)])
                if try service.invoiceSettings() == nil {
                    _ = try service.saveInvoiceSettings(original:nil,input:["companyName":.text("請求書発行テスト株式会社"),"companyAddress":.text("検証町4-5-6"),"companyCity":.text("新宿区"),"companyZip":.text("160-0000"),"companyCountry":.text("日本"),"companyRegNo":.text("1234567890123"),"baseCurrency":.text("JPY"),"defaultDueDays":.integer(14),"defaultSeriesId":series["id"],"defaultTaxRateId":tax["id"],"bankName":.text("検証銀行"),"bankAccount":.text("普通 1234567")])
                }
                let invoice = try service.saveInvoice(original:nil,header:["accountId":account["id"],"currency":.text("JPY"),"seriesId":series["id"],"publicNotes":.text("103明細のページングを検証します。"),"internalNotes":.text("社内限定の検証メモ")],lines:{ offset in (offset..<min(offset+100,103)).map { i in .init(productID:nil,description:"日本語の請求明細 \(i+1)",quantity:"1",unitPrice:"100.25",discountPercent:"10",taxRateID:tax["id"].string) } })
                return ["account":account["id"].string,"invoice":invoice["id"].string,"tax":tax["id"].string,"series":series["id"].string,"total":invoice["grandTotal"].string]
            }
            print(String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
        } catch { FileHandle.standardError.write(Data("InvoiceUIFixture: \(error)\n".utf8)); exit(1) }
    }
}
