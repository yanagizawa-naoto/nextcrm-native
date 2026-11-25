import Foundation

/// Authorization of local edits only. This never issues provider verification,
/// changes an old job, or grants an imported CRM user a different role.
enum NativePersonalRestoreAdmission {
    static let contract="personal-local-mutable-v1"
    enum Phase:String,Codable {case bindingPending,bound}
    struct Record:Codable,Equatable {
        let version:Int,contract:String,transitionID:String,revision:Int
        let authority:NativePersonalRestoreAuthority.Evidence
        let activationID:String,seal:NativeRestoreActivationSeal,catalogSHA256:String
        let owner:NativePersonalWorkspace.BindingDescriptor
        let approvedSubjectSHA256:String,approvedAt:Date
        var phase:Phase,boundAt:Date?
        var filename:String{"personal-workspace-"+authority.selection.generation+".json"}
    }
    struct Prompt:Codable,Equatable {
        let subjectSHA256:String,ownerID:String,rootPath:String
        let held:[String],validUntil:Date
    }
    enum Choice {
        case enableLocalEditingAndKeepExternalHeld(subjectSHA256:String)
    }
    struct Approval {
        fileprivate let record:Record,expires:Date
    }
    struct Opened {
        let db:NativeDatabase,identity:CRMIdentity,record:Record
        /// Strong lifetime: weak DB callbacks must not become a rule bypass.
        let rules:NativePersonalLocalPluginHost
    }
    typealias Confirm=(Prompt) async throws -> Choice
    typealias OpenWritable=(URL) throws -> NativeDatabase
    typealias PrepareLocalRules=(NativeDatabase,@escaping ()throws->Void) throws -> NativePersonalLocalPluginHost

    static func hash<T:Encodable>(_ value:T)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return NativeMigrationCodec.hash(try encoder.encode(value))
    }
    static func catalog()throws->String{try hash(NativeRestoreRuntimeCatalog.runtimes)}
    private static func journal(_ startup:NativeRestoreApplicationStartup)throws->NativeRestoreActivationJournal {
        guard let value=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              value.formatVersion==1,value.phase == .active,value.candidate==startup.plan.selection,
              value.activationID==startup.plan.activationID,let _=value.seal,
              value.runtimeCatalog==NativeRestoreRuntimeCatalog.runtimes,
              value.permittedRuntimes==["workspace.local"],
              Set(value.heldRuntimes)==Set(NativeRestoreRuntimeCatalog.heldAutomatic),
              value.heldRuntimes.count==NativeRestoreRuntimeCatalog.heldAutomatic.count else{
            throw NativeRestoreActivationFailure("personal.activationNotHeldActive")
        };return value
    }
    private static func readOwner(_ record:Record,verifier:NativeRestoreActivationVerifier)throws {
        let db=try NativeDatabase(readOnlyURL:record.authority.selection.root.url.appendingPathComponent("crm.sqlite"),schemaURL:verifier.schemaURL)
        let fresh=try NativePersonalWorkspace.select(db,userID:record.owner.ownerID)
        guard fresh.descriptor==record.owner else{throw NativeRestoreActivationFailure("personal.ownerChanged")}
    }
    /// A required UI callback receives the full bound subject; an email/user ID
    /// alone cannot produce this value. Real candidate validation precedes it.
    static func review(startup:NativeRestoreApplicationStartup,verifier:NativeRestoreActivationVerifier,
                       owner:NativePersonalWorkspace.Selection,clock:()->Date=Date.init,
                       confirm:Confirm) async throws -> Approval {
        guard startup.plan.mode == .restoredHeld || startup.plan.mode == .approvedHandoff else{
            throw NativeRestoreActivationFailure("personal.reviewMode")
        }
        let authority=try NativePersonalRestoreAuthority.check(startup),current=try journal(startup)
        guard let seal=current.seal else{throw NativeRestoreActivationFailure("personal.seal")}
        let candidate=try verifier.inspect(authority.selection.root.url)
        guard candidate.root==authority.selection.root,candidate.seal==seal else{throw NativeRestoreActivationFailure("personal.sealChanged")}
        try verifier.validate(candidate)
        let now=clock(),expiry=now.addingTimeInterval(300),transition=UUID().uuidString.lowercased()
        struct Subject:Encodable {
            let domain:String,transitionID:String,authority:NativePersonalRestoreAuthority.Evidence
            let activationID:String,seal:NativeRestoreActivationSeal,catalogSHA256:String
            let owner:NativePersonalWorkspace.BindingDescriptor,approvedAt:Date,validUntil:Date
            let held:[String]
        }
        let subject=try hash(Subject(domain:contract,transitionID:transition,authority:authority,
            activationID:current.activationID,seal:seal,catalogSHA256:catalog(),owner:owner.descriptor,
            approvedAt:now,validUntil:expiry,held:NativeRestoreRuntimeCatalog.heldAutomatic.sorted()))
        let record=Record(version:1,contract:contract,transitionID:transition,revision:1,authority:authority,
            activationID:current.activationID,seal:seal,catalogSHA256:try catalog(),owner:owner.descriptor,
            approvedSubjectSHA256:subject,approvedAt:now,phase:.bindingPending,boundAt:nil)
        try readOwner(record,verifier:verifier)
        let choice=try await confirm(.init(subjectSHA256:subject,ownerID:owner.descriptor.ownerID,
            rootPath:authority.selection.root.path,held:NativeRestoreRuntimeCatalog.heldAutomatic.sorted(),validUntil:expiry))
        guard case let .enableLocalEditingAndKeepExternalHeld(confirmed)=choice,confirmed==subject,
              clock()>=now,clock()<expiry else{throw NativeRestoreActivationFailure("personal.approval")}
        _ = try NativePersonalRestoreAuthority.check(startup,expected:authority)
        guard try journal(startup).seal==seal else{throw NativeRestoreActivationFailure("personal.journalChanged")}
        try verifier.unchanged(candidate);try readOwner(record,verifier:verifier)
        return .init(record:record,expires:expiry)
    }
    /// Must succeed and fsync before ANY writable initializer. A crash later is
    /// authorized binding preparation, not evidence that the original seal held.
    static func begin(_ approval:Approval,startup:NativeRestoreApplicationStartup,
                      verifier:NativeRestoreActivationVerifier,clock:()->Date=Date.init)throws->Record {
        let record=approval.record,now=clock()
        guard now>=record.approvedAt,now<approval.expires else{throw NativeRestoreActivationFailure("personal.expired")}
        try startup.control.acquire();defer{startup.control.release()}
        _ = try NativePersonalRestoreAuthority.check(startup,expected:record.authority)
        let current=try journal(startup)
        guard current.seal==record.seal,current.activationID==record.activationID,
              try startup.control.read(record.filename,as:Record.self)==nil else{
            throw NativeRestoreActivationFailure("personal.staleApproval")
        }
        let candidate=try verifier.inspect(record.authority.selection.root.url)
        guard candidate.seal==record.seal else{throw NativeRestoreActivationFailure("personal.sealChanged")}
        try verifier.unchanged(candidate);try readOwner(record,verifier:verifier)
        guard clock()>=record.approvedAt,clock()<approval.expires else{throw NativeRestoreActivationFailure("personal.expired")}
        _ = try NativePersonalRestoreAuthority.check(startup,expected:record.authority)
        try Task.checkCancellation();try startup.control.write(record,name:record.filename)
        return record
    }
    static func validate(_ record:Record,startup:NativeRestoreApplicationStartup)throws {
        guard record.version==1,record.contract==contract,UUID(uuidString:record.transitionID) != nil,
              record.revision==(record.phase == .bound ? 2:1),
              NativeMigrationCodec.validHash(record.approvedSubjectSHA256),
              record.catalogSHA256==(try catalog()),
              (record.phase == .bound)==(record.boundAt != nil),
              try startup.control.read(record.filename,as:Record.self)==record else{
            throw NativeRestoreActivationFailure("personal.mutableRecord")
        }
        _ = try NativePersonalRestoreAuthority.check(startup,expected:record.authority)
        guard let current=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              current.formatVersion==1,current.runtimeCatalog==NativeRestoreRuntimeCatalog.runtimes else{
            throw NativeRestoreActivationFailure("personal.journalChanged")
        }
        if current.candidate==record.authority.selection {
            guard current.phase == .active,current.activationID==record.activationID,current.seal==record.seal,
                  current.permittedRuntimes==["workspace.local"],
                  Set(current.heldRuntimes)==Set(NativeRestoreRuntimeCatalog.heldAutomatic) else{
                throw NativeRestoreActivationFailure("personal.journalChanged")
            }
        } else {
            // A later failed restore may have a different journal/seal. The old
            // generation's local capability survives only actual compensation.
            let policy=try NativePersonalRuntimeResumption.resolve(startup:startup,personal:record)
            // A policy explicitly reviewed after this compensation can reduce
            // or change groups without rewriting the historical started set.
            // resolve above binds its subject to the same root/owner/catalog.
            let currentEpoch=policy?.approvalActivationID==current.activationID
            guard (try current.phase == .previousRestored || startup.permitsPreviousRecovery(current)),current.previous==record.authority.selection,
                  (current.previousRunning == ["workspace.local"] || current.previousRunning == NativePersonalRuntimeResumption.permitted(policy) || currentEpoch),record.phase == .bound else{
                throw NativeRestoreActivationFailure("personal.previousPolicy")
            }
        }
    }
    /// No content hash recheck after durable pending: writable SQLite bootstrap
    /// and localActor bind may already have committed before a process crash.
    static func resolve(startup:NativeRestoreApplicationStartup)throws->Record? {
        guard let selected=startup.plan.selection else{return nil}
        guard UUID(uuidString:selected.generation) != nil else{throw NativeRestoreActivationFailure("personal.generation")}
        let name="personal-workspace-"+selected.generation+".json"
        guard let record=try startup.control.read(name,as:Record.self) else{return nil}
        guard record.filename==name else{throw NativeRestoreActivationFailure("personal.recordSelection")}
        try validate(record,startup:startup);return record
    }
    static func plan(for record:Record,startup:NativeRestoreApplicationStartup)throws->NativeRestoreApplicationStartupPlan {
        try validate(record,startup:startup)
        let resumption=try NativePersonalRuntimeResumption.resolve(startup:startup,personal:record)
        var runtimeReview:NativePersonalRuntimeResumption.ReviewSummary?
        if let resumption {runtimeReview=try NativePersonalRuntimeResumption.priorHold(record:resumption,startup:startup)}
        let permitted=runtimeReview == nil ? NativePersonalRuntimeResumption.permitted(resumption):["workspace.local"]
        var result=NativeRestoreApplicationStartupPlan(root:record.authority.selection.root,
            selection:record.authority.selection,mode:record.phase == .bound ? .personalActiveLocal:.personalBindingPending,
            permitted:permitted,held:NativeRestoreRuntimeCatalog.ids.filter{!permitted.contains($0)}.sorted(),
            activationID:startup.plan.activationID,requiresReview:true)
        result.personal=record;result.resumption=resumption;result.runtimeReview=runtimeReview;return result
    }
    /// Returned local hook owner must be retained by App before mutations are
    /// admitted. Both closures are mandatory; no bootstrap/provider defaults.
    static func complete(_ record:Record,startup:NativeRestoreApplicationStartup,
                         openWritable:OpenWritable,prepareLocalRules:PrepareLocalRules,
                         checkpoint:(String)throws->Void={_ in})throws->Opened {
        try validate(record,startup:startup);try checkpoint("beforeOpen")
        let db=try openWritable(record.authority.selection.root.url)
        guard !db.isReadOnly,db.schema.schemaSHA256==record.owner.schemaSHA256,
              db.url.resolvingSymlinksInPath().standardizedFileURL==record.authority.selection.root.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL else{
            throw NativeRestoreActivationFailure("personal.opener")
        }
        try validate(record,startup:startup);try checkpoint("opened")
        let fence={try validate(record,startup:startup)}
        let identity=try NativePersonalWorkspace.resumeBinding(record.owner,to:db,authorize:fence)
        try checkpoint("ownerBound")
        let rules=try prepareLocalRules(db,fence);try rules.validate()
        var bound=record
        if record.phase == .bindingPending {
            bound=Record(version:record.version,contract:record.contract,transitionID:record.transitionID,revision:2,
                authority:record.authority,activationID:record.activationID,seal:record.seal,catalogSHA256:record.catalogSHA256,
                owner:record.owner,approvedSubjectSHA256:record.approvedSubjectSHA256,approvedAt:record.approvedAt,
                phase:.bound,boundAt:Date())
            try startup.control.acquire();defer{startup.control.release()}
            try validate(record,startup:startup);try Task.checkCancellation()
            try startup.control.write(bound,name:bound.filename)
        }
        // The live fence now follows exactly this bound revision. Keeping a
        // pending-record closure would falsely reject every subsequent edit.
        rules.replaceAuthority{try validate(bound,startup:startup)}
        try checkpoint("bound");return .init(db:db,identity:identity,record:bound,rules:rules)
    }
}
