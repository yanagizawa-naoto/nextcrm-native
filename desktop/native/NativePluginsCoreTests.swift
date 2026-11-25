import Foundation

@main enum NativePluginsCoreTests {
    static func main() throws {
        let fixture=try NativePluginJSON.record(String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)),cases=fixture["cases"] as! [NativePluginRecord]
        var failures:[NativePluginRecord]=[]
        for (index,test) in cases.enumerated() {
            let input=test["input"] as! NativePluginRecord,kind=test["kind"] as! String
            var actual:NativePluginRecord
            do { actual=["ok":true,"value":try run(kind,input)] } catch { actual=["ok":false,"error":error.localizedDescription] }
            let expected=test.filter { ["ok","value","error"].contains($0.key) }
            if !NativePluginJSON.equal(actual,expected) { failures.append(["index":index,"kind":kind,"actual":actual,"expected":expected]) }
        }
        print(try NativePluginJSON.text(["cases":cases.count,"checks":cases.count,"failures":failures.count,"examples":Array(failures.prefix(5))]))
        if !failures.isEmpty { exit(1) }
    }
    static func run(_ kind:String,_ input:NativePluginRecord) throws -> Any {
        switch kind {
        case "parseVersion": return try NativePluginSDK.parseVersion(input["value"] as! String)
        case "compareVersions": return try NativePluginSDK.compareVersions(input["a"] as! String,input["b"] as! String)
        case "satisfies": return try NativePluginSDK.satisfies(input["range"] as! String)
        case "country": return NativeAccountProtectionState.countryCode(input["raw"],fallback:input["fallback"] as! String)
        case "numberKey": return NativeAccountProtectionState.numberKey(input["account"] as! NativePluginRecord,defaultCountry:input["fallback"] as! String) as Any? ?? NSNull()
        case "settings":
            var warnings:[NativePluginRecord]=[];let schema=NativePluginSettingsSchema.accountProtection
            let parsed=schema.stored(input["value"]) { message,context in warnings.append(["message":message,"context":context]) }
            return ["parsed":parsed,"warnings":warnings,"description":schema.description,"valid":(try? schema.parse(input["value"]!)) != nil]
        case "addMonths": return try NativeAccountProtectionState.addMonths(input["day"] as! String,(input["months"] as! NSNumber).intValue)
        case "newRegistration": return try NativeAccountProtectionState.newRegistration(key:"CZ:00000123",ownerId:"owner",at:NativePluginJSON.date(input["at"] as! String),settings:input["settings"] as! NativePluginRecord)
        case "withOrders":
            let reg=try NativeAccountProtectionState.withOrders(input["reg"] as! NativePluginRecord,last:input["last"] as? String,months:(input["months"] as! NSNumber).intValue)
            return ["reg":reg,"due":NativeAccountProtectionState.dueDay(reg),"since":String((reg["registeredAt"] as! String).prefix(10))+"T00:00:00.000Z","summary":NativeAccountProtectionState.summarize(hasKey:true,reg:reg,contactAt:reg["contactAt"] as? String),"verdict":try NativeAccountProtectionState.evaluate(reg,now:NativePluginJSON.date("2026-02-01T12:34:56.789Z"))]
        case "formatDay": return try NativeAccountProtectionState.formatDay(input["date"] as! String,locale:input["locale"] as! String)
        case "numberString": return NativePluginJSON.string(input["value"])
        case "parseJSON":return try NativePluginJSON.parse(input["raw"] as! String)
        case "timeZone":return NativePluginJSON.timeZoneOffset(input["zone"] as! String,at:try NativePluginJSON.date(input["date"] as! String)) as Any? ?? NSNull()
        default: throw NativePluginError(message:"Unknown case: "+kind)
        }
    }
}
