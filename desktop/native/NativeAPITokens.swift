import Foundation
import CryptoKit
import Security

enum NativeAPITokenError: Error, LocalizedError {
    case unauthorized, forbidden, notFound, limit, name, expiry, random
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "APIトークンが無効か、有効期限が切れています。"
        case .forbidden: return "APIトークンを操作する権限がありません。"
        case .notFound: return "対象のAPIトークンが見つかりません。"
        case .limit: return "有効なAPIトークンは利用者ごとに10個までです。"
        case .name: return "トークン名を1〜256文字で入力してください。"
        case .expiry: return "有効期限を確認してください。"
        case .random: return "APIトークンを生成できませんでした。もう一度お試しください。"
        }
    }
}

/// Safe management projection. Neither a raw token nor its hash reaches a list.
struct NativeAPITokenRow {
    let id: String, name: String, prefix: String, createdAt: Date
    let expiresAt: Date?, revokedAt: Date?, lastUsedAt: Date?
    func active(at now: Date) -> Bool { revokedAt == nil && (expiresAt == nil || expiresAt! > now) }
}

final class NativeAPITokens {
    let service: CRMService
    private let clock: () -> Date
    init(service: CRMService, clock: @escaping () -> Date = Date.init) { self.service = service; self.clock = clock }
    static func hash(_ raw: String) -> String { SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f.string(from: date)
    }
    static func date(_ value: SQLValue) -> Date? {
        guard case let .text(text) = value else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    private static let fields = ["name", "tokenPrefix", "createdAt", "expiresAt", "revokedAt", "lastUsedAt"]
    private static func projection(_ row: NativeRecord) throws -> NativeAPITokenRow {
        guard let created = date(row["createdAt"]), ["expiresAt", "revokedAt", "lastUsedAt"].allSatisfy({ row[$0] == .null || date(row[$0]) != nil }) else {
            throw NativeDBError.message("APIトークンの日付データを読み取れません。")
        }
        return .init(id: row["id"].string, name: row["name"].string, prefix: row["tokenPrefix"].string,
                     createdAt: created, expiresAt: date(row["expiresAt"]), revokedAt: date(row["revokedAt"]), lastUsedAt: date(row["lastUsedAt"]))
    }
    func list(offset: Int = 0, activeOnly: Bool = false) throws -> (rows: [NativeAPITokenRow], total: Int) {
        try service.db.transaction {
            try service.authenticated()
            let filter: RecordFilter = activeOnly ? .every([.equal("revokedAt", .null), .any([.equal("expiresAt", .null), .compareDate("expiresAt", .greater, Self.timestamp(clock()))])]) : .all
            let page = try service.db.page("ApiToken", fields: Self.fields, equal: ["userId": .text(service.identity.id)], offset: offset, filter: filter, sort: "createdAt", descending: true, insertionOrderForTies: true)
            return (try page.rows.map(Self.projection), page.total)
        }
    }
    /// Returns the raw value only from this call. It is never stored in SQLite,
    /// preferences, Keychain, audit history or an instance property.
    func issue(name: String, expiresAt: Date? = nil) throws -> (rawToken: String, row: NativeAPITokenRow) {
        try service.db.transaction {
            try service.authenticated()
            guard service.identity.role != "partner" else { throw NativeAPITokenError.forbidden }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256, !name.contains("\0") else { throw NativeAPITokenError.name }
            let now = clock()
            if let expiresAt, !expiresAt.timeIntervalSince1970.isFinite || expiresAt < Date(timeIntervalSince1970: -62135596800) || expiresAt > Date(timeIntervalSince1970: 253402300799) { throw NativeAPITokenError.expiry }
            let count = try service.db.page("ApiToken", fields: [], equal: ["userId": .text(service.identity.id), "revokedAt": .null], filter: .any([.equal("expiresAt", .null), .compareDate("expiresAt", .greater, Self.timestamp(now))]), limit: 1).total
            guard count < 10 else { throw NativeAPITokenError.limit }
            var bytes = [UInt8](repeating: 0, count: 24)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NativeAPITokenError.random }
            let suffix = bytes.map { String(format: "%02x", $0) }.joined(), raw = "nxtc__" + suffix
            let record = try service.db.insert("ApiToken", values: ["name": .text(name), "tokenHash": .text(Self.hash(raw)), "tokenPrefix": .text(String(suffix.prefix(8))), "userId": .text(service.identity.id), "createdAt": .text(Self.timestamp(now)), "expiresAt": expiresAt.map { .text(Self.timestamp($0)) } ?? .null], actor: service.identity.id)
            return (raw, try Self.projection(record))
        }
    }
    func revoke(id: String) throws {
        try service.db.transaction {
            try service.authenticated()
            guard let row = try service.db.get("ApiToken", key: ["id": .text(id)]), row["userId"] == .text(service.identity.id) else { throw NativeAPITokenError.notFound }
            if row["revokedAt"] == .null { try service.db.update(row, changes: ["revokedAt": .text(Self.timestamp(clock()))], actor: service.identity.id, action: "api_token_revoke") }
        }
    }
    /// Bounded pages inside one write transaction: no token escapes concurrent
    /// issuance, and a failure rolls back the whole administrative operation.
    @discardableResult func revokeAll(userID: String) throws -> Int {
        try service.db.transaction {
            try service.authenticated()
            guard service.identity.role == "admin" else { throw NativeAPITokenError.forbidden }
            guard !userID.isEmpty else { throw NativeAPITokenError.notFound }
            return try revokeAllInsideTransaction(userID: userID, at: clock())
        }
    }
    private func revokeAllInsideTransaction(userID: String, at now: Date) throws -> Int {
        var count = 0
        while true {
            let rows = try service.db.page("ApiToken", fields: [], equal: ["userId": .text(userID), "revokedAt": .null]).rows
            if rows.isEmpty { return count }
            for item in rows {
                guard let row = try service.db.get("ApiToken", key: ["id": item["id"]]) else { throw NativeDBError.conflict }
                try service.db.update(row, changes: ["revokedAt": .text(Self.timestamp(now))], actor: service.identity.id, action: "api_token_revoke_all"); count += 1
            }
        }
    }
    func deactivateUser(id: String) throws {
        try service.db.transaction {
            try service.authenticated()
            guard service.identity.role == "admin" else { throw NativeAPITokenError.forbidden }
            guard id != service.identity.id else { throw NativeDBError.message("自分自身を無効にすることはできません。") }
            guard let user = try service.db.get("Users", key: ["id": .text(id)]) else { throw NativeAPITokenError.notFound }
            try service.db.update(user, changes: ["userStatus": .text("INACTIVE")], actor: service.identity.id, action: "deactivate")
            while true {
                let rows = try service.db.page("Session", fields: [], equal: ["userId": .text(id)]).rows
                if rows.isEmpty { break }
                for item in rows { try service.db.remove(item, actor: service.identity.id, action: "session_revoke") }
            }
            _ = try revokeAllInsideTransaction(userID: id, at: clock())
        }
    }
    static func authenticate(_ raw: String, db: NativeDatabase, clock: @escaping () -> Date = Date.init) throws -> NativeAPISession {
        let session = try prepareSession(raw, db: db, clock: clock)
        try session.withAccess { _ in }
        return session
    }
    /// Hash-only request context. Preparing it has no database effects and
    /// grants no authority; every actual use still goes through withAccess.
    static func prepareSession(_ raw: String, db: NativeDatabase, clock: @escaping () -> Date = Date.init) throws -> NativeAPISession {
        guard raw.hasPrefix("nxtc__"), raw.utf8.count <= 4096, !raw.contains("\0") else { throw NativeAPITokenError.unauthorized }
        return NativeAPISession(db: db, hash: hash(raw), clock: clock)
    }
}

/// Retains a digest, never the bearer secret. Each operation rechecks the token
/// and current user in the same SQLite transaction as its database effects.
/// Async handlers must use withAccess again after awaits, before new effects.
final class NativeAPISession {
    private let db: NativeDatabase, digest: String, clock: () -> Date
    fileprivate init(db: NativeDatabase, hash: String, clock: @escaping () -> Date) { self.db = db; digest = hash; self.clock = clock }
    func withAccess<T>(_ action: (CRMService) throws -> T) throws -> T {
        try db.transaction {
            try Task.checkCancellation()
            let now = clock()
            guard let token = try db.page("ApiToken", fields: ["userId", "expiresAt", "revokedAt"], equal: ["tokenHash": .text(digest)], limit: 1).rows.first,
                  token["revokedAt"] == .null else { throw NativeAPITokenError.unauthorized }
            // Expiry is exclusive, matching the source active-list/capacity
            // predicate. The original validator's equality discrepancy is
            // deliberately closed rather than admitting an expired token.
            if token["expiresAt"] != .null {
                guard let expiry = NativeAPITokens.date(token["expiresAt"]), expiry > now else { throw NativeAPITokenError.unauthorized }
            }
            guard let user = try db.get("Users", key: ["id": token["userId"]]), user["userStatus"] == .text("ACTIVE"), user["banned"] != .integer(1), ["user", "manager", "admin"].contains(user["role"].string) else { throw NativeAPITokenError.unauthorized }
            let service = CRMService(db: db, identity: .init(id: user["id"].string, role: user["role"].string, partnerAccountID: nil))
            // Optional usage metadata must not turn a valid credential into an
            // authentication failure, or create an audit row per API request.
            try? db.touchAPIToken(id: token["id"].string, at: NativeAPITokens.timestamp(now))
            let result = try action(service)
            try Task.checkCancellation()
            return result
        }
    }
}
