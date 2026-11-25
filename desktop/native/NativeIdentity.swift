import Foundation

/// A stable authority/workspace pair is supplied by composition, never inferred
/// from an email, DB path, request header, or the legacy localActor metadata.
struct NativeIdentityWorkspace: Equatable {
    let id: String
    let issuer: String
    init(id: String, issuer: String) throws {
        guard !id.isEmpty, !issuer.isEmpty, !id.contains("\0"), !issuer.contains("\0") else { throw NativeIdentityError.invalidAuthority }
        self.id = id; self.issuer = issuer
    }
}

enum NativeIdentityError: Error, LocalizedError {
    case invalidAuthority, unauthenticated, staleAttempt, staleIdentity, inactive, partnerNotAllowed
    var errorDescription: String? {
        switch self {
        case .invalidAuthority: return "接続先の認証設定を確認してください。"
        case .unauthenticated: return "ログインの有効期限が切れました。もう一度ログインしてください。"
        case .staleAttempt: return "ログイン操作は取り消されたか、新しい操作に切り替わりました。"
        case .staleIdentity: return "利用者の権限が変更されました。もう一度ログインしてください。"
        case .inactive: return "現在の利用者状態では操作できません。管理者に確認してください。"
        case .partnerNotAllowed: return "パートナーはこの操作を利用できません。"
        }
    }
}

enum NativeIdentityDisposition: String { case active, pending, inactive }

/// Internal provider result. Only a trusted authority implementation can return
/// this through authenticate(). No controller API accepts caller-created results.
/// binding is an opaque digest, not a cookie/token/password. It must not be used
/// as a bearer credential by any future remote adapter.
struct NativeIdentitySnapshot: Equatable {
    let workspace: NativeIdentityWorkspace
    let sessionID: String
    let userID: String
    let role: String
    let partnerAccountID: String?
    let disposition: NativeIdentityDisposition
    let expiresAt: Date
    let binding: Data
}

/// Implementations are trusted composition dependencies. A provider must verify
/// its credential, re-read current authority state and fence every business effect.
/// The generic Context prevents a remote provider from silently using a local DB.
protocol NativeIdentityAuthority {
    associatedtype Credential
    associatedtype Context
    func authenticate(_ credential: Credential, workspace: NativeIdentityWorkspace) async throws -> NativeIdentitySnapshot
    func validate(_ snapshot: NativeIdentitySnapshot) throws -> NativeIdentitySnapshot
    func withAccess<T>(_ snapshot: NativeIdentitySnapshot, allowPartner: Bool, _ action: (Context) throws -> T) throws -> T
    func revoke(_ snapshot: NativeIdentitySnapshot) async throws
}

struct NativeIdentityLease {
    fileprivate let controller: UUID
    fileprivate let generation: UInt64
    fileprivate let snapshot: NativeIdentitySnapshot
    var userID: String { snapshot.userID }
    var role: String { snapshot.role }
    var disposition: NativeIdentityDisposition { snapshot.disposition }
}

/// Provider-independent account switching fence. No Session creation, email-only
/// sign-in, localActor fallback, cookie persistence, or Keychain access exists here.
/// The lock is held for short synchronous validation/effects, never across await.
/// Callers must re-enter withAccess after each await and before displaying a result.
final class NativeIdentityController<Authority: NativeIdentityAuthority> {
    enum State: Equatable {
        case signedOut, authenticating
        case signedIn(userID: String, role: String, disposition: NativeIdentityDisposition)
    }
    private let authority: Authority
    let workspace: NativeIdentityWorkspace
    private let id = UUID(), lock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var current: NativeIdentitySnapshot?
    private var status: State = .signedOut
    init(workspace: NativeIdentityWorkspace, authority: Authority) { self.workspace = workspace; self.authority = authority }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func advance() { generation &+= 1; current = nil; status = .signedOut }
    var state: State { locked { status } }
    func cancel() { locked { advance() } }
    func signIn(_ credential: Authority.Credential) async throws -> NativeIdentityLease {
        let attempt = locked { () -> UInt64 in advance(); status = .authenticating; return generation }
        do {
            try Task.checkCancellation()
            let result = try await authority.authenticate(credential, workspace: workspace)
            try Task.checkCancellation()
            return try locked {
                guard attempt == generation else { throw NativeIdentityError.staleAttempt }
                guard result.workspace == workspace else { throw NativeIdentityError.invalidAuthority }
                // A provider can suspend while authenticating. Revalidate before
                // publishing; a revoked session or changed role cannot be revived.
                let fresh = try authority.validate(result)
                guard fresh.workspace == workspace else { throw NativeIdentityError.invalidAuthority }
                current = fresh; status = .signedIn(userID: fresh.userID, role: fresh.role, disposition: fresh.disposition)
                return NativeIdentityLease(controller: id, generation: generation, snapshot: fresh)
            }
        } catch {
            locked { if generation == attempt { advance() } }
            throw error
        }
    }
    func withAccess<T>(_ lease: NativeIdentityLease, allowPartner: Bool = false, _ action: (Authority.Context) throws -> T) throws -> T {
        try locked {
            guard lease.controller == id, lease.generation == generation, current == lease.snapshot else { throw NativeIdentityError.staleAttempt }
            do { return try authority.withAccess(lease.snapshot, allowPartner: allowPartner, action) }
            catch let error as NativeIdentityError {
                switch error { case .unauthenticated, .staleIdentity, .invalidAuthority: advance(); default: break }
                throw error
            }
        }
    }
    /// Local authority is discarded before asynchronous revocation. A failure
    /// remains an error for the UI to report; it never restores a local login.
    func signOut() async throws {
        let previous = locked { () -> NativeIdentitySnapshot? in let old = current; advance(); return old }
        if let previous { try await authority.revoke(previous) }
    }
}
