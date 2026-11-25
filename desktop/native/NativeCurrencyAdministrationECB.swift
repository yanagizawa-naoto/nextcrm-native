import Foundation

enum NativeCurrencyAdministrationECB {
    static let endpoint = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
    static let maximumResponseBytes = 1_048_576
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    struct Rates { var order: [String] = []; var values: [String: Double] = [:] }
    struct Result { let skipped: Bool; let updated: Int; let ratesCount: Int }

    /// Keep the original single-quoted regex contract, last duplicate value,
    /// first insertion order, and parseFloat handling; no XML entity expansion.
    static func parse(_ text: String) throws -> Rates {
        let regex = try NSRegularExpression(pattern: #"currency='([A-Z]{3})'([\s\uFEFF]+)rate='([0-9.]+)'"#)
        var rates = Rates()
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match, let codeRange = Range(match.range(at: 1), in: text), let spaceRange = Range(match.range(at: 2), in: text),
                  text[spaceRange].unicodeScalars.allSatisfy({ NativeOdooMap.whitespace.contains($0) }), let rateRange = Range(match.range(at: 3), in: text) else { return }
            let code = String(text[codeRange])
            if rates.values[code] == nil { rates.order.append(code) }
            rates.values[code] = NativeCurrencyAdministration.parseFloat(String(text[rateRange]))
        }
        return rates
    }
    /// The source commits individual pair upserts. Keep successful earlier
    /// pairs if a later invalid rate/FK fails; do not silently make the complete
    /// import atomic. Each write still checks cancellation/configuration/lease.
    static func synchronize(db: NativeDatabase, transport: Transport, clock: () -> Date = Date.init,
                            validate: () throws -> Void = {}) async throws -> Result {
        let revision: Int64? = try db.transaction {
            try Task.checkCancellation(); try validate()
            guard let row = try db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")]), row["value"] == .text("true") else { return nil }
            return row.revision
        }
        guard let revision else { return Result(skipped: true, updated: 0, ratesCount: 0) }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/xml,text/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard (200...299).contains(response.statusCode), data.count <= maximumResponseBytes else { throw NativeDBError.message("ECBの為替レートを取得できませんでした（HTTP \(response.statusCode)）。") }
        let rates = try parse(String(decoding: data, as: UTF8.self))
        func fence() throws {
            try Task.checkCancellation(); try validate()
            guard let current = try db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")]), current.revision == revision,
                  current["value"] == .text("true") else { throw NativeDBError.message("ECBの自動更新設定が変更されたため、更新を中止しました。") }
        }
        var enabled: [String] = [], offset = 0
        try db.transaction {
            try fence()
            while true {
                let page = try db.page("Currency", fields: ["code"], equal: ["isEnabled": .integer(1)], offset: offset, limit: 100)
                // The cross-rate loop only needs currencies present in this
                // response. Other enabled currencies cannot produce a rate.
                enabled += page.rows.map { $0["code"].string }.filter { rates.values[$0] != nil }
                offset += page.rows.count; if offset >= page.total || page.rows.isEmpty { break }
            }
        }
        let enabledSet = Set(enabled)
        func upsert(_ from: String, _ to: String, _ rate: Double) throws {
            try db.transaction {
                try fence()
                _ = try NativeCurrencyAdministration.upsertRate(from: from, to: to, value: rate, source: "ECB", db: db, actor: "system:ecb", at: clock())
            }
        }
        var updated = 0
        for code in rates.order where enabledSet.contains(code) {
            let rate = rates.values[code]!
            try upsert("EUR", code, rate)
            try upsert(code, "EUR", NativeCurrencyAdministration.parseFloat(NativeOdooMap.fixed(1 / rate, digits: 8)))
            updated += 2
        }
        let codes = enabled.filter { $0 != "EUR" }
        for from in codes {
            for to in codes where from != to {
                let a = rates.values[from]!, b = rates.values[to]!
                if a == 0 || a.isNaN || b == 0 || b.isNaN { continue }
                let manual = try db.transaction { () -> Bool in
                    try fence(); return try NativeCurrencyAdministration.rate(from: from, to: to, db: db)?["source"] == .text("MANUAL")
                }
                if manual { continue }
                // Recheck MANUAL inside the same transaction as publication;
                // a manual edit racing the scan must not be overwritten.
                try db.transaction {
                    try fence()
                    if try NativeCurrencyAdministration.rate(from: from, to: to, db: db)?["source"] == .text("MANUAL") { return }
                    try upsert(from, to, NativeCurrencyAdministration.parseFloat(NativeOdooMap.fixed(b / a, digits: 8)))
                    updated += 1
                }
            }
        }
        return Result(skipped: false, updated: updated, ratesCount: rates.values.count)
    }
}

/// A fixed-endpoint, ephemeral request adapter with a receive-time body limit.
/// It is never invoked by the dedicated fixture transport.
final class NativeCurrencyAdministrationECBTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?, task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?, bytes = Data(), completed = false, cancelled = false
    private let lock = NSLock()
    static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let adapter = NativeCurrencyAdministrationECBTransport()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in adapter.begin(request, continuation) }
        }, onCancel: { adapter.cancel() })
    }
    private func begin(_ request: URLRequest, _ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        task = session!.dataTask(with: request); let started = task; lock.unlock(); started?.resume()
    }
    private func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    private func finish(_ result: Swift.Result<(Data, HTTPURLResponse), Error>) {
        lock.lock(); guard !completed else { lock.unlock(); return }; completed = true
        let continuation = continuation, session = session
        self.continuation = nil; self.session = nil; task = nil; bytes.removeAll(keepingCapacity: false); lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(NativeCurrencyAdministrationECB.maximumResponseBytes) else {
            completionHandler(.cancel); finish(.failure(NativeDBError.message("ECBの応答が大きすぎるか、形式が不正です。"))); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= NativeCurrencyAdministrationECB.maximumResponseBytes else { finish(.failure(NativeDBError.message("ECBの応答が大きすぎます。"))); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((bytes, response))) }
        else { finish(.failure(NativeDBError.message("ECBの応答を確認できませんでした。"))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The original endpoint is fixed; do not expand this adapter into a
        // general-purpose authenticated URL fetcher through redirects.
        guard request.url?.scheme == "https", request.url?.host == NativeCurrencyAdministrationECB.endpoint.host else { completionHandler(nil); return }
        completionHandler(request)
    }
}
