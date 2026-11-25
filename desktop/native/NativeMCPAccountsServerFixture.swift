import Foundation

/// Real authenticated operations over TCP, using synthetic users and an isolated
/// temporary SQLite database. Never linked into the application.
@main enum NativeMCPAccountsServerFixture {
    static func emit(_ object: [String: Any]) throws {
        print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
    }
    static func main() async {
        do { try await run() }
        catch { try? emit(["fatal": String(describing: error)]); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try NativeMCPAccountsFixture(resources: resources); defer { fixture.close() }
        let handlers = NativeMCPAccounts.handlers.merging(NativeMCPContacts.handlers) { _, _ in fatalError("duplicate tool") }.merging(NativeMCPUsers.handlers) { _, _ in fatalError("duplicate tool") }
        let router = try fixture.router(handlers: handlers)
        let server = try NativeMCPHTTPServer(configuration: .init(heartbeatInterval: 0.1)) { await router.handle($0) }
        let url = try await server.start()
        // Synthetic credentials travel only through this private child pipe.
        try emit(["ready": url.absoluteString, "credentials": fixture.credentials.mapValues { $0.raw }])
        while let line = readLine() {
            let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            switch command["command"] {
            case "stats":
                let s = await server.snapshot()
                try emit(["connections": s.connections, "requests": s.runningRequests, "retained": s.retainedPeers, "accepted": s.accepted, "rejected": s.rejected])
            case "role":
                try fixture.change("Users", id: command["id"]!, values: ["role": .text(command["role"]!)]); try emit(["changed": true])
            case "revoke":
                let user = command["id"]!
                let owner = CRMService(db: fixture.db, identity: .init(id: user, role: "user", partnerAccountID: nil))
                try NativeAPITokens(service: owner).revoke(id: fixture.credentials[user]!.id); try emit(["revoked": true])
            case "stored":
                let reopened = try NativeDatabase(url: fixture.root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
                let row = try reopened.get("crm_Accounts", key: ["id": .text(command["id"]!)])!
                try emit(["row": try NativeMCPWire.record(row, schema: reopened.schema), "actor": try reopened.history(row).first?["actor"]?.string ?? ""])
            case "quit":
                await server.stop(); try emit(["stopped": true]); return
            default: throw NativeMCPFailure.internalError
            }
        }
        await server.stop()
    }
}
