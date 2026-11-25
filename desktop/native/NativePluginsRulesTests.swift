import Foundation

enum NativePluginsRulesTests {
    static func run(_ resources:URL) throws {
        let reference=try NativePluginJSON.record(String(contentsOf:resources.appendingPathComponent("build/plugins-rules-reference.json"),encoding:.utf8))
        for scenario in reference["scenarios"] as! [NativePluginRecord] {
            let (root,db,_)=try NativePluginsRuntimeTests.fixture(resources);defer{try? FileManager.default.removeItem(at:root)}
            let mode=scenario["mode"] as! String,actor=mode=="self" ? NativePluginActor.plugin("a-test"):.init(type:.user,userId:"fixture-user",role:"user")
            var trace:[String]=[],definitions:[NativePluginDefinition]=[]
            for id in ["z-test","a-test"] {
                var definition=NativePluginDefinition(id:id,name:id,version:"0.1.0",sdk:"^0.2.0",description:"")
                definition.rules=[.init(entity:mode=="other-entity" ? .contact:.account,operation:.beforeCreate,onError:mode.hasSuffix("block") || mode=="block-error" ? "block":"allow",priority:id=="a-test" || mode=="tie" ? 10:20,handler:{ input,_ in
                    trace.append(id)
                    if id=="a-test" {
                        if mode.contains("timeout") {Thread.sleep(forTimeInterval:0.02)}
                        if mode.hasSuffix("error") {throw NativePluginError(message:"fixture rule error")}
                        if mode=="reject" {return .reject(messageKey:"blocked",params:["field":"name"])}
                    }
                    return .modify(["description":(input.data["description"] as? String ?? "")+id+";"])
                })]
                definitions.append(definition);try NativePluginsRuntimeTests.seed(db,definition,status:mode=="disabled" && id=="a-test" ? "DISABLED":"ENABLED")
            }
            let host=try NativePluginsRuntimeTests.host(db,definitions);host.ruleTimeout=mode.contains("timeout") ? 0.001:0.5
            var output:NativePluginRecord
            do {
                let frame=NativePluginActorScope.Frame(actor:actor,depth:mode=="depth" ? 4:actor.type == .plugin ? 1:0,locale:"en")
                let result=try NativePluginActorScope.$current.withValue(frame) {try host.runBefore(.init(entity:.account,operation:.beforeCreate,recordId:nil,data:["name":"Fixture"],existing:nil),actor:actor,locale:"en")}
                output=["ok":true,"value":result]
            } catch let error as NativePluginRuleError {output=["ok":false,"error":["pluginId":error.pluginId as Any? ?? NSNull(),"messageKey":error.messageKey,"params":error.params as Any? ?? NSNull()]]}
            catch {output=["ok":false,"error":["message":error.localizedDescription]]}
            try NativePluginsRuntimeTests.check(NativePluginJSON.equal(output,scenario["output"]),"rules \(mode) result")
            try NativePluginsRuntimeTests.check(NativePluginJSON.equal(trace,scenario["trace"]),"rules \(mode) order")
            try NativePluginsRuntimeTests.check(try db.page("PluginLog",fields:[]).total==scenario["logs"] as? Int,"rules \(mode) diagnostic logs")
        }
    }
}
