import Foundation

extension NativeCurrencyAdministration {
    @discardableResult func requestECBUpdate() throws -> String {
        try service.db.transaction {
            try requireAdmin()
            let setting = try settings()
            guard setting.enabled, let revision = setting.revision else { throw NativeDBError.message("ECBの自動更新を有効にしてから更新してください。") }
            return try service.db.enqueue(NativeCurrencyAdministrationJobs.event,
                                          payload: ["revision": String(revision), "actorID": service.identity.id], now: clock())
        }
    }
    func updateJobs(offset: Int = 0) throws -> [NativeJob] {
        try service.db.transaction { try requireAdmin(); return try service.db.jobs(events: [NativeCurrencyAdministrationJobs.event], offset: offset) }
    }
    func cancelUpdate(_ job: NativeJob) throws {
        try service.db.transaction {
            try requireAdmin()
            guard job.event == NativeCurrencyAdministrationJobs.event, try service.db.job(id: job.id) == job else { throw NativeDBError.conflict }
            try service.db.cancelJob(id: job.id)
        }
    }
    func retryUpdate(_ job: NativeJob) throws {
        try service.db.transaction {
            try requireAdmin()
            guard job.event == NativeCurrencyAdministrationJobs.event, ["failed", "retry"].contains(job.status), try service.db.job(id: job.id) == job else { throw NativeDBError.conflict }
            // A user-requested new read receives a fresh attempt budget and
            // current settings/actor. Cancel the prior automatic retry first.
            try service.db.cancelJob(id: job.id)
            _ = try requestECBUpdate()
        }
    }
}

enum NativeCurrencyAdministrationJobs {
    static let event = "currency/ecb-sync"
    static let maximumAttempts = 5
    static let cursor = "currency.ecb.next"
    /// Inngest source: 0 17 * * 1-5, with no timezone override.
    static func nextScheduledDate(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var candidate = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: date)!
        if candidate <= date { candidate = calendar.date(byAdding: .day, value: 1, to: candidate)! }
        while [1, 7].contains(calendar.component(.weekday, from: candidate)) { candidate = calendar.date(byAdding: .day, value: 1, to: candidate)! }
        return candidate
    }
    /// One persisted next-due cursor avoids polling and replaying every missed
    /// weekday when a Mac wakes after several days. The newest available daily
    /// XML replaces all missed daily reads, as no historic XML is requested.
    @discardableResult static func enqueueDue(db: NativeDatabase, now: Date) throws -> Date? {
        try db.transaction {
            guard let settings = try db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")]), settings["value"] == .text("true") else {
                try db.setMetadata(cursor, value: ""); return nil
            }
            let revision = settings.revision
            let stored = (try db.metadata(cursor) ?? "").split(separator: "|", omittingEmptySubsequences: false)
            let date = stored.count == 2 && stored[0] == String(revision) ? Double(stored[1]).map(Date.init(timeIntervalSince1970:)) : nil
            guard let due = date else {
                let next = nextScheduledDate(after: now)
                try db.setMetadata(cursor, value: "\(revision)|\(next.timeIntervalSince1970)"); return next
            }
            if due > now { return due }
            let jobID = "ecb-\(revision)-\(Int64(due.timeIntervalSince1970))"
            if try db.job(id: jobID) == nil { _ = try db.enqueue(event, payload: ["revision": String(revision), "scheduledAt": String(due.timeIntervalSince1970)], id: jobID, now: now) }
            let next = nextScheduledDate(after: now)
            try db.setMetadata(cursor, value: "\(revision)|\(next.timeIntervalSince1970)"); return next
        }
    }
    @discardableResult static func runNext(db: NativeDatabase, transport: NativeCurrencyAdministrationECB.Transport,
                                          clock: @escaping () -> Date = Date.init, leaseSeconds: TimeInterval = 300) async throws -> Bool {
        try Task.checkCancellation()
        let started = clock()
        guard let job = try db.claimJob(events: [event], now: started, leaseSeconds: leaseSeconds) else { return false }
        if job.attempts > maximumAttempts { try db.failJob(job, message: "ECB更新の再試行回数を超えました。設定と接続を確認してください。"); return true }
        func current() throws {
            try Task.checkCancellation()
            guard clock() < started.addingTimeInterval(leaseSeconds) else { throw NativeDBError.conflict }
            _ = try db.requireJobLease(job)
            if let actor = job.payload["actorID"] {
                let service = CRMService(db: db, identity: .init(id: actor, role: "admin", partnerAccountID: nil))
                try service.authenticated()
            }
            guard let setting = try db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")]), setting["value"] == .text("true"),
                  job.payload["revision"] == String(setting.revision) else { throw NativeDBError.message("ECB更新の設定が変更されています。") }
        }
        do {
            let active = try db.transaction { () -> Bool in
                let setting = try db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")])
                guard setting?["value"] == .text("true"), let setting, job.payload["revision"] == String(setting.revision) else { return false }
                try current(); return true
            }
            if !active { try db.finishJob(job, result: ["status": "skipped", "reason": "設定が無効または変更済みです"], now: clock()); return true }
            let result = try await NativeCurrencyAdministrationECB.synchronize(db: db, transport: transport, clock: clock, validate: current)
            try db.transaction {
                try current()
                try db.finishJob(job, result: ["status": result.skipped ? "skipped" : "updated", "updated": String(result.updated), "ratesCount": String(result.ratesCount)], now: clock())
            }
        } catch {
            try db.transaction {
                guard (try? db.requireJobLease(job)) != nil else { return }
                let setting = try db.get("crm_SystemSettings", key: ["key": .text("ecb_auto_update")])
                if setting?["value"] != .text("true") || setting.map({ String($0.revision) }) != job.payload["revision"] {
                    try db.finishJob(job, result: ["status": "skipped", "reason": "設定変更により更新を中止しました"], now: clock())
                } else {
                    let retry = job.attempts < maximumAttempts ? clock().addingTimeInterval(error is CancellationError ? 1 : min(300, pow(2, Double(job.attempts - 1)) * 5)) : nil
                    try db.failJob(job, message: error is CancellationError ? "アプリの停止によりECB更新を中断しました。" : "ECBの更新に失敗しました。通貨設定と接続を確認してください。", retryAt: retry)
                }
            }
        }
        return true
    }
}

/// Application-retained runtime: one worker and one next-due wake. All
/// configuration, retry, and restart state lives in the existing SQLite store.
actor NativeCurrencyAdministrationRuntime {
    private let db: NativeDatabase, transport: NativeCurrencyAdministrationECB.Transport, clock: () -> Date
    private let sleep:NativeProviderRuntimeTasks.Sleep
    private var tasks=NativeProviderRuntimeTasks(),stopping:(id:UUID,task:Task<Void,Never>)?
    private var running = false, task: Task<Void, Never>?, timer: Task<Void, Never>?, observers: [NSObjectProtocol] = []
    private var generation = UUID(), again = false
    private(set) var nextWake: Date?
    init(db: NativeDatabase, transport: @escaping NativeCurrencyAdministrationECB.Transport = NativeCurrencyAdministrationECBTransport.fetch,
         clock: @escaping () -> Date = Date.init,sleep:@escaping NativeProviderRuntimeTasks.Sleep = {try await Task.sleep(nanoseconds:$0)}) { self.db = db; self.transport = transport; self.clock = clock;self.sleep=sleep }
    func start() {
        guard stopping==nil else{return}
        guard !running else { wake(); return }; running = true; generation = UUID();tasks=NativeProviderRuntimeTasks()
        let owner=tasks,ticket=generation
        for name in [NativeDatabase.jobsDidChange, NativeCurrencyAdministration.settingsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self, path = db.url.path] notice in
                guard notice.userInfo?["database"] as? String == path else { return }; owner.submit(key:"wake") { [weak self] in await self?.wake(ticket) }
            })
        }
        wake()
    }
    func wake() {
        guard running,stopping==nil else { return }; timer?.cancel(); timer = nil; nextWake = nil
        if task != nil { again = true; return }
        again = false; let ticket = generation
        task = tasks.submit { [weak self] in await self?.drain(ticket) }
    }
    private func wake(_ ticket:UUID){guard generation==ticket else{return};wake()}
    func stop() async {
        if let current=stopping {await current.task.value;return}
        running=false;generation=UUID();nextWake=nil
        observers.forEach(NotificationCenter.default.removeObserver);observers=[]
        let pending=tasks.close(),id=UUID()
        let completion=Task { [weak self] in
            for task in pending {await task.value}
            await self?.completeStop(id)
        }
        stopping=(id,completion)
        await completion.value
    }
    private func completeStop(_ id:UUID) {
        guard stopping?.id==id else{return}
        task=nil;timer=nil;stopping=nil
    }
    #if RESTORE_PROVIDER_TESTING
    var tasksForTesting:NativeProviderRuntimeTasks {tasks}
    var stoppingForTesting:Bool {stopping != nil}
    #endif
    private func drain(_ ticket: UUID) async {
        guard running,generation==ticket,!Task.isCancelled else{return}
        var due: Date?
        do {
            repeat {
                again = false; due = try NativeCurrencyAdministrationJobs.enqueueDue(db: db, now: clock())
                while running, generation == ticket, !Task.isCancelled,
                      try await NativeCurrencyAdministrationJobs.runNext(db: db, transport: transport, clock: clock) {}
            } while again && running && generation == ticket && !Task.isCancelled
            if let jobDate = try db.nextJobDate(events: [NativeCurrencyAdministrationJobs.event], now: clock()) { due = due.map { min($0, jobDate) } ?? jobDate }
        } catch { due = clock().addingTimeInterval(30) }
        guard generation == ticket else { return }; task = nil
        guard running, let due else { return }; nextWake = due
        let sleep=self.sleep
        timer = tasks.submit { [weak self, clock] in
            do { try await sleep(UInt64(max(0.1, min(86_400 * 4, due.timeIntervalSince(clock()))) * 1_000_000_000));try Task.checkCancellation();await self?.wake(ticket) } catch {}
        }
    }
}
