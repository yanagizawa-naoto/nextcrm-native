import Foundation

/// Candidate owner for all five original CRM automations. These runners only
/// commit local effects and notification intents. Actual mail delivery remains
/// owned/held separately by CRMTaskMailWorker and NativeCRMSweepMailWorker.
@MainActor final class NativeCRMAutomationRuntime {
    /// Synchronous SQLite steps execute on this actor, not the UI executor.
    /// Awaiting its call propagates cancellation without an unowned detached job.
    private actor Worker {
        let db: NativeDatabase, environment: NativeCRMRenewalJobs.Environment, clock: () -> Date
        init(db: NativeDatabase, environment: NativeCRMRenewalJobs.Environment, clock: @escaping () -> Date) { self.db = db; self.environment = environment; self.clock = clock }
        func stage() throws -> Bool { try NativeCRMStageJobs.runNext(db: db, clock: clock) }
        func renewal() throws -> Bool { try NativeCRMRenewalJobs.runNext(db: db, environment: environment, clock: clock) }
        func sweep() throws -> Bool { try NativeCRMSweepJobs.runNext(db: db, clock: clock) }
    }
    private let db: NativeDatabase, clock: () -> Date, runners: [InvoiceJobRunner]
    private var scan: Task<Void, Never>?, scanID: UUID?, timer: DispatchWorkItem?, timerID: UUID?
    private var generation = UUID(), again = false
    private(set) var isStopped = false
    private(set) var nextScan: Date?
    var isScanning: Bool { scan != nil }
    var isRunning: Bool { runners.contains { $0.isRunning } }
    var onError: ((Error) -> Void)?
    init(db: NativeDatabase, environment: NativeCRMRenewalJobs.Environment, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.clock = clock
        let worker = Worker(db: db, environment: environment, clock: clock)
        runners = [
            InvoiceJobRunner(db: db, events: NativeCRMStageJobs.events, runNext: { try await worker.stage() }),
            InvoiceJobRunner(db: db, events: NativeCRMRenewalJobs.events, runNext: { try await worker.renewal() }),
            InvoiceJobRunner(db: db, events: NativeCRMSweepJobs.events, runNext: { try await worker.sweep() }),
        ]
        for runner in runners { runner.onError = { [weak self] error in guard let self, !self.isStopped else { return }; self.onError?(error) } }
    }
    deinit { scan?.cancel(); timer?.cancel() }
    func resume() {
        guard !isStopped else { return }; let epoch = generation
        timer?.cancel(); timer = nil; timerID = nil; nextScan = nil
        for runner in runners { guard !isStopped, generation == epoch else { return }; runner.kick() }
        guard !isStopped, generation == epoch else { return }
        if scan != nil { again = true; return }; again = false
        let db = db, now = clock(), ticket = UUID(); scanID = ticket
        scan = Task.detached { [weak self] in
            let result = Result { () throws -> Date in
                try Task.checkCancellation()
                return try db.transaction {
                    let renewal = try NativeCRMRenewalJobs.enqueueDue(db: db, now: now)
                    try Task.checkCancellation()
                    let sweep = try NativeCRMSweepJobs.enqueueDue(db: db, now: now)
                    try Task.checkCancellation()
                    let retention = try NativeCRMSweepSnapshotRetention.runPage(db: db)
                    try Task.checkCancellation()
                    let next = min(renewal, sweep)
                    // Reuse this one scheduler wake to finish a finite sweep of
                    // at most100 metadata keys per transaction. At end-of-pass,
                    // held keys wait for an ordinary future scan/resume.
                    return retention.hasMore ? min(next, now.addingTimeInterval(1)) : next
                }
            }
            await self?.finished(result, epoch: epoch, ticket: ticket)
        }
    }
    private func finished(_ result: Result<Date, Error>, epoch: UUID, ticket: UUID) {
        guard scanID == ticket else { return }; scan = nil; scanID = nil
        guard !isStopped, generation == epoch else { return }
        for runner in runners { guard !isStopped, generation == epoch else { return }; runner.kick() }
        guard !isStopped, generation == epoch else { return }
        if again { resume(); return }
        let due: Date
        switch result {
        case let .success(date): due = date
        case let .failure(error): onError?(error); due = clock().addingTimeInterval(30)
        }
        guard !isStopped, generation == epoch, scan == nil else { return }
        nextScan = due; let timerTicket = UUID(); timerID = timerTicket
        let work = DispatchWorkItem { [weak self] in guard let self, !self.isStopped, self.generation == epoch, self.timerID == timerTicket else { return }; self.resume() }
        timer = work; DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, due.timeIntervalSince(clock())), execute: work)
    }
    /// All producer/runner admission is closed before awaiting any owned work.
    /// Calling resume or receiving a commit notification cannot undo this stop.
    func stop() {
        isStopped = true; generation = UUID(); again = false
        scan?.cancel(); timer?.cancel(); timer = nil; timerID = nil; nextScan = nil
        for runner in runners { runner.stop() }
    }
    func stopAndDrain() async {
        stop(); let owned = scan
        await owned?.value
        for runner in runners { await runner.stopAndDrain() }
    }
}
