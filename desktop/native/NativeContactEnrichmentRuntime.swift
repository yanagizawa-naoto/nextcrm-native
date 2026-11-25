import Foundation

/// One contact at a time. No timer or provider process remains while idle.
final class NativeContactEnrichmentRuntime {
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
         enrich: @escaping NativeContactEnrichmentWorker.Enrich = NativeEnrichmentOrchestrator.contactProvider) {
        let worker = NativeContactEnrichmentWorker(db: db, store: store, environment: environment, enrich: enrich)
        runner = InvoiceJobRunner(db: db, events: NativeContactEnrichment.events, runNext: { try await worker.runNext() })
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
    /// Selected only by CRMApp after its existing isolated QA-root validation.
    static func enrich(_ email: String, _ fields: [NativeEnrichmentField], _ openai: String, _ firecrawl: String,
                       _ report: @escaping NativeContactEnrichmentWorker.Report) async throws -> NativeEnrichmentOutput {
        try Task.checkCancellation()
        if openai.hasPrefix("qa-reject") || firecrawl.hasPrefix("qa-reject") { throw NativeAIError(message: "検証用APIキーの拒否を再現しました。") }
        try await report(.init(message: "検証用の会社情報を取得しています。", kind: .agent))
        try await Task.sleep(nanoseconds: 150_000_000)
        let presets = ["position": "営業部長（検証用）", "website": "https://qa.example.invalid", "description": "検証用の会社説明です。", "office_phone": "03-0000-0000", "mobile_phone": "090-0000-0000"]
        let results = fields.reduce(into: [String: NativeEnrichmentResult]()) { values, field in
            let value: NativeEnrichmentValue
            switch field.type { case .number: value = .number(150); case .boolean: value = .boolean(true); case .array: value = .array(["検証用の値"])
            case .string: value = .string(presets[field.name] ?? (field.name.hasPrefix("social_") ? "https://qa.example.invalid/profile" : "検証用の値")) }
            values[field.name] = .init(field: field.name, value: value, confidence: 0.9, source: "検証用データ", sourceContext: [.init(url: "https://qa.example.invalid", snippet: "検証用の根拠です。外部サービスには接続していません。")])
        }
        try await report(.init(message: "検証用の情報補完が完了しました。", kind: .success)); return .init(enrichments: results, status: .completed)
    }
}
