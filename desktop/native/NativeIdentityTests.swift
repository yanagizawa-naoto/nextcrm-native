import Foundation
import CryptoKit
import SQLite3

@main enum NativeIdentityTests {
    static var checks = 0
    enum Failure: Error { case assertion(String), rollback }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func id(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
    static func values(_ object: [String: Any]) -> [String: SQLValue] { object.mapValues { if $0 is NSNull { return .null }; if let n = $0 as? NSNumber { return .integer(n.int64Value) }; return .text($0 as! String) } }
    static func signed(_ token: String, secret: Data) -> String { token + "." + Data(HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: SymmetricKey(data: secret))).base64EncodedString() }
    static func cookieCredential(_ header: String) -> NativeIdentitySQLiteAuthority.Credential {
        func part(_ name: String) -> String? { header.components(separatedBy: "; ").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)).removingPercentEncoding ?? "" } }
        return .init(signedSessionValue: part("__Secure-better-auth.session_token") ?? header, signedDontRememberValue: part("__Secure-better-auth.dont_remember"))
    }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var handle: OpaquePointer?; guard sqlite3_open(db.url.path, &handle) == SQLITE_OK else { throw Failure.assertion("fixture open") }; defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion(String(cString: sqlite3_errmsg(handle))) }
    }
    static func deny<T>(_ action: () throws -> T, _ label: String) throws { do { _ = try action(); throw Failure.assertion(label) } catch is NativeIdentityError { checks += 1 } }
    static func denyAsync<T>(_ action: () async throws -> T, _ label: String) async throws { do { _ = try await action(); throw Failure.assertion(label) } catch is NativeIdentityError { checks += 1 } }
    actor Gate {
        var started = false, released = false
        var startWaiter: CheckedContinuation<Void, Never>?, releaseWaiter: CheckedContinuation<Void, Never>?
        func pause() async { started = true; startWaiter?.resume(); startWaiter = nil; if !released { await withCheckedContinuation { releaseWaiter = $0 } } }
        func wait() async { if !started { await withCheckedContinuation { startWaiter = $0 } } }
        func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
    }
    final class DelayedAuthority: NativeIdentityAuthority {
        struct Credential { let real: NativeIdentitySQLiteAuthority.Credential; var gate: Gate? = nil }
        typealias Context = CRMService
        let base: NativeIdentitySQLiteAuthority
        var failRevoke = false
        init(_ base: NativeIdentitySQLiteAuthority) { self.base = base }
        func authenticate(_ credential: Credential, workspace: NativeIdentityWorkspace) async throws -> NativeIdentitySnapshot {
            let result = try await base.authenticate(credential.real, workspace: workspace)
            if let gate = credential.gate { await gate.pause() }
            return result
        }
        func validate(_ snapshot: NativeIdentitySnapshot) throws -> NativeIdentitySnapshot { try base.validate(snapshot) }
        func withAccess<T>(_ snapshot: NativeIdentitySnapshot, allowPartner: Bool, _ action: (CRMService) throws -> T) throws -> T { try base.withAccess(snapshot, allowPartner: allowPartner, action) }
        func revoke(_ snapshot: NativeIdentitySnapshot) async throws { if failRevoke { throw Failure.rollback }; try await base.revoke(snapshot) }
    }
    static func main() async {
        do { try await run(); print("Native identity: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-IdentityTests-" + UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        _ = try db.insert("crm_Accounts", values: ["id": .text(id(9)), "v": .integer(0), "name": .text("隔離パートナー企業")], actor: "isolated-fixture")
        let workspace = try NativeIdentityWorkspace(id: "isolated-workspace", issuer: "https://identity.invalid")
        let secret = Data((reference["secret"] as! String).utf8), config = try NativeMCPSessionAuth.Configuration(secret: secret, secureCookies: true)
        var clock = NativeAPITokens.date(.text(reference["epoch"] as! String))!
        let initialTime = clock, base = NativeIdentitySQLiteAuthority(db: db, workspace: workspace, configuration: config, clock: { clock })
        var intentional = 0
        for sample in reference["sessionCases"] as! [[String: Any]] {
            try sql(db, "DELETE FROM Session; DELETE FROM Users")
            let before = sample["before"] as! [String: Any], spec = sample["spec"] as! [String: Any], label = spec["label"] as! String
            for user in before["Users"] as! [[String: Any]] { _ = try db.insert("Users", values: values(user), actor: "isolated-fixture") }
            for session in before["Session"] as! [[String: Any]] { _ = try db.insert("Session", values: values(session), actor: "isolated-fixture") }
            let controller = NativeIdentityController(workspace: workspace, authority: base)
            let banned = (spec["user"] as? [String: Any])?["banned"] as? Bool == true
            let equality = (spec["expiry"] as? NSNumber)?.intValue == 0
            let source = sample["anyStatus"] as? [String: Any]
            let auditBefore = try db.auditCount("Session")
            if banned || equality || source == nil {
                try await denyAsync({ try await controller.signIn(cookieCredential(sample["cookie"] as! String)) }, label)
                try check(controller.state == .signedOut, "denied attempt clears state")
                if banned || equality { intentional += 1 }
            } else {
                let lease = try await controller.signIn(cookieCredential(sample["cookie"] as! String)), user = source!["user"] as! [String: Any]
                try check(lease.userID == user["id"] as? String && lease.role == user["role"] as? String, "source identity " + label)
                let sourceStatus = (user["userStatus"] as! String).lowercased()
                try check(lease.disposition.rawValue == sourceStatus, "source pending/inactive retained " + label)
                if sample["business"] is NSNull { try deny({ try controller.withAccess(lease) { _ in true } }, "business gate " + label) }
                else { try check(try controller.withAccess(lease) { $0.identity.id == lease.userID }, "active business context " + label) }
                if sample["partner"] is NSNull { try deny({ try controller.withAccess(lease, allowPartner: true) { _ in true } }, "inactive remains denied with partner option") }
                else { try check(try controller.withAccess(lease, allowPartner: true) { $0.identity.id == lease.userID }, "partner-aware source gate " + label) }
            }
            let actualSessions = try db.page("Session", fields: ["id", "expiresAt", "updatedAt"], limit: 20).rows
            let expected = equality ? [] : ((banned ? before : sample["after"] as! [String: Any])["Session"] as! [[String: Any]])
            try check(actualSessions.count == expected.count, "source expiry cleanup count " + label)
            for row in actualSessions { let exp = expected.first { $0["id"] as? String == row["id"].string }!; try check(row["expiresAt"] == .text(exp["expiresAt"] as! String), "source refresh timestamp " + label); try check(row["updatedAt"] == .text(exp["updatedAt"] as! String), "source updated timestamp " + label) }
            try check(try db.auditCount("Session") == auditBefore, "no session maintenance audit amplification")
        }
        try check(intentional == 3, "three explicit existing-native hardening differences")
        try sql(db, "DELETE FROM Session; DELETE FROM Users")
        func seed(_ n: Int, role: String = "user", status: String = "ACTIVE") throws {
            _ = try db.insert("Users", values: ["id": .text(id(n)), "email": .text("person\(n)@example.invalid"), "name": .text("利用者\(n)"), "role": .text(role), "userStatus": .text(status)], actor: "fixture")
            _ = try db.insert("Session", values: ["id": .text(id(100+n)), "token": .text("synthetic-session-\(n)"), "userId": .text(id(n)), "expiresAt": .text(NativeAPITokens.timestamp(clock.addingTimeInterval(7*86400)))], actor: "fixture")
        }
        func cred(_ n: Int) -> NativeIdentitySQLiteAuthority.Credential { .init(signedSessionValue: signed("synthetic-session-\(n)", secret: secret)) }
        func change(_ n: Int, _ fields: [String: SQLValue]) throws { _ = try db.update(db.get("Users", key: ["id": .text(id(n))])!, changes: fields, actor: "fixture") }
        try seed(1); try seed(2, role: "admin"); try seed(3, role: "partner")
        try db.setMetadata("localActor", value: id(2))
        let controller = NativeIdentityController(workspace: workspace, authority: base)
        let a = try await controller.signIn(cred(1))
        try check(try controller.withAccess(a) { $0.identity.id == id(1) && $0.identity.role == "user" }, "localActor cannot elevate a verified user")
        try await denyAsync({ try await controller.signIn(.init(signedSessionValue: "person2@example.invalid")) }, "email string cannot authenticate")
        try deny({ try controller.withAccess(a) { _ in true } }, "new failed login invalidates old lease")
        let a2 = try await controller.signIn(cred(1)), b = try await controller.signIn(cred(2))
        try deny({ try controller.withAccess(a2) { _ in true } }, "old user lease rejected after switch")
        try check(try controller.withAccess(b) { $0.identity.id == id(2) }, "new user's authority")
        let other = NativeIdentityController(workspace: workspace, authority: base)
        try deny({ try other.withAccess(b) { _ in true } }, "lease bound to controller instance")
        let count = try db.auditCount("Users")
        do { _ = try controller.withAccess(b) { service -> Bool in _ = try service.db.update(service.db.get("Users", key: ["id": .text(id(2))])!, changes: ["name": .text("rollback")], actor: id(2)); throw Failure.rollback }; throw Failure.assertion("write rollback") } catch Failure.rollback { checks += 1 }
        try check(try db.get("Users", key: ["id": .text(id(2))])?["name"] == .text("利用者2") && db.auditCount("Users") == count, "business effects and audit rollback together")
        try change(2, ["role": .text("user")]); try deny({ try controller.withAccess(b) { _ in true } }, "fresh role guard")
        try check(controller.state == .signedOut, "stale role signs local controller out")
        let p = try await controller.signIn(cred(3)); try deny({ try controller.withAccess(p) { _ in true } }, "partner default denied")
        try check(try controller.withAccess(p, allowPartner: true) { $0.identity.role == "partner" }, "partner access explicit")
        let pending = try await controller.signIn(cred(1)); try change(1, ["userStatus": .text("PENDING")]); try deny({ try controller.withAccess(pending) { _ in true } }, "status changes after login")
        let waiting = try await controller.signIn(cred(1)); try check(waiting.disposition == .pending, "pending status may be displayed"); try deny({ try controller.withAccess(waiting) { _ in true } }, "pending never authorizes effects")
        try change(1, ["userStatus": .text("ACTIVE")]); try deny({ try controller.withAccess(waiting) { _ in true } }, "activation requires fresh lease")
        let active = try await controller.signIn(cred(1)); try change(1, ["banned": .integer(1)]); try deny({ try controller.withAccess(active) { _ in true } }, "ban after login")
        try change(1, ["banned": .integer(0)])
        let delayed = NativeIdentityController(workspace: workspace, authority: DelayedAuthority(base))
        let gate = Gate(); let old = Task { try await delayed.signIn(.init(real: cred(1), gate: gate)) }; await gate.wait()
        let latest = try await delayed.signIn(.init(real: cred(2))); await gate.release()
        try await denyAsync({ try await old.value }, "slow previous login cannot replace current user")
        try check(try delayed.withAccess(latest) { $0.identity.id == id(2) }, "new attempt survives old completion")
        let gate2 = Gate(); let revoked = Task { try await delayed.signIn(.init(real: cred(1), gate: gate2)) }; await gate2.wait()
        try change(1, ["role": .text("manager")]); await gate2.release(); try await denyAsync({ try await revoked.value }, "role changed during authentication await")
        try change(1, ["role": .text("user")])
        let gate3 = Gate(); let cancelled = Task { try await delayed.signIn(.init(real: cred(1), gate: gate3)) }; await gate3.wait(); cancelled.cancel(); await gate3.release()
        do { _ = try await cancelled.value; throw Failure.assertion("task cancellation") } catch is CancellationError { checks += 1 }
        try check(delayed.state == .signedOut, "task cancellation clears state")
        let gate4 = Gate(); let explicitCancel = Task { try await delayed.signIn(.init(real: cred(1), gate: gate4)) }; await gate4.wait(); delayed.cancel(); await gate4.release(); try await denyAsync({ try await explicitCancel.value }, "explicit cancel fences awaited result")
        let gate5 = Gate(); let sessionRevoked = Task { try await delayed.signIn(.init(real: cred(1), gate: gate5)) }; await gate5.wait()
        let oldSession = try db.get("Session", key: ["id": .text(id(101))])!
        _ = try db.update(oldSession, changes: ["token": .text("rotated-synthetic-session")], actor: "fixture")
        await gate5.release(); try await denyAsync({ try await sessionRevoked.value }, "token rotation during authentication await cannot revive old credential")
        _ = try db.update(db.get("Session", key: ["id": .text(id(101))])!, changes: ["token": oldSession["token"]], actor: "fixture")
        let failing = DelayedAuthority(base), failedLogout = NativeIdentityController(workspace: workspace, authority: failing)
        let failedLease = try await failedLogout.signIn(.init(real: cred(3))); failing.failRevoke = true
        do { try await failedLogout.signOut(); throw Failure.assertion("revoke failure surfaced") } catch Failure.rollback { checks += 1 }
        try check(failedLogout.state == .signedOut, "failed provider revoke cannot restore local sign-in")
        try deny({ try failedLogout.withAccess(failedLease, allowPartner: true) { _ in true } }, "failed revoke invalidates retained lease")
        try check(try db.get("Session", key: ["id": .text(id(103))]) != nil, "remote/provider revoke failure remains observable, not falsely successful")
        let logout = try await controller.signIn(cred(1)); try await controller.signOut()
        try deny({ try controller.withAccess(logout) { _ in true } }, "logout invalidates retained form lease")
        try check(try db.get("Session", key: ["id": .text(id(101))]) == nil && db.get("Session", key: ["id": .text(id(102))]) != nil, "logout revokes only current user's exact session")
        try await controller.signOut(); try check(controller.state == .signedOut, "logout idempotent")
        let expiring = try await controller.signIn(cred(2)); clock = initialTime.addingTimeInterval(7*86400)
        try deny({ try controller.withAccess(expiring) { _ in true } }, "expiry while form retained")
        try check(try db.get("Session", key: ["id": .text(id(102))]) == nil, "expiry cleanup commits on denied effect")
        clock = initialTime
        let wrongWorkspace = NativeIdentityController(workspace: try .init(id: "other", issuer: workspace.issuer), authority: base)
        try await denyAsync({ try await wrongWorkspace.signIn(cred(3)) }, "cross workspace rejected")
        let wrongIssuer = NativeIdentityController(workspace: try .init(id: workspace.id, issuer: "https://other.invalid"), authority: base)
        try await denyAsync({ try await wrongIssuer.signIn(cred(3)) }, "same workspace name with different issuer rejected")
        try check(!String(describing: cred(3)).contains("synthetic-session") && !String(reflecting: cred(3)).contains("synthetic-session"), "credential descriptions redact")
        try check(try db.metadata("localActor") == id(2), "legacy metadata unchanged")
        var handle: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(db.url.path, &handle) == SQLITE_OK else { throw Failure.assertion("privacy query open") }
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        guard sqlite3_prepare_v2(handle, "SELECT before_json,after_json FROM native_audit", -1, &statement, nil) == SQLITE_OK else { throw Failure.assertion("privacy query") }
        var leaked = false
        while sqlite3_step(statement) == SQLITE_ROW { for column: Int32 in [0, 1] { if let p = sqlite3_column_text(statement, column) { let text = String(cString: p); leaked = leaked || text.contains("synthetic-session") || text.contains(reference["secret"] as! String) } } }
        try check(!leaked, "audit payloads contain neither Session credentials nor signing secret")
        print("Compared \((reference["sessionCases"] as! [Any]).count) actual-source session cases; \(intentional) explicit hardening cases; real SQLite switching/revocation/races")
    }
}
