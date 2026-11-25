import Foundation

/// Used only when the application has validated its isolated QA directory.
/// These rates are synthetic; this adapter never opens a network connection.
enum NativeCurrencyAdministrationQA {
    static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, url.host == "www.ecb.europa.eu" else { throw NativeDBError.message("検証用のECB接続先が不正です。") }
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
          <Cube><Cube time='\(day)'><Cube currency='USD' rate='1.10'/><Cube currency='JPY' rate='160.00'/><Cube currency='CZK' rate='25.00'/></Cube></Cube>
        </gesmes:Envelope>
        """
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!)
    }
}
