import Foundation
import CryptoKit

struct CampaignRelayError: LocalizedError {
    let message: String
    let retryable: Bool
    var errorDescription: String? { message }
}
private final class CampaignRelayNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Signed v1 relay transport. Persisting/applying the returned event cursor is
/// the caller's transaction; this layer never updates the CRM or sends mail.
struct CampaignRelayClient {
    static let maximumResponseBytes = 1_048_576
    typealias Request = (URLRequest) async throws -> (Data,HTTPURLResponse)
    struct Registration: Codable, Equatable { let sendId: String; let token: String; var providerId: String? = nil; var unsubscribedAt: String? = nil }
    struct Event: Decodable {
        let seq: Int64; let kind: String; let sendId: String; let token: String?; let providerId: String?
        let sourceEventId: String; let bodySHA256: String?; let receivedAt: String
    }
    struct State: Decodable {
        let version: Int; let instanceId: String; let clientId: String?; let head: Int64
        let registrations: [Registration]?; let events: [Event]?; let cursor: Int64?; let hasMore: Bool?
        let unsubscribeReady: Bool?
    }
    let baseURL: URL
    let clientID: String
    private var expectedInstanceID: String?
    private let key: SymmetricKey
    private let request: Request
    private let clock: () -> Date
    init(baseURL: URL, authKey: String, clientID: String, expectedInstanceID: String? = nil, allowLoopbackHTTP: Bool = false, request: @escaping Request = CampaignRelayClient.network, clock: @escaping () -> Date = Date.init) throws {
        guard var parts = URLComponents(url:baseURL,resolvingAgainstBaseURL:false), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "https" || (allowLoopbackHTTP && parts.scheme == "http" && ["127.0.0.1","localhost","[::1]","::1"].contains(host)),
              !parts.path.split(separator:"/").contains(".."), UUID(uuidString:clientID) != nil,
              expectedInstanceID == nil || UUID(uuidString:expectedInstanceID!) != nil else { throw Self.failure("公開受信窓口のURL・接続IDを確認してください。") }
        guard authKey.utf8.count == 43, authKey.range(of:#"^[A-Za-z0-9_-]{43}$"#,options:.regularExpression) != nil,
              let decoded = Data(base64Encoded:authKey.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")+"="), decoded.count == 32 else { throw Self.failure("公開受信窓口の認証キーを確認してください。") }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw Self.failure("公開受信窓口のURLが不正です。") }
        self.baseURL = url; self.clientID = clientID; self.expectedInstanceID = expectedInstanceID; key = SymmetricKey(data:decoded); self.request = request; self.clock = clock
    }
    func expecting(instanceID: String) throws -> Self {
        guard UUID(uuidString:instanceID) != nil else { throw Self.failure("公開受信窓口の識別子が不正です。") }
        var copy = self; copy.expectedInstanceID = instanceID; return copy
    }
    private static func failure(_ message: String, retryable: Bool = false) -> CampaignRelayError { CampaignRelayError(message:message,retryable:retryable) }
    static func network(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration:config,delegate:CampaignRelayNoRedirects(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (bytes,response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= maximumResponseBytes else { throw failure("受信窓口の応答が大きすぎるか、不正です。") }
        var data = Data(); data.reserveCapacity(64*1024)
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw failure("受信窓口の応答が大きすぎます。") }; data.append(byte)
        }
        return (data,response)
    }
    private func perform(_ method: String,_ endpoint: String, namespace: String = "api/native-campaigns/v1/", query: [URLQueryItem] = [], body: Data = Data(), allowUnbound: Bool = false) async throws -> State {
        guard body.count <= Self.maximumResponseBytes,
              var url = URLComponents(url:baseURL.appendingPathComponent(namespace+endpoint),resolvingAgainstBaseURL:false) else { throw Self.failure("受信窓口への送信内容が不正です。") }
        if !query.isEmpty { url.queryItems = query }
        guard let address = url.url else { throw Self.failure("受信窓口のURLが不正です。") }
        let time = clock().timeIntervalSince1970
        guard time.isFinite, time >= 0, time < 253_402_300_800 else { throw Self.failure("Macの日時を確認してください。") }
        let timestamp = String(Int64(floor(time))), nonce = UUID().uuidString.lowercased(), target = url.percentEncodedPath+(url.percentEncodedQuery.map{"?"+$0} ?? "")
        var signed = Data(("nextcrm-relay-v1-request\n"+method+"\n"+target+"\n"+timestamp+"\n"+nonce+"\n").utf8); signed.append(body)
        var request = URLRequest(url:address,cachePolicy:.reloadIgnoringLocalCacheData); request.httpMethod = method
        request.setValue(timestamp,forHTTPHeaderField:"X-NextCRM-Timestamp"); request.setValue(nonce,forHTTPHeaderField:"X-NextCRM-Nonce")
        request.setValue(Data(HMAC<SHA256>.authenticationCode(for:signed,using:key)).base64EncodedString(),forHTTPHeaderField:"X-NextCRM-Signature")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type"); request.setValue("application/json",forHTTPHeaderField:"Accept")
        if !body.isEmpty { request.httpBody = body }
        let data: Data, response: HTTPURLResponse
        do { (data,response) = try await self.request(request) }
        catch let error as CampaignRelayError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { if Task.isCancelled { throw CancellationError() }; throw Self.failure("公開受信窓口へ接続できません。時間をおいて再試行してください。",retryable:true) }
        try Task.checkCancellation()
        guard data.count <= Self.maximumResponseBytes else { throw Self.failure("受信窓口の応答が大きすぎます。") }
        var received = Data(("nextcrm-relay-v1-response\n"+nonce+"\n"+String(response.statusCode)+"\n").utf8); received.append(data)
        guard let signature = response.value(forHTTPHeaderField:"X-NextCRM-Signature"), let mac = Data(base64Encoded:signature), mac.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(mac,authenticating:received,using:key) else { throw Self.failure("公開受信窓口の応答を認証できません。接続先・認証キー・Macの日時を確認してください。",retryable:response.statusCode >= 500) }
        guard (200..<300).contains(response.statusCode) else {
            let message = response.statusCode == 409 ? "公開受信窓口の接続先または同期位置が一致しません。履歴を確認してください。" : "公開受信窓口が処理を完了できませんでした。設定を確認してください。"
            throw Self.failure(message,retryable:response.statusCode == 429 || response.statusCode >= 500)
        }
        guard let state = try? JSONDecoder().decode(State.self,from:data), state.version == 1, UUID(uuidString:state.instanceId) != nil,
              state.head >= 0, state.head <= 9_007_199_254_740_991,
              expectedInstanceID == nil || state.instanceId == expectedInstanceID,
              state.clientId == clientID || (allowUnbound && state.clientId == nil) else { throw Self.failure("公開受信窓口の識別子・形式が一致しません。設定を確認してください。") }
        return state
    }
    func health() async throws -> State { try await perform("GET","health",allowUnbound:true) }
    func checkUnsubscribeRoute() async throws {
        let state = try await perform("GET","unsubscribe",namespace:"api/campaigns/",query:[.init(name:"check",value:"ready"),.init(name:"clientId",value:clientID)])
        guard state.unsubscribeReady == true else { throw Self.failure("配信停止ページの公開経路を確認できません。受信窓口の設定を確認してください。") }
    }
    func bind() async throws -> State {
        try await perform("POST","bind",body:JSONSerialization.data(withJSONObject:["clientId":clientID],options:.sortedKeys))
    }
    func register(_ items: [Registration]) async throws -> State {
        guard !items.isEmpty, items.count <= 100, Set(items.map(\.sendId)).count == items.count,
              Set(items.map(\.token)).count == items.count, items.allSatisfy({UUID(uuidString:$0.sendId) != nil && UUID(uuidString:$0.token) != nil && ($0.providerId == nil || Self.opaque($0.providerId!,limit:512))}) else { throw Self.failure("送信・配信停止の登録内容が不正です。") }
        struct Body: Encodable { let clientId: String; let registrations: [Registration] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let state = try await perform("POST","registrations",body:encoder.encode(Body(clientId:clientID,registrations:items)))
        guard let registrations = state.registrations, registrations.count == items.count, Set(registrations.map(\.sendId)).count == items.count else { throw Self.failure("送信情報の登録結果が不正です。") }
        let expected = Dictionary(uniqueKeysWithValues:items.map{($0.sendId,$0)})
        for row in registrations {
            guard let item = expected[row.sendId], row.token == item.token,
                  item.providerId == nil || row.providerId == item.providerId,
                  row.providerId == nil || Self.opaque(row.providerId!,limit:512),
                  row.unsubscribedAt == nil || Self.date(row.unsubscribedAt!) != nil else { throw Self.failure("保存した送信情報と受信窓口の登録結果が一致しません。") }
        }
        return state
    }
    func events(after: Int64) async throws -> State {
        guard after >= 0, after <= 9_007_199_254_740_991 else { throw Self.failure("配信結果の同期位置が不正です。") }
        let state = try await perform("GET","events",query:[.init(name:"clientId",value:clientID),.init(name:"after",value:String(after))])
        guard state.head >= after, let events = state.events, events.count <= 100, let cursor = state.cursor, let more = state.hasMore,
              cursor == (events.last?.seq ?? after), cursor <= state.head, more == (cursor < state.head), !more || !events.isEmpty else { throw Self.failure("配信結果の履歴・同期位置が一致しません。") }
        var previous = after
        for event in events {
            guard event.seq > previous, event.seq <= state.head, UUID(uuidString:event.sendId) != nil,
                  Self.opaque(event.sourceEventId,limit:255), let received = Self.date(event.receivedAt), received <= clock().addingTimeInterval(300) else { throw Self.failure("配信結果の内容または順番が不正です。") }
            if event.kind == "unsubscribe" {
                guard event.token.flatMap(UUID.init(uuidString:)) != nil, event.providerId == nil, event.bodySHA256 == nil else { throw Self.failure("配信停止の記録が不正です。") }
            } else {
                guard ["email.delivered","email.bounced","email.opened","email.clicked"].contains(event.kind),
                      let provider = event.providerId, Self.opaque(provider,limit:512), event.token == nil,
                      let hash = event.bodySHA256, hash.utf8.count == 64, hash.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else { throw Self.failure("配信結果の記録が不正です。") }
            }
            previous = event.seq
        }
        return state
    }
    private static func opaque(_ value: String, limit: Int) -> Bool { !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) }
    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from:string) ?? ISO8601DateFormatter().date(from:string)
    }
}
