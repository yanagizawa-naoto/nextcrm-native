import AppKit
import Darwin

/// Cold-start orchestration. No @main, runtimes or synthetic login issuance.
/// The host is retained for the full App lifetime and releases the instance gate
/// only after its required registered App cleanup has actually completed.
@MainActor final class NativePersonalApplicationHost {
    struct Workspace {
        let service: CRMService
        let plan: NativeRestoreApplicationStartupPlan
        let owner: NativePersonalWorkspace.Selection
        var retainedRules: AnyObject? = nil
        var resumption: NativePersonalRuntimeResumption.Active? = nil
        var runtimeReview: NativePersonalRuntimeResumption.ReviewHold? = nil
    }
    struct Prepared {
        let startup: NativeRestoreApplicationStartup
        let workspace: Workspace
        var service: CRMService { workspace.service }
        var owner: NativePersonalWorkspace.Selection { workspace.owner }
        var plan: NativeRestoreApplicationStartupPlan { workspace.plan }
    }
    @MainActor final class Registration {
        private(set) var owner: AnyObject?
        fileprivate var present: (() throws -> Void)?
        fileprivate var openURL: ((URL) -> Void)?
        fileprivate var drain: (() async -> Void)?
        private var drainTask: Task<Void, Never>?
        fileprivate var retainedRules: AnyObject?
        fileprivate var retainedResumption: NativePersonalRuntimeResumption.Active?
        fileprivate var retainedRuntimeReview: NativePersonalRuntimeResumption.ReviewHold?
        /// Register immediately after App construction, before preparation that
        /// can throw. This makes compose/prepare failure cleanup host-owned.
        func install(owner: AnyObject, present: @escaping () throws -> Void,
                     openURL: @escaping (URL) -> Void, stopAndDrain: @escaping () async -> Void) throws {
            guard self.owner == nil, drainTask == nil else { throw NativeRestoreActivationFailure("personal.duplicateComposition") }
            self.owner = owner; self.present = present; self.openURL = openURL; self.drain = stopAndDrain
        }
        fileprivate func stop() async {
            if let task = drainTask { await task.value; return }
            guard let drain else { retainedRules = nil; retainedResumption = nil; retainedRuntimeReview = nil; return }
            let task = Task { await drain() }; drainTask = task
            await task.value
            owner = nil; present = nil; openURL = nil; self.drain = nil; retainedRules = nil; retainedResumption = nil; retainedRuntimeReview = nil; drainTask = nil
        }
    }
    enum State { case idle, preparing, running, closing, closed }
    typealias DatabaseOpener = (URL, Bool) throws -> NativeDatabase
    /// Root composes contracts' personal pending/bound restoration path here.
    /// No default exists; held mode is never silently converted to writable.
    typealias PersonalRestoreResolver = (NativeRestoreApplicationStartup, URL) async throws -> Workspace
    typealias Composer = (Prepared, Registration) async throws -> Void
    typealias RuntimeRestoreResolver = (NativeRestoreApplicationStartup,URL,NativePersonalRuntimeResumption.DrainPermit) async throws -> Workspace
    private let paths: NativePersonalApplicationPaths, resources: URL
    private let runtimes: [NativeRestoreActivationRuntime]
    private let databaseOpener: DatabaseOpener
    private let presentOwner: (NativePersonalOwnerWindow) throws -> Void
    private let validateReadOnly: (NativeRestoreApplicationStartup, URL) throws -> Void
    private let resolvePersonalRestore: PersonalRestoreResolver
    private let compose: Composer
    private(set) var startup: NativeRestoreApplicationStartup?
    private(set) var ownerWindow: NativePersonalOwnerWindow?
    private(set) var state: State = .idle
    private var registration = Registration()
    private var work: Task<Void, Error>?
    private var canceled = false
    private var activeReadOnly = false
    private var activePlan: NativeRestoreApplicationStartupPlan?
    private var urls: [URL] = []
    init(paths: NativePersonalApplicationPaths, resources: URL, runtimes: [NativeRestoreActivationRuntime],
         databaseOpener: @escaping DatabaseOpener, presentOwner: @escaping (NativePersonalOwnerWindow) throws -> Void,
         validateReadOnly: @escaping (NativeRestoreApplicationStartup, URL) throws -> Void,
         resolvePersonalRestore: @escaping PersonalRestoreResolver, compose: @escaping Composer) {
        self.paths = paths; self.resources = resources; self.runtimes = runtimes; self.databaseOpener = databaseOpener
        self.presentOwner = presentOwner; self.validateReadOnly = validateReadOnly; self.resolvePersonalRestore = resolvePersonalRestore; self.compose = compose
    }
    func start() async throws { try await startResolved(nil) }
    /// Takes lifetime ownership of the already authenticated IPC handoff gate;
    /// never opens a second lease. The caller still owns IPC/ACK/NOTE_EXIT and
    /// must keep local-edit review disabled until that exchange has completed.
    func start(adopting startup: NativeRestoreApplicationStartup) async throws { try await startResolved(startup) }
    /// Recovery is not an inherited IPC ACK. Its private permit exists only
    /// after the actual coordinator enters restoringPrevious on the same gate.
    func start(recoveringPrevious startup: NativeRestoreApplicationStartup, permit: NativeRestorePreviousRecoveryPermit) async throws {
        try startup.validatePreviousRecovery(permit)
        try await startResolved(startup, previousPermit: permit)
    }
    private func startResolved(_ adopted: NativeRestoreApplicationStartup?, previousPermit: NativeRestorePreviousRecoveryPermit? = nil) async throws {
        guard state == .idle else { throw NativeRestoreActivationFailure("personal.startState") }
        state = .preparing
        let task = Task { try await self.prepareAndCompose(adopting: adopted, previousPermit: previousPermit) }; work = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { Task { @MainActor in self.cancel() } })
            work = nil
        } catch {
            work = nil; state = .closing
            await registration.stop(); startup?.lease.close(); urls.removeAll(); state = .closed
            throw error
        }
    }
    func cancel() {
        canceled = true; work?.cancel(); urls.removeAll()
        if let ownerWindow { _ = ownerWindow.windowShouldClose(ownerWindow.window) }
    }
    /// Call for Quit/error and await it; destroying a host while accepted App
    /// work is live is not a substitute for this join contract.
    func stopAndDrain() async {
        cancel(); state = .closing
        if let work { _ = await work.result }
        await registration.stop()
        startup?.lease.close(); self.work = nil; ownerWindow = nil; urls.removeAll(); state = .closed
    }
    @discardableResult func receive(_ url: URL) -> Bool {
        guard state != .closing, state != .closed, !canceled,
              url.scheme?.lowercased() == "nextcrm-native", url.absoluteString.utf8.count <= 8192 else { return false }
        if state == .running, let open = registration.openURL { open(url); return true }
        guard urls.count < 16 else { return false }; urls.append(url); return true
    }
    private func check() throws { try Task.checkCancellation(); if canceled { throw CancellationError() } }
    private func validate(_ startup: NativeRestoreApplicationStartup) throws {
        try check(); try paths.validate(startup)
    }
    private func prepareAndCompose(adopting adopted: NativeRestoreApplicationStartup?, previousPermit: NativeRestorePreviousRecoveryPermit?) async throws {
        if let adopted { self.startup = adopted }
        try check()
        let startup: NativeRestoreApplicationStartup
        if let adopted {
            if let previousPermit {
                try adopted.validatePreviousRecovery(previousPermit)
                guard adopted.plan.mode == .previousPolicy || adopted.plan.mode == .personalActiveLocal else { throw NativeRestoreActivationFailure("personal.previousRecoveryMode") }
            } else {
                guard adopted.plan.mode == .approvedHandoff else { throw NativeRestoreActivationFailure("personal.handoffMode") }
            }
            startup = adopted
        } else { startup = try NativeRestoreApplicationStartup(baseRootURL: paths.baseRootURL, controlURL: paths.controlURL, runtimes: runtimes) }
        self.startup = startup
        try validate(startup)
        guard startup.plan.mode != .recoveryRequired else { throw NativeRestoreActivationFailure("personal.recoveryRequired") }
        guard startup.plan.permitted.contains("workspace.local") else { throw NativeRestoreActivationFailure("personal.workspaceNotPermitted") }
        let workspace: Workspace
        switch startup.plan.mode.rawValue {
        case "ordinary", "previousPolicy", "restoredHeld", "approvedHandoff": workspace = try await ordinaryOrHeld(startup)
        case "personalBindingPending", "personalActiveLocal": workspace = try await resolvePersonalRestore(startup, resources)
        default: throw NativeRestoreActivationFailure("personal.unsupportedStartup")
        }
        try await composeWorkspace(workspace, startup: startup)
    }
    private func composeWorkspace(_ workspace: Workspace, startup: NativeRestoreApplicationStartup) async throws {
        try validate(startup)
        guard workspace.plan.root == startup.plan.root, workspace.plan.selection == startup.plan.selection,
              workspace.service.db.url.standardizedFileURL.path == startup.plan.root.url.appendingPathComponent("crm.sqlite").standardizedFileURL.path,
              workspace.service.identity.id == workspace.owner.identity.id else { throw NativeRestoreActivationFailure("personal.workspaceBinding") }
        try workspace.service.authenticated()
        try NativePersonalRuntimeResumption.validateWorkspace(workspace.resumption,review:workspace.runtimeReview,service:workspace.service,plan:workspace.plan,startup:startup)
        registration.retainedResumption=workspace.resumption
        registration.retainedRuntimeReview=workspace.runtimeReview
        registration.retainedRules = workspace.retainedRules
        let prepared = Prepared(startup: startup, workspace: workspace)
        try await compose(prepared, registration)
        try validate(startup)
        guard registration.owner != nil, let present = registration.present else { throw NativeRestoreActivationFailure("personal.compositionRequired") }
        try present(); try check(); activeReadOnly = workspace.service.db.isReadOnly; activePlan=workspace.plan; state = .running
        let pending = urls; urls.removeAll()
        for url in pending { try check(); registration.openURL?(url) }
    }
    /// Only after contracts.review/begin have fsynced bindingPending approval.
    /// operation must capture the approved value, never old Prepared/App/DB.
    /// The old App/immutable connection is drained and released before calling
    /// operation's writable initializer. The same instance lease spans both.
    func transitionWorkspace(operation: @escaping PersonalRestoreResolver) async throws {
        guard state == .running, activeReadOnly, work == nil, let startup,
              startup.plan.mode == .restoredHeld || startup.plan.mode == .approvedHandoff else {
            throw NativeRestoreActivationFailure("personal.transitionState")
        }
        try await performWorkspaceTransition(startup:startup,operation:operation)
    }
    /// Explicit fixed-group review of an already writable personal root. The
    /// approval is a value; operation must not capture old App/service/DB.
    func transitionRuntimePolicy(_ approval:NativePersonalRuntimeResumption.Approval,
                                 operation:@escaping RuntimeRestoreResolver)async throws {
        guard state == .running,!activeReadOnly,work == nil,let startup,
              activePlan?.mode == .personalActiveLocal,activePlan?.personal?.phase == .bound else {
            throw NativeRestoreActivationFailure("personal.runtimeTransitionState")
        }
        try NativePersonalRuntimeResumption.validateApproval(approval,startup:startup)
        try await performWorkspaceTransition(startup:startup) { current,resources in
            try NativePersonalRuntimeResumption.validateApproval(approval,startup:current)
            let permit=try NativePersonalRuntimeResumption.afterDrain(approval,startup:current)
            let workspace=try await operation(current,resources,permit)
            try NativePersonalRuntimeResumption.validateApplied(approval,active:workspace.resumption,startup:current)
            return workspace
        }
    }
    private func performWorkspaceTransition(startup:NativeRestoreApplicationStartup,
                                           operation:@escaping PersonalRestoreResolver)async throws {
        try validate(startup); state = .preparing
        let task = Task {
            await self.registration.stop()
            self.registration = Registration()
            try self.validate(startup)
            let workspace = try await operation(startup, self.resources)
            try self.validate(startup)
            try await self.composeWorkspace(workspace, startup: startup)
        }
        work = task
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { Task { @MainActor in self.cancel() } })
            work = nil
        } catch {
            work = nil; state = .closing
            await registration.stop(); startup.lease.close(); urls.removeAll(); state = .closed
            throw error
        }
    }
    private struct FileIdentity: Equatable { let device: UInt64, inode: UInt64 }
    private func fileIdentity(_ url: URL) throws -> FileIdentity? {
        var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw NativeRestoreActivationFailure("personal.databaseRead") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw NativeRestoreActivationFailure("personal.databasePermissions") }
        return .init(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }
    private func ordinaryOrHeld(_ startup: NativeRestoreApplicationStartup) async throws -> Workspace {
        let readOnly = startup.plan.requiresReview || startup.plan.mode == .restoredHeld
        if startup.plan.mode == .ordinary || startup.plan.mode == .previousPolicy {
            for name in [".native-migration-candidate", ".native-restore-candidate"] {
                let marker = startup.plan.root.url.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: marker.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path)) != nil {
                    throw NativeRestoreActivationFailure("personal.unadmittedImportedRoot")
                }
            }
        }
        let fresh = try paths.permitsFreshSetup(startup)
        let file = startup.plan.root.url.appendingPathComponent("crm.sqlite")
        let before = try fileIdentity(file)
        guard before != nil || (!readOnly && fresh) else { throw NativeRestoreActivationFailure("personal.existingDatabaseMissing") }
        try validate(startup)
        if readOnly { try validateReadOnly(startup, resources) }
        let db = try databaseOpener(file, readOnly)
        try validate(startup)
        guard db.isReadOnly == readOnly, db.url.standardizedFileURL.path == file.standardizedFileURL.path,
              let after = try fileIdentity(file), before == nil || before == after else { throw NativeRestoreActivationFailure("personal.databaseChanged") }
        let identity: CRMIdentity
        if let current = try? NativePersonalWorkspace.reuseExisting(db) {
            identity = current
        } else {
            switch try NativePersonalWorkspace.inspect(db) {
            case .existing(let current): identity = current
            case .pristine:
                guard fresh, !readOnly, try paths.permitsFreshSetup(startup) else { throw NativeRestoreActivationFailure("personal.unadmittedEmptyDatabase") }
                identity = try CRMService.bootstrap(db, resources: resources)
            case .needsSelection:
                guard let selected = try await selectOwner(db, startup: startup) else { throw CancellationError() }
                try validate(startup)
                if readOnly { identity = selected.identity; try CRMService(db: db, identity: identity).authenticated() }
                else { identity = try NativePersonalWorkspace.bind(selected, to: db, authorize: { try self.validate(startup) }) }
            case .blocked: throw NativeRestoreActivationFailure("personal.noEligibleOwner")
            }
        }
        try validate(startup)
        if fresh { try paths.finishFreshSetup(startup) }
        if readOnly { try validateReadOnly(startup, resources) }
        let owner = try NativePersonalWorkspace.select(db, userID: identity.id)
        return Workspace(service: CRMService(db: db, identity: identity), plan: startup.plan, owner: owner)
    }
    private func selectOwner(_ db: NativeDatabase, startup: NativeRestoreApplicationStartup) async throws -> NativePersonalWorkspace.Selection? {
        try validate(startup)
        return try await withCheckedThrowingContinuation { continuation in
            let picker = NativePersonalOwnerWindow(db: db, authorizeRead: { try self.validate(startup) })
            ownerWindow = picker
            picker.onFinished = { [weak self] selection in
                self?.ownerWindow = nil; continuation.resume(returning: selection)
            }
            do { try presentOwner(picker) }
            catch { picker.onFinished = nil; _ = picker.windowShouldClose(picker.window); ownerWindow = nil; continuation.resume(throwing: error) }
        }
    }
}
