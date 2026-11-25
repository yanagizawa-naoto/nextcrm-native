import Foundation
import CryptoKit

extension CRMService {
    func leadJobs(leadID: String, offset: Int = 0) throws -> [NativeJob] {
        try assertAccess("crm_Leads", id: leadID, includeDeleted: identity.elevated)
        let canManage = (try? assertAccess("crm_Leads", id: leadID, write: true, includeDeleted: identity.elevated)) != nil
        return try db.jobs(events: [NativeMCPLeads.assignedEvent], recipientID: canManage ? nil : identity.id, leadID: leadID, offset: offset)
    }
    func leadFromLink(_ link: NativeMCPLeadLink) throws -> NativeRecord {
        try assertAccess("crm_Leads", id: link.leadID)
        guard let row = try db.get("crm_Leads", key: ["id": .text(link.leadID)]) else { throw NativeDBError.conflict }
        return row
    }
    func leadJobAccess(_ id: String) throws -> NativeJob {
        try authenticated()
        guard let job = try db.job(id: id), job.event == NativeMCPLeads.assignedEvent, let leadID = job.payload["leadId"] else { throw NativeDBError.message("見込み客の通知が見つかりません。") }
        if identity.elevated { return job }
        try assertAccess("crm_Leads", id: leadID, write: true, includeDeleted: true)
        return job
    }
    func retryLeadJob(_ id: String, now: Date = Date()) throws { try db.transaction { _ = try leadJobAccess(id); try db.retryJob(id: id, now: now) } }
    func cancelLeadJob(_ id: String) throws {
        try db.transaction {
            _ = try leadJobAccess(id)
            try db.cancelJob(id:id)
            try db.deferTerminalMailBodyCleanup(id:id)
        }
    }
}

/// Japanese assignee mail uses the existing frozen-body/idempotent delivery
/// mechanism. It rechecks current recipient and lead access before sending.
actor NativeMCPLeadsMailWorker {
    let db: NativeDatabase, account: () throws -> InvoiceMailAccount
    let request: ResendMailClient.Request, clock: () -> Date
    private var active = false
    init(db: NativeDatabase, account: @escaping () throws -> InvoiceMailAccount, request: @escaping ResendMailClient.Request = ResendMailClient.request, clock: @escaping () -> Date = Date.init) {
        self.db = db; self.account = account; self.request = request; self.clock = clock
    }
    private var root: URL { db.url.deletingLastPathComponent() }
    private struct Skip: Error { let reason: String }
    private func mailSubject(_ title: String) -> String {
        let prefix = "見込み客の担当者に設定されました："
        let clean = title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if prefix.utf8.count + clean.utf8.count <= 998 { return prefix + clean }
        var result = prefix, bytes = prefix.utf8.count
        for scalar in clean.unicodeScalars {
            let part = String(scalar), length = part.utf8.count
            if bytes + length > 995 { break }
            result += part; bytes += length
        }
        return result + "…"
    }
    private func recipient(_ job: NativeJob) throws -> (user: NativeRecord, address: String) {
        guard let leadID = job.payload["leadId"], let recipientID = job.payload["recipientId"],
              let lead = try db.page("crm_Leads", fields: ["assigned_to", "createdBy", "accountsIDs"], equal: ["id": .text(leadID)], limit: 1).rows.first,
              lead["assigned_to"] == .text(recipientID), let user = try db.get("Users", key: ["id": .text(recipientID)]) else { throw Skip(reason: "見込み客が削除されたか、担当者が変更されています。") }
        let service = CRMService(db: db, identity: .init(id: recipientID, role: user["role"].string, partnerAccountID: user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        do { try service.assertAccess("crm_Leads", id: leadID) } catch { throw Skip(reason: "宛先の利用者は現在この見込み客を閲覧できません。") }
        let address = try InvoiceMail.mailbox(user["email"].string)
        if let original = job.payload["recipientEmail"], try InvoiceMail.mailbox(original) != address { throw Skip(reason: "通知予約後に宛先メールアドレスが変更されています。") }
        if let frozen = job.result["to"], frozen != address { throw Skip(reason: "送信準備後に宛先メールアドレスが変更されています。") }
        return (user, address)
    }
    private func prepare(_ job: NativeJob, sender: String) throws -> NativeJob {
        try db.transaction {
            var current = try db.requireJobLease(job); let target = try recipient(current)
            if current.result["sha256"] != nil { return current }
            guard current.deliveryStartedAt == nil else { throw MailSendError(message: "送信開始済みですが、保存したメールの情報を確認できません。", retryable: false, review: true) }
            let title = current.payload["leadName"] ?? "見込み客", link = try NativeMCPLeadLink(leadID: current.payload["leadId"] ?? "")
            let subject = mailSubject(title)
            let message = target.user["name"].string + " 様\n\n見込み客「" + title + "」の担当者に設定されました。\n\n見込み客を開く：\n" + link.string + "\n\nリンクが開けない場合は、NextCRMの「ファイル → リンクから開く…」へ貼り付けてください。通知元と同じCRMデータが必要です。\n通知日時：" + current.createdAt
            let url = try InvoiceMail.bodyURL(root: root, id: current.id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            let body = try InvoiceMail.prepareText(root: root, id: current.id, from: sender, to: target.address, subject: subject, message: message)
            do {
                var result = current.result
                result.merge(["from": try InvoiceMail.mailbox(sender), "to": target.address, "subject": subject, "sha256": body.sha256, "bytes": String(body.bytes), "leadLink": link.string]) { _, new in new }
                try db.recordJobResult(current, result: result); current = try db.requireJobLease(current); return current
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }
    private func removeBody(_ job: NativeJob) { if let url = try? InvoiceMail.bodyURL(root: root, id: job.id) { try? FileManager.default.removeItem(at: url) } }
    private func complete(_ job: NativeJob) throws {
        try db.transaction {
            let current = try db.requireJobLease(job)
            guard let id = current.result["providerID"], UUID(uuidString: id) != nil else { throw NativeDBError.message("送信結果の識別子が不正です。") }
            try db.finishJob(current, result: current.result, now: clock())
        }
        removeBody(job)
    }
    @discardableResult func runNext() async throws -> Bool {
        guard !active else { return false }; active = true; defer { active = false }
        guard var job = try db.claimJob(events: [NativeMCPLeads.assignedEvent], now: clock()) else { return false }
        var externalAttempt = false
        do {
            if job.result["providerID"] != nil { try complete(job); return true }
            if let start = job.deliveryStartedAt, clock() < start || clock().timeIntervalSince(start) >= 23 * 3600 { throw MailSendError(message: "重複送信の防止期間を超えています。送信サービスで結果を確認してください。", retryable: false, review: true) }
            _ = try recipient(job)
            let credentials = try account(), key = credentials.apiKey
            guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw NativeDBError.message("送信サービスのAPIキーを設定してください。") }
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            if job.deliveryStartedAt != nil, job.result["credentialSHA256"] != digest { throw MailSendError(message: "送信開始後にAPIキーが変更されました。送信サービスで結果を確認してください。", retryable: false, review: true) }
            job = try prepare(job, sender: credentials.from)
            let url = try InvoiceMail.bodyURL(root: root, id: job.id)
            guard let hash = job.result["sha256"], let size = job.result["bytes"].flatMap(Int.init) else { throw NativeDBError.message("保存したメールの情報が不正です。") }
            try InvoiceMail.verify(url, sha256: hash, bytes: size)
            job = try db.transaction {
                let current = try db.requireJobLease(job); _ = try recipient(current)
                try db.renewJobLease(current, now: clock())
                try db.recordJobResult(current, result: current.result.merging(["credentialSHA256": digest]) { _, new in new })
                return try db.markJobDeliveryStarted(current, now: clock())
            }
            externalAttempt = true
            let id = try await ResendMailClient.send(body: url, jobID: job.id, apiKey: key, scope: "lead", request: request)
            try db.transaction {
                let current = try db.requireJobLease(job)
                try db.recordJobResult(current, result: current.result.merging(["providerID": id, "acceptedAt": ISO8601DateFormatter().string(from: clock()), "outcome": "sent"]) { _, new in new })
            }
            try complete(job)
        } catch {
            guard let current = try? db.requireJobLease(job) else { return true }
            if let skip = error as? Skip {
                if current.deliveryStartedAt == nil { try db.finishJob(current, result: current.result.merging(["outcome": "skipped", "reason": skip.reason]) { _, new in new }, now: clock()); removeBody(current) }
                else { try db.failJob(current, message: skip.reason + " 以前の送信結果を送信サービスで確認してください。", needsReview: true) }
                return true
            }
            let mail = error as? MailSendError
            let conflict: Bool; if case NativeDBError.conflict = error { conflict = true } else { conflict = false }
            let retryable = mail?.retryable ?? (externalAttempt || current.result["providerID"] != nil || conflict)
            let retry = retryable && current.attempts < 8 && mail?.review != true
            let delay = max(mail?.retryAfter ?? 0, min(300, 5 * pow(2, Double(min(current.attempts - 1, 6)))))
            let exhausted = !retry && retryable && current.deliveryStartedAt != nil && current.result["providerID"] == nil
            let message = exhausted ? "再試行の上限に達しました。送信サービスで結果を確認してください。" : mail?.message ?? (externalAttempt ? "送信結果を保存できませんでした。同じ送信IDで確認します。" : error.localizedDescription)
            try db.failJob(current, message: message, retryAt: retry ? clock().addingTimeInterval(delay) : nil, needsReview: mail?.review == true || exhausted)
        }
        return true
    }
}
