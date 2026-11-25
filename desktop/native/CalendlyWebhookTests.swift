import Foundation
import CryptoKit

@main enum CalendlyWebhookTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("CalendlyWebhook FAIL: "+label) }; checks += 1 }
    static func sign(_ data: Data,key: String,now: Date) -> String {
        let timestamp = String(Int64(now.timeIntervalSince1970)); var input = Data((timestamp+".").utf8); input.append(data)
        return "t="+timestamp+",v1="+HMAC<SHA256>.authenticationCode(for:input,using:SymmetricKey(data:Data(key.utf8))).map{String(format:"%02x",$0)}.joined()
    }
    static func main() { do { try run(); print("CalendlyWebhookTests: \(checks) checks passed; original signature/route fixtures and authenticated native importer") } catch { FileHandle.standardError.write(Data("CalendlyWebhookTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/calendly-reference.json"))) as! [String:Any]
        for fixture in reference["signatures"] as! [[String:Any]] {
            let actual = CalendlyWebhook.verify(Data((fixture["body"] as! String).utf8),signature:fixture["header"] as? String,key:fixture["key"] as! String,receivedAt:Date(timeIntervalSince1970:fixture["now"] as! Double))
            try check(actual == fixture["expected"] as! Bool,"actual original signature decision")
        }
        let routes = reference["routes"] as! [[String:Any]]
        for fixture in routes {
            let result = try CalendlyWebhook.receive(Data((fixture["body"] as! String).utf8),signature:fixture["header"] as? String,key:fixture["key"] as! String,receivedAt:Date(timeIntervalSince1970:fixture["now"] as! Double))
            let sent = fixture["events"] as! [[String:Any]]
            switch result {
            case .skipped:try check(sent.isEmpty,"unsupported/malformed signed delivery produces no CRM mutation")
            case let .event(event):
                var expected = sent.first!["data"] as! [String:Any]
                if expected["title"] as? String == "Calendly meeting" { expected["title"] = "Calendlyの面談" }
                let actual: [String:Any] = ["source":event.source.rawValue,"externalId":event.externalID,"iCalUID":event.iCalUID as Any? ?? NSNull(),"connectionId":event.connectionID as Any? ?? NSNull(),"title":event.title,"startAt":try NativeCalendarEvents.stamp(event.startAt),"endAt":try event.endAt.map(NativeCalendarEvents.stamp) as Any? ?? NSNull(),"counterpartyEmails":event.counterpartyEmails,"hostEmail":event.hostEmail as Any? ?? NSNull(),"status":event.status.rawValue,"rawPayload":try JSONSerialization.jsonObject(with:Data(event.rawPayload!.utf8))]
                try check(try NativeCalendarEvents.json(actual) == NativeCalendarEvents.json(expected),"actual original webhook normalization with Japanese default title")
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CalendlyWebhook-"+UUID().uuidString); defer{try? FileManager.default.removeItem(at:root)}
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), admin = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let host = try db.insert("Users",values:["name":.text("予約の担当者"),"email":.text("rep@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:admin.id)
        let fixture = routes[0], data = Data((fixture["body"] as! String).utf8), key = fixture["key"] as! String, date = Date(timeIntervalSince1970:fixture["now"] as! Double), header = fixture["header"] as! String
        func reject(_ label: String,_ action: () throws -> Void) throws { var rejected = false; do { try action() } catch { rejected = true }; try check(rejected,label) }
        for (body,signature,signingKey,time) in [(data+Data(" ".utf8),header,key,date),(data,header,"wrong",date),(data,header,key,date.addingTimeInterval(181))] {
            try reject("tampered or stale notification rejected before import"){ _ = try CalendlyWebhook.receive(body,signature:signature,key:signingKey,receivedAt:time) }
        }
        try check(try db.page("crm_Activities",fields:[]).total == 0,"unauthenticated notifications leave CRM empty")
        guard case let .event(event) = try CalendlyWebhook.receive(data,signature:header,key:key,receivedAt:date) else { throw NativeDBError.conflict }
        try reject("ordinary user cannot impersonate Calendly receiver"){ _ = try NativeCalendarImporter(db:db).apply(event,authorizedBy:.init(id:host["id"].string,role:"user",partnerAccountID:nil)) }
        let first = try NativeCalendarImporter(db:db).apply(event,authorizedBy:admin), repeated = try NativeCalendarImporter(db:db).apply(event,authorizedBy:admin)
        try check(try first.action == "created" && repeated.action == "skipped" && repeated.reason == "unchanged" && db.page("crm_Activities",fields:[]).total == 1,"authenticated duplicate booking leaves one unchanged activity")
        let targets = try db.page("crm_Targets",fields:["created_by"])
        try check(try targets.total == 1 && targets.rows[0]["created_by"] == host["id"] && db.get("crm_Activities",key:["id":.text(first.activityID!)])?["createdBy"] == host["id"],"new invitee and activity retain matched host as original creator")
        var cancelled = try JSONSerialization.jsonObject(with:data) as! [String:Any]; cancelled["event"] = "invitee.canceled"; let cancelledData = try JSONSerialization.data(withJSONObject:cancelled)
        guard case let .event(cancellation) = try CalendlyWebhook.receive(cancelledData,signature:sign(cancelledData,key:key,now:date),key:key,receivedAt:date) else { throw NativeDBError.conflict }
        _ = try NativeCalendarImporter(db:db).apply(cancellation,authorizedBy:admin)
        try check(try db.get("crm_Activities",key:["id":.text(first.activityID!)])?["status"] == .text("cancelled") && db.page("crm_CalendarEvents",fields:[]).total == 1,"signed cancellation updates original mapping and activity")
        let oversized = Data(repeating:65,count:NativeCalendarEvents.maximumPayloadBytes+1)
        try reject("invalid signature rejected before JSON decoding"){ _ = try CalendlyWebhook.receive(oversized,signature:header,key:key,receivedAt:date) }
        try check(!CalendlyWebhook.verify(data,signature:header,key:key,receivedAt:Date(timeIntervalSince1970:.infinity)),"invalid receipt time rejected")
    }
}
