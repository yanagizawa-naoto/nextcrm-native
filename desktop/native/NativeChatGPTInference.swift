import Foundation

enum NativeChatGPTInference {
    typealias Stream = (URLRequest) async throws -> String
    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    static let maximumInputBytes = 65_536, maximumOutputBytes = 262_144
    struct Model: Equatable, Sendable { let slug: String, name: String }
    static func models(_ data: Data, _ response: HTTPURLResponse) throws -> [Model] {
        let object = try NativeChatGPTOAuth.json(data, response, expected: modelsEndpoint)
        guard let rows = object["models"] as? [[String: Any]], rows.count <= 1000 else { throw NativeChatGPTError.invalid("ChatGPTのモデル一覧を取得できません。") }
        var result: [Model] = [], seen = Set<String>()
        for row in rows where row["visibility"] as? String == "list" {
            guard let slug = row["slug"] as? String, !slug.isEmpty, slug.utf8.count <= 256,
                  let name = row["display_name"] as? String, !name.isEmpty, name.utf8.count <= 512, seen.insert(slug).inserted else { throw NativeChatGPTError.invalid("ChatGPTのモデル一覧が不正です。") }
            result.append(.init(slug: slug, name: name))
        }
        return result
    }
    static func request(accessToken: String, model: String, instruction: String, input: String) throws -> URLRequest {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.utf8.count + instruction.utf8.count <= maximumInputBytes, !model.isEmpty, model.utf8.count <= 256 else { throw NativeChatGPTError.invalid("入力を64KB以内にして、モデルを選択してください。") }
        _ = try NativeChatGPTOAuth.token(accessToken)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"; request.setValue("Bearer "+accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instruction, "input": [["role": "user", "content": input]], "store": false, "stream": true], options: .sortedKeys)
        return request
    }
    static func network(_ request: URLRequest) async throws -> String {
        guard request.url == endpoint, request.httpMethod == "POST" else { throw NativeChatGPTError.invalid("文章生成の接続先が不正です。") }
        let session = NativeChatGPTOAuth.session(); defer { session.invalidateAndCancel() }
        do {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse, response.url == endpoint else { throw NativeChatGPTError.invalid("文章生成の応答先が不正です。") }
            if response.statusCode != 200 {
                var data = Data()
                for try await byte in bytes { try Task.checkCancellation(); guard data.count < 65_536 else { break }; data.append(byte) }
                throw NativeChatGPTError.response(data, response)
            }
            guard response.mimeType?.lowercased() == "text/event-stream" else { throw NativeChatGPTError.invalid("ChatGPTからのストリームを確認できません。") }
            var decoder = Decoder()
            for try await byte in bytes { try Task.checkCancellation(); try decoder.append(byte) }
            return try decoder.finish()
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeChatGPTError { throw error }
        catch { try Task.checkCancellation(); throw NativeChatGPTError.invalid("文章生成の接続が途切れました。結果は確定していません。再実行すると利用量が増える場合があります。") }
    }
    /// Bounded incremental SSE parsing; neither all events nor raw provider bodies are retained.
    struct Decoder {
        private var line = Data(), event = Data(), total = 0, output = "", completed = false
        mutating func append(_ byte: UInt8) throws {
            total += 1; guard total <= 4_194_304 else { throw NativeChatGPTError.invalid("ChatGPTの応答が大きすぎます。入力を短くしてください。") }
            if byte == 10 { try consumeLine(); line.removeAll(keepingCapacity: true) }
            else { guard line.count < 1_048_576 else { throw NativeChatGPTError.invalid("ChatGPTの応答行が大きすぎます。") }; line.append(byte) }
        }
        private mutating func consumeLine() throws {
            if line.last == 13 { line.removeLast() }
            if line.isEmpty { try consumeEvent(); return }
            if line.starts(with: Data("data:".utf8)) {
                var part = line.dropFirst(5); if part.first == 32 { part = part.dropFirst() }
                guard event.count + part.count + 1 <= 1_048_576 else { throw NativeChatGPTError.invalid("ChatGPTの応答イベントが大きすぎます。") }
                if !event.isEmpty { event.append(10) }; event.append(contentsOf: part)
            }
        }
        private mutating func consumeEvent() throws {
            guard !event.isEmpty else { return }; defer { event.removeAll(keepingCapacity: true) }
            if event == Data("[DONE]".utf8) { return }
            guard let object = try? JSONSerialization.jsonObject(with: event) as? [String: Any], let type = object["type"] as? String else { throw NativeChatGPTError.invalid("ChatGPTのストリーム形式が不正です。") }
            switch type {
            case "response.output_text.delta":
                guard !completed, let delta = object["delta"] as? String, output.utf8.count + delta.utf8.count <= maximumOutputBytes else { throw NativeChatGPTError.invalid("ChatGPTの文章が長すぎるか不正です。") }; output += delta
            case "response.completed":
                guard !completed, let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else { throw NativeChatGPTError.invalid("文章生成の完了を確認できません。") }; completed = true
            case "response.failed", "response.incomplete", "error":
                let response = object["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any] ?? object["error"] as? [String: Any] ?? object
                let data = try JSONSerialization.data(withJSONObject: ["error": error])
                throw NativeChatGPTError.response(data, HTTPURLResponse(url: endpoint, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            case "response.refusal.delta", "response.refusal.done": throw NativeChatGPTError.invalid("ChatGPTはこの依頼に回答できませんでした。内容を確認してください。")
            default: break
            }
        }
        mutating func finish() throws -> String {
            if !line.isEmpty { try consumeLine(); line.removeAll() }; if !event.isEmpty { try consumeEvent() }
            guard completed, !output.isEmpty else { throw NativeChatGPTError.invalid("文章生成の完了を確認できません。途中の文章は保存しませんでした。") }; return output
        }
    }
}
