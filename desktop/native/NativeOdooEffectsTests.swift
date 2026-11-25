import Foundation

/// Replays actual original HTTP transcripts against isolated real SQLite effects.
@main struct NativeOdooEffectsTests {
    typealias Row = NativePluginRecord
    final class Replay {
        let lock=NSRecursiveLock();var trace:[Row]=[],consumed:Set<Int>=[],errors:[String]=[],sleeps:[Int]=[],notes:[Row]=[],logs:[Row]=[]
        func sync<T>(_ f:()->T)->T { lock.lock();defer { lock.unlock() };return f() }
        func reset(_ next:[Row]) { sync { trace=next;consumed=[];errors=[];sleeps=[];notes=[];logs=[] } }
        func respond(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
            lock.lock();defer { lock.unlock() }
            let value:Row=["url":request.url!.absoluteString,"method":request.httpMethod!,"headers":Dictionary(uniqueKeysWithValues:(request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(),$0.value) }),"body":try JSONSerialization.jsonObject(with:request.httpBody!)]
            guard let index=trace.indices.first(where: { !consumed.contains($0) && NativePluginJSON.equal(trace[$0]["request"],value) }) else {
                let text=try NativePluginJSON.text(value);errors.append(text);throw CancellationError()
            }
            consumed.insert(index);let response=trace[index]["response"] as! Row
            return (Data((response["raw"] as! String).utf8),HTTPURLResponse(url:request.url!,statusCode:response["status"] as! Int,httpVersion:"HTTP/1.1",headerFields:[:])!)
        }
    }
    static func all(_ model:String,db:NativeDatabase,data:NativePluginData)throws->[Row] {
        let fields=try db.schema.model(model).fields.filter { $0.name != "password" }.map(\.name);var rows:[Row]=[],offset=0
        while true { let page=try db.page(model,fields:fields,includeDeleted:true,offset:offset,limit:100);rows += try page.rows.map(data.record);if page.rows.count<100 { break };offset += page.rows.count };return rows
    }
    static func views(_ ctx:NativePluginContext,now:Date)throws->Row {
        let accounts=try all("crm_Accounts",db:ctx.data.db,data:ctx.data),products=try all("crm_Products",db:ctx.data.db,data:ctx.data),orders=try all("crm_Orders",db:ctx.data.db,data:ctx.data)
        return ["needsOwner":try NativeOdooViews.needsOwner(ctx),"catalog":try NativeOdooViews.catalog(ctx),"orders":try NativeOdooViews.orders(ctx,now:now),"accounts":try accounts.map { a -> Row in let id=a["id"] as! String;return ["id":id,"panel":try NativeOdooViews.accountPanel(ctx,id:id) as Any? ?? NSNull(),"tab":try NativeOdooViews.accountTab(ctx,id:id,now:now) as Any? ?? NSNull()] },"products":try products.map { p -> Row in let id=p["id"] as! String;return ["id":id,"panel":try NativeOdooViews.productPanel(ctx,id:id) as Any? ?? NSNull()] },"orderPanels":try orders.map { o -> Row in let id=o["id"] as! String;return ["id":id,"panel":try NativeOdooViews.orderPanel(ctx,id:id) as Any? ?? NSNull()] }]
    }
    static func main() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),fixture=try NativePluginJSON.parse(String(contentsOfFile:CommandLine.arguments[2],encoding:.utf8)) as! Row,models=fixture["models"] as! [String]
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-OdooEffects-"+UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        var outputs:[Row]=[]
        for (caseIndex,c) in (fixture["cases"] as! [Row]).enumerated() {
            let db=try NativeDatabase(url:root.appendingPathComponent("\(caseIndex)/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            var now=try NativePluginJSON.date("2026-10-13T08:00:00.000Z");let clock={now},replay=Replay(),store=NativePluginStore(db:db,pluginId:"odoo-connector",clock:clock),data=NativePluginData(db:db,pluginId:"odoo-connector",permissions:NativeOdooPlugin.permissions,clock:clock)
            _=try db.insert("InstalledPlugin",values:["id":.text("odoo-connector"),"version":.text("0.4.2"),"status":.text("ENABLED"),"settings":.text("{}")],actor:"fixture")
            for model in models { for values in (c["initial"] as! Row)[model] as! [Row] { _=try db.insert(model,values:data.values(values,model:model),actor:"fixture") } }
            for (key,value) in c["initialStore"] as! Row { try store.set(key,value) }
            var output:[Row]=[],oldJobs=Set<String>()
            for step in c["steps"] as! [Row] {
                let input=step["input"] as! Row;now=try NativePluginJSON.date(input["now"] as! String);replay.reset(step["trace"] as! [Row])
                for key in input["deleteStore"] as! [String] { try store.delete(key) };for (key,value) in input["setStore"] as! Row { try store.set(key,value) }
                for change in input["changes"] as! [Row] { let model=change["model"] as! String,schema=try db.schema.model(model),rows=try db.mcpPage(model,fields:schema.fields.map(\.name),filter:data.filter(change["where"],schema:schema),limit:100,offset:0,includeDeleted:true).rows;for row in rows { _=try db.update(row,changes:data.values(change["data"] as! Row,model:model,existing:row),actor:"fixture") } }
                let ctx=NativePluginContext(definition:NativeOdooPlugin.definition,actor:.system,locale:"ja",settings:input["settings"] as! Row,secrets:c["secrets"] as! Row,store:store,data:data,clock:clock,logger:{level,message,context in replay.sync { var row:Row=["level":level,"message":message];if let context { row["context"]=context };replay.logs.append(row) } },translator:{ key,params in key+(params.map { ":"+(try! NativePluginJSON.text($0)) } ?? "") },notification:{ note in replay.sync { var row:Row=["subject":note.subject,"text":note.text];if !note.roles.isEmpty { row["roles"]=note.roles };if !note.userIds.isEmpty { row["userIds"]=note.userIds };replay.notes.append(row) } },transport:replay.respond,persistAfterTransaction:{ $0() })
                let client=NativeOdooClient.json(ctx,sleep:{ ms in replay.sync { replay.sleeps.append(ms) } });let result:Row
                do { let value:Any
                    switch input["op"] as! String {
                    case "sync":value=try await NativeOdooSync.run(ctx,client,now:now)
                    case "scheduled":value=try await NativeOdooSync.scheduled(ctx,client,now:now)
                    case "catalog":value=try await NativeOdooCatalog.sync(ctx,client,dry:NativePluginJSON.truthy(ctx.settings["dryRun"]),now:now)
                    case "parallelSend":
                        let parallelNow=now
                        async let a=NativeOdooOrdersOut.sendOrder(ctx,client,orderID:input["id"] as! String,now:parallelNow)
                        async let b=NativeOdooOrdersOut.sendOrder(ctx,client,orderID:input["id"] as! String,now:parallelNow)
                        value=try await [a,b].sorted()
                    case "after":try await NativeOdooOrdersOut.onUpdated(.init(entity:.order,operation:.updated,recordId:input["id"] as! String),ctx);value=NSNull()
                    case "install":try await NativeOdooPlugin.definition.onInstall?(ctx);value=NSNull()
                    case "cron":try await NativeOdooPlugin.definition.crons[0].handler(ctx);value=NSNull()
                    case "send":value=try await NativeOdooOrdersOut.sendOrder(ctx,client,orderID:input["id"] as! String,now:now)
                    case "sweep":value=try await NativeOdooOrdersOut.sweep(ctx,client,now:now)
                    case "import":value=try await NativeOdooOrdersIn.sync(ctx,client,dry:NativePluginJSON.truthy(ctx.settings["dryRun"]),now:now)
                    case "status":value=try await NativeOdooOrdersStatus.sync(ctx,client,dry:NativePluginJSON.truthy(ctx.settings["dryRun"]),now:now)
                    case "compare":try await NativeOdooCompare.run(ctx,client,now:now);value=NSNull()
                    case "queue":value=try NativeOdooPlugin.queue(ctx,name:input["name"] as! String,now:now)
                    case "queued":try await NativeOdooPlugin.runQueued(ctx,client,now:now);value=NSNull()
                    case "lists":value=try await NativeOdooPlugin.loadLists(ctx,client);default:value=NSNull()
                    };result=["ok":true,"value":value]
                } catch { result=["ok":false,"error":NativeOdooError.message(error)] }
                var state:Row=[:];for model in models { state[model]=try all(model,db:db,data:data) }
                var events:[Row]=[],offset=0
                while true { let jobs=try db.jobs(events:["plugin/event"],offset:offset);for job in jobs where !oldJobs.contains(job.id) { oldJobs.insert(job.id);events.append(["name":job.payload["event"]!,"data":try NativePluginJSON.parse(job.payload["data"]!)]) };if jobs.count<100 { break };offset += jobs.count }
                output.append(["result":result,"state":state,"store":Dictionary(uniqueKeysWithValues:try store.list().map { ($0.key,$0.value) }),"events":events.reversed().map{$0},"notifications":replay.notes,"logs":replay.logs,"views":try views(ctx,now:now),"traceErrors":replay.errors,"unusedTrace":replay.trace.count-replay.consumed.count,"sleeps":replay.sleeps])
            }
            outputs.append(["name":c["name"]!,"steps":output])
        }
        let settingsResults=(fixture["settingsCases"] as? [Row] ?? []).map { item -> Row in
            do { return ["ok":true,"data":try NativePluginSettingsSchema.connector(oxo:false).parse(item["input"]!)] } catch { return ["ok":false] }
        }
        let secretResults=(fixture["secretCases"] as? [Row] ?? []).map { item -> Row in
            do { return ["ok":true,"data":try NativePluginSettingsSchema.connectorSecrets(oxo:false).parse(item["input"]!)] } catch { return ["ok":false] }
        }
        try NativePluginJSON.data(["cases":outputs,"settings":settingsResults,"secrets":secretResults]).write(to:URL(fileURLWithPath:CommandLine.arguments[3]));print("NativeOdooEffectsTests: \(outputs.count) scenarios executed against isolated SQLite")
    }
}
