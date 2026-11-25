import Foundation
import SQLite3

@main enum CRMRelationshipsTests {
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("CRMRelationshipsTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RelationshipsTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")); let admin = CRMService(db:db,identity:identity)
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("FAIL: \(label)") }; checks += 1 }
        func rejects(_ label: String,_ body: () throws -> Void) throws { do { try body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: \(label) was accepted") }
        func user(_ name: String,_ role: String = "user") throws -> NativeRecord { try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"userStatus":.text("ACTIVE"),"role":.text(role)],actor:identity.id) }
        func service(_ u: NativeRecord) -> CRMService { CRMService(db:db,identity:CRMIdentity(id:u["id"].string,role:u["role"].string,partnerAccountID:nil)) }
        let alice = try user("alice"); let bob = try user("bob"); let manager = try user("manager","manager"); let partner = try user("partner","partner")
        let a = service(alice); let b = service(bob); let p = service(partner)
        func save(_ s: CRMService,_ name: String,_ input: [String:SQLValue]) throws -> NativeRecord { try s.save(CRMModule.find("crm_"+name)!,original:nil,input:input) }
        func reload(_ r: NativeRecord) throws -> NativeRecord { try db.get(r.model,key:db.key(for:r))! }
        func count(_ model: String) throws -> Int { try db.page(model,fields:[],includeDeleted:true).total }
        func events() throws -> Int {
            var c: OpaquePointer?; var statement: OpaquePointer?
            guard sqlite3_open_v2(db.url.path,&c,SQLITE_OPEN_READONLY,nil) == SQLITE_OK else { throw NativeDBError.message("test open") }
            defer { sqlite3_finalize(statement); sqlite3_close(c) }
            guard sqlite3_prepare_v2(c,"SELECT count(*) FROM native_outbox",-1,&statement,nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { throw NativeDBError.message("test outbox query") }
            return Int(sqlite3_column_int64(statement,0))
        }
        let list = try save(a,"TargetLists",["name":.text("東京の営業対象")]); let otherList = try save(b,"TargetLists",["name":.text("非公開リスト")])
        let target = try save(a,"Targets",["last_name":.text("佐藤"),"first_name":.text("花子"),"company":.text("株式会社東京"),"company_email":.text("company@example.invalid"),"company_phone":.text("03-0000-1234"),"company_website":.text("https://example.invalid"),"email":.text("person@example.invalid"),"personal_email":.text("private@example.invalid"),"mobile_phone":.text("090-0000-0000"),"office_phone":.text("03-0000-5678"),"position":.text("部長"),"social_x":.text("x-profile"),"city":.text("千代田区"),"country":.text("日本"),"employees":.text("12"),"description":.text("引き継ぐ会社メモ"),"tags":.text("[\"東京\"]"),"do_not_email":.integer(1)])
        let privateTarget = try save(b,"Targets",["last_name":.text("非公開")])
        try check(try a.addTargets([target["id"].string,privateTarget["id"].string],to:list["id"].string) == 1,"bulk filters unauthorized targets")
        let membershipAudit = try db.auditCount("TargetsToTargetLists")
        try check(try a.addTargets([target["id"].string,target["id"].string],to:list["id"].string) == 0 && db.auditCount("TargetsToTargetLists") == membershipAudit,"duplicate membership is idempotent")
        try rejects("unauthorized list modification") { _ = try a.addTargets([target["id"].string],to:otherList["id"].string) }
        try rejects("partner list access") { _ = try p.targetListPage(list["id"].string,candidates:false) }
        _ = try admin.addTargets([privateTarget["id"].string],to:list["id"].string)
        try check(try a.targetListPage(list["id"].string,candidates:false).total == 2,"list read exposes member summaries")
        try rejects("list membership does not grant target edit") { _ = try a.save(CRMModule.find("crm_Targets")!,original:privateTarget,input:["last_name":.text("不正")]) }
        try check(try a.removeTargets([privateTarget["id"].string],from:list["id"].string) == 1 && count("crm_Targets") == 2,"remove relationship retains target")
        try check(try a.removeTargets([privateTarget["id"].string],from:list["id"].string) == 0,"unlink retry safe")
        try db.transaction { for index in 0..<105 { _ = try save(a,"Targets",["last_name":.text("候補-\(index)")]) } }
        let candidates = try a.targetListPage(list["id"].string,candidates:true)
        try check(candidates.total == 105 && candidates.rows.count == 100,"candidate list bounded to 100")
        let allIDs = try a.allTargetListIDs(list["id"].string,candidates:true,search:"候補-")
        try check(allIDs.count == 105 && !allIDs.contains(target["id"].string),"select all spans pages and excludes existing")
        try check(try a.addTargets(Array(allIDs),to:list["id"].string) == 105,"bulk addition across pages")
        try check(try a.targetListPage(list["id"].string,candidates:false,offset:100).rows.count == 6,"member pagination")
        try check(try a.removeTargets(Array(allIDs),from:list["id"].string) == 105,"bulk removal across pages")
        try check(try a.historyText(reload(list)).contains("営業対象をリストから解除"),"membership change audit")
        let deletedTarget = try save(a,"Targets",["last_name":.text("削除対象")]); try a.delete(deletedTarget)
        try check(try a.addTargets([deletedTarget["id"].string],to:list["id"].string) == 0,"deleted target cannot be added")
        let account = try save(a,"Accounts",["name":.text("ウォッチ対象")]); let privateAccount = try save(b,"Accounts",["name":.text("権限なし")])
        try rejects("watch cannot grant own access") { _ = try a.setWatching(privateAccount["id"].string,enabled:true) }
        try check(try a.setWatching(account["id"].string,enabled:true) && a.isWatching(account["id"].string),"watch self")
        try check(try !a.setWatching(account["id"].string,enabled:true),"watch retry idempotent")
        _ = try db.update(reload(account),changes:["createdBy":bob["id"],"assigned_to":bob["id"]],actor:identity.id)
        try check(try a.fullRecord(account)["name"] == account["name"],"watcher retains authorized scope")
        _ = try a.setWatching(account["id"].string,enabled:false)
        try rejects("unwatch revokes watcher-only access") { _ = try a.fullRecord(account) }
        try rejects("ordinary user cannot assign partner") { _ = try b.setPartner(reload(account),userID:partner["id"].string) }
        var assigned = try service(manager).setPartner(reload(account),userID:partner["id"].string)
        try check(try p.fullRecord(assigned)["name"] == assigned["name"],"partner assignment grants account scope")
        try rejects("partner cannot watch") { _ = try p.setWatching(assigned["id"].string,enabled:true) }
        try rejects("nonpartner assignee") { _ = try admin.setPartner(assigned,userID:alice["id"].string) }
        try rejects("stale partner update") { _ = try admin.setPartner(account,userID:nil) }
        assigned = try admin.setPartner(assigned,userID:nil)
        try rejects("cleared partner loses scope") { _ = try p.fullRecord(assigned) }
        try check(try admin.historyText(assigned).contains("外部パートナー設定"),"partner changes audited")
        let converted = try a.convertTarget(target,createOpportunity:false)
        try check(converted.account["name"] == target["company"] && converted.account["email"] == target["company_email"] && converted.account["billing_city"] == target["city"] && converted.account["description"] == target["description"],"account conversion mapping")
        try check(converted.contact["last_name"] == target["last_name"] && converted.contact["accountsIDs"] == converted.account["id"] && converted.contact["social_twitter"] == target["social_x"] && converted.contact["email"] == target["email"],"contact conversion and links")
        try check(try reload(target)["do_not_email"] == .integer(1) && reload(target)["tags"] == target["tags"] && reload(target)["converted_at"] != .null,"source target and opt-out retained")
        let counts = try [count("crm_Accounts"),count("crm_Contacts"),events()]
        let duplicate = try a.convertTarget(target,createOpportunity:false)
        try check(duplicate.account["id"] == converted.account["id"] && duplicate.contact["id"] == converted.contact["id"] && (try [count("crm_Accounts"),count("crm_Contacts"),events()]) == counts,"conversion retry returns existing records without events")
        try rejects("cannot convert another owner's target") { _ = try a.convertTarget(privateTarget,createOpportunity:true) }
        try rejects("cannot convert deleted target") { _ = try a.convertTarget(deletedTarget,createOpportunity:true) }
        try rejects("partner cannot convert") { _ = try p.convertTarget(target,createOpportunity:true) }
        let changed = try save(a,"Targets",["last_name":.text("変更前")])
        _ = try a.save(CRMModule.find("crm_Targets")!,original:changed,input:["last_name":.text("変更後")])
        try rejects("stale target rejected before conversion") { _ = try a.convertTarget(changed,createOpportunity:true) }
        let stage = try db.insert("crm_Opportunities_Sales_Stages",values:["name":.text("初回受付"),"order":.integer(-50),"stage_kind":.text("new")],actor:identity.id)
        func campaign(_ name: String,_ status: SQLValue) throws -> (NativeRecord,NativeRecord) {
            let c = try db.insert("crm_campaigns",values:["v":.integer(0),"name":.text(name),"created_by":bob["id"],"status":status],actor:identity.id)
            let template = try db.insert("crm_campaign_templates",values:["name":.text(name),"content_html":.text("<p>検証用</p>"),"content_json":.text("{}")],actor:identity.id)
            let step = try db.insert("crm_campaign_steps",values:["campaign_id":c["id"],"order":.integer(0),"template_id":template["id"],"subject":.text(name)],actor:identity.id)
            return (c,step)
        }
        let oldCampaign = try campaign("古い配信",.text("sent")); let latestCampaign = try campaign("直近の配信",.null); let deletedCampaign = try campaign("削除済み配信",.text("deleted"))
        for (campaign,date) in [(oldCampaign,"2026-11-14T00:00:00Z"),(latestCampaign,"2026-11-14T01:00:00Z"),(deletedCampaign,"2026-11-14T02:00:00Z")] {
            _ = try db.insert("crm_campaign_sends",values:["campaign_id":campaign.0["id"],"step_id":campaign.1["id"],"target_id":target["id"],"email":target["email"],"sent_at":.text(date)],actor:identity.id)
        }
        let deal = try a.convertTarget(target,createOpportunity:true)
        try check(deal.opportunity?["account"] == converted.account["id"] && deal.opportunity?["contact"] == converted.contact["id"],"deal reuses converted account/contact")
        try check(deal.opportunity?["campaign"] == latestCampaign.0["id"] && deal.opportunity?["sales_stage"] == stage["id"],"latest live campaign and first ordered stage")
        let dealCount = try count("crm_Opportunities"); let eventCount = try events()
        try check(try a.convertTarget(target,createOpportunity:true).opportunity?["id"] == deal.opportunity?["id"] && count("crm_Opportunities") == dealCount && events() == eventCount,"deal retry idempotent")
        let gated = try db.update(stage,changes:["stage_kind":.text("qualified")],actor:identity.id)
        let rollback = try save(a,"Targets",["last_name":.text("変換取消")])
        let beforeRollback = try [count("crm_Accounts"),count("crm_Contacts"),count("crm_Opportunities"),events(),db.auditCount("crm_Targets")]
        try rejects("approval-gated initial stage rolls back entire conversion") { _ = try a.convertTarget(rollback,createOpportunity:true) }
        try check(try reload(rollback)["converted_at"] == .null && [count("crm_Accounts"),count("crm_Contacts"),count("crm_Opportunities"),events(),db.auditCount("crm_Targets")] == beforeRollback,"no partial records/audit/outbox after rollback")
        _ = try db.update(gated,changes:["stage_kind":.text("new")],actor:identity.id)
        let secondConnection = try open(); let second = CRMService(db:secondConnection,identity:a.identity)
        let concurrent = try save(a,"Targets",["last_name":.text("同時変換")])
        let lock = NSLock(); var ids: [String] = []; var errors: [String] = []
        DispatchQueue.concurrentPerform(iterations:2) { index in
            do { let result = try (index == 0 ? a : second).convertTarget(concurrent,createOpportunity:true); lock.lock(); ids.append(result.opportunity!["id"].string); lock.unlock() }
            catch { lock.lock(); errors.append(error.localizedDescription); lock.unlock() }
        }
        try check(errors.isEmpty && ids.count == 2 && Set(ids).count == 1,"concurrent connections do not duplicate conversion")
        try admin.delete(try reload(converted.account))
        try rejects("deleted conversion result is not silently recreated") { _ = try a.convertTarget(target,createOpportunity:false) }
        try a.delete(try reload(list))
        try rejects("deleted list cannot accept targets") { _ = try a.addTargets([target["id"].string],to:list["id"].string) }
        try check(try db.integrityCheck(),"SQLite and foreign key integrity")
        print("{\"ok\":true,\"suite\":\"CRMRelationships\",\"checks\":\(checks)}")
    }
}
