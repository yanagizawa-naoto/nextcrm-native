import Foundation

enum NativeRestoreActivationPhase: String, Codable {
    case selected, draining, drained, validating, reviewing, ready, committed, starting, active, activeDegraded
    case restoringPrevious, previousRestored, recoveryRequired
}
struct NativeRestoreActivationFailure: Error, LocalizedError {
    let code: String
    var errorDescription: String? { "復元の切り替えを完了できませんでした（\(code)）。記録された状態を確認してください。" }
    init(_ code: String) { self.code = code }
}
struct NativeRestoreActivationRoot: Codable, Equatable {
    let path: String
    let device: UInt64
    let inode: UInt64
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}
struct NativeRestoreActivationSelection: Codable, Equatable {
    let generation: String
    let root: NativeRestoreActivationRoot
}
struct NativeRestoreActivationSeal: Codable, Equatable {
    let snapshotID: String
    let restoreSHA256: String
    let databaseSHA256: String
    let filesManifestSHA256: String
    let tablesManifestSHA256: String
    let resumePlanSHA256: String
    let backupManifestSHA256: String
    let schemaSHA256: String
    let sourceNamespaceSHA256: String
    let stagingNamespaceSHA256: String
    let finalNamespaceSHA256: String
    let publicationMarkerSHA256: String?
    let planRows: Int64
}
struct NativeRestoreActivationContext {
    let activationID: String
    let previous: NativeRestoreActivationSelection
    let candidate: NativeRestoreActivationSelection
    let seal: NativeRestoreActivationSeal
    let inheritedPending: [NativeBackupPending]
    let previousRunning: [String]
    let runtimeCatalog: [NativeRestoreActivationRuntime]
}
/// Registered at composition, not inferred from restored settings. `writers`
/// includes editors/drafts, callbacks, listeners, workers, cleanup and DB handles.
struct NativeRestoreActivationRuntime: Codable, Equatable {
    let id: String
    let events: [String]
    let canProduceExternalEffects: Bool
}
struct NativeRestoreActivationDrain: Codable {
    let root: NativeRestoreActivationRoot
    let participants: [String]
    let previouslyRunning: [String]
    let unfinishedTasks: Int
    let openWritableHandles: Int
    let unsavedEditors: Int
    let pendingCallbacks: Int
    /// A digest of the host's actual drain report, not a function/feature name.
    let evidenceSHA256: String
}
struct NativeRestoreActivationEvidence: Codable {
    let kind: String
    let subjectSHA256: String
    let evidenceSHA256: String
    let checkedAt: Date
    let validUntil: Date
    let blockedRuntimes: [String]
    let disposition: String // verified / explicitlyDeferred
}
struct NativeRestoreActivationRowDecision: Codable {
    let rowSHA256: String
    let evidenceSHA256: String
    let disposition: String // preserved / reconciled / explicitlyDeferred
    let blockedRuntimes: [String]
}
struct NativeRestoreActivationStartup: Codable, Equatable {
    let started: [String]
    let held: [String]
    let evidenceSHA256: String
}
/// Only the fixed personal-local recovery mode can differ from previousRunning.
/// The trusted personal host confirms this after real App readiness. Historical
/// configured owners remain unchanged in the journal.
struct NativeRestorePersonalLocalRecovery: Codable, Equatable {
    let version: Int
    let contextSHA256: String
    let personalGrantSHA256: String
    let runtimeRecordSHA256: String
    let startup: NativeRestoreActivationStartup
}
struct NativeRestoreActivationJournal: Codable {
    var formatVersion = 1
    let activationID: String
    var phase: NativeRestoreActivationPhase
    let previous: NativeRestoreActivationSelection
    let candidate: NativeRestoreActivationSelection
    var seal: NativeRestoreActivationSeal?
    var inheritedPending: [NativeBackupPending] = []
    var previousRunning: [String] = []
    var runtimeCatalog: [NativeRestoreActivationRuntime] = []
    var drain: NativeRestoreActivationDrain?
    var evidence: [NativeRestoreActivationEvidence] = []
    var decisionsSHA256: String?
    var decisionsFile: String?
    var decisionsRows: Int64 = 0
    var permittedRuntimes: [String] = []
    var heldRuntimes: [String] = []
    var startup: NativeRestoreActivationStartup?
    var recoveryStartup: NativeRestorePersonalLocalRecovery?
    var failureCode: String?
}
struct NativeRestoreActivationResult {
    let journal: NativeRestoreActivationJournal
    let selection: NativeRestoreActivationSelection
    var activated: Bool { selection == journal.candidate }
}

/// Trusted host/provider boundary. The coordinator checks coverage, root binding,
/// evidence lifetime and durable commit ordering. These callbacks must do real
/// work; no default-success implementation or production fake is supplied.
struct NativeRestoreActivationHooks {
    let runtimes: [NativeRestoreActivationRuntime]
    let writerParticipants: [String]
    let authorize: () async throws -> Void
    let capturePreviousRunning: (NativeRestoreActivationContext) async throws -> [String]
    let drain: (NativeRestoreActivationContext) async throws -> NativeRestoreActivationDrain
    /// Cold recovery must prove no editor, task, callback, listener or writable
    /// handle is already using the selected root. Calling this on a live host
    /// must fail; a previous journal's drain report is not current evidence.
    let verifyRecoveryQuiescence: (NativeRestoreActivationContext, NativeRestoreActivationSelection) async throws -> NativeRestoreActivationDrain
    let review: (String, NativeRestoreActivationContext) async throws -> NativeRestoreActivationEvidence
    let reviewRow: (NativeRestorePlanEntry, String, NativeRestoreActivationContext) async throws -> NativeRestoreActivationRowDecision
    /// Opens/constructs the candidate with every scheduler/listener/effect paused.
    /// It must not mutate business rows, jobs or credentials during preparation.
    let preparePaused: (NativeRestoreActivationContext, [String]) async throws -> Void
    /// Called only after the durable active-root pointer chooses the candidate.
    let resumeCommitted: (NativeRestoreActivationContext, [String]) async throws -> NativeRestoreActivationStartup
    let closeCandidate: (NativeRestoreActivationContext) async throws -> Void
    let resumePrevious: (NativeRestoreActivationContext, NativeRestoreActivationDrain?) async throws -> NativeRestoreActivationStartup
    /// Nil retains exact previous-policy recovery. This is never used by live
    /// compensation or candidate startup; no arbitrary runtime permit is added.
    var confirmPersonalLocalRecovery: ((NativeRestoreActivationContext, NativeRestoreActivationStartup) async throws -> NativeRestorePersonalLocalRecovery)? = nil
}
