import Foundation
import Darwin
import CryptoKit

actor NativeRestoreActivation {
    private let control: NativeRestoreActivationControl
    private let schemaURL: URL, sqlURL: URL
    private let clock: () -> Date
    private let checkpoint: (String) throws -> Void
    private var running = false
    static let reviewKinds = ["sourceProvenance","credentials","jobs","relayAndPluginState","pendingAssets","runtimeStartup"]
    init(controlURL: URL, schemaURL: URL, sqlURL: URL, clock: @escaping () -> Date = Date.init, checkpoint: @escaping (String) throws -> Void = {_ in}) throws {
        control = try .init(url:controlURL);self.schemaURL=schemaURL;self.sqlURL=sqlURL;self.clock=clock;self.checkpoint=checkpoint
    }
    static func subject(_ context: NativeRestoreActivationContext) throws -> String {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        var bytes = Data(context.activationID.utf8);bytes.append(try encoder.encode(context.previous));bytes.append(try encoder.encode(context.candidate));bytes.append(try encoder.encode(context.seal))
        bytes.append(try encoder.encode(context.previousRunning));bytes.append(try encoder.encode(context.runtimeCatalog))
        return NativeMigrationCodec.hash(bytes)
    }
    static func validatePersonalLocalRecovery(_ receipt:NativeRestorePersonalLocalRecovery,context:NativeRestoreActivationContext)throws {
        let previous=Set(context.previousRunning),started=receipt.startup.started,held=receipt.startup.held
        guard receipt.version==1,receipt.contextSHA256==(try subject(context)),
              NativeMigrationCodec.validHash(receipt.personalGrantSHA256),NativeMigrationCodec.validHash(receipt.runtimeRecordSHA256),
              previous.count==context.previousRunning.count,previous.contains("workspace.local"),previous.count>1,
              previous.isSubset(of:Set(context.runtimeCatalog.map(\.id))),
              started==["workspace.local"],held.count==Set(held).count,Set(held)==previous.subtracting(["workspace.local"]),
              NativeMigrationCodec.validHash(receipt.startup.evidenceSHA256) else{throw NativeRestoreActivationFailure("recovery.personalLocalReceipt")}
    }
    private func currentPreviousRecovery(_ context:NativeRestoreActivationContext)throws {
        try control.validate()
        guard try control.read("active-root.json",as:NativeRestoreActivationSelection.self)==context.previous,
              try NativeRestoreActivationControl.root(context.previous.root.url)==context.previous.root,
              let current=try control.read("activation.json",as:NativeRestoreActivationJournal.self),current.phase == .restoringPrevious,
              try Self.subject(self.context(current))==Self.subject(context) else{throw NativeRestoreActivationFailure("recovery.changed")}
    }
    private func save(_ journal: NativeRestoreActivationJournal) throws { try control.write(journal,name:"activation.json");try checkpoint(journal.phase.rawValue) }
    private func validateHooks(_ hooks: NativeRestoreActivationHooks) throws {
        let ids = hooks.runtimes.map(\.id)
        guard !hooks.writerParticipants.isEmpty, hooks.writerParticipants.count <= 256, hooks.runtimes.count <= 128,
              Set(ids).count == ids.count, Set(hooks.writerParticipants).count == hooks.writerParticipants.count,
              (ids+hooks.writerParticipants).allSatisfy({!$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0")}),
              hooks.runtimes.allSatisfy({$0.events.count <= 256 && Set($0.events).count == $0.events.count && $0.events.allSatisfy{!$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0")}}) else { throw NativeRestoreActivationFailure("host.catalog") }
    }
    private func authorize(_ hooks: NativeRestoreActivationHooks) async throws {
        try Task.checkCancellation()
        do{try await hooks.authorize()}catch is CancellationError{throw CancellationError()}catch{throw NativeRestoreActivationFailure("host.authorization")}
        try Task.checkCancellation();try control.validate()
    }
    private func validateDrain(_ value: NativeRestoreActivationDrain, context: NativeRestoreActivationContext, hooks: NativeRestoreActivationHooks) throws {
        guard value.root == context.previous.root, value.participants.count == hooks.writerParticipants.count, Set(value.participants) == Set(hooks.writerParticipants),
              Set(value.previouslyRunning).isSubset(of:Set(hooks.runtimes.map(\.id))), Set(value.previouslyRunning).count == value.previouslyRunning.count,
              Set(value.previouslyRunning) == Set(context.previousRunning),
              value.unfinishedTasks == 0, value.openWritableHandles == 0, value.unsavedEditors == 0, value.pendingCallbacks == 0,
              NativeMigrationCodec.validHash(value.evidenceSHA256) else { throw NativeRestoreActivationFailure("host.notDrained") }
    }
    private func validateEvidence(_ evidence: NativeRestoreActivationEvidence, kind: String, context: NativeRestoreActivationContext, hooks: NativeRestoreActivationHooks) throws {
        guard evidence.kind == kind, evidence.subjectSHA256 == (try Self.subject(context)), NativeMigrationCodec.validHash(evidence.evidenceSHA256),
              evidence.checkedAt <= clock(), evidence.validUntil > clock(), evidence.checkedAt <= evidence.validUntil,
              Set(evidence.blockedRuntimes).count == evidence.blockedRuntimes.count, Set(evidence.blockedRuntimes).isSubset(of:Set(hooks.runtimes.map(\.id))),
              ["verified","explicitlyDeferred"].contains(evidence.disposition), evidence.disposition != "explicitlyDeferred" || !evidence.blockedRuntimes.isEmpty else { throw NativeRestoreActivationFailure("review.invalidEvidence") }
    }
    private func review(_ context: NativeRestoreActivationContext, hooks: NativeRestoreActivationHooks, journal: inout NativeRestoreActivationJournal) async throws {
        journal.evidence = [];journal.decisionsRows = 0
        var held = Set<String>()
        for kind in Self.reviewKinds {
            let evidence = try await hooks.review(kind,context);try await authorize(hooks)
            try validateEvidence(evidence,kind:kind,context:context,hooks:hooks);journal.evidence.append(evidence);held.formUnion(evidence.blockedRuntimes)
        }
        let ledger = "decisions-"+UUID().uuidString.lowercased()+".ndjson"
        let fd = try control.createLedger(ledger);defer{close(fd)}
        let cursor = try NativeRestoreActivationPlanCursor(root:context.candidate.root.url,seal:context.seal)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        var digest = SHA256()
        while let (row,rowHash) = try cursor.next() {
            let decision = try await hooks.reviewRow(row,rowHash,context);try await authorize(hooks)
            let blocked = Set(decision.blockedRuntimes), known = Set(hooks.runtimes.map(\.id))
            guard decision.rowSHA256 == rowHash, NativeMigrationCodec.validHash(decision.evidenceSHA256), blocked.count == decision.blockedRuntimes.count, blocked.isSubset(of:known),
                  ["preserved","reconciled","explicitlyDeferred"].contains(decision.disposition), decision.disposition != "explicitlyDeferred" || !blocked.isEmpty else { throw NativeRestoreActivationFailure("review.row") }
            if decision.disposition == "explicitlyDeferred", let event = row.event {
                let matching = Set(hooks.runtimes.filter{$0.events.contains(event)}.map(\.id))
                let required = matching.isEmpty ? Set(hooks.runtimes.filter(\.canProduceExternalEffects).map(\.id)) : matching
                guard required.isSubset(of:blocked) else { throw NativeRestoreActivationFailure("review.eventNotFenced") }
            }
            var line = try encoder.encode(decision);line.append(10);guard line.count <= 65536 else { throw NativeRestoreActivationFailure("review.lineLimit") }
            try NativeMigrationImportWorkspace.write(line,to:fd);digest.update(data:line);journal.decisionsRows += 1;held.formUnion(blocked)
        }
        guard journal.decisionsRows == context.seal.planRows, fsync(fd) == 0 else { throw NativeRestoreActivationFailure("review.incomplete") }
        try control.sync();journal.decisionsSHA256 = digest.finalize().map{String(format:"%02x",$0)}.joined();journal.decisionsFile = ledger
        journal.heldRuntimes = held.sorted();journal.permittedRuntimes = hooks.runtimes.map(\.id).filter{!held.contains($0)}.sorted()
    }
    private func startup(_ value: NativeRestoreActivationStartup, permitted: [String], held: [String]) throws {
        guard value.started.count == Set(value.started).count, value.held.count == Set(value.held).count,
              Set(value.started) == Set(permitted), Set(value.held) == Set(held), NativeMigrationCodec.validHash(value.evidenceSHA256) else { throw NativeRestoreActivationFailure("host.startupIncomplete") }
    }
    private func context(_ journal: NativeRestoreActivationJournal) throws -> NativeRestoreActivationContext {
        guard journal.formatVersion == 1, let seal = journal.seal else { throw NativeRestoreActivationFailure("recovery.journal") }
        return .init(activationID:journal.activationID,previous:journal.previous,candidate:journal.candidate,seal:seal,inheritedPending:journal.inheritedPending,previousRunning:journal.previousRunning,runtimeCatalog:journal.runtimeCatalog)
    }
    private func recoveryQuiescence(_ hooks: NativeRestoreActivationHooks, context: NativeRestoreActivationContext, selection: NativeRestoreActivationSelection) async throws {
        guard context.runtimeCatalog == hooks.runtimes.sorted(by:{$0.id < $1.id}) else { throw NativeRestoreActivationFailure("recovery.catalogChanged") }
        let report:NativeRestoreActivationDrain
        do{report = try await hooks.verifyRecoveryQuiescence(context,selection)}catch is CancellationError{throw CancellationError()}catch{throw NativeRestoreActivationFailure("recovery.notQuiescent")}
        try await authorize(hooks)
        guard report.root == selection.root, report.participants.count == hooks.writerParticipants.count,
              Set(report.participants) == Set(hooks.writerParticipants), report.previouslyRunning.isEmpty,
              report.unfinishedTasks == 0, report.openWritableHandles == 0, report.unsavedEditors == 0, report.pendingCallbacks == 0,
              NativeMigrationCodec.validHash(report.evidenceSHA256),
              try control.read("active-root.json",as:NativeRestoreActivationSelection.self) == selection,
              try NativeRestoreActivationControl.root(selection.root.url) == selection.root else { throw NativeRestoreActivationFailure("recovery.notQuiescent") }
    }
    /// Caller-selected completed candidate becomes the final root. Both roots
    /// remain on disk. No Session/credential/job mass rewrite is performed.
    func activate(candidateURL: URL, currentRootURL: URL, hooks: NativeRestoreActivationHooks) async throws -> NativeRestoreActivationResult {
        guard !running else { throw NativeRestoreActivationFailure("activation.busy") };running=true;defer{running=false}
        try validateHooks(hooks);try control.acquire();defer{control.release()}
        try await authorize(hooks)
        let verifier = NativeRestoreActivationVerifier(schemaURL:schemaURL,sqlURL:sqlURL,cancelled:{Task.isCancelled})
        let candidate = try verifier.inspect(candidateURL), previousRoot = try NativeRestoreActivationControl.root(currentRootURL)
        guard !(candidate.root.device == previousRoot.device && candidate.root.inode == previousRoot.inode), !candidate.root.path.hasPrefix(previousRoot.path+"/"), !previousRoot.path.hasPrefix(candidate.root.path+"/") else { throw NativeRestoreActivationFailure("root.overlap") }
        var previous = try control.read("active-root.json",as:NativeRestoreActivationSelection.self)
        if previous == nil { previous = .init(generation:UUID().uuidString.lowercased(),root:previousRoot);try control.write(previous!,name:"active-root.json") }
        guard previous!.root == previousRoot else { throw NativeRestoreActivationFailure("root.staleSelection") }
        if let existing = try control.read("activation.json",as:NativeRestoreActivationJournal.self), ![.active,.previousRestored].contains(existing.phase) { throw NativeRestoreActivationFailure("recovery.required") }
        let id = UUID().uuidString.lowercased(), selected = NativeRestoreActivationSelection(generation:UUID().uuidString.lowercased(),root:candidate.root)
        var journal = NativeRestoreActivationJournal(activationID:id,phase:.selected,previous:previous!,candidate:selected,seal:candidate.seal,inheritedPending:candidate.result.inheritedPending)
        journal.runtimeCatalog = hooks.runtimes.sorted{$0.id < $1.id}
        let previousRunning:[String]
        do{previousRunning = try await hooks.capturePreviousRunning(context(journal))}catch is CancellationError{throw CancellationError()}catch{throw NativeRestoreActivationFailure("host.previousPolicy")}
        try await authorize(hooks)
        guard previousRunning.count == Set(previousRunning).count,Set(previousRunning).isSubset(of:Set(hooks.runtimes.map(\.id))) else { throw NativeRestoreActivationFailure("host.previousPolicy") }
        journal.previousRunning = previousRunning.sorted()
        let ctx = try context(journal)
        try save(journal)
        var drainAttempted = false
        do {
            journal.phase = .draining;try save(journal);drainAttempted = true
            let drained = try await hooks.drain(ctx);try validateDrain(drained,context:ctx,hooks:hooks);journal.drain = drained
            try await authorize(hooks);journal.phase = .drained;try save(journal)
            journal.phase = .validating;try save(journal);try verifier.validate(candidate);try await authorize(hooks)
            journal.phase = .reviewing;try save(journal);try await review(ctx,hooks:hooks,journal:&journal)
            try verifier.unchanged(candidate);try await hooks.preparePaused(ctx,journal.permittedRuntimes);try await authorize(hooks)
            // Paused construction may not mutate candidate rows or create jobs.
            try verifier.unchanged(candidate)
            for evidence in journal.evidence { try validateEvidence(evidence,kind:evidence.kind,context:ctx,hooks:hooks) }
            guard try NativeRestoreActivationControl.root(previousRoot.url) == previousRoot else { throw NativeRestoreActivationFailure("root.previousChanged") }
            journal.phase = .ready;try save(journal);try await authorize(hooks)
            // The final authorization can suspend. Recheck the sealed candidate,
            // roots and evidence after it, with no further await before commit.
            try verifier.unchanged(candidate)
            guard try NativeRestoreActivationControl.root(previousRoot.url) == previousRoot else { throw NativeRestoreActivationFailure("root.previousChanged") }
            for evidence in journal.evidence { try validateEvidence(evidence,kind:evidence.kind,context:ctx,hooks:hooks) }
            guard try control.read("active-root.json",as:NativeRestoreActivationSelection.self) == previous else { throw NativeRestoreActivationFailure("root.concurrentSelection") }
            try control.write(selected,name:"active-root.json");try checkpoint("pointerCommitted")
            journal.phase = .committed;try save(journal)
            try Task.checkCancellation() // a post-commit cancel never rolls back.
            journal.phase = .starting;try save(journal)
            let started = try await hooks.resumeCommitted(ctx,journal.permittedRuntimes)
            try checkpoint("providersStarted")
            try startup(started,permitted:journal.permittedRuntimes,held:journal.heldRuntimes)
            journal.startup = started;journal.phase = .active;try save(journal)
            return .init(journal:journal,selection:selected)
        } catch {
            // Providers may include request bodies, credentials or remote error
            // text in any Error, including this module's failure type. Persist
            // only our enum-derived phase; never their description/code.
            journal.failureCode = error is CancellationError ? "cancelled" : "activation."+journal.phase.rawValue+".failed"
            // Read actual pointer even when its fsync/reporting threw: rename may
            // already have succeeded. Never infer rollback from an in-memory flag.
            guard let actual = try control.read("active-root.json",as:NativeRestoreActivationSelection.self) else { throw NativeRestoreActivationFailure("recovery.unknownSelection") }
            if actual == selected {
                journal.phase = .activeDegraded;try save(journal);return .init(journal:journal,selection:actual)
            }
            guard actual == previous else { throw NativeRestoreActivationFailure("recovery.foreignSelection") }
            journal.phase = .restoringPrevious;try save(journal)
            do {
                // Compensation must drain/restart even if the caller cancelled.
                // Await an independent task; never detach it and claim recovery.
                let oldDrain = journal.drain, shouldResume = drainAttempted
                let compensation = Task.detached { () throws -> NativeRestoreActivationStartup? in
                    try await hooks.closeCandidate(ctx)
                    return shouldResume ? try await hooks.resumePrevious(ctx,oldDrain) : nil
                }
                if let resumed = try await compensation.value { try startup(resumed,permitted:journal.previousRunning,held:[]) }
                journal.phase = .previousRestored
            } catch { journal.phase = .recoveryRequired }
            try save(journal);return .init(journal:journal,selection:actual)
        }
    }
    /// Cold-start recovery inspects durable selection. Candidate selection is
    /// returned held; explicit resumeRecovered performs fresh provider review.
    func recover(hooks: NativeRestoreActivationHooks) async throws -> NativeRestoreActivationResult? {
        guard !running else { throw NativeRestoreActivationFailure("activation.busy") };running=true;defer{running=false}
        try validateHooks(hooks);try control.acquire();defer{control.release()};try await authorize(hooks)
        guard var journal = try control.read("activation.json",as:NativeRestoreActivationJournal.self) else { return nil }
        guard let selection = try control.read("active-root.json",as:NativeRestoreActivationSelection.self), try NativeRestoreActivationControl.root(selection.root.url) == selection.root else { throw NativeRestoreActivationFailure("recovery.rootChanged") }
        let ctx = try context(journal)
        try await recoveryQuiescence(hooks,context:ctx,selection:selection)
        if selection == journal.candidate {
            // Even a previously successful activation has no live runtimes in
            // this new process. Reconcile CURRENT provider state before resume.
            journal.phase = .activeDegraded;journal.startup=nil;try save(journal)
            return .init(journal:journal,selection:selection)
        }
        guard selection == journal.previous else { throw NativeRestoreActivationFailure("recovery.foreignSelection") }
        journal.phase = .restoringPrevious;try save(journal)
        do {
            try await hooks.closeCandidate(ctx)
            let resumed = try await hooks.resumePrevious(ctx,journal.drain)
            if Set(resumed.started)==Set(journal.previousRunning),resumed.held.isEmpty {
                try startup(resumed,permitted:journal.previousRunning,held:[])
            }else{
                guard let confirm=hooks.confirmPersonalLocalRecovery else{throw NativeRestoreActivationFailure("host.startupIncomplete")}
                let receipt=try await confirm(ctx,resumed)
                try Self.validatePersonalLocalRecovery(receipt,context:ctx)
                guard receipt.startup.started==resumed.started,receipt.startup.held==resumed.held else{throw NativeRestoreActivationFailure("recovery.personalLocalChanged")}
                journal.recoveryStartup=receipt
            }
            try await authorize(hooks);try currentPreviousRecovery(ctx)
            journal.phase = .previousRestored
        } catch { journal.phase = .recoveryRequired;journal.failureCode = "recovery.resumePrevious" }
        // Never overwrite a concurrent/foreign selection or journal on failure.
        try currentPreviousRecovery(ctx)
        try save(journal);return .init(journal:journal,selection:selection)
    }
    /// Cold recovery only, before any runtime is running. Old backup bytes are
    /// not required to match a DB that may already contain committed effects;
    /// provider review must reconcile each plan row against CURRENT DB/receipts.
    func resumeRecovered(hooks: NativeRestoreActivationHooks) async throws -> NativeRestoreActivationResult {
        guard !running else { throw NativeRestoreActivationFailure("activation.busy") };running=true;defer{running=false}
        try validateHooks(hooks);try control.acquire();defer{control.release()};try await authorize(hooks)
        guard var journal = try control.read("activation.json",as:NativeRestoreActivationJournal.self), let selection = try control.read("active-root.json",as:NativeRestoreActivationSelection.self), selection == journal.candidate,
              [.committed,.starting,.activeDegraded].contains(journal.phase), try NativeRestoreActivationControl.root(selection.root.url) == selection.root else { throw NativeRestoreActivationFailure("recovery.notCandidate") }
        let ctx = try context(journal)
        try await recoveryQuiescence(hooks,context:ctx,selection:selection)
        do {
            try await review(ctx,hooks:hooks,journal:&journal);try await hooks.preparePaused(ctx,journal.permittedRuntimes);try await authorize(hooks)
            for evidence in journal.evidence { try validateEvidence(evidence,kind:evidence.kind,context:ctx,hooks:hooks) }
            guard try control.read("active-root.json",as:NativeRestoreActivationSelection.self) == selection,
                  try NativeRestoreActivationControl.root(selection.root.url) == selection.root else { throw NativeRestoreActivationFailure("recovery.rootChanged") }
            journal.phase = .starting;try save(journal)
            let started = try await hooks.resumeCommitted(ctx,journal.permittedRuntimes);try checkpoint("providersStarted");try startup(started,permitted:journal.permittedRuntimes,held:journal.heldRuntimes)
            journal.startup = started;journal.phase = .active;try save(journal)
        } catch { journal.phase = .activeDegraded;journal.failureCode = "recovery.provider";try save(journal) }
        return .init(journal:journal,selection:selection)
    }
}
