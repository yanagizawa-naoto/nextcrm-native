import Foundation

enum NativeTargetEnrichmentProvider {
    static func review(_ context: NativeTargetEnrichmentContext, _ openai: String, _ firecrawl: String,
                       _ report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeEnrichmentOutput {
        try await makeReview()(context, openai, firecrawl, report)
    }
    static func makeReview(request: @escaping NativeEnrichmentHTTP.Request = NativeEnrichmentHTTP.network) -> NativeTargetEnrichmentWorker.Review {
        { context, openai, firecrawl, report in
            try await NativeEnrichmentOrchestrator(openaiKey: openai, firecrawlKey: firecrawl, request: request)
                .run(email: context.email, companyName: context.company, website: context.website, personName: context.name,
                     fields: NativeTargetEnrichment.reviewFields(context.fields), report: report)
        }
    }
    static func makeAgent(resources: URL?, transport: NativeE2BHTTP.Transport? = nil) -> NativeTargetEnrichmentWorker.Agent {
        { context, anthropic, connection, report in
            guard let file = resources?.appendingPathComponent("TargetEnrichmentAgent.mjs"),
                  let metadata = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), metadata.isRegularFile == true,
                  let size = metadata.fileSize, size > 0, size <= 256 * 1024,
                  let script = try? String(contentsOf: file, encoding: .utf8) else { throw NativeAIError(message: "情報取得に必要なアプリの構成ファイルを読み込めません。") }
            return try await NativeE2BClient(apiKey: connection.key, configuration: connection.configuration, transport: transport).enrich(context: context, anthropic: anthropic, template: connection.template, script: script, report: report)
        }
    }
    static func agent(_ context: NativeTargetEnrichmentContext, _ anthropic: String, _ connection: NativeE2BConnection,
                      _ report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeTargetAgentOutput {
        try await makeAgent(resources: Bundle.main.resourceURL)(context, anthropic, connection, report)
    }
}

/// One target or target contact at a time; idle queues have no polling timer.
final class NativeTargetEnrichmentRuntime {
    private let runner: InvoiceJobRunner
    private var keysObserver: NSObjectProtocol?, cancellationObserver: NSObjectProtocol?
    private let controls=NativeRuntimeControlTasks()
    private var stopped=false
    var onError: ((Error) -> Void)? { get { runner.onError } set { runner.onError = newValue } }
    var isRunning: Bool { runner.isRunning || controls.pendingCount>0 }
    var isStopped:Bool {stopped}
    var pendingControlCount:Int {controls.pendingCount}
    var nextWake: Date? { runner.nextWake }
    init(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(),
         review: @escaping NativeTargetEnrichmentWorker.Review = NativeTargetEnrichmentProvider.review,
         agent: @escaping NativeTargetEnrichmentWorker.Agent = NativeTargetEnrichmentProvider.agent) {
        let worker = NativeTargetEnrichmentWorker(db: db, store: store, environment: environment, review: review, agent: agent)
        runner = InvoiceJobRunner(db: db, events: NativeTargetEnrichment.events, runNext: { try await worker.runNext() })
        let path=db.url.path
        keysObserver = NotificationCenter.default.addObserver(forName: NativeAIKeys.didChange, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["database"] as? String == path else { return }; self?.resume()
        }
        cancellationObserver = NotificationCenter.default.addObserver(forName: NativeDatabase.aiProgress, object: nil, queue: .main) { [weak self,weak worker] note in
            guard let self,!self.stopped,note.userInfo?["database"] as? String == path,let id=note.userInfo?["cancelledJob"] as? String,let worker else{return}
            self.controls.performControl(key:id){await worker.cancel(id)}
        }
    }
    deinit { for observer in [keysObserver, cancellationObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) } }
    func resume() {dispatchPrecondition(condition:.onQueue(.main));guard !stopped else{return};runner.kick()}
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main));stopped=true;controls.close()
        for observer in [keysObserver,cancellationObserver].compactMap({$0}){NotificationCenter.default.removeObserver(observer)}
        keysObserver=nil;cancellationObserver=nil;runner.stop()
    }
    @MainActor func stopAndDrain() async {stop();await runner.stopAndDrain();await controls.closeAndDrain()}
}

extension NativeAIQAServices {
    static func targetEnvironment(_ base: NativeAIEnvironment) -> NativeAIEnvironment {
        .init(lookup: { $0 == "E2B_API_KEY" ? "qa-e2b" : base.lookup($0) })
    }
    static func targetReview(_ context: NativeTargetEnrichmentContext, _ openai: String, _ firecrawl: String,
                             _ report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeEnrichmentOutput {
        try await enrich(context.email ?? "", context.fields, openai, firecrawl, report)
    }
    static func targetAgent(_ context: NativeTargetEnrichmentContext, _ anthropic: String, _ connection: NativeE2BConnection,
                            _ report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeTargetAgentOutput {
        try Task.checkCancellation(); try await report(.init(message: "検証用の企業・担当者情報を取得しています。", kind: .agent))
        if anthropic.hasPrefix("qa-reject") { throw NativeAIError(message: "検証用APIキーの拒否を再現しました。") }
        try await Task.sleep(nanoseconds: 150_000_000)
        var values: [String: String?] = [:]
        for field in context.fields { values[field.name] = field.name == "company_website" ? "https://qa.example.invalid" : "検証用の取得値" }
        let person = NativeTargetAgentOutput.Contact(name: context.mode == .contact ? context.name : "山田 太郎（検証用）", email: context.mode == .contact ? context.email : "target-contact@qa.example.invalid", title: "営業部長（検証用）", linkedinUrl: "https://qa.example.invalid/profile", phone: "03-0000-0000", source: "検証用データ")
        return .init(target: values, contacts: [person], confidence: Dictionary(uniqueKeysWithValues: context.fields.map { ($0.name, 0.9) }))
    }
}
