import Foundation

struct CampaignAIDraft: Equatable {
    let subject: String, html: String
}

/// The original generate-template action's request contract, without a JS runtime.
struct CampaignAIClient {
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let instruction = """
    You are an email copywriter. Generate a professional HTML email body and subject line.
    Return ONLY valid JSON in this exact format: {"subject":"...", "html":"..."}
    The HTML should be clean, inline-styled, suitable for email clients.
    Use merge tags {{first_name}}, {{last_name}}, {{email}}, {{company}}, {{position}} where appropriate.
    """
    static let maximumPromptBytes = 32_768, maximumHTMLBytes = 65_536, maximumSubjectBytes = 4096
    let apiKey: String
    var request: NativeEmbeddingClient.Request = { try await NativeEmbeddingClient.providerTransport($0, endpoint: endpoint) }
    var timeoutNanoseconds: UInt64 = 30_000_000_000

    static func validatePrompt(_ prompt: String) throws {
        guard !NativeAIEnvironment.trim(prompt).isEmpty else { throw NativeAIError(message: "作成したいメールの内容を入力してください。") }
        guard prompt.utf8.count <= maximumPromptBytes else { throw NativeAIError(message: "作成の指示が長すぎます。32KB以内に短くしてください。") }
    }
    func generate(_ prompt: String) async throws -> CampaignAIDraft {
        try Self.validatePrompt(prompt); try NativeAIKeys.validate(apiKey); try Task.checkCancellation()
        var req = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"; req.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": "gpt-4o-mini", "temperature": 0.7,
            "messages": [["role": "system", "content": Self.instruction], ["role": "user", "content": prompt]]], options: .sortedKeys)
        let data: Data, response: HTTPURLResponse
        do {
            let sent = req
            (data, response) = try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
                group.addTask { try await request(sent) }
                group.addTask { try await Task.sleep(nanoseconds: timeoutNanoseconds); throw NativeAIError(message: "AIの作成が30秒以内に完了しませんでした。もう一度お試しください。", retryable: true) }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }; return result
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeAIError { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw NativeAIError(message: "OpenAIに接続できません。時間をおいて再実行してください。", retryable: true) }
        try Task.checkCancellation()
        guard response.url == Self.endpoint, data.count <= NativeEmbeddingClient.maximumResponseBytes else { throw NativeAIError(message: "AIの応答先または応答サイズが不正です。") }
        guard (200...299).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401, 403: message = "OpenAIのAPIキーと利用権限を確認してください。"
            case 429: message = "OpenAIの利用上限に達しました。利用枠を確認するか、時間をおいて再実行してください。"
            default: message = "メールを作成できませんでした（HTTP \(response.statusCode)）。"
            }
            throw NativeAIError(message: message, retryable: [408, 409, 429].contains(response.statusCode) || response.statusCode >= 500, status: response.statusCode)
        }
        struct Envelope: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message? }
            let choices: [Choice]
        }
        struct Content: Decodable { let subject: String?, html: String? }
        guard let response = try? JSONDecoder().decode(Envelope.self, from: data),
              let content = try? JSONDecoder().decode(Content.self, from: Data((response.choices.first?.message?.content ?? "{}").utf8)) else {
            throw NativeAIError(message: "AIが返したメールの形式を読み取れません。もう一度作成してください。")
        }
        let result = CampaignAIDraft(subject: content.subject ?? "", html: content.html ?? "")
        guard result.subject.utf8.count <= Self.maximumSubjectBytes, result.html.utf8.count <= Self.maximumHTMLBytes else { throw NativeAIError(message: "AIが作成したメールが大きすぎます。短い内容で再作成してください。") }
        return result
    }
}

enum CampaignAIContext {
    case template(NativeRecord?)
    case step(campaign: NativeRecord, original: NativeRecord?)
    func requireCurrent(_ service: CRMService) throws {
        try service.db.transaction {
            try service.authenticated()
            guard ["admin", "manager", "user"].contains(service.identity.role) else { throw NativeDBError.message("メールを編集する権限がありません。") }
            switch self {
            case let .template(record):
                if let record { guard record.model == "crm_campaign_templates", try service.campaignTemplate(record["id"].string).revision == record.revision else { throw NativeDBError.conflict } }
            case let .step(campaign, original):
                try service.requireCampaignStepDraft(campaign: campaign, original: original)
            }
        }
    }
}

struct CampaignAIResult {
    let draft: CampaignAIDraft
    // Keep only a non-secret choice receipt while waiting to apply on the UI thread.
    let choice: NativeAIKeyChoice
}
struct CampaignAIService {
    typealias Generate = (String, String) async throws -> CampaignAIDraft
    let keys: NativeAIKeys
    var generate: Generate = { try await CampaignAIClient(apiKey: $1).generate($0) }
    func create(prompt: String, context: CampaignAIContext) async throws -> CampaignAIResult {
        try CampaignAIClient.validatePrompt(prompt); try context.requireCurrent(keys.service); try Task.checkCancellation()
        guard let key = try keys.resolve(.openai, interactive: true) else { throw NativeAIError(message: "OpenAIのAPIキーが未設定です。「AI連携の設定」で登録してください。") }
        try context.requireCurrent(keys.service); try keys.requireCurrent(key); try Task.checkCancellation()
        let draft = try await generate(prompt, key.key)
        try Task.checkCancellation(); try validate(context: context, choice: key.choice)
        return .init(draft: draft, choice: key.choice)
    }
    func validate(context: CampaignAIContext, choice: NativeAIKeyChoice) throws {
        try keys.service.db.transaction { try context.requireCurrent(keys.service); try keys.requireCurrent(choice) }
    }
}
