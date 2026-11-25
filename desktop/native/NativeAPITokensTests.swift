import Foundation
import SQLite3

@main enum NativeAPITokensTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw NativeDBError.message("FAIL: accepted " + label)
    }
    static func main() {
        do { try run(); print("Native API tokens: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        struct Reference: Decodable {
            struct Issued: Decodable { let rawToken: String }
            struct Validation: Decodable { let label: String, raw: String; let expiryOffsetMS: Double?; let revoked: Bool; let value: String? }
            struct Auth: Decodable { struct User: Decodable { let role: String }; let role: String, status: String; let value: User? }
            let epoch: Double, issued: Issued, storedHash: String, validation: [Validation], authorizationCases: [Auth]
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/api-tokens-reference.json")))
        var now = Date(timeIntervalSince1970: reference.epoch / 1000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-APITokens-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql")) }
        let db = try open(), adminIdentity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        var sql: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("crm.sqlite").path, &sql) == SQLITE_OK, let sql else { throw NativeDBError.message("fixture connection") }
        defer { sqlite3_close(sql) }
        func execute(_ statement: String) throws { guard sqlite3_exec(sql, statement, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(sql))) } }
        let admin = CRMService(db: db, identity: adminIdentity), adminTokens = NativeAPITokens(service: admin, clock: { now })
        func user(_ name: String, role: String = "user") throws -> NativeRecord {
            try db.insert("Users", values: ["name": .text(name), "email": .text(name + "@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE")], actor: adminIdentity.id)
        }
        func service(_ row: NativeRecord, database: NativeDatabase? = nil) -> CRMService {
            CRMService(db: database ?? db, identity: .init(id: row["id"].string, role: row["role"].string, partnerAccountID: nil))
        }
        func tokens(_ row: NativeRecord) -> NativeAPITokens { NativeAPITokens(service: service(row), clock: { now }) }
        func change(_ row: NativeRecord, _ values: [String: SQLValue]) throws -> NativeRecord {
            try db.update(db.get(row.model, key: ["id": row["id"]])!, changes: values, actor: adminIdentity.id)
        }
        func seed(_ owner: NativeRecord, raw: String, expires: Date? = nil) throws -> NativeRecord {
            try db.insert("ApiToken", values: ["name": .text("移行トークン"), "tokenHash": .text(NativeAPITokens.hash(raw)), "tokenPrefix": .text(String(raw.dropFirst(6).prefix(8))), "userId": owner["id"], "expiresAt": expires.map { .text(NativeAPITokens.timestamp($0)) } ?? .null], actor: adminIdentity.id)
        }
        let alice = try user("alice"), bob = try user("bob"), manager = try user("manager", role: "manager"), partner = try user("partner", role: "partner")
        let a = tokens(alice), b = tokens(bob)
        try check(NativeAPITokens.hash(reference.issued.rawToken) == reference.storedHash, "actual original SHA256 fixture")
        var imported = try seed(alice, raw: reference.issued.rawToken)
        for c in reference.validation {
            imported = try change(imported, ["expiresAt": c.expiryOffsetMS.map { .text(NativeAPITokens.timestamp(now.addingTimeInterval($0 / 1000))) } ?? .null, "revokedAt": c.revoked ? .text(NativeAPITokens.timestamp(now)) : .null])
            let expected = c.value != nil && c.label != "exact-expiry"
            if expected {
                let session = try NativeAPITokens.authenticate(c.raw, db: db, clock: { now })
                try check(try session.withAccess { $0.identity.id } == alice["id"].string, "source validation " + c.label)
            } else { try rejects("source validation / exclusive-expiry " + c.label) { _ = try NativeAPITokens.authenticate(c.raw, db: db, clock: { now }) } }
        }
        imported = try change(imported, ["expiresAt": .null, "revokedAt": .null])
        for c in reference.authorizationCases {
            // Simulate unmigrated legacy/corrupt role values that the native
            // typed writer correctly refuses, then verify fail-closed auth.
            if ["member", "viewer", "unknown"].contains(c.role) {
                try execute("PRAGMA ignore_check_constraints=ON; UPDATE Users SET role='\(c.role)',userStatus='\(c.status)' WHERE id='\(alice["id"].string)'; PRAGMA ignore_check_constraints=OFF")
            } else { _ = try change(alice, ["role": .text(c.role), "userStatus": .text(c.status)]) }
            if c.value != nil && ["user", "manager", "admin"].contains(c.role) {
                let session = try NativeAPITokens.authenticate(reference.issued.rawToken, db: db, clock: { now })
                try check(try session.withAccess { $0.identity.role } == c.value!.role, "source current authorization " + c.role)
            } else { try rejects("inactive/partner/unnormalized role " + c.role + c.status) { _ = try NativeAPITokens.authenticate(reference.issued.rawToken, db: db, clock: { now }) } }
        }
        _ = try change(alice, ["role": .text("user"), "userStatus": .text("ACTIVE")])
        let session = try NativeAPITokens.authenticate(reference.issued.rawToken, db: db, clock: { now })
        _ = try change(alice, ["banned": .integer(1)])
        try rejects("banned user in retained session") { try session.withAccess { _ in } }
        try rejects("banned user cannot issue") { _ = try a.issue(name: "拒否") }
        _ = try change(alice, ["banned": .integer(0), "role": .text("manager")])
        try check(try session.withAccess { $0.identity.role } == "manager", "retained session re-resolves role")
        try rejects("old UI identity rejected after role change") { _ = try a.issue(name: "古い権限") }
        _ = try change(alice, ["role": .text("user")])
        try rejects("partner issuance") { _ = try tokens(partner).issue(name: "拒否") }
        try rejects("empty name") { _ = try a.issue(name: " \n ") }
        try rejects("bounded name") { _ = try a.issue(name: String(repeating: "あ", count: 257)) }
        try rejects("embedded NUL") { _ = try a.issue(name: "a\0b") }
        try rejects("nonfinite expiry") { _ = try a.issue(name: "期限", expiresAt: Date(timeIntervalSince1970: .infinity)) }
        try rejects("oversized bearer") { _ = try NativeAPITokens.authenticate("nxtc__" + String(repeating: "a", count: 4096), db: db) }
        let issued = try a.issue(name: "  日本語の接続  ", expiresAt: now.addingTimeInterval(86400))
        try check(issued.rawToken.utf8.count == 54 && issued.rawToken.hasPrefix("nxtc__"), "generated wire size")
        try check(issued.rawToken.dropFirst(6).allSatisfy { "0123456789abcdef".contains($0) }, "generated hex")
        try check(issued.row.name == "日本語の接続" && issued.row.prefix == String(issued.rawToken.dropFirst(6).prefix(8)), "Japanese name and safe prefix")
        let stored = try db.get("ApiToken", key: ["id": .text(issued.row.id)])!
        try check(stored["tokenHash"] == .text(NativeAPITokens.hash(issued.rawToken)) && !stored.values.values.contains(.text(issued.rawToken)), "hash only in record")
        try check(try b.list().total == 0, "list isolated by owner")
        try rejects("foreign owner revoke") { try b.revoke(id: issued.row.id) }
        try rejects("manager bulk revoke") { _ = try tokens(manager).revokeAll(userID: alice["id"].string) }
        var rawTokens = Set([issued.rawToken])
        for i in 0..<8 { rawTokens.insert(try a.issue(name: "接続\(i)").rawToken) }
        try check(rawTokens.count == 9 && (try a.list(activeOnly: true).total) == 10, "independent random tokens and active count")
        try rejects("eleventh active token") { _ = try a.issue(name: "11") }
        try a.revoke(id: issued.row.id)
        try a.revoke(id: issued.row.id)
        try rejects("revoked authentication") { _ = try NativeAPITokens.authenticate(issued.rawToken, db: db, clock: { now }) }
        let replacement = try a.issue(name: "再発行")
        try check(replacement.rawToken != issued.rawToken, "revocation frees capacity")
        try a.revoke(id: imported["id"].string)
        try rejects("retained session rechecks revocation") { try session.withAccess { _ in } }
        try check(try adminTokens.revokeAll(userID: alice["id"].string) == 9, "admin revokes all remaining")
        try check(try adminTokens.revokeAll(userID: alice["id"].string) == 0, "bulk repeat idempotence")
        for i in 0..<205 { _ = try seed(alice, raw: "nxtc__expired-\(i)", expires: now.addingTimeInterval(-60)) }
        let all = try a.list(), next = try a.list(offset: 100)
        try check(all.rows.count == 100 && next.rows.count == 100 && all.total == 216, "bounded historical list")
        try check(Set(all.rows.map(\.id)).isDisjoint(with: Set(next.rows.map(\.id))), "stable list pages")
        try check(try a.list(activeOnly: true).total == 0, "expired and revoked excluded")
        try check(try adminTokens.revokeAll(userID: alice["id"].string) == 205, "bulk revoke multiple pages including expired")
        let current = try a.issue(name: "現在")
        let authenticated = try NativeAPITokens.authenticate(current.rawToken, db: db, clock: { now })
        let auditBefore = try db.auditCount("ApiToken")
        now.addTimeInterval(1)
        try authenticated.withAccess { _ in }
        let afterUse = try db.get("ApiToken", key: ["id": .text(current.row.id)])!
        try check(NativeAPITokens.date(afterUse["lastUsedAt"]) == now, "last-used updated")
        try check(try db.auditCount("ApiToken") == auditBefore, "authentication does not grow audit history")
        now.addTimeInterval(-10); try authenticated.withAccess { _ in }
        try check(try db.get("ApiToken", key: ["id": .text(current.row.id)])!["lastUsedAt"] == afterUse["lastUsedAt"], "last-used monotonic with clock reversal")
        now.addTimeInterval(10)
        try execute("CREATE TRIGGER token_touch_failure BEFORE UPDATE OF lastUsedAt ON ApiToken BEGIN SELECT RAISE(ABORT,'synthetic usage failure'); END")
        now.addTimeInterval(1)
        try check(try authenticated.withAccess { $0.identity.id } == alice["id"].string, "usage-write failure is nonfatal")
        try execute("DROP TRIGGER token_touch_failure")
        // Access and effects share a transaction; a failed action rolls back.
        try rejects("callback rollback") {
            try authenticated.withAccess { service in
                try service.db.setMetadata("token-test-rollback", value: "must-not-persist")
                throw NativeDBError.conflict
            }
        }
        try check(try db.metadata("token-test-rollback") == nil, "callback effects rolled back")
        let deactivate = try user("deactivate"), d = tokens(deactivate)
        let d1 = try d.issue(name: "一"), d2 = try d.issue(name: "二")
        _ = try db.insert("Session", values: ["token": .text("synthetic-session"), "userId": deactivate["id"], "expiresAt": .text(NativeAPITokens.timestamp(now.addingTimeInterval(3600)))], actor: adminIdentity.id)
        let failingID = max(d1.row.id, d2.row.id)
        try execute("CREATE TRIGGER token_revoke_failure BEFORE UPDATE OF revokedAt ON ApiToken WHEN OLD.id='\(failingID)' BEGIN SELECT RAISE(ABORT,'synthetic revoke failure'); END")
        try rejects("deactivation atomic failure") { try adminTokens.deactivateUser(id: deactivate["id"].string) }
        try check(try db.get("Users", key: ["id": deactivate["id"]])!["userStatus"] == .text("ACTIVE"), "user state rollback")
        try check(try db.page("Session", fields: [], equal: ["userId": deactivate["id"]]).total == 1, "session removal rollback")
        try check(try d.list(activeOnly: true).total == 2, "earlier token revoke rollback")
        try execute("DROP TRIGGER token_revoke_failure")
        try rejects("self deactivation") { try adminTokens.deactivateUser(id: adminIdentity.id) }
        try rejects("manager deactivation") { try tokens(manager).deactivateUser(id: deactivate["id"].string) }
        try adminTokens.deactivateUser(id: deactivate["id"].string)
        try check(try db.get("Users", key: ["id": deactivate["id"]])!["userStatus"] == .text("INACTIVE"), "deactivated user")
        try check(try db.page("Session", fields: [], equal: ["userId": deactivate["id"]]).total == 0, "sessions removed")
        try check(try db.page("ApiToken", fields: [], equal: ["userId": deactivate["id"], "revokedAt": .null]).total == 0, "tokens revoked")
        try rejects("deactivated bearer") { _ = try NativeAPITokens.authenticate(d1.rawToken, db: db, clock: { now }) }
        let deleted = try user("deleted"), deletedToken = try tokens(deleted).issue(name: "削除")
        try db.remove(deleted, actor: adminIdentity.id)
        try check(try db.page("ApiToken", fields: [], equal: ["userId": deleted["id"]]).total == 0, "user deletion cascades tokens")
        try rejects("deleted user token") { _ = try NativeAPITokens.authenticate(deletedToken.rawToken, db: db, clock: { now }) }
        // Four real SQLite connections issue concurrently against the same cap.
        let concurrent = try user("concurrent"), databases = try (0..<4).map { _ in try open() }
        let writers = databases.map { NativeAPITokens(service: service(concurrent, database: $0)) }
        let resultLock = NSLock(); var accepted = 0, errors: [String] = []
        DispatchQueue.concurrentPerform(iterations: writers.count) { index in
            for item in 0..<8 {
                do { _ = try writers[index].issue(name: "並行\(index)-\(item)"); resultLock.lock(); accepted += 1; resultLock.unlock() }
                catch NativeAPITokenError.limit { }
                catch { resultLock.lock(); errors.append(error.localizedDescription); resultLock.unlock() }
            }
        }
        try check(errors.isEmpty && accepted == 10, "cross-connection capacity: \(accepted), errors \(errors)")
        try check(try tokens(concurrent).list(activeOnly: true).total == 10, "capacity persisted exactly ten")
        let reopened = try open()
        try check(try NativeAPITokens.authenticate(current.rawToken, db: reopened, clock: { now }).withAccess { $0.identity.id } == alice["id"].string, "credential survives reopen")
        _ = try adminTokens.revokeAll(userID: alice["id"].string)
        try rejects("other connection observes revocation") { _ = try NativeAPITokens.authenticate(current.rawToken, db: reopened, clock: { now }) }
        let history = try db.history(stored)
        let historyData = try JSONSerialization.data(withJSONObject: history.map { $0.mapValues(\.json) })
        try check(!String(decoding: historyData, as: UTF8.self).contains(issued.rawToken) && !String(decoding: historyData, as: UTF8.self).contains(NativeAPITokens.hash(issued.rawToken)), "audit has no secret or digest")
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where ["sqlite", "sqlite-wal"].contains(file.pathExtension) || file.lastPathComponent.hasSuffix("-wal") {
            try check(try Data(contentsOf: file).range(of: Data(issued.rawToken.utf8)) == nil, "raw secret absent from SQLite and WAL")
        }
    }
}
