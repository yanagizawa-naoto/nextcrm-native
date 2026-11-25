import Foundation
import Darwin

/// Produced only by helper exchange after validating the ACK against its owned
/// live child and stable .starting journal. Not a provider/reconciliation proof.
struct NativeRestoreHostVerifiedStartup {
    let request:NativeRestoreHostStartupRequest
    let acknowledgment:NativeRestoreHostStartupACK
    let coordinatorStartup:NativeRestoreActivationStartup
    fileprivate init(request:NativeRestoreHostStartupRequest,acknowledgment:NativeRestoreHostStartupACK)throws {
        self.request=request;self.acknowledgment=acknowledgment
        coordinatorStartup = .init(started:request.permitted,held:request.held,evidenceSHA256:try NativeRestoreHostStartupCodec.hash(acknowledgment,domain:"NextCRM.restore.startup-ack.v1"))
    }
}

enum NativeRestoreHostStartupFailure: Error { case processExitRequired }
enum NativeRestoreHostWorkspaceShutdown: String, Codable { case preparedWorkJoinedProcessExitRequired }

/// One startup per process. The private duplicate cannot be closed through the
/// public resolver. No unlock, new disk lock, release or retry API is exposed.
private final class NativeRestoreHostProcessLeaseAnchor {
    private static let lock=NSLock()
    private static var existing:NativeRestoreHostProcessLeaseAnchor?
    private let privateLease:NativeRestoreHostInstanceLease
    private var retained:Unmanaged<NativeRestoreHostProcessLeaseAnchor>?
    private init(_ lease:NativeRestoreHostInstanceLease) {privateLease=lease}
    static func pin(_ startup:NativeRestoreApplicationStartup)throws {
        lock.lock();defer{lock.unlock()}
        guard existing == nil else {throw NativeRestoreHostStartupFailure.processExitRequired}
        let fd=try startup.lease.handoffDescriptor()
        let duplicate=try NativeRestoreHostInstanceLease.adopt(existingPrivateControl:startup.control.url,
            expected:startup.lease.identity,consuming:fd)
        let anchor=NativeRestoreHostProcessLeaseAnchor(duplicate)
        anchor.retained=Unmanaged.passRetained(anchor)
        existing=anchor
    }
}

struct NativeRestoreHostPreparedWorkspace {
    let readiness:NativeRestoreHostWorkspaceReadiness
    /// Real UI/workspace lifetime owner, retained until controlled shutdown.
    let lifetime:AnyObject
}
struct NativeRestoreHostStartupCallbacks {
    /// Fresh current administrator/session check, bound to request.subjectSHA256.
    let freshAuthorize:(NativeRestoreHostStartupRequest,NativeRestoreApplicationStartup)async throws->NativeRestoreHostFreshAuthorization
    /// Must construct the actual held workspace and prepare its UI. No default.
    let prepareWorkspaceAndUI:(NativeRestoreHostStartupRequest,NativeRestoreApplicationStartup)async throws->NativeRestoreHostPreparedWorkspace
    /// Must finish/close all prepared work even when the initiating task cancelled.
    let discardWorkspace:(NativeRestoreHostPreparedWorkspace)async->Void
}

/// Prepared work is joined/released during shutdown. The private duplicate
/// lease is deliberately retained until OS exit, even if public lease.close()
/// is called or the workspace has a slow destructor/retained aliases.
actor NativeRestoreHostStartedApplication {
    let startup:NativeRestoreApplicationStartup
    let acknowledgment:NativeRestoreHostStartupACK
    private var prepared:NativeRestoreHostPreparedWorkspace?
    private let discard:(NativeRestoreHostPreparedWorkspace)async->Void
    private var closing:Task<Void,Never>?
    fileprivate init(startup:NativeRestoreApplicationStartup,acknowledgment:NativeRestoreHostStartupACK,
                     prepared:NativeRestoreHostPreparedWorkspace,discard:@escaping(NativeRestoreHostPreparedWorkspace)async->Void) {
        self.startup=startup;self.acknowledgment=acknowledgment;self.prepared=prepared;self.discard=discard
    }
    deinit {
        if let prepared {
            let cleanup=discard
            Task.detached {await cleanup(prepared)}
        }
    }
    @discardableResult func shutdown()async->NativeRestoreHostWorkspaceShutdown {
        if let closing {await closing.value;return .preparedWorkJoinedProcessExitRequired}
        guard let prepared else {return .preparedWorkJoinedProcessExitRequired}
        let cleanup=Task.detached { [discard] in await discard(prepared) }
        closing=cleanup;await cleanup.value;self.prepared=nil;closing=nil
        return .preparedWorkJoinedProcessExitRequired
    }
}

enum NativeRestoreHostStartupExchange {
    /// Helper remains inside real coordinator.resumeCommitted (.starting).
    /// After this returns it may return coordinatorStartup; only the coordinator
    /// then writes .active. No policy/provider is enabled by this transport.
    static func helper(request:NativeRestoreHostStartupRequest,ipc:NativeRestoreHostIPC,
                       control:NativeRestoreActivationControl,lease:NativeRestoreHostInstanceLease,
                       child:NativeRestoreHostOwnedChild,timeout:TimeInterval=30,
                       clock:@escaping()->Date=Date.init)async throws->NativeRestoreHostVerifiedStartup {
        defer{ipc.close()}
        try request.validateBounds();try request.validateLifetime(now:clock())
        guard request.helper==(try .current(getpid())),request.application==(try child.processIdentity()) else {throw NativeRestoreHostHandoffFailure.invalidBinding}
        try NativeRestoreHostStartupCodec.current(request,control:control,lease:lease)
        try await ipc.send(request,timeout:timeout)
        let ack=try await ipc.receive(NativeRestoreHostStartupACK.self,timeout:timeout)
        try Task.checkCancellation();try ack.validate(now:clock())
        guard ack.request==request,try child.processIdentity()==request.application else {throw NativeRestoreHostHandoffFailure.invalidBinding}
        try NativeRestoreHostStartupCodec.current(request,control:control,lease:lease)
        return try .init(request:request,acknowledgment:ack)
    }

    /// Only private inherited IPC/lease inputs. No CLI actor/role fallback.
    static func application(ipc:NativeRestoreHostIPC,leaseDescriptor:NativeRestoreHostDescriptor,
                            baseRootURL:URL,controlURL:URL,callbacks:NativeRestoreHostStartupCallbacks,
                            timeout:TimeInterval=30,clock:@escaping()->Date=Date.init)async throws->NativeRestoreHostStartedApplication {
        var startup:NativeRestoreApplicationStartup?,prepared:NativeRestoreHostPreparedWorkspace?
        var pinnedForProcess=false
        do {
            let request=try await ipc.receive(NativeRestoreHostStartupRequest.self,timeout:timeout)
            try request.validateBounds();try request.validateLifetime(now:clock())
            guard request.application==(try .current(getpid())),request.helper==(try .parent()) else {throw NativeRestoreHostHandoffFailure.invalidBinding}
            let resolved=try NativeRestoreApplicationStartup(baseRootURL:baseRootURL,controlURL:controlURL,runtimes:NativeRestoreRuntimeCatalog.runtimes,
                inherited:.init(leaseDescriptor:leaseDescriptor,leaseIdentity:request.lease,selection:request.selection,activationID:request.activationID,
                                permitted:request.permitted,validateApproval:{try request.validateJournal($0)}))
            startup=resolved
            guard resolved.plan.mode == .approvedHandoff,resolved.plan.selection==request.selection,
                  resolved.plan.permitted==request.permitted,resolved.plan.held==request.held,resolved.plan.requiresReview else {
                throw NativeRestoreHostHandoffFailure.invalidBinding
            }
            // Once callbacks may touch data, the gate belongs to the whole process.
            // Even public lease.close(), callback failure, slow deinit or a
            // discarded StartedApplication cannot release its private duplicate.
            try NativeRestoreHostProcessLeaseAnchor.pin(resolved);pinnedForProcess=true
            // Authorization is checked before opening the workspace and again
            // after potentially suspending UI construction.
            let first=try await callbacks.freshAuthorize(request,resolved);try Task.checkCancellation()
            try validateAuthority(first,request:request,now:clock())
            let workspace=try await callbacks.prepareWorkspaceAndUI(request,resolved)
            prepared=workspace;try Task.checkCancellation();try workspace.readiness.validate(request)
            let final=try await callbacks.freshAuthorize(request,resolved);try Task.checkCancellation()
            try validateAuthority(final,request:request,now:clock())
            guard first.principalID==final.principalID else {throw NativeRestoreHostHandoffFailure.invalidBinding}
            try NativeRestoreHostStartupCodec.current(request,control:resolved.control,lease:resolved.lease)
            let ack=NativeRestoreHostStartupACK(request:request,authorization:final,readiness:workspace.readiness)
            try ack.validate(now:clock());try await ipc.send(ack,timeout:timeout);try Task.checkCancellation()
            ipc.close()
            return .init(startup:resolved,acknowledgment:ack,prepared:workspace,discard:callbacks.discardWorkspace)
        } catch {
            // A failure EOF authorizes the helper to stop/reap this owned child.
            // Complete cooperative prepared-work cleanup before announcing EOF;
            // the helper timeout remains the bound for uncooperative callbacks.
            if let prepared {
                let cleanup=Task.detached {await callbacks.discardWorkspace(prepared)}
                await cleanup.value
            }
            ipc.close()
            startup?.lease.close();leaseDescriptor.close()
            if pinnedForProcess {throw NativeRestoreHostStartupFailure.processExitRequired}
            throw error
        }
    }
    private static func validateAuthority(_ authority:NativeRestoreHostFreshAuthorization,request:NativeRestoreHostStartupRequest,now:Date)throws {
        var budget=NativeRestoreHostWireBudget();try budget.authorization(authority)
        let time=now.timeIntervalSince1970
        guard authority.principalID==request.approval.authorization.principalID,authority.subjectSHA256==(try request.subjectSHA256()),
              authority.authenticatedAt<=time,time-authority.authenticatedAt<=60,
              authority.validUntil>time,authority.validUntil-authority.authenticatedAt<=300 else {throw NativeRestoreHostHandoffFailure.expired}
        try request.validateLifetime(now:now)
    }
}
