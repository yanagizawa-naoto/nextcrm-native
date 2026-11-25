import Foundation
import Darwin

/// The first private IPC frame binds physical roots, not invented coordinator
/// generations. Only activate() may select those generations and its exact
/// drain(ctx) is offered back to the parent.
struct NativeRestoreHostLaunchRequest: Codable, Equatable {
    let requestID: String, nonce: String
    let parent: NativeRestoreHostProcessIdentity
    let lease: NativeRestoreHostLeaseIdentity
    let previousRoot: NativeRestoreActivationRoot, candidateRoot: NativeRestoreActivationRoot

    static func make(previousRoot: URL, candidateRoot: URL, lease: NativeRestoreHostInstanceLease) throws -> Self {
        try lease.validate()
        var rng = SystemRandomNumberGenerator()
        let nonce = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        let value = Self(requestID: UUID().uuidString.lowercased(), nonce: nonce, parent: try .current(getpid()), lease: lease.identity,
                         previousRoot: try NativeRestoreActivationControl.root(previousRoot), candidateRoot: try NativeRestoreActivationControl.root(candidateRoot))
        try value.validate(); return value
    }

    func validate() throws {
        var budget = NativeRestoreHostWireBudget(); try budget.uuid(requestID); try budget.hash(nonce)
        for root in [previousRoot, candidateRoot] {
            try budget.text(root.path, maximum: 4096)
            guard root.path.hasPrefix("/"), root.device > 0, root.inode > 0 else { throw NativeRestoreHostConversationFailure.invalidValue }
        }
        guard parent.pid > 1, parent.startSeconds > 0, parent.startMicroseconds < 1_000_000,
              previousRoot != candidateRoot, !previousRoot.path.hasPrefix(candidateRoot.path + "/"),
              !candidateRoot.path.hasPrefix(previousRoot.path + "/") else { throw NativeRestoreHostConversationFailure.invalidValue }
    }

    func validate(session: NativeRestoreHostConversationSession) throws {
        try validate()
        var budget = NativeRestoreHostWireBudget(); try budget.session(session)
        guard session.requestID == requestID, session.nonce == nonce, session.parent == parent,
              session.lease == lease, session.previous.root == previousRoot, session.candidate.root == candidateRoot else {
            throw NativeRestoreHostConversationFailure.wrongContext
        }
    }

    func validateRoots() throws {
        guard try NativeRestoreActivationControl.root(previousRoot.url) == previousRoot,
              try NativeRestoreActivationControl.root(candidateRoot.url) == candidateRoot else {
            throw NativeRestoreHostConversationFailure.wrongContext
        }
    }

    /// Called by the live parent after it has spawned and retained its owned
    /// helper. Cancellation still requires stopping/awaiting that owned child.
    func parentConversation(ipc: NativeRestoreHostIPC, instanceLease: NativeRestoreHostInstanceLease,
                            timeout: TimeInterval = 300) async throws -> NativeRestoreHostConversation {
        try validate(); try validateRoots(); try instanceLease.validate()
        guard instanceLease.identity == lease, try NativeRestoreHostProcessIdentity.current(getpid()) == parent else {
            throw NativeRestoreHostConversationFailure.wrongContext
        }
        try await ipc.send(self, timeout: timeout)
        let session = try await ipc.receive(NativeRestoreHostConversationSession.self, timeout: timeout)
        try validate(session: session); try validateRoots(); try instanceLease.validate()
        return try .init(session: session, ipc: ipc, operationTimeout: timeout, exitTimeout: timeout)
    }
}

/// Required real composition boundaries. The helper owns no saved actor/email
/// fallback, provider defaults, process restart fiction or alternate journal.
struct NativeRestoreCoordinatorHostCallbacks {
    let authorize: () async throws -> Void
    let freshAuthorize: NativeRestoreReviewBridge.FreshAuthorize
    let capturePreviousRunning: (NativeRestoreActivationContext) async throws -> [String]
    let preparePaused: (NativeRestoreActivationContext, [String]) async throws -> Void
    let resumeCommitted: (NativeRestoreActivationContext, [String], NativeRestoreHostCommitAdmission) async throws -> NativeRestoreActivationStartup
    let closeCandidate: (NativeRestoreActivationContext) async throws -> Void
    /// nil admission is NOT proof the parent lives: abnormal exit/expired
    /// approval can prevent admission after an actual exit. Check exact process
    /// identity separately; uncertainty must remain recoveryRequired. A live
    /// parent requires coordination; relaunch requires a real startup ACK.
    let resumePrevious: (NativeRestoreActivationContext, NativeRestoreActivationDrain?, NativeRestoreHostCommitAdmission?) async throws -> NativeRestoreActivationStartup
}

actor NativeRestoreCoordinatorHost {
    private let request: NativeRestoreHostLaunchRequest, ipc: NativeRestoreHostIPC
    private let lease: NativeRestoreHostInstanceLease, coordinator: NativeRestoreActivation
    private let callbacks: NativeRestoreCoordinatorHostCallbacks, timeout: TimeInterval, clock: () -> Date
    private var started = false
    private var cancellationRequested = false
    private var operation: Task<NativeRestoreActivationResult, Error>?
    private var conversation: NativeRestoreHostConversation?, admission: NativeRestoreHostCommitAdmission?
    private var heldPolicy: NativeRestoreHeldReviewPolicy?

    init(request: NativeRestoreHostLaunchRequest, ipc: NativeRestoreHostIPC, lease: NativeRestoreHostInstanceLease,
         coordinator: NativeRestoreActivation, callbacks: NativeRestoreCoordinatorHostCallbacks,
         timeout: TimeInterval = 300, clock: @escaping () -> Date = Date.init) throws {
        try request.validate(); try request.validateRoots(); try lease.validate()
        guard lease.identity == request.lease, try NativeRestoreHostProcessIdentity.parent() == request.parent,
              timeout.isFinite, timeout > 0, timeout <= 300 else { throw NativeRestoreHostConversationFailure.wrongContext }
        self.request = request; self.ipc = ipc; self.lease = lease; self.coordinator = coordinator
        self.callbacks = callbacks; self.timeout = timeout; self.clock = clock
    }

    func run() async throws -> NativeRestoreActivationResult {
        guard !started else { throw NativeRestoreHostConversationFailure.reused }; started = true
        defer { ipc.close() }
        guard !cancellationRequested else { throw CancellationError() }; try Task.checkCancellation()
        let hooks = NativeRestoreActivationHooks(runtimes: NativeRestoreRuntimeCatalog.runtimes,
            writerParticipants: NativeRestoreRuntimeCatalog.writerParticipants,
            authorize: { try self.lease.validate(); try await self.callbacks.authorize() },
            capturePreviousRunning: callbacks.capturePreviousRunning,
            drain: { try await self.drain($0) },
            verifyRecoveryQuiescence: { _, _ in throw NativeRestoreActivationFailure("host.separateColdRecoveryRequired") },
            review: { try await self.review($0, $1) }, reviewRow: { try await self.reviewRow($0, $1, $2) },
            preparePaused: callbacks.preparePaused,
            resumeCommitted: { try await self.resume($0, $1) }, closeCandidate: callbacks.closeCandidate,
            resumePrevious: { try await self.compensate($0, $1) })
        let task = Task { try await coordinator.activate(candidateURL: request.candidateRoot.url, currentRootURL: request.previousRoot.url, hooks: hooks) }
        operation = task
        defer { operation = nil }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func drain(_ ctx: NativeRestoreActivationContext) async throws -> NativeRestoreActivationDrain {
        guard ctx.previous.root == request.previousRoot, ctx.candidate.root == request.candidateRoot, conversation == nil else {
            throw NativeRestoreHostConversationFailure.wrongContext
        }
        let context = NativeRestoreHostConversationContext(coordinator: ctx, writerParticipants: NativeRestoreRuntimeCatalog.writerParticipants)
        try NativeRestoreReviewBridge.validate(context)
        let session = NativeRestoreHostConversationSession(sessionID: UUID().uuidString.lowercased(), nonce: request.nonce,
            requestID: request.requestID, parent: request.parent, lease: request.lease, previous: ctx.previous, candidate: ctx.candidate)
        try request.validate(session: session)
        let exchange = try NativeRestoreHostConversation(session: session, ipc: ipc, operationTimeout: timeout, exitTimeout: timeout, clock: clock)
        conversation = exchange
        try await ipc.send(session, timeout: timeout)
        let value = try await exchange.runHelper(lease: lease, callbacks: .init(loadCoordinatorContext: { context },
            afterExactParentExit: { try await self.accept($0) }))
        return value.finalQuiescence.coordinatorDrain
    }

    private func accept(_ value: NativeRestoreHostCommitAdmission) async throws {
        guard admission == nil else { throw NativeRestoreHostConversationFailure.reused }
        // Preserve actual exit evidence even if fresh auth/policy now fails;
        // compensation must distinguish a live parent from a dead parent.
        admission = value
        heldPolicy = try await NativeRestoreReviewBridge.policy(admission: value, clock: clock, authorize: callbacks.freshAuthorize)
    }

    private func policy(_ context: NativeRestoreActivationContext) throws -> NativeRestoreHeldReviewPolicy {
        guard let admission, let heldPolicy,
              try NativeRestoreHeldReviewPolicy.binding(context) == NativeRestoreHeldReviewPolicy.binding(admission.context.coordinatorContext) else {
            throw NativeRestoreActivationFailure("host.missingReviewedAdmission")
        }
        return heldPolicy
    }
    private func review(_ kind: String, _ context: NativeRestoreActivationContext) async throws -> NativeRestoreActivationEvidence {
        try await policy(context).review(kind, context: context)
    }
    private func reviewRow(_ row: NativeRestorePlanEntry, _ digest: String, _ context: NativeRestoreActivationContext) async throws -> NativeRestoreActivationRowDecision {
        try await policy(context).reviewRow(row, rowSHA256: digest, context: context)
    }
    private func resume(_ context: NativeRestoreActivationContext, _ permitted: [String]) async throws -> NativeRestoreActivationStartup {
        _ = try policy(context)
        guard let admission, permitted == ["workspace.local"] else { throw NativeRestoreActivationFailure("host.unreviewedRuntime") }
        return try await callbacks.resumeCommitted(context, permitted, admission)
    }
    private func compensate(_ context: NativeRestoreActivationContext, _ drain: NativeRestoreActivationDrain?) async throws -> NativeRestoreActivationStartup {
        try await callbacks.resumePrevious(context, drain, admission)
    }
    /// Cooperative callbacks must drain their accepted work before returning.
    /// This joins the actual coordinator task, including durable compensation.
    /// A completed pointer commit is handled by the coordinator, never rolled
    /// back just because this method was called.
    func cancel() async {
        cancellationRequested = true
        let running = operation; running?.cancel()
        _ = await conversation?.cancel()
        ipc.close()
        _ = try? await running?.value
    }
}
