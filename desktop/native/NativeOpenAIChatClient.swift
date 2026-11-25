import Foundation

struct NativeOpenAIChatClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let model = "gpt-4o-mini"
    static let summaryInstruction = "次の文書の目的と主な内容を、日本語で簡潔な2〜3文に要約してください。"
    static let classificationInstruction = "Classify this document into exactly one of these categories: RECEIPT, CONTRACT, OFFER, OTHER. Respond with only the category name, nothing else."
    private let apiKey: String, request: NativeEmbeddingClient.Request
    init(apiKey: String, request: @escaping NativeEmbeddingClient.Request = { try await NativeEmbeddingClient.providerTransport($0, endpoint: Self.endpoint) }) throws {
        _ = try NativeEmbeddingClient(apiKey: apiKey); self.apiKey = apiKey; self.request = request
    }
    private struct Response: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let role: String; let content: String? }; let index: Int; let message: Message }
        let object: String, model: String, choices: [Choice]
    }
    func summary(excerpt: String) async throws -> String? {
        try await complete(system: Self.summaryInstruction, user: NativeDocumentAIText.prefix(excerpt, units: 12_000), maxTokens: 200)
    }
    func classification(name: String, summary: String?, excerpt: String) async throws -> String {
        let user = "Document name: \(name)\n\nSummary: \(summary ?? "null")\n\nContent excerpt:\n\(NativeDocumentAIText.prefix(excerpt, units: 4000))"
        let raw = try await complete(system: Self.classificationInstruction, user: user, maxTokens: 10)
        // ECMAScript trim semantics, including FEFF and excluding U+0085.
        let trim = NativeAIEnvironment.trim(raw ?? "OTHER").uppercased()
        return ["RECEIPT", "CONTRACT", "OFFER", "OTHER"].contains(trim) ? trim : "OTHER"
    }
    private func complete(system: String, user: String, maxTokens: Int) async throws -> String? {
        var req = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.httpMethod = "POST"; req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": Self.model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "max_tokens": maxTokens], options: .sortedKeys)
        try Task.checkCancellation()
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await request(req) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NativeAIError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw NativeAIError(message: "OpenAIに接続できません。", retryable: true) }
        try Task.checkCancellation()
        guard response.url == Self.endpoint, data.count <= NativeEmbeddingClient.maximumResponseBytes else { throw NativeAIError(message: "OpenAIの応答先または応答サイズが不正です。") }
        guard response.statusCode == 200 else {
            let message = [401, 403].contains(response.statusCode) ? "OpenAIのAPIキーと利用権限を確認してください。" : "文書のAI処理が完了しませんでした（HTTP \(response.statusCode)）。"
            throw NativeAIError(message: message, retryable: [408, 409, 429].contains(response.statusCode) || response.statusCode >= 500, status: response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(Response.self, from: data), result.object == "chat.completion",
              result.model == Self.model || result.model.hasPrefix(Self.model + "-"), result.choices.count == 1,
              let first = result.choices.first, first.index == 0, first.message.role == "assistant" else { throw NativeAIError(message: "文書の要約・分類の応答を読み取れません。") }
        return first.message.content
    }
}
