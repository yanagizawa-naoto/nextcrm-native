import Foundation
import CryptoKit
import Darwin

/// Only isolates historical IDs. It grants neither worker admission nor provider
/// permission; the host must separately approve its existing fixed runtime groups.
final class NativePersonalRestoredJobQuarantine {
    struct Binding:Codable,Equatable {
        let version:Int
        let authority:NativePersonalRestoreAuthority.Evidence
        let transitionID:String,activationID:String,catalogSHA256:String
        let owner:NativePersonalWorkspace.BindingDescriptor
        let seal:NativeRestoreActivationSeal
    }
    struct Receipt:Codable,Equatable {
        let version:Int,binding:Binding
        let jobCount:Int64,indexSHA256:String
    }
    private struct Marker:Codable {
        let version:Int,phase:String,binding:Binding
        let receipt:Receipt?
    }
    let service:CRMService
    private let startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record
    let binding:Binding
    init(service:CRMService,startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record)throws {
        self.service=service;self.startup=startup;self.record=record
        binding=Binding(version:1,authority:record.authority,transitionID:record.transitionID,activationID:record.activationID,
            catalogSHA256:record.catalogSHA256,owner:record.owner,seal:record.seal)
        try Self.authority(service,startup,record)
    }
    private static func authority(_ service:CRMService,_ startup:NativeRestoreApplicationStartup,_ record:NativePersonalRestoreAdmission.Record)throws {
        try Task.checkCancellation();try NativePersonalRestoreAdmission.validate(record,startup:startup)
        guard record.phase == .bound,!service.db.isReadOnly,service.identity.id==record.owner.ownerID,
              service.db.schema.schemaSHA256==record.owner.schemaSHA256,
              service.db.url.resolvingSymlinksInPath().standardizedFileURL==record.authority.selection.root.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL,
              try service.db.metadata("localActor")==service.identity.id else{throw NativeRestoreActivationFailure("quarantine.authority")}
        try service.authenticated()
    }
    private func authority()throws{try Self.authority(service,startup,record)}
    private static func encode<T:Encodable>(_ value:T)throws->String {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return String(decoding:try e.encode(value),as:UTF8.self)
    }
    private func readComplete()throws->(String,Receipt) {
        try authority()
        guard let raw=try service.db.restoredJobQuarantineMarker(),raw.utf8.count<=32768,
              let marker=try? JSONDecoder().decode(Marker.self,from:Data(raw.utf8)),marker.version==1,marker.phase=="complete",marker.binding==binding,
              let receipt=marker.receipt,receipt.version==1,receipt.binding==binding,receipt.jobCount>=0,
              NativeMigrationCodec.validHash(receipt.indexSHA256) else{throw NativeRestoreActivationFailure("quarantine.notReady")}
        return(raw,receipt)
    }
    private func inventory()throws->(Int64,String) {
        let subject=NativeMigrationCodec.hash(Data(try Self.encode(binding).utf8))
        var digest=SHA256(),after="",count:Int64=0
        while true {
            try Task.checkCancellation()
            let page=try service.db.restoredJobQuarantinePage(bindingSHA256:subject,after:after)
            for row in page {
                guard NativeMigrationCodec.validHash(row.hash),!row.id.isEmpty else{throw NativeRestoreActivationFailure("quarantine.entry")}
                digest.update(data:Data((try Self.encode([row.id,row.hash])+"\n").utf8));count+=1;after=row.id
            }
            if page.count<100{break}
        }
        return(count,digest.finalize().map{String(format:"%02x",$0)}.joined())
    }
    /// Must be invoked outside an outer DB transaction and before worker startup.
    /// Pending is durable first. Failure rolls back every entry, leaving pending
    /// visible so reopen/claim cannot mistake a partial installation for ordinary.
    @discardableResult func install(checkpoint:(String,Int64)throws->Void={_,_ in})throws->Receipt {
        let db=service.db;try db.requireRestoredJobQuarantineBoundary();try authority()
        if let raw=try db.restoredJobQuarantineMarker(),
           let marker=try? JSONDecoder().decode(Marker.self,from:Data(raw.utf8)),marker.phase=="complete",marker.binding==binding {
            return try attach()
        }
        let pending=try Self.encode(Marker(version:1,phase:"pending",binding:binding,receipt:nil))
        try db.transaction {try authority();try db.setMetadata(NativeDatabase.restoredJobQuarantineMarkerKey,value:pending)}
        try checkpoint("pending",0)
        let subject=NativeMigrationCodec.hash(Data(try Self.encode(binding).utf8))
        try db.transaction {
            try authority();guard try db.restoredJobQuarantineMarker()==pending else{throw NativeDBError.conflict}
            let root=binding.authority.selection.root.url,dir=try NativeBackupWorkspace.openDirectory(root);defer{close(dir)}
            func named()throws->NativeMigrationFiles.Fingerprint {
                var st=stat();guard fstatat(dir,"resume-plan.ndjson",&st,AT_SYMLINK_NOFOLLOW)==0,st.st_mode&S_IFMT==S_IFREG else{throw NativeRestoreActivationFailure("quarantine.planIdentity")}
                return .init(st)
            }
            let identity=try named(),cursor=try NativeRestoreActivationPlanCursor(root:root,seal:binding.seal)
            var count:Int64=0
            while let(entry,hash)=try cursor.next() {
                try Task.checkCancellation()
                if entry.model=="native_outbox" {
                    guard ["job","terminalReceipt"].contains(entry.kind),entry.count==1,let id=entry.key,entry.event != nil,
                          (entry.kind=="terminalReceipt")==["done","cancelled"].contains(entry.state ?? "unknown") else{throw NativeRestoreActivationFailure("quarantine.planJob")}
                    try db.putRestoredJobQuarantine(id:id,bindingSHA256:subject,rowSHA256:hash);count+=1
                }
                try checkpoint("row",count)
            }
            // next()==nil certifies the exact EOF hash, row count and open inode.
            try checkpoint("eof",count);try authority();guard try named()==identity else{throw NativeRestoreActivationFailure("quarantine.planChanged")}
            let (actual,digest)=try inventory();guard count==actual else{throw NativeRestoreActivationFailure("quarantine.count")}
            let receipt=Receipt(version:1,binding:binding,jobCount:count,indexSHA256:digest)
            try checkpoint("complete",count);try Task.checkCancellation()
            guard try named()==identity else{throw NativeRestoreActivationFailure("quarantine.planChanged")}
            try authority();try db.setMetadata(NativeDatabase.restoredJobQuarantineMarkerKey,value:try Self.encode(Marker(version:1,phase:"complete",binding:binding,receipt:receipt)))
        }
        return try attach()
    }
    /// Reopen requires an explicit attachment to the current root/generation.
    /// The weak service avoids a DB→closure→service→DB retention cycle.
    @discardableResult func attach()throws->Receipt {
        try service.db.transaction {
            let(raw,receipt)=try readComplete(),(count,hash)=try inventory()
            guard count==receipt.jobCount,hash==receipt.indexSHA256 else{throw NativeRestoreActivationFailure("quarantine.indexChanged")}
            let startup=self.startup,record=self.record
            try service.db.attachRestoredJobQuarantine(marker:raw,authorize:{[weak service] in
                guard let service else{throw NativeRestoreActivationFailure("quarantine.ownerReleased")}
                try Self.authority(service,startup,record)
            })
            return receipt
        }
    }
    func requireReady()throws->Receipt {
        try service.db.transaction {
            let(_,receipt)=try readComplete();try service.db.requireRestoredJobQuarantineFence();return receipt
        }
    }
}
