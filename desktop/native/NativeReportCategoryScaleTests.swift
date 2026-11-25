import Foundation
import SQLite3
import CryptoKit
import PDFKit

private final class ReportScaleGate {
 let target:String;let ready=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0);let lock=NSLock();private var captured:String?
 init(_ target:String){self.target=target}
 func observe(_ sql:String){lock.lock();if captured != nil || !sql.lowercased().contains(target.lowercased()){lock.unlock();return};captured=sql;lock.unlock();ready.signal();_ = resume.wait(timeout:.now()+10)}
 var statement:String?{lock.lock();defer{lock.unlock()};return captured}
}

@main enum NativeReportCategoryScaleTests {
 static var checks=0
 static let groups=256,facts=8192
 static let longLabel=String(repeating:"長い日本語😀,\"\r\n",count:2048)+"終端目印"
 static func check(_ x:@autoclosure ()throws->Bool,_ label:String)throws{guard try x()else{throw NativeDBError.message("FAIL "+label)};checks+=1}
 static func rejects(_ label:String,_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeDBError.message("accepted "+label)}
 static func id(_ kind:Int,_ x:Int)->String{String(format:"%08x-0000-4000-8000-%012x",kind,x)}
 static func q(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"''")+"'"}
 static func idSQL(_ kind:Int,_ x:String)->String{"printf('%08x-0000-4000-8000-%012x',\(kind),\(x))"}
 static func main()async{do{try await run()}catch{FileHandle.standardError.write(Data("NativeReportCategoryScale: \(error)\n".utf8));exit(1)}}
 static func run()async throws{
  let n=URL(fileURLWithPath:CommandLine.arguments[1]),artifacts=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ReportCategories-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
  let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:n.appendingPathComponent("../../prisma")),service=CRMService(db:db,identity:identity)
  guard let property=Mirror(reflecting:db).children.first(where:{$0.label=="connection"})?.value,let stored=property as? Optional<OpaquePointer>,let connection=stored else{throw NativeDBError.conflict}
  func sql(_ text:String)throws{guard sqlite3_exec(connection,text,nil,nil,nil)==SQLITE_OK else{throw NativeDBError.message(String(cString:sqlite3_errmsg(connection))+" SQL "+String(text.prefix(180)))}}
  func scalar(_ query:String)throws->String{var s:OpaquePointer?;guard sqlite3_prepare_v2(connection,query,-1,&s,nil)==SQLITE_OK,let s else{throw NativeDBError.message(String(cString:sqlite3_errmsg(connection)))};defer{sqlite3_finalize(s)};guard sqlite3_step(s)==SQLITE_ROW else{throw NativeDBError.conflict};return sqlite3_column_text(s,0).map{String(cString:$0)} ?? ""}
  func tempCount()throws->Int{Int(try scalar("SELECT count(*) FROM sqlite_temp_master WHERE type='table' AND name LIKE 'native_report_%'"))!}
  let g="((n.x-1)%256+1)",stamp="strftime('%Y-%m-%dT12:00:00.000Z','2000-01-15',printf('+%d months',((n.x-1)%256)))"
  let actor=identity.id
  // Defaults are taken from an actual NativeDatabase insert. Bulk INSERT SELECT
  // then builds fixed synthetic rows without allocating a fact array in Swift.
  func populate(_ model:String,_ kind:Int,_ count:Int,_ template:[String:SQLValue],_ expressions:[String:String])throws{
   var input=template;input["id"] = .text(id(kind,0));_=try db.insert(model,values:input,actor:actor)
   var s:OpaquePointer?;guard sqlite3_prepare_v2(connection,"PRAGMA table_info(\"\(model)\")",-1,&s,nil)==SQLITE_OK,let s else{throw NativeDBError.conflict};var columns:[String]=[]
   while sqlite3_step(s)==SQLITE_ROW{columns.append(String(cString:sqlite3_column_text(s,1)))};sqlite3_finalize(s)
   try sql("CREATE TEMP TABLE scale_prototype AS SELECT * FROM \"\(model)\" WHERE id="+q(id(kind,0)))
   try sql("DELETE FROM \"\(model)\" WHERE id="+q(id(kind,0)))
   let select=columns.map{column in column=="id" ? idSQL(kind,"n.x") : expressions[column] ?? "prototype.\"\(column)\""}.joined(separator:",")
   try sql("INSERT INTO \"\(model)\" ("+columns.map{"\"\($0)\""}.joined(separator:",")+") SELECT "+select+" FROM scale_prototype prototype CROSS JOIN scale_numbers n WHERE n.x<=\(count)")
   try sql("DROP TABLE scale_prototype")
  }
  func name(_ prefix:String,_ longAt:Int=256)->String{"CASE WHEN n.x=\(longAt) THEN "+q(prefix+longLabel)+" ELSE printf("+q(prefix+"-%04d")+",n.x) END"}
  let seedStart=Date()
  try db.transaction{
   try sql("CREATE TEMP TABLE scale_numbers(x INTEGER PRIMARY KEY); WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<8192) INSERT INTO scale_numbers SELECT x FROM n")
   let admin=try db.get("Users",key:["id":.text(actor)])!;_=try db.update(admin,changes:["created_on":.text("2026-11-15T12:00:00Z")],actor:actor)
   try populate("Users",1,groups,["name":.text("seed"),"email":.text("seed@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],["name":name("担当者"),"email":"printf('scale-%04d@example.invalid',n.x)","created_on":"printf('%04d-01-15T12:00:00.000Z',1799+n.x)"])
   for (model,kind,prefix) in [("crm_Opportunities_Sales_Stages",2,"段階"),("crm_Industry_Type",3,"業種"),("crm_Lead_Sources",4,"経路")]{try populate(model,kind,groups,["name":.text("seed")],["name":name(prefix)])}
   try populate("crm_Accounts",10,facts,["v":.integer(0),"name":.text("seed")],["name":name("取引先"),"industry":idSQL(3,g),"assigned_to":idSQL(1,g),"createdBy":q(actor),"createdAt":stamp,"annual_revenue":"CAST(n.x AS TEXT)","employees":"CASE n.x%6 WHEN 0 THEN '1' WHEN 1 THEN '11' WHEN 2 THEN '51' WHEN 3 THEN '201' WHEN 4 THEN '501' ELSE NULL END"])
   try populate("crm_Opportunities",11,facts,["name":.text("seed")],["name":"printf('商談-%05d',n.x)","sales_stage":idSQL(2,g),"account":idSQL(10,g),"assigned_to":idSQL(1,g),"createdBy":q(actor),"created_on":stamp,"close_date":"strftime('%Y-%m-%dT12:00:00.000Z',"+stamp+",'+10 days')","status":"CASE n.x%3 WHEN 0 THEN 'CLOSED' WHEN 1 THEN 'ACTIVE' ELSE 'INACTIVE' END","budget":"'100'","currency":"CASE n.x%2 WHEN 0 THEN 'EUR' ELSE 'JPY' END"])
   try populate("crm_Leads",12,facts,["lastName":.text("seed")],["lastName":"printf('リード-%05d',n.x)","lead_source_id":idSQL(4,g),"assigned_to":idSQL(1,g),"createdBy":q(actor),"createdAt":stamp])
   try populate("crm_Contacts",13,facts,["last_name":.text("seed")],["last_name":"printf('連絡先-%05d',n.x)","accountsIDs":idSQL(10,g),"assigned_to":idSQL(1,g),"createdBy":q(actor),"created_on":stamp])
   _=try db.insert("Boards",values:["id":.text(id(20,1)),"v":.integer(0),"title":.text("合成ボード"),"description":.text("report fixture"),"user":.text(actor)],actor:actor)
   _=try db.insert("Sections",values:["id":.text(id(21,1)),"v":.integer(0),"title":.text("合成セクション"),"position":.integer(0),"board":.text(id(20,1))],actor:actor)
   try populate("Tasks",14,facts,["v":.integer(0),"position":.integer(0),"priority":.text("normal"),"title":.text("seed")],["title":"printf('タスク-%05d',n.x)","position":"n.x","section":q(id(21,1)),"user":idSQL(1,g),"createdBy":q(actor),"createdAt":stamp,"dueDateAt":stamp,"taskStatus":"CASE n.x%3 WHEN 0 THEN 'COMPLETE' ELSE 'ACTIVE' END"])
   try populate("crm_Activities",15,facts,["title":.text("seed"),"type":.text("call"),"date":.text("2000-01-15T12:00:00Z")],["title":"printf('活動-%05d',n.x)","type":"CASE n.x%5 WHEN 0 THEN 'call' WHEN 1 THEN 'meeting' WHEN 2 THEN 'note' WHEN 3 THEN 'email' ELSE 'visit' END","createdBy":q(actor),"createdAt":stamp,"date":stamp])
   try populate("crm_Targets",16,facts,["last_name":.text("seed")],["last_name":"printf('対象-%05d',n.x)","email":"printf('target-%05d@example.invalid',n.x)","deletedAt":"CASE n.x%16 WHEN 0 THEN '2026-01-01T00:00:00Z' ELSE NULL END"])
   try populate("crm_campaign_templates",22,groups,["name":.text("seed"),"content_html":.text("<p>合成</p>"),"content_json":.text("{}")],["name":name("テンプレート",1)])
   try populate("crm_campaigns",23,groups,["v":.integer(0),"name":.text("seed")],["name":name("配信"),"template_id":idSQL(22,"n.x"),"status":"CASE n.x%2 WHEN 0 THEN 'sent' ELSE 'sending' END","created_by":q(actor),"created_on":stamp])
   try populate("crm_campaign_steps",24,groups,["campaign_id":.text(id(23,1)),"order":.integer(1),"template_id":.text(id(22,1)),"subject":.text("合成件名")],["campaign_id":idSQL(23,"n.x"),"template_id":idSQL(22,"n.x")])
   try populate("crm_campaign_sends",17,facts,["campaign_id":.text(id(23,1)),"step_id":.text(id(24,1)),"target_id":.text(id(16,1)),"email":.text("seed@example.invalid")],["campaign_id":idSQL(23,g),"step_id":idSQL(24,g),"target_id":idSQL(16,"n.x"),"email":"printf('target-%05d@example.invalid',n.x)","status":"CASE n.x%4 WHEN 0 THEN 'failed' ELSE 'sent' END","sent_at":stamp,"opened_at":"CASE n.x%2 WHEN 1 THEN "+stamp+" ELSE NULL END","clicked_at":"CASE n.x%8 WHEN 1 THEN "+stamp+" ELSE NULL END","unsubscribe_token":idSQL(40,"n.x")])
   try populate("crm_TargetLists",25,groups,["name":.text("seed")],["name":"printf('対象リスト-%04d',n.x)","created_by":q(actor),"created_on":stamp])
   try sql("INSERT INTO TargetsToTargetLists(target_id,target_list_id) SELECT "+idSQL(16,"n.x")+","+idSQL(25,g)+" FROM scale_numbers n")
   try populate("crm_Contracts",18,facts,["v":.integer(0),"title":.text("seed"),"value":.text("100")],["title":"printf('契約-%05d',n.x)","account":idSQL(10,g),"assigned_to":idSQL(1,g),"createdBy":q(actor),"endDate":"'2026-01-01T00:00:00Z'"])
   _=try db.insert("ExchangeRate",values:["fromCurrency":.text("EUR"),"toCurrency":.text("JPY"),"rate":.text("2")],actor:actor)
   try sql("DROP TABLE scale_numbers")
  }
  let seedMS=Date().timeIntervalSince(seedStart)*1000
  let fixtureModels=["crm_Accounts","crm_Opportunities","crm_Leads","crm_Contacts","Tasks","crm_Activities","crm_Targets","crm_campaign_sends","crm_Contracts"]
  var counts:[String:Int]=[:]
  for model in fixtureModels{let count=Int(try scalar("SELECT count(*) FROM \"\(model)\""))!;try check(count==facts,"fixed fixture "+model);counts[model]=count}
  for model in ["Users","crm_Opportunities_Sales_Stages","crm_Industry_Type","crm_Lead_Sources","crm_campaign_templates","crm_campaigns","crm_campaign_steps","crm_TargetLists","TargetsToTargetLists"]{counts[model]=Int(try scalar("SELECT count(*) FROM \"\(model)\""))!}
  try check(try db.integrityCheck(),"fixture FK integrity")
  try check(try scalar("PRAGMA temp_store")=="1" && scalar("PRAGMA mmap_size")=="0","disk report temp store without mmap")
  try check(try scalar("SELECT count(*) FROM native_outbox")=="0","report fixture never starts external jobs")
  let iso=ISO8601DateFormatter(),filters=try NativeReportFilters(from:iso.date(from:"1700-01-01T00:00:00Z")!,to:iso.date(from:"2200-01-01T00:00:00Z")!),now=iso.date(from:"2060-01-01T00:00:00Z")!
  let engine=NativeReports(service:service,now:{now})
  let expectedRows=["oppsByStage":256,"oppsByMonth":256,"newLeads":256,"leadSources":256,"newContacts":256,"contactsByAccount":256,"newAccounts":256,"byIndustry":256,"topByRevenue":10,"bySize":6,"tasksCreatedCompleted":256,"tasksByAssignee":256,"activitiesByType":5,"campaignROI":256,"topTemplates":10,"targetGrowth":256,"performance":3,"activeByYear":256,"userGrowth":257,"usersByRole":2]
  let representative:[NativeReportCategory:String]=[.sales:"oppsByStage",.leads:"leadSources",.accounts:"byIndustry",.activity:"tasksByAssignee",.campaigns:"campaignROI",.users:"userGrowth"]
  var revenue=0,pipeline=0,won=0,lost=0
  for i in 1...facts{let amount=i%2==0 ? 200:100;if i%3==0{revenue+=amount;won+=1}else if i%3==1{pipeline+=amount}else{lost+=1}}
  let expectedMetrics:[NativeReportCategory:[String:Int]]=[.overview:["totalRevenue":revenue,"pipelineValue":pipeline,"newLeads":facts,"conversionRate":33,"newContacts":facts,"activeUsers":257,"openTasks":facts-won,"campaignsSent":facts,"newAccounts":facts,"contractsExpiring":facts],.sales:["revenue":revenue,"pipeline":pipeline,"avgDeal":150,"winRate":50,"cycleLength":10],.leads:["conversionRate":100,"converted":facts,"leadCount":facts],.activity:["overdueTasks":facts-won],.campaigns:["sent":6144,"opened":4096,"clicked":1024,"openRate":67,"clickRate":17],.users:["totalActive":257]]
  var categories:[[String:Any]]=[],exports:[[String:Any]]=[],pdfs:[[String:Any]]=[]
  func category(_ category:NativeReportCategory)throws{
   let started=Date(),snapshot=try engine.build(category,filters:filters)
   let metricExpected=expectedMetrics[category] ?? [:];try check(snapshot.metrics.count==metricExpected.count,"metric count "+category.rawValue)
   for (key,value) in metricExpected{try check(Double(snapshot.metrics.first{$0.id==key}?.value ?? "")==Double(value),"metric \(category.rawValue).\(key)")}
   try check(snapshot.missingRateCount==0,"currency joins "+category.rawValue)
   if category == .overview{try check(snapshot.sections.isEmpty && NativeReportExport.standardSection(category)==nil,"overview has metrics without invented series/export");try check(snapshot.metrics.allSatisfy{$0.previous=="0" && $0.destination != nil},"overview previous window and drilldowns")}
   var sections:[[String:Any]]=[]
   for section in snapshot.sections{
    var offset=0,seen=Set<Int64>(),names=Set<String>(),sum=0.0,secondary=0.0,longRows=0,maxPage=0
    let prefixes=["oppsByStage":"段階","leadSources":"経路","contactsByAccount":"取引先","byIndustry":"業種","tasksByAssignee":"担当者","campaignROI":"配信","topTemplates":"テンプレート","topByRevenue":"取引先"]
    let expected=artifacts.appendingPathComponent(category.rawValue+"-"+section.id+".expected.ndjson");FileManager.default.createFile(atPath:expected.path,contents:nil);let expectedOut=try FileHandle(forWritingTo:expected);defer{try? expectedOut.close()}
    while true{
     let page=try snapshot.page(section.id,offset:offset);maxPage=max(maxPage,page.rows.count)
     try check(page.rows.count<=100 && page.total==expectedRows[section.id],"bounded/count \(section.id) page \(offset)")
     if page.total>200 && offset<200{try check(page.rows.count==100,"full leading page "+section.id)}
     for row in page.rows{
      try check(seen.insert(row.id).inserted,"unique row "+section.id);sum+=Double(row.value)!;secondary+=Double(row.secondary ?? "0")!
      var bytes=Data();try snapshot.labelChunks(rowID:row.id){chunk in try check(chunk.count<=16384,"label chunk bound");bytes.append(chunk)}
      let label=String(data:bytes,encoding:.utf8)!;if row.truncated{longRows+=1;try check(row.name.unicodeScalars.count==1024 && label.hasSuffix("終端目印") && label.contains(longLabel),"complete Unicode label "+section.id)}else{try check(label==row.name,"normal label "+section.id)}
      try check(names.insert(label).inserted,"distinct full group labels "+section.id)
      if let prefix=prefixes[section.id]{
       if row.truncated{try check(label==prefix+longLabel,"correct related table full label "+section.id)}
       else{let number=Int(label.replacingOccurrences(of:prefix+"-",with:""));try check(label.hasPrefix(prefix+"-") && number != nil && (1...facts).contains(number!),"correct related table label "+section.id)}
       if section.id != "topByRevenue"{try check(row.value=="32","join fanout per group "+section.id)}else{try check(Double(row.value)==Double(Int(label.replacingOccurrences(of:prefix+"-",with:""))!),"top revenue matches its source account")}
      }
      let translated=NativeReportPresentation.label(label,section:section.id),columns=[translated,row.value]+(row.secondary.map{[$0]} ?? [])
      try expectedOut.write(contentsOf:JSONEncoder().encode(columns));try expectedOut.write(contentsOf:Data([10]))
     }
     offset+=page.rows.count;if offset==page.total{break};guard !page.rows.isEmpty else{throw NativeDBError.conflict}
    }
    try check(offset==expectedRows[section.id],"complete page traversal "+section.id)
    let totalExpected:Double
    switch section.id{case "topByRevenue":totalExpected=Double((facts-9...facts).reduce(0,+));case "topTemplates":totalExpected=320;case "targetGrowth":totalExpected=7680;case "performance":totalExpected=Double(6144+4096+1024);case "activeByYear","userGrowth","usersByRole":totalExpected=257;default:totalExpected=Double(facts)}
    try check(sum==totalExpected,"aggregate total "+section.id);if section.id=="tasksCreatedCompleted"{try check(secondary==Double(won),"completed secondary series")}
    let csv=artifacts.appendingPathComponent(category.rawValue+"-"+section.id+".csv")
    try check(try NativeReportExport.write(snapshot,section:section.id,format:.csv,to:csv)==offset,"streaming export row count "+section.id)
    exports.append(["csv":csv.lastPathComponent,"expected":expected.lastPathComponent,"rows":offset,"section":section.id,"headers":NativeReportExport.headers(section)])
    sections.append(["id":section.id,"rows":offset,"maxPage":maxPage,"sum":sum,"longLabels":longRows])
   }
   if let section=representative[category]{let pdf=artifacts.appendingPathComponent(category.rawValue+".pdf");let rows=try NativeReportExport.write(snapshot,section:section,format:.pdf,to:pdf);try check(rows==expectedRows[section],"PDF all rows "+category.rawValue);guard let document=PDFDocument(url:pdf),let text=document.string else{throw NativeDBError.conflict};try check(document.pageCount>5 && text.contains(category.title),"PDF pagination and title "+category.rawValue);if category != .users{try check(text.contains("終端目印"),"PDF full long label "+category.rawValue);try check(text.components(separatedBy:"長い日本語").count-1==2048,"PDF retains every repeated phrase "+category.rawValue);try check(text.components(separatedBy:"😀").count-1==2048,"PDF retains every emoji "+category.rawValue)};pdfs.append(["category":category.rawValue,"section":section,"rows":rows,"pages":document.pageCount,"path":pdf.lastPathComponent])}
   let marker=Data("prior destination".utf8),destination=artifacts.appendingPathComponent("preserved-"+category.rawValue+".csv");try marker.write(to:destination)
   let account=try db.get("crm_Accounts",key:["id":.text(id(10,1))])!;_=try db.update(account,changes:["description":.text("revision "+category.rawValue)],actor:actor)
   try rejects("stale authority/revision "+category.rawValue){try snapshot.requireCurrent()}
   if let section=snapshot.sections.first{try rejects("stale page "+category.rawValue){_=try snapshot.page(section.id)};try rejects("stale export "+category.rawValue){_=try NativeReportExport.write(snapshot,section:section.id,format:.csv,to:destination)};try check(try Data(contentsOf:destination)==marker,"stale preserves destination "+category.rawValue)}
   categories.append(["category":category.rawValue,"sections":sections,"metrics":snapshot.metrics.count,"elapsedMilliseconds":Date().timeIntervalSince(started)*1000])
  }
  for kind in NativeReportCategory.allCases{try category(kind);try check(try tempCount()==0,"snapshot workspace released "+kind.rawValue)}
  let trace:@convention(c)(UInt32,UnsafeMutableRawPointer?,UnsafeMutableRawPointer?,UnsafeMutableRawPointer?)->Int32={_,context,statement,_ in guard let context,let statement,let sql=sqlite3_sql(OpaquePointer(statement))else{return 0};Unmanaged<ReportScaleGate>.fromOpaque(context).takeUnretainedValue().observe(String(cString:sql));return 0}
  var cancellations:[[String:Any]]=[]
  func install(_ gate:ReportScaleGate)throws{guard sqlite3_trace_v2(connection,UInt32(SQLITE_TRACE_STMT),trace,Unmanaged.passUnretained(gate).toOpaque())==SQLITE_OK else{throw NativeDBError.conflict}}
  let targets:[NativeReportCategory:String]=[.overview:"FROM \"crm_Opportunities\"",.sales:"FROM \"crm_Opportunities\"",.leads:"COUNT(*) AS count FROM \"crm_Leads\"",.accounts:"INSERT INTO temp.",.activity:"COUNT(*) AS count FROM \"Tasks\"",.campaigns:"COUNT(*) AS count FROM \"crm_campaign_sends\"",.users:"COUNT(*) AS count FROM \"Users\""]
  for kind in NativeReportCategory.allCases{
   let gate=ReportScaleGate(targets[kind]!);try install(gate);let task=Task.detached{try engine.build(kind,filters:filters)}
   let observed=await Task.detached{gate.ready.wait(timeout:.now()+10) == .success}.value
   task.cancel();let cancelledAt=Date();gate.resume.signal()
   guard observed else{_ = try? await task.value;throw NativeDBError.message("SQL gate not reached "+kind.rawValue)}
   do{_=try await task.value;throw NativeDBError.message("build cancellation accepted "+kind.rawValue)}catch is CancellationError{checks+=1}
   sqlite3_trace_v2(connection,0,nil,nil);try check(try tempCount()==0,"cancel rolls back and releases workspace "+kind.rawValue)
   cancellations.append(["category":kind.rawValue,"phase":"build statement dispatch (test gate)","milliseconds":Date().timeIntervalSince(cancelledAt)*1000,"observedSQL":String(gate.statement!.prefix(180))])
  }
  for kind in NativeReportCategory.allCases where kind != .overview{
   let snapshot=try engine.build(kind,filters:filters),section=representative[kind]!,destination=artifacts.appendingPathComponent("cancel-"+kind.rawValue+".csv"),old=Data("previous export".utf8);try old.write(to:destination)
   let gate=ReportScaleGate("SELECT id,substr(label,1,1024)");try install(gate);let task=Task.detached{try NativeReportExport.write(snapshot,section:section,format:.csv,to:destination)}
   let observed=await Task.detached{gate.ready.wait(timeout:.now()+10) == .success}.value;task.cancel();gate.resume.signal()
   guard observed else{_ = try? await task.value;throw NativeDBError.message("export gate not reached")}
   do{_=try await task.value;throw NativeDBError.message("export cancellation accepted")}catch is CancellationError{checks+=1};sqlite3_trace_v2(connection,0,nil,nil)
   try check(try Data(contentsOf:destination)==old,"cancel preserves destination "+kind.rawValue)
   try check(try !FileManager.default.contentsOfDirectory(atPath:artifacts.path).contains{$0.hasPrefix(".nextcrm-report-")},"cancel removes unpublished output "+kind.rawValue)
   try check(try snapshot.page(section).total==expectedRows[section],"snapshot usable after export cancel "+kind.rawValue)
  }
  let restored=try engine.build(.accounts,filters:filters);try check(try restored.page("byIndustry",offset:200).rows.count==56,"subsequent rebuild works after cancellations")
  let staleAdmin=try db.get("Users",key:["id":.text(actor)])!;_=try db.update(staleAdmin,changes:["banned":.integer(1)],actor:actor);try rejects("fresh authority after large build"){_=try restored.page("byIndustry")}
  try check(try db.integrityCheck(),"final data integrity")
  let disk=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey]).reduce(0){$0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)}
  let result:[String:Any]=["checks":checks,"sourceMeaningOracleRerun":false,"sourceRecords":counts,"groups":groups,"factsPerFamily":facts,"longLabelBytes":longLabel.utf8.count,"categories":categories,"exports":exports,"pdfs":pdfs,"cancellations":cancellations,"temporaryDatabaseBytes":disk,"seedMilliseconds":seedMS,"syntheticFixtureRemovedOnExit":true,"fullAppMemoryMeasured":false,"externalEffects":false]
  try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:artifacts.appendingPathComponent("result.json"))
  print(String(decoding:try JSONSerialization.data(withJSONObject:["checks":checks,"categories":categories.count,"CSVExports":exports.count,"PDFExports":6,"facts":facts,"groups":groups,"temporaryDatabaseBytes":disk],options:.sortedKeys),as:UTF8.self))
 }
}
