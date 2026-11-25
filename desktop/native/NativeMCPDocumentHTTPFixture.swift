import Foundation

private final class DocumentHTTPFixtureContext: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (NativeMCPDocumentHTTP, NativeMCPRequestRouter)?, offset: TimeInterval = 0
    func install(_ http: NativeMCPDocumentHTTP, router: NativeMCPRequestRouter) { lock.lock(); defer { lock.unlock() }; value = (http, router) }
    func current() -> (NativeMCPDocumentHTTP, NativeMCPRequestRouter)? { lock.lock(); defer { lock.unlock() }; return value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: 1_795_046_400 + offset) }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; offset += seconds }
}
@main enum NativeMCPDocumentHTTPFixture {
    static func emit(_ object: Any) throws { print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout) }
    static func main() async {
        do { try await run() } catch { try? emit(["fatal": String(describing: error)]); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), fixture = try NativeMCPAccountsFixture(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { fixture.close() }
        let context = DocumentHTTPFixtureContext()
        let server = try NativeMCPHTTPServer(configuration: .init(readTimeout: 3, requestTimeout: 20, sendTimeout: 3, heartbeatInterval: 0.02), bodyReceiver: { try context.current()?.0.bodyReceiver($0) }) { request in
            guard let (http, router) = context.current() else { return .init(status: 503) }
            if let reply = http.handle(request) { return reply }
            return await router.handle(request)
        }
        let base = try await server.start(), bucket = "isolated-test", secret = "isolated-signed-capability-fixture"
        let signer = try NativeMCPDocumentLocalSigner(appURL: base.absoluteString, secret: secret, clock: { context.now() })
        let storage = try NativeMCPDocumentStorage.local(publicURL: base.absoluteString, bucket: bucket, appURL: base.absoluteString, secret: secret, clock: { context.now() })
        let store = try NativeMCPDocumentObjectStore(db: fixture.db, bucket: bucket, signer: signer)
        let router = try fixture.router(handlers: NativeMCPDocuments.handlers(storage: storage))
        context.install(NativeMCPDocumentHTTP(store: store), router: router)
        try emit(["ready": base.absoluteString, "credentials": fixture.credentials.mapValues { $0.raw }])
        while let line = readLine() {
            let command = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
            switch command["command"] {
            case "stored":
                let reopened = try NativeDatabase(url: fixture.db.url, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
                let row = try reopened.get("Documents", key: ["id": .text(command["id"]!)])!
                try emit(["row": try NativeMCPWire.record(row, schema: reopened.schema), "revision": row.revision])
            case "sign": try emit(["url": try signer.url(key: command["key"]!, method: command["method"]!, expiresIn: Int(command["expires"] ?? "3600")!, contentType: command["type"] ?? "")])
            case "advance": context.advance(Double(command["seconds"]!)!); try emit(["advanced": true])
            case "revoke":
                let id = command["id"]!, owner = CRMService(db: fixture.db, identity: .init(id: command["id"]!, role: "user", partnerAccountID: nil))
                try NativeAPITokens(service: owner).revoke(id: fixture.credentials[id]!.id); try emit(["revoked": true])
            case "stats":
                let status = await server.snapshot(), directory = fixture.root.appendingPathComponent("native-documents")
                let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                try emit(["retained": status.retainedPeers, "running": status.runningRequests, "staging": files.filter { $0.hasPrefix(".stage-") }.count])
            case "quit": await server.stop(); try emit(["stopped": true]); return
            default: throw NativeMCPFailure.internalError
            }
        }
        await server.stop()
    }
}
