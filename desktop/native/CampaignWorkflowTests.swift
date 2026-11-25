import Foundation
import SQLite3

@main enum CampaignWorkflowTests {
    struct Reference: Decodable {
        struct User: Decodable { let name: String; let id: String; let role: String }
        struct Owned: Decodable { let id: String; let created_by: String; let deletedAt: String? }
        struct Campaign: Decodable { let id: String; let created_by: String; let status: String?; let deletedAt: String? }
        struct Scope: Decodable { let user: String; let campaign: String; let read: Bool; let write: Bool }
        struct Step: Decodable { let order: Int64; let template_id: String; let subject: String; let delay_days: Int64; let send_to: String; let scheduled_at: String? }
        struct Creation: Decodable {
            struct Input: Decodable { let name: String; let description: String; let from_name: String; let reply_to: String; let template_id: String; let target_list_ids: [String]; let steps: [Step]; let scheduled_at: String? }
            struct Result: Decodable { struct Steps: Decodable { let create: [Step] }; let status: String; let steps: Steps }
            let input: Input; let result: Result
        }
        struct State: Decodable { let role: String; let status: String; let action: String; let allowed: Bool; let resultStatus: String }
        struct Recipient: Decodable { let status: String; let suppressed: Bool; let opened: Bool; let unsubscribed: Bool; let sendTo: String; let eligible: Bool; let skip: String? }
        let users: [User]; let templates: [Owned]; let lists: [Owned]; let campaigns: [Campaign]; let scopes: [Scope]; let created: [Creation]; let states: [State]; let recipientCases: [Recipient]
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignWorkflowTests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Campaigns-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(), local = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
        func rejects(_ label: String, _ work: () throws -> Void) throws { do { try work() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: "+label+" accepted") }
        func reload(_ r: NativeRecord) throws -> NativeRecord { try db.get(r.model,key:db.key(for:r))! }
        func sql(_ text: String) throws { var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.conflict }; defer{sqlite3_close(c)}; guard sqlite3_exec(c,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) } }
        let reference = try JSONDecoder().decode(Reference.self,from:Data(contentsOf:resources.appendingPathComponent("build/campaigns-reference.json")))
        var services: [String:CRMService] = [:]
        for user in reference.users { if user.role != "unknown" { _ = try db.insert("Users",values:["id":.text(user.id),"name":.text(user.name),"email":.text(user.name+"@example.invalid"),"role":.text(user.role),"userStatus":.text("ACTIVE")],actor:local.id) }; services[user.id] = CRMService(db:db,identity:CRMIdentity(id:user.id,role:user.role,partnerAccountID:nil)) }
        let admin = services[reference.users[0].id]!, alice = services[reference.users[2].id]!, bob = services[reference.users[3].id]!
        for t in reference.templates { _ = try db.insert("crm_campaign_templates",values:["id":.text(t.id),"name":.text("テンプレート"),"subject_default":.text("件名"),"content_html":.text("<p>日本語😀</p>"),"content_json":.text("{\"type\":\"doc\"}"),"created_by":.text(t.created_by),"deletedAt":t.deletedAt.map{.text($0+"T00:00:00Z")} ?? .null],actor:local.id) }
        for l in reference.lists { _ = try db.insert("crm_TargetLists",values:["id":.text(l.id),"name":.text("対象リスト"),"created_by":.text(l.created_by),"deletedAt":l.deletedAt.map{.text($0+"T00:00:00Z")} ?? .null],actor:local.id) }
        for c in reference.campaigns { _ = try db.insert("crm_campaigns",values:["id":.text(c.id),"v":.integer(0),"name":.text("権限比較"),"created_by":.text(c.created_by),"status":c.status.map(SQLValue.text) ?? .null,"deletedAt":c.deletedAt.map{.text($0+"T00:00:00Z")} ?? .null],actor:local.id) }
        for fixture in reference.scopes {
            let s = services[fixture.user]!, row = try db.get("crm_campaigns",key:["id":.text(fixture.campaign)])!
            try check(((try? s.campaign(fixture.campaign)) != nil) == fixture.read,"actual scope read")
            // Metadata editing deliberately follows the MCP's sending lock.
            if !fixture.write { try rejects("actual scope write denial") { _ = try s.saveCampaign(row,input:["description":.text("不可")]) } }
        }
        let base = CampaignWorkflow.date(.text("2026-11-14T10:00:00.125Z"))!
        for fixture in reference.created {
            let i = fixture.input
            let r = try admin.createCampaign(input:["name":.text(i.name),"description":.text(i.description),"from_name":.text(i.from_name),"reply_to":.text(i.reply_to),"template_id":.text(i.template_id)],targetListIDs:i.target_list_ids,steps:i.steps.map{CampaignStepInput(order:$0.order,templateID:$0.template_id,subject:$0.subject,delayDays:$0.delay_days,sendTo:$0.send_to)},scheduledAt:i.scheduled_at.flatMap{CampaignWorkflow.date(.text($0))},now:base)
            try check(r["status"] == .text(fixture.result.status) && r["created_by"] == .text(admin.identity.id),"source creation header")
            let steps = try admin.campaignSteps(r["id"].string).rows
            for (actual,want) in zip(steps,fixture.result.steps.create.sorted{$0.order < $1.order}) { try check(actual["order"] == .integer(want.order) && actual["subject"] == .text(want.subject) && actual["send_to"] == .text(want.send_to),"source sequence fields"); try check(CampaignWorkflow.date(actual["scheduled_at"]) == want.scheduled_at.flatMap{CampaignWorkflow.date(.text($0))},"source scheduling offset") }
            try check(try admin.campaignTargetLists(r["id"].string).total == 2,"atomic list links")
        }
        for x in reference.recipientCases { try check(CampaignWorkflow.followUpEligible(status:x.status,opened:x.opened,unsubscribed:x.unsubscribed,suppressed:x.suppressed,sendTo:x.sendTo) == x.eligible,"source followup predicate"); try check(CampaignWorkflow.sendSkipReason(status:x.status,unsubscribed:x.unsubscribed,suppressed:x.suppressed) == x.skip,"source last gate") }
        let template = reference.templates[0].id, list = reference.lists[0].id
        var campaign = try alice.createCampaign(input:["name":.text("編集の検証")],targetListIDs:[list],steps:[CampaignStepInput(order:0,templateID:template,subject:"初回")])
        let id = campaign["id"].string
        try rejects("other owner") { _ = try bob.saveCampaign(campaign,input:["name":.text("不可")]) }
        try rejects("status bypass") { _ = try alice.saveCampaign(campaign,input:["status":.text("scheduled")]) }
        try rejects("generic delete bypass") { try alice.delete(campaign) }
        try rejects("foreign template") { _ = try alice.saveCampaign(campaign,input:["template_id":.text(reference.templates[1].id)]) }
        try rejects("foreign list") { _ = try alice.setCampaignTargetList(campaign:campaign,listID:reference.lists[1].id,enabled:true) }
        try rejects("duplicate list input") { _ = try alice.createCampaign(input:["name":.text("重複")],targetListIDs:[list,list]) }
        try rejects("duplicate step order") { _ = try alice.createCampaign(input:["name":.text("重複")],steps:[CampaignStepInput(order:0,templateID:template,subject:"一"),CampaignStepInput(order:0,templateID:template,subject:"二")]) }
        try rejects("header injection") { _ = try alice.saveCampaign(campaign,input:["from_name":.text("営業\nX-Header:bad")]) }
        try rejects("invalid reply") { _ = try alice.saveCampaign(campaign,input:["reply_to":.text("bad")]) }
        let old = campaign; campaign = try alice.saveCampaign(campaign,input:["description":.text("改行\n😀")])
        try rejects("stale revision") { _ = try alice.saveCampaign(old,input:["name":.text("古い")]) }
        let step0 = try alice.campaignSteps(id).rows[0]
        let created = try alice.saveCampaignStep(campaign:campaign,original:nil,input:CampaignStepInput(order:1,templateID:template,subject:"追伸",delayDays:3,sendTo:"non_openers")); campaign = created.campaign
        try rejects("stale parent while editing steps") { _ = try alice.deleteCampaignStep(campaign:old,step:created.step) }
        try rejects("regular user schedule") { _ = try alice.scheduleCampaign(campaign,at:base.addingTimeInterval(3600),now:base) }
        let scheduledAt = base.addingTimeInterval(3600); campaign = try admin.scheduleCampaign(campaign,at:scheduledAt,now:base)
        try check(try db.nextJobDate(events:[CampaignWorkflow.scheduleEvent],now:base) != nil,"durable due time exists")
        let token = try db.metadata(CampaignWorkflow.runKey(id))!
        try rejects("non-draft step0 deletion") { _ = try alice.deleteCampaignStep(campaign:campaign,step:try reload(step0)) }
        try rejects("non-draft step0 moving") { _ = try alice.saveCampaignStep(campaign:campaign,original:try reload(step0),input:CampaignStepInput(order:7,templateID:template,subject:"初回")) }
        campaign = try alice.pauseCampaign(campaign)
        try check(campaign["status"] == .text("paused") && (try db.metadata(CampaignWorkflow.runKey(id))) != token,"pause invalidates sleeping command")
        let competitor = CRMService(db:try open(),identity:admin.identity)
        campaign = try competitor.scheduleCampaign(campaign,at:base.addingTimeInterval(7200),now:base)
        try check(try db.get("crm_campaigns",key:["id":.text(id)])!.revision == campaign.revision,"second connection sees schedule")
        var alreadyDue = 0
        while let job = try db.claimJob(events:[CampaignWorkflow.scheduleEvent],now:base) { alreadyDue += 1; try db.finishJob(job,now:base) }
        try check(alreadyDue == 1,"only past scheduled fixture is due")
        try check(try db.claimJob(events:[CampaignWorkflow.scheduleEvent],now:base.addingTimeInterval(3599)) == nil,"future commands cannot be claimed early")
        guard let due = try db.claimJob(events:[CampaignWorkflow.scheduleEvent],now:scheduledAt) else { throw NativeDBError.message("FAIL: exact fractional due time was not claimable") }
        try check(due.payload["campaignId"] == id && due.payload["runToken"] != db.metadata(CampaignWorkflow.runKey(id)),"due superseded command is fenced")
        try db.finishJob(due,result:["skipped":"superseded"],now:scheduledAt)
        let jobs = try db.jobs(events:[CampaignWorkflow.scheduleEvent]); let own = jobs.filter{$0.payload["campaignId"] == id}
        try check(own.count == 2 && own[0].payload["runToken"] != own[1].payload["runToken"],"reschedule generations differ")
        for fixture in reference.states where fixture.action != "send" {
            let owner = alice.identity.id; let record = try db.insert("crm_campaigns",values:["v":.integer(0),"name":.text("状態比較"),"status":.text(fixture.status),"created_by":.text(owner)],actor:admin.identity.id)
            let service = fixture.role == "admin" ? admin : alice
            let result = Result { if fixture.action == "pause" { _ = try service.pauseCampaign(record) } else { try service.deleteCampaign(record) } }
            let allowed = (try? result.get()) != nil
            try check(allowed == fixture.allowed,"source pause/delete transitions")
        }
        // Atomic rollback after the header and a list link have already been written.
        let countBefore = try admin.campaigns().total, auditBefore = try db.auditCount("crm_campaigns")
        try sql("CREATE TRIGGER campaign_step_failure BEFORE INSERT ON crm_campaign_steps BEGIN SELECT RAISE(ABORT,'simulated failure'); END")
        try rejects("creation rollback") { _ = try admin.createCampaign(input:["name":.text("失敗する作成")],targetListIDs:[list],steps:[CampaignStepInput(order:0,templateID:template,subject:"初回")]) }
        try sql("DROP TRIGGER campaign_step_failure")
        try check(try admin.campaigns().total == countBefore && db.auditCount("crm_campaigns") == auditBefore,"rolled back campaign/audit")
        // Bounded SQL dedup, same-case emails merged, differently cased addresses remain separate like source.
        var targets: [NativeRecord] = []
        try db.transaction {
            for i in 0..<108 { let email = i == 1 ? "same@example.invalid" : i == 2 ? "SAME@example.invalid" : i == 0 ? "same@example.invalid" : i == 3 ? "" : "t\(i)@example.invalid"; let t = try db.insert("crm_Targets",values:["last_name":.text("営業対象\(i)"),"email":.text(email),"description":.text(String(repeating:"大きな説明",count:1000)),"do_not_email":.integer(i == 4 ? 1 : 0),"created_by":.text(alice.identity.id)],actor:alice.identity.id); targets.append(t); _ = try db.insert("TargetsToTargetLists",values:["target_id":t["id"],"target_list_id":.text(list)],actor:alice.identity.id) }
        }
        var audience = try alice.campaignAudience(id)
        try check(audience.members == 108 && audience.suppressed == 1 && audience.withoutEmail == 1 && audience.eligible == 106 && audience.unique == 105 && audience.rows.count == 100,"SQL audience totals/dedup/page")
        try check(audience.rows.allSatisfy{$0.values["description"] == nil},"audience body excluded")
        try check(try alice.campaignAudience(id,offset:100).rows.count == 5,"audience tail")
        _ = try db.setDeleted(targets[5],deleted:true,actor:alice.identity.id)
        audience = try alice.campaignAudience(id); try check(audience.members == 107 && audience.unique == 104,"deleted targets excluded")
        try rejects("foreign audience disclosure") { _ = try bob.campaignAudience(id) }
        let standalone = try admin.createCampaign(input:["name":.text("手順なし")])
        try rejects("schedule requires first step") { _ = try admin.scheduleCampaign(standalone,at:scheduledAt,now:base) }
        try rejects("NaN schedule") { _ = try admin.scheduleCampaign(campaign,at:Date(timeIntervalSince1970:.nan),now:base) }
        try check(try db.integrityCheck(),"database integrity")
        print("CampaignWorkflowTests: \(checks) checks passed")
    }
}
