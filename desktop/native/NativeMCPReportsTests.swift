import Foundation
import SQLite3

@main enum NativeMCPReportsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func values(_ object: [String: Any]) throws -> [String: SQLValue] {
        try object.mapValues { if $0 is NSNull { return .null }; if let n = $0 as? NSNumber { return .integer(n.int64Value) }; if let t = $0 as? String { return .text(t) }; return .text(String(decoding: try json($0), as: UTF8.self)) }
    }
    static func sql(_ db: NativeDatabase, _ statement: String) throws {
        var h: OpaquePointer?; guard sqlite3_open(db.url.path, &h) == SQLITE_OK else { throw Failure.assertion("SQLite open") }; defer { sqlite3_close(h) }
        guard sqlite3_exec(h, statement, nil, nil, nil) == SQLITE_OK else { throw Failure.assertion(String(cString: sqlite3_errmsg(h))) }
    }
    static func outboxCount(_ db: NativeDatabase) throws -> Int {
        var h: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open(db.url.path, &h) == SQLITE_OK else { throw Failure.assertion("SQLite count open") }
        defer { sqlite3_finalize(statement); sqlite3_close(h) }
        guard sqlite3_prepare_v2(h, "SELECT count(*) FROM native_outbox", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw Failure.assertion("outbox count") }
        return Int(sqlite3_column_int64(statement, 0))
    }
    actor Buffer { var bytes = Data(); func append(_ d: Data) { bytes.append(d) } }
    static func call(_ router: NativeMCPRequestRouter, _ tool: String, _ input: [String: Any], _ header: String) async throws -> [String: Any] {
        let body = try json(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": input]])
        let response = await router.handle(.init(method: "POST", path: "/api/mcp/mcp", headers: ["accept": "application/json, text/event-stream", "content-type": "application/json", "authorization": header], body: body)), b = Buffer()
        try await response.writeBody { await b.append($0) }
        let line = String(decoding: await b.bytes, as: UTF8.self).components(separatedBy: "\n").first { $0.hasPrefix("data: ") }!
        return (try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: Any])["result"] as! [String: Any]
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(((result["content"] as! [[String: Any]])[0]["text"] as! String).utf8)) as! [String: Any] }
    static func normalize(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR", !["Unauthenticated", "操作する権限がありません"].contains(object["error"] as? String ?? "") { object["error"] = "<sanitized>" }
            return object.mapValues(normalize)
        }
        if let items = value as? [Any] { return items.map(normalize) }; return value
    }
    static func main() async {
        do { try await run(); print("Native MCP reports: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let ref = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let seeds = ref["seeds"] as! [String: [[String: Any]]], db = f.db, epoch = NativeAPITokens.date(.text(ref["epoch"] as! String))!
        for model in ["Users", "crm_Accounts", "AccountWatchers", "crm_Report_Config", "crm_Leads", "crm_Opportunities", "Boards", "Sections", "Tasks", "crm_campaign_templates", "crm_campaigns", "crm_campaign_steps", "crm_Targets", "crm_campaign_sends"] {
            for seed in seeds[model]! {
                let fields = try values(seed), key: [String: SQLValue]
                if model == "AccountWatchers" { key = ["account_id": fields["account_id"]!, "user_id": fields["user_id"]!] } else { key = ["id": fields["id"]!] }
                if let row = try db.get(model, key: key) {
                    let changes = fields.filter { !key.keys.contains($0.key) && $0.key != "updatedAt" && row[$0.key] != $0.value }
                    if !changes.isEmpty { _ = try db.update(row, changes: changes, actor: f.admin.identity.id) }
                } else { _ = try db.insert(model, values: fields, actor: f.admin.identity.id) }
            }
        }
        // Bootstrap identity is infrastructure and not an original source user.
        try sql(db, "DELETE FROM Users WHERE id='\(f.admin.identity.id)'")
        let router = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { epoch }))
        try check(router.missingTools.count == 121, "two actual report operations")
        let oldJobs = try outboxCount(db)
        for sample in ref["cases"] as! [[String: Any]] { try await compare(sample, router: router, fixture: f) }
        // This simulates a trusted resolver's output, NOT verification of real
        // cookies. The original complete auth chain is executed by the oracle.
        for sample in ref["cookieCases"] as! [[String: Any]] {
            let cookieID = sample["cookie"] as! String
            let r = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { epoch }, authorizeUserDirectory: { _ in
                await Task.yield()
                guard let user = try db.get("Users", key: ["id": .text(cookieID)]), user["userStatus"] == .text("ACTIVE"), user["role"] != .text("partner") else { throw NativeMCPFailure.reportSessionUnauthenticated }
                guard ["manager", "admin"].contains(user["role"].string) else { throw NativeMCPFailure.reportSessionForbidden }
            }))
            try await compare(sample, router: r, fixture: f)
        }
        try check(try outboxCount(db) == oldJobs, "reports do not enqueue mail or mutation events")
        let manager = "00000000-0000-4000-8000-000000000003"
        var invoked = false
        let denied = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { epoch }, authorizeUserDirectory: { _ in invoked = true }))
        _ = try await call(denied, "reports_run", ["category": "users"], f.header("00000000-0000-4000-8000-000000000001"))
        try check(!invoked, "ordinary bearer denied before cookie resolver")
        for mutation in ["role", "banned", "token"] {
            let r = try f.router(handlers: NativeMCPReports.makeHandlers(clock: { epoch }, authorizeUserDirectory: { _ in
                await Task.yield()
                if mutation == "role" { try f.change("Users", id: manager, values: ["role": .text("user")]) }
                else if mutation == "banned" { try f.change("Users", id: manager, values: ["banned": .integer(1)]) }
                else { try f.change("ApiToken", id: f.credentials[manager]!.id, values: ["revokedAt": .text(NativeAPITokens.timestamp(f.now))]) }
            }))
            let result = try payload(await call(r, "reports_run", ["category": "users"], f.header(manager)))
            try check(result["code"] as? String == (mutation == "role" ? "FORBIDDEN" : "UNAUTHORIZED"), "current access after resolver await " + mutation)
            try f.change("Users", id: manager, values: ["role": .text("manager"), "banned": .integer(0)])
            try f.change("ApiToken", id: f.credentials[manager]!.id, values: ["revokedAt": .null])
        }
        print("Compared \((ref["cases"] as! [Any]).count) original token-only reports plus \((ref["cookieCases"] as! [Any]).count) simulated verified-session outcomes; timezone \(ref["timeZone"]!)")
    }
    static func compare(_ sample: [String: Any], router: NativeMCPRequestRouter, fixture f: NativeMCPAccountsFixture) async throws {
        let tool = sample["tool"] as! String, input = sample["input"] as! [String: Any], user = sample["user"] as! String
        let actual = try await call(router, tool, input, f.header(user)), expected = sample["result"] as! [String: Any]
        let left = try json(normalize(payload(actual))), right = try json(normalize(payload(expected)))
        try check(left == right, "\(tool) \(user) \(input): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
        try check((actual["isError"] as? Bool ?? false) == (expected["isError"] as? Bool ?? false), "error flag")
        if let data = try payload(actual)["data"] as? [String: Any], let chart = data["data"] as? [[String: Any]] {
            for point in chart { try check(Set(point.keys) == ["name", "Number"] && point["name"] is String, "source chart field case and name type") }
        }
    }
}
