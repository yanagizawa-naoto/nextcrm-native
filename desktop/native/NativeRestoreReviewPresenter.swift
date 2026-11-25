import AppKit

enum NativeRestoreReviewPresenter {
    @MainActor static func present(context: NativeRestoreHostConversationContext,
                                   authorization: NativeRestoreHostFreshAuthorization,
                                   on parent: NSWindow, clock: @escaping () -> Date = Date.init,
                                   authorize: @escaping NativeRestoreReviewBridge.FreshAuthorize) async throws -> NativeRestoreHostUIDecision {
        let prompt = try NativeRestoreReviewBridge.prompt(context: context, authorization: authorization, now: clock())
        let sheet = try NativeRestoreReviewWindow(prompt: prompt, previousRoot: context.previous.root.url,
            candidateRoot: context.candidate.root.url, clock: clock, authorize: {
                let fresh = try await authorize(context)
                let authority = try NativeRestoreReviewBridge.authority(fresh, context: context, now: clock())
                guard authority.actorID == authorization.principalID else { throw NativeRestoreActivationFailure("reviewBridge.principal") }
                return authority
            })
        guard let decision = await sheet.present(on: parent) else { return .declined }
        try Task.checkCancellation()
        return .approved(try NativeRestoreReviewBridge.approval(context: context, authorization: authorization,
            displayed: prompt, source: decision.source, holds: decision.holds, checkedAuthority: decision.authority, now: clock()))
    }
}
