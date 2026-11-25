import Foundation

/// Maps the real sheet's explicit decision onto the private conversation and
/// back into the existing coordinator policy. The three subjects have distinct
/// domains; matching one never substitutes for checking the other two.
enum NativeRestoreReviewBridge {
    typealias FreshAuthorize = (NativeRestoreHostConversationContext) async throws -> NativeRestoreHostFreshAuthorization
    private struct DecisionProof: Codable {
        let domain: String, conversationSubject: String, policySubject: String, activationSubject: String
        let actorID: String, authoritySHA256: String, sourceTrust: String
        let holds: [String], heldRuntimes: [String]
        let approvedAt: Double, validUntil: Double
    }
    private struct ItemProof: Codable {
        let decisionSHA256: String, item: String, choice: String
    }

    static func validate(_ context: NativeRestoreHostConversationContext) throws {
        try NativeRestoreRuntimeCatalog.validate(context.coordinatorContext)
        guard context.writerParticipants == NativeRestoreRuntimeCatalog.writerParticipants else {
            throw NativeRestoreActivationFailure("reviewBridge.writers")
        }
        _ = try context.subjectSHA256() // Also validates bounds before any hash.
    }

    static func authority(_ value: NativeRestoreHostFreshAuthorization,
                          context: NativeRestoreHostConversationContext, now: Date,
                          requireFresh: Bool = true) throws -> NativeRestoreReviewAuthority {
        var budget = NativeRestoreHostWireBudget(); try budget.authorization(value)
        let time = now.timeIntervalSince1970
        guard time.isFinite, value.subjectSHA256 == (try context.subjectSHA256()),
              value.authenticatedAt <= time, (!requireFresh || time - value.authenticatedAt <= 60),
              value.validUntil > time, value.validUntil - value.authenticatedAt <= 300 else {
            throw NativeRestoreActivationFailure("reviewBridge.authorization")
        }
        return .init(actorID: value.principalID, evidenceSHA256: value.evidenceSHA256)
    }

    static func prompt(context: NativeRestoreHostConversationContext,
                       authorization: NativeRestoreHostFreshAuthorization, now: Date) throws -> NativeRestoreHeldReviewPrompt {
        try validate(context)
        _ = try authority(authorization, context: context, now: now)
        return try displayedPrompt(context: context, validUntil: authorization.validUntil)
    }

    private static func displayedPrompt(context: NativeRestoreHostConversationContext, validUntil: Double) throws -> NativeRestoreHeldReviewPrompt {
        let ctx = context.coordinatorContext
        return .init(fullSubjectSHA256: try NativeRestoreHeldReviewPolicy.binding(ctx),
                     activationSubjectSHA256: try NativeRestoreActivation.subject(ctx),
                     snapshotID: ctx.seal.snapshotID, sourceNamespaceSHA256: ctx.seal.sourceNamespaceSHA256,
                     finalNamespaceSHA256: ctx.seal.finalNamespaceSHA256, inheritedPending: ctx.inheritedPending,
                     previousRunning: ctx.previousRunning, kinds: NativeRestoreHeldReviewKind.allCases,
                     heldRuntimes: NativeRestoreRuntimeCatalog.heldAutomatic,
                     validUntil: Date(timeIntervalSince1970: validUntil))
    }

    /// All inputs must come from the same displayed sheet. No default choices.
    static func approval(context: NativeRestoreHostConversationContext,
                         authorization: NativeRestoreHostFreshAuthorization,
                         displayed: NativeRestoreHeldReviewPrompt,
                         source: NativeRestoreSourceTrustChoice,
                         holds: [NativeRestoreExplicitHoldChoice],
                         checkedAuthority: NativeRestoreReviewAuthority,
                         now: Date) throws -> NativeRestoreHostUIApproval {
        try validate(context)
        _ = try authority(authorization, context: context, now: now, requireFresh: false)
        let expected = try displayedPrompt(context: context, validUntil: authorization.validUntil)
        guard try NativeRestoreHeldReviewPolicy.hash(displayed) == NativeRestoreHeldReviewPolicy.hash(expected),
              now < displayed.validUntil,
              checkedAuthority.actorID == authorization.principalID,
              NativeMigrationCodec.validHash(checkedAuthority.evidenceSHA256),
              case let .trustReviewedCandidate(subject) = source, subject == displayed.fullSubjectSHA256,
              holds.count == NativeRestoreHeldReviewKind.allCases.count,
              Set(holds.map(\.kind)) == Set(NativeRestoreHeldReviewKind.allCases),
              holds.allSatisfy({ $0.fullSubjectSHA256 == subject && $0.decision == .keepHeld }) else {
            throw NativeRestoreActivationFailure("reviewBridge.explicitDecision")
        }
        let full = try context.subjectSHA256()
        let proof = DecisionProof(domain: "NextCRM.restore.review-sheet.v1", conversationSubject: full,
                                  policySubject: subject, activationSubject: displayed.activationSubjectSHA256,
                                  actorID: checkedAuthority.actorID, authoritySHA256: checkedAuthority.evidenceSHA256,
                                  sourceTrust: "explicitlyAcceptedUnverified", holds: holds.map { $0.kind.rawValue }.sorted(),
                                  heldRuntimes: displayed.heldRuntimes.sorted(), approvedAt: now.timeIntervalSince1970,
                                  validUntil: displayed.validUntil.timeIntervalSince1970)
        let digest = try NativeRestoreHeldReviewPolicy.hash(proof)
        func item(_ name: String, _ choice: String) throws -> String {
            try NativeRestoreHeldReviewPolicy.hash(ItemProof(decisionSHA256: digest, item: name, choice: choice))
        }
        let result = NativeRestoreHostUIApproval(subjectSHA256: full, decisionEvidenceSHA256: digest,
            approvedAt: now.timeIntervalSince1970, validUntil: displayed.validUntil.timeIntervalSince1970,
            sourceTrust: .init(disposition: .explicitlyAcceptedUnverified, evidenceSHA256: try item("source", "trust")),
            reviewHolds: try NativeRestoreHostReviewHold.Kind.allCases.map {
                .init(kind: $0, decision: .keepHeld, evidenceSHA256: try item("review." + $0.rawValue, "keepHeld"))
            }, runtimeChoices: try context.runtimeCatalog.map {
                let choice: NativeRestoreHostRuntimeChoice.Disposition = $0.id == "workspace.local" ? .requestResumeAfterCoordinatorReview : .hold
                return .init(runtimeID: $0.id, disposition: choice, evidenceSHA256: try item("runtime." + $0.id, choice.rawValue))
            })
        var budget = NativeRestoreHostWireBudget(); try budget.decision(result)
        return result
    }

    /// Called only with the admission returned by runHelper after actual parent
    /// exit. Fresh authorization remains mandatory in the helper on every gate;
    /// an IPC receipt is never used as a credential or a provider validation.
    static func policy(admission: NativeRestoreHostCommitAdmission,
                       clock: @escaping () -> Date = Date.init,
                       authorize: @escaping FreshAuthorize) async throws -> NativeRestoreHeldReviewPolicy {
        let context = admission.context, ctx = context.coordinatorContext, envelope = admission.approval
        try validate(context)
        var budget = NativeRestoreHostWireBudget(); try budget.approval(envelope)
        let full = try context.subjectSHA256(), decision = envelope.decision
        guard admission.subjectSHA256 == full, envelope.binding.subjectSHA256 == full,
              decision.subjectSHA256 == full, envelope.binding.session.previous == context.previous,
              envelope.binding.session.candidate == context.candidate,
              decision.sourceTrust.disposition == .explicitlyAcceptedUnverified,
              Set(decision.reviewHolds.map(\.kind)) == Set(NativeRestoreHostReviewHold.Kind.allCases),
              decision.reviewHolds.count == NativeRestoreHostReviewHold.Kind.allCases.count,
              decision.reviewHolds.allSatisfy({ $0.decision == .keepHeld }),
              Set(decision.runtimeChoices.map(\.runtimeID)) == Set(NativeRestoreRuntimeCatalog.ids),
              decision.runtimeChoices.count == NativeRestoreRuntimeCatalog.ids.count,
              decision.runtimeChoices.allSatisfy({ $0.disposition == ($0.runtimeID == "workspace.local" ? .requestResumeAfterCoordinatorReview : .hold) }) else {
            throw NativeRestoreActivationFailure("reviewBridge.admission")
        }
        let deadline = Date(timeIntervalSince1970: min(envelope.authorization.validUntil, decision.validUntil, decision.approvedAt + 300))
        let fresh: NativeRestoreHeldReviewPolicy.Authorize = {
            guard clock() < deadline else { throw NativeRestoreActivationFailure("reviewBridge.expired") }
            let checked = try await authorize(context)
            let authority = try Self.authority(checked, context: context, now: clock())
            guard authority.actorID == envelope.authorization.principalID, clock() < deadline else {
                throw NativeRestoreActivationFailure("reviewBridge.principal")
            }
            return authority
        }
        _ = try await fresh()
        let now = clock()
        guard decision.approvedAt <= now.timeIntervalSince1970, now < deadline else {
            throw NativeRestoreActivationFailure("reviewBridge.expired")
        }
        let policySubject = try NativeRestoreHeldReviewPolicy.binding(ctx)
        // Pass through evidence of exactly the reviewed envelope, explicitly
        // deferred. This is not cryptographic proof of the backup's origin.
        let evidence = NativeRestoreActivationEvidence(kind: "sourceProvenance",
            subjectSHA256: try NativeRestoreActivation.subject(ctx), evidenceSHA256: try NativeRestoreHeldReviewPolicy.hash(envelope),
            checkedAt: Date(timeIntervalSince1970: decision.approvedAt), validUntil: deadline,
            blockedRuntimes: NativeRestoreRuntimeCatalog.heldAutomatic, disposition: "explicitlyDeferred")
        return try await NativeRestoreHeldReviewPolicy.request(context: ctx, validity: deadline.timeIntervalSince(now), clock: clock,
            authorize: fresh, confirmSource: { prompt in
                guard prompt.fullSubjectSHA256 == policySubject else { throw NativeRestoreActivationFailure("reviewBridge.policySubject") }
                return .trustReviewedCandidate(fullSubjectSHA256: policySubject)
            }, chooseHolds: { prompt in
                guard prompt.fullSubjectSHA256 == policySubject else { throw NativeRestoreActivationFailure("reviewBridge.policySubject") }
                return decision.reviewHolds.map { .init(kind: NativeRestoreHeldReviewKind(rawValue: $0.kind.rawValue)!, fullSubjectSHA256: policySubject, decision: .keepHeld) }
            }, sourceEvidence: evidence)
    }
}
