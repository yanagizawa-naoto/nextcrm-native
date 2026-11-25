import Foundation
import CryptoKit

/// Verification-only adapter for existing BetterAuth-compatible Session rows.
/// Not selected by the app: remote/local deployment is still an explicit decision.
/// Credential material comes from a trusted provider/cookie boundary, never email.
final class NativeIdentitySQLiteAuthority: NativeIdentityAuthority {
    struct Credential: CustomStringConvertible, CustomDebugStringConvertible {
        fileprivate let signedSessionValue: String
        fileprivate let signedDontRememberValue: String?
        init(signedSessionValue: String, signedDontRememberValue: String? = nil) {
            self.signedSessionValue = signedSessionValue; self.signedDontRememberValue = signedDontRememberValue
        }
        var description: String { "<ログイン資格情報>" }
        var debugDescription: String { description }
    }
    typealias Context = CRMService
    private let db: NativeDatabase
    private let workspace: NativeIdentityWorkspace
    private let configuration: NativeMCPSessionAuth.Configuration
    private let clock: () -> Date
    init(db: NativeDatabase, workspace: NativeIdentityWorkspace, configuration: NativeMCPSessionAuth.Configuration, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.workspace = workspace; self.configuration = configuration; self.clock = clock
    }
    private func now() -> Date { Date(timeIntervalSince1970: floor(clock().timeIntervalSince1970 * 1000) / 1000) }
    private func binding(_ token: String) -> Data { Data(SHA256.hash(data: Data(token.utf8))) }
    private func snapshot(_ session: NativeRecord, remember: Bool, at instant: Date) throws -> Result<NativeIdentitySnapshot, NativeIdentityError> {
        guard let expiry = NativeAPITokens.date(session["expiresAt"]) else { return .failure(.unauthenticated) }
        if expiry <= instant { try db.deleteExpiredBrowserSession(session); return .failure(.unauthenticated) }
        guard let user = try db.get("Users", key: ["id": session["userId"]]), user["banned"] != .integer(1) else { return .failure(.unauthenticated) }
        var expiryAfter = expiry
        if remember, expiry.timeIntervalSince1970 - 6 * 86400 <= instant.timeIntervalSince1970 {
            expiryAfter = instant.addingTimeInterval(7 * 86400)
            guard try db.refreshBrowserSession(session, expiresAt: NativeAPITokens.timestamp(expiryAfter), updatedAt: NativeAPITokens.timestamp(instant)) != nil else { return .failure(.unauthenticated) }
        }
        let state: NativeIdentityDisposition
        switch user["userStatus"].string { case "ACTIVE": state = .active; case "PENDING": state = .pending; case "INACTIVE": state = .inactive; default: return .failure(.unauthenticated) }
        // Current AppRole has no member/viewer. Do not create an identity that
        // CRMService.authenticated would reject or silently elevate legacy data.
        guard ["user", "manager", "admin", "partner"].contains(user["role"].string) else { return .failure(.unauthenticated) }
        return .success(.init(workspace: workspace, sessionID: session["id"].string, userID: user["id"].string,
                              role: user["role"].string, partnerAccountID: user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string,
                              disposition: state, expiresAt: expiryAfter, binding: binding(session["token"].string)))
    }
    func authenticate(_ credential: Credential, workspace requested: NativeIdentityWorkspace) async throws -> NativeIdentitySnapshot {
        try Task.checkCancellation()
        guard requested == workspace else { throw NativeIdentityError.invalidAuthority }
        guard let token = NativeMCPSessionAuth.signedValue(credential.signedSessionValue, secret: configuration.secret), !token.contains("\0") else { throw NativeIdentityError.unauthenticated }
        let remember = NativeMCPSessionAuth.signedValue(credential.signedDontRememberValue, secret: configuration.secret) == nil
        // Decision is thrown after commit so expiry cleanup is durable.
        return try db.transaction {
            guard let session = try db.page("Session", fields: ["id", "token", "userId", "expiresAt", "updatedAt"], equal: ["token": .text(token)], limit: 1).rows.first else { return Result<NativeIdentitySnapshot, NativeIdentityError>.failure(.unauthenticated) }
            return try snapshot(session, remember: remember, at: now())
        }.get()
    }
    private func current(_ expected: NativeIdentitySnapshot) throws -> Result<NativeIdentitySnapshot, NativeIdentityError> {
        guard expected.workspace == workspace else { return .failure(.invalidAuthority) }
        guard let row = try db.get("Session", key: ["id": .text(expected.sessionID)]), binding(row["token"].string) == expected.binding, row["userId"] == .text(expected.userID) else { return .failure(.unauthenticated) }
        // Do not refresh during a business read/write; authenticate handles the
        // signed dont_remember preference. A lease is never a refresh credential.
        let result = try snapshot(row, remember: false, at: now())
        if case let .success(fresh) = result {
            guard fresh.role == expected.role, fresh.partnerAccountID == expected.partnerAccountID, fresh.disposition == expected.disposition else { return .failure(.staleIdentity) }
        }
        return result
    }
    func validate(_ snapshot: NativeIdentitySnapshot) throws -> NativeIdentitySnapshot { try db.transaction { try current(snapshot) }.get() }
    func withAccess<T>(_ snapshot: NativeIdentitySnapshot, allowPartner: Bool, _ action: (CRMService) throws -> T) throws -> T {
        try db.transaction { () throws -> Result<T, NativeIdentityError> in
            switch try current(snapshot) {
            case let .failure(error): return .failure(error)
            case let .success(fresh):
                guard fresh.disposition == .active else { return .failure(.inactive) }
                guard allowPartner || fresh.role != "partner" else { return .failure(.partnerNotAllowed) }
                let service = CRMService(db: db, identity: .init(id: fresh.userID, role: fresh.role, partnerAccountID: fresh.partnerAccountID))
                try service.authenticated()
                return .success(try action(service))
            }
        }.get()
    }
    func revoke(_ snapshot: NativeIdentitySnapshot) async throws {
        guard snapshot.workspace == workspace else { throw NativeIdentityError.invalidAuthority }
        try db.transaction {
            guard let session = try db.get("Session", key: ["id": .text(snapshot.sessionID)]), session["userId"] == .text(snapshot.userID), binding(session["token"].string) == snapshot.binding else { return }
            // Exact row/revision fence; logout is idempotent and may revoke its
            // own now-inactive account. No other user's session can be deleted.
            try db.remove(session, actor: snapshot.userID)
        }
    }
}
