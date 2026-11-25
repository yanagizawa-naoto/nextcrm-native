import Foundation

private final class NativeAINoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Existing OpenAI SDK contract, sent directly with Foundation. Tests inject a
/// transport; production always uses the fixed provider origin and no redirects.
struct NativeEmbeddingClient {
    typealias Request = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let endpoint = URL(string: "https://api.openai.com/v1/embeddings")!
    static let maximumResponseBytes = 131_072
    private let apiKey: String
    private let request: Request
    init(apiKey: String, request: @escaping Request = Self.network) throws {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 16_384, apiKey.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw NativeAIError(message: "OpenAIのAPIキーを確認してください。")
        }
        self.apiKey = apiKey; self.request = request
    }
    private struct Response: Decodable {
        struct Item: Decodable { let object: String; let index: Int; let embedding: String }
        let object: String; let model: String; let data: [Item]
    }
    func generate(_ text: String, allowWhitespace: Bool = false) async throws -> NativeEmbeddingVector {
        guard allowWhitespace ? !text.isEmpty : !NativeEmbeddingVector.isBlank(text) else { throw NativeAIError(message: "AI検索用の文章が空です。") }
        var req = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": NativeEmbeddingVector.model, "input": text, "encoding_format": "base64"], options: .sortedKeys)
        try Task.checkCancellation()
        let bytes: Data, response: HTTPURLResponse
        do { (bytes, response) = try await request(req) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NativeAIError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw NativeAIError(message: "OpenAIに接続できません。", retryable: true) }
        try Task.checkCancellation()
        guard response.url == Self.endpoint else { throw NativeAIError(message: "OpenAIの応答先を確認できません。") }
        guard bytes.count <= Self.maximumResponseBytes else { throw NativeAIError(message: "OpenAIの応答が大きすぎます。") }
        guard response.statusCode == 200 else {
            let message: String
            switch response.statusCode {
            case 401, 403: message = "OpenAIのAPIキーと利用権限を確認してください。"
            case 400, 413, 422: message = "AI検索データを作成できません。文章の長さや入力内容を確認してください。"
            case 429: message = "OpenAIの利用上限に達しました。利用枠を確認するか、時間をおいて再実行してください。"
            default: message = "OpenAIの処理が完了しませんでした（HTTP \(response.statusCode)）。"
            }
            throw NativeAIError(message: message, retryable: [408, 409, 429].contains(response.statusCode) || response.statusCode >= 500, status: response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: bytes), result.object == "list", result.model == NativeEmbeddingVector.model,
              result.data.count == 1, let item = result.data.first, item.object == "embedding", item.index == 0,
              let data = Data(base64Encoded: item.embedding) else { throw NativeAIError(message: "OpenAIの検索データを読み取れません。") }
        return try NativeEmbeddingVector(bytes: data)
    }
    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await transport(request, configuration: .ephemeral)
    }
    static func transport(_ request: URLRequest, configuration config: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        try await providerTransport(request, endpoint: endpoint, configuration: config)
    }
    /// Shared bounded transport for the two fixed OpenAI API resources.
    static func providerTransport(_ request: URLRequest, endpoint: URL, configuration config: URLSessionConfiguration = .ephemeral) async throws -> (Data, HTTPURLResponse) {
        guard [Self.endpoint.absoluteString, "https://api.openai.com/v1/chat/completions"].contains(endpoint.absoluteString), request.url == endpoint else { throw NativeAIError(message: "AIの接続先が不正です。") }
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config, delegate: NativeAINoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse, response.url == endpoint else { throw NativeAIError(message: "OpenAIの応答を確認できません。") }
        guard response.expectedContentLength <= Int64(maximumResponseBytes) else { throw NativeAIError(message: "OpenAIの応答が大きすぎます。") }
        var bytes = Data(); bytes.reserveCapacity(16_384)
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < maximumResponseBytes else { throw NativeAIError(message: "OpenAIの応答が大きすぎます。") }
            bytes.append(byte)
        }
        return (bytes, response)
    }
}
