import Foundation
import Darwin

enum NativeRestoreHostHandoffFailure: String, Error {
    case invalidBinding, childEnded, alreadyArmed, stopped, invalidReadiness, expired
}

/// The ONLY waiter/reaper of this owned child. Pass the newly spawned child
/// here before another caller invokes wait(). No PID-based detach/kill API.
/// An armed self-retain intentionally survives application ARC teardown.
@MainActor final class NativeRestoreHostExitHandoff {
    enum State: String { case managed, arming, armed, stopping, reaped }
    private(set) var state: State = .managed
    private(set) static var retainedAnchors = 0
    let ownerIdentity: NativeRestoreHostProcessIdentity
    let childIdentity: NativeRestoreHostProcessIdentity
    private var child: NativeRestoreHostOwnedChild?
    private var observer: Task<NativeRestoreHostChildExit, Error>!
    private var completion: Result<NativeRestoreHostChildExit, Error>?
    private var anchor: Unmanaged<NativeRestoreHostExitHandoff>?

    init(child: NativeRestoreHostOwnedChild) throws {
        ownerIdentity = try .current(getpid()); childIdentity = try child.processIdentity()
        self.child = child
        observer = Task { [weak self, child] in
            do {
                let value = try await child.wait()
                self?.finished(.success(value))
                return value
            } catch {
                self?.finished(.failure(error))
                throw error
            }
        }
    }
    deinit { observer?.cancel() }
    private func releaseAnchor() {
        if let held = anchor { anchor = nil; Self.retainedAnchors -= 1; held.release() }
    }
    private func finished(_ result: Result<NativeRestoreHostChildExit, Error>) {
        completion = result; state = .reaped; child = nil
        releaseAnchor()
    }
    private func alive(_ lease: NativeRestoreHostInstanceLease, expected: NativeRestoreHostLeaseIdentity) throws {
        guard try NativeRestoreHostProcessIdentity.current(getpid()) == ownerIdentity,
              let child, try child.processIdentity() == childIdentity,
              lease.identity == expected, completion == nil else { throw NativeRestoreHostHandoffFailure.childEnded }
        try lease.validate()
    }
    private func arm(lease: NativeRestoreHostInstanceLease, expected: NativeRestoreHostLeaseIdentity,
                     check: () throws -> Void, freshValidate: () async throws -> Void) async throws {
        guard state == .managed, anchor == nil else { throw NativeRestoreHostHandoffFailure.alreadyArmed }
        do {
            try alive(lease, expected: expected); try check(); try Task.checkCancellation()
            state = .arming; anchor = Unmanaged.passRetained(self); Self.retainedAnchors += 1
            try await freshValidate()
            try Task.checkCancellation(); try alive(lease, expected: expected); try check()
            guard state == .arming else { throw NativeRestoreHostHandoffFailure.stopped }
            state = .armed
        } catch {
            // Includes a callback failing while the raw retain already exists.
            // Join cleanup before reporting failure, even when this caller is cancelled.
            _ = try? await cancelAndJoin()
            throw error
        }
    }
    func armAfterParentPermit(_ permit: NativeRestoreHostParentExitPermit,
                              session: NativeRestoreHostConversationSession,
                              lease: NativeRestoreHostInstanceLease,
                              clock: @escaping () -> Date = Date.init,
                              freshValidate: () async throws -> Void) async throws {
        try await arm(lease: lease, expected: session.lease, check: {
            var budget = NativeRestoreHostWireBudget(); try budget.session(session); try budget.approval(permit.approval)
            try budget.drain(permit.preExitReport)
            guard ownerIdentity == session.parent, permit.approval.binding.session == session,
                  permit.registration == permit.approval.binding.registration,
                  permit.registration.process == ownerIdentity,
                  permit.subjectSHA256 == permit.approval.binding.subjectSHA256,
                  permit.preExitReport.acceptedWritesFenced,
                  permit.preExitReport.drain.root==session.previous.root,
                  permit.preExitReport.drain.unfinishedTasks==0,permit.preExitReport.drain.unsavedEditors==0,
                  permit.preExitReport.drain.pendingCallbacks==0,
                  permit.preExitReport.retainedDatabaseHandles.allSatisfy({$0.owner==ownerIdentity && $0.root==session.previous.root}) else { throw NativeRestoreHostHandoffFailure.invalidBinding }
            let now = clock().timeIntervalSince1970
            guard now.isFinite, permit.approval.authorization.authenticatedAt <= now,
                  permit.approval.decision.approvedAt <= now,
                  now < min(permit.approval.authorization.validUntil,permit.approval.decision.validUntil) else {
                throw NativeRestoreHostHandoffFailure.expired
            }
        }, freshValidate: freshValidate)
    }
    func armAfterStartupACK(_ startup: NativeRestoreHostVerifiedStartup,
                            lease: NativeRestoreHostInstanceLease,
                            clock: @escaping () -> Date = Date.init,
                            freshValidate: () async throws -> Void) async throws {
        try await arm(lease: lease, expected: startup.request.lease, check: {
            try startup.acknowledgment.validate(now: clock())
            guard startup.request.helper == ownerIdentity, startup.request.application == childIdentity else {
                throw NativeRestoreHostHandoffFailure.invalidBinding
            }
        }, freshValidate: freshValidate)
    }
    /// Not a detach. Cancels and joins the sole exact-child waiter; spontaneous
    /// child completion also releases the anchor without requiring this call.
    @discardableResult func cancelAndJoin() async throws -> NativeRestoreHostChildExit {
        if let completion { return try completion.get() }
        state = .stopping
        let task = observer!
        child?.cancel(); task.cancel()
        return try await task.value
    }
    /// Observe normal completion. Cancelling this caller does not abandon the
    /// owned child; use cancelAndJoin when cessation is required.
    func join() async throws -> NativeRestoreHostChildExit {
        if let completion { return try completion.get() }
        return try await observer.value
    }
}
