import Foundation
import CryptoKit

enum NativeRestoreHostConversationFailure: String, Error, LocalizedError {
    case invalidValue, oversized, wrongContext, outOfOrder, reused, declined, unauthorized, staleApproval, incompleteDrain, peerClosed, cancelled, timedOut, abnormalExit
    var errorDescription: String? { "復元の引継ぎを中止しました（\(rawValue)）。記録された状態を確認してください。" }
}

/// Supplied by trusted host composition, never reconstructed from CLI actor/role.
struct NativeRestoreHostConversationSession: Codable, Equatable {
    var version = 1
    let sessionID: String
    let nonce: String
    let requestID: String
    let parent: NativeRestoreHostProcessIdentity
    let lease: NativeRestoreHostLeaseIdentity
    let previous: NativeRestoreActivationSelection
    let candidate: NativeRestoreActivationSelection
}

/// Copies the EXACT context received by the coordinator's drain(ctx) callback.
/// Neither host may manufacture a new generation or omit inherited pending work.
struct NativeRestoreHostConversationContext: Codable, Equatable {
    let activationID: String
    let previous: NativeRestoreActivationSelection
    let candidate: NativeRestoreActivationSelection
    let seal: NativeRestoreActivationSeal
    let inheritedPending: [NativeBackupPending]
    let previousRunning: [String]
    let runtimeCatalog: [NativeRestoreActivationRuntime]
    let writerParticipants: [String]
    init(coordinator context: NativeRestoreActivationContext, writerParticipants: [String]) {
        activationID = context.activationID; previous = context.previous; candidate = context.candidate
        seal = context.seal; inheritedPending = context.inheritedPending; previousRunning = context.previousRunning
        runtimeCatalog = context.runtimeCatalog; self.writerParticipants = writerParticipants
    }
    var coordinatorContext: NativeRestoreActivationContext {
        .init(activationID: activationID, previous: previous, candidate: candidate, seal: seal,
              inheritedPending: inheritedPending, previousRunning: previousRunning, runtimeCatalog: runtimeCatalog)
    }
    func subjectSHA256() throws -> String {
        var budget = NativeRestoreHostWireBudget(); try budget.context(self)
        return try NativeRestoreHostConversationCodec.digest(self, domain: "NextCRM.restore.host.full-context.v1")
    }
}

struct NativeRestoreHostFreshAuthorization: Codable, Equatable {
    let principalID: String
    let subjectSHA256: String
    let evidenceSHA256: String
    let authenticatedAt: Double
    let validUntil: Double
}
struct NativeRestoreHostSourceTrust: Codable, Equatable {
    enum Disposition: String, Codable { case verified, explicitlyAcceptedUnverified }
    let disposition: Disposition
    let evidenceSHA256: String
}
struct NativeRestoreHostRuntimeChoice: Codable, Equatable {
    enum Disposition: String, Codable { case hold, requestResumeAfterCoordinatorReview }
    let runtimeID: String
    let disposition: Disposition
    let evidenceSHA256: String
}
struct NativeRestoreHostReviewHold: Codable, Equatable {
    /// Wire representation of the existing policy's six distinct review items.
    enum Kind: String, Codable, CaseIterable { case sourceProvenance, credentials, jobs, relayAndPluginState, pendingAssets, runtimeStartup }
    enum Decision: String, Codable { case keepHeld }
    let kind: Kind
    let decision: Decision
    let evidenceSHA256: String
}
struct NativeRestoreHostUIApproval: Codable, Equatable {
    let subjectSHA256: String
    let decisionEvidenceSHA256: String
    let approvedAt: Double
    /// The original displayed decision deadline; reauthorization cannot extend it.
    let validUntil: Double
    let sourceTrust: NativeRestoreHostSourceTrust
    let reviewHolds: [NativeRestoreHostReviewHold]
    let runtimeChoices: [NativeRestoreHostRuntimeChoice]
}
enum NativeRestoreHostUIDecision { case declined, approved(NativeRestoreHostUIApproval) }
struct NativeRestoreHostApprovalEnvelope: Codable, Equatable {
    let binding: NativeRestoreHostConversationHeader
    let authorization: NativeRestoreHostFreshAuthorization
    let decision: NativeRestoreHostUIApproval
}
struct NativeRestoreHostRetainedDatabaseHandle: Codable, Equatable {
    /// Only a connection confined to the named process. This is NOT a way to
    /// excuse a worker, exported/inherited FD, or a connection in another process.
    enum Purpose: String, Codable { case processLocalSQLiteConnectionNeverExported }
    let id: String
    let participant: String
    let root: NativeRestoreActivationRoot
    let owner: NativeRestoreHostProcessIdentity
    let purpose: Purpose
}
struct NativeRestoreHostDrainReport: Codable {
    /// Final-report invariant: all producers closed admission before joining
    /// their accepted work, all joins finished, and none will reopen afterward.
    let acceptedWritesFenced: Bool
    /// PRE-EXIT report. Its writable handle count is honest and may be nonzero.
    /// Every residual handle must be accounted for in this bounded inventory.
    let retainedDatabaseHandles: [NativeRestoreHostRetainedDatabaseHandle]
    let drain: NativeRestoreActivationDrain
}
struct NativeRestoreHostRegistrationReceipt: Codable, Equatable {
    let id: String
    let process: NativeRestoreHostProcessIdentity
    init(_ value: NativeRestoreHostExitRegistration) { id = value.id.uuidString.lowercased(); process = value.process }
}
enum NativeRestoreHostConversationPhase: String, Codable {
    case registeredContext, approval, accepted, drained, exitAllowed, cancelled
    var ordinal: Int { switch self { case .registeredContext: return 0; case .approval: return 1; case .accepted: return 2; case .drained: return 3; case .exitAllowed: return 4; case .cancelled: return 5 } }
}
struct NativeRestoreHostConversationHeader: Codable, Equatable {
    let session: NativeRestoreHostConversationSession
    let phase: NativeRestoreHostConversationPhase
    let sequence: Int
    let subjectSHA256: String
    let registration: NativeRestoreHostRegistrationReceipt
}
struct NativeRestoreHostConversationMessage: Codable {
    let header: NativeRestoreHostConversationHeader
    let context: NativeRestoreHostConversationContext?
    let approval: NativeRestoreHostApprovalEnvelope?
    let drain: NativeRestoreHostDrainReport?
    let acknowledgedSHA256: String?
    init(session: NativeRestoreHostConversationSession, phase: NativeRestoreHostConversationPhase,
         subject: String, registration: NativeRestoreHostRegistrationReceipt,
         context: NativeRestoreHostConversationContext? = nil, approval: NativeRestoreHostApprovalEnvelope? = nil,
         drain: NativeRestoreHostDrainReport? = nil, acknowledgedSHA256: String? = nil) {
        header = .init(session: session, phase: phase, sequence: phase.ordinal, subjectSHA256: subject, registration: registration)
        self.context = context; self.approval = approval; self.drain = drain; self.acknowledgedSHA256 = acknowledgedSHA256
    }
    /// Must run BEFORE any JSONEncoder call, including signatures/digests.
    func validateBounds() throws {
        var budget = NativeRestoreHostWireBudget(); try budget.session(header.session)
        try budget.hash(header.subjectSHA256); try budget.uuid(header.registration.id)
        guard header.registration.process == header.session.parent, header.sequence == header.phase.ordinal else { throw NativeRestoreHostConversationFailure.wrongContext }
        let flags = [context != nil, approval != nil, drain != nil, acknowledgedSHA256 != nil]
        let expected: [Bool]
        switch header.phase {
        case .registeredContext: expected = [true,false,false,false]
        case .approval: expected = [false,true,false,false]
        case .accepted, .exitAllowed: expected = [false,false,false,true]
        case .drained: expected = [false,false,true,false]
        case .cancelled: expected = [false,false,false,false]
        }
        guard flags == expected else { throw NativeRestoreHostConversationFailure.outOfOrder }
        if let context { try budget.context(context) }
        if let approval { guard approval.binding == header else { throw NativeRestoreHostConversationFailure.wrongContext }; try budget.approval(approval) }
        if let drain { try budget.drain(drain) }
        if let acknowledgedSHA256 { try budget.hash(acknowledgedSHA256) }
    }
}

struct NativeRestoreHostFinalQuiescenceEvidence: Codable {
    let version: Int
    let session: NativeRestoreHostConversationSession
    let subjectSHA256: String
    let registration: NativeRestoreHostRegistrationReceipt
    let parentReportSHA256: String
    let cleanPeerEOF: Bool
    let normalExitWaitStatus: Int32
    let processLocalSQLiteHandlesReleased: Int
}

enum NativeRestoreHostConversationCodec {
    /// Caller must have performed the corresponding field budget validation.
    fileprivate static func digest<T: Encodable>(_ value: T, domain: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var bytes = Data(domain.utf8); bytes.append(0); bytes.append(try encoder.encode(value))
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func approvalDigest(_ approval: NativeRestoreHostApprovalEnvelope) throws -> String {
        var budget = NativeRestoreHostWireBudget(); try budget.approval(approval)
        return try digest(approval, domain: "NextCRM.restore.host.approval.v1")
    }
    static func drainDigest(_ drain: NativeRestoreHostDrainReport) throws -> String {
        var budget = NativeRestoreHostWireBudget(); try budget.drain(drain)
        return try digest(drain, domain: "NextCRM.restore.host.drain.v1")
    }
    static func finalQuiescenceDigest(_ proof: NativeRestoreHostFinalQuiescenceEvidence) throws -> String {
        var budget = NativeRestoreHostWireBudget(); try budget.session(proof.session)
        try budget.hash(proof.subjectSHA256); try budget.uuid(proof.registration.id); try budget.hash(proof.parentReportSHA256)
        guard proof.version == 1, proof.registration.process == proof.session.parent, proof.cleanPeerEOF,
              proof.normalExitWaitStatus == 0, (0...256).contains(proof.processLocalSQLiteHandlesReleased) else {
            throw NativeRestoreHostConversationFailure.invalidValue
        }
        return try digest(proof, domain: "NextCRM.restore.host.final-quiescence.v1")
    }

}

/// Conservative JSON upper bound: UTF-8 byte x6 covers every escape, plus
/// per-record/key overhead. No encoder is invoked to discover an oversize value.
struct NativeRestoreHostWireBudget {
    private var bytes = 4096
    mutating func add(_ amount: Int) throws {
        guard amount >= 0, amount <= 240_000, bytes <= 240_000 - amount else { throw NativeRestoreHostConversationFailure.oversized }; bytes += amount
    }
    mutating func text(_ value: String, maximum: Int = 256, empty: Bool = false) throws {
        let count = value.utf8.count
        guard (empty || count > 0), count <= maximum, !value.utf8.contains(0) else { throw NativeRestoreHostConversationFailure.invalidValue }
        try add(count * 6 + 4)
    }
    mutating func hash(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw NativeRestoreHostConversationFailure.invalidValue }; try text(value)
    }
    mutating func uuid(_ value: String) throws {
        guard value.utf8.count == 36, UUID(uuidString: value)?.uuidString.lowercased() == value else { throw NativeRestoreHostConversationFailure.invalidValue }; try text(value)
    }
    mutating func identifiers(_ values: [String], maximum: Int, empty: Bool = true) throws {
        guard values.count <= maximum, (empty || !values.isEmpty), Set(values).count == values.count else { throw NativeRestoreHostConversationFailure.invalidValue }
        try add(values.count * 8); for value in values { try text(value) }
    }
    mutating func selection(_ value: NativeRestoreActivationSelection) throws {
        try uuid(value.generation); try text(value.root.path, maximum: 4096)
        guard value.root.path.hasPrefix("/"), value.root.device > 0, value.root.inode > 0,
              !value.root.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw NativeRestoreHostConversationFailure.invalidValue }; try add(192)
    }
    mutating func session(_ value: NativeRestoreHostConversationSession) throws {
        guard value.version == 1, value.parent.pid > 1, value.parent.uid == value.lease.uid,
              value.parent.startSeconds > 0, value.parent.startMicroseconds < 1_000_000,
              value.lease.controlDevice > 0, value.lease.controlInode > 0,
              value.lease.leaseDevice > 0, value.lease.leaseInode > 0,
              value.previous != value.candidate, value.previous.root != value.candidate.root else { throw NativeRestoreHostConversationFailure.invalidValue }
        try uuid(value.sessionID); try uuid(value.requestID); try hash(value.nonce)
        try selection(value.previous); try selection(value.candidate); try add(512)
    }
    mutating func context(_ value: NativeRestoreHostConversationContext) throws {
        try uuid(value.activationID); try selection(value.previous); try selection(value.candidate)
        try uuid(value.seal.snapshotID)
        for hashValue in [value.seal.restoreSHA256,value.seal.databaseSHA256,value.seal.filesManifestSHA256,value.seal.tablesManifestSHA256,value.seal.resumePlanSHA256,value.seal.backupManifestSHA256,value.seal.schemaSHA256,value.seal.sourceNamespaceSHA256,value.seal.stagingNamespaceSHA256,value.seal.finalNamespaceSHA256] { try hash(hashValue) }
        if let hashValue = value.seal.publicationMarkerSHA256 { try hash(hashValue) }
        guard value.seal.planRows >= 0, value.inheritedPending.count <= 32,
              Set(value.inheritedPending.map(\.rawValue)).count == value.inheritedPending.count,
              value.runtimeCatalog.count <= 128 else { throw NativeRestoreHostConversationFailure.invalidValue }
        try add(1024); for item in value.inheritedPending { try text(item.rawValue) }
        try identifiers(value.previousRunning, maximum: 128)
        try identifiers(value.writerParticipants, maximum: 256, empty: false)
        try identifiers(value.runtimeCatalog.map(\.id), maximum: 128)
        for runtime in value.runtimeCatalog { try add(160); try identifiers(runtime.events, maximum: 256) }
        guard Set(value.previousRunning).isSubset(of: Set(value.runtimeCatalog.map(\.id))) else { throw NativeRestoreHostConversationFailure.invalidValue }
    }
    mutating func authorization(_ value: NativeRestoreHostFreshAuthorization) throws {
        try text(value.principalID); try hash(value.subjectSHA256); try hash(value.evidenceSHA256)
        guard value.authenticatedAt.isFinite, value.validUntil.isFinite else { throw NativeRestoreHostConversationFailure.invalidValue }; try add(256)
    }
    mutating func decision(_ value: NativeRestoreHostUIApproval) throws {
        try hash(value.subjectSHA256); try hash(value.decisionEvidenceSHA256); try hash(value.sourceTrust.evidenceSHA256)
        guard value.approvedAt.isFinite, value.validUntil.isFinite, value.validUntil > value.approvedAt,
              value.validUntil - value.approvedAt <= 300, value.runtimeChoices.count <= 128, value.reviewHolds.count == NativeRestoreHostReviewHold.Kind.allCases.count, Set(value.reviewHolds.map(\.kind)) == Set(NativeRestoreHostReviewHold.Kind.allCases) else { throw NativeRestoreHostConversationFailure.invalidValue }
        for hold in value.reviewHolds { try hash(hold.evidenceSHA256); try add(256) }
        try identifiers(value.runtimeChoices.map(\.runtimeID), maximum: 128)
        for choice in value.runtimeChoices { try hash(choice.evidenceSHA256); try add(256) }; try add(512)
    }
    mutating func approval(_ value: NativeRestoreHostApprovalEnvelope) throws {
        try session(value.binding.session); try hash(value.binding.subjectSHA256); try uuid(value.binding.registration.id)
        guard value.binding.phase == .approval, value.binding.sequence == NativeRestoreHostConversationPhase.approval.ordinal,
              value.binding.registration.process == value.binding.session.parent,
              value.binding.subjectSHA256 == value.authorization.subjectSHA256,
              value.binding.subjectSHA256 == value.decision.subjectSHA256 else { throw NativeRestoreHostConversationFailure.wrongContext }
        try authorization(value.authorization); try decision(value.decision)
    }
    mutating func drain(_ value: NativeRestoreHostDrainReport) throws {
        guard value.retainedDatabaseHandles.count <= 256, value.drain.openWritableHandles >= 0,
              value.drain.openWritableHandles == value.retainedDatabaseHandles.count else { throw NativeRestoreHostConversationFailure.incompleteDrain }
        try identifiers(value.retainedDatabaseHandles.map(\.id), maximum:256)
        for handle in value.retainedDatabaseHandles {
            try text(handle.participant); try text(handle.root.path, maximum:4096); try add(512)
            guard handle.root.device > 0, handle.root.inode > 0, handle.owner.pid > 1,
                  handle.owner.startSeconds > 0, handle.owner.startMicroseconds < 1_000_000 else { throw NativeRestoreHostConversationFailure.invalidValue }
        }
        try text(value.drain.root.path, maximum: 4096); try identifiers(value.drain.participants, maximum: 256, empty: false)
        try identifiers(value.drain.previouslyRunning, maximum: 128); try hash(value.drain.evidenceSHA256); try add(512)
    }
}
