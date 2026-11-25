import Foundation

extension CRMService {
    static let invoiceSettingsRequired = ["companyName":200,"companyAddress":300,"companyCity":100,"companyZip":20,"companyCountry":100,"companyRegNo":50]
    static let invoiceSettingsOptional = ["bankName":200,"bankAccount":100,"iban":50,"swift":20,"footerText":1000,"companyVatId":50,"companyTaxId":50,"companyEmail":200,"companyPhone":50,"companyWebsite":300]
    private func invoiceAdmin() throws { try authenticated(); guard identity.role == "admin" else { throw NativeDBError.message("請求書の管理設定は管理者が変更してください。") } }
    func saveInvoiceSettings(original: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try invoiceAdmin()
        let keys = Array(Self.invoiceSettingsRequired.keys)+Array(Self.invoiceSettingsOptional.keys)+["baseCurrency","defaultSeriesId","defaultTaxRateId","defaultDueDays"]
        guard input.keys.allSatisfy(keys.contains), original == nil || original?.model == "Invoice_Settings" else { throw NativeDBError.message("請求書設定の項目を確認してください。") }
        return try db.transaction {
            let stored = try invoiceSettings()
            guard stored?["id"] == original?["id"], stored?.revision == original?.revision else { throw NativeDBError.conflict }
            var values = original?.values.filter { keys.contains($0.key) } ?? [:]; values.merge(input) { _,n in n }
            for (key,limit) in Self.invoiceSettingsRequired {
                let value = values[key]?.string.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                guard !value.isEmpty, value.count <= limit else { throw NativeDBError.message("会社の名称・住所・法人番号を入力し、文字数を確認してください。") }; values[key] = .text(value)
            }
            for (key,limit) in Self.invoiceSettingsOptional {
                let value = values[key]?.string.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                guard value.count <= limit else { throw NativeDBError.message("会社・振込先の入力文字数が上限を超えています。") }; values[key] = value.isEmpty ? .null : .text(value)
            }
            if let email = values["companyEmail"], email != .null { guard email.string.range(of:#"^[^\s@]+@[^\s@]+\.[^\s@]+$"#,options:.regularExpression) != nil else { throw NativeDBError.message("有効な会社メールアドレスを入力してください。") } }
            guard let currency = values["baseCurrency"], currency.string.count == 3, try db.get("Currency",key:["code":currency]) != nil,
                  case let .integer(days)? = values["defaultDueDays"], (1...365).contains(days) else { throw NativeDBError.message("基準通貨と支払期限（1〜365日）を確認してください。") }
            if let original { return try db.update(original,changes:values,actor:identity.id,action:"invoice_settings") }
            return try db.insert("Invoice_Settings",values:values,actor:identity.id)
        }
    }
    func saveInvoiceSeries(original: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try invoiceAdmin(); let keys = ["name","prefixTemplate","resetPolicy","isDefault","active"]
        guard input.keys.allSatisfy(keys.contains), original == nil || original?.model == "Invoice_Series" else { throw NativeDBError.message("採番系列の入力が不正です。") }
        var values = original?.values.filter { keys.contains($0.key) } ?? ["resetPolicy":.text("YEARLY"),"isDefault":.integer(0),"active":.integer(1)]; values.merge(input) { _,n in n }
        let name = values["name"]?.string.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""; let template = values["prefixTemplate"]?.string ?? ""; let reset = values["resetPolicy"]?.string ?? ""
        guard !name.isEmpty, name.count <= 200, !template.isEmpty, template.count <= 200, template.range(of:#"\{#+\}"#,options:.regularExpression) != nil,
              ["YEARLY","NEVER"].contains(reset), reset != "YEARLY" || template.contains("{YYYY}") else { throw NativeDBError.message("採番の名前と書式を確認してください。書式には{####}、年次リセットでは{YYYY}も含めてください。") }
        values["name"] = .text(name)
        if let original { return try db.update(original,changes:values,actor:identity.id,action:"invoice_series") }
        return try db.insert("Invoice_Series",values:values,actor:identity.id)
    }
    func saveInvoiceTaxRate(original: NativeRecord?, input: [String:SQLValue]) throws -> NativeRecord {
        try invoiceAdmin(); let keys = ["name","rate","isDefault","active"]
        guard input.keys.allSatisfy(keys.contains), original == nil || original?.model == "Invoice_TaxRates" else { throw NativeDBError.message("税率の入力が不正です。") }
        var values = original?.values.filter { keys.contains($0.key) } ?? ["isDefault":.integer(0),"active":.integer(1)]; values.merge(input) { _,n in n }
        let name = values["name"]?.string.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name.count <= 200, let rate = values["rate"], try PriceDecimal.parse(rate.string) >= 0 else { throw NativeDBError.message("税率の名前と0以上の率を入力してください。") }; values["name"] = .text(name)
        if let original { return try db.update(original,changes:values,actor:identity.id,action:"invoice_tax_rate") }
        return try db.insert("Invoice_TaxRates",values:values,actor:identity.id)
    }
    func deleteInvoiceConfiguration(_ record: NativeRecord) throws {
        try invoiceAdmin(); guard ["Invoice_Series","Invoice_TaxRates"].contains(record.model) else { throw NativeDBError.message("削除する採番系列または税率を選択してください。") }
        try db.transaction {
            let model = record.model == "Invoice_Series" ? "Invoices" : "Invoice_LineItems"; let field = record.model == "Invoice_Series" ? "seriesId" : "taxRateId"
            guard try db.page(model,fields:[],equal:[field:record["id"]]).total == 0 else { throw NativeDBError.message("請求書で使用中の設定は削除できません。不要な場合は無効にしてください。") }
            try db.remove(record,actor:identity.id,action:"invoice_configuration_delete")
        }
    }
}
