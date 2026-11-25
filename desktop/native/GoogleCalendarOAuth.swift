import Foundation
import Security
import CryptoKit

struct GoogleCalendarHTTPError: LocalizedError {
    let status: Int; let reason: String
    static let rateMarkers = ["ratelimitexceeded","userratelimitexceeded","quotaexceeded"]
    static let eventPermissionMarkers = ["forbiddenfornonorganizer","forbidden for non-organizer","cannotchangeorganizer","cannotchangeownattendeestatus","requiredaccesslevel"]
    static let revocationMarkers = ["invalid_grant","unauthorized_client"]
    var revoked: Bool { Self.revocationMarkers.contains(where:reason.contains) || status == 401 || (status == 403 && !(Self.rateMarkers+Self.eventPermissionMarkers).contains(where:reason.contains)) }
    var retryable: Bool { status == 429 || status >= 500 || Self.rateMarkers.contains(where:reason.contains) }
    var errorDescription: String? {
        if retryable { return "Googleへの接続が混み合っているか、一時的に利用できません。しばらくしてから再試行してください。" }
        if revoked { return "Googleの認証が無効か、必要な権限がありません。アカウントを接続し直してください。" }
        return "Googleカレンダーの接続を完了できませんでした。（HTTP \(status)）"
    }
}
private final class GoogleCalendarNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum GoogleCalendarOAuth {
    typealias Request = (URLRequest) async throws -> (Data,HTTPURLResponse)
    static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    static func random() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw NativeDBError.message("安全な認証情報を作成できません。もう一度お試しください。") }
        return base64url(Data(bytes))
    }
    static func authorizationURL(client: GoogleCalendarClientSettings, scope: GoogleCalendarScope, redirect: URL, state: String, verifier: String, loginHint: String?) throws -> URL {
        _ = try client.validated()
        guard redirect.scheme == "http", redirect.host == "127.0.0.1", let port = redirect.port, (1...65535).contains(port), redirect.user == nil, redirect.password == nil, redirect.query == nil, redirect.fragment == nil,
              redirect.path == "/" || redirect.path.isEmpty,
              verifier.range(of:#"^[A-Za-z0-9._~-]{43,128}$"#,options:.regularExpression) != nil,
              state.range(of:#"^[A-Za-z0-9_-]{43}$"#,options:.regularExpression) != nil else { throw NativeDBError.message("Googleの認証要求が不正です。") }
        var url = URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [URLQueryItem(name:"client_id",value:client.clientID),.init(name:"redirect_uri",value:redirect.absoluteString),.init(name:"response_type",value:"code"),.init(name:"scope",value:scope.requested),.init(name:"state",value:state),.init(name:"code_challenge",value:base64url(Data(SHA256.hash(data:Data(verifier.utf8))))),.init(name:"code_challenge_method",value:"S256"),.init(name:"access_type",value:"offline"),.init(name:"prompt",value:"consent")]
        if let loginHint { url.queryItems!.append(.init(name:"login_hint",value:loginHint)) }; return url.url!
    }
    static func network(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        try await boundedNetwork(request,maximumBytes:1_048_576)
    }
    static func boundedNetwork(_ request: URLRequest, maximumBytes: Int) async throws -> (Data,HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", ["oauth2.googleapis.com","www.googleapis.com"].contains(url.host), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw NativeDBError.message("Googleの接続先が不正です。") }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration:config,delegate:GoogleCalendarNoRedirects(),delegateQueue:nil); defer { session.invalidateAndCancel() }
        let (bytes,response) = try await session.bytes(for:request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= maximumBytes else { throw NativeDBError.message("Googleからの応答が大きすぎるか、不正です。") }
        var data = Data(); data.reserveCapacity(16_384)
        for try await byte in bytes { guard data.count < maximumBytes else { throw NativeDBError.message("Googleからの応答が大きすぎます。") }; data.append(byte) }
        return (data,response)
    }
    static func json(_ data: Data, response: HTTPURLResponse, maximumBytes: Int = 1_048_576) throws -> [String:Any] {
        guard data.count <= maximumBytes else { throw NativeDBError.message("Googleからの応答が大きすぎます。") }
        let json = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        guard (200...299).contains(response.statusCode) else {
            let object = json?["error"] as? [String:Any]
            let raw = ([json?["error"] as? String ?? "",object?["message"] as? String ?? ""] + ((object?["errors"] as? [[String:Any]]) ?? []).map{$0["reason"] as? String ?? ""}).joined(separator:" ").lowercased()
            let known = GoogleCalendarHTTPError.revocationMarkers + GoogleCalendarHTTPError.rateMarkers + GoogleCalendarHTTPError.eventPermissionMarkers + ["forbidden","insufficientpermissions","accessnotconfigured"]
            // Retain only known markers, never a server message containing credentials.
            throw GoogleCalendarHTTPError(status:response.statusCode,reason:known.filter(raw.contains).joined(separator:" "))
        }
        guard let json else { throw NativeDBError.message("Googleからの応答形式が不正です。") }; return json
    }
    static func form(_ values: [String:String]) -> Data {
        let allowed = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted{$0.key < $1.key}.map{$0.key.addingPercentEncoding(withAllowedCharacters:allowed)!+"="+$0.value.addingPercentEncoding(withAllowedCharacters:allowed)!}.joined(separator:"&").utf8)
    }
    static func exchange(client: GoogleCalendarClientSettings, code: String, verifier: String, redirect: URL, request: @escaping Request = network, now: Date = Date()) async throws -> GoogleCalendarGrant {
        _ = try client.validated()
        guard !code.isEmpty, code.utf8.count <= 8192 else { throw NativeDBError.message("Googleの認証コードが不正です。") }
        var fields = ["client_id":client.clientID,"code":code,"code_verifier":verifier,"redirect_uri":redirect.absoluteString,"grant_type":"authorization_code"]
        if !client.clientSecret.isEmpty { fields["client_secret"] = client.clientSecret }
        var tokenRequest = URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!); tokenRequest.httpMethod = "POST"; tokenRequest.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type"); tokenRequest.httpBody = form(fields)
        try Task.checkCancellation(); let (data,response) = try await request(tokenRequest); let tokens = try json(data,response:response)
        guard let access = tokens["access_token"] as? String, let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty, (tokens["token_type"] as? String)?.lowercased() == "bearer" else { throw NativeDBError.message("継続利用の認証を取得できませんでした。Googleでアクセスを許可してから、接続し直してください。") }
        var expires: Date?
        if let value = tokens["expires_in"] as? NSNumber { guard value.doubleValue.isFinite, value.doubleValue > 0, value.doubleValue <= 31_536_000 else { throw NativeDBError.message("Googleの認証有効期限が不正です。") }; expires = now.addingTimeInterval(value.doubleValue) }
        // Validate token bytes before putting them in an HTTP header.
        let grant = try GoogleCalendarGrant(accountEmail:"pending@example.invalid",accessToken:access,refreshToken:refresh,expiresAt:expires,grantedScopes:tokens["scope"] as? String).validated()
        var profile = URLRequest(url:URL(string:"https://www.googleapis.com/calendar/v3/users/me/calendarList/primary")!); profile.setValue("Bearer "+grant.accessToken,forHTTPHeaderField:"Authorization")
        try Task.checkCancellation(); let (primary,response2) = try await request(profile); let calendar = try json(primary,response:response2)
        guard let email = calendar["id"] as? String else { throw NativeDBError.message("Googleのメインカレンダーを確認できません。") }
        try Task.checkCancellation()
        return try GoogleCalendarGrant(accountEmail:email.lowercased(),accessToken:access,refreshToken:refresh,expiresAt:expires,grantedScopes:grant.grantedScopes).validated()
    }
}
