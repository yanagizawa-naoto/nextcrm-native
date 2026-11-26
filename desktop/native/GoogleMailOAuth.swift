import Foundation
import CoreFoundation

/// The installed client is a public client. Tokens never enter SQLite, URLs,
/// process arguments or diagnostics. All network seams are injectable.
enum GoogleMailFailure: Error, LocalizedError {
    case invalid, reconnect, temporary, cancelled, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "Googleメールの認証結果または接続設定が不正です。接続し直してください。"
        case .reconnect: return "Googleメールの認証が無効か、必要な権限がありません。「Googleを接続し直す」を選んでください。"
        case .temporary: return "Googleメールに一時的に接続できません。しばらくしてから再試行してください。"
        case .cancelled: return "Googleメールへの接続を中止しました。"
        case .unavailable: return "この配布版にはGoogleログインの設定がありません。配布元に確認してください。"
        }
    }
}
struct GoogleMailGrant: Codable, Equatable {
    let email: String, accessToken: String, refreshToken: String
    let expiresAt: Date
    let scopes: String
    var sentFolder = "[Gmail]/Sent Mail"
    func validate() throws {
        _ = try NativeMailAddress.checked(email); _ = try NativeMailUTF7.encode(sentFolder)
        guard email == email.lowercased(), email.utf8.count <= 320,
              [accessToken,refreshToken].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16_384 && $0.unicodeScalars.allSatisfy({(33...126).contains($0.value)}) }),
              expiresAt.timeIntervalSince1970.isFinite, scopes.utf8.count <= 16_384,
              scopes.split(separator:" ").contains(Substring(GoogleMailOAuth.scope)) else { throw GoogleMailFailure.invalid }
    }
}
struct GoogleMailStoredGrant: Codable {
    var version = 1
    let accountID: String, userID: String, namespace: String
    let client: GoogleCalendarClientSettings
    let grant: GoogleMailGrant
    func validate() throws {
        guard version == 1, UUID(uuidString:accountID) != nil, UUID(uuidString:userID) != nil,
              namespace.count == 64, namespace.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else { throw GoogleMailFailure.invalid }
        _ = try client.validated(); try grant.validate()
    }
    static func settings(email:String) -> NativeMailAccountSettings {
        .init(label:email,username:email,imap:.init(host:"imap.gmail.com",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.gmail.com",port:465,tls:.implicitTLS),sentFolder:"[Gmail]/Sent Mail")
    }
    static func validate(settings:NativeMailAccountSettings,email:String) throws {
        let fixed = Self.settings(email:email)
        guard settings.username == email, settings.imap == fixed.imap, settings.smtp == fixed.smtp else { throw GoogleMailFailure.invalid }
        try settings.validate()
    }
}
enum GoogleMailOAuth {
    typealias Request = GoogleCalendarOAuth.Request
    static let scope = "https://mail.google.com/"
    static func network(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        try await GoogleCalendarOAuth.network(request)
    }
    static func response(_ request:URLRequest,using transport:@escaping Request) async throws -> [String:Any] {
        do { try Task.checkCancellation(); let (data,response) = try await transport(request); try Task.checkCancellation(); return try GoogleCalendarOAuth.json(data,response:response) }
        catch is CancellationError { throw CancellationError() }
        catch let error as GoogleCalendarHTTPError { throw error.retryable ? GoogleMailFailure.temporary : GoogleMailFailure.reconnect }
        catch let error as GoogleMailFailure { throw error }
        catch { if Task.isCancelled { throw CancellationError() }; throw GoogleMailFailure.temporary }
    }
    static func authorizationURL(client:GoogleCalendarClientSettings,redirect:URL,state:String,verifier:String,loginHint:String?) throws -> URL {
        // Reuse the audited loopback/PKCE/state validation; replace only scope.
        let validated = try GoogleCalendarOAuth.authorizationURL(client:client,scope:.readonly,redirect:redirect,state:state,verifier:verifier,loginHint:loginHint)
        var url = URLComponents(url:validated,resolvingAgainstBaseURL:false)!
        url.queryItems = url.queryItems!.map { $0.name == "scope" ? URLQueryItem(name:"scope",value:scope) : $0 }
        return url.url!
    }
    private static func tokenRequest(client:GoogleCalendarClientSettings,fields:[String:String]) throws -> URLRequest {
        _ = try client.validated(); var values = fields; values["client_id"] = client.clientID
        if !client.clientSecret.isEmpty { values["client_secret"] = client.clientSecret }
        var request = URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type"); request.httpBody = GoogleCalendarOAuth.form(values); return request
    }
    private static func grant(_ tokens:[String:Any],email:String,previous:GoogleMailGrant?,now:Date) throws -> GoogleMailGrant {
        guard let access = tokens["access_token"] as? String, (tokens["token_type"] as? String)?.lowercased() == "bearer",
              let seconds = tokens["expires_in"] as? NSNumber, CFGetTypeID(seconds) != CFBooleanGetTypeID(), seconds.doubleValue.isFinite, seconds.doubleValue > 0, seconds.doubleValue <= 31_536_000,
              tokens["refresh_token"] == nil || tokens["refresh_token"] is String,
              tokens["scope"] == nil || tokens["scope"] is String,
              let refresh = tokens["refresh_token"] as? String ?? previous?.refreshToken else { throw GoogleMailFailure.invalid }
        var value = GoogleMailGrant(email:email,accessToken:access,refreshToken:refresh,expiresAt:now.addingTimeInterval(seconds.doubleValue),scopes:tokens["scope"] as? String ?? previous?.scopes ?? scope)
        if let previous { value.sentFolder = previous.sentFolder }
        try value.validate(); return value
    }
    static func exchange(client:GoogleCalendarClientSettings,code:String,verifier:String,redirect:URL,request:@escaping Request = network,now:Date = Date()) async throws -> GoogleMailGrant {
        _ = try authorizationURL(client:client,redirect:redirect,state:String(repeating:"x",count:43),verifier:verifier,loginHint:nil)
        guard !code.isEmpty, code.utf8.count <= 8192, !code.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}) else { throw GoogleMailFailure.invalid }
        let tokens = try await response(tokenRequest(client:client,fields:["grant_type":"authorization_code","code":code,"code_verifier":verifier,"redirect_uri":redirect.absoluteString]),using:request)
        let pending = try grant(tokens,email:"pending@example.invalid",previous:nil,now:now)
        var profile = URLRequest(url:URL(string:"https://www.googleapis.com/gmail/v1/users/me/profile")!)
        profile.setValue("Bearer "+pending.accessToken,forHTTPHeaderField:"Authorization")
        let body = try await response(profile,using:request)
        guard let email = body["emailAddress"] as? String else { throw GoogleMailFailure.invalid }
        return try grant(tokens,email:email.lowercased(),previous:nil,now:now)
    }
    static func refresh(_ stored:GoogleMailStoredGrant,request:@escaping Request = network,now:Date = Date()) async throws -> GoogleMailGrant {
        try stored.validate()
        let body = try await response(tokenRequest(client:stored.client,fields:["grant_type":"refresh_token","refresh_token":stored.grant.refreshToken]),using:request)
        return try grant(body,email:stored.grant.email,previous:stored.grant,now:now)
    }
    static func revoke(_ stored:GoogleMailStoredGrant,request:@escaping Request = network) async throws {
        try stored.validate()
        var query = URLRequest(url:URL(string:"https://oauth2.googleapis.com/revoke")!); query.httpMethod = "POST"
        query.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type"); query.httpBody = GoogleCalendarOAuth.form(["token":stored.grant.refreshToken])
        do {
            try Task.checkCancellation(); let (_,response) = try await request(query); try Task.checkCancellation()
            guard response.statusCode == 200 else { throw response.statusCode == 429 || response.statusCode >= 500 ? GoogleMailFailure.temporary : GoogleMailFailure.reconnect }
        } catch is CancellationError { throw CancellationError() } catch let error as GoogleMailFailure { throw error } catch { if Task.isCancelled { throw CancellationError() }; throw GoogleMailFailure.temporary }
    }
    static func sentFolder(_ data:Data) throws -> String {
        var matches:[String] = []
        for row in try NativeMailIMAP.rows(data) where row.count >= 5 && row[0].string == "*" && row[1].string?.uppercased() == "LIST" {
            guard case .list(let flags) = row[2],let name = row[4].string else { throw GoogleMailFailure.invalid }
            if flags.contains(where:{$0.string?.lowercased() == "\\sent"}) && !flags.contains(where:{$0.string?.lowercased() == "\\noselect"}) { matches.append(try NativeMailUTF7.decode(name)) }
        }
        guard matches.count == 1 else { throw NativeDBError.message("Googleの送信済みフォルダを確認できません。GmailのIMAP設定を確認してください。") }
        return matches[0]
    }
    static func browser(client:GoogleCalendarClientSettings,loginHint:String?,open:@escaping GoogleCalendarBrowserAuthorization.Open,request:@escaping Request = network) async throws -> GoogleMailGrant {
        let state = try GoogleCalendarOAuth.random(), verifier = try GoogleCalendarOAuth.random()
        let listener = try GoogleCalendarLoopback(state:state); defer { listener.stop() }
        let redirect = try await listener.start()
        try await open(authorizationURL(client:client,redirect:redirect,state:state,verifier:verifier,loginHint:loginHint))
        let code = try await listener.code()
        var grant = try await exchange(client:client,code:code,verifier:verifier,redirect:redirect,request:request)
        let settings = GoogleMailStoredGrant.settings(email:grant.email)
        let query = NativeMailWireRequest(endpoint:settings.imap,username:settings.username,password:"",command:"LIST \"\" \"*\"",oauthBearer:grant.accessToken)
        grant.sentFolder = try sentFolder(await NativeMailWire.perform(query).body)
        try Task.checkCancellation(); return grant
    }
}
