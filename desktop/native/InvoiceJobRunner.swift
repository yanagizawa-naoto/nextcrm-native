import Foundation

/// Owned by the application, with all scheduling state on the main queue.
/// At rest there is no polling timer. A single wake is scheduled for the next
/// retry/expired lease, and new local jobs coalesce into a wake notification.
final class InvoiceJobRunner {
    static let didProcess = Notification.Name("NextCRMNativeInvoiceJobProcessed")
    private let db: NativeDatabase
    private let events: [String]
    private let runNext: () async throws -> Bool
    private let nextDate: () throws -> Date?
    private var observer: NSObjectProtocol?
    private var task: Task<Void,Never>?
    private var wake: DispatchWorkItem?
    private var again = false
    private var stopped = false
    private var generation = UUID(), taskID: UUID?
    var onError: ((Error) -> Void)?
    private(set) var nextWake: Date?
    var isRunning: Bool { task != nil }
    var isStopped: Bool { stopped }
    init(db: NativeDatabase, events: [String], nextDate: (() throws -> Date?)? = nil, runNext: @escaping () async throws -> Bool) {
        self.db = db; self.events = events; self.runNext = runNext; self.nextDate = nextDate ?? {try db.nextJobDate(events:events)}
        observe()
    }
    private func observe() {
        let epoch = generation
        observer = NotificationCenter.default.addObserver(forName:NativeDatabase.jobsDidChange,object:nil,queue:.main) { [weak self] note in
            guard let self, self.generation == epoch, !self.stopped, note.userInfo?["database"] as? String == self.db.url.path else { return }; self.kick()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; wake?.cancel(); task?.cancel() }
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main)); stopped = true; generation = UUID(); again = false
        wake?.cancel(); wake = nil; nextWake = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        task?.cancel()
    }
    /// Cancelling the caller does not abandon the drain. The current worker may
    /// ignore cancellation while finishing I/O; await its actual completion.
    /// The owner must fence new explicit restart requests during a root switch.
    @MainActor func stopAndDrain() async {
        stop(); let current = task
        await current?.value
    }
    /// Only this explicit operation can reopen a stopped runner. A later stop
    /// or restart wins; old completions never clear or schedule a newer task.
    @MainActor @discardableResult func restartAfterDrain() async -> Bool {
        stop(); let epoch = generation, current = task
        await current?.value
        guard generation == epoch, !Task.isCancelled, task == nil else { return false }
        stopped = false; observe(); kick(); return true
    }
    func kick() {
        dispatchPrecondition(condition:.onQueue(.main)); guard !stopped else { return }
        wake?.cancel(); wake = nil; nextWake = nil
        if task != nil { again = true; return }
        again = false
        let runNext = runNext; let path = db.url.path, epoch = generation, ticket = UUID()
        taskID = ticket
        task = Task { @MainActor [weak self] in
            var failure: Error?
            do {
                while !Task.isCancelled, self?.canRun(epoch, ticket) == true {
                    let worked = try await runNext()
                    guard !Task.isCancelled, self?.canRun(epoch, ticket) == true, worked else { break }
                    NotificationCenter.default.post(name:Self.didProcess,object:nil,userInfo:["database":path])
                }
            } catch { failure = error }
            self?.finished(error:failure,epoch:epoch,ticket:ticket)
        }
    }
    private func canRun(_ epoch: UUID, _ ticket: UUID) -> Bool { !stopped && generation == epoch && taskID == ticket }
    private func finished(error: Error?, epoch: UUID, ticket: UUID) {
        guard taskID == ticket else { return }
        task = nil; taskID = nil; guard !stopped, generation == epoch else { return }
        if let error {
            onError?(error)
            guard !stopped, generation == epoch, task == nil else { return }
            schedule(Date().addingTimeInterval(30)); return
        }
        if again { kick(); return }
        do { if let due = try nextDate() { schedule(due) } }
        catch { onError?(error); schedule(Date().addingTimeInterval(30)) }
    }
    private func schedule(_ date: Date) {
        guard !stopped, task == nil else { return }
        nextWake = date
        let epoch = generation
        let work = DispatchWorkItem { [weak self] in guard let self, self.generation == epoch, !self.stopped else { return }; self.kick() }; wake = work
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0.1,date.timeIntervalSinceNow),execute:work)
    }
}
