import Foundation
import SQLite3
import Darwin

/// Review of source outbox rows only. This is never provider/startup permission.
final class NativePersonalProviderReview {
    static let domain="personal-restore-job-review-v1"
    struct Row {
        let position:Int64,id:String,event:String,restoredState:String,planSHA256:String
        var eventLabel:String {NativePersonalProviderReview.eventLabel(event)}
        var displayID:String {UUID(uuidString:id) != nil ? id:"識別子確認待ち"}
    }
    struct Page {let rows:[Row],total:Int}
    struct Ticket {
        let job:NativeJob,validUntil:Date
        fileprivate let row:Row,subject:String,ownerRevision:Int64,issuedAt:Date
        fileprivate let storage:NativeRestoredMailReviewSnapshot,quarantineValue:String?
    }
    struct Receipt:Codable,Equatable {
        let version:Int,domain:String,subjectSHA256:String,transitionID:String,generation:String,ownerID:String
        let jobID:String,event:String,planSHA256:String,beforeJobSHA256:String,afterJobSHA256:String
        let outcome:String,reviewedAt:Date
        let beforeStorageSHA256:String?,afterStorageSHA256:String?
        let providerPermissionGranted:Bool
        var calendarScope:NativePersonalCalendarHold.Scope? = nil
    }
    private struct Subject:Encodable {
        let domain:String,authority:NativePersonalRestoreAuthority.Evidence,transitionID:String,activationID:String
        let seal:NativeRestoreActivationSeal,ownerID:String,ownerRevision:Int64,role:String,partnerAccountID:String?
        let planSHA256:String,jobSHA256:String,storageSHA256:String,issuedAt:Date,validUntil:Date
    }
    let service:CRMService
    private let startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record,clock:()->Date
    private let lock=NSRecursiveLock()
    private var index:NativePersonalProviderReviewIndex?,closed=false
    private var planIdentity:NativeMigrationFiles.Fingerprint?
    init(service:CRMService,startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record,clock:@escaping()->Date=Date.init)throws {
        self.service=service;self.startup=startup;self.record=record;self.clock=clock
        try service.db.transaction{_ = try authority()}
    }
    func close(){lock.lock();defer{lock.unlock()};closed=true;index=nil}
    private func authority()throws->NativeRecord {
        try Task.checkCancellation()
        guard !closed,record.phase == .bound,!service.db.isReadOnly,
              service.identity.id==record.owner.ownerID,
              service.db.url.resolvingSymlinksInPath().standardizedFileURL==record.authority.selection.root.url.appendingPathComponent("crm.sqlite").resolvingSymlinksInPath().standardizedFileURL,
              service.db.schema.schemaSHA256==record.owner.schemaSHA256,
              try service.db.metadata("localActor")==service.identity.id else{throw NativeDBError.message("現在の個人用データで確認画面を開き直してください。")}
        try NativePersonalRestoreAdmission.validate(record,startup:startup);try service.authenticated()
        if let planIdentity,try fingerprint() != planIdentity{throw NativeDBError.message("復元計画が変更されました。確認画面を開き直してください。")}

        guard let owner=try service.db.get("Users",key:["id":.text(service.identity.id)]) else{throw NativeDBError.conflict};return owner
    }
    /// Validate every plan byte before publishing the first page. The temporary
    /// SQLite index spills to disk and retains only source IDs/hashes, not payloads.
    func page(offset:Int=0)throws->Page {
        lock.lock();defer{lock.unlock()};_ = try service.db.transaction{try authority()}
        if index==nil {
            let initial=try fingerprint(),built=try NativePersonalProviderReviewIndex()
            let cursor=try NativeRestoreActivationPlanCursor(root:record.authority.selection.root.url,seal:record.seal)
            try built.build(cursor)
            _ = try service.db.transaction{try authority()}
            guard try fingerprint()==initial else{throw NativeDBError.conflict}
            planIdentity=initial;index=built
        }
        guard offset>=0 else{throw NativeDBError.conflict}
        return try index!.page(offset:offset)
    }
    private func fingerprint()throws->NativeMigrationFiles.Fingerprint {
        let directory=try NativeBackupWorkspace.openDirectory(record.authority.selection.root.url);defer{Darwin.close(directory)}
        let fd=openat(directory,"resume-plan.ndjson",O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw NativeDBError.message("復元計画を確認できません。")};defer{Darwin.close(fd)}
        var opened=stat(),named=stat()
        guard fstat(fd,&opened)==0,fstatat(directory,"resume-plan.ndjson",&named,AT_SYMLINK_NOFOLLOW)==0,
              opened.st_mode&S_IFMT==S_IFREG,opened.st_nlink==1,opened.st_uid==geteuid(),opened.st_mode&0o077==0,
              NativeMigrationFiles.Fingerprint(opened)==NativeMigrationFiles.Fingerprint(named) else{throw NativeDBError.conflict}
        return NativeMigrationFiles.Fingerprint(opened)
    }
    func prepare(_ row:Row)throws->Ticket {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction {
            let owner=try authority()
            guard let index,try index.contains(row),UUID(uuidString:row.id) != nil,
                  let job=try service.db.job(id:row.id),job.event==row.event else{throw NativeDBError.conflict}
            let quarantine=try runningReview(row:row,job:job)
            guard job.canReviewMail || quarantine != nil else{throw NativeDBError.message("この旧処理は確認結果を記録できません。未対応・送信開始の記録がない処理は保留のまま保持します。") }
            try access(job)
            guard try service.db.metadata(receiptKey(job.id))==nil else{throw NativeDBError.message("この復元先で確認結果は記録済みです。")}
            let now=clock(),expiry=now.addingTimeInterval(300),storage=try service.db.restoredMailReviewSnapshot(job)
            let subject=try subject(row:row,job:job,storage:storage,ownerRevision:owner.revision,issuedAt:now,expiry:expiry)
            return Ticket(job:job,validUntil:expiry,row:row,subject:subject,ownerRevision:owner.revision,issuedAt:now,storage:storage,quarantineValue:quarantine)
        }
    }
    func receipt(jobID:String)throws->Receipt? {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction{
            _ = try authority();guard let raw=try service.db.metadata(receiptKey(jobID)) else{return nil}
            guard let value=try? JSONDecoder().decode(Receipt.self,from:Data(raw.utf8)),value.version==1,value.domain==Self.domain,
                  value.generation==record.authority.selection.generation,value.ownerID==service.identity.id,
                  value.transitionID==record.transitionID,value.jobID==jobID,!value.providerPermissionGranted else{throw NativeDBError.conflict};return value
        }
    }
    /// Used as CRMJobReviewWindow.Record. The existing service owns all domain
    /// audit/receipt/body cleanup semantics; this adds one minimal binding record.
    @discardableResult func record(_ ticket:Ticket,expected:NativeJob,outcome:MailReviewOutcome,providerID:String,note:String)throws->Receipt {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction {
            let owner=try authority(),now=clock()
            guard now>=ticket.issuedAt,now<ticket.validUntil,owner.revision==ticket.ownerRevision,
                  ticket.job==expected,let current=try service.db.job(id:expected.id),current==expected,
                  let index,try index.contains(ticket.row),
                  try service.db.restoredMailReviewSnapshot(current).digestMaterial==ticket.storage.digestMaterial,
                  try runningReview(row:ticket.row,job:current)==ticket.quarantineValue,
                  current.canReviewMail || ticket.quarantineValue != nil,
                  try subject(row:ticket.row,job:current,storage:ticket.storage,ownerRevision:owner.revision,issuedAt:ticket.issuedAt,expiry:ticket.validUntil)==ticket.subject,
                  try service.db.metadata(receiptKey(current.id))==nil else{throw NativeDBError.message("確認対象が変更されたか、確認時間を過ぎました。一覧から選び直してください。")}
            try access(current)
            func review(_ job:NativeJob)throws {
                if job.event==CampaignWorkflow.sendStepEvent {try service.reviewCampaignMailJob(job,outcome:outcome,providerID:providerID,note:note,now:now)}
                else if NativeCRMSweepJobs.mailEvents.contains(job.event){try service.reviewCRMSweepNotice(job,outcome:outcome,providerID:providerID,note:note,now:now)}
                else{try service.reviewMailJob(job,outcome:outcome,providerID:providerID,note:note,now:now)}
            }
            if let quarantine=ticket.quarantineValue {
                try service.db.reviewRestoredRunningMail(current,snapshot:ticket.storage,quarantineValue:quarantine,
                    authorize:{_ = try self.authority();guard try self.runningReview(row:ticket.row,job:current)==quarantine else{throw NativeDBError.conflict}},review:review)
            }else{try review(current)}
            _ = try authority()
            guard let after=try service.db.job(id:current.id),after.status=="done",after.result["reviewOutcome"]==outcome.rawValue else{throw NativeDBError.conflict}
            let result=Receipt(version:1,domain:Self.domain,subjectSHA256:ticket.subject,transitionID:record.transitionID,
                generation:record.authority.selection.generation,ownerID:service.identity.id,jobID:current.id,event:current.event,
                planSHA256:ticket.row.planSHA256,beforeJobSHA256:try Self.jobHash(current),afterJobSHA256:try Self.jobHash(after),
                outcome:outcome.rawValue,reviewedAt:now,beforeStorageSHA256:NativeMigrationCodec.hash(ticket.storage.digestMaterial),
                afterStorageSHA256:NativeMigrationCodec.hash(try service.db.restoredMailReviewSnapshot(after).digestMaterial),providerPermissionGranted:false)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            try service.db.setMetadata(receiptKey(current.id),value:String(decoding:try encoder.encode(result),as:UTF8.self))
            return result
        }
    }
    /// Running is reviewable only when it was already running in the sealed
    /// source plan and is still fenced from every worker in this restored root.
    private func runningReview(row:Row,job:NativeJob)throws->String? {
        guard job.status=="running" else{return nil}
        guard row.restoredState=="running",job.deliveryStartedAt != nil || job.event==CampaignWorkflow.sendStepEvent else{throw NativeDBError.message("送信開始を確認できない旧処理は、この画面では変更しません。")}
        let quarantine=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:record)
        _ = try quarantine.requireReady()
        let expected=try NativePersonalRestoreAdmission.hash(quarantine.binding)+":"+row.planSHA256
        guard try service.db.metadata(NativeDatabase.restoredJobQuarantinePrefix+job.id)==expected else{throw NativeDBError.message("復元前の処理の隔離を確認できません。確認画面を開き直してください。")}
        return expected
    }
    private func receiptKey(_ id:String)->String {"personal.restore.review.v1."+record.authority.selection.generation+"."+NativeMigrationCodec.hash(Data(id.utf8))}
    private func subject(row:Row,job:NativeJob,storage:NativeRestoredMailReviewSnapshot,ownerRevision:Int64,issuedAt:Date,expiry:Date)throws->String {
        try NativePersonalRestoreAdmission.hash(Subject(domain:Self.domain,authority:record.authority,transitionID:record.transitionID,
            activationID:record.activationID,seal:record.seal,ownerID:service.identity.id,ownerRevision:ownerRevision,
            role:service.identity.role,partnerAccountID:service.identity.partnerAccountID,planSHA256:row.planSHA256,
            jobSHA256:Self.jobHash(job),storageSHA256:NativeMigrationCodec.hash(storage.digestMaterial),issuedAt:issuedAt,validUntil:expiry))
    }
    private func access(_ job:NativeJob)throws {
        let current:NativeJob
        if job.event==CampaignWorkflow.sendStepEvent{current=try service.campaignMailJobAccess(job.id)}
        else if NativeCRMSweepJobs.mailEvents.contains(job.event){current=try service.crmSweepNoticeAccess(job.id)}
        else if CRMService.orderJobEvents.contains(job.event){current=try service.orderJobAccess(job.id)}
        else if CRMService.projectJobEvents.contains(job.event){current=try service.projectJobAccess(job.id)}
        else if CRMService.crmTaskJobEvents.contains(job.event){current=try service.crmTaskJobAccess(job.id)}
        else if job.event==NativeMCPLeads.assignedEvent{current=try service.leadJobAccess(job.id)}
        else if job.event=="invoice.email_requested"{current=try service.invoiceJobAccess(job.id,reviewing:true)}
        else if job.event=="reports.scheduled"{current=try service.reportMailJobAccess(job.id)}
        else{throw NativeDBError.message("この種類の処理は個別の確認方法が必要です。保留を維持します。")}
        guard current==job else{throw NativeDBError.conflict}
    }
    static func jobHash(_ job:NativeJob)throws->String {
        struct Snapshot:Encodable {
            let id:String,event:String,payload:[String:String],status:String,attempts:Int,createdAt:String,nextRunAt:String?,lastError:String?,leaseToken:String?
            let firstAttemptAt:Date?,deliveryStartedAt:Date?,result:[String:String]
        }
        return try NativePersonalRestoreAdmission.hash(Snapshot(id:job.id,event:job.event,payload:job.payload,status:job.status,
            attempts:job.attempts,createdAt:job.createdAt,nextRunAt:job.nextRunAt,lastError:job.lastError,leaseToken:job.leaseToken,
            firstAttemptAt:job.firstAttemptAt,deliveryStartedAt:job.deliveryStartedAt,result:job.result))
    }
    static func eventLabel(_ event:String)->String {
        if event==NativeMailDelivery.event{return "メールアカウントの送信（SMTP）"}
        if event==GoogleCalendarOutbound.event{return "Googleへの予定の反映"}
        if event=="invoice.email_requested"{return "請求書メール"};if event=="reports.scheduled"{return "定期レポート"}
        if event==CampaignWorkflow.sendStepEvent{return "キャンペーンメール"}
        if NativeCRMSweepJobs.mailEvents.contains(event){return "営業自動処理の通知"}
        if CRMService.orderJobEvents.contains(event){return "受注の通知"};if CRMService.projectJobEvents.contains(event){return "プロジェクトの通知"}
        if CRMService.crmTaskJobEvents.contains(event){return "CRMタスクの通知"};if event==NativeMCPLeads.assignedEvent{return "見込み客の通知"}
        return "未対応の処理（保留）"
    }
    struct SMTPTicket {
        let job:NativeJob,preview:NativeMailSendPreview,validUntil:Date,canConfirmResult:Bool,knownAccepted:Bool
        fileprivate let row:Row,subject:String,ownerRevision:Int64,accountRevision:Int64,issuedAt:Date
        fileprivate let storage:NativeRestoredMailReviewSnapshot,quarantineValue:String,bindingSHA256:String
        fileprivate let prior:NativePersonalSMTPReview.Receipt?
    }
    private func smtpBinding(row:Row,job:NativeJob)throws->(String,String) {
        let q=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:record)
        _ = try q.requireReady();let binding=try NativePersonalRestoreAdmission.hash(q.binding),value=binding+":"+row.planSHA256
        guard try service.db.metadata(NativeDatabase.restoredJobQuarantinePrefix+job.id)==value else{throw NativeDBError.conflict}
        return(binding,value)
    }
    func prepareSMTP(_ row:Row)throws->SMTPTicket {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction {
            let owner=try authority()
            guard let index,try index.contains(row),row.event==NativeMailDelivery.event,UUID(uuidString:row.id) != nil else{throw NativeDBError.conflict}
            let job=try service.mailSendJob(row.id)
            guard !["done","cancelled"].contains(job.status),job.status != "running" || row.restoredState=="running" else{throw NativeDBError.conflict}
            let account=try service.mailAccount(job.payload["accountID"]!),binding=try smtpBinding(row:row,job:job)
            let prior=try NativePersonalSMTPReview.read(db:service.db,generation:record.authority.selection.generation,id:job.id)
            let storage=try service.db.restoredMailReviewSnapshot(job),now=clock(),expiry=now.addingTimeInterval(300)
            if let prior {guard prior.outcome == .unknownHeld,prior.bindingSHA256==binding.0,prior.quarantineValue==binding.1,
                prior.afterStorageSHA256==NativeMigrationCodec.hash(storage.digestMaterial) else{throw NativeDBError.conflict}}
            let subject=try subject(row:row,job:job,storage:storage,ownerRevision:owner.revision,issuedAt:now,expiry:expiry)
            return .init(job:job,preview:try service.mailSendPreview(job),validUntil:expiry,
                canConfirmResult:job.result["smtpAccepted"]=="true" || (["needs_review","running"].contains(job.status) && job.deliveryStartedAt != nil),
                knownAccepted:job.result["smtpAccepted"]=="true",row:row,subject:subject,ownerRevision:owner.revision,
                accountRevision:account.revision,issuedAt:now,storage:storage,quarantineValue:binding.1,bindingSHA256:binding.0,prior:prior)
        }
    }
    @discardableResult func recordSMTP(_ ticket:SMTPTicket,outcome:NativePersonalSMTPReview.Outcome,note:String)throws->NativePersonalSMTPReview.Receipt {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction {
            let owner=try authority(),now=clock(),current=try service.mailSendJob(ticket.job.id)
            guard !note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,note.utf8.count<=2000,
                  now>=ticket.issuedAt,now<ticket.validUntil,owner.revision==ticket.ownerRevision,current==ticket.job,
                  let index,try index.contains(ticket.row),
                  try service.mailAccount(current.payload["accountID"]!).revision==ticket.accountRevision,
                  try service.db.restoredMailReviewSnapshot(current).digestMaterial==ticket.storage.digestMaterial,
                  try smtpBinding(row:ticket.row,job:current)==(ticket.bindingSHA256,ticket.quarantineValue),
                  try subject(row:ticket.row,job:current,storage:ticket.storage,ownerRevision:owner.revision,issuedAt:ticket.issuedAt,expiry:ticket.validUntil)==ticket.subject,
                  try NativePersonalSMTPReview.read(db:service.db,generation:record.authority.selection.generation,id:current.id)==ticket.prior else{throw NativeDBError.message("確認対象が変更されたか、確認時間を過ぎました。一覧から選び直してください。")}
            if outcome != .unknownHeld {
                guard ticket.canConfirmResult,!ticket.knownAccepted || outcome == .sent else{throw NativeDBError.message("保存済みの送信記録と矛盾しています。結果不明のまま保留できます。")}
                try service.db.reviewRestoredSMTP(current,snapshot:ticket.storage,quarantineValue:ticket.quarantineValue,sent:outcome == .sent,now:now,
                    authorize:{_ = try self.authority();_ = try self.smtpBinding(row:ticket.row,job:current)},
                    localCopy:{try NativeMailDelivery.recordLocalCopy(db:self.service.db,current:$0,now:now)})
            }
            _ = try authority();guard let after=try service.db.job(id:current.id) else{throw NativeDBError.conflict}
            let beforeSHA=NativeMigrationCodec.hash(ticket.storage.digestMaterial),afterSHA=NativeMigrationCodec.hash(try service.db.restoredMailReviewSnapshot(after).digestMaterial)
            if outcome == .unknownHeld {guard beforeSHA==afterSHA else{throw NativeDBError.conflict}}
            let receipt=NativePersonalSMTPReview.Receipt(version:1,bindingSHA256:ticket.bindingSHA256,quarantineValue:ticket.quarantineValue,
                jobID:current.id,ownerID:service.identity.id,generation:record.authority.selection.generation,beforeStorageSHA256:beforeSHA,
                afterStorageSHA256:afterSHA,subjectSHA256:ticket.subject,outcome:outcome,note:note,reviewedAt:now,providerPermissionGranted:false)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            try service.db.setMetadata(NativePersonalSMTPReview.key(generation:record.authority.selection.generation,id:current.id),value:String(decoding:try encoder.encode(receipt),as:UTF8.self))
            return receipt
        }
    }

    struct GoogleTicket {
        let job:NativeJob,validUntil:Date,scope:NativePersonalCalendarHold.Scope
        var canConfirmNotApplied:Bool {["unknown","rejected"].contains(job.result["requestOutcome"] ?? "") && job.result["remote"]==nil}
        fileprivate let row:Row,subject:String,ownerRevision:Int64,issuedAt:Date
        fileprivate let storage:NativeRestoredMailReviewSnapshot,quarantineValue:String
    }
    private func googleQuarantine(row:Row,job:NativeJob)throws->String {
        guard job.event==GoogleCalendarOutbound.event,["running","needs_review","retry","failed"].contains(job.status),
              job.status != "running" || row.restoredState=="running" else{throw NativeDBError.message("この旧予定は確認対象外です。現在の処理を確認してください。")}
        let quarantine=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:record)
        _ = try quarantine.requireReady()
        let value=try NativePersonalRestoreAdmission.hash(quarantine.binding)+":"+row.planSHA256
        guard try service.db.metadata(NativeDatabase.restoredJobQuarantinePrefix+job.id)==value else{throw NativeDBError.conflict}
        guard try service.googleCalendarPushJob(job.id)==job else{throw NativeDBError.conflict}
        return value
    }
    func prepareGoogle(_ row:Row)throws->GoogleTicket {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction {
            let owner=try authority()
            guard let index,try index.contains(row),UUID(uuidString:row.id) != nil,
                  let job=try service.db.job(id:row.id),job.event==row.event,try service.db.metadata(receiptKey(job.id))==nil else{throw NativeDBError.conflict}
            let quarantine=try googleQuarantine(row:row,job:job),storage=try service.db.restoredMailReviewSnapshot(job)
            let scope=try NativePersonalCalendarHold.prepare(service:service,job:job,storage:storage,quarantineValue:quarantine)
            let now=clock(),expiry=now.addingTimeInterval(300)
            let base=try subject(row:row,job:job,storage:storage,ownerRevision:owner.revision,issuedAt:now,expiry:expiry)
            let bound=try NativePersonalRestoreAdmission.hash([base,NativePersonalRestoreAdmission.hash(scope)])
            return .init(job:job,validUntil:expiry,scope:scope,row:row,subject:bound,ownerRevision:owner.revision,issuedAt:now,storage:storage,quarantineValue:quarantine)
        }
    }
    private func validateGoogle(_ ticket:GoogleTicket)throws {
        let owner=try authority(),now=clock()
        guard now>=ticket.issuedAt,now<ticket.validUntil,owner.revision==ticket.ownerRevision,
              let index,try index.contains(ticket.row),try service.db.job(id:ticket.job.id)==ticket.job,
              try googleQuarantine(row:ticket.row,job:ticket.job)==ticket.quarantineValue,
              try service.db.restoredMailReviewSnapshot(ticket.job).digestMaterial==ticket.storage.digestMaterial,
              try NativePersonalCalendarHold.prepare(service:service,job:ticket.job,storage:ticket.storage,quarantineValue:ticket.quarantineValue)==ticket.scope,
              try service.db.metadata(receiptKey(ticket.job.id))==nil else{throw NativeDBError.message("確認対象が変更されたか、確認時間を過ぎました。一覧から選び直してください。")}
        let base=try subject(row:ticket.row,job:ticket.job,storage:ticket.storage,ownerRevision:owner.revision,issuedAt:ticket.issuedAt,expiry:ticket.validUntil)
        guard try NativePersonalRestoreAdmission.hash([base,NativePersonalRestoreAdmission.hash(ticket.scope)])==ticket.subject else{throw NativeDBError.conflict}
    }
    @discardableResult func recordGoogleNotApplied(_ ticket:GoogleTicket,note:String)throws->Receipt {
        lock.lock();defer{lock.unlock()}
        return try service.db.transaction {
            try validateGoogle(ticket)
            guard ticket.canConfirmNotApplied else{throw NativeDBError.message("保存された反映記録と矛盾するため、未反映として確定できません。保留を維持してください。")}
            try service.db.reviewRestoredCalendarNotApplied(ticket.job,snapshot:ticket.storage,quarantineValue:ticket.quarantineValue,
                sourceState:ticket.row.restoredState,actor:service.identity.id,note:note,now:clock(),authorize:{
                    let owner=try self.authority()
                    guard owner.revision==ticket.ownerRevision,try self.service.db.metadata(NativeDatabase.restoredJobQuarantinePrefix+ticket.job.id)==ticket.quarantineValue else{throw NativeDBError.conflict}
                })
            return try googleReceipt(ticket,outcome:"googleNotApplied",scope:nil)
        }
    }
    @discardableResult func recordGoogleHeld(_ ticket:GoogleTicket,note:String)throws->Receipt {
        lock.lock();defer{lock.unlock()}
        let text=note.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.count<=2000 else{throw NativeDBError.message("確認した内容と保留する理由を2000文字以内で入力してください。")}
        return try service.db.transaction {
            try validateGoogle(ticket)
            try NativePersonalCalendarHold.record(service:service,job:ticket.job,storage:ticket.storage,scope:ticket.scope,authorize:{try self.validateGoogle(ticket)})
            guard try service.db.restoredMailReviewSnapshot(ticket.job).digestMaterial==ticket.storage.digestMaterial else{throw NativeDBError.conflict}
            // This is a local acknowledgement, never a provider success/cancel.
            let result=try googleReceipt(ticket,outcome:"googleUnknownHold",scope:ticket.scope)
            try service.db.setMetadata(receiptKey(ticket.job.id)+".note",value:text)
            return result
        }
    }
    private func googleReceipt(_ ticket:GoogleTicket,outcome:String,scope:NativePersonalCalendarHold.Scope?)throws->Receipt {
        _ = try authority()
        guard let after=try service.db.job(id:ticket.job.id) else{throw NativeDBError.conflict}
        var receipt=Receipt(version:1,domain:Self.domain,subjectSHA256:ticket.subject,transitionID:record.transitionID,
            generation:record.authority.selection.generation,ownerID:service.identity.id,jobID:after.id,event:after.event,
            planSHA256:ticket.row.planSHA256,beforeJobSHA256:try Self.jobHash(ticket.job),afterJobSHA256:try Self.jobHash(after),outcome:outcome,
            reviewedAt:clock(),beforeStorageSHA256:NativeMigrationCodec.hash(ticket.storage.digestMaterial),
            afterStorageSHA256:NativeMigrationCodec.hash(try service.db.restoredMailReviewSnapshot(after).digestMaterial),providerPermissionGranted:false)
        receipt.calendarScope=scope
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try service.db.setMetadata(receiptKey(after.id),value:String(decoding:try encoder.encode(receipt),as:UTF8.self));return receipt
    }
    static func googleHeldAcknowledged(service:CRMService,startup:NativeRestoreApplicationStartup,record:NativePersonalRestoreAdmission.Record,jobID:String)throws->Bool {
        let api=try Self(service:service,startup:startup,record:record);defer{api.close()}
        return try service.db.transaction {
            guard let receipt=try api.receipt(jobID:jobID),receipt.event==GoogleCalendarOutbound.event,
                  receipt.outcome=="googleUnknownHold",let scope=receipt.calendarScope,
                  let job=try service.db.job(id:jobID),job.event==receipt.event,
                  try Self.jobHash(job)==receipt.afterJobSHA256 else{return false}
            let quarantine=try NativePersonalRestoredJobQuarantine(service:service,startup:startup,record:record);_ = try quarantine.requireReady()
            let value=try NativePersonalRestoreAdmission.hash(quarantine.binding)+":"+receipt.planSHA256
            guard try service.db.metadata(NativeDatabase.restoredJobQuarantinePrefix+job.id)==value else{return false}
            let storage=try service.db.restoredMailReviewSnapshot(job)
            guard receipt.beforeStorageSHA256==receipt.afterStorageSHA256,NativeMigrationCodec.hash(storage.digestMaterial)==receipt.afterStorageSHA256 else{return false}
            return try NativePersonalCalendarHold.validate(service:service,job:job,storage:storage,scope:scope)
        }
    }
}
