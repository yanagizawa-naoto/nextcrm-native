import Foundation
import SQLite3

@main enum NativeCalendarTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("Calendar FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String,_ operation: () throws -> Void) throws { do { try operation() } catch { checks += 1; return }; throw NativeDBError.message("Calendar expected rejection: "+label) }
    static func sqlValue(_ value: Any) throws -> SQLValue {
        if value is NSNull { return .null }; if let s = value as? String { return .text(s) }; if let n = value as? NSNumber { return .integer(n.int64Value) }; return .text(try NativeCalendarEvents.json(value))
    }
    final class Fixture {
        let root: URL; let db: NativeDatabase; let identity: CRMIdentity; let resources: URL
        init(_ resources: URL) throws {
            self.resources = resources; root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Calendar-"+UUID().uuidString)
            db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        func seed(_ data: [String:Any]) throws {
            for model in ["Users","crm_Accounts","crm_Contacts","crm_Opportunities","crm_Targets","crm_Leads"] {
                for row in data[model] as? [[String:Any]] ?? [] {
                    var values = try row.mapValues(sqlValue)
                    if model == "Users" { values["role"] = .text("admin"); values["userStatus"] = .text("ACTIVE") }
                    _ = try db.insert(model,values:values,actor:identity.id)
                }
            }
        }
        func connection(actor: String, id: String) throws -> NativeRecord { try db.insert("CalendarConnection",values:["id":.text(id),"userId":.text(actor),"provider":.text("google"),"accountEmail":.text("rep@example.invalid"),"refreshTokenEncrypted":.text("native-keychain-reference-only")],actor:identity.id) }
        func sql(_ statements: String) throws {
            var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.message("test connection") }; defer { sqlite3_close(c) }
            guard sqlite3_exec(c,statements,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }
        }
    }
    static func wire(_ value: [String:Any]) throws -> NativeCalendarInput {
        .init(source:NativeCalendarSource(rawValue:value["source"] as! String)!,externalID:value["externalId"] as! String,iCalUID:value["iCalUID"] as? String,connectionID:value["connectionId"] as? String,title:value["title"] as! String,startAt:try NativeCalendarEvents.date(value["startAt"] as! String),endAt:try (value["endAt"] as? String).map(NativeCalendarEvents.date),counterpartyEmails:value["counterpartyEmails"] as! [String],hostEmail:value["hostEmail"] as? String,status:NativeCalendarStatus(rawValue:value["status"] as! String)!,rawPayload:try value["rawPayload"].map(NativeCalendarEvents.json))
    }
    static func normalized(_ value: NativeCalendarNormalized) throws -> [String:Any] {
        switch value {
        case let .skipped(reason):return ["skip":reason]
        case let .event(e):return ["source":e.source.rawValue,"externalId":e.externalID,"iCalUID":e.iCalUID as Any? ?? NSNull(),"connectionId":e.connectionID as Any? ?? NSNull(),"title":e.title,"startAt":try NativeCalendarEvents.stamp(e.startAt),"endAt":try e.endAt.map(NativeCalendarEvents.stamp) as Any? ?? NSNull(),"counterpartyEmails":e.counterpartyEmails,"hostEmail":e.hostEmail as Any? ?? NSNull(),"status":e.status.rawValue,"rawPayload":try e.rawPayload.map{try JSONSerialization.jsonObject(with:Data($0.utf8))} as Any? ?? NSNull()]
        }
    }
    static func run(_ resources: URL) throws {
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/calendar-reference.json"))) as! [String:Any]
        for test in reference["normalization"] as! [[String:Any]] {
            let options = test["options"] as! [String:String], input = try JSONSerialization.data(withJSONObject:test["input"]!)
            let result = try normalized(NativeCalendarEvents.normalizeGoogle(input,connectionID:options["connectionId"]!,accountEmail:options["accountEmail"]!))
            var expected = test["expected"] as! [String:Any]
            if expected["title"] as? String == "Meeting" { expected["title"] = "予定" }
            try check(try NativeCalendarEvents.json(result) == NativeCalendarEvents.json(expected),"actual original Google normalization")
        }
        try rejects("invalid date"){_ = try NativeCalendarEvents.normalizeGoogle(Data("{\"id\":\"x\",\"start\":{\"dateTime\":\"invalid\"},\"attendees\":[{\"email\":\"a@b.invalid\"}]}".utf8),connectionID:"x",accountEmail:"rep@example.invalid")}
        try rejects("malformed JSON above historical boundary"){_ = try NativeCalendarEvents.normalizeGoogle(Data(repeating:32,count:NativeCalendarEvents.maximumPayloadBytes+1),connectionID:"x",accountEmail:"rep@example.invalid")}
        for test in reference["matching"] as! [[String:Any]] {
            let f = try Fixture(resources); try f.seed(test["records"] as! [String:Any])
            let found = try f.db.calendarCounterpartyLinks(test["emails"] as! [String]).map{["entityType":$0.type,"entityId":$0.id]}
            try check(try NativeCalendarEvents.json(found) == NativeCalendarEvents.json(test["expected"]!),"actual original match priority, deleted rows and alternate addresses")
        }
        let f = try Fixture(resources); try f.seed(reference["syncRecords"] as! [String:Any])
        let actor = CRMIdentity(id:"71000000-0000-4000-8000-000000000002",role:"admin",partnerAccountID:nil), connectionID = "71000000-0000-4000-8000-000000000001"
        let connection = try f.connection(actor:actor.id,id:connectionID), importer = NativeCalendarImporter(db:f.db)
        for test in reference["transitions"] as! [[String:Any]] {
            let input = try wire(test["input"] as! [String:Any]), result = try importer.apply(input,authorizedBy:actor), expected = test["expected"] as! [String:Any]
            try check(result.action == expected["action"] as? String && result.reason == expected["reason"] as? String,"actual original calendar state transition")
            if let values = test["activity"] as? [String:Any] {
                let record = try f.db.get("crm_Activities",key:["id":.text(result.activityID!)])!
                let duration = try sqlValue(values["duration"]!)
                try check(record["title"] == .text(values["title"] as! String) && record["status"] == .text(values["status"] as! String) && record["duration"] == duration,"original activity title/status/duration semantics")
                try check(try NativeCalendarEvents.date(record["date"].string) == NativeCalendarEvents.date(values["date"] as! String),"activity time preserves offset and milliseconds")
            }
        }
        let target = try f.db.page("crm_Targets",fields:["first_name","last_name","tags","created_by"],equal:["email":.text("unknown@external.invalid")]).rows.first!
        try check(target["first_name"] == .text("山田") && target["last_name"] == .text("太郎") && target["tags"] == .text("[\"book-a-call\"]") && target["created_by"] == .text(actor.id),"unmatched Calendly invitee creates host-owned target with original tag")
        let event = NativeCalendarInput(source:.calendly,externalID:"rollback",title:"保存中のエラー",startAt:try NativeCalendarEvents.date("2026-08-01T10:00:00.125Z"),counterpartyEmails:["rollback@external.invalid"],hostEmail:"rep@example.invalid")
        let before = try ["crm_Targets","crm_Activities","crm_ActivityLinks","crm_CalendarEvents"].map{try f.db.page($0,fields:[]).total}
        try f.sql("CREATE TRIGGER calendar_test_fail BEFORE INSERT ON crm_CalendarEvents WHEN NEW.externalId='rollback' BEGIN SELECT RAISE(ABORT,'test rollback'); END;")
        try rejects("atomic target/activity/link/mapping rollback"){_ = try importer.apply(event,authorizedBy:actor)}
        let after = try ["crm_Targets","crm_Activities","crm_ActivityLinks","crm_CalendarEvents"].map{try f.db.page($0,fields:[]).total}
        try check(before == after,"mapping failure leaves no partial CRM objects")
        try f.sql("DROP TRIGGER calendar_test_fail")
        let google = NativeCalendarInput(source:.google,externalID:"permission-check",connectionID:connectionID,title:"同期",startAt:event.startAt,counterpartyEmails:["client@external.invalid"],hostEmail:"rep@example.invalid")
        _ = try f.db.update(connection,changes:["isActive":.integer(0)],actor:actor.id)
        try rejects("disconnected Google account"){_ = try importer.apply(google,authorizedBy:actor)}
        let disconnected = try f.db.get("CalendarConnection",key:["id":.text(connectionID)])!; _ = try f.db.update(disconnected,changes:["isActive":.integer(1)],actor:actor.id)
        try rejects("connection of another user"){_ = try importer.apply(google,authorizedBy:f.identity)}
        let user = try f.db.get("Users",key:["id":.text(actor.id)])!; _ = try f.db.update(user,changes:["banned":.integer(1)],actor:actor.id)
        try rejects("revoked actor"){_ = try importer.apply(event,authorizedBy:actor)}
        let revoked = try f.db.get("Users",key:["id":.text(actor.id)])!; _ = try f.db.update(revoked,changes:["banned":.integer(0)],actor:f.identity.id)
        try concurrent(f,event:event,actor:actor)
        let second = try NativeDatabase(url:f.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try second.page("crm_CalendarEvents",fields:[],equal:["externalId":.text("rollback")]).total == 1,"restart preserves single imported mapping")
        print("NativeCalendarTests: \(checks) checks passed; actual original normalization13/matching13/transitions13, local SQLite only")
    }
    static func concurrent(_ f: Fixture,event: NativeCalendarInput,actor: CRMIdentity) throws {
        let second = try NativeDatabase(url:f.db.url,schemaURL:f.resources.appendingPathComponent("schema.json"),sqlURL:f.resources.appendingPathComponent("schema.sql"))
        let group = DispatchGroup(), lock = NSLock(); var results: [NativeCalendarResult] = []; var errors: [Error] = []
        for db in [f.db,second] { group.enter(); DispatchQueue.global().async { defer { group.leave() }; do { let result = try NativeCalendarImporter(db:db).apply(event,authorizedBy:actor); lock.lock(); results.append(result); lock.unlock() } catch { lock.lock(); errors.append(error); lock.unlock() } } }
        guard group.wait(timeout:.now()+15) == .success else { throw NativeDBError.message("calendar concurrency timeout") }
        if let error = errors.first { throw error }
        try check(results.filter{$0.action == "created"}.count == 1 && results.filter{$0.action == "skipped"}.count == 1,"concurrent imports create exactly one activity")
    }
    static func main() { do { try run(URL(fileURLWithPath:CommandLine.arguments[1])) } catch { FileHandle.standardError.write(Data("NativeCalendarTests: \(error)\n".utf8)); exit(1) } }
}
