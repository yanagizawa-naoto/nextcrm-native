import Foundation

/// One lease fences local effects both after an await and at the database
/// mutation boundary. Expiry uses the injected wall clock as well as the DB
/// token, so an expired worker cannot publish before another process claims it.
private final class NativePluginJobFence {
    let host:NativePluginHost,job:NativeJob,clock:()->Date,leaseSeconds:TimeInterval
    let state:NativeRecord?
    private let lock=NSLock()
    private var active=true,expires:Date
    init(host:NativePluginHost,job:NativeJob,clock:@escaping ()->Date,leaseSeconds:TimeInterval) throws {
        self.host=host;self.job=job;self.clock=clock;self.leaseSeconds=leaseSeconds
        state=try job.payload["pluginId"].flatMap(host.state);expires=clock().addingTimeInterval(leaseSeconds)
    }
    func close() { lock.lock();active=false;lock.unlock() }
    private func live() throws { lock.lock();defer {lock.unlock()};guard active,clock()<expires else { throw NativeDBError.conflict } }
    func check(_ id:String) throws {
        try Task.checkCancellation()
        try host.db.transaction {
            try live();_ = try host.db.requireJobLease(job)
            // A saved event dispatcher has no plugin context; its child jobs
            // acquire their own revision/permission snapshots.
            if let expected=state {
                guard id==expected["id"].string,let current=try host.state(id),current.revision==expected.revision,current["status"] == .text("ENABLED") else { throw NativeDBError.conflict }
            } else if job.payload["pluginId"] != nil { throw NativeDBError.conflict }
        }
    }
    func renew() throws {
        try host.db.transaction {
            try check(job.payload["pluginId"] ?? "__native-plugin-dispatch")
            try host.db.renewJobLease(job,now:clock(),seconds:leaseSeconds)
            lock.lock();expires=clock().addingTimeInterval(leaseSeconds);lock.unlock()
        }
    }
}

enum NativePluginJobExecutor {
    /// Inngest retries:3 means one initial attempt plus three retries. This
    /// native queue preserves the original job id; a reclaimed crash counts as
    /// an attempt and can never silently create an unbounded retry loop.
    static let maximumAttempts=4
    @discardableResult static func runNext(host:NativePluginHost,clock:@escaping ()->Date=Date.init,leaseSeconds:TimeInterval=300,heartbeatSleep:@escaping NativeProviderRuntimeTasks.Sleep = {try await Task.sleep(nanoseconds:$0)}) async throws -> Bool {
        try Task.checkCancellation()
        guard let job=try host.db.claimJob(events:NativePluginHost.jobEvents,now:clock(),leaseSeconds:leaseSeconds) else { return false }
        if job.attempts>maximumAttempts { try host.db.failJob(job,message:"プラグイン処理の再試行回数を超えました");return true }
        let fence=try NativePluginJobFence(host:host,job:job,clock:clock,leaseSeconds:leaseSeconds)
        let work=Task { () throws -> [String:String] in
            try await NativePluginExecutionScope.$validate.withValue(fence.check) {
                // Disabled/missing definitions are acknowledged without running
                // callbacks. They must not turn into permanent retry loops.
                _ = try host.db.requireJobLease(job)
                if let id=job.payload["pluginId"],try host.state(id)?["status"] != .text("ENABLED") { return ["status":"skipped"] }
                try fence.check(job.payload["pluginId"] ?? "__native-plugin-dispatch")
                return try await host.runJob(job)
            }
        }
        let heartbeat=Task {
            do { while !Task.isCancelled {
                try await heartbeatSleep(UInt64(max(0.05,leaseSeconds/3)*1_000_000_000))
                try fence.renew()
            } } catch { fence.close();work.cancel() }
        }
        let outcome:Result<[String:String],Error>=await withTaskCancellationHandler(operation:{ await work.result },onCancel:{fence.close();work.cancel();heartbeat.cancel()})
        heartbeat.cancel();fence.close();await heartbeat.value
        // No business write can occur here: only the original lease token may
        // complete/retry its outbox row. A reclaimed attempt remains untouched.
        try host.db.transaction {
            guard (try? host.db.requireJobLease(job)) != nil else { return }
            switch outcome {
            case .success(let result):try host.db.finishJob(job,result:result,now:clock())
            case .failure(let error):
                let retry=job.attempts<maximumAttempts ? clock().addingTimeInterval(error is CancellationError ? 1:min(300,pow(2,Double(job.attempts-1))*5)):nil
                try host.db.failJob(job,message:error is CancellationError ? "アプリの停止により処理を中断しました":"プラグイン処理に失敗しました。プラグインのログを確認してください",retryAt:retry)
            }
        }
        return true
    }
}

/// Application-owned, single-worker scheduler. No backlog is materialized:
/// SQL supplies the next due date and each turn holds one job and its context.
actor NativePluginsRuntime {
    struct Snapshot { let running:Bool,working:Bool,completed:Int,message:String? }
    private let host:NativePluginHost,vault:NativePluginCredentialVault?,clock:()->Date,leaseSeconds:TimeInterval
    private let sleep:NativeProviderRuntimeTasks.Sleep
    private var tasks=NativeProviderRuntimeTasks(),stopping:(id:UUID,task:Task<Void,Never>)?
    private var running=false,needsUpgrade=true,worker:Task<Void,Never>?,timer:Task<Void,Never>?,observer:NSObjectProtocol?,generation=UUID(),completed=0,message:String?
    init(host:NativePluginHost,vault:NativePluginCredentialVault?=nil,clock:@escaping ()->Date=Date.init,leaseSeconds:TimeInterval=300,sleep:@escaping NativeProviderRuntimeTasks.Sleep = {try await Task.sleep(nanoseconds:$0)}) {
        self.host=host;self.vault=vault;self.clock=clock;self.leaseSeconds=leaseSeconds;self.sleep=sleep
    }
    func snapshot()->Snapshot { .init(running:running,working:worker != nil,completed:completed,message:message) }
    func start() {
        guard stopping==nil else{return}
        guard !running else { wake();return };running=true;needsUpgrade=true;generation=UUID();message=nil;tasks=NativeProviderRuntimeTasks()
        let path=host.db.url.path,owner=tasks,ticket=generation
        observer=NotificationCenter.default.addObserver(forName:NativeDatabase.jobsDidChange,object:nil,queue:nil) { [weak self] notification in
            guard notification.userInfo?["database"] as? String==path else { return };owner.submit(key:"wake") { [weak self] in await self?.wake(ticket) }
        }
        wake()
    }
    /// Call after plugin settings, wake from system sleep, or a committed UI
    /// mutation. A concurrent wake is coalesced into the current drain loop.
    func wake() {
        guard running,stopping==nil else { return };timer?.cancel();timer=nil
        guard worker==nil else { return }
        let ticket=generation
        worker=tasks.submit { [weak self] in await self?.drain(ticket) }
    }
    private func wake(_ ticket:UUID){guard generation==ticket else{return};wake()}
    func stop() async {
        if let current=stopping {await current.task.value;return}
        running=false;generation=UUID()
        if let observer { NotificationCenter.default.removeObserver(observer);self.observer=nil }
        let pending=tasks.close(),id=UUID()
        let completion=Task { [weak self] in
            // Await every accepted task, including cancelled old timers and
            // notification callbacks. Caller cancellation does not skip joins.
            for task in pending {await task.value}
            await self?.completeStop(id)
        }
        stopping=(id,completion)
        await completion.value
    }
    private func completeStop(_ id:UUID) {
        guard stopping?.id==id else{return}
        worker=nil;timer=nil;stopping=nil
    }
    #if RESTORE_PROVIDER_TESTING
    var tasksForTesting:NativeProviderRuntimeTasks {tasks}
    var stoppingForTesting:Bool {stopping != nil}
    #endif
    private func drain(_ ticket:UUID) async {
        guard running,generation==ticket,!Task.isCancelled else{return}
        do {
            _ = try vault?.cleanup()
            if needsUpgrade {
                // Upgrade hooks also run while disabled in the original host.
                // Pin their settings/version state without granting an enabled
                // job lease; OS flock in upgradeAll serializes app processes.
                let host=self.host
                let snapshots=try Dictionary(uniqueKeysWithValues:host.definitions.compactMap { definition in try host.state(definition.id).map { (definition.id,$0.revision) } })
                try await NativePluginExecutionScope.$validate.withValue({ id in
                    try Task.checkCancellation()
                    guard let expected=snapshots[id],try host.state(id)?.revision==expected else { throw NativeDBError.conflict }
                }) { try await host.upgradeAll() }
                needsUpgrade=false
            }
            while running,generation==ticket,!Task.isCancelled {
                try host.enqueueDueCrons(clock())
                if try await !NativePluginJobExecutor.runNext(host:host,clock:clock,leaseSeconds:leaseSeconds) { break }
                completed+=1
            }
        } catch { if !(error is CancellationError) { message="プラグインの処理を実行できません。設定を確認してください" } }
        guard generation==ticket else { return };worker=nil
        guard running else { return }
        let now=clock(),nextMinute=Date(timeIntervalSince1970:(floor(now.timeIntervalSince1970/60)+1)*60)
        let jobDue=(try? host.db.nextJobDate(events:NativePluginHost.jobEvents,now:now)) ?? nextMinute
        let wait=max(0.05,min(60,min(jobDue,nextMinute).timeIntervalSince(now)))
        let sleep=self.sleep
        timer=tasks.submit { [weak self] in do { try await sleep(UInt64(wait*1_000_000_000));try Task.checkCancellation();await self?.wake(ticket) } catch {} }
    }
}
