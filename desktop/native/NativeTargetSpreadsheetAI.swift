import Foundation

/// Sends column names only; source row contents never enter the mapping prompt.
struct NativeTargetSpreadsheetAI {
    struct Result { let mapping: NativeTargetSpreadsheetMapping; let usedAI: Bool; let note: String? }
    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    static let instruction = "You are a data mapping assistant. Given a list of CSV column headers and a list of CRM field names, return a JSON object mapping each CSV header to the best matching CRM field, or null if no match. Only use the provided CRM field names as values. Return only valid JSON, no explanation."
    let keys: NativeAIKeys
    var request: NativeEmbeddingClient.Request = { try await NativeEmbeddingClient.providerTransport($0, endpoint: endpoint) }
    var timeoutNanoseconds: UInt64 = 30_000_000_000
    var admission: () throws -> Void
    private func current() throws { try admission(); try keys.service.authenticated(); try Task.checkCancellation() }
    func suggest(_ headers: [String]) async throws -> Result {
        try current()
        guard let key = try keys.resolve(.openai, interactive: true) else {
            return .init(mapping: .fallback(headers), usedAI: false, note: "APIキーが未設定のため、列名から対応を提案しました。")
        }
        try current(); try keys.requireCurrent(key)
        let fallback = NativeTargetSpreadsheetMapping.fallback(headers)
        do {
            let headerJSON = String(decoding: try JSONSerialization.data(withJSONObject: headers, options: [.withoutEscapingSlashes]), as: UTF8.self)
            let fieldJSON = String(decoding: try JSONSerialization.data(withJSONObject: NativeTargetSpreadsheetFields.keys, options: [.withoutEscapingSlashes]), as: UTF8.self)
            var req = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            req.httpMethod = "POST"; req.setValue("Bearer " + key.key, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model":"gpt-4o-mini","temperature":0,"response_format":["type":"json_object"],"messages":[["role":"system","content":Self.instruction],["role":"user","content":"CSV headers: \(headerJSON)\n\nCRM fields: \(fieldJSON)\n\nReturn a JSON object like: { \"CSV Header\": \"crm_field\" or null }"]]])
            let sent = req
            let (data,response) = try await withThrowingTaskGroup(of: (Data,HTTPURLResponse).self) { group in
                group.addTask { try await request(sent) }
                group.addTask { try await Task.sleep(nanoseconds: timeoutNanoseconds); throw NativeTargetSpreadsheetFailure(message: "AIの応答が時間内に届きませんでした。") }
                defer { group.cancelAll() }; guard let value = try await group.next() else { throw CancellationError() }; return value
            }
            try current(); try keys.requireCurrent(key)
            guard response.url == Self.endpoint, (200...299).contains(response.statusCode), data.count <= NativeEmbeddingClient.maximumResponseBytes,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String:Any],
                  let choices = body["choices"] as? [[String:Any]],let message = choices.first?["message"] as? [String:Any],let content = message["content"] as? String,!content.isEmpty else { throw NativeTargetSpreadsheetFailure(message:"AIの列対応を読み取れません。") }
            return .init(mapping: try .fromAI(content, headers: headers), usedAI: true, note: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A changed session/key or closed restore admission must not be
            // disguised as an ordinary provider failure/fuzzy success.
            try current(); try keys.requireCurrent(key)
            return .init(mapping: fallback, usedAI: false, note: "AIの提案を取得できなかったため、列名から対応を提案しました。")
        }
    }
}
