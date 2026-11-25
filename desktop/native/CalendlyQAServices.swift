import Foundation

/// Only fixed public fixture credentials are accepted. No entered real secret is
/// persisted and provider requests are simulated without any external network.
final class CalendlyQAServices: CalendlySecretStore {
    static let authKey = Data(repeating:31,count:32).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
    static let apiToken = "native-calendly-qa-token", signingKey = "native-calendly-fixture-key"
    private let db: NativeDatabase
    init(db: NativeDatabase) throws { _ = try CampaignRelayQACredentials(db:db); self.db = db }
    private static func local(_ url: URL?) -> Bool { url?.scheme == "http" && ["127.0.0.1","localhost","::1","[::1]"].contains(url?.host ?? "") }
    static func relay(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard local(request.url) else { throw NativeDBError.message("検証モードではMac内の予約受信窓口だけを利用できます。") }; return try await CalendlyRelayClient.network(request)
    }
    func load(id: String,interactive: Bool) throws -> Data? {
        guard UUID(uuidString:id) != nil, let raw = try db.metadata("qa.calendly.secret."+id), !raw.isEmpty else { return nil }
        let fields = try JSONDecoder().decode([String:String].self,from:Data(raw.utf8))
        guard let url = fields["publicURL"], Self.local(URL(string:url)), let client = fields["clientID"], let instance = fields["instanceID"] else { throw NativeDBError.conflict }
        return try JSONEncoder().encode(CalendlyCredentials(publicURL:url,clientID:client,instanceID:instance,authKey:Self.authKey,apiToken:Self.apiToken,signingKey:Self.signingKey))
    }
    func save(id: String,data: Data) throws {
        let value = try JSONDecoder().decode(CalendlyCredentials.self,from:data)
        guard UUID(uuidString:id) != nil, Self.local(URL(string:value.publicURL)), value.authKey == Self.authKey, value.apiToken == Self.apiToken, value.signingKey == Self.signingKey else { throw NativeDBError.message("検証専用の接続キー・APIトークン・署名キーを使用してください。") }
        try db.transaction { guard try db.metadata("qa.calendly.secret."+id) == nil else { throw NativeDBError.conflict }; try db.setMetadata("qa.calendly.secret."+id,value:String(decoding:try JSONEncoder().encode(["publicURL":value.publicURL,"clientID":value.clientID,"instanceID":value.instanceID]),as:UTF8.self)) }
    }
    func remove(id: String) throws { try db.setMetadata("qa.calendly.secret."+id,value:"") }
    func provider(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
        guard request.url?.host == "api.calendly.com", request.value(forHTTPHeaderField:"Authorization") == "Bearer "+Self.apiToken else { throw NativeDBError.message("検証用の予約API認証情報を使用してください。") }
        let organization = "https://api.calendly.com/organizations/native-qa", path = request.url!.path, method = request.httpMethod ?? "GET"
        let pair: ([String:Any],Int) = try db.transaction {
            let raw = try db.metadata("qa.calendly.subscriptions") ?? "{}"; var rows = (try JSONSerialization.jsonObject(with:Data(raw.utf8))) as! [String:[String:Any]]
            if path == "/users/me" { return (["resource":["current_organization":organization]],200) }
            if path == "/webhook_subscriptions", method == "GET" { return (["collection":Array(rows.values),"pagination":["next_page_token":NSNull()]],200) }
            if path == "/webhook_subscriptions", method == "POST", let body = request.httpBody, body.count <= 65_536, let fields = try JSONSerialization.jsonObject(with:body) as? [String:Any], let callback = fields["url"] as? String, Self.local(URL(string:callback)), fields["signing_key"] as? String == Self.signingKey {
                let uri = "https://api.calendly.com/webhook_subscriptions/"+UUID().uuidString.lowercased()
                let row: [String:Any] = ["uri":uri,"callback_url":callback,"organization":organization,"scope":"organization","state":"active","events":CalendlyAPIClient.events]; rows[uri] = row
                try db.setMetadata("qa.calendly.subscriptions",value:String(decoding:try JSONSerialization.data(withJSONObject:rows),as:UTF8.self)); return (["resource":row],201)
            }
            if path.hasPrefix("/webhook_subscriptions/"), method == "GET" { return rows[request.url!.absoluteString].map{(["resource":$0],200)} ?? ([:],404) }
            if path.hasPrefix("/webhook_subscriptions/"), method == "DELETE" { let old = rows.removeValue(forKey:request.url!.absoluteString); try db.setMetadata("qa.calendly.subscriptions",value:String(decoding:try JSONSerialization.data(withJSONObject:rows),as:UTF8.self)); return ([:],old == nil ? 404 : 204) }
            return ([:],400)
        }
        return (try JSONSerialization.data(withJSONObject:pair.0),HTTPURLResponse(url:request.url!,statusCode:pair.1,httpVersion:nil,headerFields:nil)!)
    }
}
