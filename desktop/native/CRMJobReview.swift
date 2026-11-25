import Foundation

extension CRMService {
    /// Compare the exact row shown to the operator inside BEGIN IMMEDIATE. A
    /// competing worker/reviewer cannot have its newer result overwritten.
    func reviewMailJob(_ expected: NativeJob, outcome: MailReviewOutcome, providerID: String, note: String, now: Date = Date()) throws {
        let memo = note.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !memo.isEmpty, memo.count <= 2000, memo.utf8.count <= 8000 else { throw NativeDBError.message("確認した内容を2,000文字以内で記入してください。") }
        let suppliedID = providerID.trimmingCharacters(in:.whitespacesAndNewlines)
        let receipt: String?
        if outcome == .accepted {
            guard let id = UUID(uuidString:suppliedID), id.uuidString.lowercased() == suppliedID.lowercased() else { throw NativeDBError.message("送信サービスで確認した受付IDを入力してください。") }
            receipt = id.uuidString.lowercased()
        } else {
            guard suppliedID.isEmpty else { throw NativeDBError.message("受付IDがある場合は「送信サービスの受付を確認」を選択してください。") }
            receipt = nil
        }
        try db.transaction {
            let current: NativeJob
            if Self.orderJobEvents.contains(expected.event) { current = try orderJobAccess(expected.id) }
            else if Self.projectJobEvents.contains(expected.event) { current = try projectJobAccess(expected.id) }
            else if Self.crmTaskJobEvents.contains(expected.event) { current = try crmTaskJobAccess(expected.id) }
            else if expected.event == NativeMCPLeads.assignedEvent { current = try leadJobAccess(expected.id) }
            else if expected.event == "invoice.email_requested" { current = try invoiceJobAccess(expected.id,reviewing:true) }
            else if expected.event == "reports.scheduled" { current = try reportMailJobAccess(expected.id) }
            else { throw NativeDBError.message("この処理はメールの結果確認対象ではありません。") }
            guard current == expected else { throw NativeDBError.conflict }
            guard current.canReviewMail else { throw NativeDBError.message("このメールは結果確認で終了できません。実行中の処理は完了を待ってください。") }
            if let known = current.result["providerID"] {
                guard receipt == known.lowercased() else { throw NativeDBError.message("保存済みの受付IDと矛盾する結果は記録できません。") }
            }
            var result = current.result
            result["reviewOutcome"] = outcome.rawValue; result["reviewedBy"] = identity.id
            if let reviewer = try db.get("Users",key:["id":.text(identity.id)]) { result["reviewerName"] = reviewer["name"].string }
            result["reviewedAt"] = ISO8601DateFormatter().string(from:now); result["reviewNote"] = memo
            result["reviewPreviousStatus"] = current.status
            if let error = current.lastError { result["reviewPreviousError"] = error }
            if let receipt { result["providerID"] = receipt; result["outcome"] = "sent" }
            else { result["outcome"] = outcome == .notSent ? "not_sent" : "unconfirmed" }
            if current.event == "invoice.email_requested", let id = current.payload["invoiceId"], var invoice = try db.get("Invoices",key:["id":.text(id)]) {
                let issued = invoice["status"] == .text("ISSUED")
                if outcome == .accepted && issued { invoice = try db.update(invoice,changes:["status":.text("SENT")],actor:identity.id,action:"invoice_email_review") }
                var metadata = ["jobID":current.id,"outcome":outcome.rawValue,"note":memo,"originalActor":current.payload["actorId"] ?? ""]
                if let receipt { metadata["providerID"] = receipt }
                let json = String(decoding:try JSONEncoder().encode(metadata),as:UTF8.self)
                _ = try db.insert("Invoice_Activity",values:["invoiceId":invoice["id"],"actorId":.text(identity.id),"action":.text("EMAIL_REVIEWED"),"meta":.text(json)],actor:identity.id)
            }
            try db.completeReviewedMail(current,result:result,now:now)
            if current.event == "reports.scheduled",receipt != nil {
                let accepted=current.result["acceptedAt"].flatMap{ISO8601DateFormatter().date(from:$0)} ?? now
                try db.acknowledgeReportDelivery(current,acceptedAt:accepted)
            }
            // Retain the decision/digest in the DB and preserve retry bytes if
            // an enclosing transaction rolls this review back.
            try db.deferTerminalMailBodyCleanup(id:expected.id)
        }
        NotificationCenter.default.post(name:NativeDatabase.jobsDidChange,object:db,userInfo:["database":db.url.path])
    }
}
