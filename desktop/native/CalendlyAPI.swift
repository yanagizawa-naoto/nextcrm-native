import Foundation

struct CalendlyAPIError: LocalizedError {
    let status: Int?, message: String
    var errorDescription: String? { message }
    var definiteCreateRejection: Bool { status.map{[400,401,403,404,422,429].contains($0)} ?? false }
}

/// Fixed provider origin; response URLs and pagination links never receive a token.
struct CalendlyAPIClient {
    typealias Request = CalendlyRelayClient.Request
    struct Subscription: Codable,Equatable {
        let uri: String, callback_url: String, state: String, scope: String, organization: String
        let events: [String]
        func matches(callback: String,organization: String) -> Bool {
            callback_url == callback && self.organization == organization && scope == "organization" && Set(events) == Set(CalendlyAPIClient.events) && events.count == 2
        }
    }
    private struct Resource<T: Decodable>: Decodable { let resource: T }
    private struct User: Decodable { let current_organization: String }
    private struct Page: Decodable { struct Pagination: Decodable { let next_page_token: String? }; let collection: [Subscription], pagination: Pagination }
    static let events = ["invitee.created","invitee.canceled"]
    let token: String
    private let request: Request
    init(token: String,request: @escaping Request = CalendlyRelayClient.network) throws {
        guard !token.isEmpty, token.utf8.count <= 16_384, token.unicodeScalars.allSatisfy({(33...126).contains($0.value)}) else { throw Self.failure("CalendlyのAPIトークンを確認してください。") }
        self.token = token; self.request = request
    }
    static func failure(_ message: String,status: Int? = nil) -> CalendlyAPIError { .init(status:status,message:message) }
    static func providerURI(_ raw: String,kind: String) throws -> URL {
        guard let p = URLComponents(string:raw), p.scheme == "https", p.host == "api.calendly.com", p.user == nil, p.password == nil, p.port == nil, p.query == nil, p.fragment == nil,
              p.percentEncodedPath == p.path, p.path.range(of:"^/"+kind+"/[A-Za-z0-9_-]{1,200}$",options:.regularExpression) != nil, let url = p.url else { throw failure("Calendlyの応答に不正な参照先があります。") }; return url
    }
    private func perform(_ method: String,_ url: URL,body: [String:Any]? = nil,notFoundOK: Bool = false) async throws -> Data? {
        var req = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData); req.httpMethod = method
        req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization"); req.setValue("application/json",forHTTPHeaderField:"Accept")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject:body,options:.sortedKeys); req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        try Task.checkCancellation(); let result: (Data,HTTPURLResponse)
        do { result = try await request(req) } catch is CancellationError { throw CancellationError() } catch { if Task.isCancelled { throw CancellationError() }; throw Self.failure("Calendlyとの通信結果を確認できません。") }
        try Task.checkCancellation()
        guard result.0.count <= CalendlyRelayClient.maximumResponseBytes else { throw Self.failure("Calendlyの応答が大きすぎます。") }
        if notFoundOK && result.1.statusCode == 404 { return nil }
        guard (200..<300).contains(result.1.statusCode) else {
            let message = [401,403].contains(result.1.statusCode) ? "CalendlyのAPIトークンと通知の読み取り・書き込み権限を確認してください。" : "Calendlyの処理が完了しませんでした（HTTP \(result.1.statusCode)）。"
            throw Self.failure(message,status:result.1.statusCode)
        }; return result.0
    }
    private func decode<T: Decodable>(_ type: T.Type,_ bytes: Data) throws -> T { guard let value = try? JSONDecoder().decode(type,from:bytes) else { throw Self.failure("Calendlyの応答を読み取れません。") }; return value }
    func organization() async throws -> String {
        let value = try decode(Resource<User>.self,await perform("GET",URL(string:"https://api.calendly.com/users/me")!)!).resource.current_organization
        _ = try Self.providerURI(value,kind:"organizations"); return value
    }
    private func validated(_ value: Subscription) throws -> Subscription {
        _ = try Self.providerURI(value.uri,kind:"webhook_subscriptions"); _ = try Self.providerURI(value.organization,kind:"organizations")
        guard value.callback_url.utf8.count <= 4096, value.events.count <= 30 else { throw Self.failure("Calendlyの通知登録情報が不正です。") }; return value
    }
    func get(_ uri: String) async throws -> Subscription? {
        let url = try Self.providerURI(uri,kind:"webhook_subscriptions")
        guard let data = try await perform("GET",url,notFoundOK:true) else { return nil }
        let result = try validated(decode(Resource<Subscription>.self,data).resource)
        guard result.uri == uri else { throw Self.failure("Calendlyの通知登録の識別子が一致しません。") }; return result
    }
    func delete(_ uri: String) async throws { _ = try await perform("DELETE",Self.providerURI(uri,kind:"webhook_subscriptions"),notFoundOK:true) }
    func create(callback: String,organization: String,signingKey: String) async throws -> Subscription {
        _ = try Self.providerURI(organization,kind:"organizations")
        let bytes = try await perform("POST",URL(string:"https://api.calendly.com/webhook_subscriptions")!,body:["url":callback,"organization":organization,"scope":"organization","events":Self.events,"signing_key":signingKey])!
        let value = try validated(decode(Resource<Subscription>.self,bytes).resource)
        guard value.matches(callback:callback,organization:organization), value.state == "active" else { throw Self.failure("Calendlyの作成結果が要求した通知設定と一致しません。") }; return value
    }
    /// Scan one page at a time and follow only opaque page tokens at the fixed origin.
    func find(callback: String,organization: String,validate: () throws -> Void = {}) async throws -> Subscription? {
        _ = try Self.providerURI(organization,kind:"organizations"); var next: String?, seen = Set<String>(), found: Subscription?
        repeat {
            try validate(); try Task.checkCancellation()
            var parts = URLComponents(string:"https://api.calendly.com/webhook_subscriptions")!
            parts.queryItems = [.init(name:"organization",value:organization),.init(name:"scope",value:"organization"),.init(name:"count",value:"100")]
            if let next { parts.queryItems!.append(.init(name:"page_token",value:next)) }
            let page = try decode(Page.self,await perform("GET",parts.url!)!); try validate()
            guard page.collection.count <= 100 else { throw Self.failure("Calendlyの通知一覧がページ上限を超えています。") }
            for item in page.collection where item.callback_url == callback {
                let item = try validated(item)
                guard item.matches(callback:callback,organization:organization), found == nil else { throw Self.failure("一致する通知先が複数あるか、登録内容が異なります。Calendly側の設定を確認してください。") }; found = item
            }
            next = page.pagination.next_page_token
            if let next { guard !next.isEmpty, next.utf8.count <= 4096, seen.count < 1000, seen.insert(next).inserted else { throw Self.failure("Calendlyの通知一覧を最後まで確認できません。") } }
        } while next != nil
        return found
    }
}
