import Foundation

/// A small, OS-control-owned policy record for an already bound personal root.
/// It records an explicit choice, not evidence that any worker has started.
/// Old jobs stay quarantined; legacy cron/cursor/provider state needs separate
/// required verification before this class can issue an Active value.
enum NativePersonalRuntimeResumption {
    static let domain="personal-runtime-resumption-v1"
    struct RequirementEvidence:Codable,Equatable {
        let requirement:NativePersonalRuntimeRequirement
        /// Hash of a non-secret, separately verified configuration/state review.
        /// The reference is never a credential, URL or arbitrary runtime ID.
        let referenceSHA256:String
    }
    typealias VerifyRequirement=(NativePersonalRuntimeRequirement,RequirementEvidence?,CRMService)throws->RequirementEvidence
    struct Record:Codable,Equatable {
        let version:Int,domain:String,id:String,revision:Int64
        let authority:NativePersonalRestoreAuthority.Evidence
        let personalTransitionID:String,approvalActivationID:String,ownerID:String,ownerRevision:Int64,catalogSHA256:String
        let settings:[NativePersonalRuntimeGroup],workers:[NativePersonalRuntimeGroup]
        let isolationSHA256:String?,requirements:[RequirementEvidence]
        let previousSHA256:String?,approvedAt:Date,subjectSHA256:String
        var filename:String{"personal-runtimes-"+authority.selection.generation+".json"}
    }
    struct Prompt:Codable,Equatable {
        let subjectSHA256:String,rootPath:String,ownerID:String
        let settings:[NativePersonalRuntimeGroup],workers:[NativePersonalRuntimeGroup]
        let heldRuntimeIDs:[String],validUntil:Date
    }
    enum Choice {case approve(subjectSHA256:String)}
    struct Approval {
        fileprivate let record:Record,expires:Date
    }
    final class DrainPermit {
        fileprivate let startup:NativeRestoreApplicationStartup,approval:Record
        private var used=false
        private let lock=NSLock()
        fileprivate init(startup:NativeRestoreApplicationStartup,approval:Record){self.startup=startup;self.approval=approval}
        fileprivate func consume(startup:NativeRestoreApplicationStartup,approval:Record)throws {
            lock.lock();defer{lock.unlock()}
            guard !used,self.startup === startup,self.approval==approval else{throw NativeRestoreActivationFailure("personal.runtimeDrainPermit")};used=true
        }
    }
    /// Only after actual App ownership/worker cleanup has joined. The process
    /// connection registry prevents a closure retaining the old DB across this
    /// boundary; this returns no success token for a merely requested stop.
    static func afterDrain(_ approval:Approval,startup:NativeRestoreApplicationStartup)throws->DrainPermit {
        try validateApproval(approval,startup:startup)
        guard NativeDatabase.liveConnections().isEmpty else{throw NativeRestoreActivationFailure("personal.runtimeOldDatabaseLive")}
        return DrainPermit(startup:startup,approval:approval.record)
    }
    /// Cannot be decoded or initialized by an App caller. It binds the actual
    /// open DB/service and required verifier to this startup/record. The Host
    /// retains it until all registered App work has joined.
    final class Active {
        let record:Record
        fileprivate let service:CRMService,startup:NativeRestoreApplicationStartup,personal:NativePersonalRestoreAdmission.Record
        fileprivate let requirements:VerifyRequirement
        fileprivate init(record:Record,service:CRMService,startup:NativeRestoreApplicationStartup,
                         personal:NativePersonalRestoreAdmission.Record,requirements:@escaping VerifyRequirement) {
            self.record=record;self.service=service;self.startup=startup;self.personal=personal;self.requirements=requirements
        }
        func validate()throws {
            _ = try authority(service,startup:startup,personal:personal)
            guard try resolve(startup:startup,personal:personal)==record else{throw NativeRestoreActivationFailure("personal.runtimePolicyChanged")}
            try verifyDependencies(record,service:service,startup:startup,personal:personal,requirements:requirements)
        }
    }
    enum ReviewReason:String,Codable {
        case dependenciesChanged,previouslyHeld
        var message:String {
            switch self {
            case .dependenciesChanged:return "連携設定または復元前の処理を再確認してください。自動処理は停止したまま、CRMの編集と設定の確認を続けられます。"
            case .previouslyHeld:return "前回の起動で停止していた機能があります。再確認するまで自動処理は再開しません。"
            }
        }
    }
    struct ReviewSummary:Codable,Equatable {
        let recordID:String,revision:Int64,settings:[NativePersonalRuntimeGroup],reason:ReviewReason
    }
    final class ReviewHold {
        let summary:ReviewSummary
        fileprivate let record:Record,service:CRMService,startup:NativeRestoreApplicationStartup,personal:NativePersonalRestoreAdmission.Record
        fileprivate init(record:Record,service:CRMService,startup:NativeRestoreApplicationStartup,
                         personal:NativePersonalRestoreAdmission.Record,reason:ReviewReason) {
            self.record=record;self.service=service;self.startup=startup;self.personal=personal
            summary=ReviewSummary(recordID:record.id,revision:record.revision,settings:record.settings,reason:reason)
        }
        func validate()throws {
            _ = try authority(service,startup:startup,personal:personal)
            guard try resolve(startup:startup,personal:personal)==record else{throw NativeRestoreActivationFailure("personal.runtimePolicyChanged")}
        }
    }
    enum Opened {case localOnly,active(Active),reviewRequired(ReviewHold)}
    private struct Subject:Encodable {
        let domain:String,id:String,revision:Int64,authority:NativePersonalRestoreAuthority.Evidence
        let personalTransitionID:String,approvalActivationID:String,ownerID:String,ownerRevision:Int64,catalogSHA256:String
        let settings:[NativePersonalRuntimeGroup],workers:[NativePersonalRuntimeGroup],isolationSHA256:String?
        let requirements:[RequirementEvidence],previousSHA256:String?,approvedAt:Date,validUntil:Date
    }
    private static func required(_ groups:[NativePersonalRuntimeGroup])->[NativePersonalRuntimeRequirement] {
        Set(groups.flatMap(\.requirements)).sorted()
    }
    private static func validateShape(_ record:Record)throws {
        try NativePersonalRuntimeGroup.validateCatalog()
        guard record.version==1,record.domain==domain,UUID(uuidString:record.id)?.uuidString.lowercased()==record.id,
              record.revision>0,record.revision<=1_000_000,
              record.settings==Array(Set(record.settings)).sorted(),record.workers==Array(Set(record.workers)).sorted(),
              Set(record.workers).isSubset(of:Set(record.settings)),
              record.requirements.map(\.requirement)==required(record.workers),
              record.requirements.allSatisfy({NativeMigrationCodec.validHash($0.referenceSHA256)}),
              record.workers.isEmpty ? record.isolationSHA256==nil:NativeMigrationCodec.validHash(record.isolationSHA256 ?? ""),
              NativeMigrationCodec.validHash(record.catalogSHA256),NativeMigrationCodec.validHash(record.subjectSHA256),
              record.previousSHA256==nil || NativeMigrationCodec.validHash(record.previousSHA256!),
              UUID(uuidString:record.approvalActivationID) != nil,record.ownerRevision>=0,record.approvedAt.timeIntervalSince1970.isFinite else{
            throw NativeRestoreActivationFailure("personal.runtimeRecord")
        }
        let subject=Subject(domain:record.domain,id:record.id,revision:record.revision,authority:record.authority,
            personalTransitionID:record.personalTransitionID,approvalActivationID:record.approvalActivationID,ownerID:record.ownerID,ownerRevision:record.ownerRevision,catalogSHA256:record.catalogSHA256,
            settings:record.settings,workers:record.workers,isolationSHA256:record.isolationSHA256,requirements:record.requirements,
            previousSHA256:record.previousSHA256,approvedAt:record.approvedAt,validUntil:record.approvedAt.addingTimeInterval(300))
        guard try NativePersonalRestoreAdmission.hash(subject)==record.subjectSHA256 else{throw NativeRestoreActivationFailure("personal.runtimeSubjectChanged")}
    }
    /// Structural/current OS-root binding only. DB/credential/legacy-state
    /// admission is deliberately deferred to attach(), before any App factory.
    static func resolve(startup:NativeRestoreApplicationStartup,personal:NativePersonalRestoreAdmission.Record)throws->Record? {
        guard personal.phase == .bound else{return nil}
        let name="personal-runtimes-"+personal.authority.selection.generation+".json"
        guard let record=try startup.control.read(name,as:Record.self) else{return nil}
        try validateShape(record)
        guard record.filename==name,record.authority==personal.authority,
              record.personalTransitionID==personal.transitionID,record.ownerID==personal.owner.ownerID,
              record.catalogSHA256==(try NativePersonalRestoreAdmission.catalog()) else{
            throw NativeRestoreActivationFailure("personal.runtimeBinding")
        }
        _ = try NativePersonalRestoreAuthority.check(startup,expected:record.authority)
        return record
    }
    static func permitted(_ record:Record?)->[String]{NativePersonalRuntimeGroup.permitted(record?.workers ?? [])}
    private static func authority(_ service:CRMService,startup:NativeRestoreApplicationStartup,
                                  personal:NativePersonalRestoreAdmission.Record)throws->NativeRecord {
        try Task.checkCancellation();try NativePersonalRestoreAdmission.validate(personal,startup:startup)
        guard personal.phase == .bound,!service.db.isReadOnly,service.identity.id==personal.owner.ownerID,
              service.db.schema.schemaSHA256==personal.owner.schemaSHA256,
              service.db.url.resolvingSymlinksInPath().standardizedFileURL==personal.authority.selection.root.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL,
              try service.db.metadata("localActor")==service.identity.id else{throw NativeRestoreActivationFailure("personal.runtimeOwner")}
        try service.authenticated()
        guard let owner=try service.db.get("Users",key:["id":.text(service.identity.id)]) else{throw NativeDBError.conflict};return owner
    }
    private static func isolation(service:CRMService,startup:NativeRestoreApplicationStartup,
                                  personal:NativePersonalRestoreAdmission.Record,attach:Bool=true)throws->String {
        let quarantine=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:personal)
        if attach { _ = try quarantine.attach() } // Once per open/admission, never install.
        return try NativePersonalRestoreAdmission.hash(quarantine.requireReady())
    }
    private static func evidence(_ groups:[NativePersonalRuntimeGroup],prior:[RequirementEvidence]?,
                                 service:CRMService,verify:VerifyRequirement)throws->[RequirementEvidence] {
        try required(groups).map { requirement in
            let old=prior?.first{$0.requirement==requirement}
            let result=try verify(requirement,old,service)
            guard result.requirement==requirement,NativeMigrationCodec.validHash(result.referenceSHA256),old==nil || old==result else{
                throw NativeRestoreActivationFailure("personal.runtimePrerequisiteChanged")
            };return result
        }
    }
    private static func verifyDependencies(_ record:Record,service:CRMService,startup:NativeRestoreApplicationStartup,
                                           personal:NativePersonalRestoreAdmission.Record,requirements:VerifyRequirement)throws {
        if !record.workers.isEmpty {
            guard try isolation(service:service,startup:startup,personal:personal,attach:false)==record.isolationSHA256 else{
                throw NativeRestoreActivationFailure("personal.runtimeIsolationChanged")
            }
        }
        guard try evidence(record.workers,prior:record.requirements,service:service,verify:requirements)==record.requirements else{
            throw NativeRestoreActivationFailure("personal.runtimePrerequisiteChanged")
        }
        _ = try authority(service,startup:startup,personal:personal)
    }
    static func review(service:CRMService,startup:NativeRestoreApplicationStartup,
                       settings:Set<NativePersonalRuntimeGroup>,workers:Set<NativePersonalRuntimeGroup>,
                       requirements:VerifyRequirement,clock:()->Date=Date.init,
                       confirm:(Prompt)async throws->Choice)async throws->Approval {
        guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup),personal.phase == .bound,
              workers.isSubset(of:settings) else{throw NativeRestoreActivationFailure("personal.runtimeReview")}
        try NativePersonalRuntimeGroup.validateCatalog()
        let owner=try authority(service,startup:startup,personal:personal),previous=try resolve(startup:startup,personal:personal)
        let sortedSettings=settings.sorted(),sortedWorkers=workers.sorted(),now=clock(),expiry=now.addingTimeInterval(300)
        guard now.timeIntervalSince1970.isFinite,expiry.timeIntervalSince1970.isFinite,(previous?.revision ?? 0)<1_000_000 else{throw NativeDBError.conflict}
        let isolationSHA=workers.isEmpty ? nil:try isolation(service:service,startup:startup,personal:personal)
        let proofs=try evidence(sortedWorkers,prior:nil,service:service,verify:requirements)
        let id=UUID().uuidString.lowercased(),revision=(previous?.revision ?? 0)+1,priorSHA=try previous.map(NativePersonalRestoreAdmission.hash)
        let subject=try NativePersonalRestoreAdmission.hash(Subject(domain:domain,id:id,revision:revision,authority:personal.authority,
            personalTransitionID:personal.transitionID,approvalActivationID:startup.plan.activationID ?? "",ownerID:service.identity.id,ownerRevision:owner.revision,catalogSHA256:NativePersonalRestoreAdmission.catalog(),
            settings:sortedSettings,workers:sortedWorkers,isolationSHA256:isolationSHA,requirements:proofs,previousSHA256:priorSHA,approvedAt:now,validUntil:expiry))
        let record=Record(version:1,domain:domain,id:id,revision:revision,authority:personal.authority,
            personalTransitionID:personal.transitionID,approvalActivationID:startup.plan.activationID ?? "",ownerID:service.identity.id,ownerRevision:owner.revision,catalogSHA256:try NativePersonalRestoreAdmission.catalog(),
            settings:sortedSettings,workers:sortedWorkers,isolationSHA256:isolationSHA,requirements:proofs,previousSHA256:priorSHA,approvedAt:now,subjectSHA256:subject)
        try validateShape(record)
        let choice=try await confirm(.init(subjectSHA256:subject,rootPath:personal.authority.selection.root.path,ownerID:service.identity.id,
            settings:sortedSettings,workers:sortedWorkers,heldRuntimeIDs:NativeRestoreRuntimeCatalog.ids.filter{!permitted(record).contains($0)}.sorted(),validUntil:expiry))
        guard case let .approve(confirmed)=choice,confirmed==subject else{throw NativeRestoreActivationFailure("personal.runtimeApproval")}
        let approval=Approval(record:record,expires:expiry)
        try validateApproval(approval,startup:startup,clock:clock)
        guard try authority(service,startup:startup,personal:personal).revision==owner.revision else{throw NativeDBError.conflict}
        try verifyDependencies(record,service:service,startup:startup,personal:personal,requirements:requirements)
        return approval
    }
    /// Safe before draining: no DB is captured by the opaque approval. Exact
    /// owner revision and prerequisite checks repeat with the new open service.
    static func validateApproval(_ approval:Approval,startup:NativeRestoreApplicationStartup,clock:()->Date=Date.init)throws {
        let record=approval.record,now=clock();try validateShape(record)
        guard now>=record.approvedAt,now<approval.expires,
              let personal=try NativePersonalRestoreAdmission.resolve(startup:startup),personal.phase == .bound,
              personal.transitionID==record.personalTransitionID,personal.authority==record.authority else{
            throw NativeRestoreActivationFailure("personal.runtimeApprovalExpired")
        }
        let current=try resolve(startup:startup,personal:personal)
        guard try current.map(NativePersonalRestoreAdmission.hash)==record.previousSHA256 else{
            throw NativeRestoreActivationFailure("personal.runtimeApprovalStale")
        }
    }
    /// Call only after Host has joined/released the previous App. The existing
    /// personal grant already admits this writable DB; this CAS record adds only
    /// the reviewed feature groups. A committed record is not a startup ACK.
    static func commit(_ approval:Approval,permit:DrainPermit,service:CRMService,startup:NativeRestoreApplicationStartup,
                       requirements:@escaping VerifyRequirement,clock:()->Date=Date.init,
                       checkpoint:(String)throws->Void={_ in})throws->Active {
        try permit.consume(startup:startup,approval:approval.record)
        try service.db.requireRestoredJobQuarantineBoundary()
        try startup.control.acquire();defer{startup.control.release()}
        try validateApproval(approval,startup:startup,clock:clock)
        guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup) else{throw NativeDBError.conflict}
        let record=approval.record,owner=try authority(service,startup:startup,personal:personal)
        guard owner.revision==record.ownerRevision else{throw NativeDBError.conflict}
        if !record.workers.isEmpty {_ = try isolation(service:service,startup:startup,personal:personal)}
        try verifyDependencies(record,service:service,startup:startup,personal:personal,requirements:requirements)
        try checkpoint("beforePublish");try validateApproval(approval,startup:startup,clock:clock)
        guard try authority(service,startup:startup,personal:personal).revision==record.ownerRevision else{throw NativeDBError.conflict}
        try Task.checkCancellation();try startup.control.write(record,name:record.filename);try checkpoint("published")
        let active=Active(record:record,service:service,startup:startup,personal:personal,requirements:requirements)
        try active.validate();try startup.adoptPersonalRuntimeResumption(active);return active
    }
    /// Required on each reopened personal workspace before any worker factory.
    /// Missing/changed review state fails closed. There is no successful default.
    static func attach(service:CRMService,startup:NativeRestoreApplicationStartup,
                       requirements:@escaping VerifyRequirement)throws->Active? {
        guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup),
              let record=try resolve(startup:startup,personal:personal) else{return nil}
        guard try priorHold(record:record,startup:startup)==nil else{throw NativeRestoreActivationFailure("personal.runtimePreviousHeld")}
        if !record.workers.isEmpty {_ = try isolation(service:service,startup:startup,personal:personal)}
        let active=Active(record:record,service:service,startup:startup,personal:personal,requirements:requirements)
        try active.validate();try startup.adoptPersonalRuntimeResumption(active);return active
    }
    static func priorHold(record:Record,startup:NativeRestoreApplicationStartup)throws->ReviewSummary? {
        guard !record.workers.isEmpty,let journal=try startup.control.read("activation.json",as:NativeRestoreActivationJournal.self),
              journal.previous==record.authority.selection,
              [.restoringPrevious,.previousRestored].contains(journal.phase) else{return nil}
        if let receipt=journal.recoveryStartup {
            guard let seal=journal.seal else{throw NativeRestoreActivationFailure("personal.runtimeRecoveryReceipt")}
            let context=NativeRestoreActivationContext(activationID:journal.activationID,previous:journal.previous,candidate:journal.candidate,
                seal:seal,inheritedPending:journal.inheritedPending,previousRunning:journal.previousRunning,runtimeCatalog:journal.runtimeCatalog)
            try NativeRestoreActivation.validatePersonalLocalRecovery(receipt,context:context)
            // Read the already validated generation-bound record, avoiding a
            // recursive Admission.resolve -> plan -> priorHold call.
            let name="personal-workspace-"+record.authority.selection.generation+".json"
            guard let personal=try startup.control.read(name,as:NativePersonalRestoreAdmission.Record.self),
                  try NativePersonalRestoreAdmission.hash(personal)==receipt.personalGrantSHA256 else{throw NativeRestoreActivationFailure("personal.runtimeRecoveryGrant")}
            if try NativePersonalRestoreAdmission.hash(record)==receipt.runtimeRecordSHA256 {
                return ReviewSummary(recordID:record.id,revision:record.revision,settings:record.settings,reason:.previouslyHeld)
            }
            // Only a later explicit policy review under this same activation
            // supersedes the saved hold; transient credential repair cannot.
            guard record.approvalActivationID==journal.activationID else{throw NativeRestoreActivationFailure("personal.runtimeRecoveryPolicy")}
            return nil
        }
        guard journal.previousRunning==["workspace.local"],record.approvalActivationID != journal.activationID else{return nil}
        return ReviewSummary(recordID:record.id,revision:record.revision,settings:record.settings,reason:.previouslyHeld)
    }
    /// Missing/expired configuration must not lock the user out of local CRM.
    /// Only dependent checks can downscope; root/DB/owner/catalog/record changes
    /// are rechecked and throw, never converted into a local success fallback.
    static func resolveOpened(service:CRMService,startup:NativeRestoreApplicationStartup,
                              requirements:@escaping VerifyRequirement)throws->Opened {
        guard let personal=try NativePersonalRestoreAdmission.resolve(startup:startup),personal.phase == .bound else{throw NativeDBError.conflict}
        _ = try authority(service,startup:startup,personal:personal)
        guard let record=try resolve(startup:startup,personal:personal) else{return .localOnly}
        if try priorHold(record:record,startup:startup) != nil {
            let hold=ReviewHold(record:record,service:service,startup:startup,personal:personal,reason:.previouslyHeld)
            try hold.validate();try startup.adoptPersonalRuntimeReview(hold);return .reviewRequired(hold)
        }
        do {
            guard let active=try attach(service:service,startup:startup,requirements:requirements) else{throw NativeDBError.conflict}
            return .active(active)
        } catch {
            _ = try authority(service,startup:startup,personal:personal)
            guard try resolve(startup:startup,personal:personal)==record else{throw NativeRestoreActivationFailure("personal.runtimePolicyChanged")}
            let hold=ReviewHold(record:record,service:service,startup:startup,personal:personal,reason:.dependenciesChanged)
            try hold.validate();try startup.adoptPersonalRuntimeReview(hold);return .reviewRequired(hold)
        }
    }
    static func plan(for hold:ReviewHold,startup:NativeRestoreApplicationStartup)throws->NativeRestoreApplicationStartupPlan {
        guard hold.startup === startup else{throw NativeDBError.conflict};try hold.validate()
        var result=NativeRestoreApplicationStartupPlan(root:hold.record.authority.selection.root,selection:hold.record.authority.selection,
            mode:.personalActiveLocal,permitted:["workspace.local"],held:NativeRestoreRuntimeCatalog.heldAutomatic.sorted(),activationID:startup.plan.activationID,requiresReview:true)
        result.personal=hold.personal;result.resumption=hold.record;result.runtimeReview=hold.summary;return result
    }
    static func plan(for active:Active,startup:NativeRestoreApplicationStartup)throws->NativeRestoreApplicationStartupPlan {
        guard active.startup === startup else{throw NativeDBError.conflict};try active.validate()
        return try NativePersonalRestoreAdmission.plan(for:active.personal,startup:startup)
    }
    static func validatePlan(_ plan:NativeRestoreApplicationStartupPlan)throws {
        guard let record=plan.resumption else{guard plan.runtimeReview==nil else{throw NativeDBError.conflict};return};try validateShape(record)
        if let review=plan.runtimeReview {
            guard review.recordID==record.id,review.revision==record.revision,review.settings==record.settings else{throw NativeDBError.conflict}
        }
        guard plan.mode == .personalActiveLocal,plan.personal?.phase == .bound,
              record.authority.selection==plan.selection,record.personalTransitionID==plan.personal?.transitionID,
              record.ownerID==plan.personal?.owner.ownerID,record.catalogSHA256==(try NativePersonalRestoreAdmission.catalog()),
              plan.permitted==(plan.runtimeReview == nil ? permitted(record):["workspace.local"]) else{throw NativeRestoreActivationFailure("personal.runtimePlan")}
    }
    static func validateWorkspace(_ active:Active?,review:ReviewHold?,service:CRMService,plan:NativeRestoreApplicationStartupPlan,
                                  startup:NativeRestoreApplicationStartup)throws {
        if let summary=plan.runtimeReview {
            guard active==nil,let review,review.summary==summary,review.record==plan.resumption,
                  review.service.db === service.db,review.service.identity.id==service.identity.id,review.startup === startup,
                  plan.permitted==["workspace.local"] else{throw NativeRestoreActivationFailure("personal.runtimeReviewNotAdmitted")}
            try review.validate();return
        }
        guard review==nil else{throw NativeDBError.conflict}
        guard let record=plan.resumption else {guard active==nil else{throw NativeDBError.conflict};return}
        guard let active,active.record==record,active.service.db === service.db,active.service.identity.id==service.identity.id,active.service.identity.role==service.identity.role,active.service.identity.partnerAccountID==service.identity.partnerAccountID,
              active.startup === startup,plan.permitted==permitted(record),plan.personal?.transitionID==record.personalTransitionID else{
            throw NativeRestoreActivationFailure("personal.runtimeWorkspaceNotAdmitted")
        }
        try active.validate()
    }
    static func validateApplied(_ approval:Approval,active:Active?,startup:NativeRestoreApplicationStartup)throws {
        guard let active,active.record==approval.record,active.startup === startup else{throw NativeRestoreActivationFailure("personal.runtimeTransitionIncomplete")}
        try active.validate()
    }
}
