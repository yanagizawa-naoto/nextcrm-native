import Foundation

struct NativeEnrichmentPage: Codable, Equatable {
    struct Metadata: Codable, Equatable { var title: String?; var description: String?; var ogSiteName: String? = nil }
    var url = "", title = "", description = ""
    var markdown: String? = nil, html: String? = nil, links: [String]? = nil, metadata: Metadata? = nil
    // Internal only: lets a phase release unused HTML/markdown tails while
    // retaining the original proportional content-budget calculation.
    var originalMarkdownUnits: Int? = nil
    enum CodingKeys: String, CodingKey { case url, title, description, markdown, html, links, metadata }
    init(url: String, title: String = "", description: String = "", markdown: String? = nil, html: String? = nil,
         links: [String]? = nil, metadata: Metadata? = nil) {
        self.url = url; self.title = title; self.description = description; self.markdown = markdown
        self.html = html; self.links = links; self.metadata = metadata
    }
    init(from decoder: Decoder) throws {
        // Firecrawl's locked SDK also accepts URL-only search results.
        if let url = try? decoder.singleValueContainer().decode(String.self) { self.init(url: url); return }
        self.init(url: "")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown)
        html = try c.decodeIfPresent(String.self, forKey: .html)
        links = try c.decodeIfPresent([String].self, forKey: .links)
        metadata = try c.decodeIfPresent(Metadata.self, forKey: .metadata)
    }
    func projected(maximumUnits: Int) -> Self {
        var copy = self
        copy.originalMarkdownUnits = originalMarkdownUnits ?? markdown?.utf16.count ?? 0
        copy.markdown = markdown.map { NativeDocumentAIText.prefix($0, units: max(1000, maximumUnits)) }
        copy.html = nil; copy.links = nil; copy.metadata = nil; copy.description = ""
        return copy
    }
}

private final class NativeEnrichmentNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum NativeEnrichmentHTTP {
    typealias Request = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let search = URL(string: "https://api.firecrawl.dev/v2/search")!
    static let scrape = URL(string: "https://api.firecrawl.dev/v2/scrape")!
    static let chat = URL(string: "https://api.openai.com/v1/chat/completions")!
    // The original algorithms use at most 400,000 UTF-16 units per extraction.
    // Bound individual wire responses too; reject oversize rather than silently
    // dropping fields or sources. Streaming/large-response parity is tracked
    // separately from the original algorithm's own content limits.
    static let maximumWebBytes = 16 * 1024 * 1024, maximumAIBytes = 2 * 1024 * 1024
    static func maximumBytes(_ url: URL?) -> Int { url == chat ? maximumAIBytes : maximumWebBytes }
    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await transport(request, configuration: .ephemeral)
    }
    static func transport(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint = request.url, [search, scrape, chat].contains(endpoint) else { throw NativeAIError(message: "情報補完の接続先が不正です。") }
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: NativeEnrichmentNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse, response.url == endpoint else { throw NativeAIError(message: "情報補完の応答先を確認できません。") }
            let limit = maximumBytes(endpoint)
            guard response.expectedContentLength <= limit else { throw NativeAIError(message: "情報補完サービスの応答が大きすぎます。項目を分けて実行してください。") }
            var data = Data(); data.reserveCapacity(16_384)
            for try await byte in stream {
                try Task.checkCancellation()
                guard data.count < limit else { throw NativeAIError(message: "情報補完サービスの応答が大きすぎます。項目を分けて実行してください。") }
                data.append(byte)
            }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeAIError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw NativeAIError(message: "情報補完サービスに接続できません。", retryable: true) }
    }
    static func request(_ endpoint: URL, key: String, body: [String: Any], timeout: TimeInterval = 60) throws -> URLRequest {
        guard !key.isEmpty, key.utf8.count <= 16_384, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { throw NativeAIError(message: "情報補完のAPIキーを確認してください。") }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"; request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: .sortedKeys); return request
    }
    static func validate(_ data: Data, _ response: HTTPURLResponse, endpoint: URL) throws {
        try Task.checkCancellation()
        guard response.url == endpoint, data.count <= maximumBytes(endpoint) else { throw NativeAIError(message: "情報補完の応答先または応答サイズが不正です。") }
    }
}

struct NativeFirecrawlClient {
    typealias Sleep = (UInt64) async throws -> Void
    private let key: String, request: NativeEnrichmentHTTP.Request, sleep: Sleep
    private struct Failure: Error { let status: Int, websiteTLS: Bool }
    init(apiKey: String, request: @escaping NativeEnrichmentHTTP.Request = NativeEnrichmentHTTP.network,
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }) {
        key = apiKey; self.request = request; self.sleep = sleep
    }
    private func post(_ endpoint: URL, body: [String: Any], timeout: TimeInterval = 60) async throws -> Data {
        try Task.checkCancellation()
        let req = try NativeEnrichmentHTTP.request(endpoint, key: key, body: body, timeout: timeout)
        let (data, response) = try await request(req)
        try NativeEnrichmentHTTP.validate(data, response, endpoint: endpoint)
        struct Envelope: Decodable { let success: Bool?; let error: String? }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        guard response.statusCode == 200, envelope?.success == true else {
            if [401, 402, 403].contains(response.statusCode) { throw NativeAIError(message: "FirecrawlのAPIキー・利用権限・残高を確認してください。", status: response.statusCode) }
            let message = envelope?.error ?? ""
            throw Failure(status: response.statusCode, websiteTLS: message.contains("SSL error") || message.contains("certificate") || response.statusCode == 500 && message.contains("SSL"))
        }
        return data
    }
    func search(_ query: String, limit: Int = 5, scrapeContent: Bool = true) async throws -> [NativeEnrichmentPage] {
        guard !NativeAIEnvironment.trim(query).isEmpty, limit > 0 else { throw NativeAIError(message: "検索語と取得件数を指定してください。") }
        var body: [String: Any] = ["query": query, "limit": limit, "highlights": false]
        if scrapeContent { body["scrapeOptions"] = ["formats": ["markdown", "links", "html"]] }
        for attempt in 0..<3 {
            do {
                let data = try await post(NativeEnrichmentHTTP.search, body: body)
                struct Search: Decodable { struct Payload: Decodable { var web: [NativeEnrichmentPage]? }; let data: Payload? }
                guard let decoded = try? JSONDecoder().decode(Search.self, from: data) else { throw NativeAIError(message: "Firecrawlの検索結果を読み取れません。") }
                return decoded.data?.web ?? []
            } catch let failure as Failure {
                if [429, 502, 503, 504].contains(failure.status), attempt < 2 { try await sleep(UInt64(1 << attempt) * 1_000_000_000) }
                else { return [] } // Preserve search fallback for unavailable sources.
            }
        }
        return []
    }
    func scrape(_ url: String) async throws -> NativeEnrichmentPage {
        let full = url.hasPrefix("http") ? url : "https://" + url
        guard let parsed = URL(string: full), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { throw NativeAIError(message: "取得するウェブサイトのURLが不正です。") }
        var body: [String: Any] = ["url": NativeAIEnvironment.trim(full), "formats": ["markdown", "html"], "timeout": 30_000]
        func decode(_ data: Data) throws -> NativeEnrichmentPage {
            struct Scrape: Decodable { let data: NativeEnrichmentPage }
            guard var page = try? JSONDecoder().decode(Scrape.self, from: data).data else { throw NativeAIError(message: "Firecrawlのウェブサイト情報を読み取れません。") }
            if page.url.isEmpty { page.url = full }; return page
        }
        for attempt in 0..<3 {
            do { return try decode(await post(NativeEnrichmentHTTP.scrape, body: body, timeout: 35)) }
            catch let failure as Failure {
                if attempt == 0, failure.websiteTLS {
                    // Matches the original Firecrawl scrape fallback. TLS to
                    // Firecrawl itself is always verified by URLSession.
                    body["skipTlsVerification"] = true
                    do { return try decode(await post(NativeEnrichmentHTTP.scrape, body: body, timeout: 35)) }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as NativeAIError { throw error }
                    catch { body.removeValue(forKey: "skipTlsVerification") }
                }
                guard [429, 502, 503, 504].contains(failure.status), attempt < 2 else {
                    throw NativeAIError(message: "ウェブサイトの情報を取得できませんでした（HTTP \(failure.status)）。", retryable: [429, 502, 503, 504].contains(failure.status), status: failure.status)
                }
                try await sleep(UInt64(1 << attempt) * 1_000_000_000)
            }
        }
        throw NativeAIError(message: "ウェブサイトの情報を取得できませんでした。")
    }
}
