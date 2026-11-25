import Foundation
import Darwin

struct NativeRestoreHostParentCallbacks {
    /// Fresh current-admin/session check; no cached role/CLI identity is accepted.
    let freshAuthorize: (NativeRestoreHostConversationContext) async throws -> NativeRestoreHostFreshAuthorization
    /// Must present the actual context to the user. There is no default approval.
    let review: (NativeRestoreHostConversationContext, NativeRestoreHostFreshAuthorization) async throws -> NativeRestoreHostUIDecision
    /// Each producer must close admission before joining its accepted work.
    /// Return only after every producer is closed/joined; never reopen afterward.
    let fenceAndDrain: (NativeRestoreHostConversationContext) async throws -> NativeRestoreHostDrainReport
}
struct NativeRestoreHostHelperCallbacks {
    /// EXACT ctx supplied to the real coordinator drain(ctx), plus composition's
    /// exact writers. This adapter must not start a second coordinator/generation.
    let loadCoordinatorContext: () async throws -> NativeRestoreHostConversationContext
    /// Required integration boundary, reached only after registration, approval,
    /// validated drain, exitAllowed, clean IPC EOF, and exact normal NOTE_EXIT.
    /// It is NOT proof that the coordinator committed or that runtimes may resume.
    let afterExactParentExit: (NativeRestoreHostCommitAdmission) async throws -> Void
}
struct NativeRestoreHostCommitAdmission {
    let context: NativeRestoreHostConversationContext
    let subjectSHA256: String
    let approval: NativeRestoreHostApprovalEnvelope
    let preExitReport: NativeRestoreHostDrainReport
    let finalQuiescence: NativeRestoreHostFinalQuiescence
    let exit: NativeRestoreHostExitEvidence
}
/// Not Codable and not constructible by the parent/consumer. The conversation
/// creates this only after exact normal process exit AND clean IPC EOF.
struct NativeRestoreHostFinalQuiescence {
    let evidence: NativeRestoreHostFinalQuiescenceEvidence
    let coordinatorDrain: NativeRestoreActivationDrain
    fileprivate init(session:NativeRestoreHostConversationSession,subject:String,
                     report:NativeRestoreHostDrainReport,exit:NativeRestoreHostExitEvidence) throws {
        let proof=NativeRestoreHostFinalQuiescenceEvidence(version:1,session:session,subjectSHA256:subject,
            registration:.init(exit.registration),parentReportSHA256:try NativeRestoreHostConversationCodec.drainDigest(report),
            cleanPeerEOF:true,normalExitWaitStatus:exit.kernelWaitStatus,processLocalSQLiteHandlesReleased:report.retainedDatabaseHandles.count)
        let digest=try NativeRestoreHostConversationCodec.finalQuiescenceDigest(proof)
        evidence=proof
        coordinatorDrain = .init(root:report.drain.root,participants:report.drain.participants,
            previouslyRunning:report.drain.previouslyRunning,unfinishedTasks:0,openWritableHandles:0,
            unsavedEditors:0,pendingCallbacks:0,evidenceSHA256:digest)
    }
}

struct NativeRestoreHostParentExitPermit {
    let subjectSHA256: String
    let registration: NativeRestoreHostRegistrationReceipt
    let approval: NativeRestoreHostApprovalEnvelope
    let preExitReport: NativeRestoreHostDrainReport
    /// This is permission to request actual OS quit, never evidence of exit.
    /// Retain the helper's OwnedChild through process exit; releasing it reaps it.
}

enum NativeRestoreHostCancellationDisposition: String, Codable {
    case localCancellationRequested
    case cancellationSentAwaitHelperStop
    case cancellationUnconfirmedAwaitHelperStop
    case alreadyFinishedCheckCoordinator
    var requiresHelperStopBeforeParentExit: Bool {
        self == .cancellationSentAwaitHelperStop || self == .cancellationUnconfirmedAwaitHelperStop
    }
}

/// Single-use, one protocol role per instance. Actor reentrancy cannot start a
/// second exchange. The caller owns real UI/DB/provider hooks and process life.
actor NativeRestoreHostConversation {
    enum State: String { case idle, registering, reviewing, approvalSent, draining, waitingForExitPermission, exitPermitted, waitingForExactExit, admitting, admitted, cancelled, failed }
    private(set) var state: State = .idle
    private let session: NativeRestoreHostConversationSession
    private let ipc: NativeRestoreHostIPC
    private let operationTimeout: TimeInterval
    private let exitTimeout: TimeInterval
    private let clock: () -> Date
    private var binding: (String, NativeRestoreHostRegistrationReceipt)?
    private var cancellationRequested = false
    private var cancellationDisposition: NativeRestoreHostCancellationDisposition?
    private var activeMonitor: NativeRestoreHostParentExitMonitor?
    init(session: NativeRestoreHostConversationSession, ipc: NativeRestoreHostIPC,
         operationTimeout: TimeInterval = 30, exitTimeout: TimeInterval = 30,
         clock: @escaping () -> Date = Date.init) throws {
        var budget = NativeRestoreHostWireBudget(); try budget.session(session)
        guard operationTimeout.isFinite, operationTimeout > 0, operationTimeout <= 300,
              exitTimeout.isFinite, exitTimeout > 0, exitTimeout <= 300 else { throw NativeRestoreHostConversationFailure.invalidValue }
        self.session = session; self.ipc = ipc; self.operationTimeout = operationTimeout; self.exitTimeout = exitTimeout; self.clock = clock
    }
    /// No result authorizes OS exit. After any cancellation of an exit permit,
    /// the parent stays alive until the helper is stopped/reaped (or a future
    /// protocol supplies a durable cancellation ACK). A sent frame is not an ACK.
    @discardableResult func cancel() async -> NativeRestoreHostCancellationDisposition {
        if cancellationRequested { return cancellationDisposition ?? .localCancellationRequested }
        guard state != .admitted, state != .admitting, state != .failed else { return .alreadyFinishedCheckCoordinator }
        cancellationRequested = true
        activeMonitor?.cancel()
        let mayHaveReceivedExitPermission = state == .exitPermitted || state == .waitingForExitPermission
        cancellationDisposition = mayHaveReceivedExitPermission ? .cancellationUnconfirmedAwaitHelperStop : .localCancellationRequested
        if mayHaveReceivedExitPermission, let (subject, registration) = binding {
            let message = NativeRestoreHostConversationMessage(session: session, phase: .cancelled, subject: subject, registration: registration)
            do {
                try message.validateBounds(); try await ipc.send(message, timeout: min(1,operationTimeout))
                cancellationDisposition = .cancellationSentAwaitHelperStop
            } catch { cancellationDisposition = .cancellationUnconfirmedAwaitHelperStop }
        }
        state = .cancelled; ipc.close()
        return cancellationDisposition!
    }
    private func check() throws {
        try Task.checkCancellation(); guard !cancellationRequested else { throw NativeRestoreHostConversationFailure.cancelled }
    }
    private static func normalize(_ error: Error) -> Error {
        if error is CancellationError { return NativeRestoreHostConversationFailure.cancelled }
        if let ipc = error as? NativeRestoreHostIPCFailure {
            switch ipc { case .closed: return NativeRestoreHostConversationFailure.peerClosed
            case .cancelled: return NativeRestoreHostConversationFailure.cancelled
            case .timedOut: return NativeRestoreHostConversationFailure.timedOut
            default: break }
        }
        return error
    }
    private func begin() throws { try check(); guard state == .idle else { throw NativeRestoreHostConversationFailure.reused }; state = .registering }
    private func send(_ message: NativeRestoreHostConversationMessage) async throws {
        try check(); try message.validateBounds(); try await ipc.send(message, timeout: operationTimeout); try check()
    }
    private func receive(_ phase: NativeRestoreHostConversationPhase, subject: String? = nil,
                         registration: NativeRestoreHostRegistrationReceipt? = nil) async throws -> NativeRestoreHostConversationMessage {
        try check()
        let message = try await ipc.receive(NativeRestoreHostConversationMessage.self, timeout: operationTimeout)
        try check(); try message.validateBounds()
        guard message.header.session == session else { throw NativeRestoreHostConversationFailure.wrongContext }
        guard message.header.phase == phase else { throw NativeRestoreHostConversationFailure.outOfOrder }
        if let subject, subject != message.header.subjectSHA256 { throw NativeRestoreHostConversationFailure.wrongContext }
        if let registration, registration != message.header.registration { throw NativeRestoreHostConversationFailure.wrongContext }
        return message
    }
    private func validate(_ context: NativeRestoreHostConversationContext) throws -> String {
        guard context.previous == session.previous, context.candidate == session.candidate else { throw NativeRestoreHostConversationFailure.wrongContext }
        return try context.subjectSHA256()
    }
    private func validate(_ auth: NativeRestoreHostFreshAuthorization, subject: String, requireFresh: Bool) throws {
        var budget = NativeRestoreHostWireBudget(); try budget.authorization(auth)
        let now = clock().timeIntervalSince1970
        guard auth.subjectSHA256 == subject else { throw NativeRestoreHostConversationFailure.wrongContext }
        guard now.isFinite, auth.authenticatedAt <= now, auth.validUntil > now,
              auth.validUntil > auth.authenticatedAt, auth.validUntil - auth.authenticatedAt <= 300,
              !requireFresh || now - auth.authenticatedAt <= 60 else { throw NativeRestoreHostConversationFailure.staleApproval }
    }
    private func validate(_ approval: NativeRestoreHostApprovalEnvelope, context: NativeRestoreHostConversationContext, subject: String, requireFresh: Bool) throws {
        var budget = NativeRestoreHostWireBudget(); try budget.approval(approval)
        guard approval.binding.session == session, approval.binding.subjectSHA256 == subject else { throw NativeRestoreHostConversationFailure.wrongContext }
        try validate(approval.authorization, subject: subject, requireFresh: requireFresh)
        let now = clock().timeIntervalSince1970
        guard approval.decision.subjectSHA256 == subject,
              Set(approval.decision.runtimeChoices.map(\.runtimeID)) == Set(context.runtimeCatalog.map(\.id)) else { throw NativeRestoreHostConversationFailure.wrongContext }
        guard approval.decision.approvedAt <= now, approval.decision.validUntil > now, now - approval.decision.approvedAt <= 300,
              approval.decision.approvedAt <= approval.authorization.validUntil else { throw NativeRestoreHostConversationFailure.staleApproval }
    }
    private func validate(_ report: NativeRestoreHostDrainReport, context: NativeRestoreHostConversationContext) throws {
        var budget = NativeRestoreHostWireBudget(); try budget.drain(report)
        let drain = report.drain
        guard report.acceptedWritesFenced, drain.root == context.previous.root,
              Set(drain.participants) == Set(context.writerParticipants),
              Set(drain.previouslyRunning) == Set(context.previousRunning),
              report.retainedDatabaseHandles.allSatisfy({ handle in
                  handle.owner == session.parent && handle.root == context.previous.root &&
                  context.writerParticipants.contains(handle.participant) &&
                  handle.purpose == .processLocalSQLiteConnectionNeverExported
              }),
              drain.unfinishedTasks == 0, drain.unsavedEditors == 0, drain.pendingCallbacks == 0 else { throw NativeRestoreHostConversationFailure.incompleteDrain }
    }
    func runParent(callbacks: NativeRestoreHostParentCallbacks) async throws -> NativeRestoreHostParentExitPermit {
        try begin()
        do {
            guard try NativeRestoreHostProcessIdentity.current(getpid()) == session.parent else { throw NativeRestoreHostConversationFailure.wrongContext }
            let offered = try await receive(.registeredContext)
            guard let context = offered.context else { throw NativeRestoreHostConversationFailure.outOfOrder }
            let subject = try validate(context), registration = offered.header.registration
            guard subject == offered.header.subjectSHA256 else { throw NativeRestoreHostConversationFailure.wrongContext }
            binding = (subject,registration); state = .reviewing
            let initialAuth = try await callbacks.freshAuthorize(context); try check(); try validate(initialAuth, subject: subject, requireFresh: true)
            let decision = try await callbacks.review(context,initialAuth); try check()
            guard case .approved(let uiApproval) = decision else { throw NativeRestoreHostConversationFailure.declined }
            // A long-running review or a role/session change cannot reuse its old authorization.
            let freshAuth = try await callbacks.freshAuthorize(context); try check()
            guard freshAuth.principalID == initialAuth.principalID else { throw NativeRestoreHostConversationFailure.unauthorized }
            let approval = NativeRestoreHostApprovalEnvelope(binding: .init(session:session,phase:.approval,sequence:1,subjectSHA256:subject,registration:registration), authorization: freshAuth, decision: uiApproval)
            try validate(approval, context: context, subject: subject, requireFresh: true)
            let approvalSHA = try NativeRestoreHostConversationCodec.approvalDigest(approval)
            state = .approvalSent
            try await send(.init(session: session, phase: .approval, subject: subject, registration: registration, approval: approval))
            let accepted = try await receive(.accepted, subject: subject, registration: registration)
            guard accepted.acknowledgedSHA256 == approvalSHA else { throw NativeRestoreHostConversationFailure.wrongContext }
            // Recheck immediately before sealing write admission; no trust in a cached role.
            let drainAuth = try await callbacks.freshAuthorize(context); try check(); try validate(drainAuth,subject:subject,requireFresh:true)
            guard drainAuth.principalID == approval.authorization.principalID else { throw NativeRestoreHostConversationFailure.unauthorized }
            state = .draining
            let report = try await callbacks.fenceAndDrain(context); try check()
            try validate(report, context: context); try validate(approval,context:context,subject:subject,requireFresh:false)
            // An already accepted role/session edit may have completed during drain.
            // This callback may use an inventoried process-local connection. It must
            // finish its query and must not retain another handle or reopen admission.
            let finalAuth = try await callbacks.freshAuthorize(context); try check()
            try validate(finalAuth,subject:subject,requireFresh:true)
            guard finalAuth.principalID == approval.authorization.principalID else { throw NativeRestoreHostConversationFailure.unauthorized }
            state = .waitingForExitPermission
            try await send(.init(session: session, phase: .drained, subject: subject, registration: registration, drain: report))
            let allowed = try await receive(.exitAllowed, subject: subject, registration: registration)
            guard allowed.acknowledgedSHA256 == (try NativeRestoreHostConversationCodec.drainDigest(report)) else { throw NativeRestoreHostConversationFailure.wrongContext }
            try validate(approval,context:context,subject:subject,requireFresh:false); try check()
            state = .exitPermitted
            return .init(subjectSHA256: subject, registration: registration, approval: approval, preExitReport: report)
        } catch { if state != .cancelled { state = .failed }; ipc.close(); throw cancellationRequested || Task.isCancelled ? NativeRestoreHostConversationFailure.cancelled : Self.normalize(error) }
    }
    func runHelper(lease: NativeRestoreHostInstanceLease, callbacks: NativeRestoreHostHelperCallbacks) async throws -> NativeRestoreHostCommitAdmission {
        try begin()
        do {
            guard lease.identity == session.lease else { throw NativeRestoreHostConversationFailure.wrongContext }; try lease.validate()
            let context = try await callbacks.loadCoordinatorContext(); try check(); let subject = try validate(context)
            let monitor = try NativeRestoreHostParentExitMonitor(register: session.parent)
            activeMonitor = monitor
            defer { activeMonitor = nil }
            let registration = NativeRestoreHostRegistrationReceipt(monitor.registration); binding = (subject,registration)
            try await send(.init(session:session,phase:.registeredContext,subject:subject,registration:registration,context:context))
            state = .reviewing
            let message = try await receive(.approval,subject:subject,registration:registration)
            guard let approval = message.approval else { throw NativeRestoreHostConversationFailure.outOfOrder }
            try validate(approval,context:context,subject:subject,requireFresh:true)
            try await send(.init(session:session,phase:.accepted,subject:subject,registration:registration,acknowledgedSHA256:NativeRestoreHostConversationCodec.approvalDigest(approval)))
            state = .draining
            let drained = try await receive(.drained,subject:subject,registration:registration)
            guard let report = drained.drain else { throw NativeRestoreHostConversationFailure.outOfOrder }
            try validate(report,context:context); try validate(approval,context:context,subject:subject,requireFresh:false); try lease.validate()
            try await send(.init(session:session,phase:.exitAllowed,subject:subject,registration:registration,acknowledgedSHA256:NativeRestoreHostConversationCodec.drainDigest(report)))
            state = .waitingForExactExit
            let now = clock().timeIntervalSince1970
            let seconds = min(exitTimeout, approval.authorization.validUntil - now, approval.decision.validUntil - now)
            guard seconds > 0 else { throw NativeRestoreHostConversationFailure.staleApproval }
            let exit = try await waitForExit(monitor, subject:subject, registration:registration, timeout:seconds)
            try check(); try lease.validate(); try validate(approval,context:context,subject:subject,requireFresh:false)
            guard exit.kernelWaitStatus & 0x7f == 0, (exit.kernelWaitStatus >> 8) & 0xff == 0 else { throw NativeRestoreHostConversationFailure.abnormalExit }
            let finalQuiescence=try NativeRestoreHostFinalQuiescence(session:session,subject:subject,report:report,exit:exit)
            let admission = NativeRestoreHostCommitAdmission(context:context,subjectSHA256:subject,approval:approval,
                preExitReport:report,finalQuiescence:finalQuiescence,exit:exit)
            state = .admitting
            try await callbacks.afterExactParentExit(admission); try check()
            state = .admitted; ipc.close(); return admission
        } catch { if state != .cancelled { state = .failed }; ipc.close(); throw cancellationRequested || Task.isCancelled ? NativeRestoreHostConversationFailure.cancelled : Self.normalize(error) }
    }
    private enum ExitEvent { case exited(NativeRestoreHostExitEvidence), eof }
    private func waitForExit(_ monitor: NativeRestoreHostParentExitMonitor, subject:String,
                             registration:NativeRestoreHostRegistrationReceipt, timeout:TimeInterval) async throws -> NativeRestoreHostExitEvidence {
        try await withThrowingTaskGroup(of: ExitEvent.self) { group in
            group.addTask {
                switch try await monitor.wait(timeout:timeout) {
                case .exited(let evidence): return .exited(evidence)
                case .cancelled: throw NativeRestoreHostConversationFailure.cancelled
                case .peerClosed: throw NativeRestoreHostConversationFailure.peerClosed
                case .timedOut: throw NativeRestoreHostConversationFailure.timedOut
                }
            }
            group.addTask { [ipc,session] in
                do {
                    let message = try await ipc.receive(NativeRestoreHostConversationMessage.self,timeout:timeout)
                    try message.validateBounds()
                    guard message.header.session == session, message.header.subjectSHA256 == subject,
                          message.header.registration == registration else { throw NativeRestoreHostConversationFailure.wrongContext }
                    if message.header.phase == .cancelled { throw NativeRestoreHostConversationFailure.cancelled }
                    throw NativeRestoreHostConversationFailure.outOfOrder
                } catch NativeRestoreHostIPCFailure.closed {
                    try Task.checkCancellation(); return .eof
                }
            }
            var exit:NativeRestoreHostExitEvidence?, sawEOF=false
            do {
                while let event = try await group.next() {
                    switch event { case .exited(let value): exit=value; case .eof: sawEOF=true }
                }
                try Task.checkCancellation()
                guard let exit, sawEOF, exit.registration == monitor.registration else { throw NativeRestoreHostConversationFailure.peerClosed }
                return exit
            } catch { group.cancelAll(); monitor.cancel(); throw error }
        }
    }
}
