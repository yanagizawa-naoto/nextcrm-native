import Foundation
import Darwin

/// Cold, explicit recovery of the still-selected previous root. Every live App
/// result comes from required composition/readiness callbacks, not a saved ACK.
@MainActor final class NativePersonalPreviousRecovery {
    struct LocalReviewPrompt {
        let rootPath:String,heldRuntimes:[String],subjectSHA256:String
    }
    enum LocalReviewChoice {case keepWorkersHeld(subjectSHA256:String)}
    struct Callbacks {
        let authorize: (NativeRestoreActivationContext) async throws -> Void
        let verifyQuiescence: (NativeRestoreActivationContext, NativeRestoreActivationSelection) async throws -> NativeRestoreActivationDrain
        let makeHost: (NativeRestoreApplicationStartup, NativeRestorePreviousRecoveryPermit) throws -> NativePersonalApplicationHost
        let readiness: (NativeRestoreActivationContext, NativeRestoreApplicationStartup, NativePersonalApplicationHost) async throws -> NativeRestoreActivationStartup
        let didRecover: (NativeRestoreActivationContext, NativeRestoreApplicationStartup, NativePersonalApplicationHost) async throws -> Void
        var confirmLocalReview: ((LocalReviewPrompt) async throws -> LocalReviewChoice)? = nil
    }
    private let startup: NativeRestoreApplicationStartup, paths: NativePersonalApplicationPaths, resources: URL
    private let runtimes: [NativeRestoreActivationRuntime], writers: [String], callbacks: Callbacks
    private let context: NativeRestoreActivationContext
    private var host: NativePersonalApplicationHost?
    private var permit: NativeRestorePreviousRecoveryPermit?
    private var anchor: NativeRestoreHostDescriptor?
    private var work: Task<NativePersonalApplicationHost, Error>?
    private var canceled = false, used = false

    init(startup: NativeRestoreApplicationStartup, paths: NativePersonalApplicationPaths, resources: URL,
         runtimes: [NativeRestoreActivationRuntime], writerParticipants: [String], callbacks: Callbacks) throws {
        try paths.validate(startup)
        guard startup.plan.mode == .recoveryRequired, let selection = startup.plan.selection,
              let journal = try startup.control.read("activation.json", as: NativeRestoreActivationJournal.self),
              journal.formatVersion == 1, journal.previous == selection, journal.candidate != selection,
              journal.activationID == startup.plan.activationID,
              [.selected,.draining,.drained,.validating,.reviewing,.ready,.restoringPrevious,.recoveryRequired].contains(journal.phase),
              let seal = journal.seal, journal.runtimeCatalog == runtimes.sorted(by: { $0.id < $1.id }),
              startup.lease.identity.uid == geteuid() else { throw NativeRestoreActivationFailure("personal.previousRecoverySelection") }
        let schema = try JSONDecoder().decode(NativeSchema.self, from: Data(contentsOf: resources.appendingPathComponent("schema.json")))
        guard schema.formatVersion == 1, schema.schemaSHA256 == seal.schemaSHA256 else { throw NativeRestoreActivationFailure("personal.previousRecoverySchema") }
        self.startup=startup; self.paths=paths; self.resources=resources; self.runtimes=runtimes; writers=writerParticipants; self.callbacks=callbacks
        context = .init(activationID: journal.activationID, previous: journal.previous, candidate: journal.candidate,
            seal: seal, inheritedPending: journal.inheritedPending, previousRunning: journal.previousRunning, runtimeCatalog: journal.runtimeCatalog)
    }
    func run() async throws -> NativePersonalApplicationHost {
        guard !used, !canceled else { throw NativeRestoreActivationFailure("personal.previousRecoveryUsed") }; used=true
        // Same open-file-description gate remains held even if a failed Host
        // closes its owned lease before the coordinator saves failure state.
        anchor = try startup.lease.handoffDescriptor()
        let task = Task { try await self.perform() }; work=task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { Task { @MainActor in self.cancel() } })
            work=nil; anchor?.close(); anchor=nil; return result
        } catch {
            work=nil; await host?.stopAndDrain(); host=nil; startup.lease.close(); anchor?.close(); anchor=nil; throw error
        }
    }
    func cancel() { canceled=true; work?.cancel(); host?.cancel() }
    func cancelAndDrain() async {
        cancel(); if let work { _ = await work.result }
        await host?.stopAndDrain(); host=nil; startup.lease.close(); anchor?.close(); anchor=nil
    }
    private func check(_ supplied: NativeRestoreActivationContext? = nil) throws {
        try Task.checkCancellation(); if canceled { throw CancellationError() }
        try paths.validate(startup)
        guard startup.lease.identity.uid == geteuid(),
              let journal = try startup.control.read("activation.json", as: NativeRestoreActivationJournal.self),
              let seal = journal.seal, journal.previous == startup.plan.selection,
              journal.candidate != startup.plan.selection,
              journal.runtimeCatalog == context.runtimeCatalog,
              try NativeRestoreActivation.subject(.init(activationID: journal.activationID, previous: journal.previous,
                candidate: journal.candidate, seal: seal, inheritedPending: journal.inheritedPending,
                previousRunning: journal.previousRunning, runtimeCatalog: journal.runtimeCatalog)) == NativeRestoreActivation.subject(context),
              try supplied == nil || NativeRestoreActivation.subject(supplied!) == NativeRestoreActivation.subject(context) else {
            throw NativeRestoreActivationFailure("personal.previousRecoveryChanged")
        }
    }
    private func authorize() async throws {
        try check(); try await callbacks.authorize(context); try check()
    }
    private func resume(_ supplied: NativeRestoreActivationContext) async throws -> NativeRestoreActivationStartup {
        try check(supplied); guard host == nil else { throw NativeRestoreActivationFailure("personal.previousRecoveryDuplicate") }
        let permit = try startup.preparePreviousRecovery(supplied); self.permit=permit
        let made = try callbacks.makeHost(startup, permit); host=made
        try await made.start(recoveringPrevious: startup, permit: permit)
        try check(supplied); try startup.validatePreviousRecovery(permit)
        let result = try await callbacks.readiness(supplied, startup, made)
        try check(supplied); try startup.validatePreviousRecovery(permit)
        return result // The real coordinator checks exact started/held coverage.
    }
    private func confirmLocalReview(_ supplied:NativeRestoreActivationContext,_ resumed:NativeRestoreActivationStartup)async throws->NativeRestorePersonalLocalRecovery {
        try check(supplied)
        guard let host,host.state == .running,let permit,let confirm=callbacks.confirmLocalReview,
              startup.plan.mode == .personalActiveLocal,startup.plan.runtimeReview != nil,
              startup.plan.permitted==["workspace.local"],let personal=startup.plan.personal,
              personal.phase == .bound,let policy=startup.plan.resumption else{throw NativeRestoreActivationFailure("personal.localRecoveryUnavailable")}
        try startup.validatePreviousRecovery(permit);try NativePersonalRestoreAdmission.validate(personal,startup:startup)
        guard try NativePersonalRuntimeResumption.resolve(startup:startup,personal:personal)==policy else{throw NativeRestoreActivationFailure("personal.runtimePolicyChanged")}
        let grantHash=try NativePersonalRestoreAdmission.hash(personal),recordHash=try NativePersonalRestoreAdmission.hash(policy)
        let receipt=NativeRestorePersonalLocalRecovery(version:1,contextSHA256:try NativeRestoreActivation.subject(supplied),
            personalGrantSHA256:grantHash,runtimeRecordSHA256:recordHash,startup:resumed)
        try NativeRestoreActivation.validatePersonalLocalRecovery(receipt,context:supplied)
        // The confirmation binds root/grant/policy and the actual held set. A
        // fresh readiness evidence is collected after the dialog closes.
        struct Subject:Encodable {let context:String,grant:String,policy:String,held:[String]}
        let subject=try NativePersonalRestoreAdmission.hash(Subject(context:receipt.contextSHA256,grant:grantHash,policy:recordHash,held:resumed.held.sorted()))
        let choice=try await confirm(.init(rootPath:supplied.previous.root.path,heldRuntimes:resumed.held.sorted(),subjectSHA256:subject))
        guard case .keepWorkersHeld(let confirmed)=choice,confirmed==subject else{throw NativeRestoreActivationFailure("personal.localRecoveryConfirmation")}
        try await authorize();try startup.validatePreviousRecovery(permit);try NativePersonalRestoreAdmission.validate(personal,startup:startup)
        guard try NativePersonalRuntimeResumption.resolve(startup:startup,personal:personal)==policy else{throw NativeRestoreActivationFailure("personal.runtimePolicyChanged")}
        let fresh=try await callbacks.readiness(supplied,startup,host)
        try check(supplied);try startup.validatePreviousRecovery(permit)
        guard fresh.started==resumed.started,fresh.held==resumed.held else{throw NativeRestoreActivationFailure("personal.localRecoveryReadiness")}
        return .init(version:1,contextSHA256:receipt.contextSHA256,personalGrantSHA256:grantHash,runtimeRecordSHA256:recordHash,startup:fresh)
    }
    private func perform() async throws -> NativePersonalApplicationHost {
        let engine = try NativeRestoreActivation(controlURL: startup.control.url,
            schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let hooks = NativeRestoreActivationHooks(runtimes: runtimes, writerParticipants: writers,
            authorize: { try await self.authorize() },
            capturePreviousRunning: { _ in throw NativeRestoreActivationFailure("personal.recoveryOnly") },
            drain: { _ in throw NativeRestoreActivationFailure("personal.recoveryOnly") },
            verifyRecoveryQuiescence: { context, selection in
                try self.check(context)
                guard self.host == nil, selection == self.context.previous else { throw NativeRestoreActivationFailure("personal.previousRecoveryLive") }
                let value = try await self.callbacks.verifyQuiescence(context, selection)
                try self.check(context); return value
            },
            review: { _,_ in throw NativeRestoreActivationFailure("personal.recoveryOnly") },
            reviewRow: { _,_,_ in throw NativeRestoreActivationFailure("personal.recoveryOnly") },
            preparePaused: { _,_ in throw NativeRestoreActivationFailure("personal.recoveryOnly") },
            resumeCommitted: { _,_ in throw NativeRestoreActivationFailure("personal.recoveryOnly") },
            closeCandidate: { context in
                try self.check(context)
                guard self.host == nil else { throw NativeRestoreActivationFailure("personal.previousRecoveryLive") }
            },
            resumePrevious: { context,_ in try await self.resume(context) },
            confirmPersonalLocalRecovery: { context,resumed in try await self.confirmLocalReview(context,resumed) })
        guard let result = try await engine.recover(hooks: hooks), result.selection == context.previous,
              result.journal.phase == .previousRestored, let host, let permit, host.state == .running else {
            throw NativeRestoreActivationFailure("personal.previousRecoveryIncomplete")
        }
        try check(); try startup.finishPreviousRecovery(permit)
        try await callbacks.didRecover(context, startup, host)
        try check()
        return host
    }
}
