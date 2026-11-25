import Foundation

/// Separate serial CRM and document queues keep long documents from blocking
/// routine changes. Both schedulers are timer-free at rest, with no local model.
final class NativeEmbeddingRuntime {
    private let runner: InvoiceJobRunner, documents: InvoiceJobRunner
    private var observer: NSObjectProtocol?
    private var cancellationObserver: NSObjectProtocol?
    private let controls=NativeRuntimeControlTasks()
    private var stopped=false
    var onError: ((Error) -> Void)? { get { runner.onError } set { runner.onError = newValue; documents.onError = newValue } }
    var isRunning: Bool { runner.isRunning || documents.isRunning || controls.pendingCount>0 }
    var isStopped:Bool {stopped}
    var pendingControlCount:Int {controls.pendingCount}
    var nextWake: Date? { [runner.nextWake, documents.nextWake].compactMap { $0 }.min() }
    init(db: NativeDatabase, store: NativeAISecretStore, environment: NativeAIEnvironment = NativeAIEnvironment(), generate: @escaping NativeEmbeddingWorker.Generate = { try await NativeEmbeddingClient(apiKey: $1).generate($0, allowWhitespace: true) },
         summarize: @escaping NativeDocumentAIWorker.Summary = { try await NativeOpenAIChatClient(apiKey: $1).summary(excerpt: $0) },
         classify: @escaping NativeDocumentAIWorker.Classify = { try await NativeOpenAIChatClient(apiKey: $3).classification(name: $0, summary: $1, excerpt: $2) }) {
        let crmEvents = NativeEmbeddingJobs.events.filter { $0 != NativeDatabase.documentAIEvent }, docEvents = [NativeDatabase.documentAIEvent]
        let worker = NativeEmbeddingWorker(db: db, store: store, environment: environment, generate: generate, summarize: summarize, classify: classify, events: crmEvents)
        let documentWorker = NativeEmbeddingWorker(db: db, store: store, environment: environment, generate: generate, summarize: summarize, classify: classify, events: docEvents)
        runner = InvoiceJobRunner(db: db, events: crmEvents, runNext: { try await worker.runNext() })
        documents = InvoiceJobRunner(db: db, events: docEvents, runNext: { try await documentWorker.runNext() })
        let path=db.url.path
        observer = NotificationCenter.default.addObserver(forName: NativeAIKeys.didChange, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["database"] as? String == path else { return }; self?.resume()
        }
        cancellationObserver = NotificationCenter.default.addObserver(forName: NativeDatabase.aiProgress, object: nil, queue: .main) { [weak self,weak documentWorker] note in
            guard let self,!self.stopped,note.userInfo?["database"] as? String == path,let id=note.userInfo?["cancelledJob"] as? String,let documentWorker else{return}
            self.controls.performControl(key:id){await documentWorker.cancelDocument(id)}
        }
    }
    deinit { for token in [observer, cancellationObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) } }
    func resume() {dispatchPrecondition(condition:.onQueue(.main));guard !stopped else{return};runner.kick();documents.kick()}
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main));stopped=true;controls.close()
        for token in [observer,cancellationObserver].compactMap({$0}){NotificationCenter.default.removeObserver(token)}
        observer=nil;cancellationObserver=nil;runner.stop();documents.stop()
    }
    @MainActor func stopAndDrain() async {
        stop();await runner.stopAndDrain();await documents.stopAndDrain();await controls.closeAndDrain()
    }
}
