import Foundation
import Darwin

enum NativeRestoreApplicationStartupMode: String {
    case ordinary, previousPolicy, restoredHeld, recoveryRequired, approvedHandoff
    case personalBindingPending, personalActiveLocal
}

struct NativeRestoreApplicationStartupPlan {
    let root: NativeRestoreActivationRoot
    let selection: NativeRestoreActivationSelection?
    let mode: NativeRestoreApplicationStartupMode
    let permitted: [String], held: [String]
    let activationID: String?
    let requiresReview: Bool
    var personal: NativePersonalRestoreAdmission.Record? = nil
    var resumption: NativePersonalRuntimeResumption.Record? = nil
    var runtimeReview: NativePersonalRuntimeResumption.ReviewSummary? = nil
}

/// These values come from the authenticated, inherited host channel. They are
/// not command-line authority. validateApproval must verify the actual private
/// exchange and context-bound approval before any permitted runtime is built.
struct NativeRestoreApplicationInheritedLaunch {
    let leaseDescriptor: NativeRestoreHostDescriptor
    let leaseIdentity: NativeRestoreHostLeaseIdentity
    let selection: NativeRestoreActivationSelection
    let activationID: String
    let permitted: [String]
    let validateApproval: (NativeRestoreActivationJournal) throws -> Void
}

/// Acquired before bootstrap or opening any CRM database. This class pins the
/// instance gate for its entire lifetime. It selects roots/policy only; the App
/// must still enforce the returned policy in constructors and manual actions.
final class NativeRestoreApplicationStartup {
    let lease: NativeRestoreHostInstanceLease
    let control: NativeRestoreActivationControl
    private(set) var plan: NativeRestoreApplicationStartupPlan
    private let coldInstance: Bool
    private var previousRecovery: NativeRestorePreviousRecoveryPermit?

    init(baseRootURL: URL, controlURL: URL, runtimes: [NativeRestoreActivationRuntime],
         inherited: NativeRestoreApplicationInheritedLaunch? = nil) throws {
        let base = try NativeRestoreActivationControl.root(baseRootURL)
        // Check the prospective canonical location before creating control files.
        // An overlap rejection must not write inside a data root.
        let prospectiveControl = try Self.controlLocation(controlURL)
        guard !Self.overlap(prospectiveControl.path, base.path) else {
            throw NativeRestoreActivationFailure("startup.controlOverlap")
        }
        let control = try NativeRestoreActivationControl(url: prospectiveControl)
        // The stable control directory must not be inside a data root: backup,
        // restore and retention of a root must never move the instance gate.
        guard control.url.path != base.path,
              !control.url.path.hasPrefix(base.path + "/"),
              !base.path.hasPrefix(control.url.path + "/") else {
            throw NativeRestoreActivationFailure("startup.controlOverlap")
        }
        let lease: NativeRestoreHostInstanceLease
        if let inherited {
            lease = try .adopt(existingPrivateControl: control.url, expected: inherited.leaseIdentity,
                               consuming: inherited.leaseDescriptor)
        } else { lease = try .open(existingPrivateControl: control.url) }
        do {
            try lease.validate()
            let selection = try control.read("active-root.json", as: NativeRestoreActivationSelection.self)
            let journal = try control.read("activation.json", as: NativeRestoreActivationJournal.self)
            // Both historical roots matter: retention/backup of an inactive root
            // must not move the stable instance gate either.
            for root in [selection?.root, journal?.previous.root, journal?.candidate.root].compactMap({ $0 }) {
                guard !Self.overlap(control.url.path, root.path) else { throw NativeRestoreActivationFailure("startup.controlOverlap") }
            }
            let journalFingerprint = try Self.fingerprint(journal)
            let plan = try Self.resolve(base: base, selection: selection, journal: journal, runtimes: runtimes, inherited: inherited)
            guard try NativeRestoreActivationControl.root(plan.root.url) == plan.root,
                  plan.root.path != control.url.path,
                  !control.url.path.hasPrefix(plan.root.path + "/"),
                  !plan.root.path.hasPrefix(control.url.path + "/") else {
                throw NativeRestoreActivationFailure("startup.rootChanged")
            }
            try lease.validate()
            // An inherited helper can share the gate while publishing state.
            // Its startup ACK protocol must hold selection steady; detect a
            // concurrent pointer change after approval before opening any DB.
            guard try control.read("active-root.json", as: NativeRestoreActivationSelection.self) == selection else {
                throw NativeRestoreActivationFailure("startup.selectionChanged")
            }
            guard try Self.fingerprint(control.read("activation.json", as: NativeRestoreActivationJournal.self)) == journalFingerprint else {
                throw NativeRestoreActivationFailure("startup.journalChanged")
            }
            self.control = control; self.lease = lease; self.plan = plan; self.coldInstance = inherited == nil
            // Only cold startup resolves a durable personal grant. The original
            // inherited handoff remains immutable/held until its actual ACK.
            if inherited == nil,plan.mode != .recoveryRequired,let record=try NativePersonalRestoreAdmission.resolve(startup:self) {
                self.plan=try NativePersonalRestoreAdmission.plan(for:record,startup:self)
            }
        } catch { lease.close(); throw error }
    }

    /// Only an Active value issued after actual open-DB isolation/requirement
    /// verification can replace this live host's personal feature policy.
    func adoptPersonalRuntimeResumption(_ active:NativePersonalRuntimeResumption.Active)throws {
        plan=try NativePersonalRuntimeResumption.plan(for:active,startup:self)
    }

    func adoptPersonalRuntimeReview(_ hold:NativePersonalRuntimeResumption.ReviewHold)throws {
        plan=try NativePersonalRuntimeResumption.plan(for:hold,startup:self)
    }

    /// Available only while the real recovery coordinator owns its activation
    /// lock and has persisted restoringPrevious. This is not a startup receipt.
    /// The non-serializable permit is tied to this cold instance and its gate.
    func preparePreviousRecovery(_ context: NativeRestoreActivationContext) throws -> NativeRestorePreviousRecoveryPermit {
        try Task.checkCancellation(); try control.validate(); try lease.validate()
        guard coldInstance, previousRecovery == nil, plan.mode == .recoveryRequired,
              plan.selection == context.previous, plan.root == context.previous.root,
              plan.activationID == context.activationID,
              let journal = try control.read("activation.json", as: NativeRestoreActivationJournal.self),
              journal.phase == .restoringPrevious,
              try Self.matches(journal, context: context),
              try control.read("active-root.json", as: NativeRestoreActivationSelection.self) == context.previous,
              try NativeRestoreActivationControl.root(context.previous.root.url) == context.previous.root else {
            throw NativeRestoreActivationFailure("personal.previousRecoveryContext")
        }
        let old = plan
        let permit = NativeRestorePreviousRecoveryPermit(instance: ObjectIdentifier(self), lease: lease.identity,
            activationID: context.activationID, selection: context.previous, subject: try Self.recoverySubject(context))
        previousRecovery = permit
        plan = .init(root: context.previous.root, selection: context.previous, mode: .previousPolicy,
            permitted: context.previousRunning.sorted(), held: context.runtimeCatalog.map(\.id).filter { !context.previousRunning.contains($0) }.sorted(),
            activationID: context.activationID, requiresReview: false)
        do {
            if let record = try NativePersonalRestoreAdmission.resolve(startup: self) {
                guard record.phase == .bound, (try context.previousRunning == ["workspace.local"] || context.previousRunning == NativePersonalRuntimeResumption.permitted(NativePersonalRuntimeResumption.resolve(startup:self,personal:record))) else {
                    throw NativeRestoreActivationFailure("personal.previousRecoveryGrant")
                }
                plan = try NativePersonalRestoreAdmission.plan(for: record, startup: self)
            } else {
                guard Set(context.previousRunning) == Set(context.runtimeCatalog.map(\.id)) else {
                    throw NativeRestoreActivationFailure("personal.previousRecoveryPolicy")
                }
            }
            try validatePreviousRecovery(permit)
            return permit
        } catch { plan = old; previousRecovery = nil; throw error }
    }
    func validatePreviousRecovery(_ permit: NativeRestorePreviousRecoveryPermit) throws {
        try Task.checkCancellation(); try control.validate(); try lease.validate()
        guard coldInstance, previousRecovery == permit, permit.instance == ObjectIdentifier(self),
              permit.lease == lease.identity, permit.activationID == plan.activationID,
              permit.selection == plan.selection, permit.selection.root == plan.root,
              try control.read("active-root.json", as: NativeRestoreActivationSelection.self) == permit.selection,
              try NativeRestoreActivationControl.root(plan.root.url) == plan.root,
              let journal = try control.read("activation.json", as: NativeRestoreActivationJournal.self),
              journal.phase == .restoringPrevious, journal.previous == permit.selection,
              journal.activationID == permit.activationID, let seal = journal.seal,
              try Self.recoverySubject(.init(activationID: journal.activationID, previous: journal.previous,
                candidate: journal.candidate, seal: seal, inheritedPending: journal.inheritedPending,
                previousRunning: journal.previousRunning, runtimeCatalog: journal.runtimeCatalog)) == permit.subject else {
            throw NativeRestoreActivationFailure("personal.previousRecoveryPermit")
        }
    }
    /// Bound personal records remain valid only under the explicit same-gate
    /// recovery permit; a bare journal phase never grants local editing.
    func permitsPreviousRecovery(_ journal: NativeRestoreActivationJournal) throws -> Bool {
        guard let permit = previousRecovery, journal.phase == .restoringPrevious else { return false }
        try validatePreviousRecovery(permit); return true
    }
    func finishPreviousRecovery(_ permit: NativeRestorePreviousRecoveryPermit) throws {
        try control.validate(); try lease.validate()
        guard previousRecovery == permit, permit.instance == ObjectIdentifier(self), permit.lease == lease.identity,
              let journal = try control.read("activation.json", as: NativeRestoreActivationJournal.self),
              journal.phase == .previousRestored, journal.activationID == permit.activationID,
              journal.previous == permit.selection, let seal = journal.seal,
              try Self.recoverySubject(.init(activationID: journal.activationID, previous: journal.previous,
                candidate: journal.candidate, seal: seal, inheritedPending: journal.inheritedPending,
                previousRunning: journal.previousRunning, runtimeCatalog: journal.runtimeCatalog)) == permit.subject,
              try control.read("active-root.json", as: NativeRestoreActivationSelection.self) == permit.selection,
              try NativeRestoreActivationControl.root(plan.root.url) == plan.root else {
            throw NativeRestoreActivationFailure("personal.previousRecoveryIncomplete")
        }
        previousRecovery = nil
    }
    /// Ephemeral permit binding, deliberately independent of the coordinator
    /// actor so existing Startup-only consumers gain no new actor dependency.
    private static func recoverySubject(_ context: NativeRestoreActivationContext) throws -> String {
        struct Subject: Encodable {
            let domain: String, activationID: String
            let previous: NativeRestoreActivationSelection, candidate: NativeRestoreActivationSelection
            let seal: NativeRestoreActivationSeal
            let previousRunning: [String], catalog: [NativeRestoreActivationRuntime]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return NativeMigrationCodec.hash(try encoder.encode(Subject(domain: "NextCRM.personal.previous-recovery-permit.v1",
            activationID: context.activationID, previous: context.previous, candidate: context.candidate,
            seal: context.seal, previousRunning: context.previousRunning, catalog: context.runtimeCatalog)))
    }
    private static func matches(_ journal: NativeRestoreActivationJournal, context: NativeRestoreActivationContext) throws -> Bool {
        guard let seal = journal.seal else { return false }
        return try Self.recoverySubject(.init(activationID: journal.activationID, previous: journal.previous,
            candidate: journal.candidate, seal: seal, inheritedPending: journal.inheritedPending,
            previousRunning: journal.previousRunning, runtimeCatalog: journal.runtimeCatalog)) == Self.recoverySubject(context)
    }

    private static func overlap(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
    private static func controlLocation(_ url: URL) throws -> URL {
        guard url.isFileURL, try NativeMigrationFiles.path(url.lastPathComponent).count == 1,
              let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw NativeRestoreActivationFailure("startup.controlPath")
        }
        defer { free(parent) }
        return URL(fileURLWithPath: String(cString: parent), isDirectory: true).appendingPathComponent(url.lastPathComponent, isDirectory: true)
    }
    private static func fingerprint(_ journal: NativeRestoreActivationJournal?) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(journal)
    }
    private static func validSeal(_ seal: NativeRestoreActivationSeal?) -> Bool {
        guard let seal, UUID(uuidString: seal.snapshotID) != nil, seal.planRows > 0 else { return false }
        let hashes = [seal.restoreSHA256, seal.databaseSHA256, seal.filesManifestSHA256, seal.tablesManifestSHA256,
                      seal.resumePlanSHA256, seal.backupManifestSHA256, seal.schemaSHA256, seal.sourceNamespaceSHA256,
                      seal.stagingNamespaceSHA256, seal.finalNamespaceSHA256] + [seal.publicationMarkerSHA256].compactMap { $0 }
        return hashes.allSatisfy(NativeMigrationCodec.validHash)
    }

    private static func resolve(base: NativeRestoreActivationRoot, selection: NativeRestoreActivationSelection?,
                                journal: NativeRestoreActivationJournal?, runtimes: [NativeRestoreActivationRuntime],
                                inherited: NativeRestoreApplicationInheritedLaunch?) throws -> NativeRestoreApplicationStartupPlan {
        let ids = runtimes.map(\.id), known = Set(ids)
        guard !ids.isEmpty, ids.count <= 128, known.count == ids.count, known.contains("workspace.local"),
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              runtimes.allSatisfy({ $0.events.count <= 256 && Set($0.events).count == $0.events.count && $0.events.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") } }) else {
            throw NativeRestoreActivationFailure("startup.catalog")
        }
        func result(_ root: NativeRestoreActivationRoot, _ mode: NativeRestoreApplicationStartupMode,
                    _ permitted: [String], _ review: Bool) -> NativeRestoreApplicationStartupPlan {
            .init(root: root, selection: selection, mode: mode, permitted: permitted.sorted(),
                  held: ids.filter { !permitted.contains($0) }.sorted(), activationID: journal?.activationID, requiresReview: review)
        }
        guard let selection else {
            guard journal == nil, inherited == nil else { throw NativeRestoreActivationFailure("startup.missingSelection") }
            return result(base, .ordinary, ids, false)
        }
        guard UUID(uuidString: selection.generation) != nil else { throw NativeRestoreActivationFailure("startup.generation") }
        guard let journal else {
            // The coordinator creates the initial old-root pointer before its
            // first journal write; a crash in that gap keeps ordinary startup.
            guard selection.root == base, inherited == nil else { throw NativeRestoreActivationFailure("startup.missingJournal") }
            return result(base, .ordinary, ids, false)
        }
        guard journal.formatVersion == 1, UUID(uuidString: journal.activationID) != nil,
              UUID(uuidString: journal.previous.generation) != nil, UUID(uuidString: journal.candidate.generation) != nil,
              journal.previous != journal.candidate,
              !Self.overlap(journal.previous.root.path, journal.candidate.root.path),
              !(journal.previous.root.device == journal.candidate.root.device && journal.previous.root.inode == journal.candidate.root.inode),
              selection == journal.previous || selection == journal.candidate else {
            throw NativeRestoreActivationFailure("startup.journalSelection")
        }
        guard validSeal(journal.seal) else { throw NativeRestoreActivationFailure("startup.missingOrInvalidSeal") }
        guard journal.runtimeCatalog.sorted(by: { $0.id < $1.id }) == runtimes.sorted(by: { $0.id < $1.id }) else {
            throw NativeRestoreActivationFailure("startup.catalogChanged")
        }
        func validPolicy(_ values: [String]) -> Bool { values.count == Set(values).count && Set(values).isSubset(of: known) }
        guard validPolicy(journal.previousRunning), validPolicy(journal.permittedRuntimes), validPolicy(journal.heldRuntimes) else {
            throw NativeRestoreActivationFailure("startup.policy")
        }
        if selection == journal.candidate {
            // ready is valid only as the atomic pointer-commit crash window.
            guard [.ready, .committed, .starting, .active, .activeDegraded].contains(journal.phase) else { throw NativeRestoreActivationFailure("startup.contradictoryJournal") }
            guard Set(journal.permittedRuntimes).isDisjoint(with: journal.heldRuntimes),
                  Set(journal.permittedRuntimes).union(journal.heldRuntimes) == known else { throw NativeRestoreActivationFailure("startup.policyCoverage") }
        }
        if let inherited {
            let expected: [String]
            if selection == journal.candidate, [.committed, .starting, .activeDegraded].contains(journal.phase) {
                expected = journal.permittedRuntimes
                guard Set(expected).isDisjoint(with: journal.heldRuntimes), Set(expected).union(journal.heldRuntimes) == known else {
                    throw NativeRestoreActivationFailure("startup.policyCoverage")
                }
            } else if selection == journal.previous, journal.phase == .restoringPrevious {
                expected = journal.previousRunning
            } else { throw NativeRestoreActivationFailure("startup.handoffPhase") }
            guard inherited.selection == selection, inherited.activationID == journal.activationID,
                  validPolicy(inherited.permitted), Set(inherited.permitted) == Set(expected) else {
                throw NativeRestoreActivationFailure("startup.handoffBinding")
            }
            try inherited.validateApproval(journal)
            return result(selection.root, .approvedHandoff, expected, selection == journal.candidate && !journal.heldRuntimes.isEmpty)
        }
        if selection == journal.candidate {
            guard journal.phase != .previousRestored else { throw NativeRestoreActivationFailure("startup.contradictoryJournal") }
            // A past successful startup is not fresh proof of provider state.
            // Even phase=active comes back with external effects held.
            return result(selection.root, .restoredHeld, ["workspace.local"], true)
        }
        if journal.phase == .previousRestored { return result(selection.root, .previousPolicy, journal.previousRunning, false) }
        guard ![.committed, .starting, .active, .activeDegraded].contains(journal.phase) else {
            throw NativeRestoreActivationFailure("startup.contradictoryJournal")
        }
        return result(selection.root, .recoveryRequired, [], true)
    }
}

/// No public initializer, Codable representation or command-line conversion.
struct NativeRestorePreviousRecoveryPermit: Equatable {
    fileprivate let instance: ObjectIdentifier
    fileprivate let lease: NativeRestoreHostLeaseIdentity
    fileprivate let activationID: String
    fileprivate let selection: NativeRestoreActivationSelection
    fileprivate let subject: String
    fileprivate init(instance: ObjectIdentifier, lease: NativeRestoreHostLeaseIdentity, activationID: String,
                     selection: NativeRestoreActivationSelection, subject: String) {
        self.instance=instance; self.lease=lease; self.activationID=activationID; self.selection=selection; self.subject=subject
    }
}
