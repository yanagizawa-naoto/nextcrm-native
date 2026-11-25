import AppKit
import Darwin

/// Separate process: the existing coordinator observes the real parent's exit
/// before switching the active root, then waits for the real child's UI ACK.
@MainActor final class NativePersonalRestoreHelper {
    private let request:NativeRestoreHostLaunchRequest,lease:NativeRestoreHostInstanceLease
    private let control:NativeRestoreActivationControl,resources:URL,base:URL
    private var pausedDatabase:NativeDatabase?
    private var applicationTicket:NativeRestoreHostExitHandoff?
    private init(request:NativeRestoreHostLaunchRequest,lease:NativeRestoreHostInstanceLease,
                 control:NativeRestoreActivationControl,resources:URL,base:URL) {
        self.request=request;self.lease=lease;self.control=control;self.resources=resources;self.base=base
    }
    static func run(base:URL,controlURL:URL,resources:URL)async throws {
        let ipc=try NativeRestoreHostIPC(consumingConnectedSocket:20)
        defer {ipc.close()}
        let request=try await ipc.receive(NativeRestoreHostLaunchRequest.self,timeout:300)
        let lease=try NativeRestoreHostInstanceLease.adopt(existingPrivateControl:controlURL,expected:request.lease,consuming:.init(consuming:21))
        defer {lease.close()}
        let control=try NativeRestoreActivationControl(url:controlURL)
        let owner=NativePersonalRestoreHelper(request:request,lease:lease,control:control,resources:resources,base:base)
        _ = try owner.parentState()
        let coordinator=try NativeRestoreActivation(controlURL:controlURL,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let host=try NativeRestoreCoordinatorHost(request:request,ipc:ipc,lease:lease,coordinator:coordinator,
            callbacks:.init(authorize:{try await owner.authorize()},
                freshAuthorize:{context in try await owner.fresh(context)},
                capturePreviousRunning:{context in try await owner.running(context)},
                preparePaused:{context,permitted in try await owner.prepare(context,permitted)},
                resumeCommitted:{context,permitted,admission in try await owner.resume(context,permitted,admission,controlURL:controlURL)},
                closeCandidate:{_ in await owner.closeCandidate()},
                resumePrevious:{context,_,_ in try await owner.resumeLivePrevious(context)}),timeout:300)
        let result=try await host.run()
        owner.pausedDatabase=nil
        guard result.journal.phase == .active || result.journal.phase == .previousRestored else {
            await owner.closeCandidate();throw NativeRestoreActivationFailure("personal.activationIncomplete")
        }
        // The application's handoff ticket is anchored until this process exits.
        // Returning from the real coordinator is the sole successful exit path.
    }
    private func parentState()throws->NativePersonalRestoreParentState {
        try lease.validate();try control.validate();try request.validateRoots()
        guard let state=try control.read(NativePersonalRestoreParentState.filename,as:NativePersonalRestoreParentState.self),
              state.request==request,Set(state.running).count==state.running.count,
              Set(state.running).isSubset(of:Set(NativeRestoreRuntimeCatalog.ids)),request.parent.uid==geteuid() else {
            throw NativeRestoreHostConversationFailure.wrongContext
        }
        return state
    }
    private func authorize()throws {_ = try parentState()}
    private func fresh(_ context:NativeRestoreHostConversationContext)throws->NativeRestoreHostFreshAuthorization {
        _ = try parentState()
        return try NativePersonalHostAuthority.fresh(context,request:request,control:control,lease:lease)
    }
    private func running(_ context:NativeRestoreActivationContext)throws->[String] {
        let state=try parentState()
        guard state.phase == .reviewing,context.previous.root==request.previousRoot,
              context.candidate.root==request.candidateRoot else {throw NativeRestoreHostConversationFailure.wrongContext}
        return state.running
    }
    private func prepare(_ context:NativeRestoreActivationContext,_ permitted:[String])throws {
        try authorize()
        guard permitted==["workspace.local"],pausedDatabase==nil else {throw NativeRestoreActivationFailure("personal.heldPreparation")}
        let verifier=NativeRestoreActivationVerifier(schemaURL:resources.appendingPathComponent("schema.json"),
            sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{Task.isCancelled})
        let candidate=try verifier.inspect(context.candidate.root.url)
        guard candidate.root==request.candidateRoot,candidate.seal==context.seal else {throw NativeRestoreActivationFailure("personal.sealChanged")}
        try verifier.unchanged(candidate)
        pausedDatabase=try NativeDatabase(readOnlyURL:context.candidate.root.url.appendingPathComponent("crm.sqlite"),schemaURL:verifier.schemaURL)
    }
    private func resume(_ context:NativeRestoreActivationContext,_ permitted:[String],
                        _ admission:NativeRestoreHostCommitAdmission,controlURL:URL)async throws->NativeRestoreActivationStartup {
        guard permitted==["workspace.local"],let database=pausedDatabase,database.isReadOnly,
              database.url==context.candidate.root.url.appendingPathComponent("crm.sqlite"),
              let executable=Bundle.main.executableURL else {throw NativeRestoreActivationFailure("personal.heldPreparation")}
        _ = try fresh(admission.context)
        let pair=try NativeRestoreHostIPC.pair()
        defer {pair.0.close();pair.1.close()}
        let fd=try NativeRestoreHostDescriptor(consuming:pair.1.takeForHandoff()),leaseFD=try lease.handoffDescriptor()
        defer {fd.close();leaseFD.close()}
        let child=try NativeRestoreHostOwnedChild.spawn(executable:executable,
            arguments:["--personal-restore-child",base.path,controlURL.path],
            inheriting:[.init(descriptor:fd,target:20),.init(descriptor:leaseFD,target:21)])
        fd.close();leaseFD.close()
        let ticket=try NativeRestoreHostExitHandoff(child:child);applicationTicket=ticket
        do {
            let startupRequest=try NativeRestoreHostStartupRequest.make(control:control,lease:lease,application:child,approval:admission.approval)
            let verified=try await NativeRestoreHostStartupExchange.helper(request:startupRequest,ipc:pair.0,
                control:control,lease:lease,child:child,timeout:300)
            try await ticket.armAfterStartupACK(verified,lease:lease,freshValidate:{[self] in
                _ = try await fresh(admission.context)
            })
            return verified.coordinatorStartup
        } catch {_ = try? await ticket.cancelAndJoin();throw error}
    }
    private func closeCandidate()async {
        _ = try? await applicationTicket?.cancelAndJoin()
        pausedDatabase=nil
    }
    private func resumeLivePrevious(_ context:NativeRestoreActivationContext)throws->NativeRestoreActivationStartup {
        let state=try parentState()
        // Before fencing the original App has continued running. This is not a
        // fabricated relaunch. Once fenced/dead, require explicit cold recovery.
        guard state.phase == .reviewing,try NativeRestoreHostProcessIdentity.current(request.parent.pid)==request.parent,
              context.previous.root==request.previousRoot,context.previousRunning==state.running else {
            throw NativeRestoreActivationFailure("personal.previousProcessRecoveryRequired")
        }
        struct Evidence:Encodable {let state:NativePersonalRestoreParentState,parent:NativeRestoreHostProcessIdentity,subject:String}
        return .init(started:state.running,held:[],
            evidenceSHA256:try NativeRestoreHostStartupCodec.hash(Evidence(state:state,parent:try .current(request.parent.pid),
                subject:try NativeRestoreActivation.subject(context)),domain:"NextCRM.personal.live-parent-compensation.v1"))
    }
}
