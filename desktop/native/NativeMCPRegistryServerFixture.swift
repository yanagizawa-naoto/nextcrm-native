import Foundation

private final class RegistryFixtureContext: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (NativeMCPDocumentHTTP, NativeMCPRequestRouter)?
    func install(_ http: NativeMCPDocumentHTTP, router: NativeMCPRequestRouter) { lock.lock(); defer { lock.unlock() }; value = (http, router) }
    func current() -> (NativeMCPDocumentHTTP, NativeMCPRequestRouter)? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Real authenticated operations over TCP, using synthetic users and an isolated
/// temporary SQLite database. Never linked into the application.
@main enum NativeMCPRegistryServerFixture {
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
        let context = RegistryFixtureContext()
        let server = try NativeMCPHTTPServer(configuration: .init(heartbeatInterval: 0.1), bodyReceiver: { try context.current()?.0.bodyReceiver($0) }) { request in
            guard let (http, router) = context.current() else { return .init(status: 503) }
            if let reply = http.handle(request) { return reply }
            return await router.handle(request)
        }
        let url = try await server.start(), bucket = "registry-fixture", secret = "synthetic-registry-storage-secret"
        let signer = try NativeMCPDocumentLocalSigner(appURL: url.absoluteString, secret: secret, clock: { fixture.now })
        let storage = try NativeMCPDocumentStorage.local(publicURL: url.absoluteString, bucket: bucket, appURL: url.absoluteString, secret: secret, clock: { fixture.now })
        let store = try NativeMCPDocumentObjectStore(db: fixture.db, bucket: bucket, signer: signer)
        let secrets = NativeAIQAServices()
        let environment = NativeAIEnvironment { ["OPENAI_API_KEY", "FIRECRAWL_API_KEY", "ANTHROPIC_API_KEY", "E2B_API_KEY"].contains($0) ? "synthetic-never-transmitted-key" : nil }
        let handlers = NativeMCPRegistry.makeHandlers(documentStorage: storage, enrichmentStore: { _ in secrets }, enrichmentEnvironment: environment, clock: { fixture.now })
        var partialRegistryRejected = false
        var incomplete = handlers; incomplete.removeValue(forKey: "reports_run")
        do { _ = try NativeMCPRequestRouter(catalog: fixture.catalog, db: fixture.db, handlers: incomplete) }
        catch NativeMCPInputCatalogError.invalidCatalog { partialRegistryRejected = true }
        _ = try fixture.db.insert("Documents", values: ["id": .text("00000000-0000-4000-8000-000000008801"), "document_name": .text("通信確認用資料"), "document_file_mimeType": .text("text/plain"), "document_file_url": .text("native://fixture"), "created_by_user": .text("00000000-0000-4000-8000-000000000001")], actor: fixture.admin.identity.id)
        _ = try fixture.db.insert("EmailAccount", values: ["id": .text("00000000-0000-4000-8000-000000008802"), "userId": .text("00000000-0000-4000-8000-000000000001"), "label": .text("通信確認"), "imapHost": .text("imap.example.invalid"), "imapPort": .integer(993), "smtpHost": .text("smtp.example.invalid"), "smtpPort": .integer(465), "username": .text("fixture@example.invalid"), "passwordEncrypted": .text("synthetic-not-a-credential")], actor: fixture.admin.identity.id)
        _ = try fixture.db.insert("NumberSeries", values: ["scope": .text("order"), "name": .text("通信注文"), "template": .text("WIRE-{YYYY}-{####}"), "isDefault": .integer(1), "active": .integer(1)], actor: fixture.admin.identity.id)
        let router = try NativeMCPRequestRouter(catalog: fixture.catalog, db: fixture.db, handlers: handlers, clock: { fixture.now })
        context.install(NativeMCPDocumentHTTP(store: store), router: router)
        // Synthetic credentials travel only through this private child pipe.
        try emit(["ready": url.absoluteString, "credentials": fixture.credentials.mapValues { $0.raw }, "tools": handlers.keys.sorted(), "partialRegistryRejected": partialRegistryRejected, "fullRegistryAccepted": router.missingTools.isEmpty])
        while let line = readLine() {
            let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            switch command["command"] {
            case "uiFirstStep":
                // The original MCP schema permits only step order >=1. Step0
                // comes from the campaign editor, also in the native app.
                let campaign = try fixture.admin.campaign(command["id"]!)
                _ = try fixture.admin.saveCampaignStep(campaign: campaign, original: nil, input: .init(order: 0, templateID: command["template"]!, subject: "初回件名"))
                try emit(["created": true])
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
                let row = try reopened.get(command["model"] ?? "crm_Accounts", key: ["id": .text(command["id"]!)])!
                try emit(["row": try NativeMCPWire.record(row, schema: reopened.schema), "actor": try reopened.history(row).first?["actor"]?.string ?? ""])
            case "jobs":
                let events = ["crm.lead_assigned", "crm/lead.saved", "crm/opportunity.saved", "calendar/outbound", CampaignWorkflow.sendEvent, NativeContactEnrichment.event, NativeContactEnrichment.bulkEvent, NativeTargetEnrichment.event, NativeTargetEnrichment.bulkEvent, "orders.approval_requested", "orders.approval_decided"]
                let jobs = try fixture.db.jobs(events: events)
                try emit(["events": jobs.map(\.event)])
            case "quit":
                await server.stop(); try emit(["stopped": true]); return
            default: throw NativeMCPFailure.internalError
            }
        }
        await server.stop()
    }
}
