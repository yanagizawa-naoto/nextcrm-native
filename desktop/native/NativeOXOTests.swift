import Foundation

final class NativeOXOFixtureClient:NativeOXOClient {
    typealias Row=NativePluginRecord
    let config:Row
    var requests:[Row]=[]
    var intercept:((String,String) async throws -> Void)?
    init(_ config:Row){self.config=config}
    func fail(_ method:String,_ path:String) throws { if let f=config["failure"] as? Row,f["method"] as? String == method,f["path"] as? String == path { throw NativeOXOError(message:f["message"] as! String,status:Int(NativePluginJSON.number(f["status"])!),code:f["code"] as? String) } }
    func all(_ path:String,_ parameters:[(String,String)]) async throws -> [Row] { let params=Dictionary(uniqueKeysWithValues:parameters);requests.append(["method":"all","path":path,"params":params]);try await intercept?("all",path);try fail("all",path);return config[path == "/customers" ? "customers":path == "/products" ? "products":"orders"] as? [Row] ?? [] }
    func get(_ path:String,_ parameters:[(String,String)]) async throws -> Any { let params=Dictionary(uniqueKeysWithValues:parameters);requests.append(["method":"get","path":path,"params":params]);try await intercept?("get",path);try fail("get",path);var rows=config[path == "/price-lists" ? "lists":"orders"] as? [Row] ?? []
        if let ids=params["ids"] { rows=rows.filter{ids.components(separatedBy:",").contains(NativeOXOMap.string($0["id"]))} }
        if let ids=params["odooIds"] { rows=rows.filter{ids.components(separatedBy:",").contains(NativeOXOMap.string($0["odooId"]))} };return ["items":rows]
    }
    func post(_ path:String,_ body:Row) async throws -> (status:Int,body:Any) { requests.append(["method":"post","path":path,"body":body]);try await intercept?("post",path);try fail("post",path);return (201,config["post"] ?? NSNull()) }
}

@main enum NativeOXOTests {
    typealias Row=NativePluginRecord
    static var currentScenario=""
    static func main() async { do { try await run() } catch { print(currentScenario+": "+error.localizedDescription);exit(1) } }
    static func run() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try NativePluginJSON.record(String(contentsOf:resources.appendingPathComponent("build/oxo-reference.json"),encoding:.utf8)),models=reference["models"] as! [String]
        var outputs:[Row]=[],nativeChecks=0
        for scenario in reference["scenarios"] as! [Row] {
            currentScenario=scenario["name"] as! String
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("NativeOXO-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
            let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let config=scenario["config"] as! Row;var definition=NativeOXOConnector.definition();definition.permissions.removeAll{(config["removePermissions"] as? [String] ?? []).contains($0)};var now=try NativePluginJSON.date(reference["epoch"] as! String)
            let seedData=NativePluginData(db:db,pluginId:definition.id,permissions:definition.permissions)
            let initial=scenario["initial"] as! [String:[Row]]
            for model in models { for row in initial[model] ?? [] { _ = try db.insert(model,values:seedData.values(row,model:model),actor:"fixture") } }
            let store=NativePluginStore(db:db,pluginId:definition.id,clock:{now})
            for (key,value) in config["store"] as? Row ?? [:] { try store.set(key,value) }
            var logs:[Row]=[],notifications:[Row]=[]
            let logger:(String,String,Row?)->Void={level,message,context in var row:Row=["level":level,"message":message];row["context"]=context;logs.append(row)}
            let data=NativePluginData(db:db,pluginId:definition.id,permissions:definition.permissions,clock:{now},logger:logger)
            let client=NativeOXOFixtureClient(config)
            let ctx=NativePluginContext(definition:definition,actor:.init(type:.system),locale:"ja",settings:scenario["settings"] as! Row,secrets:["apiKey":"oxo_"+String(repeating:"a",count:40)],store:store,data:data,clock:{now},logger:logger,translator:{key,args in key+(args.map{":"+(try! NativePluginJSON.text($0))} ?? "")},notification:{ input in if config["notifyError"] as? Bool == true { throw NativePluginError(message:"notification unavailable") };notifications.append(["roles":input.roles,"subject":input.subject,"text":input.text]) },transport:{ request in
                let components=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!,path=components.path.replacingOccurrences(of:"/api/v1",with:"")
                var params=(components.queryItems ?? []).map{($0.name,$0.value ?? "")};let body:Any,status:Int
                if request.httpMethod=="POST" { let input=try NativePluginJSON.record(String(decoding:request.httpBody!,as:UTF8.self)),result=try await client.post(path,input);body=result.body;status=result.status }
                else if params.contains(where:{$0.0=="limit"}) { params.removeAll{["limit","cursor"].contains($0.0)};body=["items":try await client.all(path,params),"nextCursor":NSNull()];status=200 }
                else { body=try await client.get(path,params);status=200 }
                return (try NativePluginJSON.data(body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:[:])!)
            },persistAfterTransaction:{$0()})
            let connector=NativeOXOConnector(ctx,client:client);var results:[Row]=[]
            func readRows(_ model:String,_ database:NativeDatabase,_ api:NativePluginData) throws -> [Row] { if model=="Currency" { return try database.page(model,fields:database.schema.model(model).fields.map(\.name),includeDeleted:true,limit:100).rows.map(api.record) };return try api.all(model,where:[:]) }
            func rows(_ model:String) throws -> [Row] { try readRows(model,db,data) }
            for action in scenario["actions"] as! [Row] {
                if let value=action["now"] as? String { now=try NativePluginJSON.date(value) }
                do { var value:Any=NSNull();let id=action["id"] as? String ?? ""
                    switch action["kind"] as! String {
                    case "definition":
                        func slots(_ kind:NativePluginSlot.Kind,_ title:Bool=false)->[Row] { definition.slots.filter{$0.kind==kind}.map{s in var r:Row=["id":s.id,"roles":s.roles.sorted()];if title{r["title"]=s.title};return r} }
                        let pages=definition.slots.filter{$0.kind == .page}.map{s -> Row in ["path":s.id,"title":s.title ?? "","roles":s.roles.sorted(),"nav":["label":s.nav ?? ""]]}
                        value=["id":definition.id,"name":definition.name,"version":definition.version,"sdk":definition.sdk,"description":definition.description,"permissions":definition.permissions,"afters":definition.afters.map{["entity":$0.entity.rawValue,"operation":$0.operation.rawValue]},"crons":definition.crons.map{["id":$0.id,"schedule":$0.schedule]},"accountTabs":slots(.accountTab,true),"accountPanels":slots(.accountPanel),"productPanels":slots(.productPanel),"orderPanels":slots(.orderPanel),"pages":pages,"adminActions":definition.slots.filter{$0.kind == .adminAction}.map{["id":$0.id,"label":$0.title ?? ""]},"adminSections":definition.slots.filter{$0.kind == .adminSection}.count]
                    case "install":try await definition.onInstall?(ctx)
                    case "cron":try await definition.crons[0].handler(ctx)
                    case "after":try await definition.afters[0].handler(.init(entity:.order,operation:.updated,recordId:id,actor:.init(type:.system),changed:nil),ctx)
                    case "sync":value=try await connector.runSync(now)
                    case "queue":value=try connector.queueJob(now)
                    case "queued":try await connector.runQueued(now)
                    case "lists":value=try await connector.loadPriceLists()
                    case "test":value=try await connector.testConnection()
                    case "scheduled":value=try await connector.scheduledSync(now)
                    case "body":value=try connector.orderBody(data.get("orders",id) ?? [:])
                    case "send":value=try await connector.sendOrder(id,now:now)
                    case "sweep":value=try await connector.sweepOrders(now)
                    case "statuses":value=try await connector.syncOrderStatuses(dry:NativePluginJSON.truthy(ctx.settings["dryRun"]),now:now)
                    case "incoming":value=try await connector.syncOrdersIn(dry:NativePluginJSON.truthy(ctx.settings["dryRun"]),now:now)
                    case "ui":
                        let accounts=try rows("crm_Accounts").map{row -> Row in let id=row["id"] as! String;return ["id":id,"panel":try connector.panelData(id),"tab":try connector.accountTabData(id)]}
                        let products=try rows("crm_Products").map{row -> Row in let id=row["id"] as! String;return ["id":id,"panel":try connector.productPanelData(id)]}
                        let orderPanels=try rows("crm_Orders").map{row -> Row in let id=row["id"] as! String;return ["id":id,"panel":try connector.orderPanelData(id)]}
                        value=["needsOwner":try connector.needsOwner(),"catalog":try connector.catalogData(),"orders":try connector.ordersData(now),"accounts":accounts,"products":products,"orderPanels":orderPanels]
                    default:throw NativePluginError(message:"Unknown fixture action")
                    };results.append(["value":value])
                } catch { results.append(["error":error.localizedDescription]) }
            }
            var snapshot:[String:[Row]]=[:];for model in models { snapshot[model]=try rows(model) }
            var jobs:[NativeJob]=[],offset=0
            while true { let page=try db.jobs(events:["plugin/event"],offset:offset);jobs+=page;if page.count<100 { break };offset+=100 }
            let events=try jobs.reversed().map{job -> Row in ["name":job.payload["event"] ?? "","data":try NativePluginJSON.parse(job.payload["data"] ?? "{}") ]}
            let capturedRequests=client.requests
            let stored=try store.list().map{["key":$0.key,"value":$0.value] as Row}
            let reopened=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            let reStore=NativePluginStore(db:reopened,pluginId:definition.id,clock:{now}),reData=NativePluginData(db:reopened,pluginId:definition.id,permissions:definition.permissions)
            guard NativePluginJSON.equal(stored,try reStore.list().map{["key":$0.key,"value":$0.value] as Row}) else { throw NativePluginError(message:"Store persistence mismatch") };nativeChecks+=1
            for model in models { guard NativePluginJSON.equal(snapshot[model],try readRows(model,reopened,reData)) else { throw NativePluginError(message:"Model persistence mismatch: "+model) };nativeChecks+=1 }
            if scenario["name"] as? String == "empty-dry" {
                client.intercept={_,_ in throw CancellationError()}
                var cancelled=false;do { _ = try await connector.runSync(now) } catch is CancellationError { cancelled=true }
                guard cancelled,try store.get("meta:lock")==nil,NativePluginJSON.equal(stored,try store.list().map{["key":$0.key,"value":$0.value] as Row}) else { throw NativePluginError(message:"Sync cancellation cleanup failed") };nativeChecks+=3
                let claim="sending:fixture-cancel";guard try store.claim(claim,ms:600000),try !reStore.claim(claim,ms:600000) else{throw NativePluginError(message:"Cross-connection claim exclusion failed")};nativeChecks+=2;try store.delete(claim)
                var signal:AsyncStream<Void>.Continuation!
                let entered=AsyncStream<Void>{signal=$0}
                client.intercept={_,_ in signal.yield(());try await Task.sleep(nanoseconds:30_000_000_000)}
                let worker=Task{try await connector.runSync(now)}
                var iterator=entered.makeAsyncIterator();_ = await iterator.next();worker.cancel()
                var taskCancelled=false;do{_ = try await worker.value}catch is CancellationError{taskCancelled=true}
                guard taskCancelled,try store.get("meta:lock") != nil else{throw NativePluginError(message:"Real task cancellation must retain guarded claim until TTL")};nativeChecks+=2
                now=now.addingTimeInterval(601);guard try reStore.claim("meta:lock",ms:600000) else{throw NativePluginError(message:"Cancelled claim did not expire")};nativeChecks+=1;try reStore.delete("meta:lock")
            }
            outputs.append(["name":scenario["name"]!,"result":["results":results,"snapshot":snapshot,"store":stored,"logs":logs,"notifications":notifications,"requests":capturedRequests,"events":events]])
        }
        try NativePluginJSON.data(outputs).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        print("NativeOXOTests: \(outputs.count) isolated SQLite scenarios / \(nativeChecks) native persistence and cancellation checks passed")
    }
}
