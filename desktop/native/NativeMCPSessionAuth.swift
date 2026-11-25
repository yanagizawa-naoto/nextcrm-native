import Foundation
import CryptoKit

/// BetterAuth 1.7 cookie/session gate, independently of the MCP bearer actor.
/// The caller supplies a trusted secret and transport configuration. Request
/// headers never determine the secret, cookie prefix or authorization role.
struct NativeMCPSessionAuth {
    struct Configuration {
        let secret: Data
        let secureCookies: Bool
        init(secret: Data, secureCookies: Bool = false) throws {
            guard secret.count >= 32 else { throw NativeDBError.message("ログイン署名鍵の設定を確認してください。") }
            self.secret = secret; self.secureCookies = secureCookies
        }
        var prefix: String { (secureCookies ? "__Secure-" : "") + "better-auth." }
    }
    static let intentionalNativeDifferences = [
        "expiry equality is unauthenticated and cleaned up (source expires only when strictly earlier)",
        "banned cookie users are unauthenticated and their sessions are not refreshed (source getSession permits them)"
    ]
    private static let whitespace = CharacterSet(charactersIn: "\u{9}\u{B}\u{C}\u{20}\u{A0}\u{FEFF}\u{A}\u{D}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}\u{2028}\u{2029}")
    /// better-call uses the first duplicate, case-sensitive names, JS trim,
    /// permissive surrounding quotes and decodeURIComponent-or-original.
    private static func cookies(_ header: String?, names: Set<String>) -> [String: String] {
        guard let header else { return [:] }
        var output: [String: String] = [:]
        for segment in header.split(separator: ";", omittingEmptySubsequences: false) {
            guard let separator = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<separator].trimmingCharacters(in: whitespace)
            guard names.contains(key), output[key] == nil else { continue }
            var value = segment[segment.index(after: separator)...].trimmingCharacters(in: whitespace)
            if value.first == "\"" { value = String(value.dropFirst().dropLast()) }
            output[key] = value.removingPercentEncoding ?? value
        }
        return output
    }
    static func signedValue(_ value: String?, secret: Data) -> String? {
        guard let value, let dot = value.lastIndex(of: "."), dot != value.startIndex else { return nil }
        let token = String(value[..<dot]), signature = String(value[value.index(after: dot)...])
        guard signature.utf16.count == 44, signature.hasSuffix("="), let bytes = Data(base64Encoded: signature), bytes.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(token.utf8), using: SymmetricKey(data: secret)) else { return nil }
        return token
    }
    /// Expiry cleanup must commit even when authentication is denied. Return a
    /// decision from the transaction and throw only after its effects commit.
    static func userDirectoryDecision(cookie: String?, db: NativeDatabase, configuration: Configuration, now: Date = Date()) throws -> Result<CRMIdentity, NativeMCPFailure> {
        let tokenName = configuration.prefix + "session_token", rememberName = configuration.prefix + "dont_remember"
        let parsed = cookies(cookie, names: [tokenName, rememberName])
        guard let token = signedValue(parsed[tokenName], secret: configuration.secret), !token.contains("\0") else { return .failure(.reportSessionUnauthenticated) }
        let dontRemember = signedValue(parsed[rememberName], secret: configuration.secret) != nil
        let current = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1000) / 1000)
        let result: Result<CRMIdentity, NativeMCPFailure> = try db.transaction {
            guard let session = try db.page("Session", fields: ["id", "token", "expiresAt", "updatedAt", "userId"], equal: ["token": .text(token)], limit: 1).rows.first,
                  let expiry = NativeAPITokens.date(session["expiresAt"]) else { return .failure(.reportSessionUnauthenticated) }
            if expiry <= current {
                try db.deleteExpiredBrowserSession(session)
                return .failure(.reportSessionUnauthenticated)
            }
            guard let user = try db.get("Users", key: ["id": session["userId"]]) else { return .failure(.reportSessionUnauthenticated) }
            // Deliberate native hardening, matching bearer-token policy.
            guard user["banned"] != .integer(1) else { return .failure(.reportSessionUnauthenticated) }
            if !dontRemember, expiry.timeIntervalSince1970 - 6 * 86400 <= current.timeIntervalSince1970 {
                guard try db.refreshBrowserSession(session, expiresAt: NativeAPITokens.timestamp(current.addingTimeInterval(7 * 86400)), updatedAt: NativeAPITokens.timestamp(current)) != nil else { return .failure(.reportSessionUnauthenticated) }
            }
            // Original app auth-server rejects status/partner after BetterAuth
            // session maintenance; requireRole then reads the current DB role.
            guard user["userStatus"] == .text("ACTIVE"), user["role"] != .text("partner") else { return .failure(.reportSessionUnauthenticated) }
            let role = user["role"].string == "member" ? "manager" : user["role"].string
            guard ["admin", "manager"].contains(role) else { return .failure(.reportSessionForbidden) }
            return .success(.init(id: user["id"].string, role: role, partnerAccountID: nil))
        }
        return result
    }
    static func authorizeUserDirectory(cookie: String?, db: NativeDatabase, configuration: Configuration, now: Date = Date()) throws -> CRMIdentity {
        try userDirectoryDecision(cookie: cookie, db: db, configuration: configuration, now: now).get()
    }
}
