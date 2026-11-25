import Foundation
import Darwin

/// Personal child adapter for the real inherited startup exchange. It never
/// converts a CRM actor into an OS principal and does not alter the legacy host.
/// Retain for the process lifetime; every failure/cancel outcome requires exit
/// because StartupExchange keeps an independent lease anchor until OS exit.
@MainActor final class NativePersonalRestoreChild {
    typealias MakeHost = (NativeRestoreApplicationStartup) throws -> NativePersonalApplicationHost
    typealias Readiness = (NativeRestoreHostStartupRequest, NativeRestoreApplicationStartup) async throws -> NativeRestoreHostWorkspaceReadiness
    typealias DidBecomeReady = (NativeRestoreHostStartupRequest, NativeRestoreApplicationStartup) async throws -> Void
    enum State: String { case idle, launching, awaitingHelper, ready, stopping, processExitRequired }
    enum Failure: String, Error { case alreadyStarted, cancelled, helperFailed, helperTimedOut, exchangeFailed, activationInvalid, invalidConfiguration }
    enum Outcome { case ready(NativePersonalApplicationHost), processExitRequired(Failure) }
    private(set) var state: State = .idle
    private let ipc: NativeRestoreHostIPC, leaseDescriptor: NativeRestoreHostDescriptor
    private let baseRootURL: URL, controlURL: URL
    private let makeHost: MakeHost, readiness: Readiness, didBecomeReady: DidBecomeReady
    private let timeout: TimeInterval, clock: () -> Date
    private let monitor: NativeRestoreHostParentExitMonitor
    private var invoked = false, cancelled = false
    private var failure: Failure?
    private var launchTask: Task<Outcome, Never>?
    private var monitorTask: Task<NativeRestoreHostExitOutcome, Error>?
    private var cleanupTask: Task<Void, Never>?
    private var host: NativePersonalApplicationHost?
    private var startup: NativeRestoreApplicationStartup?
    private var started: NativeRestoreHostStartedApplication?
    private var request: NativeRestoreHostStartupRequest?

    /// Consumes supplied FD owners (main passes connected socket 20 / lease 21).
    /// Pin the actual helper's parent/birth identity before authority or DB work.
    init(ipc: NativeRestoreHostIPC, leaseDescriptor: NativeRestoreHostDescriptor,
         baseRootURL: URL, controlURL: URL, makeHost: @escaping MakeHost,
         readiness: @escaping Readiness, didBecomeReady: @escaping DidBecomeReady,
         timeout: TimeInterval = 300, clock: @escaping () -> Date = Date.init) throws {
        do {
            guard timeout.isFinite, timeout > 0, timeout <= 300, baseRootURL.isFileURL, controlURL.isFileURL else { throw Failure.invalidConfiguration }
            monitor = try NativeRestoreHostParentExitMonitor(register: .parent())
        } catch { ipc.close(); leaseDescriptor.close(); throw error }
        self.ipc = ipc; self.leaseDescriptor = leaseDescriptor; self.baseRootURL = baseRootURL; self.controlURL = controlURL
        self.makeHost = makeHost; self.readiness = readiness; self.didBecomeReady = didBecomeReady
        self.timeout = timeout; self.clock = clock
    }
    func start() async throws -> Outcome {
        guard !invoked, state == .idle else { throw Failure.alreadyStarted }
        invoked = true; state = .launching
        let task = Task { await self.performLaunch() }; launchTask = task
        if cancelled { task.cancel() }
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if Task.isCancelled || cancelled { requestCancel(); await cleanup(); return .processExitRequired(failure ?? .cancelled) }
        return result
    }
    func requestCancel() {
        cancelled = true; if failure == nil { failure = .cancelled }
        host?.cancel(); launchTask?.cancel(); monitor.cancel()
    }
    @discardableResult func cancelAndWait() async -> Outcome {
        requestCancel(); if let launchTask { _ = await launchTask.value }
        await cleanup(); return .processExitRequired(failure ?? .cancelled)
    }
    private func fail(_ reason: Failure) {
        if failure == nil { failure = reason }; cancelled = true
        host?.cancel(); launchTask?.cancel(); monitor.cancel()
    }
    private func checkCancellation() throws { try Task.checkCancellation(); if cancelled { throw CancellationError() } }
    private func observe(_ outcome: NativeRestoreHostExitOutcome) {
        switch outcome {
        case .exited(let evidence): if evidence.kernelWaitStatus != 0 { fail(.helperFailed) }
        case .timedOut: fail(.helperTimedOut)
        case .cancelled, .peerClosed: if !cancelled { fail(.helperFailed) }
        }
    }
    private func performLaunch() async -> Outcome {
        do {
            try checkCancellation()
            let watch = Task { [weak self, monitor, timeout] () throws -> NativeRestoreHostExitOutcome in
                do { let outcome = try await monitor.wait(timeout: timeout); self?.observe(outcome); return outcome }
                catch { self?.fail(.helperFailed); throw error }
            }
            monitorTask = watch
            let opened = try await NativeRestoreHostStartupExchange.application(ipc: ipc, leaseDescriptor: leaseDescriptor,
                baseRootURL: baseRootURL, controlURL: controlURL, callbacks: .init(
                    freshAuthorize: { [self] request, startup in
                        try checkRequest(request, startup: startup)
                        if host != nil {
                            let current = try await readiness(request, startup)
                            try current.validate(request); try checkRequest(request, startup: startup)
                        }
                        return try freshAuthorization(request, startup: startup)
                    }, prepareWorkspaceAndUI: { [self] request, startup in
                        try checkRequest(request, startup: startup)
                        guard host == nil else { throw Failure.alreadyStarted }
                        let made = try makeHost(startup); host = made
                        do {
                            try await made.start(adopting: startup)
                            try checkCancellation()
                            let ready = try await readiness(request, startup)
                            try checkCancellation(); try ready.validate(request)
                            return .init(readiness: ready, lifetime: made)
                        } catch {
                            // Exchange cannot discard a PreparedWorkspace that
                            // has not returned yet. Join this partial owner here
                            // before allowing its failure EOF to be announced.
                            await made.stopAndDrain(); throw error
                        }
                    }, discardWorkspace: { prepared in
                        if let host = prepared.lifetime as? NativePersonalApplicationHost { await host.stopAndDrain() }
                    }), timeout: timeout, clock: clock)
            started = opened; try checkCancellation(); state = .awaitingHelper
            // The helper may consume ACK/commit active/exit before application()
            // resumes. The retained monitor task preserves that exact evidence.
            let observed = try await watch.value
            try checkCancellation()
            guard case .exited(let evidence) = observed, evidence.kernelWaitStatus == 0,
                  evidence.registration == monitor.registration, let request, let startup, let host,
                  request.helper == evidence.registration.process else { throw Failure.helperFailed }
            try validateCommitted(request, startup: startup)
            try await didBecomeReady(request, startup)
            try checkCancellation(); try validateCommitted(request, startup: startup)
            state = .ready; return .ready(host)
        } catch {
            if failure == nil { failure = error is CancellationError ? .cancelled : (error as? Failure ?? .exchangeFailed) }
            await cleanup(); return .processExitRequired(failure ?? .exchangeFailed)
        }
    }
    private func checkRequest(_ request: NativeRestoreHostStartupRequest, startup: NativeRestoreApplicationStartup) throws {
        try checkCancellation(); try request.validateBounds(); try request.validateLifetime(now: clock())
        guard startup.plan.mode == .approvedHandoff, request.helper == monitor.registration.process,
              request.application == (try NativeRestoreHostProcessIdentity.current(getpid())),
              startup.plan.selection == request.selection, startup.plan.activationID == request.activationID,
              startup.plan.permitted == ["workspace.local"], startup.plan.held == request.held,
              startup.lease.identity == request.lease else { throw Failure.activationInvalid }
        if let previous = self.request { guard previous == request else { throw Failure.activationInvalid } }
        self.request = request; self.startup = startup
    }
    private func context(_ journal: NativeRestoreActivationJournal) throws -> NativeRestoreHostConversationContext {
        guard let seal = journal.seal else { throw Failure.activationInvalid }
        let context = NativeRestoreHostConversationContext(coordinator: .init(activationID: journal.activationID,
            previous: journal.previous, candidate: journal.candidate, seal: seal,
            inheritedPending: journal.inheritedPending, previousRunning: journal.previousRunning,
            runtimeCatalog: journal.runtimeCatalog), writerParticipants: NativeRestoreRuntimeCatalog.writerParticipants)
        try NativeRestoreReviewBridge.validate(context); return context
    }
    private func parentState(_ request: NativeRestoreHostStartupRequest, startup: NativeRestoreApplicationStartup,
                             context: NativeRestoreHostConversationContext) throws -> NativePersonalRestoreParentState {
        try startup.control.validate(); try startup.lease.validate()
        guard let state = try startup.control.read(NativePersonalRestoreParentState.filename, as: NativePersonalRestoreParentState.self),
              state.phase == .drained, state.request.parent.uid == geteuid(),
              state.running == context.previousRunning else { throw Failure.activationInvalid }
        try state.request.validate(session: request.approval.binding.session); try state.request.validateRoots()
        guard try context.subjectSHA256() == request.approval.binding.subjectSHA256 else { throw Failure.activationInvalid }
        return state
    }
    private func freshAuthorization(_ request: NativeRestoreHostStartupRequest, startup: NativeRestoreApplicationStartup) throws -> NativeRestoreHostFreshAuthorization {
        try checkCancellation()
        guard let journal = try startup.control.read("activation.json", as: NativeRestoreActivationJournal.self) else { throw Failure.activationInvalid }
        try request.validateJournal(journal)
        let context = try context(journal), state = try parentState(request, startup: startup, context: context)
        let current = try NativePersonalHostAuthority.fresh(context, request: state.request, control: startup.control, lease: startup.lease)
        guard current.principalID == request.approval.authorization.principalID,
              current.subjectSHA256 == request.approval.binding.subjectSHA256 else { throw Failure.activationInvalid }
        // Parent review binds the coordinator context. StartupExchange instead
        // binds the exact request/application/helper/nonce; preserve fresh OS
        // evidence and explicitly bind it to that second subject.
        let subject = try request.subjectSHA256()
        struct Evidence: Encodable { let contextAuthority: NativeRestoreHostFreshAuthorization; let startupSubject: String }
        let evidence = try NativeRestoreHostStartupCodec.hash(Evidence(contextAuthority: current, startupSubject: subject), domain: "NextCRM.personal.child-startup-authority.v1")
        return .init(principalID: current.principalID, subjectSHA256: subject, evidenceSHA256: evidence,
                     authenticatedAt: current.authenticatedAt, validUntil: current.validUntil)
    }
    private func validateCommitted(_ request: NativeRestoreHostStartupRequest, startup: NativeRestoreApplicationStartup) throws {
        try startup.control.validate(); try startup.lease.validate()
        guard try NativeRestoreActivationControl.root(request.selection.root.url) == request.selection.root,
              try startup.control.read("active-root.json", as: NativeRestoreActivationSelection.self) == request.selection,
              let journal = try startup.control.read("activation.json", as: NativeRestoreActivationJournal.self),
              journal.formatVersion == 1, journal.phase == .active, journal.activationID == request.activationID,
              journal.previous == request.approval.binding.session.previous, journal.candidate == request.selection,
              journal.permittedRuntimes == request.permitted, journal.heldRuntimes == request.held else { throw Failure.activationInvalid }
        let context = try context(journal)
        _ = try parentState(request, startup: startup, context: context)
    }
    private func cleanup() async {
        if let cleanupTask { await cleanupTask.value; return }
        state = .stopping
        let host = self.host, opened = started, startup = self.startup, watch = monitorTask
        let task = Task { [weak self, monitor, ipc, leaseDescriptor] in
            monitor.cancel(); watch?.cancel(); _ = try? await watch?.value
            // Both layers are idempotent and join actual accepted preparation.
            if let host { await host.stopAndDrain() }
            if let opened { _ = await opened.shutdown() }
            ipc.close(); leaseDescriptor.close(); startup?.lease.close()
            self?.host = nil; self?.started = nil; self?.startup = nil
            self?.state = .processExitRequired
        }
        cleanupTask = task; await task.value
    }
}
