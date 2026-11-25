import Foundation
import CryptoKit
import Darwin

struct NativeRestoreHostStartupRequest: Codable, Equatable {
    let version:Int
    let startupID:String, nonce:String
    let helper:NativeRestoreHostProcessIdentity, application:NativeRestoreHostProcessIdentity
    let lease:NativeRestoreHostLeaseIdentity
    let activationID:String
    let selection:NativeRestoreActivationSelection
    let journalSHA256:String
    let approval:NativeRestoreHostApprovalEnvelope
    let permitted:[String], held:[String]

    func validateBounds()throws {var budget=NativeRestoreHostWireBudget();try validateBounds(budget:&budget)}
    func validateBounds(budget:inout NativeRestoreHostWireBudget)throws {
        try budget.uuid(startupID);try budget.hash(nonce)
        try budget.uuid(activationID);try budget.selection(selection);try budget.hash(journalSHA256)
        try budget.approval(approval);try budget.identifiers(permitted,maximum:128);try budget.identifiers(held,maximum:128)
        guard version==1,helper.pid>1,application.pid>1,helper != application,
              helper.uid==application.uid,helper.uid==lease.uid,helper.startSeconds>0,application.startSeconds>0,
              helper.startMicroseconds<1_000_000,application.startMicroseconds<1_000_000,
              lease==approval.binding.session.lease,selection==approval.binding.session.candidate,
              permitted==["workspace.local"],held==NativeRestoreRuntimeCatalog.heldAutomatic.sorted() else {
            throw NativeRestoreHostHandoffFailure.invalidBinding
        }
    }
    func subjectSHA256()throws->String {
        try validateBounds();return try NativeRestoreHostStartupCodec.hash(self,domain:"NextCRM.restore.startup-request.v1")
    }
    func validateLifetime(now:Date)throws {
        let time=now.timeIntervalSince1970
        guard time.isFinite,approval.authorization.authenticatedAt<=time,approval.decision.approvedAt<=time,
              time<min(approval.authorization.validUntil,approval.decision.validUntil) else {
            throw NativeRestoreHostHandoffFailure.expired
        }
    }
    func validateJournal(_ journal:NativeRestoreActivationJournal)throws {
        try validateBounds()
        guard journal.phase == .starting,journal.activationID==activationID,journal.candidate==selection,
              journal.previous==approval.binding.session.previous,
              journal.permittedRuntimes==permitted,journal.heldRuntimes==held,
              let seal=journal.seal,
              try NativeRestoreHostStartupCodec.journalHash(journal)==journalSHA256 else {
            throw NativeRestoreHostHandoffFailure.invalidBinding
        }
        let context=NativeRestoreHostConversationContext(coordinator:.init(activationID:journal.activationID,previous:journal.previous,candidate:journal.candidate,
            seal:seal,inheritedPending:journal.inheritedPending,previousRunning:journal.previousRunning,runtimeCatalog:journal.runtimeCatalog),
            writerParticipants:NativeRestoreRuntimeCatalog.writerParticipants)
        try NativeRestoreReviewBridge.validate(context)
        guard try context.subjectSHA256()==approval.binding.subjectSHA256 else {throw NativeRestoreHostHandoffFailure.invalidBinding}
    }
    static func make(control:NativeRestoreActivationControl,lease:NativeRestoreHostInstanceLease,
                     application:NativeRestoreHostOwnedChild,approval:NativeRestoreHostApprovalEnvelope)throws->Self {
        try control.validate();try lease.validate()
        guard let journal=try control.read("activation.json",as:NativeRestoreActivationJournal.self),
              let selection=try control.read("active-root.json",as:NativeRestoreActivationSelection.self) else {throw NativeRestoreHostHandoffFailure.invalidBinding}
        var rng=SystemRandomNumberGenerator()
        let value=Self(version:1,startupID:UUID().uuidString.lowercased(),nonce:(0..<32).map{_ in String(format:"%02x",UInt8.random(in:0...255,using:&rng))}.joined(),
            helper:try .current(getpid()),application:try application.processIdentity(),lease:lease.identity,activationID:journal.activationID,
            selection:selection,journalSHA256:try NativeRestoreHostStartupCodec.journalHash(journal),approval:approval,
            permitted:journal.permittedRuntimes,held:journal.heldRuntimes)
        try value.validateJournal(journal);return value
    }
}

struct NativeRestoreHostWorkspaceReadiness:Codable,Equatable {
    let selection:NativeRestoreActivationSelection
    let workspacePrepared:Bool, presentationPrepared:Bool, writeAdmissionClosed:Bool
    let started:[String],held:[String]
    let evidenceSHA256:String
    func validate(_ request:NativeRestoreHostStartupRequest)throws {var budget=NativeRestoreHostWireBudget();try validate(request,budget:&budget)}
    func validate(_ request:NativeRestoreHostStartupRequest,budget:inout NativeRestoreHostWireBudget)throws {
        try budget.selection(selection);try budget.hash(evidenceSHA256)
        try budget.identifiers(started,maximum:128);try budget.identifiers(held,maximum:128)
        guard selection==request.selection,workspacePrepared,presentationPrepared,writeAdmissionClosed,
              started==request.permitted,held==request.held else {throw NativeRestoreHostHandoffFailure.invalidReadiness}
    }
}
struct NativeRestoreHostStartupACK:Codable {
    let request:NativeRestoreHostStartupRequest
    let authorization:NativeRestoreHostFreshAuthorization
    let readiness:NativeRestoreHostWorkspaceReadiness
    func validate(now:Date)throws {
        var budget=NativeRestoreHostWireBudget();try request.validateBounds(budget:&budget)
        try request.validateLifetime(now:now);try readiness.validate(request,budget:&budget);try budget.authorization(authorization)
        let time=now.timeIntervalSince1970
        guard authorization.principalID==request.approval.authorization.principalID,
              authorization.subjectSHA256==(try request.subjectSHA256()),
              authorization.authenticatedAt<=time,time-authorization.authenticatedAt<=60,
              authorization.validUntil>time,authorization.validUntil-authorization.authenticatedAt<=300 else {
            throw NativeRestoreHostHandoffFailure.expired
        }
    }
}

enum NativeRestoreHostStartupCodec {
    static func hash<T:Encodable>(_ value:T,domain:String)throws->String {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var data=Data(domain.utf8);data.append(0);data.append(try encoder.encode(value))
        return SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
    }
    static func journalHash(_ journal:NativeRestoreActivationJournal)throws->String {
        // Control.read already bounds the private journal to 262144 bytes. This
        // is a metadata snapshot hash, not an authority or a second journal.
        try hash(journal,domain:"NextCRM.restore.starting-journal.v1")
    }
    static func current(_ request:NativeRestoreHostStartupRequest,control:NativeRestoreActivationControl,
                        lease:NativeRestoreHostInstanceLease)throws {
        try control.validate();try lease.validate()
        guard lease.identity==request.lease,
              try control.read("active-root.json",as:NativeRestoreActivationSelection.self)==request.selection,
              try NativeRestoreActivationControl.root(request.selection.root.url)==request.selection.root,
              let journal=try control.read("activation.json",as:NativeRestoreActivationJournal.self) else {
            throw NativeRestoreHostHandoffFailure.invalidBinding
        }
        try request.validateJournal(journal)
    }

}
