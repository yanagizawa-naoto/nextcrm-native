import Foundation

@main enum NativeAccountProtectionPresentationTests {
    static var checks=0
    static func check(_ condition:@autoclosure () throws->Bool,_ name:String) throws {checks+=1;guard try condition() else {throw NativePluginError(message:name)}}
    static func rejects(_ name:String,_ body:() throws->Void) throws {do{try body()}catch{checks+=1;return};throw NativePluginError(message:"accepted "+name)}
    static func main() {
        do {try run();print(try NativePluginJSON.text(["exit":0,"checks":checks]))}
        catch {print(try! NativePluginJSON.text(["exit":1,"checks":checks,"error":error.localizedDescription]));exit(1)}
    }
    static func run() throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NativeAccountProtectionPresentation-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),admin=CRMService(db:db,identity:identity)
        let now=try NativePluginJSON.date("2026-11-01T06:00:00Z")
        var secretReads=0,externalCalls=0
        let definition=NativeAccountProtection.definition(),host=try NativePluginHost(db:db,definitions:[definition],secretStore:.init(read:{_ in secretReads+=1;throw NativeDBError.conflict},write:{_,_ in throw NativeDBError.conflict},remove:{_ in}),clock:{now},sendNotification:{_,_,_ in externalCalls+=1;throw NativeDBError.conflict},transport:{_,_ in externalCalls+=1;throw NativeDBError.conflict})
        let userRow=try db.insert("Users",values:["name":.text("担当 太郎"),"email":.text("user@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE"),"v":.integer(0)],actor:identity.id)
        let managerRow=try db.insert("Users",values:["name":.text("管理 花子"),"email":.text("manager@example.invalid"),"role":.text("manager"),"userStatus":.text("ACTIVE"),"v":.integer(0)],actor:identity.id)
        let user=CRMService(db:db,identity:.init(id:userRow["id"].string,role:"user",partnerAccountID:nil)),manager=CRMService(db:db,identity:.init(id:managerRow["id"].string,role:"manager",partnerAccountID:nil))
        let account=try db.insert("crm_Accounts",values:["name":.text("第一商事"),"company_id":.text("12345678"),"assigned_to":userRow["id"],"createdBy":userRow["id"],"v":.integer(0)],actor:identity.id),id=account["id"].string
        let other=try db.insert("crm_Accounts",values:["name":.text("別担当の取引先"),"company_id":.text("12345678"),"assigned_to":managerRow["id"],"createdBy":managerRow["id"],"v":.integer(0)],actor:identity.id)
        func build(_ service:CRMService,_ location:NativePluginLocation) throws -> NativePluginPresentation? {try NativeAccountProtectionPresentation.build(service:service,host:host,location:location)}
        func texts(_ view:NativePluginPresentation?)->[String] {view?.sections.flatMap{$0.rows.flatMap{$0.map(\.text)}} ?? []}
        try check(try build(admin,.account(id))==nil,"uninstalled omitted")
        try db.insert("InstalledPlugin",values:["id":.text(definition.id),"version":.text(definition.version),"status":.text("ENABLED"),"settings":.text("{}"),"secrets":.text("fake-secret-reference-do-not-display")],actor:identity.id)
        try check(try texts(build(user,.account(id))).contains("保護なし：担当者未設定"),"unregistered summary")
        let withoutNumber=try db.insert("crm_Accounts",values:["name":.text("番号なし"),"createdBy":userRow["id"],"v":.integer(0)],actor:identity.id)
        try check(try texts(build(user,.account(withoutNumber["id"].string))).contains("保護なし：登録番号未設定"),"missing number summary")
        let store=NativePluginStore(db:db,pluginId:definition.id,clock:{now})
        var registration=try NativeAccountProtectionState.newRegistration(key:"CZ:12345678",ownerId:userRow["id"].string,at:NativePluginJSON.date("2026-10-01T14:00:00Z"),settings:definition.settings.parse([:]))
        try NativeAccountProtection.start(store,id,registration)
        try check(try texts(build(user,.account(id))).contains("2026年10月31日までに連絡が必要"),"contact deadline Japanese UTC")
        let activity=try db.insert("crm_Activities",values:["title":.text("訪問済み"),"type":.text("visit"),"status":.text("completed"),"date":.text("2026-10-05T09:00:00.000Z"),"createdBy":managerRow["id"]],actor:identity.id)
        try db.insert("crm_ActivityLinks",values:["activityId":activity["id"],"entityType":.text("account"),"entityId":.text(id)],actor:identity.id)
        let contact=try build(user,.account(id))
        try check(texts(contact).contains("2026年10月5日に連絡済み") && texts(contact).contains("2026年12月30日まで保護"),"live contact without background recompute")
        try check(texts(contact).contains("確定した受注はありません"),"order rule enabled no order")
        registration=try NativeAccountProtectionState.withOrders(registration,last:"2026-10-06",months:12);try store.set("reg:"+id,registration)
        try check(try texts(build(user,.account(id))).contains("最終受注確定日：2026年10月6日"),"confirmed order date")
        try store.set("hist:"+id+":2026-10-01T14:00:00Z",["at":"2026-10-01T14:00:00Z","from":NSNull(),"to":userRow["id"].string,"byUserId":NSNull(),"reason":"created","unusedRaw":"private-metadata"])
        try store.set("hist:"+id+":2026-10-08T14:00:00Z",["at":"2026-10-08T14:00:00Z","from":userRow["id"].string,"to":managerRow["id"].string,"byUserId":userRow["id"].string,"reason":"assigned"])
        let history=try build(user,.account(id))!.sections[1]
        try check(history.rows.count==2 && history.rows[0].map(\.text)==["2026年10月8日","担当 太郎","管理 花子","担当 太郎","割り当て"],"history newest first and readable people")
        try check(history.rows[1][3].text=="システム" && history.rows[1][1].text=="未設定","system actor and unassigned")
        try rejects("primary ownership") {_=try build(user,.account(other["id"].string))}
        try rejects("page slot role") {_=try build(user,.page("expiring"))}
        try rejects("admin only conflicts") {_=try build(manager,.admin)}
        try store.set("due:2026-11-03:"+id,[:]);try store.set("due:2026-11-20:"+other["id"].string,[:]);try store.set("freed:2026-10-30:"+other["id"].string,[:])
        let page=try build(manager,.page("expiring"))!
        try check(page.title=="期限間近の担当保護" && page.sections[0].title=="7日以内に期限","page Japanese headings")
        try check(page.sections[0].rows.count==2 && !page.sections[0].rows.contains{$0[1].text=="別担当の取引先"},"warning horizon includes overdue, excludes distant")
        try check(page.sections[1].rows.first?[1].text=="別担当の取引先","freed list")
        try check(page.sections[0].rows[0][1].record?.model=="crm_Accounts" && page.sections[0].rows[0][1].record?.id==id,"native record navigation target")
        try store.set("conflict:"+id,["key":"CZ:12345678","otherAccountId":other["id"].string])
        try check(try build(admin,.admin)!.sections[0].rows[0].map(\.text)==["CZ:12345678","第一商事","別担当の取引先"],"conflict shows both authorized accounts")
        try db.setDeleted(other,deleted:true,actor:identity.id)
        try check(try build(admin,.admin)!.sections[0].rows.isEmpty,"deleted related account hidden")
        try check(try build(manager,.page("expiring"))!.sections[1].rows.isEmpty,"deleted freed account hidden")
        try check(try build(admin,.account(UUID().uuidString))==nil && build(admin,.order(id))==nil && build(admin,.page("unknown"))==nil,"unavailable locations omitted")
        let count=try db.page("PluginData",fields:[]).total,logs=try db.page("PluginLog",fields:[]).total,audits=try db.page("crm_AuditLog",fields:[]).total
        let values=try store.list().map{try NativePluginJSON.text($0.value)}
        let display=try build(user,.account(id))!
        try check(!texts(display).contains(where:{$0.contains("private-metadata") || $0.contains("secret-reference") || $0.contains("{")}),"no raw JSON or secret references")
        try check(try db.page("PluginData",fields:[]).total==count && db.page("PluginLog",fields:[]).total==logs && db.page("crm_AuditLog",fields:[]).total==audits && store.list().map{try NativePluginJSON.text($0.value)}==values,"display has no persistent effects")
        try check(secretReads==0 && externalCalls==0,"no Keychain or external operations")
        try db.update(host.state(definition.id)!,changes:["status":.text("DISABLED")],actor:identity.id)
        try check(try build(admin,.account(id))==nil && build(admin,.admin)==nil,"disabled omitted")
        try db.update(db.get("Users",key:["id":userRow["id"]])!,changes:["role":.text("manager")],actor:identity.id)
        try rejects("stale authority even disabled") {_=try build(user,.account(id))}
    }
}
