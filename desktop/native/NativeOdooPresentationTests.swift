import Foundation

@main struct NativeOdooPresentationTests {
    typealias Row = NativePluginRecord
    static var checks=0
    static func check(_ value:Bool,_ message:String)throws { checks += 1;if !value { throw NativePluginError(message:message) } }
    static func denied(_ body:()throws->Void,_ message:String)throws { var caught=false;do { try body() } catch { caught=true };try check(caught,message) }
    static func id(_ n:Int)->String { String(format:"b0000000-0000-4000-8000-%012d",n) }
    static func texts(_ value:NativePluginPresentation)->String {
        var parts=[value.title]
        for section in value.sections {
            parts.append(section.title);parts.append(contentsOf:section.columns);parts.append(section.empty)
            for row in section.rows { for cell in row { parts.append(cell.text) } }
        }
        return parts.joined(separator:"\n")
    }

    static func cells(_ value:NativePluginPresentation)->[NativePluginPresentation.Cell] { value.sections.flatMap { $0.rows.flatMap { $0 } } }
    static func main()throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-OdooPresentation-"+UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),now=try NativePluginJSON.date("2026-10-13T08:00:00.000Z"),clock={now}
        let data=NativePluginData(db:db,pluginId:"odoo-connector",permissions:NativeOdooPlugin.permissions,clock:clock)
        func seed(_ model:String,_ values:Row)throws { _=try db.insert(model,values:data.values(values,model:model),actor:"fixture") }
        func service(_ n:Int,_ role:String,partner:String?=nil)->CRMService { CRMService(db:db,identity:.init(id:id(n),role:role,partnerAccountID:partner)) }
        for (n,role) in [(1,"admin"),(2,"user"),(3,"manager"),(4,"user"),(5,"partner")] { let row:Row=["id":id(n),"name":"利用者\(n)","email":"u\(n)@example.invalid","role":role,"userStatus":"ACTIVE"];try seed("Users",row) }
        try seed("Currency",["code":"JPY","name":"日本円","symbol":"¥"])
        try seed("NumberSeries",["id":id(6),"name":"受注","scope":"order","template":"ORD-{YYYY}-{####}","isDefault":true])
        try seed("crm_Accounts",["id":id(10),"v":0,"name":"公開先 株式会社","assigned_to":id(2)])
        try seed("crm_Accounts",["id":id(11),"v":0,"name":"別担当の取引先","assigned_to":id(4)])
        try seed("crm_Accounts",["id":id(12),"v":0,"name":"担当者未設定の取引先"])
        let partnerRow=try db.get("Users",key:["id":.text(id(5))])!;_=try db.update(partnerRow,changes:["partnerAccountId":.text(id(10))],actor:"fixture")
        try seed("crm_Contacts",["id":id(13),"v":0,"first_name":"別担当","last_name":"連絡先","accountsIDs":id(11),"assigned_to":id(4)])
        for (n,source) in [(20,"EXTERNAL"),(21,"CRM")] { try seed("crm_Products",["id":id(n),"name":"商品\(n)","type":"PRODUCT","status":"ACTIVE","unit_price":100,"currency":"JPY","source":source,"externalRef":n==20 ? "700":NSNull()]) }
        for (n,account,owner) in [(30,10,2),(31,11,2)] { try seed("crm_Orders",["id":id(n),"number":"ORD-\(n)","seriesId":id(6),"accountId":id(account),"ownerId":id(owner),"currency":"JPY","status":"SYNC_FAILED","subtotal":200,"grandTotal":220,"orderDate":"2026-10-12T00:00:00.000Z"]) }
        let admin=service(1,"admin"),user=service(2,"user"),manager=service(3,"manager"),partner=service(5,"partner",partner:id(10));var secretReads=0,httpCalls=0,notifications=0
        func host(_ definition:NativePluginDefinition=NativeOdooPlugin.definition)throws->NativePluginHost {
            try NativePluginHost(db:db,definitions:[definition],secretStore:.init(read:{ _ in secretReads += 1;return ["apiKey":"secret-should-never-be-read"] },write:{ _,_ in throw NativePluginError(message:"unexpected write") },remove:{ _ in throw NativePluginError(message:"unexpected remove") }),clock:clock,sendNotification:{ _,_,_ in notifications += 1 },transport:{ _,_ in httpCalls += 1;throw NativePluginError(message:"unexpected network") })
        }
        let host=try host()
        try check(try NativeOdooPresentation.build(service:admin,host:host,location:.admin)==nil,"uninstalled plugin hidden")
        let reference="opaque-reference-must-not-be-shown",settings:Row=["url":"https://odoo.example.invalid","database":"db","timeZone":"Asia/Tokyo","dryRun":true,"priceLists":"245","sendOrders":true]
        try seed("InstalledPlugin",["id":"odoo-connector","version":"0.4.2","status":"ENABLED","settings":settings,"secrets":reference])
        let store=NativePluginStore(db:db,pluginId:"odoo-connector",clock:clock)
        try store.set("account:"+id(10),["partnerId":50,"syncedAt":"2026-10-13T08:00:00.000Z","salesperson":"営業担当","odooPriceList":[245,"特別価格"],"archived":true])
        try store.set("account:"+id(12),["partnerId":51,"syncedAt":"2026-10-13T08:00:00.000Z","salesperson":"担当待ち"])
        try store.set("product:700",["productId":id(20),"tmplId":70,"categoryRef":NSNull()])
        try store.set("meta:lastRun",["at":"2026-10-13T08:00:00.000Z","ok":true,"created":3,"updated":2,"unchanged":4,"skipped":1,"conflicts":1,"failed":0,"catalog":["categories":2,"productsCreated":3,"productsUpdated":4,"productsFailed":1,"listsReplaced":2,"listsMissing":[999],"accountLists":1],"orders":["checked":5,"moved":2,"imported":1]])
        try store.set("conflict:50",["partnerId":50,"name":"Odoo側顧客","reason":"number","candidates":[id(10)]])
        try store.set("meta:odooLists",["at":"2026-10-13T08:00:00.000Z","lists":[["id":245,"name":"特別価格","currency":"JPY","rules":2,"active":true]]])
        try store.set("skipped:245",[["ruleId":7,"reason":"compute_price unsupported"]])
        try store.set("job:sync",["requestedAt":"2026-10-13T08:00:00.000Z"])
        try store.set("compare:progress",["done":1,"total":3])
        try store.set("compare:last",["at":"2026-10-13T08:00:00.000Z","ok":false,"error":"{\"secret\":\"raw-json-must-not-appear\"}","lists":[["name":"特別価格","checked":3,"failed":1]],"mismatches":[["list":"特別価格","product":"商品20","quantity":10,"crm":"100","odoo":"110","diff":"-10","reason":"rate","error":"exchange rate missing"]]])
        try store.set("meta:sendPaused",["at":"2026-10-13T08:00:00.000Z","reason":"Odoo rejected the API key"])
        try store.set("meta:created",[["at":"2026-10-13T08:00:00.000Z","kind":"delivery","name":"東京倉庫","odooId":52,"orderNumber":"ORD-30"]])
        try store.set("meta:imported",["lastRun":1])
        try store.set("importFailed:999",["at":"2026-10-13T08:00:00.000Z","name":"S00999","reason":"取り込み対象の商品がありません"])
        try store.set("failed:"+id(30),["at":"2026-10-13T08:00:00.000Z","reason":"Bearer sensitive-token "+reference])
        try store.set("send:"+id(30),["waitingSince":"2026-10-12T08:00:00.000Z","attempts":2,"lastError":"Odoo unreachable: timeout"])
        try store.set("order:"+id(30),["odooId":900,"name":"S00900","state":"missing","sentAt":"2026-10-12T08:00:00.000Z","checkedAt":"2026-10-13T08:00:00.000Z","imported":true,"movedNotified":true,"created":["customer","delivery"],"priceDiffs":[["sku":"SKU20","crm":100,"odoo":110]],"totalDiffers":true,"total":230,"missing":1,"deliveries":[["name":"OUT001","state":"assigned","date":"2026-10-12"]],"invoices":[["number":"INV001","due":"2026-10-01","amount":220,"residual":80,"paymentState":"partial"]]])
        try store.set("customer:"+id(10),["at":"2026-10-13T08:00:00.000Z","invoices":[["number":"INV001","date":"2026-09-20","due":"2026-10-01","amount":220,"residual":80,"currency":"JPY","type":"out_invoice"],["number":"REF001","date":"2026-10-01","due":"2026-10-15","amount":10,"residual":10,"currency":"JPY","type":"out_refund"]],"totals":[["year":2026,"currency":"JPY","amount":1234.56]]])
        let installedBefore=try host.state("odoo-connector")!,logsBefore=try db.page("PluginLog",fields:[]).total
        let a=try NativeOdooPresentation.build(service:admin,host:host,location:.admin)!,aText=texts(a)
        for expected in ["試行モード","17:00 (Asia/Tokyo)","競合","999","予約済み","3件中 1件","為替レート","OdooのAPIキーが拒否","東京倉庫","ORD-30","S00999","未対応の価格計算方法"] { try check(aText.contains(expected),"admin displays "+expected) }
        for forbidden in [reference,"sensitive-token","secret-should-never-be-read","raw-json-must-not-appear","{\"secret\""] { try check(!aText.contains(forbidden),"admin hides "+forbidden) }
        try check(cells(a).contains { $0.record?.model=="crm_Accounts" && $0.record?.id==id(10) && $0.text=="公開先 株式会社" },"conflict candidate safe record target")
        try check(cells(a).contains { $0.record?.model=="crm_Orders" && $0.record?.id==id(30) },"failed order safe record target")
        let account=try NativeOdooPresentation.build(service:user,host:host,location:.account(id(10)))!,accountText=texts(account)
        for expected in ["Odooパートナー #50","アーカイブ済み","未取得","S00900","同期失敗","12日","返金・貸方","-10.00 JPY","70.00 JPY","1,234.56 JPY"] { try check(accountText.contains(expected),"account displays "+expected) }
        try check(cells(account).contains { $0.record?.id==id(30) },"account order link")
        try check(cells(account).contains { $0.url?.absoluteString=="https://odoo.example.invalid/odoo/contacts/50" },"validated external account URL")
        let order=try NativeOdooPresentation.build(service:user,host:host,location:.order(id(30)))!,orderText=texts(order)
        for expected in ["APIユーザーの権限不足","CRMの取引先は維持","納品先住所","SKU20","出荷準備済み","一部入金","未取得の明細","送信失敗"] { try check(orderText.contains(expected),"order displays "+expected) }
        try check(!order.sections.contains{$0.title=="送信待ち"},"stale waiting hidden on failure")
        var orderRecord=try db.get("crm_Orders",key:["id":.text(id(30))])!;orderRecord=try db.update(orderRecord,changes:["status":.text("READY")],actor:"fixture")
        let waiting=try NativeOdooPresentation.build(service:user,host:host,location:.order(id(30)))!
        try check(waiting.sections.contains{$0.title=="送信待ち"} && !waiting.sections.contains{$0.title=="送信失敗"},"ready status has only current waiting details")
        let product=try NativeOdooPresentation.build(service:user,host:host,location:.product(id(20)))!
        try check(cells(product).contains{$0.url?.absoluteString.contains("product.product&id=700")==true},"product deep link")
        try check(try NativeOdooPresentation.build(service:user,host:host,location:.product(id(21)))==nil,"unlinked CRM product has no panel")
        try check(try NativeOdooPresentation.build(service:admin,host:host,location:.account(id(11)))==nil,"unlinked account has no panel")
        let page=try NativeOdooPresentation.build(service:manager,host:host,location:.page("needs-owner"))!
        try check(texts(page).contains("担当者未設定の取引先") && cells(page).contains{$0.record?.id==id(12)},"manager owner page")
        try check(try NativeOdooPresentation.build(service:admin,host:host,location:.page("unknown"))==nil,"unknown location hidden")
        try denied({ _=try NativeOdooPresentation.build(service:user,host:host,location:.admin) },"admin is restricted")
        try denied({ _=try NativeOdooPresentation.build(service:user,host:host,location:.page("needs-owner")) },"owner page role restricted")
        try denied({ _=try NativeOdooPresentation.build(service:partner,host:host,location:.account(id(10))) },"partner excluded by slot roles")
        try denied({ _=try NativeOdooPresentation.build(service:user,host:host,location:.account(id(11))) },"account ownership checked")
        try user.assertAccess("crm_Orders",id:id(31))
        try denied({ _=try NativeOdooPresentation.build(service:user,host:host,location:.order(id(31))) },"related account checked despite order owner access")
        _=try db.update(orderRecord,changes:["contactId":.text(id(13))],actor:"fixture")
        try denied({ _=try NativeOdooPresentation.build(service:user,host:host,location:.order(id(30))) },"related contact checked")
        let currentPlugin=try host.state("odoo-connector")!;try check(currentPlugin.revision==installedBefore.revision,"display did not update plugin state")
        try check(try db.page("PluginLog",fields:[]).total==logsBefore,"display did not emit logs")
        try check(secretReads==0 && httpCalls==0 && notifications==0,"display has no secret or external I/O")
        var changedSettings=settings;changedSettings["url"]="https://user:password@odoo.example.invalid"
        var installed=try db.update(currentPlugin,changes:["settings":.text(try NativePluginJSON.text(changedSettings))],actor:"fixture")
        let unsafe=try NativeOdooPresentation.build(service:admin,host:host,location:.account(id(10)))!
        try check(cells(unsafe).allSatisfy{$0.url==nil},"credential-bearing configured URL not exposed")
        installed=try db.update(installed,changes:["status":.text("DISABLED")],actor:"fixture")
        try check(try NativeOdooPresentation.build(service:admin,host:host,location:.admin)==nil,"disabled plugin hidden")
        _=try db.update(installed,changes:["status":.text("ENABLED")],actor:"fixture")
        let administrator=try db.get("Users",key:["id":.text(id(1))])!;_=try db.update(administrator,changes:["role":.text("user")],actor:"fixture")
        try denied({ _=try NativeOdooPresentation.build(service:admin,host:host,location:.admin) },"cached admin role revalidated")
        let currentUser=try db.get("Users",key:["id":.text(id(2))])!;_=try db.update(currentUser,changes:["banned":.integer(1)],actor:"fixture")
        try denied({ _=try NativeOdooPresentation.build(service:user,host:host,location:.product(id(20))) },"banned identity revalidated")
        print("NativeOdooPresentationTests: \(checks) isolated SQLite presentation/access checks passed")
    }
}
