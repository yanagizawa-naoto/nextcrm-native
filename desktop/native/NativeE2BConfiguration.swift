import Foundation

/// Snapshot the SDK's connection options together with the key. Never reread
/// environment variables while uploading an agent or cleaning up its sandbox.
struct NativeE2BConfiguration: Equatable {
    let domain: String, apiURL: URL, sandboxURL: URL?, debug: Bool, accessToken: String?
    static let standard = try! NativeE2BConfiguration(environment: .init(lookup: { _ in nil }))
    init(environment: NativeAIEnvironment) throws {
        func configured(_ name: String) -> String? { environment.lookup(name).flatMap { $0.isEmpty ? nil : $0 } }
        debug = (configured("E2B_DEBUG") ?? "false").lowercased() == "true"
        domain = configured("E2B_DOMAIN") ?? "e2b.app"
        try Self.validateDomain(domain)
        apiURL = try Self.endpoint(configured("E2B_API_URL") ?? (debug ? "http://localhost:3000" : "https://api." + domain))
        sandboxURL = try configured("E2B_SANDBOX_URL").map(Self.endpoint)
        accessToken = configured("E2B_ACCESS_TOKEN")
        if let accessToken { try NativeAIKeys.validate(accessToken) }
    }
    static func endpoint(_ value: String) throws -> URL {
        guard value.utf8.count <= 4096, !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }), !value.contains("\\"),
              var parts = URLComponents(string: value), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw invalid() }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        guard let url = parts.url else { throw invalid() }
        return url
    }
    static func validateDomain(_ value: String) throws {
        guard value.utf8.count <= 300, !value.contains("%"), let parts = URLComponents(string: "https://" + value),
              parts.path.isEmpty, parts.host != nil else { throw invalid() }
        _ = try endpoint("https://" + value)
        let host = parts.host!, domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" && $0.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) }) else { throw invalid() }
    }
    func sandboxBase(id: String, responseDomain: String?) throws -> URL {
        if let sandboxURL { return sandboxURL }
        if debug { return URL(string: "http://localhost:49983")! }
        let host = responseDomain.flatMap { $0.isEmpty ? nil : $0 } ?? domain
        try Self.validateDomain(host)
        return try Self.endpoint("https://49983-" + id + "." + host)
    }
    var fingerprint: String {
        NativeEmbeddingVector.hash([domain, apiURL.absoluteString, sandboxURL?.absoluteString ?? "", debug ? "true" : "false", accessToken ?? ""].joined(separator: "\u{0}"))
    }
    static func origin(_ url: URL) -> String {
        (url.scheme?.lowercased() ?? "") + "://" + (url.host?.lowercased() ?? "") + ":" + String(url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
    }
    /// HTTP is opt-in through an explicit URL or the SDK debug mode. A server
    /// response cannot expand this set and redirects remain disabled.
    var insecureOrigins: Set<String> {
        let sandbox = sandboxURL ?? (debug ? URL(string: "http://localhost:49983") : nil)
        return Set(([apiURL] + [sandbox].compactMap { $0 }).filter { $0.scheme?.lowercased() == "http" }.map(Self.origin))
    }
    static func invalid() -> NativeAIError { .init(message: "E2Bの接続先を確認してください。HTTP(S)のURLと正しいドメインを指定し、URLに認証情報・クエリ・フラグメントを含めないでください。") }
}
