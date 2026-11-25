import Foundation

enum InvoiceFXClient {
    static func quote(currency: String, settings: NativeRecord,
                      request: (URLRequest) async throws -> (Data,URLResponse) = { try await URLSession.shared.data(for:$0) }) async throws -> InvoiceFXQuote {
        let base = settings["baseCurrency"].string
        guard [currency,base].allSatisfy({ $0.range(of:#"^[A-Z]{3}$"#,options:.regularExpression) != nil }) else { throw NativeDBError.message("換算する通貨コードが不正です。") }
        if currency == base { return InvoiceFXQuote(from:currency,to:base,rate:"1",settingsRevision:settings.revision) }
        var parts = URLComponents(string:"https://api.frankfurter.app/latest")!; parts.queryItems = [URLQueryItem(name:"from",value:currency),URLQueryItem(name:"to",value:base)]
        var query = URLRequest(url:parts.url!,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:15); query.setValue("application/json",forHTTPHeaderField:"Accept")
        let (data,response) = try await request(query)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count <= 131072 else { throw NativeDBError.message("換算レートを取得できません。接続を確認して再実行してください。") }
        struct Reply: Decodable { let rates: [String:Decimal] }
        guard let result = try? JSONDecoder().decode(Reply.self,from:data), let value = result.rates[base], !value.isNaN, value > 0 else { throw NativeDBError.message("換算レートの応答が不正です。") }
        let rate = PriceDecimal.rounded(value,scale:8); guard rate > 0 else { throw NativeDBError.message("換算レートが保存可能な精度を下回っています。") }
        return InvoiceFXQuote(from:currency,to:base,rate:PriceDecimal.string(rate),settingsRevision:settings.revision)
    }
}
