import Foundation

enum NativeCalendarSource: String, Codable { case google, calendly }
enum NativeCalendarStatus: String, Codable { case scheduled, cancelled }
struct NativeCalendarInput {
    let source: NativeCalendarSource
    let externalID: String
    var iCalUID: String? = nil
    var connectionID: String? = nil
    var title: String
    var startAt: Date
    var endAt: Date? = nil
    var counterpartyEmails: [String]
    var hostEmail: String? = nil
    var status: NativeCalendarStatus = .scheduled
    var rawPayload: String? = nil
}
struct NativeCalendarResult: Equatable {
    let action: String
    var reason: String? = nil
    var activityID: String? = nil
}
enum NativeCalendarNormalized { case event(NativeCalendarInput), skipped(String) }

enum NativeCalendarEvents {
    // Historical boundary retained for migration/regression fixtures, not an incoming event cap.
    static let maximumPayloadBytes = 1_048_576
    static func date(_ value: String) throws -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if let date = f.date(from:value) { return date }
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from:value) else { throw NativeDBError.message("カレンダーの日時が不正です。") }
        return date
    }
    static func stamp(_ value: Date) throws -> String {
        guard value.timeIntervalSince1970.isFinite, (-62_135_596_800...253_402_300_799).contains(value.timeIntervalSince1970) else { throw NativeDBError.message("カレンダーの日時が範囲外です。") }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.string(from:value)
    }
    static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])
        return String(decoding:data,as:UTF8.self)
    }
    /// One provider event at a time; callers page the provider feed instead of
    /// retaining a complete calendar. No provider SDK or web renderer is used.
    static func normalizeGoogle(_ data: Data, connectionID: String, accountEmail: String) throws -> NativeCalendarNormalized {
        guard let event = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw NativeDBError.message("カレンダーの予定データが不正です。") }
        guard let id = event["id"] as? String, !id.isEmpty else { return .skipped("no-id") }
        let start = (event["start"] as? [String:Any])?["dateTime"] as? String
        let cancelled = event["status"] as? String == "cancelled"
        if !cancelled && (start == nil || start == "") { return .skipped("all-day") }
        let attendees = event["attendees"] as? [[String:Any]] ?? []
        if !cancelled, attendees.first(where:{$0["self"] as? Bool == true})?["responseStatus"] as? String == "declined" { return .skipped("declined") }
        let own = accountEmail.lowercased(), domain = own.components(separatedBy:"@").dropFirst().first
        let others = cancelled ? [] : attendees.compactMap{$0["email"] as? String}.map{$0.lowercased()}.filter { !$0.isEmpty && $0 != own && $0.components(separatedBy:"@").dropFirst().first != domain }
        if !cancelled && others.isEmpty { return .skipped("no-counterparty") }
        let end = (event["end"] as? [String:Any])?["dateTime"] as? String
        return .event(.init(source:.google,externalID:id,iCalUID:event["iCalUID"] as? String,connectionID:connectionID,title:event["summary"] as? String ?? "予定",startAt:try start.flatMap{$0.isEmpty ? nil : try date($0)} ?? Date(timeIntervalSince1970:0),endAt:cancelled ? nil : try end.flatMap{$0.isEmpty ? nil : try date($0)},counterpartyEmails:others,hostEmail:accountEmail,status:cancelled ? .cancelled : .scheduled,rawPayload:try json(event)))
    }
}

/// Internal importer for authenticated provider responses. Google workers must
/// validate their current connection and Calendly workers must authenticate the
/// webhook before invoking this service. This is not a public webhook handler.
final class NativeCalendarImporter {
    let db: NativeDatabase
    init(db: NativeDatabase) { self.db = db }

    func apply(_ input: NativeCalendarInput, authorizedBy identity: CRMIdentity) throws -> NativeCalendarResult {
        let actor = CRMService(db:db,identity:identity)
        return try db.transaction {
            try actor.authenticated()
            if input.source == .google {
                guard let id = input.connectionID, let connection = try db.get("CalendarConnection",key:["id":.text(id)]),
                      connection["provider"] == .text("google"), connection["isActive"] == .integer(1),
                      connection["userId"] == .text(identity.id),
                      input.hostEmail?.lowercased() == connection["accountEmail"].string.lowercased() else { throw NativeDBError.message("カレンダーの接続が無効か、利用者が変更されています。") }
            } else {
                guard identity.elevated && input.connectionID == nil else { throw NativeDBError.message("予約サービスの取込には管理権限が必要です。") }
            }
            guard !input.externalID.isEmpty, input.externalID.utf8.count <= 4096, !input.externalID.contains("\0"),
                  input.counterpartyEmails.allSatisfy({!$0.contains("\0") && $0.utf8.count <= 4096}) else { throw NativeDBError.message("カレンダーの予定データが不正です。") }
            let start = try NativeCalendarEvents.stamp(input.startAt), end = try input.endAt.map(NativeCalendarEvents.stamp)
            let emails = try NativeCalendarEvents.json(input.counterpartyEmails)
            if let raw = input.rawPayload {
                guard (try? JSONSerialization.jsonObject(with:Data(raw.utf8),options:.fragmentsAllowed)) != nil else { throw NativeDBError.message("カレンダーの予定データが不正です。") }
            }
            var raw: [String:SQLValue] = [:]; if let payload = input.rawPayload { raw["rawPayload"] = .text(payload) }
            if let existing = try db.page("crm_CalendarEvents",fields:["status","activityId","startAt"],equal:["source":.text(input.source.rawValue),"externalId":.text(input.externalID)],limit:1).rows.first {
                if input.status == .cancelled && existing["status"] != .text("cancelled") {
                    guard let activity = try db.get("crm_Activities",key:["id":existing["activityId"]]) else { throw NativeDBError.message("予定に対応する活動が見つかりません。") }
                    _ = try db.update(existing,changes:raw.merging(["status":.text("cancelled")]){_,v in v},actor:identity.id,action:"calendar_cancelled")
                    _ = try db.update(activity,changes:["status":.text("cancelled")],actor:identity.id,action:"calendar_cancelled")
                    return .init(action:"cancelled",activityID:activity["id"].string)
                }
                if input.status == .scheduled, try NativeCalendarEvents.date(existing["startAt"].string) != input.startAt {
                    guard let activity = try db.get("crm_Activities",key:["id":existing["activityId"]]) else { throw NativeDBError.message("予定に対応する活動が見つかりません。") }
                    _ = try db.update(existing,changes:raw.merging(["startAt":.text(start),"endAt":end.map(SQLValue.text) ?? .null,"status":.text("scheduled")]){_,v in v},actor:identity.id,action:"calendar_rescheduled")
                    _ = try db.update(activity,changes:["date":.text(start),"status":.text("scheduled")],actor:identity.id,action:"calendar_rescheduled")
                    return .init(action:"updated",activityID:activity["id"].string)
                }
                return .init(action:"skipped",reason:"unchanged")
            }
            if input.status == .cancelled { return .init(action:"skipped",reason:"cancel-for-unknown") }
            if input.source == .google, try db.calendarHasCalendlyMatch(startAt:start,emails:input.counterpartyEmails) { return .init(action:"skipped",reason:"duplicate-of-calendly") }
            var links = try db.calendarCounterpartyLinks(input.counterpartyEmails)
            if links.isEmpty && input.source == .google { return .init(action:"skipped",reason:"no-match") }
            let host = try input.hostEmail.flatMap { try db.page("Users",fields:["id"],equal:["email":.text($0)],limit:1).rows.first?["id"] } ?? .null
            if links.isEmpty {
                let rawObject = input.rawPayload.flatMap{try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any]}
                let name = (rawObject?["payload"] as? [String:Any])?["name"] as? String ?? input.counterpartyEmails.first ?? "不明"
                let parts = name.split(whereSeparator:{$0.isWhitespace}).map(String.init)
                let target = try db.insert("crm_Targets",values:["first_name":parts.count > 1 ? .text(parts.dropLast().joined(separator:" ")) : .null,"last_name":.text(parts.last ?? ""),"email":input.counterpartyEmails.first.map(SQLValue.text) ?? .null,"tags":.text("[\"book-a-call\"]"),"created_by":host],actor:identity.id)
                links = [("target",target["id"].string)]
            }
            var duration = SQLValue.null
            if let end = input.endAt {
                let minutes = max(0,(end.timeIntervalSince(input.startAt)/60).rounded())
                guard minutes < Double(Int64.max) else { throw NativeDBError.message("予定の所要時間が範囲外です。") }
                duration = .integer(Int64(minutes))
            }
            let activity = try db.insert("crm_Activities",values:["type":.text("meeting"),"title":.text(input.title),"date":.text(start),"duration":duration,"status":.text("scheduled"),"metadata":.text(try NativeCalendarEvents.json(["calendarSource":input.source.rawValue])),"createdBy":host],actor:identity.id)
            for link in links { _ = try db.insert("crm_ActivityLinks",values:["activityId":activity["id"],"entityType":.text(link.type),"entityId":.text(link.id)],actor:identity.id) }
            _ = try db.insert("crm_CalendarEvents",values:raw.merging(["source":.text(input.source.rawValue),"externalId":.text(input.externalID),"iCalUID":input.iCalUID.map(SQLValue.text) ?? .null,"connectionId":input.connectionID.map(SQLValue.text) ?? .null,"activityId":activity["id"],"startAt":.text(start),"endAt":end.map(SQLValue.text) ?? .null,"attendeeEmails":.text(emails),"status":.text("scheduled")]){_,v in v},actor:identity.id)
            return .init(action:"created",activityID:activity["id"].string)
        }
    }
}
