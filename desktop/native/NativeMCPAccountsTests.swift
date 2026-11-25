import Foundation

@main enum NativeMCPAccountsTests {
    static var checks = 0
    enum Failure: Error { case assertion(String) }
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.assertion(label) }; checks += 1 }
    static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
    static func id(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", value) }
    actor Buffer { var bytes = Data(); func append(_ data: Data) { bytes.append(data) } }
    actor Gate {
        var openFlag = false, waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { if openFlag { return }; await withCheckedContinuation { waiters.append($0) } }
        func open() { openFlag = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    }
    static func request(_ tool: String, _ input: [String: Any], authorization: String? = nil, method: String = "tools/call") throws -> NativeMCPHTTPRequest {
        var headers = ["accept": "application/json, text/event-stream", "content-type": "application/json"]
        if let authorization { headers["authorization"] = authorization }
        return .init(method: "POST", path: "/api/mcp/mcp", headers: headers, body: try json(["jsonrpc": "2.0", "id": 1, "method": method, "params": ["name": tool, "arguments": input]]))
    }
    static func consume(_ response: NativeMCPHTTPResponse) async throws -> [String: Any] {
        let buffer = Buffer(); try await response.writeBody { await buffer.append($0) }
        let text = String(decoding: await buffer.bytes, as: UTF8.self)
        guard let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("data: ") }),
              let message = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any], let result = message["result"] as? [String: Any] else { throw Failure.assertion("missing JSON-RPC result: " + text) }
        return result
    }
    static func payload(_ result: [String: Any]) throws -> [String: Any] {
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }
    static func normalized(_ value: Any, newID: String? = nil, field: String = "") throws -> Any {
        if var object = value as? [String: Any] {
            if object["code"] as? String == "INTERNAL_ERROR" { object["error"] = "<sanitized-internal>" }
            let generated = (object["id"] as? String) == newID
            var result: [String: Any] = [:]
            for (key, value) in object {
                if ["updatedAt", "deletedAt"].contains(key), !(value is NSNull) {
                    try check(NativeAPITokens.date(.text(value as! String)) != nil, "valid timestamp " + key); result[key] = "<date>"
                } else if generated && key == "createdAt" {
                    try check(NativeAPITokens.date(.text(value as! String)) != nil, "generated creation timestamp"); result[key] = "<date>"
                } else { result[key] = try normalized(value, newID: newID, field: key) }
            }
            return result
        }
        if let array = value as? [Any] { return try array.map { try normalized($0, newID: newID) } }
        if let text = value as? String, text == newID { return "<new>" }
        return value
    }
    static func main() async {
        do { try await run(); print("Native MCP accounts: \(checks) checks passed") }
        catch { fputs("After \(checks) checks: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1])); defer { fixture.close() }
        let router = try fixture.router(), alice = id(1), bob = id(2), manager = id(3)
        try check(router.missingTools.count == 117, "remaining117 handlers explicitly tracked")
        do { _ = try NativeMCPRequestRouter(catalog: fixture.catalog, db: fixture.db, handlers: NativeMCPAccounts.handlers); throw Failure.assertion("partial app runtime enabled") }
        catch NativeMCPInputCatalogError.invalidCatalog { try check(true, "default app construction rejects incomplete registry") }
        let discovery = try await consume(await router.handle(request("", [:], authorization: fixture.header(alice), method: "tools/list")))
        try check((discovery["tools"] as? [[String: Any]])?.count == 6, "discovery advertises only real six handlers")
        let initialToken = try fixture.db.get("ApiToken", key: ["id": .text(fixture.credentials[alice]!.id)])!
        try check(initialToken["lastUsedAt"] == .null, "public discovery does not authenticate or touch credential")
        for sample in fixture.reference["cases"] as! [[String: Any]] {
            try fixture.resetAccounts()
            let tool = sample["tool"] as! String, label = sample["label"] as! String, user = sample["user"] as! String
            let auditBefore = try fixture.db.auditCount("crm_Accounts")
            let result = try await consume(await router.handle(request(tool, sample["input"] as! [String: Any], authorization: fixture.header(user))))
            let actual = try payload(result), expected = try payload(sample["result"] as! [String: Any])
            let newID = tool == "crm_create_account" ? (actual["data"] as? [String: Any])?["id"] as? String : nil
            if let newID { try check(UUID(uuidString: newID) != nil && fixture.initial[newID] == nil, "generated unique account UUID") }
            let left = try json(normalized(actual, newID: newID)), right = try json(normalized(expected, newID: tool == "crm_create_account" ? id(999) : nil))
            try check(left == right, "source case \(label): \(String(decoding: left, as: UTF8.self)) != \(String(decoding: right, as: UTF8.self))")
            try check((result["isError"] as? Bool ?? false) == ((sample["result"] as! [String: Any])["isError"] as? Bool ?? false), "source error flag " + label)
            let writes = ["crm_create_account", "crm_update_account", "crm_delete_account"].contains(tool) && result["isError"] as? Bool != true
            try check(try fixture.db.auditCount("crm_Accounts") == auditBefore + (writes ? 1 : 0), "only successful mutations create account audit entries " + label)
            if writes {
                let changedID = newID ?? (sample["input"] as! [String: Any])["id"] as! String
                let row = try fixture.db.get("crm_Accounts", key: ["id": .text(changedID)])!
                try check(try fixture.db.history(row).first?["actor"] == .text(user), "audit retains API token owner " + label)
            }
            for expectedRow in sample["state"] as! [[String: Any]] {
                let expectedID = expectedRow["id"] as! String, actualID = expectedID == id(999) ? newID! : expectedID
                guard let row = try fixture.db.get("crm_Accounts", key: ["id": .text(actualID)]) else { throw Failure.assertion("missing stored row") }
                let stored = try NativeMCPWire.record(row, schema: fixture.db.schema)
                try check(try json(normalized(stored, newID: newID)) == json(normalized(expectedRow, newID: tool == "crm_create_account" ? id(999) : nil)), "source stored effects " + label)
            }
        }
        try fixture.resetAccounts()
        for header: String? in [nil, "", fixture.credentials[alice]!.raw, "bearer " + fixture.credentials[alice]!.raw, "Bearer wrong", "Bearer nxtc__unknown"] {
            let result = try await consume(await router.handle(request("crm_list_accounts", [:], authorization: header)))
            try check(try payload(result)["code"] as? String == "UNAUTHORIZED", "strict bearer / unknown token rejection")
        }
        for user in [id(5), id(6)] {
            let result = try await consume(await router.handle(request("crm_list_accounts", [:], authorization: fixture.header(user))))
            try check(try payload(result)["code"] as? String == "UNAUTHORIZED", "inactive/partner denied")
        }
        try fixture.change("Users", id: alice, values: ["banned": .integer(1)])
        var result = try await consume(await router.handle(request("crm_list_accounts", [:], authorization: fixture.header(alice))))
        try check(try payload(result)["code"] as? String == "UNAUTHORIZED", "banned user denied")
        try fixture.change("Users", id: alice, values: ["banned": .integer(0)])
        let prepared = await router.handle(try request("crm_get_account", ["id": id(102)], authorization: fixture.header(manager)))
        try fixture.change("Users", id: manager, values: ["role": .text("user")])
        result = try await consume(prepared)
        try check(try payload(result)["code"] as? String == "NOT_FOUND", "lazy request reads fresh downgraded role")
        try fixture.change("Users", id: manager, values: ["role": .text("manager")])
        try fixture.change("ApiToken", id: fixture.credentials[bob]!.id, values: ["expiresAt": .text(NativeAPITokens.timestamp(fixture.now))])
        result = try await consume(await router.handle(request("crm_list_accounts", [:], authorization: fixture.header(bob))))
        try check(try payload(result)["code"] as? String == "UNAUTHORIZED", "exact expiry boundary rejected")
        try fixture.change("ApiToken", id: fixture.credentials[bob]!.id, values: ["expiresAt": .null])
        // Two request-specific closures cannot substitute each other's user.
        async let one = consume(await router.handle(request("crm_get_account", ["id": id(102)], authorization: fixture.header(alice))))
        async let two = consume(await router.handle(request("crm_get_account", ["id": id(102)], authorization: fixture.header(bob))))
        let (denied, allowed) = try await (one, two)
        try check(try payload(denied)["code"] as? String == "NOT_FOUND" && payload(allowed)["data"] != nil, "concurrent requests retain separate token identities")
        let entered = Gate(), release = Gate()
        var waitingHandlers = NativeMCPAccounts.handlers
        waitingHandlers["crm_create_account"] = { session, arguments in
            await entered.open(); await release.wait()
            return try session.withAccess { try NativeMCPAccounts.run("crm_create_account", arguments: arguments, service: $0) }
        }
        let waiting = try fixture.router(handlers: waitingHandlers)
        let response = await waiting.handle(try request("crm_create_account", ["name": "must-not-save"], authorization: fixture.header(alice)))
        let operation = Task { try await consume(response) }; await entered.wait()
        // Revoke through a second real SQLite connection while the operation awaits.
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let other = try NativeDatabase(url: fixture.root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let owner = CRMService(db: other, identity: .init(id: alice, role: "user", partnerAccountID: nil))
        try NativeAPITokens(service: owner).revoke(id: fixture.credentials[alice]!.id); await release.open()
        result = try await operation.value
        try check(try payload(result)["code"] as? String == "UNAUTHORIZED", "revocation after await blocks effect")
        try check(try fixture.db.page("crm_Accounts", fields: [], equal: ["name": .text("must-not-save")]).total == 0, "revoked async operation leaves no account")
        // Cancellation after a write but before the session transaction commits
        // must roll back the write and its audit entry.
        var cancelHandlers = NativeMCPAccounts.handlers
        cancelHandlers["crm_create_account"] = { session, arguments in
            try session.withAccess { service in
                let result = try NativeMCPAccounts.run("crm_create_account", arguments: arguments, service: service)
                withUnsafeCurrentTask { $0?.cancel() }; return result
            }
        }
        let cancelRouter = try fixture.router(handlers: cancelHandlers)
        let auditBeforeCancellation = try fixture.db.auditCount("crm_Accounts")
        let cancelResponse = await cancelRouter.handle(try request("crm_create_account", ["name": "rollback-on-cancel"], authorization: fixture.header(bob)))
        let canceled = Task { try await consume(cancelResponse) }
        do { _ = try await canceled.value; throw Failure.assertion("canceled write succeeded") }
        catch is CancellationError { try check(true, "canceled transaction propagates cancellation") }
        try check(try fixture.db.page("crm_Accounts", fields: [], equal: ["name": .text("rollback-on-cancel")]).total == 0, "canceled account creation rolled back")
        try check(try fixture.db.auditCount("crm_Accounts") == auditBeforeCancellation, "canceled account audit rolled back")
        // The retained database has no bearer value in any account or audit text.
        for credential in fixture.credentials.values {
            let raw = Data(credential.raw.utf8)
            for file in ["crm.sqlite", "crm.sqlite-wal"] {
                let data = try? Data(contentsOf: fixture.root.appendingPathComponent(file))
                try check(data?.range(of: raw) == nil, "raw token absent from database and WAL")
            }
        }
        print("Compared \((fixture.reference["cases"] as! [Any]).count) original handler cases with real SQLite effects")
    }
}
