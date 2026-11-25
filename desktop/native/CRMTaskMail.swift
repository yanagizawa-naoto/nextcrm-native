import Foundation
import CryptoKit

extension CRMService {
    func crmTaskJobs(taskID: String, offset: Int = 0) throws -> [NativeJob] {
        let access = try crmTaskAccess(taskID)
        return try db.jobs(events:Self.crmTaskJobEvents,taskID:taskID,recipientID:access.canEdit ? nil : identity.id,offset:offset)
    }
    func crmTaskJobAccess(_ id: String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id),Self.crmTaskJobEvents.contains(job.event),let taskID = job.payload["taskId"] else { throw NativeDBError.message("CRMタスクの通知が見つかりません。") }
        if identity.elevated { return job }
        let access = try crmTaskAccess(taskID)
        guard access.canEdit || job.payload["recipientId"] == identity.id else { throw NativeDBError.message("この通知を変更する権限がありません。") }
        return job
    }
    func retryCRMTaskJob(_ id: String, now: Date = Date()) throws { try db.transaction { _ = try crmTaskJobAccess(id); try db.retryJob(id:id,now:now) } }
    func cancelCRMTaskJob(_ id: String) throws {
        try db.transaction {
            _ = try crmTaskJobAccess(id)
            try db.cancelJob(id:id)
            try db.deferTerminalMailBodyCleanup(id:id)
        }
    }
}

actor CRMTaskMailWorker {
    let db: NativeDatabase
    let account: () throws -> InvoiceMailAccount
    let request: ResendMailClient.Request
    let clock: () -> Date
    private var active = false
    init(db: NativeDatabase, account: @escaping () throws -> InvoiceMailAccount, request: @escaping ResendMailClient.Request = ResendMailClient.request, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.account = account; self.request = request; self.clock = clock
    }
    private var root: URL { db.url.deletingLastPathComponent() }
    private struct Skip: Error { let reason: String }
    private struct Context { let user: NativeRecord; let task: NativeRecord }
    private func context(_ job: NativeJob) throws -> Context {
        guard let taskID = job.payload["taskId"],let recipientID = job.payload["recipientId"],
              let task = try db.page("crm_Accounts_Tasks",fields:["user","account","opportunity_id","createdBy"],equal:["id":.text(taskID)]).rows.first,
              task["account"].string == job.payload["accountId"],task["opportunity_id"].string == job.payload["opportunityId"],
              let user = try db.get("Users",key:["id":.text(recipientID)]) else { throw Skip(reason:"タスク・関連先・宛先が削除または変更されています。") }
        for (model,field) in [("crm_Accounts","account"),("crm_Opportunities","opportunity_id")] where task[field] != .null {
            guard try db.page(model,fields:[],equal:["id":task[field]]).total == 1 else { throw Skip(reason:"タスクの関連先が削除されています。") }
        }
        let service = CRMService(db:db,identity:CRMIdentity(id:recipientID,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        do { try service.assertAccess("crm_Accounts_Tasks",id:taskID) } catch { throw Skip(reason:"宛先の利用者は現在タスクを閲覧できません。") }
        switch job.event {
        case "crm.task_assigned": guard task["user"] == .text(recipientID) else { throw Skip(reason:"タスクの担当者が変更されています。") }
        case "crm.task_watched": guard task["account"] != .null,try db.get("AccountWatchers",key:["account_id":task["account"],"user_id":.text(recipientID)]) != nil else { throw Skip(reason:"宛先の利用者は取引先のウォッチ対象から外れています。") }
        default: throw Skip(reason:"通知の種類を確認できません。")
        }
        return Context(user:user,task:task)
    }
    private func recipient(_ job: NativeJob) throws -> String {
        let current = try context(job)
        let to = try InvoiceMail.mailbox(current.user["email"].string)
        if let original = job.payload["recipientEmail"], try InvoiceMail.mailbox(original) != to { throw Skip(reason:"通知予約後に宛先メールアドレスが変更されています。") }
        if let frozen = job.result["to"], frozen != to { throw Skip(reason:"送信準備後に宛先メールアドレスが変更されています。") }
        return to
    }
    private func prepare(_ job: NativeJob, sender: String) throws -> NativeJob {
        try db.transaction {
            var current = try db.requireJobLease(job); let to = try recipient(current)
            if current.result["sha256"] != nil { return current }
            guard current.deliveryStartedAt == nil else { throw MailSendError(message:"送信開始済みですが、保存したメールの情報を確認できません。",retryable:false,review:true) }
            let access = try context(current)
            let title = current.payload["taskTitle"] ?? "タスク"; let actor = current.payload["actorName"] ?? "担当者"
            let subject = "新しいCRMタスク："+title
            var message: String
            if current.payload["automationKind"] == NativeCRMAutomationTasks.notificationKind {
                guard current.event == "crm.task_assigned", let content = current.payload["taskContent"], let due = current.payload["taskDueAt"] else { throw NativeDBError.message("自動タスクの通知内容が不正です。") }
                let date = try NativeCRMAutomationDates.parse(due)
                let format = DateFormatter(); format.locale = Locale(identifier: "ja_JP"); format.timeZone = .current; format.dateFormat = "yyyy年M月d日 H:mm (zzz)"
                message = access.user["name"].string+" 様\n\n営業フローによりタスク「"+title+"」が作成されました。\n\n"+content+"\n\n期限："+format.string(from: date)
            } else {
                message = access.user["name"].string+" 様\n\n"+actor+"さんがタスク「"+title+"」を作成しました。"
                message += current.event == "crm.task_assigned" ? "あなたが担当者に設定されています。" : "ウォッチ中の取引先に関連するタスクです。"
            }
            let link = try NativeCRMTaskLink(taskID:current.payload["taskId"] ?? "")
            message += "\n\nタスクを開く：\n"+link.string+"\n\nリンクが開けない場合は、NextCRMの「ファイル → リンクから開く…」へ貼り付けてください。通知元と同じCRMデータが必要です。\n通知日時："+current.createdAt
            let url = try InvoiceMail.bodyURL(root:root,id:current.id)
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
            let body = try InvoiceMail.prepareText(root:root,id:current.id,from:sender,to:to,subject:subject,message:message)
            do {
                var result = current.result
                result.merge(["from":try InvoiceMail.mailbox(sender),"to":to,"subject":subject,"sha256":body.sha256,"bytes":String(body.bytes),"taskLink":link.string]) { _,new in new }
                try db.recordJobResult(current,result:result); current = try db.requireJobLease(current); return current
            } catch { try? FileManager.default.removeItem(at:url); throw error }
        }
    }
    private func complete(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let id = current.result["providerID"], UUID(uuidString:id) != nil else { throw NativeDBError.message("送信結果の識別子が不正です。") }
            try db.finishJob(current,result:current.result,now:clock())
        }
        removeBody(job)
    }
    private func removeBody(_ job: NativeJob) {
        if let url = try? InvoiceMail.bodyURL(root:root,id:job.id) { try? FileManager.default.removeItem(at:url) }
    }

    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard var job = try db.claimJob(events:CRMService.crmTaskJobEvents,now:clock()) else { return false }
        var externalAttempt = false
        do {
            // A stored provider receipt is completed locally even if access,
            // settings or credentials changed while the request was in flight.
            if job.result["providerID"] != nil { try complete(job); return true }
            if let start = job.deliveryStartedAt, clock() < start || clock().timeIntervalSince(start) >= 23*3600 {
                throw MailSendError(message:"重複送信の防止期間を超えています。送信サービスで結果を確認してください。",retryable:false,review:true)
            }
            _ = try recipient(job)
            let credentials = try account()
            let key = credentials.apiKey
            guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw NativeDBError.message("送信サービスのAPIキーを設定してください。") }
            let digest = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
            if job.deliveryStartedAt != nil, job.result["credentialSHA256"] != digest {
                throw MailSendError(message:"送信開始後にAPIキーが変更されました。送信サービスで結果を確認してください。",retryable:false,review:true)
            }
            job = try prepare(job,sender:credentials.from)
            let url = try InvoiceMail.bodyURL(root:root,id:job.id)
            guard let hash = job.result["sha256"], let size = job.result["bytes"].flatMap(Int.init) else { throw NativeDBError.message("保存したメールの情報が不正です。") }
            try InvoiceMail.verify(url,sha256:hash,bytes:size)
            job = try db.transaction {
                let current = try db.requireJobLease(job); _ = try recipient(current)
                try db.renewJobLease(current,now:clock())
                try db.recordJobResult(current,result:current.result.merging(["credentialSHA256":digest]) { _,new in new })
                return try db.markJobDeliveryStarted(current,now:clock())
            }
            externalAttempt = true
            let id = try await ResendMailClient.send(body:url,jobID:job.id,apiKey:key,scope:"crm-task",request:request)
            try db.transaction {
                let current = try db.requireJobLease(job)
                try db.recordJobResult(current,result:current.result.merging(["providerID":id,"acceptedAt":ISO8601DateFormatter().string(from:clock()),"outcome":"sent"]) { _,new in new })
            }
            try complete(job)
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if let skip = error as? Skip {
                if current.deliveryStartedAt == nil {
                    try db.finishJob(current,result:current.result.merging(["outcome":"skipped","reason":skip.reason]) { _,new in new },now:clock()); removeBody(current)
                } else { try db.failJob(current,message:skip.reason+" 以前の送信結果を送信サービスで確認してください。",needsReview:true) }
                return true
            }
            let mail = error as? MailSendError
            let conflict: Bool
            if case NativeDBError.conflict = error { conflict = true } else { conflict = false }
            let retryable = mail?.retryable ?? (externalAttempt || current.result["providerID"] != nil || conflict)
            let retry = retryable && current.attempts < 8 && mail?.review != true
            let delay = max(mail?.retryAfter ?? 0,min(300,5*pow(2,Double(min(current.attempts-1,6)))))
            let exhausted = !retry && retryable && current.deliveryStartedAt != nil && current.result["providerID"] == nil
            let message = exhausted ? "再試行の上限に達しました。送信サービスで結果を確認してください。" : mail?.message ?? (externalAttempt ? "送信結果を保存できませんでした。同じ送信IDで確認します。" : error.localizedDescription)
            try db.failJob(current,message:message,retryAt:retry ? clock().addingTimeInterval(delay) : nil,needsReview:mail?.review == true || exhausted)
        }
        return true
    }
}
