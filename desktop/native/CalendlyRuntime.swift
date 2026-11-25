import Foundation

final class CalendlyRuntime {
    let store: CalendlySecretStore
    private let db: NativeDatabase, runner: InvoiceJobRunner, interval: TimeInterval, clock: () -> Date
    private let enqueueDue:(NativeDatabase,Date,TimeInterval,Bool) throws -> Bool
    private var scan: Task<Void,Never>?, timer: DispatchWorkItem?, observer: NSObjectProtocol?
    private var generation = UUID(), scanID:UUID?, timerID:UUID?
    private var stopped = false, again = false, pendingForce = false
    private(set) var nextScan: Date?
    var isScanning: Bool { scan != nil }
    var isRunning: Bool { runner.isRunning }
    var isStopped: Bool { stopped }
    var onError: ((Error) -> Void)?
    init(db: NativeDatabase,store: CalendlySecretStore? = nil,allowLoopbackHTTP: Bool = false,apiRequest: @escaping CalendlyAPIClient.Request = CalendlyRelayClient.network,relayRequest: CalendlyRelayClient.Request? = nil,clock: @escaping () -> Date = Date.init,interval: TimeInterval = CalendlyJobs.interval) {
        self.db = db; self.clock = clock; self.interval = interval; enqueueDue = CalendlyJobs.enqueueDue
        let store = store ?? KeychainCalendlySecrets(databaseURL:db.url); self.store = store
        let worker = CalendlyJobWorker(db:db,store:store,allowLoopbackHTTP:allowLoopbackHTTP,apiRequest:apiRequest,relayRequest:relayRequest,clock:clock)
        runner = InvoiceJobRunner(db:db,events:[CalendlyJobs.subscription,CalendlyJobs.sync],runNext:{try await worker.runNext()})
        connectCallbacks()
    }
    #if RUNTIME_DRAIN_TESTS
    init(db:NativeDatabase,store:CalendlySecretStore,runner:InvoiceJobRunner,clock:@escaping () -> Date,interval:TimeInterval,enqueueDue:@escaping (NativeDatabase,Date,TimeInterval,Bool) throws -> Bool) {
        self.db = db; self.store = store; self.runner = runner; self.clock = clock; self.interval = interval; self.enqueueDue = enqueueDue; connectCallbacks()
    }
    #endif
    private func connectCallbacks() {
        runner.onError = { [weak self] error in guard let self, !self.stopped else { return }; self.onError?(error) }
        let path = db.url.path, epoch = generation
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, !self.stopped, self.generation == epoch, note.userInfo?["database"] as? String == path else { return }; self.resume(forceSync:false)
        }
    }
    deinit { scan?.cancel(); timer?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func resume(forceSync: Bool = true) {
        dispatchPrecondition(condition:.onQueue(.main)); guard !stopped else { return }
        let epoch = generation
        timer?.cancel(); timer = nil; timerID = nil; nextScan = nil; runner.kick()
        guard !stopped, generation == epoch else { return }
        pendingForce = pendingForce || forceSync
        if scan != nil { again = true; return }; again = false
        let db = db, now = clock(), interval = interval, force = pendingForce, enqueueDue = enqueueDue, ticket = UUID(); pendingForce = false
        guard !stopped, generation == epoch, scan == nil else { return }; scanID = ticket
        scan = Task.detached { [weak self] in
            let result = Result { try Task.checkCancellation(); return try enqueueDue(db,now,interval,force) }
            await MainActor.run { [weak self] in self?.finished(result,epoch:epoch,ticket:ticket) }
        }
    }
    private func finished(_ result: Result<Bool,Error>,epoch:UUID,ticket:UUID) {
        guard scanID == ticket else { return }; scan = nil; scanID = nil
        guard !stopped, generation == epoch else { return }; runner.kick()
        guard !stopped, generation == epoch, scan == nil else { return }
        if again { resume(forceSync:false); return }
        let active: Bool
        switch result { case let .success(value):active = value; case let .failure(error):onError?(error); active = false }
        guard active, !stopped, generation == epoch, scan == nil else { return }
        let next = clock().addingTimeInterval(interval), ticket = UUID()
        guard !stopped, generation == epoch, scan == nil else { return }; nextScan = next; timerID = ticket
        let work = DispatchWorkItem{[weak self] in guard let self, !self.stopped, self.generation == epoch, self.timerID == ticket else { return }; self.resume(forceSync:false)}
        timer = work; DispatchQueue.main.asyncAfter(deadline:.now()+max(0.1,interval),execute:work)
    }
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main)); stopped = true; generation = UUID(); again = false; pendingForce = false
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        scan?.cancel(); timer?.cancel(); timer = nil; timerID = nil; nextScan = nil; runner.stop()
    }
    /// Does not unsubscribe remotely or discard relay cursors/uncertain registration receipts.
    @MainActor func stopAndDrain() async {
        stop(); let current = scan
        await current?.value; await runner.stopAndDrain()
    }
}
