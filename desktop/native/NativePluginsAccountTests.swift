import Foundation

@main enum NativePluginsAccountTests {
    static var checks=0
    static func check(_ value:Bool,_ name:String) throws { checks+=1;if !value { throw NativePluginError(message:name) } }
    static func main() async {
        do { try await perform() } catch { print(try! NativePluginJSON.text(["exit":1,"checks":checks,"error":error.localizedDescription]));exit(1) }
    }
    static func perform() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try NativePluginJSON.record(String(contentsOf:resources.appendingPathComponent("build/plugins-account-reference.json"),encoding:.utf8))
        let scenarios=reference["scenarios"] as! [NativePluginRecord]
        for scenario in scenarios { try await run(scenario,reference,resources) }
        let hostChecks=try await NativePluginsHostTests.run(resources)
        print(try NativePluginJSON.text(["scenarios":scenarios.count,"checks":checks,"hostChecks":hostChecks,"exit":0]))
    }
    static func uid(_ n:Int)->String { "a0000000-0000-4000-8000-"+String(format:"%012d",n) }
    static func run(_ scenario:NativePluginRecord,_ reference:NativePluginRecord,_ resources:URL) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NativePluginsAccount-"+UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")),identity=try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let config=scenario["config"] as! NativePluginRecord,name=scenario["name"] as! String
        for n in 100...102 { try db.insert("Users",values:["id":.text(uid(n)),"name":.text("User "+uid(n)),"email":.text("qa\(n)@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE"),"v":.integer(0)],actor:identity.id) }
        var now=try NativePluginJSON.date(reference["epoch"] as! String)
        let data=NativePluginData(db:db,pluginId:NativeAccountProtection.id,permissions:[])
        for account in reference["base"] as! [NativePluginRecord] { var values=try data.values(account,model:"crm_Accounts");values["v"] = .integer(0);try db.insert("crm_Accounts",values:values,actor:identity.id) }
        let orders=config["orders"] as? [NativePluginRecord] ?? []
        if !orders.isEmpty {
            let series=try db.page("NumberSeries",fields:["id"],equal:["scope":.text("order")],limit:1).rows.first!
            let currency=try db.page("Currency",fields:["code"],equal:["isDefault":.integer(1)],limit:1).rows.first!["code"]
            for order in orders { var values=try data.values(order,model:"crm_Orders");values["seriesId"]=series["id"];values["currency"]=currency;values["number"] = .text("fixture-"+(order["id"] as! String));try db.insert("crm_Orders",values:values,actor:identity.id) }
        }
        for activity in config["activities"] as? [NativePluginRecord] ?? [] {
            var input=activity;let account=input.removeValue(forKey:"accountId") as! String
            input["title"]="Fixture activity"
            let row=try db.insert("crm_Activities",values:try data.values(input,model:"crm_Activities"),actor:identity.id)
            try db.insert("crm_ActivityLinks",values:["activityId":row["id"],"entityType":.text("account"),"entityId":.text(account)],actor:identity.id)
        }
        var definition=NativeAccountProtection.definition()
        if config["orderError"] as? Bool == true { definition.permissions.removeAll { $0=="orders:read" } }
        let settings=try definition.settings.parse(config["settings"] ?? NativePluginRecord()),actorData=config["actor"] as? NativePluginRecord ?? ["type":"user","userId":uid(102),"role":"user"]
        let actor=try JSONDecoder().decode(NativePluginActor.self,from:NativePluginJSON.data(actorData)),store=NativePluginStore(db:db,pluginId:definition.id,clock:{now})
        var logs:[NativePluginRecord]=[],notifications:[NativePluginRecord]=[]
        let logger:(String,String,NativePluginRecord?)->Void={ level,message,context in var value:NativePluginRecord=["level":level,"message":message];value["context"]=context;logs.append(value) }
        let liveData=NativePluginData(db:db,pluginId:definition.id,permissions:definition.permissions,clock:{now},logger:logger)
        let ctx=NativePluginContext(definition:definition,actor:actor,locale:config["locale"] as? String ?? "en",settings:settings,secrets:[:],store:store,data:liveData,clock:{now},logger:logger,translator:{ key,params in
            // The oracle deliberately stubs only translation; message JSON is
            // checked independently by the common host tests.
            if let params { let ordered=params.keys.sorted();let parts=ordered.map { key in "\""+key+"\":"+(try! NativePluginJSON.text(params[key]!)) };return key+":{"+parts.joined(separator:",")+"}" };return key
        },notification:{ input in if config["notifyError"] as? Bool == true { throw NativePluginError(message:"notification unavailable") };notifications.append(["roles":input.roles,"subject":input.subject,"text":input.text]) },transport:{ _ in throw NativePluginError(message:"No network in fixture") },persistAfterTransaction:{ $0() })
        var results:[NativePluginRecord]=[]
        for action in scenario["actions"] as! [NativePluginRecord] {
            if let value=action["now"] as? String { now=try NativePluginJSON.date(value) }
            do {
                var result:Any=NSNull()
                switch action["kind"] as! String {
                case "install":try NativeAccountProtection.install(ctx,now)
                case "createRule","updateRule":
                    let update=action["kind"] as? String == "updateRule",id=action["id"] as? String,existing=try id.flatMap { try liveData.get("accounts",$0) }
                    let input=NativePluginRuleInput(entity:.account,operation:update ? .beforeUpdate:.beforeCreate,recordId:id,data:action["data"] as! NativePluginRecord,existing:existing)
                    let value=try update ? NativeAccountProtection.beforeUpdate(input,ctx):NativeAccountProtection.beforeCreate(input,ctx)
                    switch value { case .allow:result=["kind":"allow"];case let .modify(patch):result=["kind":"modify","patch":patch];case let .reject(key,params):var object:NativePluginRecord=["kind":"reject","messageKey":key];object["params"]=params;result=object }
                case "after":
                    let id=action["id"] as! String
                    if let patch=action["patch"] as? NativePluginRecord,let row=try db.get("crm_Accounts",key:["id":.text(id)]) { try db.update(row,changes:try data.values(patch,model:"crm_Accounts"),actor:identity.id) }
                    let actor=try (action["actor"] as? NativePluginRecord).map { try JSONDecoder().decode(NativePluginActor.self,from:NativePluginJSON.data($0)) }
                    try NativeAccountProtection.after(.init(entity:.account,operation:.init(rawValue:action["operation"] as! String)!,recordId:id,actor:actor,changed:action["changed"] as? [String]),ctx)
                case "order":
                    let id=action["id"] as! String
                    if let patch=action["patch"] as? NativePluginRecord,let row=try db.get("crm_Orders",key:["id":.text(id)]) { try db.update(row,changes:try data.values(patch,model:"crm_Orders"),actor:identity.id) }
                    try NativeAccountProtection.after(.init(entity:.order,operation:.init(rawValue:action["operation"] as! String)!,recordId:id,changed:action["changed"] as? [String]),ctx)
                case "set":try store.set(action["key"] as! String,action["value"]!)
                case "expire":try await NativeAccountProtection.expire(ctx,now)
                case "notices":try await NativeAccountProtection.sendNotices(ctx,now)
                case "resume":try NativeAccountProtection.resume(ctx,now)
                case "upgrade":try NativeAccountProtection.upgrade(ctx,now)
                default:throw NativePluginError(message:"Unknown fixture action")
                }
                results.append(["ok":true,"value":result])
            } catch { results.append(["ok":false,"error":error.localizedDescription]) }
        }
        try check(NativePluginJSON.equal(results,scenario["results"]),name+": results")
        let stored=try store.list(),actualStore=stored.filter { !$0.key.hasPrefix("notice:") }.map { ["key":$0.key,"value":$0.value] as NativePluginRecord }
        if !NativePluginJSON.equal(actualStore,scenario["store"]) { print(try NativePluginJSON.text(["scenario":name,"actualStore":actualStore,"expectedStore":scenario["store"]!])) }
        try check(NativePluginJSON.equal(actualStore,scenario["store"]),name+": store")
        let actualNotices=stored.filter{$0.key.hasPrefix("notice:")}.map { try! NativePluginJSON.text($0.value) }.sorted(),expectedNotices=(scenario["notices"] as! [Any]).map { try! NativePluginJSON.text($0) }.sorted()
        try check(actualNotices==expectedNotices,name+": notices")
        for expected in scenario["accounts"] as! [NativePluginRecord] {
            let actual=try liveData.get("accounts",expected["id"] as! String)!.filter { expected[$0.key] != nil };try check(NativePluginJSON.equal(actual,expected),name+": account")
        }
        // JSON object key order in translated params is semantically irrelevant.
        func normalizedNotices(_ notices:[NativePluginRecord])->[NativePluginRecord] { notices.map { item in item.mapValues { value in
            guard let text=value as? String,let start=text.range(of:":{"),let object=try? NativePluginJSON.parse(String(text[start.lowerBound...].dropFirst())) else { return value }
            return String(text[..<start.lowerBound])+":"+(try! NativePluginJSON.text(object))
        } } }
        try check(NativePluginJSON.equal(normalizedNotices(notifications),normalizedNotices(scenario["notifications"] as! [NativePluginRecord])),name+": notifications")
        let expectedLogs=scenario["logs"] as! [NativePluginRecord]
        func normalizedLogs(_ values:[NativePluginRecord])->[NativePluginRecord] { values.map { value in var result=value;if let message=value["message"] as? String,message.contains(": ") { result["message"]=String(message.prefix(while:{$0 != ":"})) };return result } }
        try check(NativePluginJSON.equal(normalizedLogs(logs),normalizedLogs(expectedLogs)),name+": log levels/context")
    }
}
