import Foundation
import Security
import CryptoKit

/// Public-client Sign in with ChatGPT. No application secret or borrowed client ID.
enum NativeChatGPTOAuth {
    typealias Request = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let issuer = "https://auth.openai.com"
    static let authorizeEndpoint = URL(string: issuer + "/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: issuer + "/api/accounts/oauth/token")!
    static let discoveryEndpoint = URL(string: issuer + "/.well-known/openid-configuration")!
    static let jwksEndpoint = URL(string: issuer + "/.well-known/jwks.json")!
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let maximumBytes = 1_048_576
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeChatGPTError.invalid("安全な認証情報を作成できません。") }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode64(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= maximumBytes, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), value.count % 4 != 1,
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4-value.count%4)%4)), base64(data) == value else { throw NativeChatGPTError.invalid("認証の符号化が不正です。") }
        return data
    }
    static func exact(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
    static func token(_ value: String, maximum: Int = 65_536) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximum, value.utf8.allSatisfy({ (33...126).contains($0) }) else { throw NativeChatGPTError.invalid("認証の応答が不正です。") }; return value
    }
    static func client(_ value: String) throws -> String {
        guard value.hasPrefix("oaiapp_"), value.utf8.count <= 256, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw NativeChatGPTError.invalid("アプリの登録を確認できません。接続し直してください。") }; return value
    }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&").utf8)
    }
    struct Attempt {
        let state: String, nonce: String, verifier: String, hostID: String, redirect: URL
        let clientID: String?, idTokenHint: String?, loginHint: String?
        let reconsent: Bool
        func authorizationURL() throws -> URL {
            guard redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.path == "/auth/callback", redirect.port != nil, redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil,
                  UUID(uuidString: String(hostID.dropFirst("urn:uuid:".count))) != nil, hostID.hasPrefix("urn:uuid:"), [state, nonce, verifier].allSatisfy({ $0.utf8.count == 43 }) else { throw NativeChatGPTError.invalid("認証の開始情報が不正です。") }
            if let clientID { _ = try client(clientID) }
            var u = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = [.init(name: "client_id", value: clientID ?? "dynamic_agent_client"), .init(name: "ext_agent_host_id", value: hostID), .init(name: "redirect_uri", value: redirect.absoluteString), .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes), .init(name: "resource", value: resource), .init(name: "state", value: state), .init(name: "nonce", value: nonce), .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: base64(Data(SHA256.hash(data: Data(verifier.utf8)))))]
            if clientID == nil { items.append(.init(name: "agent_name_hint", value: "NextCRM Native")) }
            else {
                if let idTokenHint { items.append(.init(name: "id_token_hint", value: idTokenHint)) }
                if let loginHint { items.append(.init(name: "login_hint", value: loginHint)) }
            }
            if reconsent { items.append(.init(name: "prompt", value: "consent")) }
            u.queryItems = items; return u.url!
        }
        func callback(_ url: URL) throws -> (code: String, clientID: String) {
            guard var got = URLComponents(url: url, resolvingAgainstBaseURL: false), let expected = URLComponents(url: redirect, resolvingAgainstBaseURL: false), got.fragment == nil else { throw NativeChatGPTError.invalid("認証の戻り先が不正です。") }
            let items = got.queryItems ?? []; got.query = nil
            guard got.url == expected.url else { throw NativeChatGPTError.invalid("認証の戻り先が一致しません。") }
            func values(_ key: String) -> [String] { items.filter { $0.name == key }.map { $0.value ?? "" } }
            guard values("state").count == 1, exact(values("state")[0], state) else { throw NativeChatGPTError.invalid("認証の確認情報が一致しません。") }
            if !values("error").isEmpty {
                guard values("error").count == 1 else { throw NativeChatGPTError.invalid("認証の応答が不正です。") }
                throw NativeChatGPTError.invalid(values("error") == ["access_denied"] ? "ChatGPTへの接続を取り消しました。" : "ChatGPTの認証を完了できませんでした。")
            }
            guard values("code").count == 1, values("client_id").count <= 1 else { throw NativeChatGPTError.invalid("認証の応答が不正です。") }
            let issued = values("client_id").first ?? clientID ?? ""
            _ = try client(issued)
            if let clientID, !exact(clientID, issued) { throw NativeChatGPTError.invalid("選択したアカウントの登録が一致しません。") }
            return (try token(values("code")[0], maximum: 8192), issued)
        }
    }
    static func post(_ fields: [String: String], to url: URL = tokenEndpoint) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept"); request.httpBody = form(fields); return request
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return false }
        if url.host == "auth.openai.com" { return url.path.hasPrefix("/api/accounts/") || ["/.well-known/openid-configuration", "/.well-known/jwks.json"].contains(url.path) }
        return url.host == "api.openai.com" && ["/v1/models", "/v1/responses"].contains(url.path)
    }
    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, allowed(url) else { throw NativeChatGPTError.invalid("ChatGPTの接続先が不正です。") }
        let session = session(); defer { session.invalidateAndCancel() }
        do {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse, response.url == url, response.expectedContentLength <= maximumBytes else { throw NativeChatGPTError.invalid("ChatGPTの応答が大きすぎるか不正です。") }
            var data = Data(); data.reserveCapacity(4096)
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < maximumBytes else { throw NativeChatGPTError.invalid("ChatGPTの応答が大きすぎます。") }; data.append(byte) }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeChatGPTError { throw error }
        catch { try Task.checkCancellation(); throw NativeChatGPTError.invalid("ChatGPTに接続できません。ネットワークを確認してください。") }
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: NativeChatGPTNoRedirects(), delegateQueue: nil)
    }
    static func json(_ data: Data, _ response: HTTPURLResponse, expected: URL) throws -> [String: Any] {
        guard data.count <= maximumBytes, response.url == expected else { throw NativeChatGPTError.invalid("ChatGPTの応答を確認できません。") }
        guard response.statusCode == 200 else { throw NativeChatGPTError.response(data, response) }
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeChatGPTError.invalid("ChatGPTの応答形式が不正です。") }; return value
    }
}

struct NativeChatGPTError: LocalizedError {
    let message: String
    var status: Int? = nil, code: String? = nil, requestID: String? = nil, bodyShape: String? = nil
    var errorDescription: String? { message }
    static func invalid(_ message: String) -> Self { .init(message: message) }
    var terminalRefresh: Bool { ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") }
    static func response(_ data: Data, _ response: HTTPURLResponse) -> Self {
        let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let object = value?["error"] as? [String: Any]
        func safe(_ raw: String?) -> String? { guard let raw, raw.utf8.count <= 160, raw.utf8.allSatisfy({ (45...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { return nil }; return raw }
        let code = safe(object?["code"] as? String ?? value?["error"] as? String)
        let message: String
        switch code {
        case "subscription_sharing_user_not_eligible": message = "このChatGPTアカウント・ワークスペースではプランの利用が許可されていません。APIキー方式も選べます。"
        case "subscription_sharing_usage_limit_exceeded": message = "ChatGPTプランまたはこのアプリの利用上限に達しました。「利用状況を管理」で確認してください。"
        case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported": message = "この機能はChatGPTプランの接続では利用できません。APIキー方式を選んでください。"
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused": message = "ChatGPTの認証が失効しました。同じアカウントで接続し直してください。"
        default:
            switch response.statusCode {
            case 401: message = "ChatGPTの認証とプラン利用の許可を確認してください。"
            case 403: message = "アカウント・地域・ワークスペースのポリシーにより利用できません。"
            case 429: message = "ChatGPTの利用上限を確認するか、時間をおいて再実行してください。"
            default: message = "ChatGPTへの要求が完了しませんでした（HTTP \(response.statusCode)）。時間をおいて再実行してください。"
            }
        }
        return .init(message: message, status: response.statusCode, code: code, requestID: safe(response.value(forHTTPHeaderField: "x-request-id") ?? response.value(forHTTPHeaderField: "openai-request-id")), bodyShape: object != nil ? "error-object" : value?["detail"] != nil ? "detail" : value != nil ? "json" : "non-json")
    }
}
private final class NativeChatGPTNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
