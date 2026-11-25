import Foundation
import SQLite3
import Darwin

enum SQLValue: Equatable {
    case null, text(String), integer(Int64), real(Double), blob(Data)
    var string: String {
        switch self { case .null: return ""; case let .text(v): return v; case let .integer(v): return String(v)
        case let .real(v): return String(v); case let .blob(v): return v.base64EncodedString() }
    }
    var json: Any {
        switch self { case .null: return NSNull(); case let .text(v): return v; case let .integer(v): return v
        case let .real(v): return v; case let .blob(v): return ["base64": v.base64EncodedString()] }
    }
}

struct NativeJob: Equatable {
    let id: String; let event: String; let payload: [String:String]; let status: String; let attempts: Int
    let createdAt: String; let nextRunAt: String?; let lastError: String?; let leaseToken: String?
    let firstAttemptAt: Date?; let deliveryStartedAt: Date?; let result: [String:String]
}

extension NativeDatabase {
    func calendarOutboundMapping(activityID: String) throws -> NativeRecord? {
        try synchronized {
            guard let id = try query("SELECT id FROM crm_CalendarEvents WHERE activityId=? ORDER BY CASE WHEN source='calendly' THEN 0 ELSE 1 END,julianday(createdAt) DESC,id DESC LIMIT 1",[.text(activityID)]).first?["id"] else { return nil }
            return try get("crm_CalendarEvents",key:["id":id])
        }
    }
    func calendarOutboundConnection(ownerID: String,preferredID: String?) throws -> NativeRecord? {
        try synchronized {
            if let preferredID, let row = try get("CalendarConnection",key:["id":.text(preferredID)]), row["userId"] == .text(ownerID), row["provider"] == .text("google"), row["isActive"] == .integer(1), row["scopeLevel"] == .text("readwrite") { return row }
            guard let id = try query("SELECT id FROM CalendarConnection WHERE userId=? AND provider='google' AND isActive=1 AND scopeLevel='readwrite' ORDER BY julianday(createdAt) ASC,id ASC LIMIT 1",[.text(ownerID)]).first?["id"] else { return nil }
            return try get("CalendarConnection",key:["id":id])
        }
    }
    private var calendarOutboundEligible: String {
        "j.event='calendar/outbound' AND \(restoredJobEligible("j.id")) AND NOT (\(personalCalendarHoldForJobSQL("j"))) AND NOT EXISTS(SELECT 1 FROM native_outbox blocked WHERE blocked.event='calendar/outbound' AND blocked.id<>j.id AND json_extract(blocked.payload,'$.activity_id')=json_extract(j.payload,'$.activity_id') AND (blocked.status='needs_review' OR (blocked.status IN ('pending','retry','running') AND (blocked.created_at<j.created_at OR (blocked.created_at=j.created_at AND blocked.rowid<j.rowid)))))"
    }
    /// Serialize external writes across app processes. A review hold blocks only
    /// its own activity; unrelated meetings may still progress.
    func claimCalendarOutboundJob(now: Date = Date()) throws -> NativeJob? { try requireWritable();
        return try transaction {
            try requireRestoredJobQuarantineFence()
            guard try query("SELECT id FROM native_outbox WHERE event='calendar/outbound' AND \(restoredJobEligible("id")) AND status='running' AND lease_until>? LIMIT 1",[.real(now.timeIntervalSince1970)]).isEmpty else { return nil }
            let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
            guard let row = try query("SELECT j.* FROM native_outbox j WHERE \(calendarOutboundEligible) AND ((j.status IN ('pending','retry') AND (j.next_run_at IS NULL OR julianday(j.next_run_at)<=julianday(?))) OR (j.status='running' AND (j.lease_until IS NULL OR j.lease_until<=?))) ORDER BY j.created_at,j.rowid LIMIT 1",[.text(formatter.string(from:now)),.real(now.timeIntervalSince1970)]).first else { return nil }
            let id = row["id"]!, token = UUID().uuidString.lowercased()
            try run("UPDATE native_outbox SET status='running',attempts=attempts+1,lease_token=?,lease_until=?,first_attempt_at=COALESCE(first_attempt_at,?),next_run_at=NULL WHERE id=?",[.text(token),.real(now.timeIntervalSince1970+300),.real(now.timeIntervalSince1970),id]); return try job(id:id.string)
        }
    }
    func nextCalendarOutboundJobDate(now: Date = Date()) throws -> Date? {
        try synchronized {
            try requireRestoredJobQuarantineFence()
            if let value = try query("SELECT MIN(lease_until) due FROM native_outbox WHERE event='calendar/outbound' AND \(restoredJobEligible("id")) AND status='running' AND lease_until>?",[.real(now.timeIntervalSince1970)]).first?["due"], let epoch = Double(value.string) { return Date(timeIntervalSince1970:epoch) }
            let sql = "SELECT MIN(CASE WHEN j.status='running' THEN COALESCE(j.lease_until,?) WHEN j.next_run_at IS NULL THEN ? ELSE COALESCE((julianday(j.next_run_at)-2440587.5)*86400,?) END) due FROM native_outbox j WHERE \(calendarOutboundEligible) AND j.status IN ('pending','retry','running')"
            guard let value = try query(sql,Array(repeating:.real(now.timeIntervalSince1970),count:3)).first?["due"], let epoch = Double(value.string) else { return nil }; return Date(timeIntervalSince1970:epoch)
        }
    }
    func retryCalendarOutboundJob(_ expected: NativeJob) throws { try requireWritable();
        try transaction {
            guard let current = try job(id:expected.id), current == expected, current.event == "calendar/outbound", ["failed","retry","needs_review"].contains(current.status) else { throw NativeDBError.conflict }
            // Stable provider IDs and operation markers allow recovery even
            // after the email provider's unrelated 23-hour retry window.
            try run("UPDATE native_outbox SET status='pending',next_run_at=NULL,last_error=NULL WHERE id=?",[.text(current.id)])
        }
        notifyJobChange()
    }
    func calendarOutboundJobs(ownerID: String,offset: Int = 0) throws -> (rows:[(job:NativeJob,title:String)],total:Int) {
        try synchronized {
            let from = " FROM native_outbox j JOIN crm_Activities a ON a.id=json_extract(j.payload,'$.activity_id') WHERE j.event='calendar/outbound' AND a.createdBy=?"
            let count = try query("SELECT COUNT(*) count"+from,[.text(ownerID)]).first?["count"]?.string ?? "0"
            let summary = "json_object('pushed',COALESCE(json_extract(j.result,'$.pushed'),''),'did',COALESCE(json_extract(j.result,'$.did'),''),'reason',COALESCE(json_extract(j.result,'$.reason'),''),'requestOutcome',COALESCE(json_extract(j.result,'$.requestOutcome'),'')) AS result"
            let rows = try query("SELECT j.id,j.event,j.payload,j.status,j.attempts,j.created_at,j.next_run_at,j.last_error,j.lease_token,j.first_attempt_at,j.delivery_started_at,"+summary+",a.title AS activity_title"+from+" ORDER BY j.created_at DESC,j.rowid DESC LIMIT 100 OFFSET ?",[.text(ownerID),.integer(Int64(max(0,offset)))])
            return (try rows.map{(try job($0),$0["activity_title"]?.string ?? "")},Int(count) ?? 0)
        }
    }
    func reviewCalendarOutboundNotApplied(_ expected: NativeJob,actor: String,note: String,now: Date = Date()) throws -> String { try requireWritable();
        guard let next=try reviewCalendarNotApplied(expected,actor:actor,note:note,now:now,followUp:true) else{throw NativeDBError.conflict};return next
    }
    private func reviewCalendarNotApplied(_ expected:NativeJob,actor:String,note:String,now:Date,followUp:Bool)throws->String? {
        return try transaction {
            guard let current = try job(id:expected.id), current == expected, current.event == "calendar/outbound", ["failed","retry","needs_review"].contains(current.status), ["unknown","rejected"].contains(current.result["requestOutcome"] ?? ""), let activity = current.payload["activity_id"] else { throw NativeDBError.conflict }
            let next = followUp ? try enqueue("calendar/outbound",payload:["activity_id":activity,"operation":"upsert","reviewed_job":current.id],now:now):nil
            var result = current.result; result["requestOutcome"] = "reviewedNotApplied"; result["pushed"] = "false"; result["reason"] = "manually-not-applied"; result["reviewedBy"] = actor; result["reviewNote"] = note; result["reviewedAt"] = ISO8601DateFormatter().string(from:now); result["followUpJob"] = next
            let json = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET status='done',result=?,completed_at=?,next_run_at=NULL,last_error=NULL,lease_token=NULL,lease_until=NULL WHERE id=?",[.text(json),.text(ISO8601DateFormatter().string(from:now)),.text(current.id)])
            return next
        }
    }
    static let jobsDidChange = Notification.Name("NextCRMNativeJobsDidChange")
    static let aiProgress = Notification.Name("NextCRMNativeAIProgress")
    func notifyAIProgress(cancelledJob: String? = nil) {
        let path = url.path
        DispatchQueue.main.async {
            var info: [String: Any] = ["database": path]
            if let cancelledJob { info["cancelledJob"] = cancelledJob }
            NotificationCenter.default.post(name: Self.aiProgress, object: nil, userInfo: info)
        }
    }
    private func notifyJobChange() {
        let path = url.path
        DispatchQueue.main.async { NotificationCenter.default.post(name:Self.jobsDidChange,object:nil,userInfo:["database":path]) }
    }
    private func job(_ row: [String:SQLValue]) throws -> NativeJob {
        func optional(_ key: String) -> String? { guard let value = row[key], value != .null else { return nil }; return value.string }
        func date(_ key: String) -> Date? { optional(key).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) }
        func json(_ key: String) -> [String:String] { guard let value = optional(key) else { return [:] }; return (try? JSONDecoder().decode([String:String].self,from:Data(value.utf8))) ?? [:] }
        return NativeJob(id:row["id"]!.string,event:row["event"]!.string,payload:json("payload"),status:row["status"]!.string,attempts:Int(row["attempts"]!.string) ?? 0,createdAt:row["created_at"]!.string,nextRunAt:optional("next_run_at"),lastError:optional("last_error"),leaseToken:optional("lease_token"),firstAttemptAt:date("first_attempt_at"),deliveryStartedAt:date("delivery_started_at"),result:json("result"))
    }
    func job(id: String) throws -> NativeJob? { try synchronized { try query("SELECT * FROM native_outbox WHERE id=?",[.text(id)]).first.map(job) } }
    func jobs(events: [String], invoiceID: String? = nil, orderID: String? = nil, taskID: String? = nil, boardID: String? = nil, recipientID: String? = nil, campaignID: String? = nil, leadID: String? = nil, offset: Int = 0) throws -> [NativeJob] {
        guard !events.isEmpty else { return [] }
        var filter = ""; var values = events.map(SQLValue.text)
        for (field,value) in [("invoiceId",invoiceID),("orderId",orderID),("taskId",taskID),("boardId",boardID),("recipientId",recipientID),("campaignId",campaignID),("leadId",leadID)] {
            if let value { filter += " AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.\(field)') END=?"; values.append(.text(value)) }
        }
        return try synchronized { try query("SELECT * FROM native_outbox WHERE event IN (\(events.map { _ in "?" }.joined(separator:",")))\(filter) ORDER BY created_at DESC,rowid DESC LIMIT 100 OFFSET ?",values+[.integer(Int64(max(0,offset)))]).map(job) }
    }
    func campaignJobCount(_ id: String, events: [String]) throws -> Int {
        guard !events.isEmpty else { return 0 }
        return try synchronized {
            let row = try query("SELECT COUNT(*) n FROM native_outbox WHERE CASE WHEN json_valid(payload) THEN json_extract(payload,'$.campaignId') END=? AND event IN (\(events.map{_ in "?"}.joined(separator:",")))",[.text(id)]+events.map(SQLValue.text)).first
            return Int(row?["n"]?.string ?? "0") ?? 0
        }
    }
    func aiJobs(events: [String], actorID: String, offset: Int = 0) throws -> (rows: [NativeJob], total: Int) {
        guard !events.isEmpty else { return ([], 0) }
        return try synchronized {
            let condition = "event IN (\(events.map { _ in "?" }.joined(separator: ","))) AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.actorID') END=?"
            let values = events.map(SQLValue.text) + [.text(actorID)]
            let total = Int(try query("SELECT COUNT(*) n FROM native_outbox WHERE \(condition)", values).first?["n"]?.string ?? "0") ?? 0
            let rows = try query("SELECT * FROM native_outbox WHERE \(condition) ORDER BY created_at DESC,rowid DESC LIMIT 100 OFFSET ?", values + [.integer(Int64(max(0, offset)))]).map(job)
            return (rows, total)
        }
    }
    func retryAIJob(_ expected: NativeJob, events: [String]) throws { try requireWritable();
        try transaction {
            guard events.contains(expected.event), let current = try job(id: expected.id), current == expected,
                  ["failed", "retry"].contains(current.status), current.deliveryStartedAt == nil else { throw NativeDBError.conflict }
            try run("UPDATE native_outbox SET status='pending',attempts=0,next_run_at=NULL,last_error=NULL WHERE id=?", [.text(current.id)])
        }; notifyJobChange()
    }
    func cancelAIJob(_ expected: NativeJob, events: [String]) throws { try requireWritable();
        try transaction {
            guard events.contains(expected.event), let current = try job(id: expected.id), current == expected,
                  current.deliveryStartedAt == nil,
                  ["pending", "retry", "failed"].contains(current.status) || ([Self.documentAIEvent, "enrich/contact.run", "enrich/target.run", "enrich/target.contact.run"].contains(current.event) && current.status == "running") else { throw NativeDBError.conflict }
            var result = current.result; result["outcome"] = "cancelled"
            let json = String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)
            try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL,lease_token=NULL,lease_until=NULL,last_error=NULL,result=? WHERE id=?", [.text(json), .text(current.id)])
        }
        notifyJobChange(); notifyAIProgress(cancelledJob: expected.id)
    }
    /// Only the earliest due time crosses the SQL boundary, not the job backlog.
    func nextJobDate(events: [String], now: Date = Date()) throws -> Date? {
        guard !events.isEmpty else { return nil }
        return try synchronized {
            try requireRestoredJobQuarantineFence()
            let sql = "SELECT MIN(CASE WHEN status='running' THEN COALESCE(lease_until,?) WHEN next_run_at IS NULL THEN ? ELSE COALESCE((julianday(next_run_at)-2440587.5)*86400,?) END) AS due FROM native_outbox WHERE \(restoredJobEligible("id")) AND status IN ('pending','retry','running') AND event IN (\(events.map { _ in "?" }.joined(separator:",")))"
            let row = try query(sql,Array(repeating:SQLValue.real(now.timeIntervalSince1970),count:3)+events.map(SQLValue.text)).first
            guard let value = row?["due"], value != .null, let epoch = Double(value.string) else { return nil }
            return Date(timeIntervalSince1970:epoch)
        }
    }
    /// BEGIN IMMEDIATE serializes claims across separate app processes. A new
    /// token fences an abandoned attempt after its lease has been reclaimed.
    func claimJob(events: [String], now: Date = Date(), leaseSeconds: TimeInterval = 300) throws -> NativeJob? { try requireWritable();
        guard !events.isEmpty, leaseSeconds > 0, leaseSeconds <= 3600 else { return nil }
        return try transaction {
            try requireRestoredJobQuarantineFence()
            let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
            let stamp = formatter.string(from:now)
            let placeholders = events.map { _ in "?" }.joined(separator:",")
            guard let row = try query("SELECT * FROM native_outbox WHERE \(restoredJobEligible("id")) AND event IN (\(placeholders)) AND ((status IN ('pending','retry') AND (next_run_at IS NULL OR COALESCE(julianday(next_run_at),0)<=julianday(?))) OR (status='running' AND (lease_until IS NULL OR lease_until<=?))) ORDER BY created_at,rowid LIMIT 1",events.map(SQLValue.text)+[.text(stamp),.real(now.timeIntervalSince1970)]).first else { return nil }
            let id = row["id"]!; let token = UUID().uuidString.lowercased()
            try run("UPDATE native_outbox SET status='running',attempts=attempts+1,lease_token=?,lease_until=?,first_attempt_at=COALESCE(first_attempt_at,?),next_run_at=NULL WHERE id=?",[.text(token),.real(now.timeIntervalSince1970+leaseSeconds),.real(now.timeIntervalSince1970),id])
            return try job(id:id.string)
        }
    }
    func requireJobLease(_ expected: NativeJob) throws -> NativeJob {
        try requireRestoredJobQuarantineFence()
        guard try metadata(Self.restoredJobQuarantinePrefix+expected.id)==nil else {throw NativeDBError.message("復元前の処理は確認待ちのため実行しません。")}
        guard let current = try job(id:expected.id), current.status == "running", let token = expected.leaseToken, current.leaseToken == token else { throw NativeDBError.conflict }
        return current
    }
    func renewJobLease(_ expected: NativeJob, now: Date = Date(), seconds: TimeInterval = 300) throws { try requireWritable();
        try transaction {
            _ = try requireJobLease(expected)
            guard seconds > 0 && seconds <= 3600 else { throw NativeDBError.message("処理の有効期間が不正です。") }
            try run("UPDATE native_outbox SET lease_until=? WHERE id=?",[.real(now.timeIntervalSince1970+seconds),.text(expected.id)])
        }
    }
    /// Persist the start before any external request. Retries use the same job
    /// ID/body; a crash after sending cannot reset the provider's dedupe clock.
    func markJobDeliveryStarted(_ expected: NativeJob, now: Date = Date()) throws -> NativeJob { try requireWritable();
        return try transaction {
            _ = try requireJobLease(expected)
            try run("UPDATE native_outbox SET delivery_started_at=COALESCE(delivery_started_at,?) WHERE id=?",[.real(now.timeIntervalSince1970),.text(expected.id)])
            return try job(id:expected.id)!
        }
    }
    func finishJob(_ expected: NativeJob, result: [String:String] = [:], now: Date = Date()) throws { try requireWritable();
        try transaction {
            _ = try requireJobLease(expected)
            let json = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET status='done',result=?,completed_at=?,lease_token=NULL,lease_until=NULL,last_error=NULL,next_run_at=NULL WHERE id=?",[.text(json),.text(ISO8601DateFormatter().string(from:now)),.text(expected.id)])
        }
    }
    /// Preserve an external acceptance before applying the domain transition.
    /// Recovery can finish locally even after the provider's dedupe period ends.
    func recordJobResult(_ expected: NativeJob, result: [String:String]) throws { try requireWritable();
        try transaction {
            _ = try requireJobLease(expected)
            let json = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET result=? WHERE id=?",[.text(json),.text(expected.id)])
        }
    }
    func failJob(_ expected: NativeJob, message: String, retryAt: Date? = nil, needsReview: Bool = false) throws { try requireWritable();
        try transaction {
            _ = try requireJobLease(expected)
            let next = retryAt.map { SQLValue.text(ISO8601DateFormatter().string(from:$0)) } ?? .null
            try run("UPDATE native_outbox SET status=?,last_error=?,next_run_at=?,lease_token=NULL,lease_until=NULL WHERE id=?",[.text(needsReview ? "needs_review" : retryAt == nil ? "failed" : "retry"),.text(String(message.prefix(2000))),next,.text(expected.id)])
        }
    }
    func retryJob(id: String, now: Date = Date()) throws { try requireWritable();
        try transaction {
            guard let current = try job(id:id), ["failed","retry"].contains(current.status) else { throw NativeDBError.message("この処理は再試行できません。") }
            if let start = current.deliveryStartedAt, current.result["providerID"] == nil, now < start || now.timeIntervalSince(start) >= 23*3600 { throw NativeDBError.message("送信結果を確認してから操作してください。重複送信の防止期間を超えています。") }
            try run("UPDATE native_outbox SET status='pending',next_run_at=NULL,last_error=NULL WHERE id=?",[.text(id)])
        }
        notifyJobChange()
    }
    func cancelJob(id: String, result: [String:String]? = nil) throws { try requireWritable();
        try transaction {
            guard let current = try job(id:id), ["pending","retry","failed"].contains(current.status), current.deliveryStartedAt == nil else { throw NativeDBError.message("送信中、または送信結果を確認する必要があるため取り消せません。") }
            try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL WHERE id=?",[.text(id)])
            if let result {
                try run("UPDATE native_outbox SET result=? WHERE id=?",[.text(String(decoding:try JSONEncoder().encode(result),as:UTF8.self)),.text(id)])
            }
        }
        notifyJobChange()
    }
    /// A terminal manual decision is fenced against the exact row the reviewer
    /// saw, just as automatic completion is fenced against its lease token.
    func completeReviewedMail(_ expected: NativeJob, result: [String:String], now: Date) throws { try requireWritable();
        try transaction {
            guard let current = try job(id:expected.id), current == expected else { throw NativeDBError.conflict }
            let campaignReview = current.event == "campaigns/send-step" && current.status == "needs_review"
            guard ["invoice.email_requested","orders.approval_requested","orders.approval_decided","projects.task_assigned","projects.task_updated","projects.task_commented","crm.task_assigned","crm.task_watched","crm.lead_assigned","campaigns/send-step","reports.scheduled","crm.automation.kill.notice","crm.automation.recycle.notice"].contains(current.event),
                  ["needs_review","failed","retry"].contains(current.status), current.deliveryStartedAt != nil || campaignReview else { throw NativeDBError.message("この処理は結果確認で終了できません。") }
            if let receipt = result["providerID"] {
                let reused = try query("SELECT id FROM native_outbox WHERE id<>? AND CASE WHEN json_valid(result) THEN lower(json_extract(result,'$.providerID')) END=? LIMIT 1",[.text(current.id),.text(receipt.lowercased())])
                guard reused.isEmpty else { throw NativeDBError.message("その受付IDは別のメールに記録されています。対象のメールを確認してください。") }
            }
            let encoded = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET status='done',result=?,completed_at=?,last_error=NULL,next_run_at=NULL,lease_token=NULL,lease_until=NULL WHERE id=?",[.text(encoded),.text(ISO8601DateFormatter().string(from:now)),.text(current.id)])
        }
    }
}

struct NativeSchema: Decodable {
    struct Field: Decodable {
        let name: String; let column: String; let type: String; let optional: Bool; let array: Bool
        let attributes: String; let defaultExpression: String?
    }
    struct Model: Decodable {
        let name: String; let fields: [Field]; let primaryKey: [String]
        func field(_ name: String) -> Field? { fields.first { $0.name == name } }
    }
    let formatVersion: Int; let schemaSHA256: String; let models: [Model]; let enums: [String: [String]]
    func model(_ name: String) throws -> Model {
        guard let result = models.first(where: { $0.name == name }) else { throw NativeDBError.message("保存先が見つかりません：\(name)") }
        return result
    }
}

enum NativeDBError: LocalizedError {
    case message(String), conflict
    var errorDescription: String? {
        switch self { case let .message(value): return value
        case .conflict: return "別の操作で更新されています。最新の内容を開き直してください。" }
    }
}

struct NativeRecord {
    let model: String
    let values: [String: SQLValue]
    let revision: Int64
    subscript(_ field: String) -> SQLValue { values[field] ?? .null }
}

indirect enum RecordFilter {
    case all, none, equal(String, SQLValue), not(RecordFilter), any([RecordFilter]), every([RecordFilter])
    case arrayContains(String, String), beforeDate(String, String)
    case compareDate(String, NativeDateComparison, String)
    case relation(model: String, local: String, foreign: String, matching: RecordFilter)
    case scalar(String, String, [SQLValue], Bool)
}

/// Import/restore code must opt out explicitly; regular UI/API/worker writes
/// use the same database hooks. This type has no plugin module dependency.
enum NativeRecordMutationScope {
    @TaskLocal static var bypassHooks = false
}

enum NativeDateComparison: String { case less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">=" }

/// Literal Unicode case-insensitive matching without copying a complete stored
/// description/body into Swift. KMP retains only the query and its failure table.
private final class NativeTextNeedle {
    let pattern: [UInt32], failure: [Int]
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static func folded(_ scalar: Unicode.Scalar, visit: (UInt32) -> Bool) -> Bool {
        if scalar.value < 128 { return visit((65...90).contains(scalar.value) ? scalar.value + 32 : scalar.value) }
        if !scalar.properties.isCased { return visit(scalar.value) }
        for value in String(scalar).folding(options: .caseInsensitive, locale: locale).unicodeScalars {
            if visit(value.value) { return true }
        }
        return false
    }
    init(_ text: String) {
        var values: [UInt32] = []
        for scalar in text.unicodeScalars { _ = Self.folded(scalar) { values.append($0); return false } }
        pattern = values
        var back = [Int](repeating: 0, count: values.count), matched = 0
        if values.count > 1 {
            for i in 1..<values.count {
                while matched > 0 && values[i] != values[matched] { matched = back[matched - 1] }
                if values[i] == values[matched] { matched += 1 }; back[i] = matched
            }
        }
        failure = back
    }
    func contains<I: IteratorProtocol>(_ input: inout I) -> Bool where I.Element == UInt8 {
        if pattern.isEmpty { return true }
        var parser = Unicode.UTF8(), matched = 0, scanned = 0
        while true {
            if scanned % 4096 == 0 && Task.isCancelled { return false }; scanned += 1
            let scalar: Unicode.Scalar
            switch parser.decode(&input) {
            case .emptyInput: return false
            case .error: scalar = "\u{fffd}"
            case let .scalarValue(value): scalar = value
            }
            if Self.folded(scalar, visit: { value in
                while matched > 0 && value != pattern[matched] { matched = failure[matched - 1] }
                if value == pattern[matched] { matched += 1 }
                return matched == pattern.count
            }) { return true }
        }
    }
}

/// SQLite incremental I/O also supports TEXT. Keeping only 16 KiB here avoids
/// materializing the complete field inside SQLite or Foundation while scanning.
private struct NativeSQLiteTextIterator: IteratorProtocol {
    let blob: OpaquePointer, buffer: UnsafeMutablePointer<UInt8>, size: Int32
    var offset: Int32 = 0, available = 0, cursor = 0, status: Int32 = SQLITE_OK
    mutating func next() -> UInt8? {
        if cursor == available {
            guard offset < size, status == SQLITE_OK else { return nil }
            let count = min(Int32(16_384), size - offset)
            status = sqlite3_blob_read(blob, buffer, count, offset)
            guard status == SQLITE_OK else { return nil }
            offset += count; available = Int(count); cursor = 0
        }
        defer { cursor += 1 }; return buffer[cursor]
    }
}

struct RecordRelationSort {
    let model: String; let local: String; let foreign: String; let field: String
}

/// SQLite keeps Decimal columns as text. Compare the digits directly, without
/// Double rounding or an array of decoded records (including beyond 38 digits).
enum NativeDecimalOrder {
    static func compare(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int32 {
        func parts(_ bytes: UnsafeRawBufferPointer) -> (negative: Bool, whole: Range<Int>, fraction: Range<Int>)? {
            guard !bytes.isEmpty else { return nil }
            let negative = bytes[0] == 45; let start = negative ? 1 : 0
            guard start < bytes.count else { return nil }
            var point = bytes.count
            for i in start..<bytes.count {
                if bytes[i] == 46 { guard point == bytes.count, i > start, i < bytes.count-1 else { return nil }; point = i }
                else if !(48...57).contains(bytes[i]) { return nil }
            }
            var first = start; while first < point && bytes[first] == 48 { first += 1 }
            let fractionalStart = min(point+1,bytes.count)
            var end = bytes.count; while end > fractionalStart && bytes[end-1] == 48 { end -= 1 }
            return (negative && (first < point || end > fractionalStart),first..<point,fractionalStart..<end)
        }
        let ap = parts(a); let bp = parts(b)
        guard let x = ap, let y = bp else {
            if ap != nil { return -1 }; if bp != nil { return 1 }
            for i in 0..<min(a.count,b.count) where a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            return a.count == b.count ? 0 : a.count < b.count ? -1 : 1
        }
        if x.negative != y.negative { return x.negative ? -1 : 1 }
        let sign: Int32 = x.negative ? -1 : 1
        if x.whole.count != y.whole.count { return (x.whole.count < y.whole.count ? -1 : 1) * sign }
        for i in 0..<x.whole.count {
            let l = a[x.whole.lowerBound+i]; let r = b[y.whole.lowerBound+i]
            if l != r { return (l < r ? -1 : 1) * sign }
        }
        for i in 0..<max(x.fraction.count,y.fraction.count) {
            let l: UInt8 = i < x.fraction.count ? a[x.fraction.lowerBound+i] : 48
            let r: UInt8 = i < y.fraction.count ? b[y.fraction.lowerBound+i] : 48
            if l != r { return (l < r ? -1 : 1) * sign }
        }
        return 0
    }
}

/// Typed SQLite tables mirror all source scalar fields and explicit relationships.
/// Access is serialized across complete operations, including nested transactions.
/// UI/domain layers own business rules; this class enforces storage integrity.
final class NativeDatabase {
    /// Metadata only: no strong DB ownership and no query buffer retention.
    /// Restore reports these real, process-local SQLite connections before exit.
    struct LiveConnection:Codable,Equatable {
        let id:String,path:String,readOnly:Bool
    }
    private static let connectionsLock=NSLock()
    private static var connections:[String:LiveConnection]=[:]
    private let connectionIdentity=UUID().uuidString.lowercased()
    private func registerLiveConnection() {
        let row=LiveConnection(id:connectionIdentity,path:url.resolvingSymlinksInPath().standardizedFileURL.path,readOnly:isReadOnly)
        Self.connectionsLock.lock();defer{Self.connectionsLock.unlock()}
        Self.connections[connectionIdentity]=row
    }
    static func liveConnections()->[LiveConnection] {
        connectionsLock.lock();defer{connectionsLock.unlock()}
        return connections.values.sorted{$0.id<$1.id}
    }

    let schema: NativeSchema
    let url: URL
    let isReadOnly: Bool
    private var connection: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    private var restoredJobQuarantineFence:(marker:String,authorize:()throws->Void)?
    var beforeRecordWrite: ((String,String,NativeRecord?,[String:SQLValue],String) throws -> [String:SQLValue])?
    var afterRecordWrite: ((String,String,NativeRecord?,NativeRecord?,[String:SQLValue],String) -> Void)?
    private struct TransactionCompletion { let commit:()->Void;let rollback:()->Void;var rolledBack=false }
    private var transactionCompletions: [[TransactionCompletion]] = []
    private var mcpLowerRegistered = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let locale = Locale(identifier: "en_US_POSIX")

    init(url: URL, schemaURL: URL, sqlURL: URL) throws {
        self.url = url
        isReadOnly = false
        schema = try JSONDecoder().decode(NativeSchema.self, from: Data(contentsOf: schemaURL))
        guard schema.formatVersion == 1 else { throw NativeDBError.message("未対応のデータ形式です。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = error; if let connection { sqlite3_close(connection) }; connection = nil
            throw NativeDBError.message(message)
        }
        do {
            try registerCollations()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(connection, 5000)
            try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;")
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS native_metadata(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL)")
                let existing = try query("SELECT value FROM native_metadata WHERE key='schemaSHA256'").first?["value"]?.string
                if let existing, existing != schema.schemaSHA256 {
                    throw NativeDBError.message("データ構造の移行が必要です。既存データは変更していません。")
                }
                if existing == nil {
                    try execute(String(contentsOf: sqlURL, encoding: .utf8))
                    try execute("CREATE TABLE native_audit(id TEXT PRIMARY KEY,model TEXT NOT NULL,record_key TEXT NOT NULL,action TEXT NOT NULL,actor TEXT NOT NULL,created_at TEXT NOT NULL,before_json TEXT,after_json TEXT); CREATE INDEX native_audit_record ON native_audit(model,record_key,created_at,id);")
                    try run("INSERT INTO native_metadata VALUES('schemaSHA256',?)", [.text(schema.schemaSHA256)])
                    try execute("PRAGMA user_version=1")
                }
                if try metadata("mail.headerSearch.version") != "1" {
                    var after = ""
                    while true {
                        let rows = try query("SELECT id,subject,fromName,fromEmail FROM Email WHERE id>? ORDER BY id LIMIT 100",[.text(after)])
                        for row in rows { try run("UPDATE Email SET _native_search=? WHERE id=?",[.text(searchKey(row,model:"Email")),row["id"]!]) }
                        if rows.count < 100 { break }; after = rows.last!["id"]!.string
                    }
                    try setMetadata("mail.headerSearch.version",value:"1")
                }
                try execute("CREATE TABLE IF NOT EXISTS native_legacy_accounts(id TEXT PRIMARY KEY NOT NULL,original_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS native_outbox(id TEXT PRIMARY KEY NOT NULL,event TEXT NOT NULL,payload TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,next_run_at TEXT,last_error TEXT);")
                let jobColumns = Set(try query("PRAGMA table_info(native_outbox)").compactMap { $0["name"]?.string })
                for (column,type) in [("lease_token","TEXT"),("lease_until","REAL"),("first_attempt_at","REAL"),("delivery_started_at","REAL"),("completed_at","TEXT"),("result","TEXT")] where !jobColumns.contains(column) {
                    try execute("ALTER TABLE native_outbox ADD COLUMN \(column) \(type)")
                }
                try execute("CREATE INDEX IF NOT EXISTS native_outbox_ready ON native_outbox(event,status,next_run_at,created_at)")
                try execute("CREATE INDEX IF NOT EXISTS native_outbox_campaign ON native_outbox(CASE WHEN json_valid(payload) THEN json_extract(payload,'$.campaignId') END,event,created_at DESC)")
                try execute("""
                CREATE TABLE IF NOT EXISTS native_ai_key_cleanup(
                  credential_id TEXT PRIMARY KEY NOT NULL,not_before REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS native_document_objects(
                  bucket TEXT NOT NULL,object_key TEXT NOT NULL,file_key TEXT NOT NULL,
                  content_type TEXT NOT NULL,bytes INTEGER NOT NULL CHECK(bytes>=0),sha256 TEXT NOT NULL,
                  revision INTEGER NOT NULL DEFAULT 1,updated_at TEXT NOT NULL,
                  PRIMARY KEY(bucket,object_key));
                CREATE INDEX IF NOT EXISTS native_document_objects_file ON native_document_objects(file_key);
                CREATE TABLE IF NOT EXISTS native_document_processing(
                  document_id TEXT PRIMARY KEY NOT NULL REFERENCES Documents(id) ON DELETE CASCADE,
                  job_id TEXT NOT NULL,file_key TEXT NOT NULL,content_hash TEXT NOT NULL,
                  text_bytes INTEGER NOT NULL DEFAULT 0,text_parts INTEGER NOT NULL DEFAULT 0,
                  has_result INTEGER NOT NULL DEFAULT 0,thumbnail BLOB,note TEXT NOT NULL DEFAULT '');
                CREATE TABLE IF NOT EXISTS native_document_text(
                  document_id TEXT NOT NULL REFERENCES native_document_processing(document_id) ON DELETE CASCADE,
                  part INTEGER NOT NULL,content TEXT NOT NULL,PRIMARY KEY(document_id,part));
                CREATE TABLE IF NOT EXISTS native_document_ai_work(
                  document_id TEXT PRIMARY KEY NOT NULL REFERENCES Documents(id) ON DELETE CASCADE,
                  job_id TEXT UNIQUE NOT NULL REFERENCES native_outbox(id) ON DELETE CASCADE);
                CREATE TABLE IF NOT EXISTS native_document_ai_chunks(
                  job_id TEXT NOT NULL REFERENCES native_document_ai_work(job_id) ON DELETE CASCADE,
                  chunk_index INTEGER NOT NULL,chunk_text TEXT NOT NULL,embedding BLOB NOT NULL,
                  PRIMARY KEY(job_id,chunk_index));
                CREATE TABLE IF NOT EXISTS native_campaign_audience(
                  job_id TEXT NOT NULL REFERENCES native_outbox(id) ON DELETE CASCADE,
                  target_id TEXT NOT NULL REFERENCES crm_Targets(id),email TEXT NOT NULL,
                  PRIMARY KEY(job_id,target_id),UNIQUE(job_id,email));
                CREATE TABLE IF NOT EXISTS native_campaign_mail_intents(
                  send_id TEXT PRIMARY KEY NOT NULL REFERENCES crm_campaign_sends(id) ON DELETE CASCADE,
                  run_token TEXT NOT NULL,actor_id TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS native_mail_sends(
                  job_id TEXT PRIMARY KEY NOT NULL REFERENCES native_outbox(id) ON DELETE CASCADE,
                  account_id TEXT NOT NULL REFERENCES EmailAccount(id) ON DELETE CASCADE,
                  actor_id TEXT NOT NULL,message_id TEXT NOT NULL,summary TEXT NOT NULL,mime BLOB,
                  UNIQUE(account_id,message_id));
                CREATE INDEX IF NOT EXISTS native_mail_sends_owner ON native_mail_sends(account_id,actor_id,job_id);
                CREATE TABLE IF NOT EXISTS native_campaign_events(
                  event_id TEXT PRIMARY KEY NOT NULL,provider_id TEXT NOT NULL,kind TEXT NOT NULL,
                  body_sha256 TEXT NOT NULL,received_at TEXT NOT NULL,processed_at TEXT);
                CREATE INDEX IF NOT EXISTS native_campaign_events_pending ON native_campaign_events(provider_id,processed_at);
                CREATE INDEX IF NOT EXISTS native_campaign_events_retention ON native_campaign_events(processed_at);
                CREATE TABLE IF NOT EXISTS native_campaign_relay_registrations(
                  instance_id TEXT NOT NULL,send_id TEXT NOT NULL REFERENCES crm_campaign_sends(id) ON DELETE CASCADE,
                  token TEXT NOT NULL,provider_id TEXT,PRIMARY KEY(instance_id,send_id));
                CREATE INDEX IF NOT EXISTS native_calendar_contact_email ON crm_Contacts(email COLLATE native_email) WHERE deletedAt IS NULL;
                CREATE INDEX IF NOT EXISTS native_calendar_contact_personal ON crm_Contacts(personal_email COLLATE native_email) WHERE deletedAt IS NULL;
                CREATE INDEX IF NOT EXISTS native_calendar_target_email ON crm_Targets(email COLLATE native_email) WHERE deletedAt IS NULL;
                CREATE INDEX IF NOT EXISTS native_calendar_target_personal ON crm_Targets(personal_email COLLATE native_email) WHERE deletedAt IS NULL;
                CREATE INDEX IF NOT EXISTS native_calendar_target_company ON crm_Targets(company_email COLLATE native_email) WHERE deletedAt IS NULL;
                CREATE INDEX IF NOT EXISTS native_calendar_lead_email ON crm_Leads(email COLLATE native_email) WHERE deletedAt IS NULL;
                CREATE INDEX IF NOT EXISTS native_calendar_slot ON crm_CalendarEvents(source,julianday(startAt));
                """)
            }
        } catch { if let connection { sqlite3_close(connection) }; connection = nil; throw error }
        registerLiveConnection()
    }
    /// For an externally sealed, quiescent restored snapshot only. The owner
    /// must keep the file immutable for this connection's entire lifetime.
    /// A live/cold database with WAL/journal sidecars is not this API's input.
    /// No identity selection, bootstrap, migration, or runtime activation.
    init(readOnlyURL url: URL, schemaURL: URL) throws {
        self.url = url
        isReadOnly = true
        schema = try JSONDecoder().decode(NativeSchema.self, from: Data(contentsOf: schemaURL))
        guard schema.formatVersion == 1 else { throw NativeDBError.message("未対応のデータ形式です。") }
        guard url.isFileURL, url.query == nil, url.fragment == nil,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw NativeDBError.message("封印されたデータベースの通常ファイルを指定してください。")
        }
        var before = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1 else {
            throw NativeDBError.message("閲覧用のデータベースが見つからないか、通常ファイルではありません。")
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            var sidecar = stat()
            let result = lstat(url.path + suffix, &sidecar)
            guard result != 0, errno == ENOENT else {
                throw NativeDBError.message("更新途中のデータベースは封印済みの閲覧用として開けません。")
            }
        }
        // Foundation normalizes macOS /private/var back to /var, which the
        // SQLite NOFOLLOW VFS correctly rejects. Use the POSIX canonical path,
        // without URL.standardizedFileURL undoing that canonicalization.
        guard let resolved = realpath(url.path, nil) else { throw NativeDBError.message("閲覧用データベースの保存先を確認できません。") }
        let canonical = String(cString: resolved); free(resolved)
        var components = URLComponents()
        components.scheme = "file"; components.path = canonical
        components.queryItems = [.init(name: "mode", value: "ro"), .init(name: "immutable", value: "1")]
        guard let opened = components.string,
              sqlite3_open_v2(opened, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            let message = error; if let connection { sqlite3_close(connection) }; connection = nil
            throw NativeDBError.message(message)
        }
        do {
            var after = stat()
            guard lstat(url.path, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  sqlite3_db_readonly(connection, "main") == 1 else { throw NativeDBError.conflict }
            try registerCollations()
            sqlite3_busy_timeout(connection, 5000)
            // Connection-local tuning only. No journal mode / synchronous change.
            try execute("PRAGMA foreign_keys=ON; PRAGMA cache_size=-1024; PRAGMA temp_store=FILE; PRAGMA mmap_size=0;")
            guard sqlite3_set_authorizer(connection, { _, operation, p1, p2, database, _ in
                switch operation {
                case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE, SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
                    return SQLITE_OK
                case SQLITE_PRAGMA:
                    let name = p1.map { String(cString: $0).lowercased() } ?? ""
                    if ["table_info", "table_xinfo", "index_list", "index_info", "foreign_key_list", "integrity_check", "foreign_key_check"].contains(name) { return SQLITE_OK }
                    return p2 == nil && ["data_version", "user_version", "journal_mode"].contains(name) ? SQLITE_OK : SQLITE_DENY
                case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE, SQLITE_CREATE_TEMP_TABLE, SQLITE_DROP_TEMP_TABLE, SQLITE_CREATE_TEMP_INDEX, SQLITE_DROP_TEMP_INDEX, SQLITE_CREATE_INDEX, SQLITE_DROP_INDEX, SQLITE_REINDEX:
                    // Existing exact text search / aggregate views use ephemeral
                    // SQLite work tables. Never permit main/attached DB writes.
                    return database.map { String(cString: $0) == "temp" } == true ? SQLITE_OK : SQLITE_DENY
                default:
                    return SQLITE_DENY
                }
            }, nil) == SQLITE_OK else { throw NativeDBError.message(error) }
            try transaction { try validateReadOnlySchema() }
        } catch { if let connection { sqlite3_close(connection) }; connection = nil; throw error }
        registerLiveConnection()
    }
    private func requireWritable() throws {
        guard !isReadOnly else { throw NativeDBError.message("このデータベースは閲覧専用です。") }
    }
    /// Check real table/column affinity, nullability and ordered primary keys,
    /// not merely the metadata claim. Full auxiliary DDL/seal verification stays
    /// at the restore boundary; this opener never repairs an old schema.
    private func validateReadOnlySchema() throws {
        guard try metadata("schemaSHA256") == schema.schemaSHA256,
              try query("PRAGMA user_version").first?["user_version"] == .integer(1) else {
            throw NativeDBError.message("閲覧用データベースの構造が一致しません。移行または復元の確認が必要です。")
        }
        for model in schema.models {
            guard try query("SELECT type FROM sqlite_master WHERE name=?", [.text(model.name)]).first?["type"] == .text("table") else { throw NativeDBError.message("閲覧用データベースの保存先が不足しています：" + model.name) }
            let columns = try query("PRAGMA table_info(" + quoted(model.name) + ")")
            let expected = Set(model.fields.map { $0.column } + ["_native_revision", "_native_search"])
            guard columns.count == expected.count, Set(columns.compactMap { $0["name"]?.string }) == expected else { throw NativeDBError.message("閲覧用データベースの項目が一致しません：" + model.name) }
            let indexed = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"]!.string, $0) })
            for field in model.fields {
                let type = field.array ? "TEXT" : ["Int", "BigInt", "Boolean"].contains(field.type) ? "INTEGER" : field.type == "Float" ? "REAL" : field.type == "Bytes" || field.type.hasPrefix("Unsupported(\"vector") ? "BLOB" : "TEXT"
                let row = indexed[field.column]!, pk = model.primaryKey.firstIndex(of: field.name).map { $0 + 1 } ?? 0
                guard row["type"] == .text(type), row["notnull"] == .integer(field.optional ? 0 : 1), row["pk"] == .integer(Int64(pk)) else { throw NativeDBError.message("閲覧用データベースの型が一致しません：" + model.name + "." + field.name) }
            }
            guard indexed["_native_revision"]?["type"] == .text("INTEGER"), indexed["_native_revision"]?["notnull"] == .integer(1), indexed["_native_search"]?["type"] == .text("TEXT"), indexed["_native_search"]?["notnull"] == .integer(1) else { throw NativeDBError.message("閲覧用データベースの管理項目が一致しません。") }
        }
    }

    private func registerCollations() throws {
            guard sqlite3_create_collation_v2(connection,"native_decimal",SQLITE_UTF8,nil,{ _,ac,a,bc,b in
                NativeDecimalOrder.compare(UnsafeRawBufferPointer(start:a,count:Int(ac)),UnsafeRawBufferPointer(start:b,count:Int(bc)))
            },nil) == SQLITE_OK,
            sqlite3_create_collation_v2(connection,"native_japanese",SQLITE_UTF8,nil,{ _,ac,a,bc,b in
                let left = String(decoding:UnsafeRawBufferPointer(start:a,count:Int(ac)),as:UTF8.self)
                let right = String(decoding:UnsafeRawBufferPointer(start:b,count:Int(bc)),as:UTF8.self)
                return Int32(left.compare(right,options:[.caseInsensitive],locale:Locale(identifier:"ja_JP")).rawValue)
            },nil) == SQLITE_OK,
            sqlite3_create_collation_v2(connection,"native_email",SQLITE_UTF8,nil,{ _,ac,a,bc,b in
                let left = String(decoding:UnsafeRawBufferPointer(start:a,count:Int(ac)),as:UTF8.self).lowercased()
                let right = String(decoding:UnsafeRawBufferPointer(start:b,count:Int(bc)),as:UTF8.self).lowercased()
                if left == right { return 0 }; return left < right ? -1 : 1
            },nil) == SQLITE_OK else { throw NativeDBError.message(error) }
    }
    deinit {
        if let connection {sqlite3_close_v2(connection)}
        Self.connectionsLock.lock();Self.connections.removeValue(forKey:connectionIdentity);Self.connectionsLock.unlock()
    }
    private var error: String { connection.map { String(cString: sqlite3_errmsg($0)) } ?? "データベースを開けません。" }
    private func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP")).precomposedStringWithCanonicalMapping
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(error) }
    }
    private func statement(_ sql: String, _ values: [SQLValue]) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw NativeDBError.message(error) }
        do {
            guard sqlite3_bind_parameter_count(pointer) == Int32(values.count) else { throw NativeDBError.message("保存パラメータが一致しません。") }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1); let code: Int32
                switch value {
                case .null: code = sqlite3_bind_null(pointer, index)
                case let .text(v): code = sqlite3_bind_text(pointer, index, v, -1, transient)
                case let .integer(v): code = sqlite3_bind_int64(pointer, index, v)
                case let .real(v): code = sqlite3_bind_double(pointer, index, v)
                case let .blob(v): code = v.isEmpty ? sqlite3_bind_zeroblob(pointer, index, 0) : v.withUnsafeBytes { sqlite3_bind_blob(pointer, index, $0.baseAddress, Int32($0.count), transient) }
                }
                guard code == SQLITE_OK else { throw NativeDBError.message(error) }
            }
            return pointer
        } catch { sqlite3_finalize(pointer); throw error }
    }
    @discardableResult private func run(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw NativeDBError.message(error) }
        return Int(sqlite3_changes(connection))
    }
    private func query(_ sql: String, _ values: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        var rows: [[String: SQLValue]] = []
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw NativeDBError.message(error) }
            var row: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(query) {
                let name = String(cString: sqlite3_column_name(query, column)); let value: SQLValue
                switch sqlite3_column_type(query, column) {
                case SQLITE_INTEGER: value = .integer(sqlite3_column_int64(query, column))
                case SQLITE_FLOAT: value = .real(sqlite3_column_double(query, column))
                case SQLITE_TEXT: value = .text(String(cString: sqlite3_column_text(query, column)))
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(query, column))
                    value = .blob(length == 0 ? Data() : Data(bytes: sqlite3_column_blob(query, column)!, count: length))
                default: value = .null
                }
                row[name] = value
            }
            rows.append(row)
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try synchronized {
            let depth = transactionDepth; let savepoint = "native_sp_\(depth)"
            try execute(depth == 0 ? (isReadOnly ? "BEGIN DEFERRED" : "BEGIN IMMEDIATE") : "SAVEPOINT \(savepoint)")
            transactionDepth += 1;transactionCompletions.append([])
            let result:T
            do {
                result = try body()
                try execute(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            } catch {
                try? execute(depth == 0 ? "ROLLBACK" : "ROLLBACK TO \(savepoint); RELEASE \(savepoint)")
                finishTransaction(rolledBack:true)
                throw error
            }
            finishTransaction(rolledBack:false)
            return result
        }
    }
    private func finishTransaction(rolledBack:Bool) {
        var callbacks=transactionCompletions.removeLast();transactionDepth-=1
        if rolledBack { for index in callbacks.indices { callbacks[index].rolledBack=true } }
        if transactionDepth>0 { transactionCompletions[transactionCompletions.count-1] += callbacks }
        else { for callback in callbacks { if callback.rolledBack { callback.rollback() } else { callback.commit() } } }
    }
    /// Nested rollback callbacks wait until the outermost transaction ends.
    /// Calls outside a transaction run the commit callback immediately.
    func deferUntilTransactionEnds(onCommit:@escaping ()->Void,onRollback:@escaping ()->Void) {
        synchronized {
            if transactionDepth==0 { onCommit() }
            else { transactionCompletions[transactionCompletions.count-1].append(.init(commit:onCommit,rollback:onRollback)) }
        }
    }
    private func initial(_ field: NativeSchema.Field) throws -> SQLValue? {
        guard let expression = field.defaultExpression else {
            if field.attributes.contains("@updatedAt") { return .text(Self.now()) }
            if field.array { return .text("[]") }
            return nil
        }
        if expression == "uuid()" || expression == "cuid()" { return .text(UUID().uuidString.lowercased()) }
        if expression == "now()" { return .text(Self.now()) }
        if expression == "true" { return .integer(1) }; if expression == "false" { return .integer(0) }
        if expression.hasPrefix("\"") { return .text(try JSONDecoder().decode(String.self, from: Data(expression.utf8))) }
        if field.type == "Int" || field.type == "BigInt", let value = Int64(expression) { return .integer(value) }
        if field.type == "Float", let value = Double(expression) { return .real(value) }
        return .text(expression)
    }
    func initialValues(_ name: String) throws -> [String: SQLValue] {
        var values: [String: SQLValue] = [:]
        for field in try schema.model(name).fields { values[field.name] = try initial(field) ?? .null }
        return values
    }
    private func validated(_ field: NativeSchema.Field, value: SQLValue) throws -> SQLValue {
        if value == .null {
            guard field.optional else { throw NativeDBError.message("必須項目が未入力です：\(field.name)") }
            return value
        }
        if case let .text(text) = value, text.contains("\0") { throw NativeDBError.message("使用できない文字が含まれています。") }
        if field.array || field.type == "Json" {
            guard case let .text(text) = value, let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  !field.array || parsed is [Any] else { throw NativeDBError.message("構造化データの形式が不正です：\(field.name)") }
            return value
        }
        switch field.type {
        case "Int", "BigInt", "Boolean":
            guard case let .integer(number) = value, field.type != "Boolean" || number == 0 || number == 1 else { throw NativeDBError.message("数値の形式が不正です：\(field.name)") }
            if field.type == "Int", number < Int64(Int32.min) || number > Int64(Int32.max) { throw NativeDBError.message("数値が範囲を超えています。") }
        case "Float":
            guard case let .real(number) = value, number.isFinite else { throw NativeDBError.message("数値の形式が不正です。") }
        case "Decimal":
            guard case let .text(text) = value, let number = Decimal(string: text, locale: Self.locale), !number.isNaN,
                  text.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { throw NativeDBError.message("金額・数量の形式が不正です。") }
            if let range = field.attributes.range(of: #"@db.Decimal\([0-9]+,\s*[0-9]+\)"#, options: .regularExpression) {
                let limits = field.attributes[range].dropFirst(12).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let parts = text.replacingOccurrences(of: "-", with: "").split(separator: ".", omittingEmptySubsequences: false)
                let integerDigits = parts[0].drop(while: { $0 == "0" }).count
                guard limits.count == 2, integerDigits <= limits[0] - limits[1], parts.count == 1 || parts[1].count <= limits[1] else {
                    throw NativeDBError.message("金額・数量の桁数が保存可能な範囲を超えています。")
                }
            }
        case "DateTime":
            guard case let .text(text) = value else { throw NativeDBError.message("日時の形式が不正です。") }
            let formatter = ISO8601DateFormatter()
            if formatter.date(from: text) == nil {
                formatter.formatOptions.insert(.withFractionalSeconds)
                guard formatter.date(from: text) != nil else { throw NativeDBError.message("日時の形式が不正です：\(field.name)") }
            }
        case "Bytes":
            guard case .blob = value else { throw NativeDBError.message("添付データの形式が不正です。") }
        default:
            if field.type.hasPrefix("Unsupported(\"vector") {
                guard case .blob = value else { throw NativeDBError.message("ベクトルデータの形式が不正です。") }
            } else {
                guard case let .text(text) = value else { throw NativeDBError.message("文字列の形式が不正です：\(field.name)") }
                if field.attributes.contains("@db.Uuid"), UUID(uuidString: text) == nil { throw NativeDBError.message("識別子の形式が不正です：\(field.name)") }
                if let options = schema.enums[field.type], !options.contains(text) { throw NativeDBError.message("選択肢が不正です：\(field.name)") }
            }
        }
        return value
    }
    private func checked(_ model: NativeSchema.Model, _ input: [String: SQLValue], fillingDefaults: Bool) throws -> [String: SQLValue] {
        guard input.keys.allSatisfy({ model.field($0) != nil }) else { throw NativeDBError.message("不明な保存項目があります。") }
        var output: [String: SQLValue] = [:]
        for field in model.fields {
            let value = try input[field.name] ?? (fillingDefaults ? initial(field) : nil) ?? .null
            output[field.name] = try validated(field, value: value)
        }
        return output
    }
    private func secret(_ field: String) -> Bool {
        let lower = field.lowercased()
        return ["password", "token", "secret", "credential", "encrypted", "apikey"].contains { lower.contains($0) }
    }
    private func searchKey(_ values: [String: SQLValue],model: String) -> String {
        if model == "Email" { return Self.normalized(["subject","fromName","fromEmail"].map{values[$0]?.string ?? ""}.joined(separator:"\n")) }
        return Self.normalized(values.sorted { $0.key < $1.key }.compactMap { key, value in
            guard !secret(key), !["body", "html", "content", "description", "embedding"].contains(key.lowercased()), case let .text(text) = value else { return nil }
            return String(text.prefix(512))
        }.joined(separator: "\n"))
    }
    /// UNION terminates malformed cycles; every ancestor must still be live.
    func importedDocumentAncestorsLive(_ id:String)throws->Bool{
        try synchronized{
            let rows=try query("WITH RECURSIVE lineage(id,parent,deleted) AS (SELECT id,parent_document_id,deletedAt FROM Documents WHERE id=? UNION SELECT d.id,d.parent_document_id,d.deletedAt FROM Documents d JOIN lineage p ON d.id=p.parent) SELECT COUNT(*) n,SUM(CASE WHEN deleted IS NOT NULL THEN 1 ELSE 0 END) dead,SUM(CASE WHEN parent IS NULL THEN 1 ELSE 0 END) roots FROM lineage",[.text(id)])
            return rows.first?["dead"] == .integer(0) && rows.first?["roots"] == .integer(1)
        }
    }
    func discardOperationalMigrationConnection() throws {
        try synchronized {
            guard !isReadOnly,transactionDepth==0,try metadata("localActor")==nil else{throw NativeDBError.conflict}
            guard sqlite3_close(connection)==SQLITE_OK else{throw NativeDBError.conflict};connection=nil
        }
    }
    /// Close the exclusively owned unpublished migration DB after durable sealing.
    /// Never used for an ordinary live workspace or accepted application work.
    func sealOperationalMigration() throws {
        try requireWritable()
        try synchronized {
            guard transactionDepth==0,try metadata("migration.operational.state")=="review-required",try metadata("localActor")==nil else{throw NativeDBError.conflict}
            guard try query("PRAGMA foreign_key_check").isEmpty else{throw NativeDBError.conflict}
            try execute("DROP TABLE IF EXISTS _migration_assets")
            guard sqlite3_wal_checkpoint_v2(connection,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil)==SQLITE_OK else{throw NativeDBError.conflict}
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
            guard sqlite3_close(connection)==SQLITE_OK else{throw NativeDBError.conflict};connection=nil
        }
    }
    /// Offline migration only: no actor issuance, business scalar updates or jobs.
    /// The caller owns an unpublished new root, never a live workspace.
    func rebuildOperationalMigrationSearch() throws {
        try requireWritable()
        try transaction {
            guard try metadata("migration.operational.state")=="preparing",try metadata("localActor")==nil else {throw NativeDBError.conflict}
            for model in schema.models {
                var after:Int64=0
                while true {
                    try Task.checkCancellation()
                    let columns=model.fields.map {field in
                        "CASE WHEN typeof(\(quoted(field.column)))='text' THEN \(quoted(field.column)) ELSE NULL END AS \(quoted(field.name))"
                    }.joined(separator:",")
                    let rows=try query("SELECT rowid AS _migration_rowid,\(columns) FROM \(quoted(model.name)) WHERE rowid>? ORDER BY rowid LIMIT 1",[.integer(after)])
                    for row in rows {guard case let .integer(id)=row["_migration_rowid"] else{throw NativeDBError.conflict};after=id;try run("UPDATE \(quoted(model.name)) SET _native_search=? WHERE rowid=?",[.text(searchKey(row,model:model.name)),.integer(id)])}
                    if rows.isEmpty{break}
                }
            }
        }
    }
    private func keyClause(_ model: NativeSchema.Model, _ key: [String: SQLValue]) throws -> (String, [SQLValue]) {
        guard Set(key.keys) == Set(model.primaryKey), !key.values.contains(.null) else { throw NativeDBError.message("識別子が不足しています。") }
        return (model.primaryKey.map { quoted(model.field($0)!.column) + "=?" }.joined(separator: " AND "), model.primaryKey.map { key[$0]! })
    }
    func key(for record: NativeRecord) throws -> [String: SQLValue] {
        let model = try schema.model(record.model)
        return Dictionary(uniqueKeysWithValues: model.primaryKey.map { ($0, record[$0]) })
    }
    /// Frozen CRM automation IDs/recipients only; not a general metadata query API.
    func crmAutomationSnapshotPage(ownerID: String, kind: String, after: String? = nil) throws -> [(key: String, value: String)] {
        guard UUID(uuidString: ownerID) != nil, ["recycleTarget", "recipient"].contains(kind) else { throw NativeDBError.conflict }
        let prefix = "crm.automation.snapshot.v1." + ownerID + "." + kind + "."
        guard after == nil || after!.hasPrefix(prefix) else { throw NativeDBError.conflict }
        return try synchronized {
            try Task.checkCancellation()
            return try query("SELECT key,value FROM native_metadata WHERE key LIKE ? AND key>? ORDER BY key LIMIT 100", [.text(prefix + "%"), .text(after ?? prefix)]).map { ($0["key"]!.string, $0["value"]!.string) }
        }
    }
    /// Explicit native notice retry grants a fresh bounded attempt budget while
    /// preserving total attempts, immutable bytes, receipts, and dedupe clocks.
    func retryCRMAutomationNotice(_ expected: NativeJob, actor: String, now: Date) throws {
        try requireWritable()
        try transaction {
            guard ["crm.automation.kill.notice","crm.automation.recycle.notice"].contains(expected.event),
                  let current = try job(id:expected.id),current == expected else { throw NativeDBError.conflict }
            // The established guard rejects uncertain sends beyond 23 hours and
            // keeps needs_review terminal to retry (manual outcome only).
            try retryJob(id:current.id,now:now)
            var result = current.result
            result["manualRetryAttemptBase"] = String(current.attempts)
            result["manualRetryRequestedBy"] = actor
            result["manualRetryRequestedAt"] = ISO8601DateFormatter().string(from:now)
            let encoded = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET result=? WHERE id=?",[.text(encoded),.text(current.id)])
        }
    }

    /// The snapshot namespace alone is indexed/range-seeked; never enumerate
    /// all metadata or materialize its values. Oversized unknown keys stay held.
    func crmAutomationSnapshotRetentionPage(after: String?) throws -> [String?] {
        let lower = "crm.automation.snapshot.v1.", upper = "crm.automation.snapshot.v1/"
        guard after == nil || (after!.hasPrefix(lower) && after!.utf8.count <= 128) else { throw NativeDBError.conflict }
        return try synchronized {
            try query("SELECT CASE WHEN length(CAST(key AS BLOB))<=128 THEN key END AS key FROM native_metadata WHERE key>=? AND key<? AND key>? ORDER BY key LIMIT 100",[.text(lower),.text(upper),.text(after ?? lower)]).map { $0["key"] == .null ? nil:$0["key"]?.string }
        }
    }
    func crmAutomationSnapshotRetentionCursor() throws -> String? {
        try synchronized { try query("SELECT CASE WHEN length(CAST(value AS BLOB))<=128 THEN value END AS value FROM native_metadata WHERE key='crm.automation.snapshot.retention.cursor.v1'").first?["value"].flatMap { $0 == .null || $0.string.isEmpty ? nil:$0.string } }
    }
    /// Bounded proof projection. Notice bodies, subject/user names, full audit
    /// notes and unrelated jobs are never fetched by the cleanup path.
    func crmAutomationSnapshotOwnerProof(_ id: String) throws -> [String:String]? {
        guard UUID(uuidString:id) != nil else { return nil }
        let fields:[(String,String,String)] = [
            ("payload","scanId","scanId"),("payload","count","count"),("payload","recipientCount","recipientCount"),
            ("result","recycled","recycled"),("result","applyJobId","applyJobId"),("result","outcome","outcome"),
            ("result","providerID","providerID"),("result","acceptedAt","acceptedAt"),("result","reviewOutcome","reviewOutcome"),
            ("result","reviewedBy","reviewedBy"),("result","reviewedAt","reviewedAt"),("result","reviewPreviousStatus","reviewPreviousStatus"),
            ("result","cancelledBy","cancelledBy"),("result","listId","listId"),("result","recipients","recipients")]
        let projections = fields.map { column,key,alias in
            "CASE WHEN json_valid(\(column)) THEN CASE WHEN json_type(\(column),'$.\(key)')='text' AND length(CAST(json_extract(\(column),'$.\(key)') AS BLOB))<=128 THEN json_extract(\(column),'$.\(key)') END END AS "+alias
        }
        let sql = "SELECT CASE WHEN length(event)<=64 THEN event END AS event,CASE WHEN length(status)<=32 THEN status END AS status,delivery_started_at IS NOT NULL AS begun," +
            "CASE WHEN json_valid(payload) AND json_valid(result) THEN json_type(payload)='object' AND json_type(result)='object' ELSE 0 END AS validJSON," +
            "CASE WHEN json_valid(result) THEN json_type(result,'$.providerID') IS NOT NULL ELSE 1 END AS hasProvider," +
            "CASE WHEN json_valid(result) THEN json_type(result,'$.reviewOutcome') IS NOT NULL ELSE 1 END AS hasReview," +
            "CASE WHEN json_valid(result) THEN json_type(result,'$.reviewNote')='text' AND length(trim(json_extract(result,'$.reviewNote')))>0 ELSE 0 END AS note," +
            "CASE WHEN json_valid(result) THEN json_type(result,'$.reason')='text' AND length(trim(json_extract(result,'$.reason')))>0 ELSE 0 END AS reason," + projections.joined(separator:",") + " FROM native_outbox WHERE id=?"
        return try synchronized {
            guard let row=try query(sql,[.text(id)]).first else { return nil }
            return row.reduce(into:[:]){ result,pair in if pair.value != .null { result[pair.key]=pair.value.string } }
        }
    }
    /// Internal exact key deletion; the retention caller owns terminal proofs
    /// and this operation inside one outer transaction.
    func removeCRMAutomationSnapshot(ownerID: String, kind: String, ordinal: String) throws {
        try requireWritable()
        guard let uuid=UUID(uuidString:ownerID),uuid.uuidString.lowercased()==ownerID,
              ["recycleTarget","recipient"].contains(kind),ordinal.utf8.count==12,ordinal.utf8.allSatisfy({(48...57).contains($0)}) else { throw NativeDBError.conflict }
        _ = try transaction { try run("DELETE FROM native_metadata WHERE key=?",[.text("crm.automation.snapshot.v1."+ownerID+"."+kind+"."+ordinal)]) }
    }

    func metadata(_ key: String) throws -> String? {
        try synchronized { try query("SELECT value FROM native_metadata WHERE key=?", [.text(key)]).first?["value"]?.string }
    }
    func setMetadata(_ key: String, value: String) throws { try requireWritable();
        _ = try synchronized { try run("INSERT INTO native_metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)]) }
    }
    func queueAIKeyCleanup(_ id: String, notBefore: Date) throws { try requireWritable();
        guard UUID(uuidString: id) != nil, notBefore.timeIntervalSince1970.isFinite else { throw NativeDBError.conflict }
        _ = try synchronized { try run("INSERT INTO native_ai_key_cleanup VALUES(?,?) ON CONFLICT(credential_id) DO UPDATE SET not_before=excluded.not_before", [.text(id), .real(notBefore.timeIntervalSince1970)]) }
    }
    func requireAIKeyReservation(_ id: String, now: Date) throws {
        try synchronized {
            guard try !query("SELECT credential_id FROM native_ai_key_cleanup WHERE credential_id=? AND not_before>?", [.text(id), .real(now.timeIntervalSince1970)]).isEmpty else { throw NativeDBError.conflict }
        }
    }
    func aiKeyCleanupPage(after: String = "", now: Date) throws -> [String] {
        try synchronized { try query("SELECT credential_id FROM native_ai_key_cleanup c WHERE credential_id>? AND not_before<=? AND NOT EXISTS(SELECT 1 FROM ApiKeys a WHERE a.encryptedKey='native-ai-keychain:'||c.credential_id) AND NOT EXISTS(SELECT 1 FROM native_metadata m WHERE m.key='native_e2b_keychain' AND m.value=c.credential_id) ORDER BY credential_id LIMIT 100", [.text(after), .real(now.timeIntervalSince1970)]).compactMap { $0["credential_id"]?.string } }
    }
    func aiKeyIsReferenced(_ id: String) throws -> Bool {
        try synchronized { try !query("SELECT id FROM ApiKeys WHERE encryptedKey=? UNION ALL SELECT value FROM native_metadata WHERE key='native_e2b_keychain' AND value=? LIMIT 1", [.text("native-ai-keychain:" + id), .text(id)]).isEmpty }
    }
    func clearAIKeyCleanup(_ id: String) throws { try requireWritable(); _ = try synchronized { try run("DELETE FROM native_ai_key_cleanup WHERE credential_id=?", [.text(id)]) } }
    func preserveLegacyAccount(id: String, json: String) throws { try requireWritable();
        _ = try synchronized { try run("INSERT OR IGNORE INTO native_legacy_accounts VALUES(?,?)", [.text(id), .text(json)]) }
    }
    @discardableResult func enqueue(_ event: String, payload: [String: String], id: String = UUID().uuidString.lowercased(), now: Date = Date(), runAt: Date? = nil) throws -> String { try requireWritable();
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
        if let runAt, !runAt.timeIntervalSince1970.isFinite || runAt.timeIntervalSince1970 < -62_135_596_800 || runAt.timeIntervalSince1970 >= 253_402_300_800 { throw NativeDBError.message("処理の予約日時が範囲外です。") }
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds)
        _ = try synchronized { try run("INSERT INTO native_outbox(id,event,payload,created_at,next_run_at) VALUES(?,?,?,?,?)", [.text(id), .text(event), .text(json), .text(ISO8601DateFormatter().string(from:now)),runAt.map{.text(f.string(from:$0))} ?? .null]) }
        notifyJobChange()
        return id
    }
    private func record(_ model: NativeSchema.Model, _ raw: [String: SQLValue]) -> NativeRecord {
        let revision: Int64 = { if case let .integer(v) = raw["_native_revision"] { return v }; return 0 }()
        return NativeRecord(model: model.name, values: raw.filter { !$0.key.hasPrefix("_native_") }, revision: revision)
    }
    func get(_ name: String, key: [String: SQLValue]) throws -> NativeRecord? {
        try synchronized {
            let model = try schema.model(name); let (whereSQL, bindings) = try keyClause(model, key)
            let fields = model.fields.map { quoted($0.column) + " AS " + quoted($0.name) }.joined(separator: ",")
            return try query("SELECT \(fields),_native_revision FROM \(quoted(name)) WHERE \(whereSQL)", bindings).first.map { record(model, $0) }
        }
    }
    @discardableResult func insert(_ name: String, values: [String: SQLValue], actor: String) throws -> NativeRecord { try requireWritable();
        return try transaction {
            let original=values,model = try schema.model(name)
            let patch=try NativeRecordMutationScope.bypassHooks ? values:beforeRecordWrite?(name,"create",nil,values,actor) ?? values
            let values = try checked(model, patch, fillingDefaults: true)
            let fields = model.fields.map { quoted($0.column) } + ["_native_search"]
            let bindings = model.fields.map { values[$0.name]! } + [.text(searchKey(values,model:model.name))]
            try run("INSERT INTO \(quoted(name))(\(fields.joined(separator: ","))) VALUES(\(bindings.map { _ in "?" }.joined(separator: ",")))", bindings)
            let result = NativeRecord(model: name, values: values, revision: 1)
            try audit(before: nil, after: result, action: "create", actor: actor)
            if !NativeRecordMutationScope.bypassHooks { afterRecordWrite?(name,"create",nil,result,original,actor) }
            return result
        }
    }
    @discardableResult func update(_ record: NativeRecord, changes: [String: SQLValue], actor: String, action: String = "update") throws -> NativeRecord { try requireWritable();
        return try transaction {
            let model = try schema.model(record.model); let key = try key(for: record)
            guard changes.keys.allSatisfy({ !model.primaryKey.contains($0) }) else { throw NativeDBError.message("識別子は変更できません。") }
            guard let before = try get(model.name, key: key), before.revision == record.revision else { throw NativeDBError.conflict }
            let patch=try NativeRecordMutationScope.bypassHooks ? changes:beforeRecordWrite?(model.name,"update",before,changes,actor) ?? changes
            guard patch.keys.allSatisfy({ !model.primaryKey.contains($0) }) else { throw NativeDBError.message("識別子は変更できません。") }
            var merged = before.values.merging(patch) { _, new in new }
            for field in model.fields where field.attributes.contains("@updatedAt") { merged[field.name] = .text(Self.now()) }
            let checked = try checked(model, merged, fillingDefaults: false)
            let mutable = model.fields.filter { !model.primaryKey.contains($0.name) }
            let (whereSQL, bindings) = try keyClause(model, key)
            let assignments = mutable.map { quoted($0.column) + "=?" } + ["_native_search=?", "_native_revision=_native_revision+1"]
            guard try run("UPDATE \(quoted(model.name)) SET \(assignments.joined(separator: ",")) WHERE \(whereSQL) AND _native_revision=?",
                          mutable.map { checked[$0.name]! } + [.text(searchKey(checked,model:model.name))] + bindings + [.integer(record.revision)]) == 1 else { throw NativeDBError.conflict }
            let result = NativeRecord(model: model.name, values: checked, revision: record.revision + 1)
            try audit(before: before, after: result, action: action, actor: actor)
            if !NativeRecordMutationScope.bypassHooks { afterRecordWrite?(model.name,"update",before,result,changes,actor) }
            return result
        }
    }
    @discardableResult func setDeleted(_ record: NativeRecord, deleted: Bool, actor: String) throws -> NativeRecord { try requireWritable();
        let model = try schema.model(record.model)
        guard model.field("deletedAt") != nil else { throw NativeDBError.message("このデータの削除操作には専用の処理が必要です。") }
        var changes: [String: SQLValue] = ["deletedAt": deleted ? .text(Self.now()) : .null]
        if model.field("deletedBy") != nil { changes["deletedBy"] = deleted ? .text(actor) : .null }
        return try update(record, changes: changes, actor: actor, action: deleted ? "delete" : "restore")
    }
    private func compile(_ filter: RecordFilter, model: NativeSchema.Model, alias: String, counter: inout Int) throws -> (String, [SQLValue]) {
        func column(_ field: String) throws -> String {
            guard let field = model.field(field) else { throw NativeDBError.message("不明な絞り込み項目です。") }
            return alias + "." + quoted(field.column)
        }
        switch filter {
        case .all: return ("1", [])
        case .none: return ("0", [])
        case let .equal(field, value): return try (column(field) + (value == .null ? " IS NULL" : "=?"), value == .null ? [] : [value])
        case let .arrayContains(field, value):
            guard model.field(field)?.array == true else { throw NativeDBError.message("配列の絞り込み項目が不正です。") }
            let c = try column(field); counter += 1; let item = "array\(counter)"
            return ("EXISTS(SELECT 1 FROM json_each(CASE WHEN json_valid(\(c)) THEN CASE WHEN json_type(\(c))='array' THEN \(c) ELSE '[]' END ELSE '[]' END) \(item) WHERE \(item).type='text' AND \(item).value=?)", [.text(value)])
        case let .beforeDate(field, value):
            guard model.field(field)?.type == "DateTime" else { throw NativeDBError.message("日付の絞り込み項目が不正です。") }
            return try ("julianday(\(column(field)))<julianday(?)", [.text(value)])
        case let .compareDate(field, comparison, value):
            guard model.field(field)?.type == "DateTime" else { throw NativeDBError.message("日付の絞り込み項目が不正です。") }
            return try ("julianday(\(column(field)))\(comparison.rawValue)julianday(?)", [.text(value)])
        case let .not(inner): let (sql, values) = try compile(inner, model: model, alias: alias, counter: &counter); return ("NOT (\(sql))", values)
        case let .any(filters), let .every(filters):
            let any: Bool = { if case .any = filter { return true }; return false }()
            if filters.isEmpty { return (any ? "0" : "1", []) }
            var pieces: [String] = []; var values: [SQLValue] = []
            for item in filters { let result = try compile(item, model: model, alias: alias, counter: &counter); pieces.append(result.0); values += result.1 }
            return ("(" + pieces.joined(separator: any ? " OR " : " AND ") + ")", values)
        case let .relation(name, local, foreign, inner):
            let target = try schema.model(name)
            guard let remote = target.field(foreign) else { throw NativeDBError.message("関連先の項目が不正です。") }
            counter += 1; let next = "scope\(counter)"
            let (sql, values) = try compile(inner, model: target, alias: next, counter: &counter)
            return try ("EXISTS(SELECT 1 FROM \(quoted(name)) \(next) WHERE \(next).\(quoted(remote.column))=\(column(local)) AND (\(sql)))", values)
        case let .scalar(name,operation,values,insensitive):
            guard let field=model.field(name) else { throw NativeDBError.message("不明な絞り込み項目です。") }
            let raw=try column(name)
            let column=field.type == "DateTime" ? "julianday(\(raw))":field.type == "Decimal" ? raw+" COLLATE native_decimal":insensitive ? "native_mcp_lower(\(raw))":raw
            func parameter()->String { field.type == "DateTime" ? "julianday(?)":insensitive ? "native_mcp_lower(?)":"?" }
            if ["in","notIn"].contains(operation) {
                if values.isEmpty { return (operation=="in" ? "0":"1",[]) }
                return (column+(operation=="in" ? " IN (":" NOT IN (")+values.map { _ in parameter() }.joined(separator:",")+")",values)
            }
            if ["has","hasSome","hasEvery","isEmpty"].contains(operation) {
                guard field.array else { throw NativeDBError.message("配列の絞り込み項目が不正です。") }
                if operation=="isEmpty" { return ("json_array_length(\(raw))"+(values.first?.string=="true" || values.first == .integer(1) ? "=0":">0"),[]) }
                if values.isEmpty { return (operation=="hasEvery" ? "1":"0",[]) }
                let clauses=values.map { _ in "EXISTS(SELECT 1 FROM json_each(\(raw)) item WHERE item.value=?)" }
                return ("("+clauses.joined(separator:operation=="hasEvery" ? " AND ":" OR ")+")",values)
            }
            guard values.count==1,let value=values.first else { throw NativeDBError.message("絞り込み条件が不正です。") }
            if operation=="equals" { return (column+(value == .null ? " IS NULL":"="+parameter()),value == .null ? []:[value]) }
            if let comparison=["lt":"<","lte":"<=","gt":">","gte":">="][operation] { return (column+comparison+parameter(),[value]) }
            if ["contains","startsWith","endsWith"].contains(operation),field.type=="String",!field.array {
                var glob="",escape=false
                for char in value.string {
                    if !escape && char == "\\" { escape=true;continue }
                    if !escape && char == "%" { glob+="*" }
                    else if !escape && char == "_" { glob+="?" }
                    else { glob += char == "*" ? "[*]":char == "?" ? "[?]":char == "[" ? "[[]":String(char) }
                    escape=false
                }
                if escape { glob+="\\" }
                if operation != "startsWith" { glob="*"+glob };if operation != "endsWith" { glob+="*" }
                return (column+" GLOB "+parameter(),[.text(glob)])
            }
            throw NativeDBError.message("絞り込み演算子が不正です。")
        }
    }
    func page(_ name: String, fields requested: [String], search: String = "", equal: [String: SQLValue] = [:], includeDeleted: Bool = false, offset: Int = 0, filter: RecordFilter = .all, sort: String? = nil, descending: Bool = false, insertionOrderForTies: Bool = false, relatedSort: RecordRelationSort? = nil, nullsFirst: Bool = false, localizedSort: Bool = false, limit: Int = 100) throws -> (rows: [NativeRecord], total: Int) {
        try synchronized {
            let model = try schema.model(name)
            guard requested.allSatisfy({ model.field($0) != nil }), equal.keys.allSatisfy({ model.field($0) != nil }) else { throw NativeDBError.message("不明な検索項目があります。") }
            let names = Array(Set(requested + model.primaryKey)).sorted()
            var clauses: [String] = []; var bindings: [SQLValue] = []
            var aliases = 0; let scope = try compile(filter, model: model, alias: "base", counter: &aliases)
            clauses.append(scope.0); bindings += scope.1
            if !includeDeleted, let deleted = model.field("deletedAt") { clauses.append(quoted(deleted.column) + " IS NULL") }
            for (field, value) in equal.sorted(by: { $0.key < $1.key }) {
                clauses.append(quoted(model.field(field)!.column) + (value == .null ? " IS NULL" : "=?"))
                if value != .null { bindings.append(value) }
            }
            if !search.isEmpty {
                let term = Self.normalized(search).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                clauses.append("_native_search LIKE ? ESCAPE '\\'"); bindings.append(.text("%\(term)%"))
            }
            let filter = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            let count = try query("SELECT count(*) AS count FROM \(quoted(name)) base\(filter)", bindings).first?["count"]
            let total: Int = { if case let .integer(v) = count { return Int(v) }; return 0 }()
            let fields = names.map { quoted(model.field($0)!.column) + " AS " + quoted($0) } + ["_native_revision"]
            var ordering = model.primaryKey.map { quoted(model.field($0)!.column) }
            if insertionOrderForTies { ordering.insert("base.rowid" + (descending ? " DESC" : " ASC"),at:0) }
            var orderField: NativeSchema.Field?; var orderColumn: String?
            if let related = relatedSort {
                let target = try schema.model(related.model)
                guard target.primaryKey == [related.foreign], let local = model.field(related.local), let foreign = target.field(related.foreign), let field = target.field(related.field) else { throw NativeDBError.message("関連先の並べ替え項目が不正です。") }
                orderField = field
                orderColumn = "(SELECT related.\(quoted(field.column)) FROM \(quoted(related.model)) related WHERE related.\(quoted(foreign.column))=base.\(quoted(local.column)))"
            } else if let sort {
                guard let field = model.field(sort) else { throw NativeDBError.message("並べ替え項目が不正です。") }
                orderField = field; orderColumn = "base." + quoted(field.column)
            }
            if let field = orderField, let column = orderColumn {
                let expression: String
                if field.type == "DateTime" { expression = "julianday(\(column))" }
                else if field.type == "Decimal" { expression = column + " COLLATE native_decimal" }
                else { expression = column + (localizedSort ? " COLLATE native_japanese" : " COLLATE NOCASE") }
                ordering.insert(expression + (descending ? " DESC" : " ASC"), at: 0)
                ordering.insert(column + " IS NULL" + (nullsFirst ? " DESC" : " ASC"), at: 0)
            }
            let rows = try query("SELECT \(fields.joined(separator: ",")) FROM \(quoted(name)) base\(filter) ORDER BY \(ordering.joined(separator: ",")) LIMIT ? OFFSET ?", bindings + [.integer(Int64(min(100,max(1,limit)))), .integer(Int64(max(0, offset)))])
            return (rows.map { record(model, $0) }, total)
        }
    }
    /// Source MCP lists return full scalar rows, sorted by createdAt/id DESC.
    /// Search is restricted to the caller's declared columns and intersects the
    /// existing access filter. LIKE wildcards retain the original Prisma API
    /// behavior; this is deliberately separate from literal UI search.
    func mcpPage(_ name: String, fields: [String], filter: RecordFilter, searchFields: [String] = [], query text: String? = nil, limit: Int, offset: Int, order: [(field: String, descending: Bool)] = [("createdAt", true), ("id", true)], includeDeleted:Bool=false, allowEmptyOrder:Bool=false) throws -> (rows: [NativeRecord], total: Int) {
        try synchronized {
            try Task.checkCancellation()
            let model = try schema.model(name)
            guard (1...100).contains(limit), offset >= 0, model.primaryKey == ["id"], allowEmptyOrder || !order.isEmpty, order.count <= 8,
                  order.allSatisfy({ model.field($0.field) != nil && model.field($0.field)?.array == false }),
                  fields.allSatisfy({ model.field($0) != nil }), searchFields.allSatisfy({ model.field($0)?.type == "String" }) else { throw NativeDBError.message("MCPの検索条件が不正です。") }
            if !mcpLowerRegistered {
                guard sqlite3_create_function_v2(connection, "native_mcp_lower", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, args in
                    guard let context, let args, sqlite3_value_type(args[0]) != SQLITE_NULL, let bytes = sqlite3_value_text(args[0]) else { sqlite3_result_null(context); return }
                    let text = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(args[0]))), as: UTF8.self).lowercased()
                    text.withCString { sqlite3_result_text(context, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                }, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(error) }
                mcpLowerRegistered = true
            }
            var counter = 0
            let scope = try compile(filter, model: model, alias: "base", counter: &counter)
            var clauses = [scope.0], bindings = scope.1
            if !includeDeleted,let deleted = model.field("deletedAt") { clauses.append("base." + quoted(deleted.column) + " IS NULL") }
            if let text {
                guard !searchFields.isEmpty, !text.contains("\0") else { throw NativeDBError.message("MCPの検索文字が不正です。") }
                clauses.append("(" + searchFields.map { "native_mcp_lower(base." + quoted(model.field($0)!.column) + ") LIKE native_mcp_lower(?) ESCAPE '\\'" }.joined(separator: " OR ") + ")")
                bindings += searchFields.map { _ in .text("%" + text + "%") }
            }
            let predicate = " WHERE " + clauses.joined(separator: " AND ")
            let totalValue = try query("SELECT count(*) AS count FROM \(quoted(name)) base\(predicate)", bindings).first?["count"]
            let total: Int = { if case let .integer(value) = totalValue { return Int(value) }; return 0 }()
            try Task.checkCancellation()
            let projection = Array(Set(fields + ["id"])).sorted().map { "base." + quoted(model.field($0)!.column) + " AS " + quoted($0) } + ["base._native_revision"]
            let ordering = order.map { term -> String in
                let field = model.field(term.field)!, column = "base." + quoted(field.column)
                let expression = field.type == "DateTime" ? "julianday(\(column))" : column
                // PostgreSQL defaults: ascending nulls last, descending first.
                return expression + (term.descending ? " DESC NULLS FIRST" : " ASC NULLS LAST")
            }.joined(separator: ",")
            let orderClause=ordering.isEmpty ? "":" ORDER BY "+ordering
            let rows = try query("SELECT \(projection.joined(separator: ",")) FROM \(quoted(name)) base\(predicate)\(orderClause) LIMIT ? OFFSET ?", bindings + [.integer(Int64(limit)), .integer(Int64(offset))])
            return (rows.map { record(model, $0) }, total)
        }
    }
    /// Bounded primary-key iteration for background indexing and vector search.
    /// Unlike page(), this does not recount or OFFSET-scan the preceding records.
    /// Optional BLOB bounds are enforced by SQLite before copying into Swift;
    /// an oversized or wrongly typed BLOB is returned as null for diagnosis.
    private func withText<T>(_ table: String, column: String, rowid: Int64, _ action: (inout NativeSQLiteTextIterator) throws -> T) throws -> T {
        var blob: OpaquePointer?
        guard sqlite3_blob_open(connection, "main", table, column, rowid, 0, &blob) == SQLITE_OK, let blob else { throw NativeDBError.conflict }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16_384)
        defer { buffer.deallocate(); sqlite3_blob_close(blob) }
        var reader = NativeSQLiteTextIterator(blob: blob, buffer: buffer, size: sqlite3_blob_bytes(blob))
        let value = try action(&reader)
        guard reader.status == SQLITE_OK else { throw NativeDBError.conflict }
        return value
    }
    func keywordIDs(_ name: String, fields: [String], query term: String, filter: RecordFilter, limit: Int = 10, validate: () throws -> Void = {}) throws -> [String] {
        guard (1...100).contains(limit) else { throw NativeDBError.message("文章の検索件数が不正です。") }
        var found: [String] = []
        try scanTextMatches(name, fields: fields, query: term, filter: filter, validate: validate) { id in
            found.append(id); return found.count < limit
        }
        return found
    }
    /// Visits bounded ID pages and reads each candidate's full text incrementally.
    /// Returning false stops scanning without retaining the remaining identities.
    private func scanTextMatches(_ name: String, fields: [String], query term: String, filter: RecordFilter, validate: () throws -> Void, visit: (String) throws -> Bool) throws {
        let model = try schema.model(name)
        guard model.primaryKey.count == 1, let key = model.primaryKey.first, let primary = model.field(key), primary.type == "String", !fields.isEmpty,
              fields.allSatisfy({ model.field($0)?.type == "String" && model.field($0)?.array != true }) else { throw NativeDBError.message("文章の検索項目が不正です。") }
        let needle = NativeTextNeedle(term); var after: String?, stopped = false
        while !stopped {
            let count = try synchronized { () -> Int in
                try Task.checkCancellation(); try validate()
                var aliases = 0; let scope = try compile(filter, model: model, alias: "base", counter: &aliases)
                var clauses = [scope.0], bindings = scope.1
                if let deleted = model.field("deletedAt") { clauses.append("base." + quoted(deleted.column) + " IS NULL") }
                if let after { clauses.append("base." + quoted(primary.column) + ">?"); bindings.append(.text(after)) }
                let types = fields.enumerated().map { "typeof(base." + quoted(model.field($0.element)!.column) + ") AS _native_type\($0.offset)" }
                let rows = try self.query("SELECT base.rowid AS _native_rowid,base.\(quoted(primary.column)) AS id,\(types.joined(separator: ",")) FROM \(quoted(name)) base WHERE \(clauses.joined(separator: " AND ")) ORDER BY base.\(quoted(primary.column)) LIMIT 100", bindings)
                for row in rows {
                    try Task.checkCancellation()
                    guard case let .integer(rowid) = row["_native_rowid"] else { throw NativeDBError.conflict }
                    for (i, field) in fields.enumerated() where row["_native_type\(i)"] == .text("text") {
                        let matched = try withText(name, column: model.field(field)!.column, rowid: rowid) { needle.contains(&$0) }
                        try Task.checkCancellation()
                        if matched { stopped = try !visit(row["id"]!.string); break }
                    }
                    if stopped { break }
                }
                after = rows.last?["id"]?.string; return rows.count
            }
            if count < 100 { break }
        }
        try Task.checkCancellation(); try validate()
    }
    /// Exact full-field matching and count without a Swift array of all matches.
    /// SQLite's file-backed temporary table owns the IDs; only the requested page
    /// and bounded display prefixes are returned to the reference picker.
    func textSearchPage(_ name: String, field: String, query term: String, filter: RecordFilter, offset: Int = 0, limit: Int = 100, validate: () throws -> Void = {}) throws -> (rows: [NativeRecord], total: Int) {
        guard offset >= 0, (1...100).contains(limit) else { throw NativeDBError.message("検索のページ番号が不正です。") }
        return try transaction {
            try Task.checkCancellation(); try validate()
            let model = try schema.model(name)
            guard model.primaryKey == ["id"], model.field("id")?.type == "String", let textField = model.field(field), textField.type == "String", !textField.array else { throw NativeDBError.message("文章の検索項目が不正です。") }
            let temporary = quoted("native_text_matches_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
            try execute("CREATE TEMP TABLE \(temporary)(id TEXT PRIMARY KEY)")
            defer { try? execute("DROP TABLE \(temporary)") }
            sqlite3_progress_handler(connection, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
            defer { sqlite3_progress_handler(connection, 0, nil, nil) }
            if term.isEmpty {
                var aliases = 0; let scope = try compile(filter, model: model, alias: "base", counter: &aliases)
                let deleted = model.field("deletedAt").map { " AND base." + quoted($0.column) + " IS NULL" } ?? ""
                try run("INSERT INTO \(temporary) SELECT base.\(quoted(model.field("id")!.column)) FROM \(quoted(name)) base WHERE \(scope.0)\(deleted)", scope.1)
            } else {
                try scanTextMatches(name, fields: [field], query: term, filter: filter, validate: validate) { id in
                    try self.run("INSERT INTO \(temporary) VALUES(?)", [.text(id)]); return true
                }
            }
            try Task.checkCancellation(); try validate()
            let total = Int(try query("SELECT COUNT(*) AS total FROM \(temporary)").first!["total"]!.string)!
            let column = "base." + quoted(textField.column)
            let ids = try query("SELECT matches.id FROM \(temporary) matches JOIN \(quoted(name)) base ON base.\(quoted(model.field("id")!.column))=matches.id ORDER BY \(column) IS NULL,\(column) COLLATE NOCASE,matches.id LIMIT ? OFFSET ?", [.integer(Int64(limit)), .integer(Int64(offset))]).map { $0["id"]!.string }
            if ids.isEmpty { return ([], total) }
            let rows = try keysetPage(name, fields: [field], filter: .every([filter, .any(ids.map { .equal("id", .text($0)) })]), maximumTextCharacters: [field: 512])
            let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"].string, $0) })
            try Task.checkCancellation(); try validate()
            return (ids.compactMap { indexed[$0] }, total)
        }
    }
    func keysetPage(_ name: String, fields requested: [String], after: String? = nil, filter: RecordFilter = .all, includeDeleted: Bool = false, search: String = "", limit: Int = 100, maximumBlobBytes: [String: Int] = [:], maximumTextCharacters: [String: Int] = [:]) throws -> [NativeRecord] {
        try synchronized {
            let model = try schema.model(name)
            guard model.primaryKey.count == 1, let key = model.primaryKey.first, let primary = model.field(key), primary.type == "String",
                  requested.allSatisfy({ model.field($0) != nil }), (1...100).contains(limit) else {
                throw NativeDBError.message("順次読み込みの指定が不正です。")
            }
            for (name, maximum) in maximumBlobBytes {
                guard requested.contains(name), let field = model.field(name), maximum > 0,
                      field.type == "Bytes" || field.type.hasPrefix("Unsupported(\"vector") else { throw NativeDBError.message("読み込みサイズの指定が不正です。") }
            }
            for (name, maximum) in maximumTextCharacters {
                guard requested.contains(name), model.field(name)?.type == "String", model.field(name)?.array != true, (1...32000).contains(maximum) else { throw NativeDBError.message("文章の読み込みサイズが不正です。") }
            }
            var aliases = 0
            let scope = try compile(filter, model: model, alias: "base", counter: &aliases)
            var clauses = [scope.0], bindings = scope.1
            if !includeDeleted, let deleted = model.field("deletedAt") { clauses.append("base." + quoted(deleted.column) + " IS NULL") }
            if let after { clauses.append("base." + quoted(primary.column) + ">?"); bindings.append(.text(after)) }
            if !search.isEmpty {
                let term = Self.normalized(search).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                clauses.append("base._native_search LIKE ? ESCAPE '\\'"); bindings.append(.text("%\(term)%"))
            }
            let names = Array(Set(requested + [key])).sorted()
            var fields = names.map { name -> String in
                let column = "base." + quoted(model.field(name)!.column)
                if let maximum = maximumBlobBytes[name] { return "CASE WHEN typeof(\(column))='blob' AND length(\(column))<=\(maximum) THEN \(column) ELSE NULL END AS " + quoted(name) }
                if maximumTextCharacters[name] != nil { return "NULL AS " + quoted(name) }
                return column + " AS " + quoted(name)
            } + ["base._native_revision"]
            let capped = maximumTextCharacters.keys.sorted()
            if !capped.isEmpty {
                fields.append("base.rowid AS _native_rowid")
                fields += capped.enumerated().map { "typeof(base." + quoted(model.field($0.element)!.column) + ") AS _native_type\($0.offset)" }
            }
            var rows = try query("SELECT \(fields.joined(separator: ",")) FROM \(quoted(name)) base WHERE \(clauses.joined(separator: " AND ")) ORDER BY base.\(quoted(primary.column)) LIMIT ?", bindings + [.integer(Int64(limit))])
            for i in rows.indices where !capped.isEmpty {
                guard case let .integer(rowid) = rows[i]["_native_rowid"] else { throw NativeDBError.conflict }
                for (j, field) in capped.enumerated() where rows[i]["_native_type\(j)"] == .text("text") {
                    rows[i][field] = try withText(name, column: model.field(field)!.column, rowid: rowid) { reader in
                        var parser = Unicode.UTF8(), text = ""
                        for _ in 0..<maximumTextCharacters[field]! {
                            switch parser.decode(&reader) { case .emptyInput: return .text(text); case .error: text.unicodeScalars.append("\u{fffd}"); case let .scalarValue(scalar): text.unicodeScalars.append(scalar) }
                        }
                        return .text(text)
                    }
                }
            }
            return rows.map { record(model, $0) }
        }
    }
    /// A disk-backed temporary order snapshot avoids retaining every line or losing rows
    /// while normalizing legacy duplicate positions. Ordinary moves update only two rows.
    func moveOrderedLine(_ record: NativeRecord, parentField: String, parentID: SQLValue, direction: Int, actor: String) throws -> Bool { try requireWritable();
        return try transaction {
            guard ["crm_OpportunityLineItems":"opportunityId","crm_ContractLineItems":"contractId"][record.model] == parentField,
                  [-1,1].contains(direction) else { throw NativeDBError.message("並べ替えの指定が不正です。") }
            let name = "native_order_" + UUID().uuidString.replacingOccurrences(of:"-",with:"")
            let snapshot = quoted(name)
            try execute("CREATE TEMP TABLE \(snapshot)(id TEXT PRIMARY KEY,position INTEGER NOT NULL)")
            defer { try? execute("DROP TABLE \(snapshot)") }
            _ = try run("INSERT INTO \(snapshot) SELECT id,ROW_NUMBER() OVER(ORDER BY sort_order,id)-1 FROM \(quoted(record.model)) WHERE \(quoted(parentField))=?",[parentID])
            guard case let .integer(position) = try query("SELECT position FROM \(snapshot) WHERE id=?",[record["id"]]).first?["position"] else { throw NativeDBError.conflict }
            let destination = position + Int64(direction)
            guard try !query("SELECT id FROM \(snapshot) WHERE position=?",[.integer(destination)]).isEmpty else { return false }
            var offset: Int64 = 0
            while true {
                let rows = try query("SELECT id,position FROM \(snapshot) ORDER BY position LIMIT 100 OFFSET ?",[.integer(offset)])
                for row in rows {
                    try autoreleasepool {
                        guard let id = row["id"], case let .integer(p) = row["position"], let current = try get(record.model,key:["id":id]) else { throw NativeDBError.conflict }
                        let next = p == position ? destination : p == destination ? position : p
                        if current["sort_order"] != .integer(next) { _ = try update(current,changes:["sort_order":.integer(next)],actor:actor,action:"reorder") }
                    }
                }
                offset += Int64(rows.count); if rows.count < 100 { break }
            }
            return true
        }
    }
    func remove(_ record: NativeRecord, actor: String, action: String = "unlink") throws { try requireWritable();
        try transaction {
            let model = try schema.model(record.model); let (whereSQL, bindings) = try keyClause(model, key(for: record))
            guard let before=try get(model.name,key:key(for:record)),before.revision==record.revision else { throw NativeDBError.conflict }
            if !NativeRecordMutationScope.bypassHooks { _ = try beforeRecordWrite?(model.name,"delete",before,[:],actor) }
            guard try run("DELETE FROM \(quoted(model.name)) WHERE \(whereSQL) AND _native_revision=?", bindings + [.integer(record.revision)]) == 1 else { throw NativeDBError.conflict }
            try audit(before: record, after: record, action: action, actor: actor)
            if !NativeRecordMutationScope.bypassHooks { afterRecordWrite?(model.name,"delete",before,nil,[:],actor) }
        }
    }
    /// These seven nullable dictionary relations use ON DELETE SET NULL in
    /// the original PostgreSQL migrations. Native schema FKs are deliberately
    /// restrictive, so mirror that cascade here without pretending each child
    /// was saved: business timestamps, audit, and save events remain untouched.
    /// Incrementing native revisions still invalidates retained child editors.
    func deleteCRMConfiguration(_ record: NativeRecord, actor: String) throws { try requireWritable();
        let references: [String: (model: String, field: String)] = [
            "crm_Industry_Type": ("crm_Accounts", "industry"),
            "crm_Contact_Types": ("crm_Contacts", "contact_type_id"),
            "crm_Lead_Sources": ("crm_Leads", "lead_source_id"),
            "crm_Lead_Statuses": ("crm_Leads", "lead_status_id"),
            "crm_Lead_Types": ("crm_Leads", "lead_type_id"),
            "crm_Opportunities_Type": ("crm_Opportunities", "type"),
            "crm_Opportunities_Sales_Stages": ("crm_Opportunities", "sales_stage")
        ]
        guard let reference = references[record.model] else { throw NativeDBError.message("CRMの選択肢だけを削除できます。") }
        try transaction {
            guard let current = try get(record.model, key: key(for: record)), current.revision == record.revision else { throw NativeDBError.conflict }
            let model = try schema.model(reference.model)
            let column = quoted(model.field(reference.field)!.column)
            while true {
                let rows = try query("SELECT id FROM \(quoted(reference.model)) WHERE \(column)=? ORDER BY id LIMIT 100", [current["id"]])
                if rows.isEmpty { break }
                for row in rows { try autoreleasepool {
                    try Task.checkCancellation()
                    guard let id = row["id"], let child = try get(reference.model, key: ["id": id]) else { throw NativeDBError.conflict }
                    var values = child.values; values[reference.field] = .null
                    guard try run("UPDATE \(quoted(reference.model)) SET \(column)=NULL,_native_search=?,_native_revision=_native_revision+1 WHERE id=? AND _native_revision=?",
                                  [.text(searchKey(values, model: reference.model)), id, .integer(child.revision)]) == 1 else { throw NativeDBError.conflict }
                } }
            }
            try remove(current, actor: actor, action: "delete")
        }
    }
    /// Users-only deletion. Prisma defaults optional relations to SetNull, while
    /// the legacy SQLite DDL leaves unspecified actions as NO ACTION. Explicit
    /// SetNull relations are included too, so native revisions/search stay valid.
    /// Derived from schema.prisma's Users relations; required Restrict and all
    /// explicit Cascade relations remain enforced by the SQLite foreign keys.
    static let administrativeUserSetNullReferences: [(String, String)] = [
        ("crm_Accounts", "assigned_to"), ("crm_Accounts", "partnerUserId"),
        ("crm_Leads", "assigned_to"), ("crm_Contact_Enrichment", "triggeredBy"),
        ("crm_Target_Enrichment", "triggeredBy"), ("crm_Opportunities", "assigned_to"),
        ("crm_Opportunities", "createdBy"), ("crm_campaigns", "created_by"),
        ("crm_campaign_templates", "created_by"), ("crm_Contacts", "assigned_to"),
        ("crm_Contacts", "createdBy"), ("crm_Contracts", "assigned_to"),
        ("crm_Activities", "createdBy"), ("crm_Activities", "updatedBy"),
        ("Documents", "created_by_user"), ("Documents", "assigned_user"),
        ("Tasks", "user"), ("crm_Accounts_Tasks", "user"),
        ("crm_AuditLog", "userId"), ("crm_Targets", "created_by"),
        ("crm_TargetLists", "created_by"), ("crm_Products", "createdBy"), ("crm_Orders", "ownerId")
    ]
    func deleteAdministrativeUser(_ record: NativeRecord, actor: String) throws { try requireWritable();
        guard record.model == "Users" else { throw NativeDBError.message("利用者だけを削除できます。") }
        try transaction {
            guard let current = try get("Users", key: key(for: record)), current.revision == record.revision else { throw NativeDBError.conflict }
            for (name, field) in Self.administrativeUserSetNullReferences {
                let model = try schema.model(name)
                guard let definition = model.field(field), model.primaryKey == ["id"] else { throw NativeDBError.conflict }
                let column = quoted(definition.column)
                while true {
                    let rows = try query("SELECT id FROM \(quoted(name)) WHERE \(column)=? ORDER BY id LIMIT 100", [current["id"]])
                    if rows.isEmpty { break }
                    for row in rows { try autoreleasepool {
                        try Task.checkCancellation()
                        guard let id = row["id"], let child = try get(name, key: ["id": id]) else { throw NativeDBError.conflict }
                        var values = child.values; values[field] = .null
                        guard try run("UPDATE \(quoted(name)) SET \(column)=NULL,_native_search=?,_native_revision=_native_revision+1 WHERE id=? AND _native_revision=?",
                                      [.text(searchKey(values, model: name)), id, .integer(child.revision)]) == 1 else { throw NativeDBError.conflict }
                    } }
                }
            }
            try remove(current, actor: actor, action: "user_delete")
        }
    }
    /// Project order stays in SQLite. At most 100 IDs/revisions cross into Swift
    /// while legacy duplicate/null positions are normalized transactionally.
    func nextProjectPosition(_ model: String, parentID: SQLValue) throws -> Int64 {
        try synchronized {
            guard let field = ["Sections":"board","Tasks":"section"][model] else { throw NativeDBError.message("並び順の種類が不正です。") }
            let value = try query("SELECT MAX(position) AS last FROM \(quoted(model)) WHERE \(quoted(field))=?",[parentID]).first?["last"] ?? .null
            guard value != .null else { return 0 }
            guard let last = Int64(value.string), last < Int64.max else { throw NativeDBError.message("並び順の上限に達しました。") }
            return max(0,last+1)
        }
    }
    func reorderProjectItem(_ record: NativeRecord, direction: Int, actor: String) throws -> Bool { try requireWritable();
        return try transaction {
            guard let field = ["Sections":"board","Tasks":"section"][record.model], [-1,1].contains(direction),
                  let current = try get(record.model,key:["id":record["id"]]), current.revision == record.revision else { throw NativeDBError.conflict }
            let descending = record.model == "Tasks"
            let snapshot = quoted("native_project_order_"+UUID().uuidString.replacingOccurrences(of:"-",with:""))
            try execute("CREATE TEMP TABLE \(snapshot)(id TEXT PRIMARY KEY,ordinal INTEGER NOT NULL)")
            defer { try? execute("DROP TABLE \(snapshot)") }
            try run("INSERT INTO \(snapshot) SELECT id,ROW_NUMBER() OVER(ORDER BY position \(descending ? "DESC" : "ASC"),id)-1 FROM \(quoted(record.model)) WHERE \(quoted(field))=?",[current[field]])
            guard case let .integer(position) = try query("SELECT ordinal FROM \(snapshot) WHERE id=?",[record["id"]]).first?["ordinal"],
                  case let .integer(count) = try query("SELECT count(*) AS n FROM \(snapshot)").first?["n"] else { throw NativeDBError.conflict }
            let destination = position+Int64(direction)
            guard destination >= 0, destination < count else { return false }
            var offset: Int64 = 0
            while true {
                let rows = try query("SELECT id,ordinal FROM \(snapshot) ORDER BY ordinal LIMIT 100 OFFSET ?",[.integer(offset)])
                for row in rows { try autoreleasepool {
                    guard let id = row["id"], case let .integer(p) = row["ordinal"], let item = try get(record.model,key:["id":id]) else { throw NativeDBError.conflict }
                    let next = p == position ? destination : p == destination ? position : p
                    let stored = descending ? count-1-next : next
                    if item["position"] != .integer(stored) { _ = try update(item,changes:["position":.integer(stored)],actor:actor,action:"reorder") }
                } }
                offset += Int64(rows.count); if rows.count < 100 { break }
            }
            return true
        }
    }
    /// Work on a disk-backed identity/order snapshot. No array of the whole
    /// board is decoded, and legacy duplicate/gapped ranks are normalized.
    func placeProjectTask(_ record: NativeRecord, to destination: SQLValue, before anchor: SQLValue?, actor: String) throws -> Bool { try requireWritable();
        return try transaction {
            guard record.model == "Tasks", let current = try get("Tasks",key:["id":record["id"]]), current.revision == record.revision else { throw NativeDBError.conflict }
            let snapshot = quoted("native_kanban_"+UUID().uuidString.replacingOccurrences(of:"-",with:""))
            try execute("CREATE TEMP TABLE \(snapshot)(id TEXT PRIMARY KEY,section TEXT NOT NULL,ordinal INTEGER NOT NULL)")
            defer { try? execute("DROP TABLE \(snapshot)") }
            try run("INSERT INTO \(snapshot) SELECT id,section,ROW_NUMBER() OVER(PARTITION BY section ORDER BY position DESC,id)-1 FROM Tasks WHERE section IN (?,?) AND id<>?",[current["section"],destination,current["id"]])
            let index: SQLValue
            if let anchor {
                guard let row = try query("SELECT ordinal FROM \(snapshot) WHERE id=? AND section=?",[anchor,destination]).first else { throw NativeDBError.conflict }
                index = row["ordinal"]!
            } else { index = try query("SELECT count(*) AS n FROM \(snapshot) WHERE section=?",[destination]).first!["n"]! }
            // Already immediately before the anchor (or last) means no writes.
            if current["section"] == destination {
                let original = try query("SELECT count(*) AS n FROM Tasks WHERE section=? AND (position>? OR (position=? AND id<?))",[destination,current["position"],current["position"],current["id"]]).first!["n"]!
                if original == index { return false }
            }
            try run("UPDATE \(snapshot) SET ordinal=ordinal+1 WHERE section=? AND ordinal>=?",[destination,index])
            try run("INSERT INTO \(snapshot) VALUES(?,?,?)",[current["id"],destination,index])
            var offset: Int64 = 0
            while true {
                let rows = try query("SELECT id,section,ordinal,COUNT(*) OVER(PARTITION BY section) AS n FROM \(snapshot) ORDER BY section,ordinal LIMIT 100 OFFSET ?",[.integer(offset)])
                for row in rows { try autoreleasepool {
                    guard let id = row["id"], let section = row["section"], case let .integer(ordinal) = row["ordinal"], case let .integer(count) = row["n"], let item = try get("Tasks",key:["id":id]) else { throw NativeDBError.conflict }
                    let position = SQLValue.integer(count-1-ordinal)
                    if item["position"] != position || item["section"] != section {
                        _ = try update(item,changes:["position":position,"section":section,"updatedBy":.text(actor)],actor:actor,action:"reorder")
                    }
                } }
                offset += Int64(rows.count); if rows.count < 100 { break }
            }
            return true
        }
    }
    func history(_ record: NativeRecord, offset: Int = 0) throws -> [[String: SQLValue]] {
        try synchronized {
            let key = try key(for: record).mapValues(\.json)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: key, options: [.sortedKeys]), as: UTF8.self)
            return try query("SELECT action,actor,created_at,before_json,after_json FROM native_audit WHERE model=? AND record_key=? ORDER BY rowid DESC LIMIT 100 OFFSET ?", [.text(record.model), .text(json), .integer(Int64(max(0, offset)))])
        }
    }
    private func audit(before: NativeRecord?, after: NativeRecord, action: String, actor: String) throws {
        let key = try key(for: after)
        func json(_ values: [String: SQLValue]) throws -> String {
            let hiddenModel = ["ApiKeys", "ApiToken", "Account", "Session", "Verification", "EmailAccount", "CalendarConnection"].contains(after.model)
            let fields = values.keys.filter { !secret($0) && (!hiddenModel || key[$0] != nil) }.sorted {
                $0.compare($1,options:[.numeric,.caseInsensitive,.forcedOrdering],locale:NSLocale.system) == .orderedAscending
            }
            // Audit values are a flat SQLValue dictionary. Keep large text as
            // String slices and allocate the final JSON once; do not bridge all
            // text through Foundation's Any/Data representation and back.
            let lowEscapes=(0..<32).map{String(format:"\\u%04x",$0)}
            func escape(_ byte:UInt8)->String? {
                switch byte {
                case 34:return "\\\""
                case 92:return "\\\\"
                case 47:return "\\/"
                case 8:return "\\b"
                case 9:return "\\t"
                case 10:return "\\n"
                case 12:return "\\f"
                case 13:return "\\r"
                case 0..<32:return lowEscapes[Int(byte)]
                default:return nil
                }
            }
            func add(_ left:Int,_ right:Int)throws->Int {let (value,overflow)=left.addingReportingOverflow(right);guard !overflow else{throw NativeDBError.message("監査データを保存するための領域が不足しています。")};return value}
            func quotedSize(_ text:String)throws->Int {
                var size=try add(text.utf8.count,2)
                for byte in text.utf8 {if let escaped=escape(byte){size=try add(size,escaped.utf8.count-1)}}
                return size
            }
            // Only numeric/null tokens or the original base64 string are
            // prepared separately. Non-finite reals fail exactly as before.
            var rendered:[String:String]=[:],capacity=2
            for (index,field) in fields.enumerated() {
                capacity=try add(capacity,try add(quotedSize(field),index==0 ? 1:2))
                let size:Int
                switch values[field]! {
                case .null:rendered[field]="null";size=4
                case let .integer(value):let token=String(value);rendered[field]=token;size=token.utf8.count
                case let .real(value):guard value.isFinite else{throw NativeDBError.message("数値の形式が不正です。")};let token=String(decoding:try JSONSerialization.data(withJSONObject:value,options:.fragmentsAllowed),as:UTF8.self);rendered[field]=token;size=token.utf8.count
                case let .text(text):size=try quotedSize(text)
                case let .blob(data):let text=data.base64EncodedString();rendered[field]=text;size=try add(11,quotedSize(text))
                }
                capacity=try add(capacity,size)
            }
            var output=String();output.reserveCapacity(capacity)
            func appendQuoted(_ text:String) {
                output.append("\"");var start=text.startIndex
                for index in text.utf8.indices {
                    guard let escaped=escape(text.utf8[index]) else{continue}
                    output.append(contentsOf:text[start..<index]);output.append(escaped);start=text.utf8.index(after:index)
                }
                output.append(contentsOf:text[start...]);output.append("\"")
            }
            output.append("{")
            for (index,field) in fields.enumerated() {
                if index>0{output.append(",")};appendQuoted(field);output.append(":")
                switch values[field]! {
                case let .text(text):appendQuoted(text)
                case .blob:output.append("{\"base64\":");appendQuoted(rendered[field]!);output.append("}")
                default:output.append(rendered[field]!)
                }
            }
            output.append("}");return output
        }
        try run("INSERT INTO native_audit VALUES(?,?,?,?,?,?,?,?)", [.text(UUID().uuidString.lowercased()), .text(after.model), .text(try json(key)), .text(action), .text(actor), .text(Self.now()), before == nil ? .null : .text(try json(before!.values)), .text(try json(after.values))])
    }
    func auditCount(_ model: String) throws -> Int {
        try synchronized { if case let .integer(count) = try query("SELECT count(*) AS count FROM native_audit WHERE model=?", [.text(model)]).first?["count"] { return Int(count) }; return 0 }
    }
    /// Usage metadata is not a user edit. Keep it monotonic without generating
    /// unbounded audit history, but advance the revision to fence stale writers.
    func touchAPIToken(id: String, at timestamp: String) throws { try requireWritable();
        try synchronized {
            _ = try run("UPDATE ApiToken SET lastUsedAt=?,_native_revision=_native_revision+1 WHERE id=? AND (lastUsedAt IS NULL OR julianday(lastUsedAt)<julianday(?))", [.text(timestamp), .text(id), .text(timestamp)])
        }
    }
    /// Browser-session refresh is authentication metadata. Keep the caller's
    /// verified clock and avoid both wall-clock @updatedAt substitution and
    /// auditing a session's credential. A stale snapshot cannot renew a token.
    func refreshBrowserSession(_ expected: NativeRecord, expiresAt: String, updatedAt: String) throws -> NativeRecord? { try requireWritable();
        return try transaction {
            guard expected.model == "Session", case let .text(id) = expected["id"], !id.isEmpty,
                  expected.revision > 0, expected.revision < Int64.max else { throw NativeDBError.conflict }
            guard try run("UPDATE Session SET expiresAt=?,updatedAt=?,_native_revision=_native_revision+1 WHERE id=? AND _native_revision=?", [.text(expiresAt), .text(updatedAt), .text(id), .integer(expected.revision)]) == 1 else { return nil }
            return try get("Session", key: ["id": .text(id)])
        }
    }
    /// The resolver verifies expiry before calling this. Match the exact row
    /// it inspected so a concurrent renewal or replacement survives cleanup.
    func deleteExpiredBrowserSession(_ expected: NativeRecord) throws { try requireWritable();
        try transaction {
            guard expected.model == "Session", case let .text(id) = expected["id"], !id.isEmpty,
                  expected.revision > 0 else { throw NativeDBError.conflict }
            _ = try run("DELETE FROM Session WHERE id=? AND _native_revision=?", [.text(id), .integer(expected.revision)])
        }
    }
    /// Snapshot only IDs/revisions inside SQLite's disk-backed temporary store.
    /// No list of all target contacts is materialized in the app while the agent
    /// runs. The next attempt takes a fresh snapshot after a restart or retry.
    func snapshotTargetContacts(_ targetID: String) throws -> String {
        try transaction {
            try execute("CREATE TEMP TABLE IF NOT EXISTS native_target_contact_snapshot(snapshot_id TEXT NOT NULL,id TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(snapshot_id,id))")
            let id = UUID().uuidString.lowercased()
            try run("INSERT INTO native_target_contact_snapshot SELECT ?,id,_native_revision FROM crm_Target_Contact WHERE targetId=?", [.text(id), .text(targetID)])
            return id
        }
    }
    func targetContactSnapshotRevision(_ contactID: String, snapshot: String) throws -> Int64? {
        try synchronized {
            if case let .integer(value) = try query("SELECT revision FROM native_target_contact_snapshot WHERE snapshot_id=? AND id=?", [.text(snapshot), .text(contactID)]).first?["revision"] { return value }; return nil
        }
    }
    func discardTargetContactSnapshot(_ id: String) throws {
        try synchronized { _ = try run("DELETE FROM native_target_contact_snapshot WHERE snapshot_id=?", [.text(id)]) }
    }
    func isLatestTargetContactJob(_ expected: NativeJob) throws -> Bool {
        guard expected.event == "enrich/target.contact.run", let contactID = expected.payload["contactId"] else { return false }
        return try synchronized {
            try query("SELECT id FROM native_outbox WHERE event='enrich/target.contact.run' AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.contactId') END=? ORDER BY rowid DESC LIMIT 1", [.text(contactID)]).first?["id"] == .text(expected.id)
        }
    }
    func matchMailAddresses(_ name: String,addresses: [String],scope: RecordFilter,offset: Int) throws -> [NativeRecord] {
        try synchronized {
            guard ["crm_Contacts","crm_Accounts"].contains(name), !addresses.isEmpty, addresses.count <= 50 else { throw NativeDBError.conflict }
            let model = try schema.model(name); var aliases = 0
            let compiled = try compile(scope,model:model,alias:"base",counter:&aliases)
            let placeholders = Array(repeating:"?",count:addresses.count).joined(separator:",")
            let sql = "SELECT id,_native_revision FROM \(quoted(name)) base WHERE deletedAt IS NULL AND email COLLATE native_email IN (\(placeholders)) AND (\(compiled.0)) ORDER BY id LIMIT 100 OFFSET ?"
            return try query(sql,addresses.map(SQLValue.text)+compiled.1+[.integer(Int64(max(0,offset)))]).map{record(model,$0)}
        }
    }
    func storeMailSend(jobID: String,accountID: String,actorID: String,messageID: String,summary: String,mime: Data) throws { try requireWritable();
        try transaction {
            // Complete composer metadata can exceed the MIME header bound because
            // recipient arrays also retain display names. The payload-size bound
            // covers all currently admitted envelope/header combinations. Lists
            // use mailSendPreview rather than retaining 50 complete summaries.
            guard summary.utf8.count <= 33_554_432, !mime.isEmpty, mime.count <= 33_554_432,
                  let job = try job(id:jobID), job.event == "native.mail.send", job.status == "pending",
                  job.payload["actorID"] == actorID, job.payload["accountID"] == accountID else { throw NativeDBError.conflict }
            try run("INSERT INTO native_mail_sends(job_id,account_id,actor_id,message_id,summary,mime) VALUES(?,?,?,?,?,?)",[.text(jobID),.text(accountID),.text(actorID),.text(messageID),.text(summary),.blob(mime)])
        }
    }
    func mailSendPayload(_ id: String,includeMIME: Bool = true) throws -> [String:SQLValue]? {
        try synchronized { try query("SELECT job_id,account_id,actor_id,message_id,summary"+(includeMIME ? ",mime" : "")+" FROM native_mail_sends WHERE job_id=?",[.text(id)]).first }
    }
    /// List projection never reads the full recipient JSON into the app.
    /// Selected detail/delivery still use the immutable complete summary.
    func mailSendPreview(_ id:String) throws -> [String:SQLValue]? {
        try synchronized { try query("SELECT substr(json_extract(summary,'$.subject'),1,512) AS subject,substr(json_extract(summary,'$.from'),1,512) AS sender,substr(json_extract(summary,'$.to[0]'),1,512) AS recipient0,substr(json_extract(summary,'$.to[1]'),1,512) AS recipient1,substr(json_extract(summary,'$.to[2]'),1,512) AS recipient2,json_array_length(summary,'$.to') AS recipient_count FROM native_mail_sends WHERE job_id=? AND json_valid(summary)",[.text(id)]).first }
    }
    func releaseMailSendPayload(_ id: String) throws { try requireWritable(); _ = try synchronized { try run("UPDATE native_mail_sends SET mime=NULL WHERE job_id=?",[.text(id)]) } }
    func mailSendJobs(accountID: String,actorID: String,offset: Int = 0) throws -> [NativeJob] {
        guard offset >= 0 else { throw NativeDBError.conflict }
        return try synchronized { try query("SELECT o.* FROM native_outbox o JOIN native_mail_sends s ON s.job_id=o.id WHERE s.account_id=? AND s.actor_id=? AND o.event='native.mail.send' ORDER BY o.created_at DESC,o.rowid DESC LIMIT 50 OFFSET ?",[.text(accountID),.text(actorID),.integer(Int64(offset))]).map(job) }
    }
    func clearMailDeliveryStarted(_ expected: NativeJob) throws { try requireWritable();
        try transaction {
            let current = try requireJobLease(expected)
            guard current.event == "native.mail.send", current.result["smtpAccepted"] != "true" else { throw NativeDBError.conflict }
            try run("UPDATE native_outbox SET delivery_started_at=NULL WHERE id=?",[.text(current.id)])
        }
    }
    func retryMailSend(_ expected: NativeJob) throws { try requireWritable();
        try transaction {
            guard let current = try job(id:expected.id), current == expected, current.event == "native.mail.send",
                  try !personalPrerequisiteOldJob(current.id),
                  ["failed","retry"].contains(current.status), current.deliveryStartedAt == nil || current.result["smtpAccepted"] == "true" else { throw NativeDBError.conflict }
            try run("UPDATE native_outbox SET status='pending',next_run_at=NULL,last_error=NULL WHERE id=?",[.text(current.id)])
        }; notifyJobChange()
    }
    func reviewMailSend(_ expected: NativeJob,sent: Bool,now: Date) throws { try requireWritable()
        try transaction {
            guard try !personalPrerequisiteOldJob(expected.id) else{throw NativeDBError.message("復元した旧メールは、旧処理の確認画面から確認してください。")}
            try applyMailSendReview(expected,sent:sent,now:now)
        }
    }
    private func applyMailSendReview(_ expected:NativeJob,sent:Bool,now:Date)throws {
        try transaction {
            guard let current = try job(id:expected.id), current == expected, current.event == "native.mail.send", current.status == "needs_review", current.deliveryStartedAt != nil, current.result["smtpAccepted"] != "true" else { throw NativeDBError.conflict }
            var result = current.result; result["review"] = sent ? "sent" : "notSent"
            if sent { result["smtpAccepted"] = "true"; result["acceptedAt"] = ISO8601DateFormatter().string(from:now) }
            let json = String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET status=?,result=?,last_error=?,next_run_at=NULL,delivery_started_at=CASE WHEN ?=1 THEN delivery_started_at ELSE NULL END WHERE id=?",[.text(sent ? "pending" : "failed"),.text(json),.text(sent ? "送信済みとして保存します。" : "未送信と確認されました。必要なら再試行してください。"),.integer(sent ? 1 : 0),.text(current.id)])
        }; notifyJobChange()
    }
    func removeMailAccount(_ expected: NativeRecord,actor: String) throws { try requireWritable();
        try transaction {
            guard expected.model == "EmailAccount" else { throw NativeDBError.conflict }
            // Delete message-local state before the FK cascade, in the same
            // transaction, without materializing all message IDs in memory.
            for prefix in ["mail.location.","mail.bodyLoaded.","mail.body.job.","mail.body.foreground.","mail.body.absent.","mail.embed.job.","mail.embed.hash."] {
                try run("DELETE FROM native_metadata WHERE key IN (SELECT ? || id FROM Email WHERE emailAccountId=?)",[.text(prefix),expected["id"]])
            }
            let accountID = expected["id"].string
            for key in ["mail.tls."+accountID,"mail.sync.job."+accountID,"mail.sync.generation."+accountID,"mail.sync.error."+accountID,"mail.sync.cursor."+accountID+".INBOX","mail.sync.cursor."+accountID+".SENT"] {
                try run("DELETE FROM native_metadata WHERE key=?",[.text(key)])
            }
            try remove(expected,actor:actor,action:"delete-mail-account")
        }
    }
    func reserveDocumentProcessing(_ document: NativeRecord, jobID: String) throws { try requireWritable();
        try transaction {
            let id = document["id"], hash = try documentProcessingHash(document)
            if let old = try query("SELECT job_id,file_key,content_hash FROM native_document_processing WHERE document_id=?",[id]).first {
                if let previous = old["job_id"], previous != .text(jobID) {
                    try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL WHERE id=? AND status IN ('pending','retry','failed')",[previous])
                }
                if old["file_key"] != document["key"] || old["content_hash"] != hash {
                    try run("DELETE FROM native_document_processing WHERE document_id=?",[id])
                    try clearDocumentAIIndex(document["id"].string)
                }
            } else { try clearDocumentAIIndex(document["id"].string) }
            try run("DELETE FROM native_document_ai_work WHERE document_id=?", [id])
            try run("INSERT INTO native_document_processing(document_id,job_id,file_key,content_hash) VALUES(?,?,?,?) ON CONFLICT(document_id) DO UPDATE SET job_id=excluded.job_id,file_key=excluded.file_key,content_hash=excluded.content_hash",[id,.text(jobID),document["key"],hash])
        }
    }
    private func documentProcessingHash(_ document: NativeRecord) throws -> SQLValue {
        if let bucket = try metadata("document.storage.bucket"), let mapped = try documentObject(bucket:bucket,key:document["key"].string) { return .text(mapped.sha256) }
        return document["content_hash"]
    }
    func documentProcessingJob(_ document: NativeRecord) throws -> String? {
        try synchronized { try query("SELECT job_id FROM native_document_processing WHERE document_id=? AND file_key=? AND content_hash=?",[document["id"],document["key"],documentProcessingHash(document)]).first?["job_id"]?.string }
    }
    static let documentAIEvent = "document/enrich.requested"
    /// Called inside the extraction transaction after the text and source job
    /// completion are durable. A new reservation fences every older attempt.
    @discardableResult func enqueueDocumentAI(_ document: NativeRecord, actor: String, backfillID: String? = nil, now: Date = Date()) throws -> String? { try requireWritable();
        return try transaction {
            let sourceJob = try documentProcessingJob(document) ?? ""
            if !sourceJob.isEmpty, try job(id: sourceJob)?.status != "done" { return nil }
            guard try documentTextPage(document["id"].string).ready else { return nil }
            if let oldID = try documentAIJob(document["id"].string), let old = try job(id: oldID),
               ["pending", "running", "retry"].contains(old.status), old.payload["actorID"] == actor,
               old.payload["sourceJob"] == sourceJob, old.payload["key"] == document["key"].string,
               old.payload["contentHash"] == document["content_hash"].string, old.payload["backfillID"] == backfillID { return oldID }
            var payload = ["documentId": document["id"].string, "actorID": actor, "sourceJob": sourceJob, "key": document["key"].string, "contentHash": document["content_hash"].string]
            if let backfillID { payload["backfillID"] = backfillID }
            let id = try enqueue(Self.documentAIEvent, payload: payload, now: now)
            try run("DELETE FROM native_document_ai_work WHERE document_id=?", [document["id"]])
            try run("INSERT INTO native_document_ai_work(document_id,job_id) VALUES(?,?)", [document["id"], .text(id)])
            return id
        }
    }
    func documentAIJob(_ documentID: String) throws -> String? {
        try synchronized { try query("SELECT job_id FROM native_document_ai_work WHERE document_id=?", [.text(documentID)]).first?["job_id"]?.string }
    }
    func requireDocumentAI(_ job: NativeJob) throws {
        _ = try requireJobLease(job)
        guard let id = job.payload["documentId"], try documentAIJob(id) == job.id else { throw NativeDBError.conflict }
    }
    func clearDocumentAIStage(_ job: NativeJob) throws { try requireWritable();
        try transaction { try requireDocumentAI(job); try run("DELETE FROM native_document_ai_chunks WHERE job_id=?", [.text(job.id)]) }
    }
    func discardCancelledDocumentAI(_ job: NativeJob) throws { try requireWritable();
        try transaction {
            guard try self.job(id: job.id)?.status == "cancelled" else { throw NativeDBError.conflict }
            try run("DELETE FROM native_document_ai_work WHERE job_id=?", [.text(job.id)])
        }
    }
    func stageDocumentAI(_ job: NativeJob, index: Int, text: String, vector: Data, result: [String: String]) throws { try requireWritable();
        guard index >= 0, vector.count == 6144, text.utf16.count <= 32000 else { throw NativeDBError.message("文書の検索データの保存形式が不正です。") }
        try transaction {
            try requireDocumentAI(job)
            try run("INSERT INTO native_document_ai_chunks(job_id,chunk_index,chunk_text,embedding) VALUES(?,?,?,?) ON CONFLICT(job_id,chunk_index) DO UPDATE SET chunk_text=excluded.chunk_text,embedding=excluded.embedding", [.text(job.id), .integer(Int64(index)), .text(text), .blob(vector)])
            try recordJobResult(job, result: result)
        }
    }
    func stagedDocumentAICount(_ job: NativeJob) throws -> Int {
        try synchronized { Int(try query("SELECT COUNT(*) n FROM native_document_ai_chunks WHERE job_id=?", [.text(job.id)]).first?["n"]?.string ?? "0") ?? 0 }
    }
    func clearDocumentAIIndex(_ id: String) throws { try requireWritable();
        try transaction {
            try run("DELETE FROM crm_Embeddings_Documents WHERE document_id=?", [.text(id)])
            try run("DELETE FROM crm_Document_Chunks WHERE document_id=?", [.text(id)])
        }
    }
    /// Derived metadata is patched without materializing a legacy content_text
    /// body or copying it into an audit record. Rebuild the bounded search key.
    func patchDocumentAI(_ source: NativeRecord, changes: [String: SQLValue], actor: String) throws -> NativeRecord { try requireWritable();
        let allowed = Set(["summary", "document_system_type", "processing_status", "processing_error"])
        guard source.model == "Documents", !changes.isEmpty, Set(changes.keys).isSubset(of: allowed) else { throw NativeDBError.conflict }
        return try transaction {
            let fields = Array(allowed).sorted(), model = try schema.model("Documents")
            guard let before = try keysetPage("Documents", fields: fields, filter: .equal("id", source["id"]), includeDeleted: true, limit: 1).first, before.revision == source.revision else { throw NativeDBError.conflict }
            // Validate using the schema's ordinary field checks.
            for (name, value) in changes { _ = try validated(model.field(name)!, value: value) }
            let names = changes.keys.sorted()
            guard try run("UPDATE Documents SET \(names.map { quoted($0) + "=?" }.joined(separator: ",")),_native_revision=_native_revision+1 WHERE id=? AND _native_revision=?", names.map { changes[$0]! } + [source["id"], .integer(source.revision)]) == 1 else { throw NativeDBError.conflict }
            let columns = model.fields.map { field in
                let column = quoted(field.column)
                return "CASE WHEN typeof(\(column))='text' THEN substr(\(column),1,512) ELSE NULL END AS \(quoted(field.name))"
            }.joined(separator: ",")
            let values = try query("SELECT \(columns) FROM Documents WHERE id=?", [source["id"]]).first ?? [:]
            try run("UPDATE Documents SET _native_search=? WHERE id=?", [.text(searchKey(values, model: "Documents")), source["id"]])
            let after = NativeRecord(model: "Documents", values: before.values.merging(changes) { _, new in new }, revision: before.revision + 1)
            try audit(before: before, after: after, action: "document_ai", actor: actor)
            return after
        }
    }
    /// Publish all chunks and document metadata together; failed or cancelled
    /// generations never replace the previously searchable complete generation.
    func publishDocumentAI(_ job: NativeJob, source: NativeRecord, single: Bool, count: Int, hash: String, changes: [String: SQLValue], actor: String, result: [String: String], now: Date) throws { try requireWritable();
        try transaction {
            try requireDocumentAI(job)
            guard count > 0, (!single || count == 1), hash.count == 64,
                  let stats = try query("SELECT COUNT(*) n,MIN(chunk_index) lo,MAX(chunk_index) hi,MIN(length(embedding)) lowbytes,MAX(length(embedding)) highbytes FROM native_document_ai_chunks WHERE job_id=?", [.text(job.id)]).first,
                  stats["n"] == .integer(Int64(count)), stats["lo"] == .integer(0), stats["hi"] == .integer(Int64(count - 1)), stats["lowbytes"] == .integer(6144), stats["highbytes"] == .integer(6144) else { throw NativeDBError.conflict }
            try clearDocumentAIIndex(source["id"].string)
            let stamp: SQLValue = .text(ISO8601DateFormatter().string(from: now))
            if single {
                try run("INSERT INTO crm_Embeddings_Documents(id,document_id,embedding,content_hash,embedded_at) SELECT ?,?,embedding,?,? FROM native_document_ai_chunks WHERE job_id=? AND chunk_index=0", [.text(UUID().uuidString.lowercased()), source["id"], .text(hash), stamp, .text(job.id)])
            } else {
                let uuid = "lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(2)))||'-'||lower(hex(randomblob(6)))"
                try run("INSERT INTO crm_Document_Chunks(id,document_id,chunk_index,chunk_text,embedding,embedded_at) SELECT \(uuid),?,chunk_index,chunk_text,embedding,? FROM native_document_ai_chunks WHERE job_id=? ORDER BY chunk_index", [source["id"], stamp, .text(job.id)])
            }
            _ = try patchDocumentAI(source, changes: changes, actor: actor)
            try finishJob(job, result: result, now: now)
            try run("DELETE FROM native_document_ai_chunks WHERE job_id=?", [.text(job.id)])
        }
    }
    func archiveDocumentProcessing(from original: NativeRecord, to archive: NativeRecord) throws { try requireWritable();
        try transaction {
            try run("INSERT INTO native_document_processing(document_id,job_id,file_key,content_hash,text_bytes,text_parts,has_result,thumbnail,note) SELECT ?,job_id,?,?,text_bytes,text_parts,has_result,thumbnail,note FROM native_document_processing WHERE document_id=? AND file_key=? AND content_hash=?",[archive["id"],archive["key"],archive["content_hash"],original["id"],original["key"],documentProcessingHash(original)])
            try run("INSERT INTO native_document_text(document_id,part,content) SELECT ?,part,content FROM native_document_text WHERE document_id=? AND EXISTS(SELECT 1 FROM native_document_processing WHERE document_id=?)",[archive["id"],original["id"],archive["id"]])
        }
    }
    /// A producer streams one UTF-8 chunk from an anonymous disk spool. No
    /// whole-document String, JSON audit snapshot or normalized search copy.
    func saveDocumentProcessing(_ document: NativeRecord, jobID: String, textBytes: Int, thumbnail: Data?, note: String, produce: (_ append: (String) throws -> Void) throws -> Void) throws { try requireWritable();
        try transaction {
            guard try documentProcessingJob(document) == jobID else { throw NativeDBError.conflict }
            try run("DELETE FROM native_document_text WHERE document_id=?",[document["id"]])
            var part: Int64 = 0
            try produce { text in
                guard text.utf8.count <= 32771, !text.contains("\0") else { throw NativeDBError.message("抽出した本文の保存形式が不正です。") }
                try run("INSERT INTO native_document_text(document_id,part,content) VALUES(?,?,?)",[document["id"],.integer(part),.text(text)]); part += 1
            }
            try run("UPDATE native_document_processing SET text_bytes=?,text_parts=?,has_result=1,thumbnail=?,note=? WHERE document_id=?",[.integer(Int64(textBytes)),.integer(part),thumbnail.map(SQLValue.blob) ?? .null,.text(note),document["id"]])
        }
    }
    func documentTextPage(_ id: String, part: Int = 0, includeThumbnail: Bool = false) throws -> (text: String, parts: Int, bytes: Int64, thumbnail: Data?, note: String, ready: Bool) {
        try synchronized {
            let thumb = includeThumbnail ? "p.thumbnail" : "NULL AS thumbnail"
            if let row = try query("SELECT p.text_bytes,p.text_parts,p.has_result,p.note,\(thumb),t.content FROM native_document_processing p JOIN Documents d ON d.id=p.document_id AND d.key=p.file_key AND COALESCE((SELECT o.sha256 FROM native_document_objects o WHERE o.object_key=d.key AND o.bucket=(SELECT value FROM native_metadata WHERE key='document.storage.bucket')),d.content_hash)=p.content_hash LEFT JOIN native_document_text t ON t.document_id=p.document_id AND t.part=? WHERE p.document_id=?",[.integer(Int64(max(0,part))),.text(id)]).first {
                let image: Data? = { if case let .blob(data) = row["thumbnail"] { return data }; return nil }()
                return (row["content"]?.string ?? "",Int(row["text_parts"]?.string ?? "") ?? 0,Int64(row["text_bytes"]?.string ?? "") ?? 0,image,row["note"]?.string ?? "",row["has_result"] == .integer(1))
            }
            if try !query("SELECT 1 FROM Documents d JOIN native_document_objects o ON o.object_key=d.key AND o.bucket=(SELECT value FROM native_metadata WHERE key='document.storage.bucket') WHERE d.id=?",[.text(id)]).isEmpty { return ("",0,0,nil,"",false) }
            // Legacy text is also paged by SQLite, without fetching its body.
            let row = try query("SELECT substr(content_text,?,8192) AS body,COALESCE(length(content_text),0) AS count FROM Documents WHERE id=?",[.integer(Int64(max(0,min(part,1_000_000)))*8192+1),.text(id)]).first
            let count = Int(row?["count"]?.string ?? "") ?? 0
            return (row?["body"]?.string ?? "",(count+8191)/8192,0,nil,"",count > 0)
        }
    }
    func documentStorageBytes(filter: RecordFilter) throws -> Int64 {
        try synchronized {
            var counter = 0; let condition = try compile(filter,model:schema.model("Documents"),alias:"base",counter:&counter)
            let value = try query("SELECT COALESCE(SUM(CASE WHEN COALESCE((SELECT o.bytes FROM native_document_objects o WHERE o.object_key=base.key AND o.bucket=(SELECT value FROM native_metadata WHERE key='document.storage.bucket')),size)>0 THEN COALESCE((SELECT o.bytes FROM native_document_objects o WHERE o.object_key=base.key AND o.bucket=(SELECT value FROM native_metadata WHERE key='document.storage.bucket')),size) ELSE 0 END),0) AS bytes FROM Documents base WHERE deletedAt IS NULL AND (\(condition.0))",condition.1).first?["bytes"]
            guard case let .integer(bytes) = value else { throw NativeDBError.message("文書の合計サイズを取得できません。") }; return bytes
        }
    }
    func documentFileIsReferenced(_ key: String) throws -> Bool {
        try synchronized {
            !(try query("SELECT 1 FROM native_document_objects WHERE file_key=? UNION ALL SELECT 1 FROM Documents d WHERE d.key=? AND NOT EXISTS(SELECT 1 FROM native_document_objects o WHERE o.object_key=d.key AND o.bucket=(SELECT value FROM native_metadata WHERE key='document.storage.bucket')) LIMIT 1",[.text(key),.text(key)])).isEmpty
        }
    }
    // Primitive tuples keep database-only consumers independent of MCP types.
    func documentObject(bucket: String, key: String) throws -> (fileKey: String, contentType: String, bytes: Int64, sha256: String, revision: Int64)? {
        try synchronized {
            guard let row = try query("SELECT file_key,content_type,bytes,sha256,revision FROM native_document_objects WHERE bucket=? AND object_key=?",[.text(bucket),.text(key)]).first,
                  case let .integer(bytes) = row["bytes"], case let .integer(revision) = row["revision"] else { return nil }
            return (row["file_key"]!.string,row["content_type"]!.string,bytes,row["sha256"]!.string,revision)
        }
    }
    @discardableResult func putDocumentObject(bucket: String, key: String, fileKey: String, contentType: String, bytes: Int64, sha256: String) throws -> Int64 { try requireWritable();
        return try transaction {
            guard !bucket.isEmpty,!bucket.contains("\0"),!key.isEmpty,key.utf8.count<=1024,!key.contains("\0"),bytes>=0,
                  contentType.utf16.count<=256,!contentType.utf8.contains(13),!contentType.utf8.contains(10),
                  fileKey.hasPrefix("native-documents/"),sha256.utf8.count==64,sha256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else { throw NativeDBError.conflict }
            let previous = try documentObject(bucket:bucket,key:key)
            guard previous?.revision != Int64.max else { throw NativeDBError.conflict }
            let revision = (previous?.revision ?? 0)+1
            try run("INSERT INTO native_document_objects(bucket,object_key,file_key,content_type,bytes,sha256,revision,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(bucket,object_key) DO UPDATE SET file_key=excluded.file_key,content_type=excluded.content_type,bytes=excluded.bytes,sha256=excluded.sha256,revision=excluded.revision,updated_at=excluded.updated_at",[.text(bucket),.text(key),.text(fileKey),.text(contentType),.integer(bytes),.text(sha256),.integer(revision),.text(Self.now())])
            if let old = previous?.fileKey, old != fileKey { try enqueue("documents.file_cleanup",payload:["key":old]) }
            else if previous == nil,key.hasPrefix("native-documents/"),key != fileKey { try enqueue("documents.file_cleanup",payload:["key":key]) }
            guard try metadata("document.storage.bucket")==bucket else { return revision }
            // Old extraction generations must not remain visible after a PUT.
            // Only native processing/index state changes, never CRM scalars.
            try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL WHERE id IN (SELECT p.job_id FROM native_document_processing p JOIN Documents d ON d.id=p.document_id WHERE d.key=?) AND status IN ('pending','retry','failed')",[.text(key)])
            try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL WHERE id IN (SELECT w.job_id FROM native_document_ai_work w JOIN Documents d ON d.id=w.document_id WHERE d.key=?) AND status IN ('pending','retry','failed')",[.text(key)])
            try run("DELETE FROM native_document_ai_work WHERE document_id IN (SELECT id FROM Documents WHERE key=?)",[.text(key)])
            try run("DELETE FROM native_document_processing WHERE document_id IN (SELECT id FROM Documents WHERE key=?)",[.text(key)])
            var after=""
            while true {
                let ids=try query("SELECT id FROM Documents WHERE key=? AND id>? ORDER BY id LIMIT 100",[.text(key),.text(after)])
                for row in ids { try clearDocumentAIIndex(row["id"]!.string) }
                if ids.count<100 { break };after=ids.last!["id"]!.string
            }
            return revision
        }
    }
    func documentLogicalKeyIsReferenced(_ key: String) throws -> Bool { try synchronized { !(try query("SELECT id FROM Documents WHERE key=? LIMIT 1",[.text(key)])).isEmpty } }
    func removeUnreferencedDocumentObjects(_ key: String) throws -> [String] { try requireWritable();
        return try transaction {
            guard try !documentLogicalKeyIsReferenced(key) else { return [] }
            let files = try query("SELECT DISTINCT file_key FROM native_document_objects WHERE object_key=?",[.text(key)]).compactMap { $0["file_key"]?.string }
            try run("DELETE FROM native_document_objects WHERE object_key=?",[.text(key)]); return files
        }
    }
    /// Snapshot the family in a disk-backed temporary table, so deletion never
    /// retains every version/body in Swift and also handles legacy descendants.
    func removeDocumentFamily(_ expected: NativeRecord, actor: String) throws { try requireWritable();
        try transaction {
            guard expected.model == "Documents", let root = try get("Documents",key:["id":expected["id"]]), root.revision == expected.revision, root["parent_document_id"] == .null else { throw NativeDBError.conflict }
            let table = quoted("native_document_delete_"+UUID().uuidString.replacingOccurrences(of:"-",with:""))
            try execute("CREATE TEMP TABLE \(table)(id TEXT PRIMARY KEY)"); defer { try? execute("DROP TABLE \(table)") }
            try run("INSERT INTO \(table) WITH RECURSIVE family(id) AS (SELECT ? UNION SELECT d.id FROM Documents d JOIN family f ON d.parent_document_id=f.id) SELECT id FROM family",[root["id"]])
            var offset: Int64 = 0
            while true {
                let ids = try query("SELECT id FROM \(table) ORDER BY id LIMIT 100 OFFSET ?",[.integer(offset)])
                for id in ids { try autoreleasepool {
                    guard let value = id["id"], let row = try get("Documents",key:["id":value]) else { throw NativeDBError.conflict }
                    if row["key"] != .null { try enqueue("documents.file_cleanup",payload:["key":row["key"].string,"documentId":value.string]) }
                    try remove(row,actor:actor,action:"document_delete")
                } }
                offset += Int64(ids.count); if ids.count < 100 { break }
            }
        }
    }
    func recordOrderLineCount(_ order: NativeRecord, before: Int, after: Int, actor: String) throws { try requireWritable();
        try synchronized {
            guard order.model == "crm_Orders" else { throw NativeDBError.message("受注履歴の種類が不正です。") }
            let previous = NativeRecord(model:order.model,values:order.values.merging(["lineCount":.integer(Int64(before))]) { _,n in n },revision:order.revision)
            let updated = NativeRecord(model:order.model,values:order.values.merging(["lineCount":.integer(Int64(after))]) { _,n in n },revision:order.revision)
            try audit(before:previous,after:updated,action:"order_lines",actor:actor)
        }
    }
    /// Import lookups live in disk-backed temporary tables, not a set of every product in RAM.
    /// The surrounding transaction serializes duplicate checks with the inserts.
    func withProductImportIndex<T>(_ body: (_ hasSKU: (String) throws -> Bool, _ addSKU: (String) throws -> Void, _ category: (String) throws -> SQLValue?) throws -> T) throws -> T {
        try transaction {
            let suffix = UUID().uuidString.replacingOccurrences(of:"-",with:"")
            let skus = quoted("import_skus_"+suffix); let categories = quoted("import_categories_"+suffix)
            try execute("CREATE TEMP TABLE \(skus)(name TEXT PRIMARY KEY NOT NULL); CREATE TEMP TABLE \(categories)(name TEXT PRIMARY KEY NOT NULL,id TEXT NOT NULL)")
            defer { try? execute("DROP TABLE IF EXISTS \(skus); DROP TABLE IF EXISTS \(categories)") }
            for model in ["crm_Products","crm_ProductCategories"] {
                var offset = 0
                while true {
                    let rows = try page(model,fields:model == "crm_Products" ? ["sku"] : ["name"],equal:model == "crm_Products" ? [:] : ["isActive":.integer(1)],includeDeleted:true,offset:offset)
                    for row in rows.rows {
                        try autoreleasepool {
                            if model == "crm_Products", row["sku"] != .null { try run("INSERT OR IGNORE INTO \(skus) VALUES(?)",[.text(row["sku"].string.lowercased())]) }
                            else if model != "crm_Products" { try run("INSERT OR REPLACE INTO \(categories) VALUES(?,?)",[.text(row["name"].string.lowercased()),row["id"]]) }
                        }
                    }
                    offset += rows.rows.count; if rows.rows.isEmpty || offset >= rows.total { break }
                }
            }
            return try body({ try !self.query("SELECT 1 FROM \(skus) WHERE name=?",[.text($0.lowercased())]).isEmpty },
                            { try self.run("INSERT INTO \(skus) VALUES(?)",[.text($0.lowercased())]) },
                            { try self.query("SELECT id FROM \(categories) WHERE name=?",[.text($0.lowercased())]).first?["id"] })
        }
    }
    func validateFieldValues(_ model: String, _ values: [String:SQLValue]) throws {
        let definition = try schema.model(model)
        for (key,value) in values { guard let field = definition.field(key) else { throw NativeDBError.message("未対応の項目です。") }; _ = try validated(field,value:value) }
    }
    func integrityCheck() throws -> Bool {
        try synchronized { try query("PRAGMA integrity_check").first?["integrity_check"] == .text("ok") && query("PRAGMA foreign_key_check").isEmpty }
    }
}

// Campaign audiences are grouped inside SQLite. Neither the whole member set
// nor large target descriptions enter Swift; only 100 summaries are decoded.
extension NativeDatabase {
    func campaignAudience(campaignID: String, offset: Int = 0) throws -> (rows:[NativeRecord],members:Int,suppressed:Int,withoutEmail:Int,eligible:Int,unique:Int) {
        try synchronized {
            let cte = """
            WITH members AS (
              SELECT t.id,t.first_name,t.last_name,t.company,t.email,t.do_not_email,t._native_revision
              FROM crm_Targets t WHERE t.deletedAt IS NULL AND EXISTS (
                SELECT 1 FROM TargetsToTargetLists m
                JOIN crm_TargetLists l ON l.id=m.target_list_id
                JOIN CampaignToTargetLists c ON c.target_list_id=l.id
                WHERE m.target_id=t.id AND c.campaign_id=? AND l.deletedAt IS NULL
              )
            ), eligible AS (SELECT * FROM members WHERE do_not_email=0 AND email IS NOT NULL AND email!='')
            """
            let counts = try query(cte+" SELECT (SELECT COUNT(*) FROM members) members,(SELECT COUNT(*) FROM members WHERE do_not_email=1) suppressed,(SELECT COUNT(*) FROM members WHERE do_not_email=0 AND (email IS NULL OR email='')) missing,COUNT(*) eligible,COUNT(DISTINCT email COLLATE BINARY) unique_count FROM eligible",[.text(campaignID)]).first!
            func count(_ field: String) -> Int { Int(counts[field]?.string ?? "0") ?? 0 }
            let rows = try query(cte+", ranked AS (SELECT *,ROW_NUMBER() OVER(PARTITION BY email COLLATE BINARY ORDER BY id) rank FROM eligible) SELECT id,first_name,last_name,company,email,do_not_email,_native_revision FROM ranked WHERE rank=1 ORDER BY email COLLATE BINARY,id LIMIT 100 OFFSET ?",[.text(campaignID),.integer(Int64(max(0,offset)))])
            let model = try schema.model("crm_Targets")
            return (rows.map{record(model,$0)},count("members"),count("suppressed"),count("missing"),count("eligible"),count("unique_count"))
        }
    }
}

// Campaign fanout has a durable, disk-backed cohort. Pagination uses a stable
// target key, so a restart or a change to a target cannot shift an OFFSET page.
extension NativeDatabase {
    func stageCampaignAudience(jobID: String, campaignID: String, stepID: String, initial: Bool, sendTo: String) throws -> Int { try requireWritable();
        return try transaction {
            try run("DELETE FROM native_campaign_audience WHERE job_id=?",[.text(jobID)])
            if initial {
                // Existing sends win over changed list membership or addresses on
                // resume. Their immutable delivery IDs and original emails survive.
                try run("INSERT OR IGNORE INTO native_campaign_audience(job_id,target_id,email) SELECT ?,target_id,email FROM crm_campaign_sends WHERE step_id=? ORDER BY id",[.text(jobID),.text(stepID)])
                try run("""
                INSERT OR IGNORE INTO native_campaign_audience(job_id,target_id,email)
                SELECT ?,MIN(t.id),t.email FROM crm_Targets t
                WHERE t.deletedAt IS NULL AND t.do_not_email=0 AND t.email IS NOT NULL AND t.email!=''
                AND NOT EXISTS (SELECT 1 FROM native_campaign_audience a WHERE a.job_id=? AND a.target_id=t.id)
                AND EXISTS (SELECT 1 FROM TargetsToTargetLists m
                  JOIN crm_TargetLists l ON l.id=m.target_list_id
                  JOIN CampaignToTargetLists c ON c.target_list_id=l.id
                  WHERE m.target_id=t.id AND c.campaign_id=? AND l.deletedAt IS NULL)
                GROUP BY t.email COLLATE BINARY ORDER BY t.email COLLATE BINARY
                """,[.text(jobID),.text(jobID),.text(campaignID)])
            } else {
                try run("""
                INSERT OR IGNORE INTO native_campaign_audience(job_id,target_id,email)
                SELECT ?,s.target_id,s.email FROM crm_campaign_sends s
                JOIN crm_campaign_steps p ON p.id=s.step_id
                JOIN crm_Targets t ON t.id=s.target_id
                WHERE s.campaign_id=? AND p."order"=0 AND s.status IN ('sent','delivered')
                  AND s.unsubscribed_at IS NULL AND t.do_not_email=0 AND t.deletedAt IS NULL
                  AND (?!='non_openers' OR s.opened_at IS NULL)
                ORDER BY s.id
                """,[.text(jobID),.text(campaignID),.text(sendTo)])
            }
            return Int(try query("SELECT COUNT(*) n FROM native_campaign_audience WHERE job_id=?",[.text(jobID)]).first?["n"]?.string ?? "0") ?? 0
        }
    }
    func campaignDispatchRecipients(jobID: String, after: String) throws -> [(targetID:String,email:String)] {
        try synchronized { try query("SELECT target_id,email FROM native_campaign_audience WHERE job_id=? AND target_id>? ORDER BY target_id LIMIT 100",[.text(jobID),.text(after)]).map{($0["target_id"]!.string,$0["email"]!.string)} }
    }
    func clearCampaignAudience(jobID: String) throws { try requireWritable(); _ = try synchronized { try run("DELETE FROM native_campaign_audience WHERE job_id=?",[.text(jobID)]) } }
    func campaignFollowUpSteps(campaignID: String, after: Int64) throws -> [NativeRecord] {
        try synchronized { let model = try schema.model("crm_campaign_steps"); return try query("SELECT * FROM crm_campaign_steps WHERE campaign_id=? AND \"order\">? ORDER BY \"order\" LIMIT 100",[.text(campaignID),.integer(after)]).map{record(model,$0)} }
    }
    func campaignInitialWaiting(_ id: String) throws -> Bool {
        try synchronized { try query("""
        SELECT 1 FROM crm_campaign_sends s JOIN crm_campaign_steps p ON p.id=s.step_id
        JOIN crm_Targets t ON t.id=s.target_id WHERE s.campaign_id=? AND p."order"=0
        AND s.status IN ('queued','sending') AND s.unsubscribed_at IS NULL
        AND t.do_not_email=0 AND t.deletedAt IS NULL LIMIT 1
        """,[.text(id)]).first != nil }
    }
    func campaignMailIntent(sendID: String) throws -> (token:String,actorID:String)? {
        try synchronized { try query("SELECT run_token,actor_id FROM native_campaign_mail_intents WHERE send_id=?",[.text(sendID)]).first.map{($0["run_token"]!.string,$0["actor_id"]!.string)} }
    }
    /// One outbox identity per send survives every pause/resume generation.
    /// Rearming never resets an in-flight lease, frozen payload, or first request
    /// time. Ambiguous attempts beyond the dedupe window require review.
    func queueCampaignSend(_ send: NativeRecord, token: String, actorID: String, now: Date) throws { try requireWritable();
        try transaction {
            guard send.model == "crm_campaign_sends", ["queued","sending","failed"].contains(send["status"].string) else { return }
            let id = send["id"].string
            try run("INSERT INTO native_campaign_mail_intents(send_id,run_token,actor_id) VALUES(?,?,?) ON CONFLICT(send_id) DO UPDATE SET run_token=excluded.run_token,actor_id=excluded.actor_id",[.text(id),.text(token),.text(actorID)])
            guard let existing = try job(id:id) else {
                try enqueue("campaigns/send-step",payload:["sendId":id,"campaignId":send["campaign_id"].string],id:id,now:now); return
            }
            guard existing.event == "campaigns/send-step", existing.payload["sendId"] == id, existing.payload["campaignId"] == send["campaign_id"].string else { throw NativeDBError.conflict }
            // Explicit recipient cancellation survives campaign pause/resume.
            guard existing.result["cancelledBy"] == nil else { return }
            guard ["failed","cancelled","done"].contains(existing.status) else { return }
            if existing.status == "done", existing.result["outcome"] != "skipped" { return }
            if let start = existing.deliveryStartedAt, existing.result["providerID"] == nil, now < start || now.timeIntervalSince(start) >= 23*3600 {
                try run("UPDATE native_outbox SET status='needs_review',last_error=?,next_run_at=NULL WHERE id=?",[.text("以前の送信結果を確認してください。重複送信の防止期間を超えています。"),.text(id)])
            } else {
                try run("UPDATE native_outbox SET status='pending',next_run_at=NULL,last_error=NULL,completed_at=NULL WHERE id=?",[.text(id)])
            }
            notifyJobChange()
        }
    }
}

extension NativeDatabase {
    private static func campaignEventStamp(_ date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= -62_135_596_800, date.timeIntervalSince1970 < 253_402_300_800 else { throw NativeDBError.message("受信日時が範囲外です。") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds); return formatter.string(from:date)
    }
    /// Token possession authorizes only unsubscribe. The send marker and all
    /// existing matching targets commit together, including case variants and
    /// a target whose address changed since this particular mail was sent.
    func unsubscribeCampaign(token: String, now: Date = Date()) throws -> (campaignID:String,targets:Int)? { try requireWritable();
        guard UUID(uuidString:token) != nil else { return nil }
        return try transaction {
            guard let id = try query("SELECT id FROM crm_campaign_sends WHERE unsubscribe_token=?",[.text(token)]).first?["id"],
                  let send = try get("crm_campaign_sends",key:["id":id]) else { return nil }
            let stamp = try Self.campaignEventStamp(now), actor = "campaign:unsubscribe"
            if send["unsubscribed_at"] == .null { _ = try update(send,changes:["unsubscribed_at":.text(stamp)],actor:actor,action:"campaign_unsubscribed") }
            var cursor = ""; var changed = 0
            while true {
                let ids = try query("SELECT id FROM crm_Targets WHERE id>? AND do_not_email=0 AND (id=? OR email=? COLLATE native_email) ORDER BY id LIMIT 100",[.text(cursor),send["target_id"],send["email"]])
                guard !ids.isEmpty else { break }
                for item in ids {
                    guard let id = item["id"], let target = try get("crm_Targets",key:["id":id]) else { throw NativeDBError.conflict }
                    _ = try update(target,changes:["do_not_email":.integer(1),"do_not_email_at":.text(stamp)],actor:actor,action:"campaign_suppressed")
                    cursor = id.string; changed += 1
                }
            }
            return (send["campaign_id"].string,changed)
        }
    }
    /// Do not lose tracking events that arrive before the provider receipt is
    /// committed locally. Only compact metadata is retained, never message HTML
    /// or raw signed payloads. Pending events are bounded and never age-deleted.
    func receiveCampaignEvent(id: String, providerID: String, kind: String, bodySHA256: String, receivedAt: Date? = nil, now: Date = Date(), retiredSendID: String? = nil) throws -> String { try requireWritable();
        guard !id.isEmpty, id.utf8.count <= 255, !providerID.isEmpty, providerID.utf8.count <= 512,
              !id.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}), !providerID.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}),
              ["email.delivered","email.bounced","email.opened","email.clicked"].contains(kind),
              bodySHA256.utf8.count == 64, bodySHA256.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else { throw NativeDBError.message("配信結果の形式が不正です。") }
        return try transaction {
            if let retiredSendID {
                guard let job = try job(id:retiredSendID), job.event == "campaigns/send-step", job.status == "done",
                      ["notSent","unknown"].contains(job.result["reviewOutcome"] ?? ""), job.result["relayProviderIDHint"] == providerID,
                      let send = try get("crm_campaign_sends",key:["id":.text(retiredSendID)]), send["resend_message_id"] == .null,
                      try query("SELECT 1 FROM crm_campaign_sends WHERE resend_message_id=? LIMIT 1",[.text(providerID)]).isEmpty else { throw NativeDBError.message("終了済みの確認記録と配信結果が一致しません。") }
            }
            let received = receivedAt ?? now
            guard received <= now.addingTimeInterval(300) else { throw NativeDBError.message("配信結果の受信日時が未来です。") }
            let stamp = try Self.campaignEventStamp(received)
            if let old = try query("SELECT provider_id,kind,body_sha256 FROM native_campaign_events WHERE event_id=?",[.text(id)]).first {
                guard old["provider_id"] == .text(providerID), old["kind"] == .text(kind), old["body_sha256"] == .text(bodySHA256) else { throw NativeDBError.message("同じ配信結果IDに異なる内容が届いています。") }
                if retiredSendID != nil {
                    try run("UPDATE native_campaign_events SET processed_at=COALESCE(processed_at,?) WHERE event_id=?",[.text(try Self.campaignEventStamp(now)),.text(id)]); return "retired"
                }
                try reconcileCampaignEvents(providerID:providerID,now:now); return "duplicate"
            }
            // Delete at most100 processed old receipts per new arrival. The CRM
            // status/timestamps and audit remain; duplicate old events are still
            // idempotent at the record level. Never discard unresolved events.
            let cutoff = try Self.campaignEventStamp(now.addingTimeInterval(-30*86400))
            try run("DELETE FROM native_campaign_events WHERE event_id IN (SELECT event_id FROM native_campaign_events WHERE processed_at IS NOT NULL AND processed_at<? ORDER BY processed_at LIMIT 100)",[.text(cutoff)])
            let count = Int(try query("SELECT COUNT(*) n FROM native_campaign_events WHERE processed_at IS NULL").first?["n"]?.string ?? "0") ?? 0
            if count >= 10_000, retiredSendID == nil, try query("SELECT 1 FROM crm_campaign_sends WHERE resend_message_id=? LIMIT 1",[.text(providerID)]).first == nil { throw NativeDBError.message("未照合の配信結果が上限に達しました。送信サービスの接続先を確認してください。") }
            try run("INSERT INTO native_campaign_events(event_id,provider_id,kind,body_sha256,received_at,processed_at) VALUES(?,?,?,?,?,?)",[.text(id),.text(providerID),.text(kind),.text(bodySHA256),.text(stamp),try retiredSendID == nil ? .null : .text(Self.campaignEventStamp(now))])
            // Explicit terminal review is enough to retire an observation, not
            // to adopt its receipt. Normal processed-event retention now applies.
            if retiredSendID != nil { return "retired" }
            try reconcileCampaignEvents(providerID:providerID,now:now)
            let row = try query("SELECT processed_at FROM native_campaign_events WHERE event_id=?",[.text(id)]).first!
            return row["processed_at"] == .null ? "pending" : "applied"
        }
    }
    func reconcileCampaignEvents(providerID: String, now: Date = Date()) throws { try requireWritable();
        try transaction {
            let sends = try query("SELECT id FROM crm_campaign_sends WHERE resend_message_id=? LIMIT 2",[.text(providerID)])
            guard sends.count <= 1 else { throw NativeDBError.message("配信結果が複数の送信記録に対応しています。") }
            guard let id = sends.first?["id"] else { return }
            let stamp = try Self.campaignEventStamp(now)
            while true {
                let events = try query("SELECT event_id,kind,received_at FROM native_campaign_events WHERE provider_id=? AND processed_at IS NULL ORDER BY rowid LIMIT 100",[.text(providerID)])
                guard !events.isEmpty else { return }
                for event in events {
                    guard let send = try get("crm_campaign_sends",key:["id":id]) else { throw NativeDBError.conflict }
                    var changes: [String:SQLValue] = [:]
                    switch event["kind"]?.string {
                    case "email.delivered": if send["status"] == .text("sent") { changes["status"] = .text("delivered") }
                    case "email.bounced": if send["status"] != .text("bounced") || send["error_message"] != .text("Bounced") { changes = ["status":.text("bounced"),"error_message":.text("Bounced")] }
                    case "email.opened": if send["opened_at"] == .null { changes["opened_at"] = event["received_at"] }
                    case "email.clicked": if send["clicked_at"] == .null { changes["clicked_at"] = event["received_at"] }
                    default: throw NativeDBError.message("配信結果の種類が不正です。")
                    }
                    if !changes.isEmpty { _ = try update(send,changes:changes,actor:"campaign:webhook",action:"campaign_"+(event["kind"]?.string.replacingOccurrences(of:"email.",with:"") ?? "event")) }
                    try run("UPDATE native_campaign_events SET processed_at=? WHERE event_id=?",[.text(stamp),event["event_id"]!])
                }
            }
        }
    }
}


extension NativeDatabase {
    /// Keyset scan of native accepted messages whose receiver mapping is not
    /// acknowledged yet. No OFFSET and no full outbox payload crosses SQLite.
    func campaignRelayReceiptIDs(instanceID: String, publicURL: String, after: String) throws -> [String] {
        try synchronized {
            try query("""
            SELECT s.id FROM crm_campaign_sends s
            JOIN native_outbox j ON j.id=s.id AND j.event='campaigns/send-step'
            LEFT JOIN native_campaign_relay_registrations r ON r.instance_id=? AND r.send_id=s.id
            WHERE s.id>? AND s.resend_message_id IS NOT NULL
              AND CASE WHEN json_valid(j.result) THEN json_extract(j.result,'$.publicURL') END=?
              AND (r.send_id IS NULL OR r.token IS NOT s.unsubscribe_token OR r.provider_id IS NOT s.resend_message_id)
            ORDER BY s.id LIMIT 100
            """,[.text(instanceID),.text(after),.text(publicURL)]).map{$0["id"]!.string}
        }
    }
    func recordCampaignRelayRegistration(instanceID: String, sendID: String, token: String, providerID: String?) throws { try requireWritable();
        guard UUID(uuidString:instanceID) != nil, UUID(uuidString:sendID) != nil, UUID(uuidString:token) != nil else { throw NativeDBError.conflict }
        try transaction {
            guard let send = try get("crm_campaign_sends",key:["id":.text(sendID)]), send["unsubscribe_token"] == .text(token),
                  send["resend_message_id"] == (providerID.map(SQLValue.text) ?? .null) else { throw NativeDBError.conflict }
            if let old = try query("SELECT token,provider_id FROM native_campaign_relay_registrations WHERE instance_id=? AND send_id=?",[.text(instanceID),.text(sendID)]).first {
                guard old["token"] == .text(token), old["provider_id"] == .null || old["provider_id"] == providerID.map(SQLValue.text) else {
                    throw NativeDBError.message("受信窓口に登録済みのメール識別子を変更することはできません。")
                }
            }
            try run("INSERT INTO native_campaign_relay_registrations(instance_id,send_id,token,provider_id) VALUES(?,?,?,?) ON CONFLICT(instance_id,send_id) DO UPDATE SET provider_id=excluded.provider_id",[.text(instanceID),.text(sendID),.text(token),providerID.map(SQLValue.text) ?? .null])
        }
    }
}


extension NativeDatabase {
    /// The original matching priority is contact (+ account + single active
    /// opportunity), target, then lead. SQL examines the full database while
    /// returning at most three identifiers, independent of the CRM row count.
    func calendarCounterpartyLinks(_ emails: [String]) throws -> [(type:String,id:String)] {
        try transaction {
            let normalized = Array(Set(emails.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter{!$0.isEmpty}))
            if normalized.isEmpty { return [] }
            let json = String(decoding:try JSONEncoder().encode(normalized),as:UTF8.self)
            guard json.utf8.count <= 1_048_576 else { throw NativeDBError.message("カレンダーの宛先が多すぎます。") }
            for (model,kind,fields) in [("crm_Contacts","contact",["email","personal_email"]),("crm_Targets","target",["email","personal_email","company_email"]),("crm_Leads","lead",["email"])] {
                let clause = fields.map{quoted($0)+" COLLATE native_email IN (SELECT value FROM json_each(?) WHERE type='text')"}.joined(separator:" OR ")
                let selected = kind == "contact" ? "id,accountsIDs" : "id"
                guard let row = try query("SELECT \(selected) FROM \(quoted(model)) WHERE deletedAt IS NULL AND (\(clause)) ORDER BY rowid LIMIT 1",fields.map{_ in .text(json)}).first else { continue }
                var links: [(type:String,id:String)] = [(kind,row["id"]!.string)]
                if kind == "contact", let account = row["accountsIDs"], account != .null {
                    links.append(("account",account.string))
                    let opportunities = try query("SELECT id FROM crm_Opportunities WHERE account=? AND status='ACTIVE' AND deletedAt IS NULL ORDER BY rowid LIMIT 2",[account])
                    if opportunities.count == 1 { links.append(("opportunity",opportunities[0]["id"]!.string)) }
                }
                return links
            }
            return []
        }
    }
    func calendarHasCalendlyMatch(startAt: String, emails: [String]) throws -> Bool {
        try synchronized {
            if emails.isEmpty { return false }
            let json = String(decoding:try JSONEncoder().encode(emails),as:UTF8.self)
            guard json.utf8.count <= 1_048_576 else { throw NativeDBError.message("カレンダーの宛先が多すぎます。") }
            return try !query("""
                SELECT c.id FROM crm_CalendarEvents c
                WHERE c.source='calendly' AND julianday(c.startAt)=julianday(?) AND EXISTS (
                  SELECT 1 FROM json_each(CASE WHEN json_valid(c.attendeeEmails) THEN
                    CASE WHEN json_type(c.attendeeEmails)='array' THEN c.attendeeEmails ELSE '[]' END ELSE '[]' END) attendee
                  JOIN json_each(?) incoming ON incoming.value COLLATE native_email=attendee.value
                  WHERE incoming.type='text' AND attendee.type='text') LIMIT 1
                """,[.text(startAt),.text(json)]).isEmpty
        }
    }
}


// Report workspaces live in SQLite's disk-backed TEMP database. No source rows
// or arbitrary-size chart arrays need to remain in the application heap.
extension NativeDatabase {
    private func reportTable(_ token: String) throws -> String {
        guard UUID(uuidString: token) != nil else { throw NativeDBError.conflict }
        return quoted("native_report_" + token.replacingOccurrences(of: "-", with: ""))
    }
    /// Check the full stored record size before materializing imported JSON or
    /// text. Authorization belongs to NativeReportConfigurations.load.
    func reportConfigurationRecord(_ id: String) throws -> NativeRecord {
        try reportSavedRecord("crm_Report_Config",id:id)
    }
    func reportScheduleRecord(_ id:String)throws->NativeRecord {
        try reportSavedRecord("crm_Report_Schedule",id:id)
    }
    private func reportSavedRecord(_ name:String,id:String)throws->NativeRecord {
        try transaction {
            let model=try schema.model(name)
            let size=model.fields.map { "COALESCE(length(CAST(\(quoted($0.column)) AS BLOB)),0)" }.joined(separator:"+")
            guard let raw=try query("SELECT \(size) AS bytes FROM \(quoted(name)) WHERE id=?",[.text(id)]).first,
                  let bytes=Int(raw["bytes"]!.string),bytes<=131_072 else {throw NativeDBError.message("保存されたレポートが見つからないか、読み込めるサイズを超えています。")}
            guard let record=try get(name,key:["id":.text(id)]) else {throw NativeDBError.conflict}
            return record
        }
    }
    func reportScheduleTimeZone(_ id:String)throws->String? {
        try reportScheduleState("timezone",id:id)
    }
    func reportScheduleState(_ field:String,id:String)throws->String? {
        guard ["timezone","generation","job"].contains(field) else {throw NativeDBError.conflict}
        return try synchronized {
            guard let row=try query("SELECT CASE WHEN length(CAST(value AS BLOB))<=128 THEN value END AS value FROM native_metadata WHERE key=?",[.text("reportSchedule."+field+"."+id)]).first else {return nil}
            guard let value=row["value"],value != .null else {throw NativeDBError.message("保存されたタイムゾーンを読み込めません。")};return value.string
        }
    }
    func clearReportScheduleMetadata(_ id:String)throws { try requireWritable();
        _ = try synchronized {try run("DELETE FROM native_metadata WHERE key IN (?,?,?)",[.text("reportSchedule.timezone."+id),.text("reportSchedule.generation."+id),.text("reportSchedule.job."+id)])}
    }
    func clearReportConfigurationScheduleMetadata(_ id:String)throws { try requireWritable();
        try synchronized {
            for field in ["timezone","generation","job"] {
                try run("DELETE FROM native_metadata WHERE key IN (SELECT ?||id FROM crm_Report_Schedule WHERE reportConfigId=?)",[.text("reportSchedule."+field+"."),.text(id)])
            }
        }
    }
    private func prepareReportJobIndex()throws {
        try run("CREATE INDEX IF NOT EXISTS native_report_job_scope ON native_outbox((CASE WHEN json_valid(payload) THEN json_extract(payload,'$.scheduleId') END),created_at,status) WHERE event='reports.scheduled'")
    }
    private func reportJobFilter(scheduleID:String?,configID:String?)->(String,[SQLValue]) {
        var sql="event='reports.scheduled'",values:[SQLValue]=[]
        if let scheduleID {sql+=" AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.scheduleId') END=?";values.append(.text(scheduleID))}
        if let configID {sql+=" AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.configId') END=?";values.append(.text(configID))}
        return(sql,values)
    }
    func cancelUnstartedReportJobs(scheduleID:String?=nil,configID:String?=nil)throws { try requireWritable();
        guard scheduleID != nil || configID != nil else {throw NativeDBError.conflict}
        try transaction {
            try requireRestoredJobQuarantineFence();try prepareReportJobIndex();let filter=reportJobFilter(scheduleID:scheduleID,configID:configID)
            try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL,lease_token=NULL,lease_until=NULL WHERE \(filter.0) AND \(restoredJobEligible("native_outbox.id")) AND status IN ('pending','retry','running','failed') AND delivery_started_at IS NULL",filter.1)
        };notifyJobChange()
    }
    func cancelledReportBodyIDs(scheduleID:String?,configID:String?,after:String)throws->[String] {
        guard scheduleID != nil || configID != nil else {throw NativeDBError.conflict}
        return try synchronized {
            let filter=reportJobFilter(scheduleID:scheduleID,configID:configID)
            return try query("SELECT id FROM native_outbox WHERE \(filter.0) AND status='cancelled' AND delivery_started_at IS NULL AND id>? ORDER BY id LIMIT 100",filter.1+[.text(after)]).map{$0["id"]!.string}
        }
    }
    /// A previous unresolved delivery blocks just its own schedule. Use exactly
    /// the same predicate for claims and timers, avoiding a busy wake loop.
    private var reportJobEligible:String {
        "j.event='reports.scheduled' AND \(restoredJobEligible("j.id")) AND NOT EXISTS(SELECT 1 FROM native_outbox b WHERE b.event='reports.scheduled' AND b.id<>j.id AND CASE WHEN json_valid(b.payload) THEN json_extract(b.payload,'$.scheduleId') END=CASE WHEN json_valid(j.payload) THEN json_extract(j.payload,'$.scheduleId') END AND (b.status='needs_review' OR (b.status IN ('pending','retry','running') AND (b.created_at<j.created_at OR (b.created_at=j.created_at AND b.rowid<j.rowid)))))"
    }
    func claimReportJob(now:Date=Date())throws->NativeJob? { try requireWritable();
        return try transaction {
            try requireRestoredJobQuarantineFence()
            try prepareReportJobIndex()
            let formatter=ISO8601DateFormatter();formatter.formatOptions.insert(.withFractionalSeconds)
            guard let row=try query("SELECT j.* FROM native_outbox j WHERE \(reportJobEligible) AND ((j.status IN ('pending','retry') AND (j.next_run_at IS NULL OR COALESCE(julianday(j.next_run_at),0)<=julianday(?))) OR (j.status='running' AND (j.lease_until IS NULL OR j.lease_until<=?))) ORDER BY j.created_at,j.rowid LIMIT 1",[.text(formatter.string(from:now)),.real(now.timeIntervalSince1970)]).first else {return nil}
            let id=row["id"]!,token=UUID().uuidString.lowercased()
            try run("UPDATE native_outbox SET status='running',attempts=attempts+1,lease_token=?,lease_until=?,first_attempt_at=COALESCE(first_attempt_at,?),next_run_at=NULL WHERE id=?",[.text(token),.real(now.timeIntervalSince1970+300),.real(now.timeIntervalSince1970),id]);return try job(id:id.string)
        }
    }
    func nextReportJobDate(now:Date=Date())throws->Date? {
        try synchronized {
            try requireRestoredJobQuarantineFence()
            try prepareReportJobIndex()
            let row=try query("SELECT MIN(CASE WHEN j.status='running' THEN COALESCE(j.lease_until,?) WHEN j.next_run_at IS NULL THEN ? ELSE COALESCE((julianday(j.next_run_at)-2440587.5)*86400,?) END) due FROM native_outbox j WHERE \(reportJobEligible) AND j.status IN ('pending','retry','running')",Array(repeating:.real(now.timeIntervalSince1970),count:3)).first
            guard let value=row?["due"],value != .null,let epoch=Double(value.string) else{return nil};return Date(timeIntervalSince1970:epoch)
        }
    }
    /// Receipt bookkeeping must survive deletion or malformed later edits. Do
    /// not load recipient/filter JSON, change the generation, or move time back.
    /// The immutable outbox receipt is the audit record for this operational field.
    func acknowledgeReportDelivery(_ job:NativeJob,acceptedAt:Date)throws { try requireWritable();
        guard job.event=="reports.scheduled",let schedule=job.payload["scheduleId"],let owner=job.payload["ownerId"] else {throw NativeDBError.conflict}
        try transaction {
            let stamp=ISO8601DateFormatter().string(from:acceptedAt)
            try run("UPDATE crm_Report_Schedule SET lastSentAt=?,updatedAt=?,_native_revision=_native_revision+1 WHERE id=? AND createdBy=? AND (lastSentAt IS NULL OR julianday(lastSentAt) IS NULL OR julianday(lastSentAt)<julianday(?))",[.text(stamp),.text(Self.now()),.text(schedule),.text(owner),.text(stamp)])
        }
    }
    func reportJobs(ownerID:String?,scheduleID:String?=nil,offset:Int=0)throws->(rows:[NativeJob],total:Int) {
        try synchronized {
            var filter=reportJobFilter(scheduleID:scheduleID,configID:nil)
            if let ownerID {filter.0+=" AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.ownerId') END=?";filter.1.append(.text(ownerID))}
            let total=Int(try query("SELECT COUNT(*) n FROM native_outbox WHERE \(filter.0)",filter.1).first?["n"]?.string ?? "0") ?? 0
            let rows=try query("SELECT * FROM native_outbox WHERE \(filter.0) ORDER BY created_at DESC,rowid DESC LIMIT 100 OFFSET ?",filter.1+[.integer(Int64(max(0,offset)))]).map(job);return(rows,total)
        }
    }
    func createReportWorkspace() throws -> String {
        try synchronized {
            guard sqlite3_create_function_v2(connection, "native_report_integer", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, _, args in
                guard let args, let value = args[0], sqlite3_value_type(value) != SQLITE_NULL,
                      let ptr = sqlite3_value_text(value) else { sqlite3_result_null(context); return }
                let bytes = UnsafeBufferPointer(start: ptr, count: Int(sqlite3_value_bytes(value)))
                var iterator = bytes.makeIterator(), decoder = Unicode.UTF8(), started = false, negative = false, digits = 0
                var significant: [UInt8] = []; significant.reserveCapacity(309)
                while true {
                    guard case let .scalarValue(scalar) = decoder.decode(&iterator) else { break }
                    let n = scalar.value
                    if !started {
                        if [9,10,11,12,13,32,160,5760,8232,8233,8239,8287,12288,65279].contains(n) || (8192...8202).contains(n) { continue }
                        started = true
                        if n == 43 || n == 45 { negative = n == 45; continue }
                    }
                    guard (48...57).contains(n) else { break }
                    digits += 1
                    if n != 48 || !significant.isEmpty {
                        guard significant.count < 309 else { sqlite3_result_null(context); return }
                        significant.append(UInt8(n))
                    }
                }
                guard digits > 0, let number = Double(significant.isEmpty ? "0" : String(decoding:significant,as:UTF8.self)), number.isFinite else { sqlite3_result_null(context); return }
                sqlite3_result_double(context, negative ? -number : number)
            }, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(error) }
            let token = UUID().uuidString.lowercased(), table = try reportTable(token)
            try execute("CREATE TEMP TABLE \(table)(id INTEGER PRIMARY KEY,section TEXT NOT NULL,label TEXT NOT NULL,value TEXT NOT NULL,secondary TEXT)")
            try execute("CREATE INDEX temp.\(quoted("report_section_" + token.replacingOccurrences(of:"-",with:""))) ON \(table)(section,id)")
            return token
        }
    }
    func removeReportWorkspace(_ token: String) { try? synchronized { try execute("DROP TABLE IF EXISTS temp.\(reportTable(token))") } }
    func reportRevision() throws -> String {
        try synchronized {
            let external = try query("PRAGMA data_version").first?["data_version"]?.string ?? ""
            return String(sqlite3_total_changes64(connection)) + ":" + external
        }
    }
    func insertReportRow(_ token: String, section: String, label: String, value: String, secondary: String? = nil) throws {
        _ = try synchronized { try run("INSERT INTO temp.\(reportTable(token))(section,label,value,secondary) VALUES(?,?,?,?)", [.text(section),.text(label),.text(value),secondary.map(SQLValue.text) ?? .null]) }
    }
    /// Recipes are internal identifiers, never caller-supplied SQL. Grouping uses
    /// complete names on disk; only the visible page abbreviates very long labels.
    func aggregateReport(_ token: String, section: String, recipe: String, filter: RecordFilter) throws {
        try synchronized {
            let modelName: String, label: String, value: String, secondary: String, grouping: String?, ordering: String, suffix: String
            func month(_ field: String) -> String { "strftime('%Y-%m',base.\(quoted(field)),'localtime')" }
            func related(_ table: String, _ local: String, fallback: String) -> String { "COALESCE((SELECT name FROM \(quoted(table)) ref WHERE ref.id=base.\(quoted(local))),'\(fallback)')" }
            var group = true; var order = "label"; var tail = ""; var second = "NULL"; var number = "count(*)"
            switch recipe {
            case "oppsByStage": modelName = "crm_Opportunities"; label = related("crm_Opportunities_Sales_Stages","sales_stage",fallback:"Unassigned")
            case "oppsByMonth": modelName = "crm_Opportunities"; label = month("created_on")
            case "newLeads": modelName = "crm_Leads"; label = month("createdAt")
            case "leadSources": modelName = "crm_Leads"; label = related("crm_Lead_Sources","lead_source_id",fallback:"Unknown")
            case "newContacts": modelName = "crm_Contacts"; label = month("created_on")
            case "contactsByAccount": modelName = "crm_Contacts"; label = related("crm_Accounts","accountsIDs",fallback:"Unassigned")
            case "newAccounts": modelName = "crm_Accounts"; label = month("createdAt")
            case "byIndustry": modelName = "crm_Accounts"; label = related("crm_Industry_Type","industry",fallback:"Unknown")
            case "topByRevenue":
                modelName = "crm_Accounts"; label = "base.name"; number = "native_report_integer(base.annual_revenue)"; group = false
                order = "native_report_integer(base.annual_revenue) DESC,base.id"; tail = " LIMIT 10"
            case "bySize":
                modelName = "crm_Accounts"
                let n = "native_report_integer(base.employees)"
                label = "CASE WHEN \(n) BETWEEN 1 AND 10 THEN '1-10' WHEN \(n) BETWEEN 11 AND 50 THEN '11-50' WHEN \(n) BETWEEN 51 AND 200 THEN '51-200' WHEN \(n) BETWEEN 201 AND 500 THEN '201-500' WHEN \(n)>=501 THEN '500+' ELSE 'Unknown' END"
                order = "CASE label WHEN '1-10' THEN 1 WHEN '11-50' THEN 2 WHEN '51-200' THEN 3 WHEN '201-500' THEN 4 WHEN '500+' THEN 5 ELSE 6 END"
            case "tasksCreatedCompleted": modelName = "Tasks"; label = month("createdAt"); second = "sum(CASE WHEN base.taskStatus='COMPLETE' THEN 1 ELSE 0 END)"
            case "tasksByAssignee": modelName = "Tasks"; label = related("Users","user",fallback:"Unassigned")
            case "mcpTasksByAssignee": modelName = "Tasks"; label = related("Users","user",fallback:"Unassigned"); order = "MIN(base.rowid)"
            case "activitiesByType": modelName = "crm_Activities"; label = "base.type"
            case "campaignROI":
                modelName = "crm_campaigns"; label = "base.name"; number = "(SELECT count(*) FROM crm_campaign_sends s WHERE s.campaign_id=base.id)"; group = false; order = "base.id"
            case "topTemplates":
                modelName = "crm_campaigns"; label = "(SELECT name FROM crm_campaign_templates ref WHERE ref.id=base.template_id)"
                number = "(SELECT count(*) FROM crm_campaign_sends s WHERE s.campaign_id=base.id)"; group = false; order = "\(number) DESC,base.id"; tail = " LIMIT 10"
            case "targetGrowth":
                modelName = "crm_TargetLists"; label = month("created_on")
                number = "sum((SELECT count(*) FROM TargetsToTargetLists link JOIN crm_Targets target ON target.id=link.target_id WHERE link.target_list_id=base.id AND target.deletedAt IS NULL))"
            case "activeByYear": modelName = "Users"; label = "strftime('%Y',base.created_on,'localtime')"
            case "userGrowth": modelName = "Users"; label = month("created_on")
            case "usersByRole": modelName = "Users"; label = "upper(substr(COALESCE(base.role,'user'),1,1)) || substr(COALESCE(base.role,'user'),2)"
            default: throw NativeDBError.message("レポートの集計項目が不正です。")
            }
            value = number; secondary = second; grouping = group ? label : nil; ordering = order; suffix = tail
            let model = try schema.model(modelName); var aliases = 0
            let scope = try compile(filter, model:model, alias:"base", counter:&aliases)
            let sql = "SELECT \(label) AS label,\(value) AS value,\(secondary) AS secondary FROM \(quoted(modelName)) base WHERE \(scope.0)" + (grouping.map { " GROUP BY \($0)" } ?? "") + " ORDER BY \(ordering)\(suffix)"
            sqlite3_progress_handler(connection,1000,{ _ in Task.isCancelled ? 1 : 0 },nil)
            defer { sqlite3_progress_handler(connection,0,nil,nil) }
            try Task.checkCancellation()
            do {
                // Filter NULL only after top-10 selection, matching the source's
                // optional template filtering (a missing template consumes a slot).
                try run("INSERT INTO temp.\(reportTable(token))(section,label,value,secondary) SELECT ?,label,value,secondary FROM (\(sql)) WHERE label IS NOT NULL AND value IS NOT NULL", [.text(section)] + scope.1)
            } catch { try Task.checkCancellation(); throw error }
            try Task.checkCancellation()
        }
    }
    func reportPage(_ token: String, section: String, offset: Int = 0, sort: String = "original", ascending: Bool = true) throws -> (rows:[[String:SQLValue]],total:Int) {
        try synchronized {
            guard ["original","label","value"].contains(sort), offset >= 0 else { throw NativeDBError.conflict }
            let table = try reportTable(token)
            let order = sort == "original" ? "id" : sort == "label" ? "label COLLATE native_japanese" : "CAST(value AS REAL)"
            let total = try query("SELECT count(*) AS n FROM temp.\(table) WHERE section=?",[.text(section)]).first!["n"]!.string
            let rows = try query("SELECT id,substr(label,1,1024) AS label,length(label)>1024 AS truncated,value,secondary FROM temp.\(table) WHERE section=? ORDER BY \(order) \(ascending ? "ASC" : "DESC"),id LIMIT 100 OFFSET ?",[.text(section),.integer(Int64(offset))])
            return (rows,Int(total)!)
        }
    }
    /// Full labels remain available for streaming exports even when the display
    /// uses a 1024-character prefix. Byte chunks may split a UTF-8 scalar.
    func reportLabelChunks(_ token: String, rowID: Int64, visit: (Data) throws -> Void) throws {
        try synchronized {
            let table = try reportTable(token); var blob: OpaquePointer?
            guard sqlite3_blob_open(connection,"temp",String(table.dropFirst().dropLast()),"label",rowID,0,&blob) == SQLITE_OK, let blob else { throw NativeDBError.conflict }
            defer { sqlite3_blob_close(blob) }
            let count = Int(sqlite3_blob_bytes(blob)); var position = 0
            while position < count {
                try Task.checkCancellation(); let length = min(16384,count-position); var bytes = Data(count:length)
                let code = bytes.withUnsafeMutableBytes { sqlite3_blob_read(blob,$0.baseAddress,Int32(length),Int32(position)) }; guard code == SQLITE_OK else { throw NativeDBError.conflict }
                try visit(bytes); position += length
            }
        }
    }
}

// Candidate CRM automation bridge: no module/runtime dependencies.
extension NativeDatabase {
    private func opportunityStageHeadKey(_ recordID: String) throws -> String {
        guard let id = UUID(uuidString: recordID) else { throw NativeDBError.message("商談の識別子が不正です。") }
        return "crm.automation.stage.head.v1." + id.uuidString.lowercased()
    }
    /// Always called in the same outer transaction as the actual stage write.
    @discardableResult func enqueueOpportunityStageChange(recordID: String, toStage: String, now: Date = Date()) throws -> String {
        try transaction {
            let key = try opportunityStageHeadKey(recordID)
            guard UUID(uuidString: toStage) != nil else { throw NativeDBError.message("営業段階の識別子が不正です。") }
            let format = ISO8601DateFormatter(); format.formatOptions.insert(.withFractionalSeconds)
            guard now.timeIntervalSince1970.isFinite else { throw NativeDBError.message("営業段階の変更日時が不正です。") }
            let id = try enqueue("crm/opportunity.stage-changed", payload: ["record_id": recordID, "to_stage": toStage], now: now)
            try setMetadata(key, value: id)
            try setMetadata(key + ".timestamp", value: format.string(from: now))
            try cancelObsoleteOpportunityTouches(recordID: recordID, head: id)
            return id
        }
    }
    /// New producers write the durable head atomically. The indexed legacy
    /// query runs only when that opportunity has no metadata yet; retained heads
    /// do not depend on keeping old outbox rows indefinitely.
    func opportunityStageEventHead(recordID: String) throws -> String? {
        try transaction {
            let key = try opportunityStageHeadKey(recordID)
            if let head = try metadata(key), !head.isEmpty { return head }
            try requireWritable()
            try execute("CREATE INDEX IF NOT EXISTS native_crm_stage_legacy_head ON native_outbox(lower(CASE WHEN json_valid(payload) THEN json_extract(payload,'$.record_id') END)) WHERE event='crm/opportunity.stage-changed'")
            guard let row = try query("SELECT id,created_at FROM native_outbox WHERE event='crm/opportunity.stage-changed' AND lower(CASE WHEN json_valid(payload) THEN json_extract(payload,'$.record_id') END)=lower(?) ORDER BY rowid DESC LIMIT 1", [.text(recordID)]).first,
                  let id = row["id"]?.string else { return nil }
            try setMetadata(key, value: id)
            try setMetadata(key + ".timestamp", value: row["created_at"]!.string)
            try cancelObsoleteOpportunityTouches(recordID: recordID, head: id)
            return id
        }
    }
    /// The private envelope timestamp never changes the original event.data.
    /// Returning nil means this event is no longer the accepted generation.
    func opportunityStageEventTimestamp(recordID: String, eventID: String) throws -> String? {
        try transaction {
            guard try opportunityStageEventHead(recordID: recordID) == eventID else { return nil }
            let key = try opportunityStageHeadKey(recordID) + ".timestamp"
            if let timestamp = try metadata(key), !timestamp.isEmpty { return timestamp }
            // Compatibility for an already adopted legacy head with no separate
            // timestamp. A live parent receipt is the only valid fallback.
            guard let event = try job(id: eventID), event.event == "crm/opportunity.stage-changed", event.payload["record_id"]?.lowercased() == recordID.lowercased() else { throw NativeDBError.conflict }
            try setMetadata(key, value: event.createdAt); return event.createdAt
        }
    }
    private func cancelObsoleteOpportunityTouches(recordID: String, head: String) throws {
        try requireWritable()
        try execute("CREATE INDEX IF NOT EXISTS native_crm_stage_touch_scope ON native_outbox(lower(CASE WHEN json_valid(payload) THEN json_extract(payload,'$.record_id') END)) WHERE event='crm.automation.stage.touch'")
        try run("UPDATE native_outbox SET status='cancelled',next_run_at=NULL,lease_token=NULL,lease_until=NULL WHERE event='crm.automation.stage.touch' AND lower(CASE WHEN json_valid(payload) THEN json_extract(payload,'$.record_id') END)=lower(?) AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.stageEventID') END<>? AND status IN ('pending','retry','running','failed') AND delivery_started_at IS NULL", [.text(recordID), .text(head)])
    }
}

// Exact internal terminal-mail recovery boundary. A scan invoked beneath an
// uncommitted transaction must not delete a body based on its tentative result.
extension NativeDatabase {
    func withCommittedMailBodyRecovery(id:String,events:[String],operation:(NativeJob)throws->Bool)throws->Bool? {
        try synchronized {
            guard !isReadOnly,transactionDepth==0 else{return nil}
            return try transaction {
                guard !events.isEmpty,events.count<=13,events.allSatisfy({$0.utf8.count<=128}) else{return false}
                // Hold malformed/large metadata before materializing it in Swift.
                // CASE keeps json_each/type away from invalid JSON. Valid string
                // dictionaries are required; job() otherwise silently returns [:].
                let object = { (column:String) in
                    "CASE WHEN length(CAST(\(column) AS BLOB))<=262144 AND json_valid(\(column)) THEN json_type(\(column))='object' AND NOT EXISTS(SELECT 1 FROM json_each(\(column)) WHERE type<>'text') ELSE 0 END"
                }
                let sql="SELECT id,event,payload,status,attempts,created_at,next_run_at,NULL AS last_error,lease_token,first_attempt_at,delivery_started_at,result FROM native_outbox WHERE id=? AND event IN (\(events.map{_ in "?"}.joined(separator:","))) AND status IN ('done','cancelled') AND \(object("payload")) AND (result IS NULL OR \(object("result")))"
                guard let row=try query(sql,[.text(id)]+events.map(SQLValue.text)).first else{return false}
                return try operation(job(row))
            }
        }
    }
}

// A prepared report's final hardlink may be removed only against a committed
// current job. No cleanup is admitted below an uncommitted outer transaction.
extension NativeDatabase {
    func withCommittedReportPreparationRecovery(id:String,operation:(NativeJob)throws->Bool)throws->Bool? {
        try synchronized {
            guard !isReadOnly,transactionDepth==0 else{return nil}
            return try transaction {
                let object = { (column:String) in
                    "CASE WHEN length(CAST(\(column) AS BLOB))<=262144 AND json_valid(\(column)) THEN json_type(\(column))='object' AND NOT EXISTS(SELECT 1 FROM json_each(\(column)) WHERE type<>'text') ELSE 0 END"
                }
                let sql="SELECT id,event,payload,status,attempts,created_at,next_run_at,NULL AS last_error,lease_token,first_attempt_at,delivery_started_at,result FROM native_outbox WHERE id=? AND event='reports.scheduled' AND \(object("payload")) AND (result IS NULL OR \(object("result")))"
                guard let row=try query(sql,[.text(id)]).first else{return false}
                return try operation(job(row))
            }
        }
    }
}

extension NativeDatabase {
    /// Initial personal setup only. Read-only and fail-closed: no table, model,
    /// metadata, imported row, audit/outbox/cleanup receipt or unknown schema
    /// object may be silently ignored. Caller owns root admission separately.
    func isPristinePersonalWorkspace() throws -> Bool {
        try transaction {
            let native = ["native_metadata", "native_audit", "native_legacy_accounts", "native_outbox",
                "native_ai_key_cleanup", "native_document_objects", "native_document_processing",
                "native_document_text", "native_document_ai_work", "native_document_ai_chunks",
                "native_campaign_audience", "native_campaign_mail_intents", "native_mail_sends",
                "native_campaign_events", "native_campaign_relay_registrations"]
            let expected = Set(schema.models.map(\.name) + native)
            let rows = try query("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT ?", [.integer(Int64(expected.count + 1))])
            guard Set(rows.compactMap { $0["name"]?.string }) == expected,
                  try query("SELECT 1 FROM sqlite_schema WHERE type IN ('view','trigger') LIMIT 1").isEmpty else { return false }
            let metadata = try query("SELECT key,value FROM native_metadata LIMIT 3")
            guard metadata.count == 2,
                  metadata.contains(where: { $0["key"] == .text("schemaSHA256") && $0["value"] == .text(schema.schemaSHA256) }),
                  metadata.contains(where: { $0["key"] == .text("mail.headerSearch.version") && $0["value"] == .text("1") }) else { return false }
            for name in expected.sorted() where name != "native_metadata" {
                if try !query("SELECT 1 FROM \(quoted(name)) LIMIT 1").isEmpty { return false }
            }
            return true
        }
    }
}

// Internal primitives only: no restore/App type dependency or schema addition.
extension NativeDatabase {
    static let restoredJobQuarantineMarkerKey="personal.restore.job-quarantine.v1.marker"
    static let restoredJobQuarantinePrefix="personal.restore.job-quarantine.v1.job."
    private func restoredJobEligible(_ identifier:String)->String {
        "NOT EXISTS(SELECT 1 FROM native_metadata q WHERE q.key='"+Self.restoredJobQuarantinePrefix+"'||"+identifier+")"
    }
    func requireRestoredJobQuarantineBoundary()throws {
        try synchronized {guard transactionDepth==0 else{throw NativeDBError.message("復元前の処理の確認は保存処理の完了後に開始してください。")}}
    }
    func restoredJobQuarantineMarker()throws->String? {
        try synchronized {
            guard let row=try query("SELECT CASE WHEN length(CAST(value AS BLOB))<=32768 THEN value ELSE NULL END value FROM native_metadata WHERE key=?",[.text(Self.restoredJobQuarantineMarkerKey)]).first else{return nil}
            guard case let .text(value)=row["value"] else{throw NativeDBError.message("復元前の処理の確認記録が不正です。")};return value
        }
    }
    func requireRestoredJobQuarantineFence()throws {
        try synchronized {
            let current=try restoredJobQuarantineMarker()
            guard current != nil || restoredJobQuarantineFence != nil else{
                let prefix=Self.restoredJobQuarantinePrefix
                guard try query("SELECT key FROM native_metadata WHERE key>=? AND key<? LIMIT 1",[.text(prefix),.text(String(prefix.dropLast())+"/")]).isEmpty else{throw NativeDBError.message("復元前の処理の確認記録が不足しています。")}
                return
            }
            guard let fence=restoredJobQuarantineFence,current==fence.marker else{throw NativeDBError.message("復元前の処理の確認を完了してから再開してください。")}
            try fence.authorize()
        }
    }
    func attachRestoredJobQuarantine(marker:String,authorize:@escaping ()throws->Void)throws {
        try synchronized {
            guard try restoredJobQuarantineMarker()==marker else{throw NativeDBError.conflict}
            try authorize();restoredJobQuarantineFence=(marker,authorize)
        }
    }
    func putRestoredJobQuarantine(id:String,bindingSHA256:String,rowSHA256:String)throws {
        try requireWritable()
        func hash(_ value:String)->Bool{value.utf8.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
        guard !id.isEmpty,id.utf8.count<=65536,!id.utf8.contains(0),hash(bindingSHA256),hash(rowSHA256) else{throw NativeDBError.conflict}
        let key=Self.restoredJobQuarantinePrefix+id
        if try query("SELECT key FROM native_metadata WHERE key=? AND substr(value,1,65)=?",[.text(key),.text(bindingSHA256+":")]).first != nil{throw NativeDBError.message("復元計画に同じ処理が重複しています。")}
        try setMetadata(key,value:bindingSHA256+":"+rowSHA256)
    }
    func restoredJobQuarantinePage(bindingSHA256:String,after:String="")throws->[(id:String,hash:String)] {
        try synchronized {
            let prefix=Self.restoredJobQuarantinePrefix
            return try query("SELECT key,substr(value,1,130) value FROM native_metadata WHERE key>? AND key>=? AND key<? AND substr(value,1,65)=? ORDER BY key LIMIT 100",
                [.text(prefix+after),.text(prefix),.text(String(prefix.dropLast())+"/"),.text(bindingSHA256+":")]).map{row in
                    let key=row["key"]!.string,value=row["value"]!.string
                    guard key.hasPrefix(prefix),value.utf8.count==129 else{throw NativeDBError.conflict}
                    return(String(key.dropFirst(prefix.count)),String(value.suffix(64)))
                }
        }
    }
}

extension NativeDatabase {
    func personalPrerequisiteReceipt(_ requirement:String)throws->String? {
        guard requirement.utf8.count<=80,requirement.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber)}) else{throw NativeDBError.conflict}
        return try synchronized {
            guard let row=try query("SELECT CASE WHEN length(CAST(value AS BLOB))<=8192 THEN value END value FROM native_metadata WHERE key=?",[.text("personal.restore.prerequisite.v1."+requirement)]).first else{return nil}
            guard let value=row["value"],value != .null else{throw NativeDBError.conflict};return value.string
        }
    }
    func personalPrerequisiteOldJobs(after:String="")throws->[(id:String,event:String,status:String,ambiguous:Bool)] {
        try synchronized {
            try query("""
            SELECT o.id,substr(o.event,1,1025) event,substr(o.status,1,65) status,
            (o.status NOT IN ('pending','retry','failed','done','cancelled') OR
              (o.status NOT IN ('done','cancelled') AND o.delivery_started_at IS NOT NULL AND
                NOT CASE WHEN json_valid(o.result) THEN json_extract(o.result,'$.providerID') IS NOT NULL OR json_extract(o.result,'$.smtpAccepted')='true' OR json_extract(o.result,'$.requestOutcome')='confirmed' ELSE 0 END)) ambiguous
            FROM native_metadata q JOIN native_outbox o ON q.key='personal.restore.job-quarantine.v1.job.'||o.id
            WHERE q.key>? AND q.key<'personal.restore.job-quarantine.v1.job/' ORDER BY q.key LIMIT 100
            """,[.text("personal.restore.job-quarantine.v1.job."+after)]).map{($0["id"]!.string,$0["event"]!.string,$0["status"]!.string,$0["ambiguous"] == .integer(1))}
        }
    }
    func personalPrerequisiteAIKeys(after:String="")throws->[String] {
        try synchronized{try query("SELECT credential_id FROM native_ai_key_cleanup WHERE credential_id>? ORDER BY credential_id LIMIT 100",[.text(after)]).map{$0["credential_id"]!.string}}
    }
    func personalPrerequisiteOldJob(_ id:String)throws->Bool {
        try synchronized{try !query("SELECT 1 FROM native_metadata WHERE key=?",[.text(Self.restoredJobQuarantinePrefix+id)]).isEmpty}
    }
    /// Exact known non-secret worker pointers/cleanup maps only. Retain the
    /// original value durably before replacing the live source. Nothing is sent.
    @discardableResult func personalPrerequisiteArchive(key:String,value:String?,generation:String)throws->Bool {
        let allowed = ["campaignRelay.syncJob.v1","plugins.secrets.cleanup.v1","mcp.signing.cleanup.v1","crm.automation.renewals.next.v1","crm.automation.kill.scan.next.v1","crm.automation.recycle.scan.next.v1"].contains(key) || ["mail.sync.job.","calendar.google.syncJob."].contains(where:key.hasPrefix)
        guard allowed,UUID(uuidString:generation) != nil,key.utf8.count<=256 else{throw NativeDBError.conflict}
        return try transaction {
            try requireRestoredJobQuarantineFence()
            guard let old=try metadata(key),!old.isEmpty else{return false}
            guard old.utf8.count<=262144 else{throw NativeDBError.message("復元前の設定が大きすぎるため個別の確認が必要です。")}
            let archive="personal.restore.prerequisite.archive."+generation+"."+key
            if let prior=try metadata(archive) {
                if prior != old {try setMetadata(archive+"."+UUID().uuidString.lowercased(),value:old)}
            } else{try setMetadata(archive,value:old)}
            try setMetadata(key,value:value ?? "");return true
        }
    }
}

extension NativeDatabase {
    func personalPrerequisiteValidateLocalWork()throws {
        try synchronized {
            guard try query("SELECT 1 FROM native_document_ai_work w LEFT JOIN Documents d ON d.id=w.document_id LEFT JOIN native_outbox o ON o.id=w.job_id WHERE d.id IS NULL OR o.id IS NULL LIMIT 1").isEmpty else{throw NativeDBError.message("文書のAI処理と元データの対応を確認してください。途中の結果は保持しています。")}
        }
    }
}
extension NativeDatabase {
    /// EXISTS short-circuits and uses event/ID indexes; no job payload or scan
    /// array is decoded on each admission check.
    func personalPrerequisiteAmbiguous(events:[String],prefixes:[String],excludingDisabledConnectors:Bool=false)throws->Bool {
        guard events.count<=32,prefixes.count<=8,(events+prefixes).allSatisfy({!$0.isEmpty && $0.utf8.count<=128}) else{throw NativeDBError.conflict}
        if events.isEmpty && prefixes.isEmpty{return false}
        var clauses:[String]=[],values:[SQLValue]=[]
        for event in events{clauses.append("o.event=?");values.append(.text(event))}
        for prefix in prefixes{clauses.append("(o.event>=? AND o.event<?)");values += [.text(prefix),.text(prefix+"\u{10ffff}")]}
        // Only exact typed connector jobs may use this exception. An unscoped
        // dispatch, missing/unknown plugin, malformed payload or enabled source
        // remains held. The old row is never changed.
        let disabled = excludingDisabledConnectors ? """
        AND NOT (o.event IN ('plugin/installed','plugin/after','plugin/event-dispatch','plugin/cron')
          AND COALESCE(CASE WHEN json_valid(o.payload) THEN json_type(o.payload,'$.pluginId')='text'
            AND json_extract(o.payload,'$.pluginId') IN ('odoo-connector','oxo-erp-connector')
            AND EXISTS(SELECT 1 FROM InstalledPlugin p WHERE p.id=json_extract(o.payload,'$.pluginId') AND p.status='DISABLED') ELSE 0 END,0))
        """ : ""
        return try synchronized {
            try !query("""
            SELECT 1 FROM native_outbox o WHERE (\(clauses.joined(separator:" OR ")))
            AND o.status NOT IN ('done','cancelled')
            AND (o.status NOT IN ('pending','retry','failed') OR (o.delivery_started_at IS NOT NULL AND NOT CASE WHEN json_valid(o.result) THEN json_extract(o.result,'$.providerID') IS NOT NULL OR json_extract(o.result,'$.smtpAccepted')='true' OR json_extract(o.result,'$.requestOutcome')='confirmed' ELSE 0 END))
            AND EXISTS(SELECT 1 FROM native_metadata q WHERE q.key='personal.restore.job-quarantine.v1.job.'||o.id) \(disabled) LIMIT 1
            """,values).isEmpty
        }
    }
}

// Personal restored workspaces run only the exact newly-produced, purely-local
// account-protection after intent. This cannot claim any old/other plugin work.
extension NativeDatabase {
    func personalProtectionStoreOversized() throws -> Bool {
        try synchronized { try !query("SELECT 1 blocked FROM PluginData WHERE pluginId='account-protection' AND entityType='' AND entityId='' AND (length(CAST(value AS BLOB))>262144 OR NOT json_valid(value)) LIMIT 1",[]).isEmpty }
    }
    func personalLocalProtectionPending() throws -> Bool {
        try synchronized {
            let sql="SELECT 1 held FROM native_outbox WHERE event='plugin/after' AND CASE WHEN json_valid(payload) THEN json_extract(payload,'$.pluginId') END='account-protection' AND status<>'done' LIMIT 1"
            return try !query(sql,[]).isEmpty
        }
    }
    func claimPersonalLocalProtection(id:String,transitionID:String,now:Date) throws -> NativeJob {
        try requireWritable()
        guard UUID(uuidString:id) != nil,UUID(uuidString:transitionID) != nil else{throw NativeDBError.conflict}
        return try transaction {
            guard try !query("SELECT 1 bounded FROM native_outbox WHERE id=? AND length(CAST(payload AS BLOB))<=262144 AND (result IS NULL OR length(CAST(result AS BLOB))<=262144)",[.text(id)]).isEmpty else{throw NativeDBError.conflict}
            guard let current=try job(id:id),current.event=="plugin/after",current.status=="pending",
                  current.attempts==0,current.firstAttemptAt==nil,current.deliveryStartedAt==nil,
                  current.leaseToken==nil,current.result.isEmpty,
                  current.payload["pluginId"]=="account-protection",
                  current.payload["personalLocalTransition"]==transitionID,
                  Set(current.payload.keys)==Set(["pluginId","input","personalLocalTransition"]) else{throw NativeDBError.conflict}
            let token=UUID().uuidString.lowercased()
            try run("UPDATE native_outbox SET status='running',attempts=attempts+1,lease_token=?,lease_until=?,first_attempt_at=?,next_run_at=NULL WHERE id=?",
                    [.text(token),.real(now.timeIntervalSince1970+300),.real(now.timeIntervalSince1970),.text(id)])
            return try job(id:id)!
        }
    }
}


/// An opaque, exact storage snapshot for the restored-mail review boundary.
/// Includes lease_until, completed_at, raw JSON bytes and future added columns.
struct NativeRestoredMailReviewSnapshot {
    fileprivate let row:[String:SQLValue]
    let digestMaterial:Data
}
extension NativeDatabase {
    func restoredMailReviewSnapshot(_ expected:NativeJob)throws->NativeRestoredMailReviewSnapshot {
        try synchronized {
            guard let current=try job(id:expected.id),current==expected,
                  let row=try query("SELECT rowid AS _review_rowid,* FROM native_outbox WHERE id=?",[.text(expected.id)]).first else{throw NativeDBError.conflict}
            let typed=row.keys.sorted().map{key->[String] in
                let value=row[key]!
                switch value {
                case .null:return[key,"null"]
                case let .text(text):return[key,"text",text]
                case let .integer(number):return[key,"integer",String(number)]
                case let .real(number):return[key,"real",String(number.bitPattern,radix:16)]
                case let .blob(bytes):return[key,"blob",bytes.base64EncodedString()]
                }
            }
            return .init(row:row,digestMaterial:try JSONEncoder().encode(typed))
        }
    }
    /// The caller supplies the current bound authority and exact source-plan
    /// membership. Never claims an old worker lease or unquarantines its ID.
    /// The intermediate state must terminate via the existing domain reviewer
    /// before this savepoint may commit. An enclosing rollback restores all bytes.
    func reviewRestoredRunningMail<T>(_ expected:NativeJob,snapshot:NativeRestoredMailReviewSnapshot,
        quarantineValue:String,authorize:()throws->Void,review:(NativeJob)throws->T)throws->T {
        try requireWritable()
        return try transaction {
            try Task.checkCancellation();try authorize();try requireRestoredJobQuarantineFence()
            guard try restoredJobQuarantineMarker() != nil,
                  try metadata(Self.restoredJobQuarantinePrefix+expected.id)==quarantineValue,
                  quarantineValue.utf8.count==129,
                  try restoredMailReviewSnapshot(expected).digestMaterial==snapshot.digestMaterial,
                  expected.status=="running",
                  ["invoice.email_requested","orders.approval_requested","orders.approval_decided","projects.task_assigned","projects.task_updated","projects.task_commented","crm.task_assigned","crm.task_watched","crm.lead_assigned","campaigns/send-step","reports.scheduled","crm.automation.kill.notice","crm.automation.recycle.notice"].contains(expected.event),
                  expected.deliveryStartedAt != nil || expected.event=="campaigns/send-step" else{throw NativeDBError.conflict}
            // Retain the previous state without copying old lease credentials.
            var result=expected.result
            result["restoreReviewPreviousStatus"]="running"
            let json=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET status='needs_review',lease_token=NULL,lease_until=NULL,result=? WHERE id=?",[.text(json),.text(expected.id)])
            guard let reviewable=try job(id:expected.id),reviewable.canReviewMail else{throw NativeDBError.conflict}
            let value=try review(reviewable)
            try Task.checkCancellation();try authorize()
            guard let after=try job(id:expected.id),after.status=="done",after.result["reviewOutcome"] != nil,
                  try metadata(Self.restoredJobQuarantinePrefix+expected.id)==quarantineValue else{throw NativeDBError.conflict}
            return value
        }
    }
}

extension NativeDatabase {
    func restoredSMTPReviewReceipt(_ key:String)throws->String? {
        guard key.hasPrefix("personal.restore.smtp-review.v1."),key.utf8.count<256 else{throw NativeDBError.conflict}
        return try synchronized {
            guard let row=try query("SELECT CASE WHEN length(CAST(value AS BLOB))<=8192 THEN value END value FROM native_metadata WHERE key=?",[.text(key)]).first else{return nil}
            guard let value=row["value"],value != .null else{throw NativeDBError.conflict};return value.string
        }
    }
    /// A restored, quarantined SMTP result is reconciled locally without claiming
    /// or manufacturing a transport lease. Unknown is handled receipt-only above.
    func reviewRestoredSMTP(_ expected:NativeJob,snapshot:NativeRestoredMailReviewSnapshot,quarantineValue:String,
                           sent:Bool,now:Date,authorize:()throws->Void,
                           localCopy:(NativeJob)throws->[String:String])throws {
        try requireWritable()
        try transaction {
            try Task.checkCancellation();try authorize();try requireRestoredJobQuarantineFence()
            guard try restoredJobQuarantineMarker() != nil,
                  try metadata(Self.restoredJobQuarantinePrefix+expected.id)==quarantineValue,quarantineValue.utf8.count==129,
                  try restoredMailReviewSnapshot(expected).digestMaterial==snapshot.digestMaterial,
                  expected.event=="native.mail.send",!["done","cancelled"].contains(expected.status) else{throw NativeDBError.conflict}
            let accepted=expected.result["smtpAccepted"]=="true"
            if accepted {
                guard sent,["pending","running","retry","failed","needs_review"].contains(expected.status) else{throw NativeDBError.conflict}
                try run("UPDATE native_outbox SET status='pending',lease_token=NULL,lease_until=NULL WHERE id=?",[.text(expected.id)])
            }else {
                guard ["running","needs_review"].contains(expected.status),expected.deliveryStartedAt != nil else{throw NativeDBError.message("送信開始の記録がありません。結果不明のまま保留してください。")}
                if expected.status=="running" {
                    try run("UPDATE native_outbox SET status='needs_review',lease_token=NULL,lease_until=NULL WHERE id=?",[.text(expected.id)])
                }
                try applyMailSendReview(try job(id:expected.id)!,sent:sent,now:now)
            }
            if sent {
                guard let reviewed=try job(id:expected.id),reviewed.status=="pending",reviewed.result["smtpAccepted"]=="true" else{throw NativeDBError.conflict}
                let result=try localCopy(reviewed)
                guard try job(id:reviewed.id)==reviewed else{throw NativeDBError.conflict}
                let json=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
                try run("UPDATE native_outbox SET status='done',result=?,completed_at=?,lease_token=NULL,lease_until=NULL,last_error=NULL,next_run_at=NULL WHERE id=?",[.text(json),.text(ISO8601DateFormatter().string(from:now)),.text(reviewed.id)])
                try releaseMailSendPayload(reviewed.id)
            }
            try Task.checkCancellation();try authorize()
            guard try metadata(Self.restoredJobQuarantinePrefix+expected.id)==quarantineValue,
                  let after=try job(id:expected.id),(sent ? after.status=="done" && after.result["smtpAccepted"]=="true" : after.status=="failed" && after.result["review"]=="notSent" && after.deliveryStartedAt==nil) else{throw NativeDBError.conflict}
        };notifyJobChange()
    }
}

// Restored Google review is local-only: unlike the ordinary reviewer it never
// creates a replacement job. The old ID remains permanently quarantined.
extension NativeDatabase {
    func reviewRestoredCalendarNotApplied(_ expected:NativeJob,snapshot:NativeRestoredMailReviewSnapshot,
        quarantineValue:String,sourceState:String,actor:String,note:String,now:Date,
        authorize:()throws->Void)throws {
        try requireWritable()
        let text=note.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.count<=2000 else{throw NativeDBError.message("Googleで未反映と確認した内容を2000文字以内で入力してください。")}
        try transaction {
            try Task.checkCancellation();try authorize();try requireRestoredJobQuarantineFence()
            guard try metadata(Self.restoredJobQuarantinePrefix+expected.id)==quarantineValue,quarantineValue.utf8.count==129,
                  try restoredMailReviewSnapshot(expected).digestMaterial==snapshot.digestMaterial,
                  expected.event=="calendar/outbound",["running","failed","retry","needs_review"].contains(expected.status),
                  expected.status != "running" || sourceState=="running",
                  ["unknown","rejected"].contains(expected.result["requestOutcome"] ?? ""),expected.result["followUpJob"]==nil else{throw NativeDBError.conflict}
            var result=expected.result
            result["restoreReviewPreviousStatus"]=expected.status
            result["restoreReviewPreviousRequestOutcome"]=expected.result["requestOutcome"]
            let json=String(decoding:try JSONEncoder().encode(result),as:UTF8.self)
            try run("UPDATE native_outbox SET status='needs_review',lease_token=NULL,lease_until=NULL,result=? WHERE id=?",[.text(json),.text(expected.id)])
            guard let reviewable=try job(id:expected.id) else{throw NativeDBError.conflict}
            guard try reviewCalendarNotApplied(reviewable,actor:actor,note:text,now:now,followUp:false)==nil else{throw NativeDBError.conflict}
            try Task.checkCancellation();try authorize()
            guard let after=try job(id:expected.id),after.status=="done",after.result["requestOutcome"]=="reviewedNotApplied",
                  after.result["followUpJob"]==nil,try metadata(Self.restoredJobQuarantinePrefix+expected.id)==quarantineValue else{throw NativeDBError.conflict}
        }
    }
}

// Restored Google continued-hold lookup. Foundation/SQLite only: no Host or
// review UI dependency in the base database's small compilation boundary.
extension NativeDatabase {
    private func personalCalendarHoldSQL(activity:String,connection:String,account:String,event:String)->String {
        let marker="(SELECT value FROM native_metadata WHERE key='personal.restore.job-quarantine.v1.marker')"
        return """
        (\(marker) IS NOT NULL AND EXISTS(
          SELECT 1 FROM native_metadata h
          WHERE h.key>='personal.restore.google-hold.v1.lookup.'
            AND h.key<'personal.restore.google-hold.v1.lookup/'
            AND CASE WHEN NOT json_valid(h.value) THEN 1
              WHEN json_extract(h.value,'$.marker') IS NULL THEN 1
              WHEN json_extract(h.value,'$.marker')<>\(marker) THEN 0
              WHEN json_extract(h.value,'$.version')<>1 OR json_extract(h.value,'$.kind') NOT IN ('global','activity','connection','remote') THEN 1
              WHEN json_extract(h.value,'$.kind')='global' THEN 1
              WHEN json_extract(h.value,'$.kind')='activity' THEN json_extract(h.value,'$.activityID')=\(activity)
              WHEN json_extract(h.value,'$.kind')='connection' THEN
                json_extract(h.value,'$.connectionID')=\(connection)
                OR json_extract(h.value,'$.accountEmail') COLLATE native_email=\(account)
              WHEN json_extract(h.value,'$.kind')='remote' THEN
                json_extract(h.value,'$.remoteEventID')=\(event) AND (
                  json_extract(h.value,'$.connectionID')=\(connection)
                  OR json_extract(h.value,'$.accountEmail') COLLATE native_email=\(account))
              ELSE 1 END))
        """
    }
    private func personalCalendarHoldForJobSQL(_ alias:String)->String {
        // All callers supply a fixed internal alias, never user SQL.
        let activity="json_extract(\(alias).payload,'$.activity_id')"
        let plan="(CASE WHEN json_valid(\(alias).result) AND json_valid(json_extract(\(alias).result,'$.plan')) THEN json_extract(\(alias).result,'$.plan') ELSE '{}' END)"
        let mapping="(SELECT connectionId FROM crm_CalendarEvents WHERE activityId=\(activity) LIMIT 1)"
        let fallback="(SELECT id FROM CalendarConnection WHERE userId=(SELECT createdBy FROM crm_Activities WHERE id=\(activity)) AND provider='google' AND isActive=1 AND scopeLevel='readwrite' ORDER BY createdAt,id LIMIT 1)"
        let connection="COALESCE(json_extract(\(plan),'$.connectionID'),\(mapping),\(fallback))"
        let account="COALESCE(json_extract(\(plan),'$.accountEmail'),(SELECT accountEmail FROM CalendarConnection WHERE id=\(connection)))"
        let event="COALESCE(json_extract(\(plan),'$.eventID'),(SELECT externalId FROM crm_CalendarEvents WHERE activityId=\(activity) AND source='google' LIMIT 1))"
        return personalCalendarHoldSQL(activity:activity,connection:connection,account:account,event:event)
    }
    func requirePersonalCalendarOutboundAllowed(activityID:String,connectionID:String,accountEmail:String,eventID:String)throws {
        try synchronized {
            try requireRestoredJobQuarantineFence()
            // Ordinary workspaces do not interpret restoration metadata.
            guard try restoredJobQuarantineMarker() != nil else{return}
            let blocked=personalCalendarHoldSQL(activity:"c.activity",connection:"c.connection",account:"c.account",event:"c.event")
            guard try query("SELECT 1 FROM (SELECT ? activity,? connection,? account,? event) c WHERE "+blocked,
                [.text(activityID),.text(connectionID),.text(accountEmail),.text(eventID)]).isEmpty else {
                throw NativeDBError.message("復元前の結果不明な予定があるため、このGoogle予定への書込みを保留しています。無関係な予定や読取り同期は利用できます。")
            }
        }
    }
}
