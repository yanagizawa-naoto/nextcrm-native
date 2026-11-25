import Foundation
import CryptoKit
import Darwin

/// One immutable request per cron occurrence. Provider acceptance is persisted
/// before lastSentAt; recovery of that receipt does not require a live schedule.
actor ReportMailWorker {
    typealias Export = (NativeReportSnapshot,String,NativeReportExportFormat,URL,String) throws -> Int
    let db:NativeDatabase
    let account:()throws->InvoiceMailAccount
    let request:ResendMailClient.Request
    let clock:()->Date
    let export:Export
    private var active=false
    private var recovery:NativeMailPreparationFiles.Recovery?,recoveryPassComplete=false
    private let preparationCheckpoint:(String)throws->Void
    init(db:NativeDatabase,account:@escaping ()throws->InvoiceMailAccount,request:@escaping ResendMailClient.Request=ResendMailClient.request,clock:@escaping ()->Date=Date.init,export:@escaping Export={try NativeReportExport.write($0,section:$1,format:$2,to:$3,title:$4)},preparationCheckpoint:@escaping(String)throws->Void={_ in}) {
        self.db=db;self.account=account;self.request=request;self.clock=clock;self.export=export;self.preparationCheckpoint=preparationCheckpoint
    }
    private var root:URL {db.url.deletingLastPathComponent()}
    private struct Skip:Error {let reason:String}
    private struct Context {
        let service:CRMService,schedule:NativeReportSchedule,configuration:NativeReportConfiguration,fingerprint:String
    }
    private func context(_ job:NativeJob)throws->Context {
        try db.transaction {
            guard let schedule=try NativeReportQueue.current(job,db:db),let owner=job.payload["ownerId"],let user=try db.get("Users",key:["id":.text(owner)]) else {throw Skip(reason:"定期送信が変更・停止・削除されているか、所有者が見つかりません。")}
            let identity=CRMIdentity(id:owner,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string),service=CRMService(db:db,identity:identity)
            let configuration:NativeReportConfiguration
            do {
                try service.authenticated()
                configuration=try NativeReportConfigurations(service:service).load(schedule.record["reportConfigId"].string)
            } catch {throw Skip(reason:"所有者は現在このレポートを利用できません。利用者と共有設定を確認してください。")}
            guard configuration.category != .users || identity.elevated else {throw Skip(reason:"利用者レポートの送信権限がありません。")}
            _ = try configuration.filters.period(now:clock());_ = try configuration.filters.currency
            let content:[String:String]=[
                "owner":owner,"role":identity.role,"partnerAccount":identity.partnerAccountID ?? "",
                "config":configuration.id,"configRevision":String(configuration.record.revision),"name":configuration.name,
                "category":configuration.category.rawValue,"filters":configuration.record["filters"].string,
                "schedule":schedule.id,"cron":schedule.settings.cron.expression,"zone":schedule.settings.timeZone.identifier,
                "recipients":String(decoding:try JSONEncoder().encode(schedule.settings.recipients),as:UTF8.self),"format":schedule.settings.format.rawValue]
            let digest=SHA256.hash(data:try JSONSerialization.data(withJSONObject:content,options:.sortedKeys)).map{String(format:"%02x",$0)}.joined()
            if let frozen=job.result["contextSHA256"],frozen != digest {throw Skip(reason:"送信準備後にレポートの設定または所有者の権限が変更されています。")}
            return .init(service:service,schedule:schedule,configuration:configuration,fingerprint:digest)
        }
    }
    private func cleanTitle(_ name:String,limit:Int)->String {
        let text=String(String.UnicodeScalarView(name.unicodeScalars.prefix(limit).map{CharacterSet.controlCharacters.contains($0) ? UnicodeScalar(32)! : $0})).trimmingCharacters(in:.whitespacesAndNewlines)
        return text.isEmpty ? "定期レポート" : text
    }
    private func prepare(_ expected:NativeJob,sender:String)throws->NativeJob {
        let current=try db.transaction {()throws->NativeJob in
            let job=try db.requireJobLease(expected);_ = try context(job)
            if job.result["sha256"] == nil {
                guard job.deliveryStartedAt == nil else {throw MailSendError(message:"送信開始済みですが、保存した添付メールを確認できません。",retryable:false,review:true)}
                // No heartbeat writes during export: they would invalidate the
                // report snapshot. A reclaimed lease still fences publication.
                try db.renewJobLease(job,now:clock(),seconds:3600)
            }
            return job
        }
        if current.result["sha256"] != nil {return current}
        let state=try context(current),config=state.configuration,settings=state.schedule.settings
        let snapshot=try NativeReports(service:state.service,now:clock).build(config.category,filters:config.filters.period(now:clock()),currency:config.filters.currency)
        guard let section=NativeReportExport.standardSection(config.category) else {throw NativeDBError.message("定期送信の集計項目を確認してください。")}
        let preparation=try NativeMailPreparationFiles.create(.report,root:root),stagingID=preparation.id,directory=preparation.url
        defer {withExtendedLifetime(preparation){}}
        try preparationCheckpoint("created")
        do {
            var attachments:[NativeReportMailAttachment]=[]
            let formats:[NativeReportExportFormat]=settings.format == .both ? [.csv,.pdf] : [settings.format == .csv ? .csv : .pdf]
            for format in formats {
                try Task.checkCancellation()
                let name=config.category.rawValue+"-report."+format.rawValue,url=directory.appendingPathComponent("report."+format.rawValue)
                _ = try export(snapshot,section,format,url,cleanTitle(config.name,limit:256));try preparationCheckpoint("exported")
                attachments.append(.init(filename:name,url:url))
            }
            let subject="レポート："+cleanTitle(config.name,limit:220)
            let message="定期レポート「"+config.name+"」を添付しました。\n集計期間："+NativeReportFilters.timestamp(snapshot.filters.from)+" 〜 "+NativeReportFilters.timestamp(snapshot.filters.to)+"\n"
            let body=try NativeReportMailBody.prepare(root:directory,id:stagingID,from:sender,to:settings.recipients,subject:subject,message:message,attachments:attachments)
            try preparationCheckpoint("body")
            let prepared=try db.transaction {
                let fresh=try db.requireJobLease(current),freshState=try context(fresh)
                guard freshState.fingerprint==state.fingerprint else {throw NativeDBError.conflict}
                try snapshot.requireCurrent();try Task.checkCancellation()
                guard fresh.deliveryStartedAt == nil,fresh.result["sha256"] == nil else {throw NativeDBError.conflict}
                try preparation.publish(body,job:fresh,db:db,checkpoint:preparationCheckpoint)
                do {
                    let values=["from":try InvoiceMail.mailbox(sender),"to":settings.recipients.joined(separator:", "),"subject":subject,"sha256":body.sha256,"bytes":String(body.bytes),"contextSHA256":state.fingerprint,"reportName":cleanTitle(config.name,limit:256),"periodFrom":NativeReportFilters.timestamp(snapshot.filters.from),"periodTo":NativeReportFilters.timestamp(snapshot.filters.to)]
                    try db.recordJobResult(fresh,result:fresh.result.merging(values){_,new in new})
                    try preparationCheckpoint("recorded")
                    return try db.requireJobLease(fresh)
                } catch {throw error}
            }
            try preparationCheckpoint("committed")
            return prepared
        } catch {
            if !(error is CancellationError),try db.reportRevision() != snapshot.revision {throw NativeDBError.conflict}
            throw error
        }
    }
    private func removeBody(_ job:NativeJob) {if let file=try? InvoiceMail.bodyURL(root:root,id:job.id){try? FileManager.default.removeItem(at:file)}}
    private func complete(_ job:NativeJob)throws {
        try db.transaction {
            let current=try db.requireJobLease(job)
            guard let receipt=current.result["providerID"],UUID(uuidString:receipt) != nil,let stamp=current.result["acceptedAt"],let accepted=ISO8601DateFormatter().date(from:stamp) else {throw NativeDBError.message("保存された受付結果を確認できません。")}
            try db.acknowledgeReportDelivery(current,acceptedAt:accepted)
            try db.finishJob(current,result:current.result,now:clock())
        }
        removeBody(job)
    }
    @discardableResult func runNext()async throws->Bool {
        guard !active else {return false};active=true;defer{active=false}
        if Task.isCancelled{recovery=nil;recoveryPassComplete=true}
        if !recoveryPassComplete && !db.isReadOnly {
            do {
                if recovery==nil{recovery=try NativeMailPreparationFiles.Recovery(db:db)}
                let page=try recovery!.step();recoveryPassComplete=page.finished || page.busy
                if recoveryPassComplete{recovery=nil}
            }catch is CancellationError{recovery=nil;recoveryPassComplete=true}
            catch{recovery=nil;recoveryPassComplete=true} // Cleanup never blocks ordinary report work.
            await Task.yield()
        }
        guard var job=try db.claimReportJob(now:clock()) else {
            let more = !recoveryPassComplete && !db.isReadOnly
            if !more{recoveryPassComplete=false};return more
        }
        var externalAttempt=false
        do {
            if job.result["providerID"] != nil {try complete(job);return true}
            // Reservation is independent of authorization. Temporarily inactive
            // owners can resume on a future occurrence after reactivation.
            _ = try NativeReportQueue.advance(job,db:db,now:clock())
            if let start=job.deliveryStartedAt,clock()<start || clock().timeIntervalSince(start)>=23*3600 {throw MailSendError(message:"重複送信の防止期間を超えています。送信サービスで結果を確認してください。",retryable:false,review:true)}
            _ = try context(job)
            let credentials=try account(),key=credentials.apiKey,sender=try InvoiceMail.mailbox(credentials.from)
            guard !key.isEmpty,!key.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {throw NativeDBError.message("送信サービスのAPIキーを設定してください。")}
            let digest=SHA256.hash(data:Data(key.utf8)).map{String(format:"%02x",$0)}.joined()
            if job.deliveryStartedAt != nil,job.result["credentialSHA256"] != digest {throw MailSendError(message:"送信開始後にAPIキーが変更されています。送信サービスで結果を確認してください。",retryable:false,review:true)}
            job=try prepare(job,sender:sender)
            if job.deliveryStartedAt == nil,job.result["from"] != sender {throw Skip(reason:"送信準備後に差出人が変更されています。")}
            let url=try InvoiceMail.bodyURL(root:root,id:job.id)
            do {
                guard let hash=job.result["sha256"],let bytes=job.result["bytes"].flatMap(Int.init) else {throw NativeDBError.message("保存したメールの情報が不正です。")}
                try InvoiceMail.verify(url,sha256:hash,bytes:bytes)
            } catch {throw MailSendError(message:"保存した添付メールを確認できません。"+(job.deliveryStartedAt == nil ? "設定と送信履歴を確認してください。" : "送信サービスで結果を確認してください。"),retryable:false,review:job.deliveryStartedAt != nil)}
            try Task.checkCancellation()
            let latest=try account()
            guard latest.apiKey==key,try InvoiceMail.mailbox(latest.from)==sender else {throw Skip(reason:"送信準備中にメール送信設定が変更されています。")}
            job=try db.transaction {
                let fresh=try db.requireJobLease(job);_ = try context(fresh)
                try db.renewJobLease(fresh,now:clock())
                try db.recordJobResult(fresh,result:fresh.result.merging(["credentialSHA256":digest]){_,new in new})
                return try db.markJobDeliveryStarted(fresh,now:clock())
            }
            externalAttempt=true
            let receipt=try await ResendMailClient.send(body:url,jobID:job.id,apiKey:key,scope:"report",request:request)
            try db.transaction {
                let fresh=try db.requireJobLease(job)
                try db.recordJobResult(fresh,result:fresh.result.merging(["providerID":receipt,"acceptedAt":ISO8601DateFormatter().string(from:clock()),"outcome":"sent"]){_,new in new})
            }
            try complete(job)
        } catch {
            guard let current=try? db.requireJobLease(job) else {return true}
            if let skip=error as? Skip {
                if current.deliveryStartedAt == nil {try db.finishJob(current,result:current.result.merging(["outcome":"skipped","reason":skip.reason]){_,new in new},now:clock());removeBody(current)}
                else {try db.failJob(current,message:skip.reason+" 以前の送信結果を送信サービスで確認してください。",needsReview:true)}
                return true
            }
            let mail=error as? MailSendError,conflict:Bool
            if case NativeDBError.conflict=error {conflict=true}else{conflict=false}
            let retryable=mail?.retryable ?? (externalAttempt || current.result["providerID"] != nil || conflict || error is CancellationError || error is NativeMailPreparationFiles.Busy)
            let retry=retryable && current.attempts<8 && mail?.review != true
            let delay=max(mail?.retryAfter ?? 0,min(300,5*pow(2,Double(min(current.attempts-1,6)))))
            let exhausted = !retry && retryable && current.deliveryStartedAt != nil && current.result["providerID"] == nil
            let message=exhausted ? "再試行の上限に達しました。送信サービスで結果を確認してください。" : mail?.message ?? (externalAttempt ? "送信結果を保存できませんでした。同じ送信IDで確認します。" : error.localizedDescription)
            try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(delay) : nil,needsReview:mail?.review == true || exhausted)
        }
        return true
    }
}
