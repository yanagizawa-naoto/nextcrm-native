import Foundation
import CryptoKit

actor CampaignMailWorker {
    let db: NativeDatabase
    let account: () throws -> InvoiceMailAccount
    let configuration: () throws -> CampaignMailConfiguration
    // Required dependency: runtime registers this send's token, verifies the
    // public route, drains opt-outs and renews this job's lease while paging.
    let endpointReady: (NativeJob,CampaignMailConfiguration) async throws -> Void
    let request: ResendMailClient.Request
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, account: @escaping () throws -> InvoiceMailAccount, configuration: @escaping () throws -> CampaignMailConfiguration, endpointReady: @escaping (NativeJob,CampaignMailConfiguration) async throws -> Void, request: @escaping ResendMailClient.Request = ResendMailClient.request, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.account = account; self.configuration = configuration; self.endpointReady = endpointReady; self.request = request; self.clock = clock
    }
    private var root: URL { db.url.deletingLastPathComponent() }
    private struct Skip: Error { let reason: String }
    private struct Context { let campaign: NativeRecord; let send: NativeRecord; let step: NativeRecord; let target: NativeRecord; let actorID: String }
    private func context(_ job: NativeJob) throws -> Context {
        guard job.event == CampaignWorkflow.sendStepEvent, job.payload["sendId"] == job.id,
              let campaignID = job.payload["campaignId"], UUID(uuidString:campaignID) != nil,
              let send = try db.get("crm_campaign_sends",key:["id":.text(job.id)]), send["campaign_id"] == .text(campaignID),
              let campaign = try db.page("crm_campaigns",fields:["status","deletedAt","from_name","reply_to"],equal:["id":.text(campaignID)],limit:1).rows.first,
              let intent = try db.campaignMailIntent(sendID:job.id) else { throw Skip(reason:"送信予約またはキャンペーンが見つかりません。") }
        guard ["sending","sent"].contains(campaign["status"].string), campaign["deletedAt"] == .null,
              try db.metadata(CampaignWorkflow.runKey(campaignID)) == intent.token else { throw Skip(reason:"停止・削除・変更されたキャンペーンです。") }
        guard let user = try db.page("Users",fields:["role"],equal:["id":.text(intent.actorID)],limit:1).rows.first,
              ["admin","manager"].contains(user["role"].string) else { throw Skip(reason:"配信を予約した利用者の権限が変更されています。") }
        let service = CRMService(db:db,identity:CRMIdentity(id:intent.actorID,role:user["role"].string,partnerAccountID:nil))
        do { try service.assertAccess("crm_campaigns",id:campaignID) } catch { throw Skip(reason:"配信を予約した利用者は現在このキャンペーンを利用できません。") }
        if ["sent","delivered","bounced"].contains(send["status"].string) { throw Skip(reason:"このメールはすでに送信処理済みです。") }
        guard ["queued","failed","sending"].contains(send["status"].string) else { throw Skip(reason:"送信状態が変更されています。") }
        if send["status"] == .text("sending"), job.deliveryStartedAt == nil { throw MailSendError(message:"以前の送信中の記録があります。送信結果を確認してください。",retryable:false,review:true) }
        guard send["unsubscribed_at"] == .null,
              let target = try db.page("crm_Targets",fields:CampaignMergeTags.fields+["do_not_email","deletedAt"],equal:["id":send["target_id"]],limit:1).rows.first,
              target["deletedAt"] == .null, target["do_not_email"] == .integer(0) else { throw Skip(reason:"宛先が配信停止・削除されています。") }
        guard try InvoiceMail.mailbox(target["email"].string) == InvoiceMail.mailbox(send["email"].string),
              job.result["to"] == nil || job.result["to"] == send["email"].string.trimmingCharacters(in:.whitespacesAndNewlines) else { throw NativeDBError.message("予約後に宛先メールアドレスが変更されています。") }
        guard let step = try db.get("crm_campaign_steps",key:["id":send["step_id"]]), step["campaign_id"] == send["campaign_id"] else { throw Skip(reason:"配信手順が削除・変更されています。") }
        do { try service.assertAccess("crm_campaign_templates",id:step["template_id"].string) } catch { throw Skip(reason:"メールのテンプレートは現在利用できません。") }
        return Context(campaign:campaign,send:send,step:step,target:target,actorID:intent.actorID)
    }
    private func prepare(_ job: NativeJob, account: InvoiceMailAccount, configuration: CampaignMailConfiguration) throws -> NativeJob {
        var created: URL?
        do { return try db.transaction {
            let current = try db.requireJobLease(job), c = try context(current)
            if current.result["sha256"] != nil { return current }
            guard current.deliveryStartedAt == nil else { throw MailSendError(message:"送信開始済みですが、保存した本文の情報がありません。",retryable:false,review:true) }
            guard let template = try db.page("crm_campaign_templates",fields:["content_html"],equal:["id":c.step["template_id"]],limit:1).rows.first else { throw NativeDBError.conflict }
            let url = try InvoiceMail.bodyURL(root:root,id:current.id)
            // A file with no published digest and no request is an interrupted
            // preparation. A published/started payload is never overwritten.
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
            let target = Dictionary(uniqueKeysWithValues:CampaignMergeTags.fields.map{($0,c.target[$0].string)})
            let prepared = try CampaignMail.prepare(root:root,id:current.id,address:account.from,fromName:c.campaign["from_name"].string,to:c.send["email"].string,subject:c.step["subject"].string,html:template["content_html"].string,replyTo:c.campaign["reply_to"].string,token:c.send["unsubscribe_token"].string,target:target,configuration:configuration)
            created = prepared.body.url
            let result = current.result.merging(["from":prepared.from,"to":prepared.to,"subject":prepared.subject,"replyTo":prepared.replyTo,"sha256":prepared.body.sha256,"bytes":String(prepared.body.bytes),"publicURL":configuration.publicURL.absoluteString,"appName":configuration.appName,"unsubscribeURL":prepared.unsubscribeURL.absoluteString,"actorID":c.actorID]){_,v in v}
            try db.recordJobResult(current,result:result)
            return try db.requireJobLease(current)
        } } catch { if let created { try? FileManager.default.removeItem(at:created) }; throw error }
    }
    private func settingsMatch(_ job: NativeJob, c: Context, account: InvoiceMailAccount, configuration: CampaignMailConfiguration) throws {
        let from = try CampaignMail.sender(address:account.from,name:c.campaign["from_name"].string)
        let reply = try c.campaign["reply_to"].string.isEmpty ? "" : InvoiceMail.mailbox(c.campaign["reply_to"].string)
        guard job.result["from"] == from, job.result["replyTo"] == reply,
              job.result["publicURL"] == configuration.publicURL.absoluteString, job.result["appName"] == configuration.appName,
              job.result["unsubscribeURL"] == (try configuration.unsubscribeURL(token:c.send["unsubscribe_token"].string)).absoluteString else {
            throw MailSendError(message:"送信準備後に差出人・返信先・公開URLの設定が変更されています。保存した送信内容を確認してください。",retryable:false,review:job.deliveryStartedAt != nil)
        }
    }
    private func checkWindow(_ job: NativeJob) throws {
        if let start = job.deliveryStartedAt, clock() < start || clock().timeIntervalSince(start) >= 23*3600 {
            throw MailSendError(message:"重複送信の防止期間を超えています。送信サービスで結果を確認してください。",retryable:false,review:true)
        }
    }
    private func keyDigest(_ account: InvoiceMailAccount) throws -> String {
        guard !account.apiKey.isEmpty, !account.apiKey.contains(where:{$0.isWhitespace}) else { throw NativeDBError.message("送信サービスのAPIキーを設定してください。") }
        return SHA256.hash(data:Data(account.apiKey.utf8)).map{String(format:"%02x",$0)}.joined()
    }
    private func complete(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let id = current.result["providerID"], UUID(uuidString:id) != nil,
                  let accepted = current.result["acceptedAt"], CampaignWorkflow.date(.text(accepted)) != nil,
                  let actor = current.result["actorID"], let campaignID = current.payload["campaignId"], current.payload["sendId"] == current.id,
                  let send = try db.get("crm_campaign_sends",key:["id":.text(current.id)]), send["campaign_id"] == .text(campaignID) else { throw NativeDBError.message("保存した送信結果が不正です。") }
            guard send["resend_message_id"] == .null || send["resend_message_id"] == .text(id),
                  try db.page("crm_campaign_sends",fields:[],equal:["resend_message_id":.text(id)],limit:2).rows.allSatisfy({$0["id"] == send["id"]}) else { throw MailSendError(message:"送信結果の識別子が別の記録と競合しています。",retryable:false,review:true) }
            var changes: [String:SQLValue] = ["resend_message_id":.text(id)]
            if send["sent_at"] == .null { changes["sent_at"] = .text(accepted) }
            if !["delivered","bounced"].contains(send["status"].string) { changes["status"] = .text("sent"); changes["error_message"] = .null }
            _ = try db.update(send,changes:changes,actor:actor,action:"campaign_mail_accepted")
            try db.reconcileCampaignEvents(providerID:id,now:clock())
            try db.finishJob(current,result:current.result,now:clock())
            try CampaignDispatch.finishInitialIfReady(db:db,campaignID:campaignID,actorID:actor,now:clock())
            _ = try CampaignRelayJobs.request(db:db,now:clock())
        }
        if let url = try? InvoiceMail.bodyURL(root:root,id:job.id) { try? FileManager.default.removeItem(at:url) }
    }
    private func finishSkipped(_ job: NativeJob, reason: String) throws {
        try db.transaction {
            try db.finishJob(job,result:job.result.merging(["outcome":"skipped","reason":reason]){_,v in v},now:clock())
            if let campaignID = job.payload["campaignId"], let intent = try db.campaignMailIntent(sendID:job.id) {
                try CampaignDispatch.finishInitialIfReady(db:db,campaignID:campaignID,actorID:intent.actorID,now:clock())
            }
        }
        // Keep a published body: an authorized resume reuses this same job ID.
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard var job = try db.claimJob(events:[CampaignWorkflow.sendStepEvent],now:clock()) else { return false }
        var externalAttempt = false
        let previousRequest = job.deliveryStartedAt != nil
        do {
            if job.result["providerID"] != nil { try complete(job); return true }
            try checkWindow(job); _ = try context(job)
            let credentials = try account(), config = try configuration(), digest = try keyDigest(credentials)
            if job.deliveryStartedAt != nil, job.result["credentialSHA256"] != digest { throw MailSendError(message:"送信開始後にAPIキーが変更されています。送信結果を確認してください。",retryable:false,review:true) }
            job = try prepare(job,account:credentials,configuration:config)
            let url = try InvoiceMail.bodyURL(root:root,id:job.id)
            guard let hash = job.result["sha256"], let bytes = job.result["bytes"].flatMap(Int.init) else { throw NativeDBError.message("保存したメールの情報が不正です。") }
            try InvoiceMail.verify(url,sha256:hash,bytes:bytes)
            try settingsMatch(job,c:context(job),account:credentials,configuration:config)
            try await endpointReady(job,config)
            // Awaited readiness can race with edits/revocation/settings changes.
            // Reload both credentials and all database gates immediately before
            // starting the external request, never holding a DB lock over await.
            let latest = try account(), latestConfig = try configuration()
            guard try keyDigest(latest) == digest, latest.from == credentials.from, latestConfig == config else { throw MailSendError(message:"送信直前にメール設定が変更されました。再試行してください。",retryable:true,review:false) }
            job = try db.transaction {
                let current = try db.requireJobLease(job), c = try context(current)
                try checkWindow(current); try settingsMatch(current,c:c,account:latest,configuration:latestConfig)
                try db.renewJobLease(current,now:clock())
                try db.recordJobResult(current,result:current.result.merging(["credentialSHA256":digest]){_,v in v})
                let started = try db.markJobDeliveryStarted(current,now:clock())
                _ = try db.update(c.send,changes:["status":.text("sending"),"error_message":.null],actor:c.actorID,action:"campaign_mail_started")
                return started
            }
            externalAttempt = true
            let id = try await ResendMailClient.send(body:url,jobID:job.id,apiKey:latest.apiKey,scope:"campaign",request:request)
            try db.transaction {
                let current = try db.requireJobLease(job)
                try db.recordJobResult(current,result:current.result.merging(["providerID":id,"acceptedAt":try CampaignWorkflow.stamp(clock()),"outcome":"sent"]){_,v in v})
            }
            try complete(job)
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if let receipt = error as? CampaignRelayReceiptConflict, receipt.sendID == current.id {
                try db.transaction {
                    try db.recordJobResult(current,result:current.result.merging(["relayProviderIDHint":receipt.providerID,"relayInstanceIDHint":receipt.instanceID,"relayHintAt":try CampaignWorkflow.stamp(clock())]){_,v in v})
                    try db.failJob(current,message:receipt.localizedDescription,needsReview:true)
                }
                return true
            }
            if let skip = error as? Skip {
                if current.deliveryStartedAt == nil { try finishSkipped(current,reason:skip.reason) }
                else { try db.failJob(current,message:skip.reason+" 以前の送信結果を確認してください。",needsReview:true) }
                return true
            }
            let mail = error as? MailSendError
            let conflict: Bool; if case NativeDBError.conflict = error { conflict = true } else { conflict = false }
            let relay = error as? CampaignRelayError
            let retryable = mail?.retryable ?? relay?.retryable ?? (externalAttempt || current.result["providerID"] != nil || conflict)
            let retry = retryable && current.attempts < 8 && mail?.review != true
            let ambiguous = current.deliveryStartedAt != nil && current.result["providerID"] == nil
            // A local failure after an unknown request cannot safely become a
            // definitive failed send, even when that local error is permanent.
            let review = mail?.review == true || (!retry && ambiguous && (retryable || !externalAttempt || previousRequest))
            let delay = max(mail?.retryAfter ?? 0,min(300,5*pow(2,Double(min(current.attempts-1,6)))))
            let message = mail?.message ?? (externalAttempt ? "送信結果を保存できませんでした。同じ送信IDで確認します。" : error.localizedDescription)
            try db.transaction {
                try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(delay) : nil,needsReview:review)
                if !retry && !review && current.result["providerID"] == nil,
                   let send = try db.get("crm_campaign_sends",key:["id":.text(current.id)]), ["queued","sending","failed"].contains(send["status"].string),
                   let intent = try db.campaignMailIntent(sendID:current.id) {
                    _ = try db.update(send,changes:["status":.text("failed"),"error_message":.text(message)],actor:intent.actorID,action:"campaign_mail_failed")
                    try CampaignDispatch.finishInitialIfReady(db:db,campaignID:send["campaign_id"].string,actorID:intent.actorID,now:clock())
                }
            }
        }
        return true
    }
}
