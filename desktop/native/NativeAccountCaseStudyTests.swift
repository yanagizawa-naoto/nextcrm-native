import AppKit
import Foundation
import SQLite3

@main enum NativeAccountCaseStudyTests {
    static var checks=0
    static let actor="10000000-0000-4000-8000-000000000001",other="10000000-0000-4000-8000-000000000002",id="10000000-0000-4000-8000-000000000003"
    struct Failure:Error {let message:String}
    static func check(_ value:@autoclosure () throws->Bool,_ message:String)throws {guard try value() else {throw Failure(message:message)};checks += 1}
    static func reject(_ label:String,_ block:()throws->Void)throws {do {try block()} catch {checks += 1;return};throw Failure(message:"accepted "+label)}
    static func sql(_ db:NativeDatabase,_ statement:String)throws {
        var handle:OpaquePointer?;guard sqlite3_open(db.url.path,&handle)==SQLITE_OK else {throw Failure(message:"SQL open")};defer {sqlite3_close(handle)}
        guard sqlite3_exec(handle,statement,nil,nil,nil)==SQLITE_OK else {throw Failure(message:String(cString:sqlite3_errmsg(handle)))}
    }
    static func count(_ db:NativeDatabase,_ statement:String)throws->Int {
        var handle:OpaquePointer?,query:OpaquePointer?;guard sqlite3_open(db.url.path,&handle)==SQLITE_OK else{throw Failure(message:"count open")};defer{sqlite3_finalize(query);sqlite3_close(handle)}
        guard sqlite3_prepare_v2(handle,statement,-1,&query,nil)==SQLITE_OK,sqlite3_step(query)==SQLITE_ROW else{throw Failure(message:"count query")};return Int(sqlite3_column_int64(query,0))
    }
    static func same(_ a:NativeRecord?,_ b:NativeRecord)->Bool {a?.values == b.values && a?.revision == b.revision && a?.model == b.model}
    static func seed(_ folder:URL,_ resources:URL,input:[String:Any])throws->(CRMService,NativeRecord) {
        let db=try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let role=input["role"] as? String ?? "admin"
        _ = try db.insert("Users",values:["id":.text(other),"email":.text("other@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:actor)
        if input["missingUser"] as? Bool != true {
            _ = try db.insert("Users",values:["id":.text(actor),"email":.text("actor@example.invalid"),"role":.text(role),"userStatus":.text(input["status"] as? String ?? "ACTIVE"),"banned":.integer(input["banned"] as? Bool == true ? 1:0)],actor:actor)
        }
        let selected=input["scope"] as? String ?? "assigned"
        var row=NativeRecord(model:"crm_Accounts",values:["id":.text(id)],revision:0)
        if input["missing"] as? Bool != true {
            row=try db.insert("crm_Accounts",values:["id":.text(id),"v":.integer(0),"name":.text("導入事例の確認"),"assigned_to":.text(selected=="assigned" && input["missingUser"] as? Bool != true ? actor:other),"createdBy":.text(selected=="created" ? actor:other),"case_study_candidate":.integer(input["candidate"] as? Bool == true ? 1:0),"case_study_approved":.integer(input["approved"] as? Bool == true ? 1:0),"deletedAt":input["deleted"] as? Bool == true ? .text("2026-11-20T00:00:00.000Z"):.null],actor:actor)
            if selected=="watcher" {_ = try db.insert("AccountWatchers",values:["account_id":.text(id),"user_id":.text(actor)],actor:actor)}
        }
        return (.init(db:db,identity:.init(id:input["noSession"] as? Bool == true ? "10000000-0000-4000-8000-000000000099":actor,role:role,partnerAccountID:nil)),row)
    }
    static func json(_ value:Any)throws->Data {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])}
    static func oracle(_ fixture:URL,_ resources:URL,_ root:URL)throws {
        let data=try JSONSerialization.jsonObject(with:Data(contentsOf:fixture)) as! [String:Any],cases=data["cases"] as! [[String:Any]]
        for (index,entry) in cases.enumerated() {
            let input=entry["input"] as! [String:Any],label=input["label"] as! String
            let (service,before)=try seed(root.appendingPathComponent("case-\(index)"),resources,input:input),db=service.db
            let baseline=try db.auditCount("crm_Accounts")
            if input["auditFailure"] as? Bool == true {try sql(db,"CREATE TRIGGER deny_source_audit BEFORE INSERT ON crm_AuditLog BEGIN SELECT RAISE(ABORT,'synthetic source audit'); END;")}
            var error:String?
            do {
                if input["operation"] as! String == "candidate" {_ = try service.setAccountCaseStudyCandidate(before,candidate:input["value"] as! Bool)}
                else {_ = try service.setAccountCaseStudyApproved(before,approved:input["value"] as! Bool)}
            } catch let caught {error=caught.localizedDescription}
            let source=entry["result"] as! [String:Any]
            var expected=source["error"] as? String
            if expected=="Flag the account as a case-study candidate first." {expected=NativeAccountCaseStudyFailure.candidateRequired.localizedDescription}
            try check(error==expected,label+" error: "+String(describing:error))
            let after=try db.get("crm_Accounts",key:["id":.text(id)])
            if let sourceRow=entry["account"] as? [String:Any],let after {
                try check((after["case_study_candidate"] == .integer(1)) == (sourceRow["case_study_candidate"] as! Bool),label+" candidate")
                try check((after["case_study_approved"] == .integer(1)) == (sourceRow["case_study_approved"] as! Bool),label+" approved")
                try check(after["updatedBy"] == ((sourceRow["updatedBy"] as? String).map(SQLValue.text) ?? .null),label+" updater")
                try check(after.revision == before.revision+(expected==nil ? 1:0),label+" exact revision")
            } else {try check(after==nil,label+" missing remains missing")}
            let audits=try db.page("crm_AuditLog",fields:["entityType","entityId","action","changes","userId"],includeDeleted:true).rows
            let expectedAudits=entry["audits"] as! [[String:Any]]
            try check(audits.count==expectedAudits.count,label+" source audit count")
            for (actual,expected) in zip(audits,expectedAudits) {
                for key in ["entityType","entityId","action","userId"] {try check(actual[key].string==expected[key] as! String,label+" audit "+key)}
                try check(json(JSONSerialization.jsonObject(with:Data(actual["changes"].string.utf8))) == json(expected["changes"]!),label+" exact single-field audit")
            }
            try check(db.auditCount("crm_Accounts")==baseline+(expected==nil ? 1:0),label+" mandatory audit")
            try check(count(db,"SELECT count(*) FROM native_outbox") == 0,label+" no fabricated notification/event")
        }
    }
    static func transactionChecks(_ resources:URL,_ root:URL)throws {
        let (service,row)=try seed(root.appendingPathComponent("transactions"),resources,input:[:]),db=service.db
        let native=try db.auditCount("crm_Accounts")
        try reject("outer rollback") {try db.transaction {_ = try service.setAccountCaseStudyCandidate(row,candidate:true);throw Failure(message:"rollback")}}
        try check(same(try db.get("crm_Accounts",key:["id":.text(id)]),row),"outer rollback exact account")
        try check(db.auditCount("crm_Accounts")==native && db.page("crm_AuditLog",fields:[]).total==0,"both audits rollback")
        try sql(db,"CREATE TRIGGER deny_native_audit BEFORE INSERT ON native_audit WHEN NEW.model='crm_Accounts' BEGIN SELECT RAISE(ABORT,'synthetic native audit'); END;")
        try reject("mandatory native audit") {_ = try service.setAccountCaseStudyCandidate(row,candidate:true)}
        try check(same(try db.get("crm_Accounts",key:["id":.text(id)]),row),"mandatory audit failure rolls back change")
        try sql(db,"DROP TRIGGER deny_native_audit")
        let changed=try service.setAccountCaseStudyCandidate(row,candidate:true)
        try reject("stale snapshot") {_ = try service.setAccountCaseStudyApproved(row,approved:true)}
        try check(same(try db.get("crm_Accounts",key:["id":.text(id)]),changed),"stale does not change current")
        let user=try db.get("Users",key:["id":.text(actor)])!
        _ = try db.update(user,changes:["role":.text("user")],actor:actor)
        try reject("revoked role") {_ = try service.setAccountCaseStudyApproved(changed,approved:true)}
        try check(same(try db.get("crm_Accounts",key:["id":.text(id)]),changed),"revoked role leaves account")
        let fresh=CRMService(db:db,identity:.init(id:actor,role:"user",partnerAccountID:nil))
        let assigned=try db.update(changed,changes:["assigned_to":.text(other)],actor:actor)
        try reject("lost account scope") {_ = try fresh.setAccountCaseStudyCandidate(assigned,candidate:false)}
        let manager=try db.update(try db.get("Users",key:["id":.text(actor)])!,changes:["role":.text("manager")],actor:actor)
        let current=CRMService(db:db,identity:.init(id:actor,role:manager["role"].string,partnerAccountID:nil))
        let deleted=try db.setDeleted(assigned,deleted:true,actor:actor)
        try reject("soft delete") {_ = try current.setAccountCaseStudyApproved(deleted,approved:true)}
        let live=try db.setDeleted(deleted,deleted:false,actor:actor)
        let forged=NativeRecord(model:live.model,values:live.values.merging(["case_study_candidate":.integer(0)]){_,new in new},revision:live.revision)
        _ = try current.setAccountCaseStudyApproved(forged,approved:true)
        let last=try db.page("crm_AuditLog",fields:["changes"]).rows.first(where:{$0["changes"].string.contains("case_study_approved")})!
        try check(last["changes"].string.contains("case_study_approved"),"audit uses persisted state not forged values")
        let history=try current.historyText(try db.get("crm_Accounts",key:["id":.text(id)])!)
        try check(history.contains("導入事例の候補") && history.contains("導入事例の承認"),"Japanese history includes dedicated fields")
        let module=CRMModule.find("crm_Accounts")!
        try reject("generic fields") {_ = try current.save(module,original:try db.get("crm_Accounts",key:["id":.text(id)]),input:["case_study_approved":.integer(0)])}
        let custom=CRMModule(model:"crm_Accounts",title:"test",singular:"test",entity:"account",nameFields:["name"],columns:[],fields:[EditorField("case_study_approved","test",.toggle)])
        try reject("custom generic whitelist") {_ = try current.save(custom,original:try db.get("crm_Accounts",key:["id":.text(id)]),input:["case_study_approved":.integer(0)])}
        let beforeGeneric=try db.get("crm_Accounts",key:["id":.text(id)])!
        let afterGeneric=try current.save(module,original:beforeGeneric,input:["name":.text("通常の会社名編集")])
        try check(afterGeneric["name"] == .text("通常の会社名編集") && afterGeneric["case_study_candidate"] == beforeGeneric["case_study_candidate"] && afterGeneric["case_study_approved"] == beforeGeneric["case_study_approved"],"ordinary generic save preserves dedicated flags")
    }
    final class Pause {
        private let condition=NSCondition();private var enteredValue=false,released=false
        var entered:Bool {condition.lock();defer{condition.unlock()};return enteredValue}
        func block(){condition.lock();enteredValue=true;while !released {condition.wait()};condition.unlock()}
        func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
    }
    final class Race {
        private let lock=NSLock();private var successes=0,failures=0
        func add(_ success:Bool){lock.lock();defer{lock.unlock()};if success{successes += 1}else{failures += 1}}
        var counts:(Int,Int){lock.lock();defer{lock.unlock()};return (successes,failures)}
    }
    static func raceChecks(_ resources:URL,_ root:URL)throws {
        let (one,row)=try seed(root.appendingPathComponent("race"),resources,input:[:])
        let two=CRMService(db:try NativeDatabase(url:one.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity:one.identity)
        let group=DispatchGroup(),race=Race()
        for service in [one,two] {group.enter();DispatchQueue.global().async{defer{group.leave()};do{_ = try service.setAccountCaseStudyCandidate(row,candidate:true);race.add(true)}catch{race.add(false)}}}
        try check(group.wait(timeout:.now()+10) == .success,"two SQLite connections joined")
        let result=race.counts;try check(result.0==1 && result.1==1,"same revision accepts exactly one concurrent write")
        try check(try one.db.get("crm_Accounts",key:["id":.text(id)])?.revision == row.revision+1,"race increments once")
        try check(one.db.page("crm_AuditLog",fields:[]).total==1,"race creates one source audit")
    }
    static func readonlyChecks(_ resources:URL,_ root:URL)throws {
        func prepare() throws -> URL {
            let (service,_)=try seed(root.appendingPathComponent("readonly"),resources,input:[:]),url=root.appendingPathComponent("readonly/sealed.sqlite")
            var input:OpaquePointer?,output:OpaquePointer?
            defer{sqlite3_close(input);sqlite3_close(output)}
            guard sqlite3_open_v2(service.db.url.path,&input,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(url.path,&output)==SQLITE_OK,let backup=sqlite3_backup_init(output,"main",input,"main") else{throw Failure(message:"backup open")}
            let step=sqlite3_backup_step(backup,-1),finish=sqlite3_backup_finish(backup)
            guard step==SQLITE_DONE && finish==SQLITE_OK else{throw Failure(message:"backup copy")}
            let inClose=sqlite3_close(input),outClose=sqlite3_close(output);input=nil;output=nil
            guard inClose==SQLITE_OK && outClose==SQLITE_OK else{throw Failure(message:"backup close")}
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            return url
        }
        let url=try prepare(),before=try Data(contentsOf:url)
        let db=try NativeDatabase(readOnlyURL:url,schemaURL:resources.appendingPathComponent("schema.json")),service=CRMService(db:db,identity:.init(id:actor,role:"admin",partnerAccountID:nil))
        let state=try service.accountCaseStudy(id)
        try check(!state.canSetCandidate && !state.canApprove,"readonly exposes neither mutation")
        try reject("readonly candidate") {_ = try service.setAccountCaseStudyCandidate(state.account,candidate:true)}
        try reject("readonly approval") {_ = try service.setAccountCaseStudyApproved(state.account,approved:false)}
        try check(try Data(contentsOf:url)==before,"readonly database bytes unchanged")
    }
    @MainActor static func wait(_ label:String,_ predicate:()->Bool)async throws {
        for _ in 0..<500 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"UI timeout "+label)
    }
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func button(_ view:NSView,_ id:String)throws->NSButton {guard let b=views(view).compactMap({$0 as? NSButton}).first(where:{$0.identifier?.rawValue==id}) else{throw Failure(message:"button "+id)};return b}
    @MainActor static func ui(_ resources:URL,_ root:URL,_ output:URL)async throws {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let (service,row)=try seed(root.appendingPathComponent("ui"),resources,input:[:]),db=service.db
        let controller=try NativeAccountCaseStudyWindow(service:service,accountID:id),view=controller.window.contentView!
        let candidate=try button(view,"case-study-candidate"),approval=try button(view,"case-study-approval"),reload=try button(view,"case-study-reload")
        try check(candidate.title=="候補にする" && candidate.isEnabled && approval.isHidden,"initial actual controls")
        candidate.performClick(nil);try check(controller.isBusy && !controller.confirmDiscard(),"busy close veto")
        try await wait("candidate saved"){!controller.isBusy}
        try check(try db.get("crm_Accounts",key:["id":.text(id)])?["case_study_candidate"] == .integer(1),"actual candidate click persists")
        try check(!approval.isHidden && approval.isEnabled,"approval appears after candidacy")
        approval.performClick(nil);try await wait("approval saved"){!controller.isBusy}
        try check(approval.title=="承認を取り消す","approval reversal visible")
        controller.window.contentView?.layoutSubtreeIfNeeded()
        if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);if let png=bitmap.representation(using:.png,properties:[:]) {try png.write(to:output.appendingPathComponent("approved.png"))}}
        candidate.performClick(nil);try await wait("withdrawal"){!controller.isBusy}
        let withdrawn=try db.get("crm_Accounts",key:["id":.text(id)])!
        try check(withdrawn["case_study_candidate"] == .integer(0) && withdrawn["case_study_approved"] == .integer(0),"actual withdrawal clears approval")
        _ = try db.update(withdrawn,changes:["name":.text("別の更新")],actor:actor)
        candidate.performClick(nil);try await wait("stale"){!controller.isBusy}
        try check(!candidate.isEnabled && reload.isEnabled,"conflict closes mutation until reload")
        reload.performClick(nil);try check(candidate.isEnabled,"reload fresh state")
        let user=try db.get("Users",key:["id":.text(actor)])!;_ = try db.update(user,changes:["banned":.integer(1)],actor:actor)
        candidate.performClick(nil);try await wait("authority revoked"){!controller.isBusy}
        try check(!candidate.isEnabled && !approval.isEnabled,"late authority revoked disables actions")
        try check(controller.confirmDiscard(),"finished operation allows close")
        try check(!controller.window.isVisible,"offscreen actual AppKit only")
        let (rep,_)=try seed(root.appendingPathComponent("ui-rep"),resources,input:["role":"user","candidate":true])
        let repUI=try NativeAccountCaseStudyWindow(service:rep,accountID:id)
        try check(try button(repUI.window.contentView!,"case-study-approval").isHidden,"ordinary assigned rep cannot approve in UI")
        let (busyService,busyRow)=try seed(root.appendingPathComponent("ui-busy"),resources,input:[:]),pause=Pause()
        let busyUI=try NativeAccountCaseStudyWindow(service:busyService,accountID:id),busyButton=try button(busyUI.window.contentView!,"case-study-candidate")
        let held=Task.detached {try busyService.db.transaction {
            let user=try busyService.db.get("Users",key:["id":.text(actor)])!
            _ = try busyService.db.update(user,changes:["banned":.integer(1)],actor:actor)
            pause.block()
        }}
        defer{pause.release()}
        try await wait("writer entered"){pause.entered};busyButton.performClick(nil)
        try await Task.sleep(nanoseconds:20_000_000)
        try check(busyUI.isBusy && !busyUI.confirmDiscard() && !busyUI.windowShouldClose(busyUI.window),"accepted callback owns busy sheet while DB is locked")
        pause.release();try await held.value;try await wait("role gate rechecked"){!busyUI.isBusy}
        try check(same(try busyService.db.get("crm_Accounts",key:["id":.text(id)]),busyRow),"fresh authority after await refuses queued UI mutation")
        try check(!busyButton.isEnabled && busyUI.confirmDiscard(),"failed queued mutation joins before close allowed")
        _ = row
    }
    static func main() async {
        do {
            let resources=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2]);let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CaseStudy-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            try oracle(output.appendingPathComponent("reference.json"),resources,root)
            try transactionChecks(resources,root)
            try readonlyChecks(resources,root)
            try raceChecks(resources,root)
            try await ui(resources,root,output)
            print("{\"checks\":\(checks),\"sourceCases\":43}")
        } catch {fputs("Case-study failure after \(checks): \(error)\n",stderr);exit(1)}
    }
}
