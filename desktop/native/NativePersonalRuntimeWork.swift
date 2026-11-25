import Foundation

/// The caller awaits every task, including a cancelled/non-cooperative body.
/// Nothing returned from a review step retains the old App or its CRMService.
enum NativePersonalRuntimeWork {
    typealias Stores=(CRMService)throws->NativePersonalRuntimePrerequisites.Stores
    static func joined<T>(_ operation:@escaping()async throws->T)async throws->T {
        let task=Task.detached(priority:.userInitiated){
            try Task.checkCancellation();let value=try await operation();try Task.checkCancellation();return value
        }
        return try await withTaskCancellationHandler(operation:{
            do {let value=try await task.value;try Task.checkCancellation();return value}
            catch {task.cancel();_ = await task.result;throw error}
        },onCancel:{task.cancel()})
    }
    static func workspace(startup:NativeRestoreApplicationStartup,resources:URL,stores:@escaping Stores,
                          approval:NativePersonalRuntimeResumption.Approval?=nil,
                          permit:NativePersonalRuntimeResumption.DrainPermit?=nil)async throws->NativePersonalApplicationHost.Workspace {
        try await joined {
            guard let record=try NativePersonalRestoreAdmission.resolve(startup:startup) else{throw NativeRestoreActivationFailure("personal.recordMissing")}
            let opened=try NativePersonalRestoreAdmission.complete(record,startup:startup,
                openWritable:{root in try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))},
                prepareLocalRules:{db,authorize in try NativePersonalLocalPluginHost(db:db,
                    definitions:[NativeAccountProtection.definition(),NativeAresPlugin.definition(),NativeOdooPlugin.definition,NativeOXOConnector.definition()],
                    transitionID:record.transitionID,authorize:authorize)})
            let service=CRMService(db:opened.db,identity:opened.identity)
            let verifier=NativePersonalRuntimePrerequisites.verifier(startup:startup,personal:opened.record,stores:stores,clock:Date.init)
            let active:NativePersonalRuntimeResumption.Active?,review:NativePersonalRuntimeResumption.ReviewHold?
            if let approval {
                guard let permit else{throw NativeRestoreActivationFailure("personal.runtimeDrainPermit")}
                active=try NativePersonalRuntimeResumption.commit(approval,permit:permit,service:service,startup:startup,requirements:verifier);review=nil
            } else {
                guard permit==nil else{throw NativeRestoreActivationFailure("personal.runtimeDrainPermit")}
                switch try NativePersonalRuntimeResumption.resolveOpened(service:service,startup:startup,requirements:verifier) {
                case .localOnly:active=nil;review=nil
                case .active(let value):active=value;review=nil
                case .reviewRequired(let value):active=nil;review=value
                }
            }
            let plan:NativeRestoreApplicationStartupPlan
            if active != nil || review != nil {plan=startup.plan}
            else {plan=try NativePersonalRestoreAdmission.plan(for:opened.record,startup:startup)}
            return .init(service:service,plan:plan,owner:try NativePersonalWorkspace.select(opened.db,userID:opened.identity.id),
                retainedRules:opened.rules,resumption:active,runtimeReview:review)
        }
    }
    struct DependencyFailure:Error {}
    static func assertCurrent(service:CRMService,startup:NativeRestoreApplicationStartup,
                              personal:NativePersonalRestoreAdmission.Record,
                              expected:NativePersonalRuntimeResumption.Record?)throws {
        try Task.checkCancellation();try NativePersonalRestoreAdmission.validate(personal,startup:startup)
        guard personal.phase == .bound,!service.db.isReadOnly,service.identity.id==personal.owner.ownerID,
              service.db.schema.schemaSHA256==personal.owner.schemaSHA256,
              service.db.url.resolvingSymlinksInPath().standardizedFileURL==personal.authority.selection.root.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL,
              try service.db.metadata("localActor")==service.identity.id else{throw NativeRestoreActivationFailure("personal.runtimeOwner")}
        try service.authenticated()
        guard try NativePersonalRuntimeResumption.resolve(startup:startup,personal:personal)==expected else{throw NativeRestoreActivationFailure("personal.runtimePolicyChanged")}
    }
    static func approval(service:CRMService,startup:NativeRestoreApplicationStartup,
                         settings:Set<NativePersonalRuntimeGroup>,workers:Set<NativePersonalRuntimeGroup>,stores:@escaping Stores,
                         confirm:@escaping(NativePersonalRuntimeResumption.Prompt)async throws->NativePersonalRuntimeResumption.Choice)async throws->NativePersonalRuntimeResumption.Approval {
        try await joined {
            guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup) else{throw NativeDBError.conflict}
            let expected=try NativePersonalRuntimeResumption.resolve(startup:startup,personal:personal)
            try assertCurrent(service:service,startup:startup,personal:personal,expected:expected)
            let verifier=NativePersonalRuntimePrerequisites.verifier(startup:startup,personal:personal,stores:stores,clock:Date.init)
            let checked:NativePersonalRuntimeResumption.VerifyRequirement={requirement,prior,current in
                do {return try verifier(requirement,prior,current)}
                catch is CancellationError {throw CancellationError()}
                catch {
                    try assertCurrent(service:service,startup:startup,personal:personal,expected:expected)
                    throw DependencyFailure()
                }
            }
            return try await NativePersonalRuntimeResumption.review(service:service,startup:startup,settings:settings,workers:workers,requirements:checked,confirm:confirm)
        }
    }
    enum Isolation:String {case ready,missing,interrupted,newRestoration}
    private struct Marker:Decodable {
        let version:Int,phase:String,binding:NativePersonalRestoredJobQuarantine.Binding
        let receipt:NativePersonalRestoredJobQuarantine.Receipt?
    }
    private static func quarantine(service:CRMService,startup:NativeRestoreApplicationStartup)throws->NativePersonalRestoredJobQuarantine {
        guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup) else{throw NativeDBError.conflict}
        return try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:personal)
    }
    private static func isolationStatus(service:CRMService,startup:NativeRestoreApplicationStartup)throws->Isolation {
        let q=try quarantine(service:service,startup:startup)
        guard let raw=try service.db.restoredJobQuarantineMarker() else{return .missing}
        guard raw.utf8.count<=32768,let marker=try? JSONDecoder().decode(Marker.self,from:Data(raw.utf8)),marker.version==1,
              marker.binding.version==1,["pending","complete"].contains(marker.phase) else{throw NativeRestoreActivationFailure("personal.runtimeIsolationMalformed")}
        if marker.phase=="complete" {
            guard let receipt=marker.receipt,receipt.version==1,receipt.binding==marker.binding,receipt.jobCount>=0,
                  NativeMigrationCodec.validHash(receipt.indexSHA256) else{throw NativeRestoreActivationFailure("personal.runtimeIsolationMalformed")}
        } else {guard marker.receipt==nil else{throw NativeRestoreActivationFailure("personal.runtimeIsolationMalformed")}}
        if marker.binding==q.binding {
            if marker.phase=="pending"{return .interrupted}
            _ = try q.attach();_ = try q.requireReady();return .ready
        }
        // A second actual restore changes the root/generation. It may retain the
        // old DB's isolation record; that is different from corruption of the
        // current root's complete index, which attach above must reject.
        guard marker.binding.authority.selection != q.binding.authority.selection,
              marker.binding.owner.schemaSHA256==q.binding.owner.schemaSHA256,
              NativeMigrationCodec.validHash(marker.binding.catalogSHA256) else{throw NativeRestoreActivationFailure("personal.runtimeIsolationBinding")}
        return .newRestoration
    }
    static func isolation(service:CRMService,startup:NativeRestoreApplicationStartup)async throws->Isolation {
        try await joined {try isolationStatus(service:service,startup:startup)}
    }
    /// Called only after the explicit UI isolation choice. Re-evaluate before
    /// mutation; a corrupt current complete record is never repaired as success.
    static func installIsolation(service:CRMService,startup:NativeRestoreApplicationStartup,
                                 expected:Isolation)async throws {
        try await joined {
            guard expected != .ready,try isolationStatus(service:service,startup:startup)==expected else{throw NativeDBError.conflict}
            _ = try quarantine(service:service,startup:startup).install()
        }
    }
    static func inspect(_ requirement:NativePersonalRuntimeRequirement,service:CRMService,
                        startup:NativeRestoreApplicationStartup,stores:@escaping Stores)async throws->NativePersonalRuntimePrerequisites.Prompt {
        try await joined {try prerequisites(service:service,startup:startup,stores:stores).inspect(requirement)}
    }
    static func review(_ prompt:NativePersonalRuntimePrerequisites.Prompt,choice:NativePersonalRuntimePrerequisites.Choice,
                       service:CRMService,startup:NativeRestoreApplicationStartup,stores:@escaping Stores)async throws {
        try await joined {_ = try prerequisites(service:service,startup:startup,stores:stores).review(prompt,choice:choice,confirmedSubject:prompt.subjectSHA256)}
    }
    private static func prerequisites(service:CRMService,startup:NativeRestoreApplicationStartup,stores:Stores)throws->NativePersonalRuntimePrerequisites {
        guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup) else{throw NativeDBError.conflict}
        return try NativePersonalRuntimePrerequisites(service:service,startup:startup,personal:personal,stores:stores(service),clock:Date.init)
    }
}
