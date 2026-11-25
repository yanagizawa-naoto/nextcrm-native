import AppKit
import Darwin

struct NativePersonalRestoreParentState:Codable,Equatable {
    enum Phase:String,Codable {case reviewing,fencing,drained}
    let request:NativeRestoreHostLaunchRequest
    let running:[String]
    var phase:Phase
    static let filename="personal-restore-parent.json"
}

/// Local macOS admission and business authorization are deliberately separate.
/// The UI's selected CRM owner is never fabricated from an operating-system UID.
enum NativePersonalHostAuthority {
    static func validateRunning(_ startup:NativeRestoreApplicationStartup,paths:NativePersonalApplicationPaths)throws {
        do {try paths.validate(startup);return} catch {
            // A cancelled first switch can legitimately publish a generation
            // for the unchanged old root. Accept only this live process's exact
            // unfenced request and the coordinator's completed compensation.
            try startup.control.validate();try startup.lease.validate()
            guard let state=try startup.control.read(NativePersonalRestoreParentState.filename,as:NativePersonalRestoreParentState.self),
                  state.phase == .reviewing,state.request.parent == (try .current(getpid())),
                  state.request.lease==startup.lease.identity,state.request.previousRoot==startup.plan.root,
                  let journal=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
                  journal.phase == .previousRestored,journal.previous.root==startup.plan.root,
                  journal.candidate.root==state.request.candidateRoot,journal.previousRunning==state.running,
                  journal.runtimeCatalog==NativeRestoreRuntimeCatalog.runtimes,
                  try startup.control.read("active-root.json",as:NativeRestoreActivationSelection.self)==journal.previous,
                  try NativeRestoreActivationControl.root(startup.plan.root.url)==startup.plan.root else {throw error}
        }
    }
    static func fresh(_ context:NativeRestoreHostConversationContext,
                      request:NativeRestoreHostLaunchRequest,
                      control:NativeRestoreActivationControl,
                      lease:NativeRestoreHostInstanceLease)throws->NativeRestoreHostFreshAuthorization {
        try control.validate();try lease.validate();try request.validateRoots()
        try NativeRestoreReviewBridge.validate(context)
        guard request.lease==lease.identity,request.parent.uid==geteuid(),
              context.previous.root==request.previousRoot,context.candidate.root==request.candidateRoot else {
            throw NativeRestoreHostConversationFailure.unauthorized
        }
        let process=try NativeRestoreHostProcessIdentity.current(getpid()),now=Date().timeIntervalSince1970
        let subject=try context.subjectSHA256()
        struct Evidence:Encodable {
            let uid:UInt32,process:NativeRestoreHostProcessIdentity,lease:NativeRestoreHostLeaseIdentity
            let requestID:String,nonce:String,subject:String,observedAt:Double
        }
        let evidence=Evidence(uid:geteuid(),process:process,lease:lease.identity,requestID:request.requestID,
            nonce:request.nonce,subject:subject,observedAt:now)
        return .init(principalID:"macOS:\(geteuid())",subjectSHA256:subject,
            evidenceSHA256:try NativeRestoreHostStartupCodec.hash(evidence,domain:"NextCRM.personal.macOS-authority.v1"),
            authenticatedAt:now,validUntil:now+300)
    }
}

@MainActor final class NativePersonalRestoreParent {
    private let startup:NativeRestoreApplicationStartup,resources:URL,paths:NativePersonalApplicationPaths
    private weak var application:NativeCRMApplication?
    private var task:Task<Void,Never>?
    private var conversation:NativeRestoreHostConversation?
    private var ticket:NativeRestoreHostExitHandoff?
    private var reviewedContext:NativeRestoreHostConversationContext?
    private var fenced=false
    private(set) var isExitArmed=false
    init(startup:NativeRestoreApplicationStartup,application:NativeCRMApplication,
         resources:URL,paths:NativePersonalApplicationPaths)throws {
        try NativePersonalHostAuthority.validateRunning(startup,paths:paths);try application.authorizePersonalRestore()
        self.startup=startup;self.application=application;self.resources=resources;self.paths=paths
    }
    func start(artifact:NativeDataMaintenanceArtifact,parent:NSWindow,onFinished:@escaping ()->Void)throws {
        guard task==nil,artifact.kind == .restore,let result=artifact.restore,result.candidateCreated,
              !result.activated,!result.workersStarted,let application else {throw NativeRestoreActivationFailure("personal.restoreArtifact")}
        try application.authorizePersonalRestore();try application.checkRestoreParentAdmission(ownedWindows:[parent])
        let verifier=NativeRestoreActivationVerifier(schemaURL:resources.appendingPathComponent("schema.json"),
            sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{Task.isCancelled})
        let candidate=try verifier.inspect(artifact.url)
        guard candidate.seal.snapshotID==artifact.snapshotID else {throw NativeRestoreActivationFailure("personal.restoreArtifact")}
        let request=try NativeRestoreHostLaunchRequest.make(previousRoot:startup.plan.root.url,candidateRoot:candidate.root.url,lease:startup.lease)
        let state=NativePersonalRestoreParentState(request:request,running:try application.personalRuntimeInventory(),phase:.reviewing)
        try write(state)
        task=Task { [self] in
            defer {task=nil;onFinished()}
            do {try await run(request:request,state:state,parent:parent)}
            catch {
                _ = await conversation?.cancel();await settleHelper()
                if !(error is CancellationError),error as? NativeRestoreHostConversationFailure != .declined {
                    let alert=NSAlert();alert.messageText="復元への切り替えを中止しました"
                    alert.informativeText=fenced ? "元のデータは保存されています。処理の終了後にアプリを開き直して、復元の状態を確認してください。" : error.localizedDescription
                    alert.runModal()
                }
                if fenced {await application.discardRestoredWorkspace();application.terminateAfterPersonalDiscard()}
            }
        }
    }
    private func write(_ value:NativePersonalRestoreParentState)throws {
        // This parent is the sole writer of its request/phase record. The helper
        // owns the separate activation journal lock while it waits on our UI.
        // Atomic write/fsync and the shared instance gate protect this file.
        try startup.lease.validate();try startup.control.write(value,name:NativePersonalRestoreParentState.filename)
    }
    private func run(request:NativeRestoreHostLaunchRequest,state:NativePersonalRestoreParentState,parent:NSWindow)async throws {
        guard let app=application,let executable=Bundle.main.executableURL else {throw CancellationError()}
        let pair=try NativeRestoreHostIPC.pair()
        defer {pair.0.close();pair.1.close()}
        let fd=try NativeRestoreHostDescriptor(consuming:pair.1.takeForHandoff()),leaseFD=try startup.lease.handoffDescriptor()
        defer {fd.close();leaseFD.close()}
        let child=try NativeRestoreHostOwnedChild.spawn(executable:executable,
            arguments:["--personal-restore-helper",paths.baseRootURL.path,paths.controlURL.path],
            inheriting:[.init(descriptor:fd,target:20),.init(descriptor:leaseFD,target:21)])
        fd.close();leaseFD.close()
        let ticket=try NativeRestoreHostExitHandoff(child:child);self.ticket=ticket
        let conversation=try await request.parentConversation(ipc:pair.0,instanceLease:startup.lease,timeout:300)
        self.conversation=conversation
        let authorize:NativeRestoreReviewBridge.FreshAuthorize = {[self,startup] context in
            try await MainActor.run {
                if let previous=reviewedContext,previous != context {throw NativeRestoreHostConversationFailure.wrongContext}
                reviewedContext=context
                try app.authorizeRestoreBusinessIdentity()
            }
            return try NativePersonalHostAuthority.fresh(context,request:request,control:startup.control,lease:startup.lease)
        }
        let permit=try await conversation.runParent(callbacks:.init(freshAuthorize:authorize,
            review:{context,authority in
                try await NativeRestoreReviewPresenter.present(context:context,authorization:authority,on:parent,authorize:authorize)
            },fenceAndDrain:{[self] context in
                try await MainActor.run {
                    try app.authorizeRestoreBusinessIdentity()
                    var next=state;next.phase = .fencing;try write(next)
                    do {try app.fenceRestoreParent(ownedWindows:[parent]);fenced=true}
                    catch {try write(state);throw error}
                }
                let receipt=try await app.drainRestoreParent()
                let connections=NativeDatabase.liveConnections().filter{!$0.readOnly}
                let expected=request.previousRoot.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL.path
                guard connections.count<=256,connections.allSatisfy({$0.path==expected}),
                      receipt.remainingTrackedTasks==0,receipt.requiresProcessExitForDatabaseHandles else {
                    throw NativeRestoreHostConversationFailure.incompleteDrain
                }
                struct Evidence:Encodable {
                    let subject:String,receipt:NativeRestoreParentActivities.Receipt
                    let connections:[NativeDatabase.LiveConnection]
                }
                let digest=try NativeRestoreHostStartupCodec.hash(Evidence(subject:try context.subjectSHA256(),receipt:receipt,connections:connections),domain:"NextCRM.personal.parent-drain.v1")
                try await MainActor.run {var next=state;next.phase = .drained;try write(next)}
                return .init(acceptedWritesFenced:true,retainedDatabaseHandles:connections.map {
                    .init(id:$0.id,participant:"workspace.database-handles",root:request.previousRoot,owner:request.parent,purpose:.processLocalSQLiteConnectionNeverExported)
                },drain:.init(root:request.previousRoot,participants:context.writerParticipants,
                    previouslyRunning:context.previousRunning,unfinishedTasks:receipt.remainingTrackedTasks,
                    openWritableHandles:connections.count,unsavedEditors:0,pendingCallbacks:0,evidenceSHA256:digest))
            }))
        guard let context=reviewedContext,try context.subjectSHA256()==permit.subjectSHA256 else {
            throw NativeRestoreHostConversationFailure.wrongContext
        }
        try await ticket.armAfterParentPermit(permit,session:permit.approval.binding.session,lease:startup.lease,freshValidate:{
            _ = try await authorize(context)
        })
        isExitArmed=true
        try app.terminateAfterRestoreDrain()
    }
    private func settleHelper()async {
        guard let ticket else{return}
        guard !fenced else {_ = try? await ticket.cancelAndJoin();return}
        // Let the real coordinator finish its before-fence compensation after
        // EOF/decline. Killing it immediately would leave an avoidable journal.
        let deadline=Task {
            do {try await Task.sleep(nanoseconds:15_000_000_000)} catch {return}
            _ = try? await ticket.cancelAndJoin()
        }
        _ = try? await ticket.join()
        deadline.cancel();await deadline.value
    }
    func cancelAndDrain()async {
        task?.cancel();_ = await conversation?.cancel()
        await task?.value
    }
}
