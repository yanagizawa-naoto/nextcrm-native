import AppKit
import SQLite3

@main enum ProjectCompletionTests {
 static var checks=0
 static func check(_ x:@autoclosure () throws->Bool,_ label:String)throws{guard try x() else{throw NativeDBError.message("FAIL "+label)};checks+=1}
 static func rejects(_ label:String,_ f:()throws->Void)throws{do{try f()}catch{checks+=1;return};throw NativeDBError.message("accepted "+label)}
 static func uid(_ n:Int)->String{String(format:"10000000-0000-4000-8000-%012d",n)}
 static func val(_ x:Any)throws->SQLValue{if x is NSNull{return .null};if let n=x as? NSNumber{return .integer(n.int64Value)};if let a=x as? [String]{return .text(String(decoding:try JSONEncoder().encode(a),as:UTF8.self))};return .text(x as! String)}
 static func main(){do{try run()}catch{FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}}
 static func run()throws{
  _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
  let n=URL(fileURLWithPath:CommandLine.arguments[1]),c=URL(fileURLWithPath:CommandLine.arguments[2]);let root=FileManager.default.temporaryDirectory.appendingPathComponent("ProjectCompletion-"+UUID().uuidString)
  defer{NSApp.windows.forEach{$0.orderOut(nil)};try? FileManager.default.removeItem(at:root)}
  func open(_ name:String)throws->NativeDatabase{try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))}
  let fixture=try JSONSerialization.jsonObject(with:Data(contentsOf:c.appendingPathComponent("reference.json"))) as! [String:Any]
  for test in fixture["cases"] as! [[String:Any]]{
   let name=test["name"] as! String,rows=test["rows"] as! [String:[[String:Any]]],db=try open(name)
   try db.transaction{for m in ["Users","Boards","Sections","Tasks","Documents","DocumentsToTasks"]{for r in rows[m] ?? []{_=try db.insert(m,values:r.mapValues(val),actor:uid(1))}}}
   let service=CRMService(db:db,identity:.init(id:test["session"] as! Bool ? uid(1):uid(99),role:test["role"] as! String,partnerAccountID:nil))
   let beforeDoc=try db.get("Documents",key:["id":.text(uid(6))])!,beforeTask=try db.get("Tasks",key:["id":.text(uid(5))])
   if test["list"] as! Bool{try check(try service.list(.projects).rows.map{$0.record["id"].string} == test["order"] as! [String],name+" source order/scope");continue}
   var success=false
   do{
    if test["quick"] as! Bool{_=try service.quickAddProjectTask(boardID:uid(3),section:db.get("Sections",key:["id":.text(uid(4))])!)}
    else{let expected=beforeTask ?? NativeRecord(model:"Tasks",values:["id":.text(uid(5))],revision:0);_=try service.setProjectTaskDocumentLink(beforeDoc,task:expected,linked:!name.contains("unlink"))};success=true
   }catch{}
   let expected=(test["sourceSuccess"] as! Bool) && !(test["nativeDeny"] as! Bool)
   try check(success == expected,name+" actual source outcome")
   try check(try db.get("Documents",key:["id":beforeDoc["id"]])!.values == beforeDoc.values,name+" doc untouched")
   try check(try db.get("Documents",key:["id":beforeDoc["id"]])!.revision == beforeDoc.revision,name+" doc revision untouched")
   if test["quick"] as! Bool,success{
    let created=try db.page("Tasks",fields:["title","content","priority","user","taskStatus","position","createdBy","updatedBy","v"],filter:.not(.equal("id",.text(uid(5))))).rows
    let original=(test["created"] as! [[String:Any]])[0];try check(created.count==1,"quick single row")
    for key in ["title","content","priority","user","taskStatus","position","createdBy","updatedBy","v"]{try check(try created[0][key] == val(original[key]!),name+" "+key)}
    try check(try db.jobs(events:CRMService.projectJobEvents).isEmpty,"quick self has no mail")
   }else if !(test["quick"] as! Bool){
    let links=try db.page("DocumentsToTasks",fields:[]).total
    try check(links == (test["nativeDeny"] as! Bool ? rows["DocumentsToTasks"]!.count:test["links"] as! Int),name+" junction")
    if success{let task=try db.get("Tasks",key:["id":.text(uid(5))])!;try check(task["updatedBy"] == .text(uid(1)),name+" actor");try check(try db.history(task).first?["actor"] == .text(uid(1)),name+" audit")}
   }
   try check(try db.integrityCheck(),name+" integrity")
  }
  let db=try open("boundaries"),identity=try CRMService.bootstrap(db,resources:n.appendingPathComponent("../../prisma")),admin=CRMService(db:db,identity:identity)
  func fresh(_ r:NativeRecord)throws->NativeRecord{try db.get(r.model,key:db.key(for:r))!}
  let user=try db.insert("Users",values:["name":.text("担当者"),"email":.text("assignee@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
  let assignee=CRMService(db:db,identity:.init(id:user["id"].string,role:"user",partnerAccountID:nil))
  let board=try admin.saveProject(original:nil,input:["title":.text("新しいプロジェクト"),"description":.text("説明"),"visibility":.text("public")]);let section=try admin.projectSections(board["id"].string).rows[0]
  var task=try admin.saveProjectTask(sectionID:section["id"].string,original:nil,input:["title":.text("関連付け"),"user":user["id"]])
  let doc=try db.insert("Documents",values:["document_name":.text("他者の公開文書"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("unmigrated:test"),"size":.integer(1),"visibility":.text("public"),"createdBy":.text(identity.id)],actor:identity.id)
  try rejects("generic document write unchanged"){_=try assignee.setDocumentLink(doc,to:.init(model:"Tasks",id:task["id"].string),linked:true)}
  let beforeAudit=try db.auditCount("Tasks")
  try rejects("outer rollback"){try db.transaction{_=try assignee.setProjectTaskDocumentLink(doc,task:task,linked:true);throw NativeDBError.conflict}}
  try check(try db.page("DocumentsToTasks",fields:[]).total==0 && db.auditCount("Tasks")==beforeAudit,"rollback links and task audit")
  let stale=task;task=try db.update(task,changes:["title":.text("別の更新")],actor:identity.id)
  try rejects("task CAS"){_=try assignee.setProjectTaskDocumentLink(doc,task:stale,linked:true)}
  let revisedDoc=try db.update(doc,changes:["description":.text("別の説明")],actor:identity.id)
  try rejects("doc CAS"){_=try assignee.setProjectTaskDocumentLink(doc,task:task,linked:true)}
  _=try db.update(user,changes:["userStatus":.text("INACTIVE")],actor:identity.id)
  try rejects("fresh status"){_=try assignee.setProjectTaskDocumentLink(revisedDoc,task:task,linked:true)}
  _=try db.update(fresh(user),changes:["userStatus":.text("ACTIVE"),"role":.text("partner")],actor:identity.id)
  try rejects("fresh role"){_=try assignee.setProjectTaskDocumentLink(revisedDoc,task:task,linked:true)}
  _=try db.update(fresh(user),changes:["role":.text("user")],actor:identity.id)
  task=try assignee.setProjectTaskDocumentLink(revisedDoc,task:task,linked:true)
  try rejects("duplicate link"){_=try assignee.setProjectTaskDocumentLink(revisedDoc,task:task,linked:true)}
  let second=try db.insert("Documents",values:doc.values.filter{!["id","createdAt","updatedAt"].contains($0.key)},actor:identity.id)
  task=try assignee.setProjectTaskDocumentLink(second,task:task,linked:true)
  try rejects("batch unlink rollback"){try db.transaction{let t=try assignee.setProjectTaskDocumentLink(revisedDoc,task:task,linked:false);_=try assignee.setProjectTaskDocumentLink(second,task:t,linked:false);throw NativeDBError.conflict}}
  try check(try db.page("DocumentsToTasks",fields:[]).total==2,"all batch links restored")
  try rejects("quick-add foreign board"){_=try admin.quickAddProjectTask(boardID:UUID().uuidString,section:section)}
  let newSection=try db.update(section,changes:["title":.text("改訂")],actor:identity.id)
  try rejects("quick section CAS"){_=try admin.quickAddProjectTask(boardID:board["id"].string,section:section)}
  let oldCount=try db.page("Tasks",fields:[]).total
  try rejects("quick outer rollback"){try db.transaction{_=try admin.quickAddProjectTask(boardID:board["id"].string,section:newSection);throw NativeDBError.conflict}}
  try check(try db.page("Tasks",fields:[]).total==oldCount,"quick atomic rollback")
  try ui(db:db,admin:admin,assignee:assignee,board:try fresh(board),task:try fresh(task),section:newSection,doc:revisedDoc)
  // Real immutable snapshot, not a live WAL database disguised as read-only.
  let sealed=root.appendingPathComponent("readonly.sqlite")
  var source:OpaquePointer?,destination:OpaquePointer?
  guard sqlite3_open_v2(db.url.path,&source,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&destination)==SQLITE_OK else{throw NativeDBError.conflict}
  guard let backup=sqlite3_backup_init(destination,"main",source,"main") else{throw NativeDBError.conflict}
  let status=sqlite3_backup_step(backup,-1);sqlite3_backup_finish(backup);sqlite3_close(source);sqlite3_close(destination)
  try check(status==SQLITE_DONE,"read-only synthetic snapshot")
  let ro=try NativeDatabase(readOnlyURL:sealed,schemaURL:n.appendingPathComponent("schema.json"));let readOnly=CRMService(db:ro,identity:identity)
  let retainedLink=try ro.page("DocumentsToTasks",fields:["document_id","task_id"]).rows[0]
  try rejects("readonly association"){_=try readOnly.setProjectTaskDocumentLink(ro.get("Documents",key:["id":retainedLink["document_id"]])!,task:ro.get("Tasks",key:["id":retainedLink["task_id"]])!,linked:false)}
  let sortDB=try open("paging"),sortActor=try CRMService.bootstrap(sortDB,resources:n.appendingPathComponent("../../prisma")),sortService=CRMService(db:sortDB,identity:sortActor)
  try sortDB.transaction{for i in 0..<103{_=try sortDB.insert("Boards",values:["v":.integer(0),"title":.text(String(format:"reverse %03d",102-i)),"description":.text("sort"),"user":.text(sortActor.id),"updatedAt":.text(String(format:"2026-01-%02dT00:00:00Z",1+i%28))],actor:sortActor.id)}}
  let first=try sortService.list(.projects),last=try sortService.list(.projects,offset:100)
  let combined=first.rows+last.rows
  try check(first.rows.count==100 && last.rows.count==3 && first.total==103,"recent list bounded paging")
  try check(Set(combined.map{$0.record["id"].string}).count==103,"stable timestamp ties across pages")
  let dates=combined.map{$0.record["updatedAt"].string}
  try check(dates==dates.sorted(by:>),"all pages updatedAt descending")
  try check(try sortService.list(.projects).rows.map{$0.record["id"]} == first.rows.map{$0.record["id"]},"stable repeat ordering")
  try check(CRMModule.find("crm_Accounts")!.sort=="name" && CRMModule.projectTask.sort=="position","other module defaults unchanged")
  try check(try db.integrityCheck(),"final integrity")
  print("{\"checks\":\(checks),\"sourceCases\":26,\"network\":false,\"keychain\":false}")
 }
 static func views(_ v:NSView)->[NSView]{[v]+v.subviews.flatMap(views)}
 static func button(_ name:String,_ w:NSWindow)throws->NSButton{guard let b=views(w.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title==name})else{throw NativeDBError.message("button "+name)};return b}
 static func table(_ w:NSWindow)->NSTableView{views(w.contentView!).compactMap{$0 as? NSTableView}.first!}
 static func wait(_ label:String,_ f:()throws->Bool)throws{let end=Date().addingTimeInterval(10);while Date()<end{if try f(){checks+=1;return};RunLoop.current.run(until:Date().addingTimeInterval(0.01))};throw NativeDBError.message("timeout "+label)}
 static func ui(db:NativeDatabase,admin:CRMService,assignee:CRMService,board:NativeRecord,task:NativeRecord,section:NativeRecord,doc:NativeRecord)throws{
  let w=try CRMDocumentsWindow(service:assignee,linkedTo:task);defer{w.window.orderOut(nil)}
  try wait("association load"){try button("既存の文書を関連付ける…",w.window).isEnabled}
  try check(try !button("ファイルを取り込む…",w.window).isEnabled,"assignee cannot import through board")
  try button("既存の文書を関連付ける…",w.window).performClick(nil)
  try wait("actual picker"){w.window.attachedSheet != nil}
  let picker=w.window.attachedSheet!;try wait("picker rows"){table(picker).numberOfRows>=2}
  try button("キャンセル",picker).performClick(nil);try wait("picker cancel"){w.window.attachedSheet==nil}
  try check(try db.page("DocumentsToTasks",fields:[]).total==2,"picker cancel no effect")
  // Unlink is separately CAS/rollback checked above. Actual picker submit a
  // fresh third public document so duplicate behavior cannot mask routing.
  let third=try db.insert("Documents",values:["document_name":.text("AAA 添付候補"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("unmigrated:test"),"size":.integer(1),"visibility":.text("public"),"createdBy":.text(admin.identity.id)],actor:admin.identity.id)
  try button("既存の文書を関連付ける…",w.window).performClick(nil);try wait("second picker"){w.window.attachedSheet != nil};let p=w.window.attachedSheet!
  let search=views(p.contentView!).compactMap{$0 as? NSSearchField}.first!;search.stringValue="AAA 添付候補";search.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:search))
  try wait("picker filtered"){table(p).numberOfRows==1};table(p).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);try button("選択",p).performClick(nil)
  try wait("UI write completes"){try !w.busy && w.window.attachedSheet==nil && (db.get("DocumentsToTasks",key:["document_id":third["id"],"task_id":task["id"]])) != nil}
  try check(try db.get("Documents",key:["id":third["id"]])!.revision==third.revision,"UI document unchanged")
  let fourth=try db.insert("Documents",values:["document_name":.text("BBB 競合検証"),"document_file_mimeType":.text("text/plain"),"document_file_url":.text("unmigrated:test"),"size":.integer(1),"visibility":.text("public"),"createdBy":.text(admin.identity.id)],actor:admin.identity.id)
  try wait("third link load"){try button("既存の文書を関連付ける…",w.window).isEnabled}
  try button("既存の文書を関連付ける…",w.window).performClick(nil);try wait("stale picker"){w.window.attachedSheet != nil}
  let stalePicker=w.window.attachedSheet!,staleSearch=views(stalePicker.contentView!).compactMap{$0 as? NSSearchField}.first!
  staleSearch.stringValue="BBB 競合検証";staleSearch.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:staleSearch))
  try wait("stale candidate loaded"){table(stalePicker).numberOfRows==1}
  let currentTask=try db.get("Tasks",key:["id":task["id"]])!;_=try db.update(currentTask,changes:["title":.text("選択中の別更新")],actor:admin.identity.id)
  table(stalePicker).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);try button("選択",stalePicker).performClick(nil)
  try wait("stale submit completes"){try w.window.attachedSheet==nil && button("既存の文書を関連付ける…",w.window).isEnabled}
  try check(try db.get("DocumentsToTasks",key:["document_id":fourth["id"],"task_id":task["id"]])==nil,"UI captured task CAS rejects stale picker")
  // Exercise the production confirmation sheet, cancellation and unlink.
  table(w.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
  try button("関連付けを解除…",w.window).performClick(nil);try wait("unlink confirmation"){w.window.attachedSheet != nil}
  try button("キャンセル",w.window.attachedSheet!).performClick(nil);try wait("unlink cancel closes"){w.window.attachedSheet==nil}
  try check(try db.page("DocumentsToTasks",fields:[]).total==3,"unlink cancel retains all links")
  try button("関連付けを解除…",w.window).performClick(nil);try wait("unlink confirmation again"){w.window.attachedSheet != nil}
  try button("実行",w.window.attachedSheet!).performClick(nil)
  try wait("unlink confirmed"){try button("既存の文書を関連付ける…",w.window).isEnabled && db.page("DocumentsToTasks",fields:[]).total==2}
  try check(try db.page("Documents",fields:[]).total==4,"unlink retains document records")
  let kanban=CRMProjectKanbanWindow(project:board,service:admin);defer{kanban.window.orderOut(nil)}
  try wait("kanban loaded"){try button("タスクを追加",kanban.window).isEnabled}
  let count=try db.page("Tasks",fields:[]).total;try button("タスクを追加",kanban.window).performClick(nil)
  try check(!kanban.confirmDiscard(),"quick accepted write close veto")
  try wait("one click quick add"){try button("タスクを追加",kanban.window).isEnabled && (db.page("Tasks",fields:[]).total)==count+1}
  try check(kanban.window.attachedSheet==nil,"quick add does not require form")
  try button("詳細入力…",kanban.window).performClick(nil);try check(kanban.window.attachedSheet != nil,"full form remains available from actual button")
  if let sheet=kanban.window.attachedSheet{kanban.window.endSheet(sheet);sheet.orderOut(nil)}
 }
}
