import Foundation

/// A decision about one sealed old SMTP job, never a new sending permission.
enum NativePersonalSMTPReview {
    enum Outcome:String,Codable,CaseIterable {
        case sent,notSent,unknownHeld
        var title:String {switch self {
        case .sent:return "送信済みと確認した（送信済みフォルダへ保存）"
        case .notSent:return "未送信と確認した（旧メールは再送しない）"
        case .unknownHeld:return "結果不明のまま旧メールを保留する"
        }}
    }
    struct Receipt:Codable,Equatable {
        let version:Int,bindingSHA256:String,quarantineValue:String,jobID:String,ownerID:String,generation:String
        let beforeStorageSHA256:String,afterStorageSHA256:String,subjectSHA256:String,outcome:Outcome,note:String,reviewedAt:Date
        let providerPermissionGranted:Bool
    }
    static func key(generation:String,id:String)->String {"personal.restore.smtp-review.v1."+generation+"."+NativeMigrationCodec.hash(Data(id.utf8))}
    static func read(db:NativeDatabase,generation:String,id:String)throws->Receipt? {
        guard let raw=try db.restoredSMTPReviewReceipt(key(generation:generation,id:id)) else{return nil}
        guard let value=try? JSONDecoder().decode(Receipt.self,from:Data(raw.utf8)),value.version==1,value.jobID==id,value.generation==generation,!value.providerPermissionGranted else{throw NativeDBError.conflict}
        return value
    }
    /// Only exact, still-quarantined old SMTP IDs can be acknowledged. New jobs,
    /// provider cursor progress, and other domains never use this exception.
    static func hasAmbiguous(service:CRMService,startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record)throws->Bool {
        let db=service.db,q=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:record)
        _ = try q.requireReady();let binding=try NativePersonalRestoreAdmission.hash(q.binding)
        let generation=record.authority.selection.generation
        var after=""
        while true {
            try Task.checkCancellation();let page=try db.personalPrerequisiteOldJobs(after:after)
            for row in page where row.event==NativeMailDelivery.event && row.ambiguous {
                let job=try service.mailSendJob(row.id)
                guard let receipt=try read(db:db,generation:generation,id:row.id),receipt.outcome == .unknownHeld,
                      receipt.ownerID==service.identity.id,receipt.bindingSHA256==binding,
                      receipt.quarantineValue.hasPrefix(binding+":"),receipt.quarantineValue.utf8.count==129,
                      try db.metadata(NativeDatabase.restoredJobQuarantinePrefix+row.id)==receipt.quarantineValue,
                      receipt.beforeStorageSHA256==receipt.afterStorageSHA256,
                      NativeMigrationCodec.hash(try db.restoredMailReviewSnapshot(job).digestMaterial)==receipt.afterStorageSHA256 else{return true}
            }
            if page.count<100{return false};after=page.last!.id
        }
    }
}
