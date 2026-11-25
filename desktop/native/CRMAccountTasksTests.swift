import Foundation
import SQLite3

@main enum CRMAccountTasksTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws { guard try condition() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func rejects(_ label: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL accepted: "+label) }
    static func scalar(_ value: Any) -> SQLValue { if value is NSNull { return .null }; if let n = value as? NSNumber { return .integer(n.int64Value) }; return .text(value as! String) }
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("CRMAccountTasksTests after \(checks) checks: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CRMTaskTests-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        func open() throws -> NativeDatabase { try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let db = try open(); let second = try open()
        let reference = try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/crm-tasks-reference.json"))) as! [String:Any]
        let records = reference["records"] as! [String:[[String:Any]]]; let labels = reference["labels"] as! [String:String]
        let adminID = labels["admin"]!
        try db.transaction { for (model,rows) in records { for row in rows {
            var values = row.mapValues(scalar)
            if values["role"] == .text("unknown") { values["role"] = .text("user") }
            _ = try db.insert(model,values:values,actor:adminID)
        } } }
        func service(_ id: String, _ database: NativeDatabase? = nil) throws -> CRMService {
            let user = try db.get("Users",key:["id":.text(id)])!
            return CRMService(db:database ?? db,identity:CRMIdentity(id:id,role:user["role"].string,partnerAccountID:user["partnerAccountId"] == .null ? nil : user["partnerAccountId"].string))
        }
        func row(_ model: String, _ id: String) throws -> NativeRecord { try db.get(model,key:["id":.text(id)])! }
        func fresh(_ r: NativeRecord) throws -> NativeRecord { try row(r.model,r["id"].string) }
        func sql(_ statement: String) throws {
            var c: OpaquePointer?; guard sqlite3_open(db.url.path,&c) == SQLITE_OK else { throw NativeDBError.message("open test SQL") }; defer { sqlite3_close(c) }
            guard sqlite3_exec(c,statement,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.message(String(cString:sqlite3_errmsg(c))) }
        }
        for test in reference["cases"] as! [[String:Any]] {
            let identity = CRMIdentity(id:test["userId"] as! String,role:test["role"] as! String,partnerAccountID:test["partnerAccountId"] as? String)
            let s = CRMService(db:db,identity:identity)
            for (field,write,deletion) in [("readable",false,false),("writable",true,false),("deletable",true,true)] {
                let allowed = Set(test[field] as! [String])
                for raw in records["crm_Accounts_Tasks"]! {
                    let id = raw["id"] as! String
                    try check(((try? s.assertAccess("crm_Accounts_Tasks",id:id,write:write,deletion:deletion)) != nil) == allowed.contains(id),"source \(field) \(identity.role)/\(raw["title"]!)")
                }
            }
        }
        for test in reference["actionCases"] as! [[String:Any]] {
            let s = try service(test["actorId"] as! String)
            let parent = CRMTaskParent(model:"crm_Accounts",id:test["parentID"] as! String)
            let input: [String:SQLValue] = ["title":.text("日本語タスク"),"content":.text("確認と連絡をお願いします。"),"priority":.text("high"),"user":.text(test["assignedID"] as! String)]
            if test["ok"] as! Bool {
                let task = try s.saveCRMTask(parent:parent,original:nil,input:input)
                for (field,value) in test["data"] as! [String:Any] { try check(task[field] == scalar(value),"source creation field "+field) }
                let jobs = try db.jobs(events:CRMService.crmTaskJobEvents,taskID:task["id"].string)
                try check(jobs.map{$0.payload["recipientEmail"]!}.sorted() == test["recipients"] as! [String],"source recipients, deduplicated")
                try check(task["dueDateAt"] == .null,"omitted due date remains unset")
            } else { try rejects("source create denied") { _ = try s.saveCRMTask(parent:parent,original:nil,input:input) } }
        }
        let alice = try service(labels["alice"]!), bob = try service(labels["bob"]!), partner = try service(labels["partner"]!), admin = try service(adminID)
        let parent = CRMTaskParent(model:"crm_Accounts",id:labels["owned"]!)
        var input: [String:SQLValue] = ["title":.text("営業の確認タスク"),"content":.text("日本語でご連絡ください。😀"),"priority":.text("critical"),"user":.text(bob.identity.id),"dueDateAt":.text("2026-11-20T10:00:00+09:00")]
        var task = try alice.saveCRMTask(parent:parent,original:nil,input:input)
        let taskID = task["id"].string
        let readerTask = try row("crm_Accounts_Tasks",labels["owned-account"]!)
        try check(try alice.crmTaskAccess(readerTask["id"].string).canEdit == false,"account scope read does not grant task edit")
        try rejects("account reader comment denied") { _ = try alice.addCRMTaskComment(taskID:readerTask["id"].string,comment:"拒否") }
        try rejects("account reader status denied") { _ = try alice.setCRMTaskStatus(readerTask,status:"COMPLETE") }
        task = try bob.setCRMTaskStatus(task,status:"COMPLETE")
        try check(task["taskStatus"] == .text("COMPLETE") && task["updatedBy"] == .text(bob.identity.id),"assignee completes with current actor")
        task = try alice.setCRMTaskStatus(task,status:"PENDING")
        try rejects("invalid status") { _ = try alice.setCRMTaskStatus(task,status:"fake") }
        try rejects("protected fields") { _ = try alice.saveCRMTask(original:task,input:["createdBy":.text(adminID)]) }
        try rejects("generic save bypass") { _ = try admin.save(.crmTask,original:task,input:["title":.text("無効")]) }
        try rejects("generic delete bypass") { try admin.delete(task) }
        try rejects("wrong model despite matching id") { _ = try alice.setCRMTaskStatus(NativeRecord(model:"Tasks",values:task.values,revision:task.revision),status:"COMPLETE") }
        try rejects("parent move bypass") { _ = try alice.saveCRMTask(parent:CRMTaskParent(model:"crm_Accounts",id:labels["other"]!),original:task,input:[:]) }
        let stale = task; let alice2 = try service(alice.identity.id,second)
        task = try alice2.saveCRMTask(original:task,input:["title":.text("二接続の更新")])
        try rejects("stale editor") { _ = try alice.saveCRMTask(original:stale,input:["title":.text("古い画面")]) }
        try rejects("stale delete") { try alice.deleteCRMTask(stale) }
        let comment = try bob.addCRMTaskComment(taskID:taskID,comment:"顧客へ連絡済みです。😀")
        try check(comment["assigned_crm_account_task"] == .text(taskID) && comment["task"] == .null && comment["user"] == .text(bob.identity.id),"correct comment FK/actor")
        try check(try alice.crmTaskComments(taskID:taskID).total == 1,"creator reads comments")
        try rejects("blank comment") { _ = try bob.addCRMTaskComment(taskID:taskID,comment:" \n") }
        let ptask = try row("crm_Accounts_Tasks",labels["partner-client"]!)
        _ = try partner.addCRMTaskComment(taskID:ptask["id"].string,comment:"パートナーのコメント")
        try check(try partner.crmTaskAccess(ptask["id"].string).canDelete == false,"partner may edit/comment but not delete")
        try rejects("partner deletes denied") { try partner.deleteCRMTask(ptask) }
        let source = root.appendingPathComponent("文書.txt"); try Data("タスクの関連資料".utf8).write(to:source)
        let doc = try alice.commitDocument(alice.stageDocument(source),linkedTo:DocumentLink(model:task.model,id:taskID))
        let query = DocumentQuery(linkedTo:DocumentLink(model:task.model,id:taskID))
        try check(try alice.documentPage(query).total == 1,"CRM task document junction connected")
        try check(try bob.documentPage(query).total == 0,"task read alone does not reveal private document")
        try rejects("readonly parent document attach denied") { try alice.setDocumentLink(doc,to:DocumentLink(model:task.model,id:readerTask["id"].string),linked:true) }
        try alice.setDocumentLink(doc,to:DocumentLink(model:task.model,id:taskID),linked:false)
        try check(try alice.documentPage(query).total == 0,"document disconnect")
        try alice.setDocumentLink(fresh(doc),to:DocumentLink(model:task.model,id:taskID),linked:true)
        let opportunity = CRMTaskParent(model:"crm_Opportunities",id:labels["client-opportunity"]!)
        let opportunityTask = try partner.saveCRMTask(parent:opportunity,original:nil,input:input)
        try check(opportunityTask["account"] == .null && opportunityTask["opportunity_id"] == .text(opportunity.id) && opportunityTask["user"] == .text(partner.identity.id),"opportunity parent and partner self assignment")
        try check(try partner.crmTaskPage(CRMTaskQuery(parent:opportunity)).total == 2,"opportunity related list")
        try rejects("unreadable parent list") { _ = try alice.crmTaskPage(CRMTaskQuery(parent:opportunity)) }
        input["priority"] = .text("unknown")
        try rejects("invalid priority") { _ = try alice.saveCRMTask(parent:parent,original:nil,input:input) }; input["priority"] = .text("medium")
        input["dueDateAt"] = .text("not-a-date")
        try rejects("invalid date") { _ = try alice.saveCRMTask(parent:parent,original:nil,input:input) }; input["dueDateAt"] = .null
        let beforeCount = try admin.crmTaskPage(CRMTaskQuery()).total
        let beforeJobs = try db.jobs(events:CRMService.crmTaskJobEvents).count
        try sql("CREATE TRIGGER fail_crm_task_notice BEFORE INSERT ON native_outbox WHEN NEW.event LIKE 'crm.task_%' BEGIN SELECT RAISE(ABORT, 'forced notice rollback'); END")
        try rejects("atomic create/notice rollback") { _ = try alice.saveCRMTask(parent:parent,original:nil,input:input) }
        try check(try admin.crmTaskPage(CRMTaskQuery()).total == beforeCount && db.jobs(events:CRMService.crmTaskJobEvents).count == beforeJobs,"failed notice leaves neither task nor job")
        try sql("DROP TRIGGER fail_crm_task_notice")
        try sql("CREATE TRIGGER fail_crm_task_delete BEFORE DELETE ON crm_Accounts_Tasks BEGIN SELECT RAISE(ABORT, 'forced task rollback'); END")
        try rejects("atomic delete rollback") { try alice.deleteCRMTask(task) }
        try check(try alice.crmTaskComments(taskID:taskID).total == 1 && alice.documentPage(query).total == 1,"failed delete preserves comments and links")
        try sql("DROP TRIGGER fail_crm_task_delete")
        // Stress both paged lists and deletion loops beyond one SQL page.
        for i in 0..<105 { _ = try bob.addCRMTaskComment(taskID:taskID,comment:"コメント\(i)") }
        try check(try alice.crmTaskComments(taskID:taskID).rows.count == 100 && alice.crmTaskComments(taskID:taskID,offset:100).rows.count == 6,"comment pagination")
        for i in 0..<105 { var data = input; data["title"] = .text("ページ確認\(i)"); data["user"] = .text(alice.identity.id); _ = try alice.saveCRMTask(parent:parent,original:nil,input:data) }
        let page = try alice.crmTaskPage(CRMTaskQuery(parent:parent,search:"ページ確認"))
        let page2 = try alice.crmTaskPage(CRMTaskQuery(parent:parent,search:"ページ確認"),offset:100)
        try check(page.total == 105 && page.rows.count == 100 && page2.rows.count == 5,"100-row task pagination")
        try check(page.rows.allSatisfy{$0.record["content"] == .null},"task list excludes body")
        try check(Set(page.rows.map{$0.record["id"].string}).isDisjoint(with:page2.rows.map{$0.record["id"].string}),"pages do not overlap")
        try check(try alice.crmTaskPage(CRMTaskQuery(parent:parent,status:"PENDING")).rows.contains{$0.record["id"] == .text(taskID)},"status filter")
        try check(try alice.crmTaskPage(CRMTaskQuery(search:"%_")).total == 0,"literal wildcard search")
        // A role or ban change must be honored by an already-open service.
        let aliceUser = try row("Users",alice.identity.id)
        _ = try db.update(aliceUser,changes:["banned":.integer(1)],actor:adminID)
        try rejects("revoked writer") { _ = try alice.addCRMTaskComment(taskID:taskID,comment:"拒否") }
        try rejects("revoked reader") { _ = try alice.crmTaskPage(CRMTaskQuery()) }
        _ = try db.update(fresh(aliceUser),changes:["banned":.integer(0)],actor:adminID)
        try alice.deleteCRMTask(task)
        try check(try db.get(task.model,key:["id":.text(taskID)]) == nil,"task removed")
        try check(try db.page("tasksComments",fields:[],equal:["assigned_crm_account_task":.text(taskID)]).total == 0,"all106 comments removed")
        try check(try db.page("DocumentsToCrmAccountsTasks",fields:[],equal:["crm_accounts_task_id":.text(taskID)]).total == 0,"document links removed")
        try check(try alice.documentRecord(doc["id"].string)["id"] == doc["id"] && FileManager.default.fileExists(atPath:alice.documentFile(doc["id"].string).path),"document file survives task deletion")
        try check(try service(alice.identity.id,open()).crmTaskPage(CRMTaskQuery(parent:parent,search:"ページ確認")).total == 105,"persistence after reopen")
        try check(try db.integrityCheck(),"foreign key and integrity checks")
        print("CRM account tasks: \(checks) checks passed; original scope252/action4 fixtures, bounded pages, concurrent edits and atomic rollback")
    }
}
