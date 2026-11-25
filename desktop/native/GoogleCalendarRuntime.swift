import Foundation

enum GoogleCalendarSchedule {
    static let interval: TimeInterval = 15*60
    /// The server version scans active connections every 15 minutes. Keep the
    /// same cadence while the Mac app is open, reading at most 100 rows at once.
    static func enqueueDue(db: NativeDatabase, now: Date = Date(), interval: TimeInterval = interval) throws -> Int {
        var offset = 0, eligible = 0
        while true {
            try Task.checkCancellation()
            let rows = try db.page("CalendarConnection",fields:["userId","lastSyncedAt","syncToken"],equal:["provider":.text("google"),"isActive":.integer(1)],offset:offset,sort:"id").rows
            for row in rows {
                try Task.checkCancellation()
                guard let user = try db.get("Users",key:["id":row["userId"]]) else { continue }
                let service = CRMService(db:db,identity:.init(id:user["id"].string,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
                guard (try? service.authenticated()) != nil else { continue }; eligible += 1
                let last = try? NativeCalendarEvents.date(row["lastSyncedAt"].string)
                if row["syncToken"] == .null || last == nil || last! > now || now.timeIntervalSince(last!) >= interval {
                    do { _ = try service.requestGoogleCalendarSync(row,now:now) }
                    catch NativeDBError.conflict { continue }
                }
            }
            if rows.count < 100 { return eligible }; offset += rows.count
        }
    }
}

/// Main-queue lifecycle owner. No scan timer is retained when no authorized
/// active connection exists. Job retries use the existing durable job runner.
final class GoogleCalendarRuntime {
    let store: GoogleCalendarSecretStore
    private let db: NativeDatabase, worker: GoogleCalendarSyncWorker, runner: InvoiceJobRunner
    private let pushRunner: InvoiceJobRunner
    private let clock: () -> Date, interval: TimeInterval
    private let enqueueDue:(NativeDatabase,Date,TimeInterval) throws -> Int
    private var scan: Task<Void,Never>?, timer: DispatchWorkItem?
    private var generation = UUID(), scanID:UUID?, timerID:UUID?
    private var stopped = false, again = false
    private(set) var nextScan: Date?
    var isScanning: Bool { scan != nil }
    var isRunning: Bool { runner.isRunning || pushRunner.isRunning }
    var isStopped: Bool { stopped }
    var onError: ((Error) -> Void)?
    init(db: NativeDatabase,store: GoogleCalendarSecretStore? = nil,request: GoogleCalendarOAuth.Request? = nil,clock: @escaping () -> Date = Date.init,interval: TimeInterval = GoogleCalendarSchedule.interval) {
        self.db = db; self.clock = clock; self.interval = interval; enqueueDue = GoogleCalendarSchedule.enqueueDue
        let store = store ?? KeychainGoogleCalendarSecrets(databaseURL:db.url); self.store = store
        let worker = GoogleCalendarSyncWorker(db:db,store:store,request:request,clock:clock); self.worker = worker
        runner = InvoiceJobRunner(db:db,events:[GoogleCalendarSyncJobs.event],runNext:{try await worker.runNext()})
        let push = GoogleCalendarPushWorker(db:db,store:store,request:request,clock:clock)
        pushRunner = InvoiceJobRunner(db:db,events:[GoogleCalendarOutbound.event],nextDate:{try db.nextCalendarOutboundJobDate(now:clock())},runNext:{try await push.runNext()})
        connectErrors()
    }
    #if RUNTIME_DRAIN_TESTS
    init(db:NativeDatabase,store:GoogleCalendarSecretStore,runner:InvoiceJobRunner,pushRunner:InvoiceJobRunner,clock:@escaping () -> Date,interval:TimeInterval,enqueueDue:@escaping (NativeDatabase,Date,TimeInterval) throws -> Int) {
        self.db = db; self.store = store; self.runner = runner; self.pushRunner = pushRunner; self.clock = clock; self.interval = interval; self.enqueueDue = enqueueDue
        worker = GoogleCalendarSyncWorker(db:db,store:store,request:{_ in throw NativeDBError.conflict},clock:clock); connectErrors()
    }
    #endif
    private func connectErrors() {
        runner.onError = { [weak self] error in guard let self, !self.stopped else { return }; self.onError?(error) }
        pushRunner.onError = { [weak self] error in guard let self, !self.stopped else { return }; self.onError?(error) }
    }
    deinit { scan?.cancel(); timer?.cancel() }
    func resume() {
        dispatchPrecondition(condition:.onQueue(.main)); guard !stopped else { return }
        let epoch = generation
        timer?.cancel(); timer = nil; timerID = nil; nextScan = nil; runner.kick()
        guard !stopped, generation == epoch else { return }; pushRunner.kick()
        guard !stopped, generation == epoch else { return }
        if scan != nil { again = true; return }; again = false
        let db = db, now = clock(), interval = interval, enqueueDue = enqueueDue, ticket = UUID()
        guard !stopped, generation == epoch, scan == nil else { return }; scanID = ticket
        scan = Task.detached { [weak self] in
            let result = Result { try Task.checkCancellation(); return try enqueueDue(db,now,interval) }
            await MainActor.run { [weak self] in self?.finished(result,epoch:epoch,ticket:ticket) }
        }
    }
    private func finished(_ result: Result<Int,Error>,epoch:UUID,ticket:UUID) {
        guard scanID == ticket else { return }; scan = nil; scanID = nil
        guard !stopped, generation == epoch else { return }
        runner.kick(); guard !stopped, generation == epoch, scan == nil else { return }
        if again { resume(); return }
        var active = true
        switch result { case let .success(count): active = count > 0; case let .failure(error):onError?(error) }
        guard active, !stopped, generation == epoch, scan == nil else { return }
        let next = clock().addingTimeInterval(interval), ticket = UUID()
        guard !stopped, generation == epoch, scan == nil else { return }; nextScan = next; timerID = ticket
        let work = DispatchWorkItem { [weak self] in guard let self, !self.stopped, self.generation == epoch, self.timerID == ticket else { return }; self.resume() }; timer = work
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0.1,interval),execute:work)
    }
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main)); stopped = true; generation = UUID(); again = false
        scan?.cancel(); timer?.cancel(); timer = nil; timerID = nil; nextScan = nil; runner.stop(); pushRunner.stop()
    }
    /// Both inbound reads and outbound mutations must settle before releasing the database.
    @MainActor func stopAndDrain() async {
        stop(); let current = scan
        await current?.value
        await runner.stopAndDrain(); await pushRunner.stopAndDrain()
    }
}
