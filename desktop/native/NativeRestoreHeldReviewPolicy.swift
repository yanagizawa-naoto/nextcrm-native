import Foundation

enum NativeRestoreHeldReviewKind: String, Codable, CaseIterable {
    case sourceProvenance, credentials, jobs, relayAndPluginState, pendingAssets, runtimeStartup
}
struct NativeRestoreReviewAuthority {
    let actorID: String
    /// Digest of a fresh authenticated ACTIVE, non-banned administrator check.
    /// The host supplies the check; a saved UI identity/email is insufficient.
    let evidenceSHA256: String
}
struct NativeRestoreHeldReviewPrompt: Codable {
    let fullSubjectSHA256: String
    let activationSubjectSHA256: String
    let snapshotID: String
    let sourceNamespaceSHA256: String
    let finalNamespaceSHA256: String
    let inheritedPending: [NativeBackupPending]
    let previousRunning: [String]
    let kinds: [NativeRestoreHeldReviewKind]
    let heldRuntimes: [String]
    let validUntil: Date
}
enum NativeRestoreSourceTrustChoice {
    case reject
    /// Deliberate operator trust of these displayed bytes/root; not a claim of a signature.
    case trustReviewedCandidate(fullSubjectSHA256: String)
}
struct NativeRestoreExplicitHoldChoice {
    enum Decision: String, Codable { case keepHeld, cancel }
    let kind: NativeRestoreHeldReviewKind
    let fullSubjectSHA256: String
    let decision: Decision
}
/// Session-bound user approvals, never a live-provider validator. No approval is
/// loaded from restored metadata and no default-success UI callback is supplied.
actor NativeRestoreHeldReviewPolicy {
    typealias Authorize = () async throws -> NativeRestoreReviewAuthority
    private struct Binding: Codable {
        let version: String, activationSubject: String
        let inheritedPending: [NativeBackupPending], writerParticipants: [String]
    }
    private struct Approval: Codable {
        let nonce: String, fullSubjectSHA256: String, actorID: String, authoritySHA256: String
        let kind: NativeRestoreHeldReviewKind
        let sourceTrust: String, decision: String
        let checkedAt: Date, validUntil: Date
        let blockedRuntimes: [String]
    }
    private struct RowProof: Codable {
        let fullSubjectSHA256: String, rowSHA256: String, approvalSHA256: String
        let blockedRuntimes: [String]
        let disposition: String
    }
    private let prompt: NativeRestoreHeldReviewPrompt
    private let approvals: [NativeRestoreHeldReviewKind: Approval]
    private let authorize: Authorize, clock: () -> Date
    private let sourceEvidence: NativeRestoreActivationEvidence?
    private var reviewed = Set<NativeRestoreHeldReviewKind>(), busy = false
    private init(prompt: NativeRestoreHeldReviewPrompt, approvals: [NativeRestoreHeldReviewKind: Approval],
                 sourceEvidence: NativeRestoreActivationEvidence?, authorize: @escaping Authorize, clock: @escaping () -> Date) {
        self.prompt=prompt; self.approvals=approvals; self.sourceEvidence=sourceEvidence; self.authorize=authorize; self.clock=clock
    }
    static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return NativeMigrationCodec.hash(try encoder.encode(value))
    }
    static func binding(_ context: NativeRestoreActivationContext) throws -> String {
        try NativeRestoreRuntimeCatalog.validate(context)
        return try hash(Binding(version:NativeRestoreRuntimeCatalog.version,activationSubject:NativeRestoreActivation.subject(context),
                                inheritedPending:context.inheritedPending,writerParticipants:NativeRestoreRuntimeCatalog.writerParticipants))
    }
    private static func authority(_ value: NativeRestoreReviewAuthority) throws {
        guard !value.actorID.isEmpty,value.actorID.utf8.count<=256,!value.actorID.contains("\0"),NativeMigrationCodec.validHash(value.evidenceSHA256) else { throw NativeRestoreActivationFailure("policy.authority") }
    }
    private static func validateSource(_ value: NativeRestoreActivationEvidence, context: NativeRestoreActivationContext, now: Date) throws {
        guard value.kind == NativeRestoreHeldReviewKind.sourceProvenance.rawValue,
              value.subjectSHA256 == (try NativeRestoreActivation.subject(context)),NativeMigrationCodec.validHash(value.evidenceSHA256),
              value.checkedAt<=now,value.validUntil>now,value.checkedAt<=value.validUntil,
              ["verified","explicitlyDeferred"].contains(value.disposition),
              Set(value.blockedRuntimes).count == value.blockedRuntimes.count,
              Set(value.blockedRuntimes).isSubset(of:Set(NativeRestoreRuntimeCatalog.ids)),
              value.disposition != "explicitlyDeferred" || !value.blockedRuntimes.isEmpty else { throw NativeRestoreActivationFailure("policy.sourceEvidence") }
    }
    /// Both callbacks must represent actual user decisions. Holding every worker
    /// alone cannot establish trust in an unsigned/unknown-source candidate.
    /// Optional sourceEvidence is independently produced by the host and passed
    /// through unchanged; this adapter never manufactures a `verified` receipt.
    static func request(context: NativeRestoreActivationContext, validity: TimeInterval = 300,
                        clock: @escaping () -> Date = Date.init, authorize: @escaping Authorize,
                        confirmSource: (NativeRestoreHeldReviewPrompt) async throws -> NativeRestoreSourceTrustChoice,
                        chooseHolds: (NativeRestoreHeldReviewPrompt) async throws -> [NativeRestoreExplicitHoldChoice],
                        sourceEvidence: NativeRestoreActivationEvidence? = nil) async throws -> NativeRestoreHeldReviewPolicy {
        guard validity.isFinite,validity>0,validity<=900 else { throw NativeRestoreActivationFailure("policy.lifetime") }
        let first=try await authorize();try authority(first);try Task.checkCancellation()
        let now=clock(),full=try binding(context)
        let prompt=NativeRestoreHeldReviewPrompt(fullSubjectSHA256:full,activationSubjectSHA256:try NativeRestoreActivation.subject(context),
            snapshotID:context.seal.snapshotID,sourceNamespaceSHA256:context.seal.sourceNamespaceSHA256,finalNamespaceSHA256:context.seal.finalNamespaceSHA256,
            inheritedPending:context.inheritedPending,previousRunning:context.previousRunning,kinds:NativeRestoreHeldReviewKind.allCases,
            heldRuntimes:NativeRestoreRuntimeCatalog.heldAutomatic,validUntil:now.addingTimeInterval(validity))
        guard case let .trustReviewedCandidate(subject)=try await confirmSource(prompt),subject==full else { throw NativeRestoreActivationFailure("policy.sourceNotTrusted") }
        try Task.checkCancellation()
        let decisions=try await chooseHolds(prompt)
        let last=try await authorize();try authority(last);try Task.checkCancellation()
        guard last.actorID==first.actorID,clock()>=now,clock()<prompt.validUntil,
              decisions.count==prompt.kinds.count,Set(decisions.map(\.kind))==Set(prompt.kinds),
              decisions.allSatisfy({$0.fullSubjectSHA256==full && $0.decision == .keepHeld}) else { throw NativeRestoreActivationFailure("policy.explicitApproval") }
        if let sourceEvidence { try validateSource(sourceEvidence,context:context,now:clock()) }
        let nonce=UUID().uuidString.lowercased()
        let approvals=Dictionary(uniqueKeysWithValues:decisions.map { decision in
            (decision.kind,Approval(nonce:nonce,fullSubjectSHA256:full,actorID:last.actorID,authoritySHA256:last.evidenceSHA256,
                kind:decision.kind,sourceTrust:"operatorTrustOfDisplayedCandidateNotCryptographicAttestation",decision:decision.decision.rawValue,
                checkedAt:now,validUntil:prompt.validUntil,blockedRuntimes:NativeRestoreRuntimeCatalog.blockedRuntimes(for:decision.kind)))
        })
        return .init(prompt:prompt,approvals:approvals,sourceEvidence:sourceEvidence,authorize:authorize,clock:clock)
    }
    private func current(_ context: NativeRestoreActivationContext) async throws {
        guard try Self.binding(context)==prompt.fullSubjectSHA256,clock()<prompt.validUntil else { throw NativeRestoreActivationFailure("policy.subjectOrExpiry") }
        let authority=try await authorize();try Self.authority(authority);try Task.checkCancellation()
        guard authority.actorID==approvals[.sourceProvenance]?.actorID,clock()>=approvals[.sourceProvenance]!.checkedAt,
              clock()<prompt.validUntil else { throw NativeRestoreActivationFailure("policy.authorityOrExpiry") }
    }
    func review(_ kind: String, context: NativeRestoreActivationContext) async throws -> NativeRestoreActivationEvidence {
        guard let kind=NativeRestoreHeldReviewKind(rawValue:kind),!busy,!reviewed.contains(kind),let approval=approvals[kind] else { throw NativeRestoreActivationFailure("policy.duplicateOrUnknownReview") }
        busy=true;defer{busy=false};try await current(context)
        if kind == .sourceProvenance,let sourceEvidence {
            try Self.validateSource(sourceEvidence,context:context,now:clock());reviewed.insert(kind);return sourceEvidence
        }
        reviewed.insert(kind)
        return .init(kind:kind.rawValue,subjectSHA256:prompt.activationSubjectSHA256,evidenceSHA256:try Self.hash(approval),
                     checkedAt:approval.checkedAt,validUntil:approval.validUntil,blockedRuntimes:approval.blockedRuntimes,disposition:"explicitlyDeferred")
    }
    func reviewRow(_ row: NativeRestorePlanEntry, rowSHA256: String, context: NativeRestoreActivationContext) async throws -> NativeRestoreActivationRowDecision {
        guard !busy,reviewed==Set(NativeRestoreHeldReviewKind.allCases),row.count>=0,
              NativeMigrationCodec.validHash(rowSHA256),try Self.hash(row)==rowSHA256 else { throw NativeRestoreActivationFailure("policy.row") }
        busy=true;defer{busy=false};try await current(context)
        let blocked=NativeRestoreRuntimeCatalog.blockedRuntimes(for:row)
        let proof=RowProof(fullSubjectSHA256:prompt.fullSubjectSHA256,rowSHA256:rowSHA256,approvalSHA256:try Self.hash(approvals[.jobs]!),
                           blockedRuntimes:blocked,disposition:"explicitlyDeferred")
        return .init(rowSHA256:rowSHA256,evidenceSHA256:try Self.hash(proof),disposition:"explicitlyDeferred",blockedRuntimes:blocked)
    }
    /// Compensation uses this preserved policy only. Candidate permission is
    /// derived from review holds, never from which old schedulers were running.
    func previousRunning(context: NativeRestoreActivationContext) throws -> [String] {
        // Expiring candidate approval must not erase the old rollback policy.
        // This is data only; host compensation still proves real authorization/startup.
        guard try Self.binding(context)==prompt.fullSubjectSHA256 else { throw NativeRestoreActivationFailure("policy.previousSubject") }
        return context.previousRunning
    }
}
