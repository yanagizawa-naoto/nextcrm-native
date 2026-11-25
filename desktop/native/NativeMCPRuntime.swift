import Foundation
import CryptoKit
import Network

/// One application-owned runtime, on IPv4 loopback only. Configuration and
/// credentials are lazy: a disabled launch does not read Keychain or catalog.
actor NativeMCPRuntime {
    enum State: String { case disabled, stopped, starting, running, stopping, failed }
    struct Snapshot {
        var state: State
        var endpoint: String?
        var message: String?
        var connections = 0, runningRequests = 0, retainedPeers = 0, peakConnections = 0, accepted = 0, rejected = 0
    }
    typealias AuthorizationFactory = (String) -> NativeMCPReports.UserDirectoryAuthorization
    private let db: NativeDatabase, catalogURL: URL, secretStore: NativeMCPSecretStore
    private let enrichmentStore: NativeMCPEnrichment.Store, enrichmentEnvironment: NativeAIEnvironment
    private let authorizeUserDirectory: AuthorizationFactory, wakeJobs: () async -> Void, clock: () -> Date
    private var server: NativeMCPHTTPServer?, generation = UUID()
    private var status = Snapshot(state: .stopped)
    init(db: NativeDatabase, catalogURL: URL, secretStore: NativeMCPSecretStore? = nil,
         enrichmentStore: @escaping NativeMCPEnrichment.Store = { KeychainNativeAISecrets(databaseURL: $0.db.url) },
         enrichmentEnvironment: NativeAIEnvironment = NativeAIEnvironment(),
         authorizeUserDirectory: @escaping AuthorizationFactory = { _ in { _ in throw NativeMCPFailure.reportSessionUnauthenticated } },
         wakeJobs: @escaping () async -> Void = {}, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.catalogURL = catalogURL
        self.secretStore = secretStore ?? KeychainNativeMCPSecrets(databaseURL: db.url)
        self.enrichmentStore = enrichmentStore; self.enrichmentEnvironment = enrichmentEnvironment
        self.authorizeUserDirectory = authorizeUserDirectory; self.wakeJobs = wakeJobs; self.clock = clock
    }
    func snapshot() async -> Snapshot {
        let ticket = generation
        var value = status
        if let server {
            let counts = await server.snapshot()
            guard ticket == generation else { return status }
            value.connections = counts.connections; value.runningRequests = counts.runningRequests
            value.retainedPeers = counts.retainedPeers; value.peakConnections = counts.peakConnections
            value.accepted = counts.accepted; value.rejected = counts.rejected
        }
        return value
    }
    /// Separate purposes share one immutable per-database seed, not the same
    /// HMAC key. Original BetterAuth secret migration remains an explicit task.
    static func derivedSecret(_ seed: String, purpose: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(("nextcrm-native-mcp-v1/" + purpose).utf8), using: SymmetricKey(data: Data(seed.utf8)))).base64EncodedString()
    }
    @discardableResult func start() async throws -> Snapshot {
        guard server == nil, status.state != .starting, status.state != .stopping else { throw NativeMCPHTTPServerError.alreadyStarted }
        let ticket = UUID(); generation = ticket; status = .init(state: .starting)
        var candidate: NativeMCPHTTPServer?
        do {
            try Task.checkCancellation()
            let settings = try NativeMCPSettingsStore.read(db: db)
            guard settings.enabled else { status = .init(state: .disabled); return status }
            let seed = try NativeMCPSettingsStore.signingSecret(expected: settings, db: db, store: secretStore)
            let secret = Self.derivedSecret(seed, purpose: "document-storage")
            let cookieSecret = Self.derivedSecret(seed, purpose: "better-auth-cookie")
            try Task.checkCancellation()
            let catalog = try NativeMCPInputCatalog(data: Data(contentsOf: catalogURL))
            let signer = try NativeMCPDocumentLocalSigner(appURL: settings.origin, secret: secret, clock: clock)
            let storage = try NativeMCPDocumentStorage.local(publicURL: settings.origin, bucket: settings.bucket, appURL: settings.origin, secret: secret, clock: clock)
            let objectStore = try NativeMCPDocumentObjectStore(db: db, bucket: settings.bucket, signer: signer, activateForDocuments: false)
            let documentHTTP = NativeMCPDocumentHTTP(store: objectStore)
            let wake = wakeJobs, db = self.db
            let original = NativeMCPRegistry.makeHandlers(documentStorage: storage, enrichmentStore: enrichmentStore,
                enrichmentEnvironment: enrichmentEnvironment, authorizeUserDirectory: authorizeUserDirectory(cookieSecret), clock: clock)
            // A source handler can commit and then fail (for example presign).
            // Wake after it exits on either path, never while its DB is locked.
            let handlers = original.mapValues { handler -> NativeMCPRequestRouter.Handler in
                { session, input in
                    try NativeMCPSettingsStore.requireCurrent(settings, db: db)
                    do { let value = try await handler(session, input); await wake(); return value }
                    catch { await wake(); throw error }
                }
            }
            let router = try NativeMCPRequestRouter(catalog: catalog, db: db, handlers: handlers, requireFull: true, clock: clock)
            let listener = try NativeMCPHTTPServer(configuration: .init(port: UInt16(settings.port), maximumConnections: settings.maximumConnections), bodyReceiver: { request in
                guard (try? NativeMCPSettingsStore.requireCurrent(settings, db: db)) != nil else { throw NativeMCPHTTPParseError(status: 503) }
                guard let receiver = try documentHTTP.bodyReceiver(request) else { return nil }
                return .init(maximumBytes: receiver.maximumBytes, append: {
                    try NativeMCPSettingsStore.requireCurrent(settings, db: db); try receiver.append($0)
                }, complete: {
                    try NativeMCPSettingsStore.requireCurrent(settings, db: db)
                    do { let value = try await receiver.finish(); await wake(); return value }
                    catch { await wake(); throw error }
                }, discard: { _ = receiver })
            }) { request in
                guard (try? NativeMCPSettingsStore.requireCurrent(settings, db: db)) != nil else { return .init(status: 503) }
                if let response = documentHTTP.handle(request) { return response }
                return await router.handle(request)
            }
            candidate = listener; server = listener
            _ = try await listener.start()
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            try NativeMCPSettingsStore.requireCurrent(settings, db: db)
            status = .init(state: .running, endpoint: settings.endpoint)
            _ = try? NativeMCPSettingsStore.cleanup(db: db, secretStore: secretStore, now: clock())
            await wake()
            try Task.checkCancellation()
            guard generation == ticket else { throw CancellationError() }
            return await snapshot()
        } catch {
            if let candidate { await candidate.stop() }
            if generation == ticket {
                server = nil
                if error is CancellationError { status = .init(state: .stopped) }
                else { status = .init(state: .failed, message: Self.message(error)) }
            }
            throw error
        }
    }
    func stop() async {
        let ticket = UUID(); generation = ticket
        guard let current = server else { status = .init(state: .stopped); return }
        status = .init(state: .stopping)
        await current.stop()
        if generation == ticket { server = nil; status = .init(state: .stopped) }
    }
    @discardableResult func restart() async throws -> Snapshot { await stop(); try Task.checkCancellation(); return try await start() }
    private static func message(_ error: Error) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE { return "指定したポートは別のアプリが使用しています。ポート番号を変更してください。" }
        if let settings = error as? NativeMCPSettingsError { return settings.localizedDescription }
        return "MCP サーバーを起動できません。設定とポート番号を確認してください。"
    }
}
