import Foundation
import SQLite3

@main struct NativeIdentityMailTests {
    final class State {
        var now = Date(timeIntervalSince1970: 1_795_137_600)
        var available = true, code = "173629", key = "synthetic-provider-key"
        var requests = 0, resolutions = 0, lookups = 0
        var replies: [Int] = [200], bodies: [Data] = [], requestKeys: [String] = []
        var beforeTransport: (() throws -> Void)?
        var beforeReply: (() throws -> Void)?
        var rawFailure = false
    }
    enum Failure: Error { case expected }
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: "IdentityMailTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks += 1
    }
    static func deny(_ block: () throws -> Void, _ label: String) throws {
        do { try block() } catch { checks += 1; return }; try check(false, label)
    }
    static func denyAsync(_ block: () async throws -> Void, _ label: String) async throws {
        do { try await block() } catch { checks += 1; return }; try check(false, label)
    }
    static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let workspace = try NativeIdentityWorkspace(id: "synthetic-workspace", issuer: "https://identity.invalid")
        let configuration = try NativeIdentityMailConfiguration(workspace: workspace, applicationName: "日本語CRM", sender: "sender@example.invalid", loginURL: URL(string: "https://identity.invalid/login"))
        let binding = try NativeIdentityMailBinding(secret: Data(repeating: 0x41, count: 32))
        for url in ["http://identity.invalid/login", "https://other.invalid/login", "https://user:pass@identity.invalid/login", "https://identity.invalid/login#token", "https://identity.invalid:8443/login"] {
            try deny({ _ = try NativeIdentityMailConfiguration(workspace: workspace, applicationName: "CRM", sender: "sender@example.invalid", loginURL: URL(string: url)) }, "invalid login origin")
        }
        try deny({ _ = try NativeIdentityMailBinding(secret: Data(repeating: 1, count: 16)) }, "weak binding secret")
        for code in ["12345", "1234567", "１２３４５６", "12345\n"] { try deny({ _ = try NativeIdentityMailContent.code(code) }, "invalid OTP") }
        let content = try NativeIdentityMailContent.code("173629")
        try check(!String(describing: content).contains("173629"), "description does not expose OTP")
        try check(!String(reflecting: content).contains("173629"), "debug description does not expose OTP")
        for kind in [NativeIdentityMailIntent.Kind.invitation, .activation, .newUserNotice] {
            let material = try NativeIdentityMailContent.notification(kind, name: "利用者", inviter: "管理者", configuration: configuration)
            try check(material.text.contains("https://identity.invalid/login"), "notification reaches configured authority")
            try check(material.subject.contains("日本語CRM"), "Japanese notification subject")
        }
        let withoutLogin = try NativeIdentityMailConfiguration(workspace: workspace, applicationName: "CRM", sender: "sender@example.invalid", loginURL: nil)
        try deny({ _ = try NativeIdentityMailContent.notification(.invitation, name: "利用者", inviter: "管理者", configuration: withoutLogin) }, "invitation unconfigured without usable URL")

        func database(_ name: String) throws -> NativeDatabase {
            let directory = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return try NativeDatabase(url: directory.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        }
        func intent(_ state: State, id: String = UUID().uuidString.lowercased(), reference: String = UUID().uuidString.lowercased(), expiry: TimeInterval = 300) throws -> NativeIdentityMailIntent {
            try .init(id: id, workspace: workspace, referenceID: reference, recipient: "Person@Example.invalid", kind: .signInCode, issuedAt: state.now, expiresAt: state.now.addingTimeInterval(expiry))
        }
        func worker(_ db: NativeDatabase, _ state: State) -> NativeIdentityMailWorker {
            NativeIdentityMailWorker(db: db, configuration: configuration, binding: binding, resolve: { _, _ in
                state.resolutions += 1; return state.available ? try NativeIdentityMailContent.code(state.code) : nil
            }, transport: {
                state.lookups += 1; try state.beforeTransport?()
                return try NativeIdentityMailTransport.make(apiKey: state.key, request: { request, body in
                    state.requests += 1; state.bodies.append(body); state.requestKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
                    try check(request.url?.absoluteString == "https://api.resend.com/emails" && request.httpMethod == "POST", "actual Resend endpoint construction")
                    try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + state.key, "selected sender credential")
                    try state.beforeReply?()
                    if state.rawFailure { throw NSError(domain: "secret", code: 9, userInfo: [NSLocalizedDescriptionKey: "must-not-log-OTP-" + state.code]) }
                    let status = state.replies.isEmpty ? 200 : state.replies.removeFirst()
                    let data = status == 200 ? Data("{\"id\":\"00000000-0000-4000-8000-000000000099\"}".utf8) : Data("{\"name\":\"synthetic_failure\"}".utf8)
                    return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
                })
            }, clock: { state.now })
        }
        func safe(_ db: NativeDatabase, _ id: String, code: String) throws {
            let job = try db.job(id: id)!
            for text in Array(job.payload.values) + Array(job.result.values) { try check(!text.contains(code), "queue never contains OTP") }
            try check(!(job.lastError ?? "").contains(code), "queue error never contains OTP")
            try check(!FileManager.default.fileExists(atPath: db.url.deletingLastPathComponent().appendingPathComponent("mail-outbox").path), "no plaintext body spool")
        }
        do {
            let state = State(), db = try database("accepted"), item = try intent(state), send = worker(db, state)
            try check(item.recipient == "person@example.invalid", "OTP follows source lowercase email")
            try await check(send.enqueue(item) == item.id, "enqueued")
            _ = try await send.enqueue(item)
            try check(try db.job(id: item.id)?.attempts == 0, "same intent is idempotent enqueue")
            try await check(send.runNext(), "accepted worker processed")
            try check(state.requests == 1 && db.job(id: item.id)?.result["outcome"] == "accepted", "provider acceptance recorded")
            try check(state.requestKeys == ["nextcrm/identity/" + item.id], "identity-specific stable send key")
            let body = try JSONSerialization.jsonObject(with: state.bodies[0]) as! [String: Any]
            try check((body["to"] as? [String]) == [item.recipient] && (body["text"] as? String)?.contains(state.code) == true, "real serialized code and recipient")
            try safe(db, item.id, code: state.code)
            let other = try intent(state, id: item.id)
            try await denyAsync({ _ = try await send.enqueue(other) }, "same ID cannot replace reference")
        }
        do {
            let state = State(); try deny({ _ = try intent(state, expiry: 301) }, "source OTP five-minute maximum")
            let db = try database("expired"), item = try intent(state), send = worker(db, state)
            _ = try await send.enqueue(item); state.now = item.expiresAt!
            _ = try await send.runNext()
            try check(state.requests == 0 && state.lookups == 0 && db.job(id: item.id)?.result["outcome"] == "expired", "expired before even credential lookup")
        }
        do {
            let state = State(), db = try database("superseded"), item = try intent(state), send = worker(db, state)
            _ = try await send.enqueue(item); state.available = false; _ = try await send.runNext()
            try check(state.requests == 0 && db.job(id: item.id)?.result["outcome"] == "superseded", "resend invalidates prior challenge")
        }
        do {
            let state = State(), db = try database("retry"), item = try intent(state), send = worker(db, state); state.replies = [500, 200]
            _ = try await send.enqueue(item); _ = try await send.runNext()
            try check(try db.job(id: item.id)?.status == "retry", "transient error retries within expiry")
            state.now = state.now.addingTimeInterval(6); _ = try await send.runNext()
            try check(state.requests == 2 && state.bodies[0] == state.bodies[1] && Set(state.requestKeys).count == 1, "retry exact bytes and idempotency ID")
            try safe(db, item.id, code: state.code)
        }
        for mode in ["expiry", "body", "transport", "authority"] {
            let state = State(), db = try database("changed-" + mode), item = try intent(state), send = worker(db, state); state.replies = [500]
            _ = try await send.enqueue(item); _ = try await send.runNext(); state.now = state.now.addingTimeInterval(6)
            if mode == "expiry" { state.now = item.expiresAt! }
            if mode == "body" { state.code = "991134" }
            if mode == "transport" { state.key = "different-synthetic-key" }
            if mode == "authority" { state.available = false }
            _ = try await send.runNext()
            try check(state.requests == 1 && db.job(id: item.id)?.status == "needs_review", "no new send after " + mode + " change")
        }
        do {
            let state = State(), db = try database("recheck"), item = try intent(state), send = worker(db, state)
            _ = try await send.enqueue(item); state.beforeTransport = { state.available = false }; _ = try await send.runNext()
            try check(state.requests == 0 && db.job(id: item.id)?.deliveryStartedAt == nil, "revalidate after secret lookup")
        }
        do {
            let state = State(), db = try database("last-attempt"), item = try intent(state, expiry: 2), send = worker(db, state); state.replies = [500]
            _ = try await send.enqueue(item); _ = try await send.runNext()
            try check(try db.job(id: item.id)?.status == "needs_review", "retry is not queued beyond expiry")
        }
        do {
            let state = State(), db = try database("raw-error"), item = try intent(state), send = worker(db, state); state.rawFailure = true
            _ = try await send.enqueue(item); _ = try await send.runNext(); try safe(db, item.id, code: state.code)
        }
        do {
            let state = State(), db = try database("finish-failure"), item = try intent(state), send = worker(db, state)
            var sqlite: OpaquePointer?; try check(sqlite3_open(db.url.path, &sqlite) == SQLITE_OK, "failure connection")
            guard let sqlite else { throw Failure.expected }; defer { sqlite3_close(sqlite) }
            func sql(_ text: String) throws { try check(sqlite3_exec(sqlite, text, nil, nil, nil) == SQLITE_OK, "injected SQLite fixture SQL") }
            try sql("CREATE TRIGGER fail_identity_finish BEFORE UPDATE OF status ON native_outbox WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT,'synthetic finalization failure'); END")
            _ = try await send.enqueue(item); _ = try await send.runNext()
            try check(try db.job(id: item.id)?.result["providerID"] != nil && db.job(id: item.id)?.status == "retry", "acceptance durable before failed finalization")
            try sql("DROP TRIGGER fail_identity_finish"); state.now = item.expiresAt!.addingTimeInterval(1); state.available = false
            _ = try await send.runNext()
            try check(state.requests == 1 && db.job(id: item.id)?.result["outcome"] == "accepted", "accepted result finishes after expiry without resend")
        }
        do {
            let state = State(), db = try database("fenced"), item = try intent(state), send = worker(db, state)
            state.beforeReply = {
                state.now = state.now.addingTimeInterval(301)
                let replacement = try db.claimJob(events: [NativeIdentityMailWorker.event], now: state.now)!
                try db.finishJob(replacement, result: ["outcome": "replacement-worker"], now: state.now)
            }
            _ = try await send.enqueue(item); _ = try await send.runNext()
            try check(try db.job(id: item.id)?.result["outcome"] == "replacement-worker", "stale worker cannot overwrite newer lease")
        }
        do {
            func sealed() throws -> URL {
                // Reuse the actual native sealing API: it registers the schema's
                // custom collations and closes this exclusively owned fixture.
                let db = try database("readonly")
                try db.setMetadata("migration.operational.state", value: "review-required")
                try db.sealOperationalMigration()
                // The sealed connection is closed and all committed pages are in
                // the main file. Use a new immutable snapshot pathname: a stale
                // shared-memory sidecar on the source is not part of this snapshot.
                let destination = root.appendingPathComponent("readonly-sealed.sqlite")
                try FileManager.default.copyItem(at: db.url, to: destination)
                for suffix in ["-wal", "-shm", "-journal"] {
                    try check(!FileManager.default.fileExists(atPath: destination.path + suffix), "sealed snapshot has no " + suffix)
                }
                return destination
            }
            let url = try sealed()
            let db = try NativeDatabase(readOnlyURL: url, schemaURL: resources.appendingPathComponent("schema.json"))
            let state = State(), send = worker(db, state), item = try intent(state)
            try await denyAsync({ _ = try await send.enqueue(item) }, "readonly enqueue rejected")
            try await denyAsync({ _ = try await send.runNext() }, "readonly delivery rejected")
            try check(state.resolutions == 0 && state.requests == 0 && state.lookups == 0, "readonly does not read code or sender credential")
        }
        let ids = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        try check(!ids.contains(where: { $0.lastPathComponent.contains("mail-outbox") }), "no root plaintext spool")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "externalRequests": 0, "actualSQLiteQueue": true, "diskOTPSpools": 0], options: [.sortedKeys]), as: UTF8.self))
    }
}
