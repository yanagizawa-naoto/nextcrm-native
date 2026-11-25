import Foundation

@main enum CampaignTemplatesTests {
    struct Reference: Decodable {
        struct Merge: Decodable { let source: String; let target: [String:String?]; let escaped: Bool; let expected: String? }
        struct Scope: Decodable { let user: String; let role: String; let owner: String; let deleted: Bool; let read: Bool; let write: Bool }
        let mergeCases: [Merge]; let scopes: [Scope]
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignTemplatesTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Templates-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(), identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String, _ work: () throws -> Void) throws { do { try work() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: "+label+" accepted") }
        let ref = try JSONDecoder().decode(Reference.self,from:Data(contentsOf:resources.appendingPathComponent("build/templates-reference.json")))
        for item in ref.mergeCases {
            let result = CampaignMergeTags.resolve(item.source,target:item.target.compactMapValues{$0},escaped:item.escaped)
            // JS's plain-object tag map accidentally accepts Object.prototype names;
            // native deliberately recognizes only the documented five fields.
            if item.source.contains("{{__proto__}}") { try check(result == item.source,"unknown inherited keys remain literal") }
            else { try check(result == item.expected,"actual source merge fixture") }
        }
        var users: [String:CRMService] = [:]
        for name in ["admin","manager","alice","bob","partner"] { let role = ["alice","bob"].contains(name) ? "user" : name; let u = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE")],actor:identity.id); users[name] = CRMService(db:db,identity:CRMIdentity(id:u["id"].string,role:role,partnerAccountID:nil)) }
        var records: [String:NativeRecord] = [:]
        for name in ["alice","bob"] { for deleted in [false,true] { let s = users[name]!; var r = try s.saveCampaignTemplate(nil,input:["name":.text(name+(deleted ? "削除" : "現役")),"subject_default":.text("件名"),"description":.text("説明\n二行"),"content_html":.text("<table><tr><td>既存😀</td></tr></table>"),"content_json":.text("{\"legacy\":true}")]); if deleted { try s.deleteCampaignTemplate(r); r = try db.get(r.model,key:db.key(for:r))! }; records[name+(deleted ? "-deleted" : "")] = r } }
        for item in ref.scopes where item.user != "unknown" {
            let s = users[item.user]!, row = records[item.owner+(item.deleted ? "-deleted" : "")]!
            let canRead = (try? s.campaignTemplate(row["id"].string)) != nil
            try check(canRead == item.read,"reference read \(item.user)/\(item.owner)/\(item.deleted)")
            if !item.write { try rejects("reference write denial") { _ = try s.saveCampaignTemplate(row,input:["name":.text("不可")]) } }
        }
        let alice = users["alice"]!, initial = records["alice"]!
        let changed = try alice.saveCampaignTemplate(initial,input:["name":.text("日本語に更新😀")])
        try check(changed["content_html"] == initial["content_html"] && changed["content_json"] == initial["content_json"] && changed["description"] == initial["description"],"metadata edit retains exact legacy body")
        try rejects("stale save") { _ = try alice.saveCampaignTemplate(initial,input:["name":.text("競合")]) }
        try rejects("stale delete") { try alice.deleteCampaignTemplate(initial) }
        try rejects("field escalation") { _ = try alice.saveCampaignTemplate(changed,input:["created_by":.text(identity.id)]) }
        for input in [["name":SQLValue.text(" ")],["subject_default":.text("\n")],["content_json":.text("[]")],["content_json":.text("bad")]] { try rejects("invalid fields") { _ = try alice.saveCampaignTemplate(changed,input:input) } }
        try rejects("partner create cannot own unreadable template") { _ = try users["partner"]!.saveCampaignTemplate(nil,input:["name":.text("不可"),"subject_default":.text("不可")]) }
        try rejects("generic delete bypass") { try alice.delete(changed) }
        try alice.deleteCampaignTemplate(changed); let deleted = try db.get(changed.model,key:db.key(for:changed))!
        try check(deleted["deletedBy"] == .text(alice.identity.id) && deleted["deletedAt"] != .null,"delete audit actor")
        try rejects("manager restore") { try users["manager"]!.restoreCampaignTemplate(deleted) }
        try service.restoreCampaignTemplate(deleted); let restored = try service.campaignTemplate(changed["id"].string)
        try check(restored["deletedAt"] == .null && restored["content_html"] == initial["content_html"],"admin restore content")
        try rejects("stale restore") { try service.restoreCampaignTemplate(deleted) }
        try rejects("non-admin trash") { _ = try alice.campaignTemplates(trash:true) }
        try check(try service.campaignTemplates(trash:true).total == 2,"admin trash")
        try check(try alice.campaignTemplates().total == 1 && users["partner"]!.campaignTemplates().total == 0,"list scope")
        try db.transaction { for n in 0..<106 { _ = try service.saveCampaignTemplate(nil,input:["name":.text("大きな本文\(n)"),"subject_default":.text("件名\(n)"),"content_html":.text(String(repeating:"本文",count:4096))]) } }
        let page = try service.campaignTemplates(search:"大きな本文")
        try check(page.total == 106 && page.rows.count == 100,"bounded list")
        try check(page.rows.allSatisfy{$0.record.values["content_html"] == nil && $0.record.values["content_json"] == nil && $0.record.values["description"] == nil},"body excluded from list memory")
        try check(try service.campaignTemplates(search:"大きな本文",offset:100).rows.count == 6,"tail page")
        let reopened = CRMService(db:try open(),identity:identity)
        try check(try reopened.campaignTemplate(restored["id"].string)["name"] == .text("日本語に更新😀"),"reopen persistence")
        let u = try db.get("Users",key:["id":.text(alice.identity.id)])!; _ = try db.update(u,changes:["banned":.integer(1)],actor:identity.id)
        try rejects("fresh banned-user check") { _ = try alice.saveCampaignTemplate(restored,input:["name":.text("不可")]) }
        try rejects("banned list") { _ = try alice.campaignTemplates() }
        print("CampaignTemplatesTests: \(checks) checks passed")
    }
}
