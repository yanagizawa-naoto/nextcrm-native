import Foundation
import SQLite3
import CryptoKit

@main enum NativeMCPSessionAuthTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ ok: Bool, _ label: String) throws { guard ok else { throw Failure.assertion(label) }; checks += 1 }
    static func id(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
    static func json(_ v: Any) throws -> Data { try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ d: [String: Any]) throws -> [String: SQLValue] { try d.mapValues { if $0 is NSNull { return .null }; if let n = $0 as? NSNumber { return .integer(n.int64Value) }; if let s = $0 as? String { return .text(s) }; return .text(String(decoding: try json($0), as: UTF8.self)) } }
    static func sql(_ db: NativeDatabase, _ sql: String) throws {
        var h: OpaquePointer?; guard sqlite3_open(db.url.path, &h) == SQLITE_OK else { throw Failure.assertion("SQLite open") }; defer { sqlite3_close(h) }
        guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion(String(cString: sqlite3_errmsg(h))) }
    }
    static func auditBytes(_ db: NativeDatabase) throws -> String {
        var h: OpaquePointer?, st: OpaquePointer?; guard sqlite3_open(db.url.path, &h) == SQLITE_OK else { throw Failure.assertion("audit open") }; defer { sqlite3_finalize(st); sqlite3_close(h) }
        guard sqlite3_prepare_v2(h, "SELECT before_json,after_json FROM native_audit", -1, &st, nil) == SQLITE_OK else { throw Failure.assertion("audit query") }
        var text = ""; while sqlite3_step(st) == SQLITE_ROW { for i: Int32 in [0,1] { if let p = sqlite3_column_text(st, i) { text += String(cString: p) } } }; return text
    }
    actor Started {
        var ready = false
        var waiter: CheckedContinuation<Void, Never>?
        func signal() { ready = true; waiter?.resume(); waiter = nil }
        func wait() async { if ready { return }; await withCheckedContinuation { waiter = $0 } }
    }
    actor Buffer { var bytes = Data(); func append(_ data: Data) { bytes.append(data) } }
    static func request(_ cookie: String?, header: String, body: Data? = nil) throws -> NativeMCPHTTPRequest {
        var headers = ["accept": "application/json, text/event-stream", "content-type": "application/json", "authorization": header]
        if let cookie { headers["cookie"] = cookie }
        return .init(method: "POST", path: "/api/mcp/mcp", headers: headers, body: try body ?? json(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "reports_run", "arguments": ["category": "users", "dateFrom": "2026-01-01T00:00:00Z", "dateTo": "2026-12-31T23:59:59Z"]]]))
    }
    static func collect(_ response: NativeMCPHTTPResponse) async throws -> [String: Any] {
        let b = Buffer(); try await response.writeBody { await b.append($0) }
        let bytes = await b.bytes
        if response.headers["content-type"] == "application/json" { return try JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
        let line = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!
        return (try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any])["result"] as! [String: Any]
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(((result["content"] as! [[String: Any]])[0]["text"] as! String).utf8)) as! [String: Any] }
    static func main() async {
        do { try await run(); print("Native signed-cookie session auth: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let ref = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let db = f.db, now = NativeAPITokens.date(.text(ref["epoch"] as! String))!, secret = ref["secret"] as! String
        let config = try NativeMCPSessionAuth.Configuration(secret: Data(secret.utf8), secureCookies: ref["secure"] as! Bool)
        try sql(db, "DELETE FROM Users WHERE id='\(f.admin.identity.id)'")
        let samples = ref["cases"] as! [[String: Any]]
        func reset(_ sample: [String: Any]) throws {
            try sql(db, "DELETE FROM Session")
            let before = sample["before"] as! [String: Any], users = before["users"] as! [[String: Any]], ids = Set(users.map { $0["id"] as! String })
            for n in 1...6 where !ids.contains(id(n)) { try sql(db, "DELETE FROM Users WHERE id='\(id(n))'") }
            for item in users {
                let data = try values(item)
                if let row = try db.get("Users", key: ["id": data["id"]!]) {
                    let changes = data.filter { $0.key != "id" && $0.key != "updated_at" && row[$0.key] != $0.value }
                    if !changes.isEmpty { _ = try db.update(row, changes: changes, actor: id(4)) }
                } else { _ = try db.insert("Users", values: data, actor: id(4)) }
            }
            for item in before["sessions"] as! [[String: Any]] { _ = try db.insert("Session", values: values(item), actor: id(4)) }
        }
        let router = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { now }, authorizeUserDirectory: { session in
            await Task.yield()
            let decision = try session.withAccess { try NativeMCPSessionAuth.userDirectoryDecision(cookie: NativeMCPRequestContext.cookie, db: $0.db, configuration: config, now: now) }
            _ = try decision.get()
        }))
        var intentional = 0
        for sample in samples {
            try reset(sample)
            let cookie = sample["cookie"] as? String, bearer = sample["bearer"] as! [String: String], q = sample["request"] as! [String: Any], label = q["label"] as! String
            let before = sample["before"] as! [String: Any], source = sample["result"] as! [String: Any]
            let equality = (q["expiry"] as? NSNumber)?.intValue == 0, banned = (q["userChange"] as? [String: Any])?["banned"] as? Bool == true
            let hardened = equality || banned
            let oldAudit = try db.auditCount("Session")
            let response = await router.handle(try request(cookie, header: f.header(bearer["id"]!)))
            try check(response.headers["content-type"] == "text/event-stream", "lazy SSE response")
            let result = try await collect(response), actual = try payload(result)
            let expected: [String: Any] = hardened ? NativeMCPFailure.reportSessionUnauthenticated.payload : try payload(source)
            try check(try json(actual) == json(expected), "source/auth decision \(label): \(actual) != \(expected)")
            try check((result["isError"] as? Bool ?? false) == (hardened || source["isError"] as? Bool == true), "error flag " + label)
            let rows = try db.page("Session", fields: db.schema.model("Session").fields.map(\.name)).rows
            let actualSessions = try rows.map { try NativeMCPWire.record($0, schema: db.schema) }
            let expectedSessions: Any = equality ? [] : banned ? before["sessions"]! : (sample["after"] as! [String: Any])["sessions"]!
            try check(try json(actualSessions) == json(expectedSessions), "expiry cleanup/refresh/dont_remember state " + label)
            try check(try db.auditCount("Session") == oldAudit, "session maintenance has no audit amplification")
            try check(NativeMCPRequestContext.cookie == nil, "context cleared after response/throw")
            if hardened { intentional += 1 }
            let errorText = String(decoding: try json(result), as: UTF8.self)
            try check(!errorText.contains(secret) && !errorText.contains("isolated-session-token"), "response contains no secret/token")
        }
        let audit = try auditBytes(db)
        try check(!audit.contains(secret) && !audit.contains("isolated-session-token") && !audit.contains("session_token="), "all persisted audit payloads omit raw auth material")
        try check(intentional == 4, "explicit equality and banned hardening cases")
        let valid = samples.first { ($0["request"] as! [String: Any])["label"] as? String == "cookie role/status 3" }!
        let wrongRole = samples.first { ($0["request"] as! [String: Any])["label"] as? String == "cookie role/status 1" }!
        try reset(valid)
        let validCookie = valid["cookie"] as! String
        // A separate valid signed token for user1 lets requests overlap without
        // changing database state or sharing a single cookie identity.
        let base = (valid["before"] as! [String: Any])["sessions"] as! [[String: Any]]
        var second = base[0]; second["id"] = id(901); second["token"] = "parallel-user-token"; second["userId"] = id(1)
        _ = try db.insert("Session", values: values(second), actor: id(4))
        let parallelCookie = try syntheticCookie(token: "parallel-user-token", config: config)
        let responses = await [router.handle(try request(validCookie, header: f.header(id(4)))), router.handle(try request(parallelCookie, header: f.header(id(4)))), router.handle(try request(nil, header: f.header(id(4))))]
        // The stream bodies actually execute in separate tasks, after handle()
        // returned. This detects context established at the wrong lifecycle point.
        let outputs = try await withThrowingTaskGroup(of: (Int, [String: Any]).self) { group in
            for (index, response) in responses.enumerated() { group.addTask { (index, try await payload(collect(response))) } }
            var outputs: [Int: [String: Any]] = [:]; for try await (i, value) in group { outputs[i] = value }; return outputs
        }
        try check(outputs[0]?["data"] != nil && outputs[1]?["error"] as? String == "操作する権限がありません" && outputs[2]?["error"] as? String == "Unauthenticated", "parallel distinct cookies and no-cookie remain isolated")
        try check(NativeMCPRequestContext.cookie == nil, "parallel contexts restore")
        let malformed = await router.handle(try request(validCookie, header: f.header(id(4)), body: Data("{bad".utf8)))
        try check(malformed.headers["content-type"] == "application/json", "invalid JSON produces immediate JSON response")
        _ = try await collect(malformed)
        try check(NativeMCPRequestContext.cookie == nil, "immediate JSON path does not establish cookie context")
        let cancellationRouter = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { now }, authorizeUserDirectory: { _ in
            try check(NativeMCPRequestContext.cookie == validCookie, "cookie present inside cancelling dispatch")
            throw CancellationError()
        }))
        let cancelled = await cancellationRouter.handle(try request(validCookie, header: f.header(id(4))))
        do { _ = try await collect(cancelled); throw Failure.assertion("cancellation swallowed") } catch is CancellationError { checks += 1 }
        try check(NativeMCPRequestContext.cookie == nil, "cancelled context restores")
        let started = Started()
        let suspendedRouter = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { now }, authorizeUserDirectory: { _ in
            try check(NativeMCPRequestContext.cookie == validCookie, "context present before suspension")
            await started.signal()
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }))
        let suspended = await suspendedRouter.handle(try request(validCookie, header: f.header(id(4))))
        let task = Task { () throws -> Bool in
            do { _ = try await collect(suspended); return false }
            catch is CancellationError { return NativeMCPRequestContext.cookie == nil }
        }
        await started.wait(); task.cancel()
        try check(try await task.value, "external task cancellation unwinds cookie context")
        try check(NativeMCPRequestContext.cookie == nil, "parent context unchanged after task cancellation")
        let stale = try db.get("Session", key: ["id": .text(id(900))])!
        let later = NativeAPITokens.timestamp(now.addingTimeInterval(8 * 86400)), stamp = NativeAPITokens.timestamp(now)
        let auditBefore = try db.auditCount("Session")
        let renewed = try db.refreshBrowserSession(stale, expiresAt: later, updatedAt: stamp)!
        try check(renewed["expiresAt"] == .text(later) && renewed["updatedAt"] == .text(stamp), "refresh preserves explicit clock timestamps")
        try check(try db.refreshBrowserSession(stale, expiresAt: stamp, updatedAt: stamp) == nil, "stale refresh cannot overwrite renewal")
        try db.deleteExpiredBrowserSession(stale)
        try check(try db.get("Session", key: ["id": stale["id"]])?.revision == renewed.revision, "stale expiry cleanup cannot delete renewed session")
        try check(try db.auditCount("Session") == auditBefore, "fenced maintenance adds no audit entries")
        do { _ = try db.refreshBrowserSession(db.get("Users", key: ["id": .text(id(4))])!, expiresAt: later, updatedAt: stamp); throw Failure.assertion("wrong model accepted") } catch is NativeDBError { checks += 1 }
        do { _ = try NativeMCPSessionAuth.Configuration(secret: Data("too-short".utf8)); throw Failure.assertion("short signing key accepted") } catch is NativeDBError { checks += 1 }
        _ = wrongRole
        print("Compared \(samples.count) real BetterAuth report/session cases; \(intentional) intentional native hardening differences; secure=\(ref["secure"]!)")
    }
    static func syntheticCookie(token: String, config: NativeMCPSessionAuth.Configuration) throws -> String {
        // Signing is only a fixture helper; production exposes verification only.
        let mac = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: SymmetricKey(data: config.secret))
        let raw = token + "." + Data(mac).base64EncodedString()
        return config.prefix + "session_token=" + raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    }
}
