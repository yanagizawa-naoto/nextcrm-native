import Foundation
import CryptoKit

extension CRMService {
    func projectBoardJobs(boardID: String, offset: Int = 0) throws -> [NativeJob] {
        try assertAccess("Boards",id:boardID)
        let canEdit = (try? assertAccess("Boards",id:boardID,write:true)) != nil
        return try db.jobs(events:Self.projectJobEvents,boardID:boardID,recipientID:canEdit ? nil : identity.id,offset:offset)
    }
    func projectJobs(taskID: String, offset: Int = 0) throws -> [NativeJob] {
        let access = try projectTaskOverview(taskID)
        return try db.jobs(events:Self.projectJobEvents,taskID:taskID,recipientID:access.canEdit ? nil : identity.id,offset:offset)
    }
    func projectJobAccess(_ id: String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id:id), Self.projectJobEvents.contains(job.event), let taskID = job.payload["taskId"] else { throw NativeDBError.message("タスクの通知が見つかりません。") }
        // An accepted/ambiguous send must remain reviewable after task deletion.
        if identity.elevated { return job }
        if let boardID = job.payload["boardId"], (try? assertAccess("Boards",id:boardID,write:true)) != nil { return job }
        let access = try projectTaskOverview(taskID)
        guard access.canEdit || job.payload["recipientId"] == identity.id else { throw NativeDBError.message("この通知を変更する権限がありません。") }
        return job
    }
    func retryProjectJob(_ id: String, now: Date = Date()) throws { try db.transaction { _ = try projectJobAccess(id); try db.retryJob(id:id,now:now) } }
    func cancelProjectJob(_ id: String) throws {
        try db.transaction {
            _ = try projectJobAccess(id)
            try db.cancelJob(id:id)
            try db.deferTerminalMailBodyCleanup(id:id)
        }
    }
}

/// One notification at a time. Current access is checked again immediately
/// before delivery, and retries reuse the exact frozen body/idempotency key.
actor ProjectMailWorker {
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
    private struct Context { let user: NativeRecord; let task: NativeRecord; let canReadBoard: Bool }
    private func context(_ job: NativeJob) throws -> Context {
        guard let taskID = job.payload["taskId"], let boardID = job.payload["boardId"], let recipientID = job.payload["recipientId"],
              let task = try db.page("Tasks",fields:["user","section","createdBy"],equal:["id":.text(taskID)]).rows.first,
              let section = try db.page("Sections",fields:["board"],equal:["id":task["section"]]).rows.first, section["board"] == .text(boardID),
              let board = try db.page("Boards",fields:["deletedAt"],equal:["id":.text(boardID)]).rows.first, board["deletedAt"] == .null,
              let user = try db.get("Users",key:["id":.text(recipientID)]) else { throw Skip(reason:"タスク・プロジェクト・宛先が削除または移動されています。") }
        let service = CRMService(db:db,identity:CRMIdentity(id:recipientID,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        do { try service.authenticated() } catch { throw Skip(reason:"宛先の利用者は現在利用できません。") }
        guard ["admin","manager","user"].contains(user["role"].string) else { throw Skip(reason:"宛先の利用者にタスクの閲覧権限がありません。") }
        let canReadBoard = (try? service.assertAccess("Boards",id:boardID)) != nil
        if job.event == "projects.task_commented" {
            guard canReadBoard else { throw Skip(reason:"宛先の利用者は現在コメントを閲覧できません。") }
            let watched = try db.get("BoardWatchers",key:["board_id":.text(boardID),"user_id":.text(recipientID)]) != nil
            guard watched || task["createdBy"] == .text(recipientID) else { throw Skip(reason:"宛先の利用者は通知対象から外れています。") }
            guard let commentID = job.payload["commentId"],
                  let comment = try db.page("tasksComments",fields:["task","user"],equal:["id":.text(commentID)]).rows.first,
                  comment["task"] == .text(taskID), comment["user"] == .text(job.payload["actorId"] ?? ""),
                  String(comment.revision) == job.payload["commentRevision"] else { throw Skip(reason:"通知対象のコメントが削除または変更されています。") }
        } else {
            guard task["user"] == .text(recipientID) else { throw Skip(reason:"タスクの担当者が変更されています。") }
            // The original assigned-task action grants task-only access even
            // when the parent board is private. Do not reveal its title here.
        }
        return Context(user:user,task:task,canReadBoard:canReadBoard)
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
            let project = access.canReadBoard ? "プロジェクト「"+(current.payload["boardTitle"] ?? "")+"」の" : ""
            let subject: String; var message = access.user["name"].string+" 様\n\n"
            switch current.event {
            case "projects.task_assigned":
                subject = "新しい担当タスク："+title
                message += actor+"さんが、"+project+"タスク「"+title+"」をあなたに割り当てました。"
            case "projects.task_updated":
                subject = "タスクを更新しました："+title
                message += actor+"さんが、"+project+"担当タスク「"+title+"」を更新しました。"
            case "projects.task_commented":
                subject = "タスクにコメントが追加されました："+title
                guard let commentID = current.payload["commentId"], let comment = try db.get("tasksComments",key:["id":.text(commentID)]) else { throw Skip(reason:"コメントが見つかりません。") }
                message += actor+"さんが、"+project+"タスク「"+title+"」にコメントを追加しました。\n\nコメント：\n"+comment["comment"].string
            default: throw NativeDBError.message("通知の種類が正しくありません。")
            }
            let link = try NativeProjectTaskLink(taskID:current.payload["taskId"] ?? "")
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
        guard var job = try db.claimJob(events:CRMService.projectJobEvents,now:clock()) else { return false }
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
            let id = try await ResendMailClient.send(body:url,jobID:job.id,apiKey:key,scope:"project",request:request)
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
