import Foundation
import Darwin

/// Bootstrap-only owner. Call after NSApplication didFinishLaunching; install
/// the returned CRM delegate only after ready. Retain this owner for the process.
/// No identity, approval, provider or writable-workspace default is supplied.
@MainActor final class NativeRestoreApplicationLaunchHost {
    typealias FreshAuthorize = (NativeRestoreHostStartupRequest, NativeRestoreApplicationStartup) async throws -> NativeRestoreHostFreshAuthorization
    enum State: String { case idle, launching, awaitingHelper, ready, stopping, processExitRequired }
    enum Failure: String, Error { case alreadyStarted, cancelled, helperFailed, helperTimedOut, exchangeFailed, activationInvalid, invalidConfiguration }
    enum Outcome { case ready(NativeCRMApplication), processExitRequired(Failure) }

    private(set) var state: State = .idle
    private let ipc: NativeRestoreHostIPC, leaseDescriptor: NativeRestoreHostDescriptor
    private let baseRootURL: URL, controlURL: URL, resourcesURL: URL
    private let freshAuthorize: FreshAuthorize, workspaceOpener: NativeCRMApplication.WorkspaceOpener
    private let timeout: TimeInterval, clock: () -> Date
    private let monitor: NativeRestoreHostParentExitMonitor
    private var invoked = false, cancellationRequested = false
    private var failure: Failure?
    private var launchTask: Task<Outcome, Never>?
    private var monitorTask: Task<NativeRestoreHostExitOutcome, Error>?
    private var helperOutcome: NativeRestoreHostExitOutcome?
    private var cleanupTask: Task<Void, Never>?
    private var application: NativeCRMApplication?
    private var resolved: NativeRestoreApplicationStartup?
    private var started: NativeRestoreHostStartedApplication?
    private var request: NativeRestoreHostStartupRequest?

    /// Consumes the supplied private endpoints. Registration pins the actual
    /// helper birth identity before any request, authority callback or DB open.
    init(ipc: NativeRestoreHostIPC, leaseDescriptor: NativeRestoreHostDescriptor,
         baseRootURL: URL, controlURL: URL, resourcesURL: URL,
         freshAuthorize: @escaping FreshAuthorize,
         workspaceOpener: @escaping NativeCRMApplication.WorkspaceOpener,
         timeout: TimeInterval = 30, clock: @escaping () -> Date = Date.init) throws {
        do {
            guard timeout.isFinite, timeout > 0, timeout <= 300,
                  baseRootURL.isFileURL, controlURL.isFileURL, resourcesURL.isFileURL else { throw Failure.invalidConfiguration }
            monitor = try NativeRestoreHostParentExitMonitor(register: .parent())
        } catch { ipc.close(); leaseDescriptor.close(); throw error }
        self.ipc=ipc; self.leaseDescriptor=leaseDescriptor
        self.baseRootURL=baseRootURL; self.controlURL=controlURL; self.resourcesURL=resourcesURL
        self.freshAuthorize=freshAuthorize; self.workspaceOpener=workspaceOpener; self.timeout=timeout; self.clock=clock
    }

    /// A second invocation rejects without cancelling or replacing the first.
    func start() async throws -> Outcome {
        guard !invoked, state == .idle else { throw Failure.alreadyStarted }
        invoked=true; state = .launching
        let task=Task { [self] in await performLaunch() }
        launchTask=task
        if cancellationRequested { task.cancel() }
        let outcome=await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        // Cancellation racing with the task's final return must not publish ready.
        if Task.isCancelled || cancellationRequested {
            requestCancel(); await cleanup(); return .processExitRequired(failure ?? .cancelled)
        }
        return outcome
    }

    /// The close/Quit callback cancels THIS owned task, never an unrelated copy.
    /// It does not announce EOF before prepared-work cleanup has joined.
    func requestCancel() {
        cancellationRequested=true
        if failure == nil { failure = .cancelled }
        launchTask?.cancel(); monitor.cancel()
    }
    @discardableResult func cancelAndWait() async -> Outcome {
        requestCancel()
        if let task=launchTask { _ = await task.value }
        await cleanup()
        return .processExitRequired(failure ?? .cancelled)
    }

    private func observe(_ outcome: NativeRestoreHostExitOutcome) {
        helperOutcome=outcome
        switch outcome {
        case .exited(let evidence):
            // Normal NOTE_EXIT may be observed before application() returns:
            // the helper can consume ACK, commit active and exit while the
            // child's send continuation is still queued. Keep this evidence.
            if evidence.kernelWaitStatus != 0 { failAndCancel(.helperFailed) }
        case .timedOut: failAndCancel(.helperTimedOut)
        case .cancelled, .peerClosed:
            if !cancellationRequested { failAndCancel(.helperFailed) }
        }
    }
    private func failAndCancel(_ reason: Failure) {
        if failure == nil { failure=reason }
        cancellationRequested=true; launchTask?.cancel(); monitor.cancel()
    }
    private func checkCancellation() throws {
        try Task.checkCancellation()
        guard !cancellationRequested else { throw CancellationError() }
    }
    private func performLaunch() async -> Outcome {
        do {
            try checkCancellation()
            let watch=Task { [weak self, monitor, timeout] () throws -> NativeRestoreHostExitOutcome in
                do { let outcome=try await monitor.wait(timeout:timeout); self?.observe(outcome); return outcome }
                catch { self?.failAndCancel(.helperFailed); throw error }
            }
            monitorTask=watch
            let opened=try await NativeRestoreHostStartupExchange.application(ipc:ipc,leaseDescriptor:leaseDescriptor,
                baseRootURL:baseRootURL,controlURL:controlURL,callbacks:.init(
                    freshAuthorize:{ [self] request, startup in
                        try checkRequest(request,startup:startup)
                        let authority=try await freshAuthorize(request,startup)
                        try checkCancellation()
                        if let application { try application.revalidateRestoredWorkspace(request:request,startup:startup) }
                        return authority
                    },prepareWorkspaceAndUI:{ [self] request, startup in
                        try checkRequest(request,startup:startup)
                        guard application == nil else { throw Failure.alreadyStarted }
                        let app=try NativeCRMApplication(startupPlan:startup.plan,workspaceOpener:workspaceOpener,
                            cancelHostLaunch:{ [weak self] in self?.requestCancel() })
                        application=app
                        let readiness=try await app.prepareRestoredWorkspace(request:request,startup:startup,resources:resourcesURL)
                        try checkCancellation()
                        return .init(readiness:readiness,lifetime:app)
                    },discardWorkspace:{ prepared in
                        if let app=prepared.lifetime as? NativeCRMApplication { await app.discardRestoredWorkspace() }
                    }),timeout:timeout,clock:clock)
            started=opened
            try checkCancellation()
            state = .awaitingHelper
            let observed=try await watch.value
            try checkCancellation()
            guard case .exited(let evidence)=observed,
                  evidence.kernelWaitStatus==0,
                  evidence.registration==monitor.registration,
                  let request,request.helper==evidence.registration.process,
                  let resolved,let application else { throw Failure.helperFailed }
            try validateCommitted(request,startup:resolved)
            try application.completeRestoredHostLaunch(request:request,startup:resolved)
            try checkCancellation()
            state = .ready
            return .ready(application)
        } catch {
            if failure == nil { failure = error is CancellationError ? .cancelled : (error as? Failure ?? .exchangeFailed) }
            await cleanup()
            return .processExitRequired(failure ?? .exchangeFailed)
        }
    }
    private func checkRequest(_ request: NativeRestoreHostStartupRequest, startup: NativeRestoreApplicationStartup) throws {
        try checkCancellation(); try request.validateBounds(); try request.validateLifetime(now:clock())
        guard startup.plan.mode == .approvedHandoff, request.helper==monitor.registration.process,
              startup.plan.selection==request.selection, startup.plan.activationID==request.activationID,
              startup.plan.permitted==["workspace.local"], startup.plan.held==request.held,
              startup.lease.identity==request.lease else { throw Failure.activationInvalid }
        if let expected=self.request { guard expected==request else { throw Failure.activationInvalid } }
        self.request=request; resolved=startup
    }
    /// Active changes the starting-journal hash legitimately. Rebind immutable
    /// context, exact roots/generations, seal and complete held policy instead.
    private func validateCommitted(_ request: NativeRestoreHostStartupRequest, startup: NativeRestoreApplicationStartup) throws {
        try startup.control.validate(); try startup.lease.validate()
        guard try NativeRestoreActivationControl.root(request.selection.root.url)==request.selection.root,
              try startup.control.read("active-root.json",as:NativeRestoreActivationSelection.self)==request.selection,
              let journal=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              journal.formatVersion==1,journal.phase == .active,journal.activationID==request.activationID,
              journal.previous==request.approval.binding.session.previous,journal.candidate==request.selection,
              journal.permittedRuntimes==request.permitted,journal.heldRuntimes==request.held,let seal=journal.seal else { throw Failure.activationInvalid }
        let context=NativeRestoreHostConversationContext(coordinator:.init(activationID:journal.activationID,previous:journal.previous,
            candidate:journal.candidate,seal:seal,inheritedPending:journal.inheritedPending,previousRunning:journal.previousRunning,
            runtimeCatalog:journal.runtimeCatalog),writerParticipants:NativeRestoreRuntimeCatalog.writerParticipants)
        try NativeRestoreReviewBridge.validate(context)
        guard try context.subjectSHA256()==request.approval.binding.subjectSHA256 else { throw Failure.activationInvalid }
    }
    private func cleanup() async {
        if let task=cleanupTask { await task.value; return }
        state = .stopping
        let opened=started, app=application, startup=resolved, watch=monitorTask
        let task=Task { [weak self,monitor,ipc,leaseDescriptor] in
            monitor.cancel();watch?.cancel();_ = try? await watch?.value
            if let opened { _ = await opened.shutdown() }
            if let app { await app.discardRestoredWorkspace() }
            ipc.close();leaseDescriptor.close();startup?.lease.close()
            // Exchange keeps its independent private duplicate until OS exit.
            self?.started=nil;self?.application=nil;self?.resolved=nil
            self?.state = .processExitRequired
        }
        cleanupTask=task;await task.value
    }
}
