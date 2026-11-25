import Foundation

enum NativeMailSchedule {
    static let interval: TimeInterval = 15*60
    static func enqueueDue(db:NativeDatabase,now:Date = Date(),interval:TimeInterval = interval) throws -> Int {
        var offset = 0, eligible = 0
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
        while true {
            try Task.checkCancellation()
            let rows = try db.page("EmailAccount",fields:["userId","lastSyncedAt"],equal:["isActive":.integer(1)],offset:offset,sort:"id").rows
            for row in rows {
                try Task.checkCancellation()
                guard let user = try db.get("Users",key:["id":row["userId"]]) else { continue }
                let service = CRMService(db:db,identity:.init(id:user["id"].string,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
                guard (try? service.authenticated()) != nil else { continue }; eligible += 1
                let last = plain.date(from:row["lastSyncedAt"].string) ?? fractional.date(from:row["lastSyncedAt"].string)
                if last == nil || last! > now || now.timeIntervalSince(last!) >= interval {
                    if let job = try service.mailSyncJob(row["id"].string), ["pending","running","retry"].contains(job.status) { continue }
                    do { _ = try service.requestMailSync(row,now:now) } catch NativeDBError.conflict { continue }
                }
            }
            if rows.count < 100 { return eligible }; offset += rows.count
        }
    }
}

/// App lifecycle owns the runtime. The existing wake-only runner processes
/// persisted work; a single periodic scan is retained only for active accounts.
final class NativeMailRuntime {
    let store: NativeMailSecretStore
    private let db:NativeDatabase, runners:[InvoiceJobRunner], clock:() -> Date, interval:TimeInterval
    private let enqueueDue:(NativeDatabase,Date,TimeInterval) throws -> Int
    private let recoverTemporary:() async throws -> Void
    private var scan:Task<Void,Never>?, timer:DispatchWorkItem?
    private var generation = UUID(), scanID:UUID?, timerID:UUID?
    private var stopped = false, again = false
    private(set) var nextScan:Date?
    var isScanning:Bool { scan != nil }
    var isRunning:Bool { runners.contains{$0.isRunning} }
    var isStopped:Bool { stopped }
    var onError:((Error) -> Void)?
    init(db:NativeDatabase,store:NativeMailSecretStore? = nil,makeClient:@escaping NativeMailSyncWorker.Factory = { NativeMailClient(endpoint:$0.imap,username:$0.username,password:$1.password) },send:NativeMailSendWorker.Send? = nil,clock:@escaping () -> Date = Date.init,interval:TimeInterval = NativeMailSchedule.interval,recoverTemporary:@escaping () async throws -> Void = { try await NativeMailTemporaryFiles.recover() }) {
        self.db = db; self.clock = clock; self.interval = interval; enqueueDue = NativeMailSchedule.enqueueDue; self.recoverTemporary = recoverTemporary
        let secrets = store ?? KeychainNativeMailSecrets(databaseURL:db.url); self.store = secrets
        let sync = NativeMailSyncWorker(db:db,store:secrets,makeClient:makeClient,clock:clock)
        let content = NativeMailContentWorker(db:db,store:secrets,makeClient:makeClient,clock:clock)
        let delivery: NativeMailSendWorker
        if let send { delivery = NativeMailSendWorker(db:db,store:secrets,send:send,clock:clock) }
        else { delivery = NativeMailSendWorker(db:db,store:secrets,clock:clock) }
        runners = [
            InvoiceJobRunner(db:db,events:[NativeMailJobs.sync],runNext:{try await sync.runNext()}),
            InvoiceJobRunner(db:db,events:[NativeMailJobs.link,NativeMailJobs.body],runNext:{try await content.runNext()}),
            InvoiceJobRunner(db:db,events:[NativeMailDelivery.event],runNext:{try await delivery.runNext()})
        ]
        connectErrors()
    }
    #if RUNTIME_DRAIN_TESTS
    init(db:NativeDatabase,store:NativeMailSecretStore,runners:[InvoiceJobRunner],clock:@escaping () -> Date,interval:TimeInterval,enqueueDue:@escaping (NativeDatabase,Date,TimeInterval) throws -> Int,recoverTemporary:@escaping () async throws -> Void = {}) {
        self.db = db; self.store = store; self.runners = runners; self.clock = clock; self.interval = interval; self.enqueueDue = enqueueDue; self.recoverTemporary = recoverTemporary; connectErrors()
    }
    #endif
    private func connectErrors() {
        for runner in runners { runner.onError = { [weak self] error in guard let self, !self.stopped else { return }; self.onError?(error) } }
    }
    deinit { scan?.cancel(); timer?.cancel() }
    func resume() {
        dispatchPrecondition(condition:.onQueue(.main)); guard !stopped else { return }
        let epoch = generation
        timer?.cancel(); timer = nil; timerID = nil; nextScan = nil
        for runner in runners { runner.kick(); guard !stopped, generation == epoch else { return } }
        if scan != nil { again = true; return }; again = false
        let db = db, now = clock(), interval = interval, enqueueDue = enqueueDue, recoverTemporary = recoverTemporary, ticket = UUID()
        guard !stopped, generation == epoch, scan == nil else { return }; scanID = ticket
        scan = Task.detached { [weak self] in
            let result = Result { try Task.checkCancellation(); return try enqueueDue(db,now,interval) }
            // Newly queued mail can run while bounded cleanup yields between pages.
            await MainActor.run { [weak self] in
                guard let self, !self.stopped, self.generation == epoch, self.scanID == ticket else { return }
                for runner in self.runners { runner.kick(); if self.stopped || self.generation != epoch { return } }
            }
            do { try Task.checkCancellation(); try await recoverTemporary() }
            catch is CancellationError { /* Stop still joins this scan's actual completion. */ }
            catch {
                await MainActor.run { [weak self] in
                    guard let self, !self.stopped, self.generation == epoch, self.scanID == ticket else { return }
                    self.onError?(error)
                }
            }
            await MainActor.run { [weak self] in self?.finished(result,epoch:epoch,ticket:ticket) }
        }
    }
    private func finished(_ result:Result<Int,Error>,epoch:UUID,ticket:UUID) {
        guard scanID == ticket else { return }; scan = nil; scanID = nil
        guard !stopped, generation == epoch else { return }
        for runner in runners { runner.kick(); guard !stopped, generation == epoch, scan == nil else { return } }
        if again { resume(); return }
        var eligible = true
        switch result { case let .success(count):eligible = count > 0; case let .failure(error):onError?(error) }
        guard eligible, !stopped, generation == epoch, scan == nil else { return }
        let next = clock().addingTimeInterval(interval), ticket = UUID()
        guard !stopped, generation == epoch, scan == nil else { return }; nextScan = next; timerID = ticket
        let work = DispatchWorkItem { [weak self] in guard let self, !self.stopped, self.generation == epoch, self.timerID == ticket else { return }; self.resume() }; timer = work
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0.1,interval),execute:work)
    }
    func stop() {
        dispatchPrecondition(condition:.onQueue(.main)); stopped = true; generation = UUID(); again = false
        scan?.cancel(); timer?.cancel(); timer = nil; timerID = nil; nextScan = nil; runners.forEach{$0.stop()}
    }
    /// Terminal for this instance. The host must reconstruct a runtime to resume.
    /// Cancellation requests do not replace awaiting actual worker/scan completion.
    @MainActor func stopAndDrain() async {
        stop(); let current = scan
        await current?.value
        for runner in runners { await runner.stopAndDrain() }
    }
}
