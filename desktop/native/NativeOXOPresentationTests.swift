import Foundation

@main enum NativeOXOPresentationTests {
    typealias Row=NativePluginRecord
    static var checks=0
    static func check(_ test:Bool,_ message:String) throws { checks+=1;if !test{throw NativePluginError(message:message)} }
    static func denied(_ body:()throws->Void,_ message:String) throws { var failed=false;do{try body()}catch{failed=true};try check(failed,message) }
    static func text(_ view:NativePluginPresentation?) -> String { guard let view else{return ""};return ([view.title]+view.sections.flatMap{[$0.title,$0.empty]+$0.columns+$0.rows.flatMap{$0.map(\.text)}}).joined(separator:"\n") }
    static func main() {
        do { try run() } catch { print("NativeOXOPresentationTests failed: "+error.localizedDescription);exit(1) }
    }
    static func run() throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NativeOXOPresentation-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),adminIdentity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")),admin=CRMService(db:db,identity:adminIdentity)
        let definition=NativeOXOConnector.definition(),now=try NativePluginJSON.date("2026-11-20T08:30:00.000Z")
        var secretReads=0,http=0,notifications=0
        let secretStore=NativePluginSecretStore(read:{_ in secretReads+=1;throw NativePluginError(message:"Do not read display secrets")},write:{_,_ in throw NativePluginError(message:"No secret writes")},remove:{_ in throw NativePluginError(message:"No secret removals")})
        func makeHost(_ definitions:[NativePluginDefinition]) throws -> NativePluginHost { try .init(db:db,definitions:definitions,secretStore:secretStore,clock:{now},sendNotification:{_,_,_ in notifications+=1},transport:{_,_ in http+=1;throw NativePluginError(message:"No HTTP")}) }
        let host=try makeHost([definition])
        func build(_ location:NativePluginLocation,_ service:CRMService?=nil,_ chosenHost:NativePluginHost?=nil) throws -> NativePluginPresentation? { try NativeOXOPresentation.build(service:service ?? admin,host:chosenHost ?? host,location:location) }
        try check(try build(.admin)==nil,"Uninstalled plugin must have no presentation")
        let settings=try definition.settings.parse(["url":"https://erp.example.invalid","timeZone":"Asia/Tokyo","currency":"JPY","priceLists":"3","sendOrders":true,"dryRun":false])
        var installed=try db.insert("InstalledPlugin",values:["id":.text(definition.id),"version":.text(definition.version),"status":.text("ENABLED"),"settings":.text(try NativePluginJSON.text(settings)),"secrets":.text("opaque-reference-not-for-display")],actor:adminIdentity.id)
        let store=NativePluginStore(db:db,pluginId:definition.id,clock:{now})
        let empty=try build(.admin);try check(text(empty).contains("未実行"),"Never-run Japanese status");try check(text(empty).contains("価格表を取得"),"Initial catalog guidance")
        func user(_ role:String,_ name:String) throws -> CRMService {
            let row=try db.insert("Users",values:["name":.text(name),"email":.text(UUID().uuidString+"@example.invalid"),"role":.text(role),"userStatus":.text("ACTIVE"),"v":.integer(0)],actor:adminIdentity.id)
            return CRMService(db:db,identity:.init(id:row["id"].string,role:role,partnerAccountID:nil))
        }
        let member=try user("user","担当者"),other=try user("user","別の担当者"),manager=try user("manager","マネージャー"),partner=try user("partner","外部担当者")
        let account=try db.insert("crm_Accounts",values:["name":.text("東京商事"),"v":.integer(0),"assigned_to":.text(member.identity.id)],actor:adminIdentity.id),accountID=account["id"].string
        let unowned=try db.insert("crm_Accounts",values:["name":.text("未設定商事"),"v":.integer(0),"assigned_to":.null],actor:adminIdentity.id)
        let product=try db.insert("crm_Products",values:["name":.text("テスト商品"),"type":.text("PRODUCT"),"status":.text("ACTIVE"),"unit_price":.text("1234.50"),"currency":.text("JPY")],actor:adminIdentity.id),productID=product["id"].string
        let series=try db.page("NumberSeries",fields:["id"],equal:["scope":.text("order")],limit:1).rows.first!
        var order=try db.insert("crm_Orders",values:["number":.text("ORD-2026-001"),"seriesId":series["id"],"accountId":account["id"],"ownerId":.text(other.identity.id),"currency":.text("JPY"),"status":.text("CONFIRMED"),"subtotal":.text("1234.50"),"orderDate":.text("2026-11-19T00:00:00.000Z")],actor:adminIdentity.id)
        let orderID=order["id"].string
        try check(text(try build(.account(accountID))).contains("未連携"),"Unlinked account tab message")
        try check(try build(.product(productID))==nil,"Unlinked product panel absent")
        try check(try build(.order(orderID))==nil,"Unlinked order panel absent")
        try store.set("account:"+accountID,["customerId":10,"syncedAt":"2026-11-20T08:30:00.000Z","priceListId":3,"addresses":[["id":1,"name":"倉庫","street":"中央1-2","city":"東京","zip":"100-0001"]],"inactive":true])
        try store.set("account:"+unowned["id"].string,["customerId":11,"syncedAt":"2026-11-20T08:30:00.000Z","priceListId":NSNull(),"addresses":[]])
        try store.set("product:"+productID,["oxoId":55,"ref":"internal-ref-do-not-display"])
        var link:Row=["oxoId":77,"number":"SO-77","state":"sale","delivery":"partial","deliveries":[["number":"OUT-1","state":"done","doneAt":"2026-11-19T12:00:00.000Z"]],"belowList":["SKU-A"],"sentAt":"2026-11-19T12:00:00.000Z","checkedAt":"2026-11-20T08:30:00.000Z","imported":true]
        try store.set("order:"+orderID,link)
        let accountView=try build(.account(accountID),member),accountText=text(accountView)
        try check(accountText.contains("2026年11月20日 17:30 (Asia/Tokyo)"),"Configured local date/time")
        try check(accountText.contains("価格表 #3は未取得"),"Unimported price list warning")
        try check(accountText.contains("100-0001 東京"),"Address display")
        try check(accountText.contains("無効です"),"Inactive remote customer")
        try check(accountText.contains("1,234.50 JPY"),"Readable currency amount")
        try check(accountText.contains("確定") && accountText.contains("一部出荷"),"Japanese CRM and delivery status")
        try check(accountView!.sections.flatMap(\.rows).flatMap{$0}.contains{$0.record?.model=="crm_Orders" && $0.record?.id==orderID},"Account orders navigate to internal records")
        let productText=text(try build(.product(productID),member));try check(productText.contains("#55"),"Product remote id");try check(!productText.contains("internal-ref"),"Implementation reference not shown")
        let orderView=try build(.order(orderID),member),orderText=text(orderView)
        try check(orderText.contains("受注確定") && orderText.contains("SKU-A"),"ERP state and below-list lines")
        try check(orderText.contains("OUT-1") && orderText.contains("完了") && orderText.contains("2026年11月19日"),"Shipment completion data")
        try check(orderText.contains("OXO ERPから取得"),"Imported-order provenance")
        try check(orderView!.sections.flatMap(\.rows).flatMap{$0}.compactMap(\.url).map(\.absoluteString)==["https://erp.example.invalid/prodej/77"],"Only original external order URL")
        link["state"]="missing";try store.set("order:"+orderID,link)
        let missingView=text(try build(.order(orderID)))
        try check(missingView.contains("OXO ERPに見つかりません"),"Missing provider record status");try check(!missingView.contains("納品状況"),"Missing remote order does not imply a fresh delivery status")
        let synthetic="oxo_"+String(repeating:"a",count:40)
        order=try db.update(order,changes:["status":.text("READY")],actor:adminIdentity.id)
        try store.set("send:"+orderID,["waitingSince":"2026-11-19T08:00:00.000Z","lastError":"OXO ERP unreachable: "+synthetic])
        let waiting=text(try build(.order(orderID)));try check(waiting.contains("送信待ち") && waiting.contains("接続できません"),"Waiting and readable connection error")
        try check(!waiting.contains(synthetic) && waiting.contains("［非表示］"),"API-key-shaped provider text redacted")
        order=try db.update(order,changes:["status":.text("SYNC_FAILED")],actor:adminIdentity.id)
        try store.set("failed:"+orderID,["reason":"商品を確認してください","at":"2026-11-20T08:30:00.000Z"])
        let failed=text(try build(.order(orderID)));try check(failed.contains("未送信") && failed.contains("商品を確認"),"Failed order reason");try check(!failed.contains("待機開始"),"Stale waiting state hidden after failure")
        let counts:Row=["linked":1,"number":2,"vat":3,"name":4,"created":5,"updated":6,"conflicts":1,"skipped":2,"failed":0]
        let summary:Row=["at":"2026-11-20T08:30:00.000Z","ok":true,"dryRun":false,"customers":counts,"catalog":["categoriesMatched":1,"categoriesCreated":2,"productsUpdated":3,"productsCreated":4,"productsFailed":0,"listsReplaced":1,"listsMissing":[99],"accountLists":1],"orders":["checked":2,"moved":1,"imported":1,"updated":0,"pending":1],"rows":["name":[["name":"東京商事","customerId":10,"accountId":accountID]],"created":[["name":"新規商事","customerId":12]],"conflicts":[]]]
        try store.set("meta:lastRun",summary);var report=summary;report["dryRun"]=true;try store.set("meta:report",report)
        try store.set("conflict:10",["customerId":10,"name":"東京商事","reason":"linked","candidates":[accountID]])
        try store.set("meta:oxoLists",["at":"2026-11-20T08:00:00.000Z","lists":[["id":3,"name":"一般価格表","currency":"JPY","rules":2],["id":4,"name":"卸売価格表","currency":"JPY","rules":1]]])
        try store.set("pricelist:3",["priceListId":"unused","name":"一般価格表","isActive":true]);try store.set("skipped:3",[["ruleId":8,"reason":"base list 99 not imported"],["ruleId":9,"reason":"category Missing not in the CRM"]])
        try store.set("job:sync",["requestedAt":"2026-11-20T08:30:00.000Z"])
        try store.set("pending:1",["order":["id":1]])
        try store.set("meta:sendPaused",["at":"2026-11-20T08:30:00.000Z","reason":"OXO ERP error 403: "+synthetic])
        let before=try NativePluginJSON.text(store.list().map{["key":$0.key,"value":$0.value]}),installedBefore=try host.state(definition.id)!.revision
        let adminView=try build(.admin),adminText=text(adminView)
        for expected in ["前回の同期結果","前回の試行結果","6件","99","一般価格表","選択済み","未選択","基準の価格表 99 が未取得","カテゴリ Missing がCRMにありません","送信失敗","5分以内","連携待ち","接続をテスト"] { try check(adminText.contains(expected),"Admin display missing: "+expected) }
        try check(!adminText.contains(synthetic) && !adminText.contains("opaque-reference") && !adminText.contains("{\""),"No secret or raw JSON in presentation")
        try check(adminView!.sections.flatMap(\.rows).flatMap{$0}.contains{$0.record?.model=="crm_Accounts" && $0.record?.id==accountID},"Conflict/report internal account navigation")
        try check(adminView!.sections.flatMap(\.rows).flatMap{$0}.contains{$0.record?.model=="crm_Orders" && $0.record?.id==orderID},"Failure internal order navigation")
        let owners=try build(.page("needs-owner"),manager)
        try check(text(owners).contains("未設定商事") && !text(owners).contains("東京商事"),"Needs-owner filtering")
        try check(owners!.sections.flatMap(\.rows).flatMap{$0}.contains{$0.record?.id==unowned["id"].string},"Needs-owner internal navigation")
        try check(try build(.page("unknown"))==nil,"Unknown page not presented")
        try denied({_ = try build(.admin,member)},"Nonadmin must not see admin data")
        try denied({_ = try build(.page("needs-owner"),member)},"Needs-owner is manager/admin only")
        try denied({_ = try build(.account(accountID),other)},"Unrelated user must not see account linkage")
        try denied({_ = try build(.account(accountID),partner)},"Partner excluded by source slot roles")
        var noPanel=definition;noPanel.slots.removeAll{$0.kind == .productPanel}
        try check(try build(.product(productID),nil,makeHost([noPanel]))==nil,"Missing product slot returns nil")
        var roleRestricted=definition;roleRestricted.slots=roleRestricted.slots.map{slot in var s=slot;if s.kind == .productPanel{s.roles=["admin"]};return s}
        try denied({_ = try build(.product(productID),member,makeHost([roleRestricted]))},"Current slot-role declaration enforced")
        var hiddenAdmin=definition;hiddenAdmin.slots=hiddenAdmin.slots.map{slot in var s=slot;if s.kind == .adminSection{s.roles=["manager"]};return s}
        try denied({_ = try build(.admin,nil,makeHost([hiddenAdmin]))},"Admin slot role restriction enforced")
        let managerRow=try db.get("Users",key:["id":.text(manager.identity.id)])!
        _ = try db.update(managerRow,changes:["role":.text("user")],actor:adminIdentity.id)
        try denied({_ = try build(.page("needs-owner"),manager)},"Stale role identity rejected after downgrade")
        installed=try db.update(installed,changes:["status":.text("DISABLED")],actor:adminIdentity.id)
        try check(try build(.admin)==nil && build(.account(accountID))==nil,"Disabled plugin hidden")
        installed=try db.update(installed,changes:["status":.text("ENABLED")],actor:adminIdentity.id)
        try check(secretReads==0 && http==0 && notifications==0,"Read-only view did not access secrets or network")
        try check(try NativePluginJSON.text(store.list().map{["key":$0.key,"value":$0.value]})==before,"Presentation did not change plugin store")
        try check(installedBefore+2==installed.revision,"Only explicit fixture lifecycle changes changed revision")
        try check(try db.page("PluginLog",fields:[]).total==0,"Presentation did not write diagnostic logs")
        for view in [empty,accountView,orderView,adminView,owners].compactMap({$0}) { for section in view.sections { try check(section.rows.allSatisfy{$0.count==section.columns.count},"Column/cell alignment: "+section.title) } }
        for unsafe in ["javascript:alert(1)","file:///tmp/test","https://user:password@example.invalid/prodej/1","https:///missing","data:text/html,x","https://erp.example.invalid/prodej/1?apiKey="+synthetic,"https://erp.example.invalid/prodej/1?token=private"] { try check(NativeOXOPresentation.externalURL(unsafe)==nil,"Unsafe external URL rejected") }
        try check(NativeOXOPresentation.error(["raw":"not a message"])=="詳細情報は表示できません。","Structured values never dumped")
        try check(NativeOXOPresentation.error("{\"message\":\"入力を確認してください\",\"token\":\"hidden\"}")=="入力を確認してください","Structured provider error shows message only")
        print("NativeOXOPresentationTests: \(checks) Japanese projection / authorization / read-only checks passed")
    }
}
