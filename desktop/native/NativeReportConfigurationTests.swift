import Foundation

enum NativeReportConfigurationTests {
    static func run(db: NativeDatabase, services: [String:CRMService], resources: URL) throws -> Int {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/report-configs-reference.json"))) as! [String:Any]
        let users=reference["users"] as! [[String:String]],admin=services[users[0]["id"]!]!,actor=admin.identity.id
        let adminStore=NativeReportConfigurations(service:admin)
        var checks=0
        func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws {guard try value() else{throw NativeDBError.message("FAIL configurations: "+label)};checks+=1}
        func rejects(_ label: String,_ work: () throws -> Void) throws {do{try work()}catch{checks+=1;return};throw NativeDBError.message("FAIL configurations accepted: "+label)}
        func sql(_ value: Any) throws -> SQLValue {if let value=value as? String{return .text(value)};if let value=value as? NSNumber{return .integer(value.int64Value)};return .text(String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self))}
        let configs=reference["configs"] as! [[String:Any]]
        var originals:[String:NativeReportConfiguration]=[:]
        for c in configs {let row=try db.insert("crm_Report_Config",values:c.mapValues(sql),actor:actor);originals[row["id"].string]=try adminStore.load(row["id"].string)}
        for c in reference["lists"] as! [[String:Any]] {let store=NativeReportConfigurations(service:services[c["user"] as! String]!);let list=try store.list(category:.sales);try check(Set(list.rows.map{$0["id"].string})==Set(c["ids"] as! [String]),"source read list")}
        for c in reference["scopes"] as! [[String:Any]] {
            let service=services[c["user"] as! String]!,store=NativeReportConfigurations(service:service),original=originals[c["config"] as! String]!
            try check(((try? store.load(original.id)) != nil)==(c["read"] as! Bool),"source read scope")
            var values=original.record.values;values.removeValue(forKey:"id");values.removeValue(forKey:"updatedAt")
            let clone=try db.insert("crm_Report_Config",values:values,actor:actor)
            var current=try adminStore.load(clone["id"].string)
            if c["duplicate"] as! Bool {
                let copy=try store.duplicate(current,name:"自分の複製")
                try check(copy.record["createdBy"] == .text(service.identity.id) && copy.record["isShared"] == .integer(0),"duplicate private owner")
                try check(copy.filters.parameters==original.filters.parameters,"duplicate keeps all original filters")
                try adminStore.delete(copy)
            } else {try rejects("duplicate private other owner"){_ = try store.duplicate(current,name:"不可")}}
            if c["share"] as! Bool {current=try store.share(current,enabled:false);try check(current.record["isShared"] == .integer(0),"source share scope")}
            else {try rejects("share others"){_ = try store.share(current,enabled:false)}}
            if c["delete"] as! Bool {try store.delete(current);try check(try db.get("crm_Report_Config",key:["id":.text(current.id)])==nil,"source delete scope")}
            else {try rejects("delete others"){try store.delete(current)};try adminStore.delete(current)}
        }
        let creation=reference["create"] as! [String:Any],input=creation["input"] as! [String:Any]
        let filters=try NativeReportSavedFilters(json:String(decoding:JSONSerialization.data(withJSONObject:input["filters"]!),as:UTF8.self))
        let alice=services[users[2]["id"]!]!,store=NativeReportConfigurations(service:alice)
        let saved=try store.save(name:input["name"] as! String,category:.accounts,filters:filters,shared:true)
        try check(saved.name==input["name"] as! String&&saved.record["createdBy"] == .text(alice.identity.id)&&saved.record["isShared"] == .integer(1),"source save fields")
        let initial=try saved.filters.period()
        try check(NativeReportFilters.timestamp(initial.from)=="2026-09-01T00:00:00.000Z" && NativeReportFilters.timestamp(initial.to)=="2026-11-01T00:00:00.000Z","source date-only UTC semantics")
        let retained=try NativeReportSavedFilters(period:initial,currency:"USD",retaining:filters.parameters)
        try check(try retained.currency=="USD" && retained.parameters["accountId"]=="元の取引先","preserve unused source parameters")
        try check(try retained.period().from==initial.from && retained.period().to==initial.to,"exact ISO period roundtrip")
        let changed=try store.share(saved,enabled:false)
        try rejects("stale shared change"){_ = try store.share(saved,enabled:true)}
        try rejects("stale delete"){try store.delete(saved)}
        try rejects("stale duplicate"){_ = try store.duplicate(saved,name:"古い条件")}
        let bobStore=NativeReportConfigurations(service:services[users[3]["id"]!]!)
        try rejects("sharing revoked"){_ = try bobStore.load(changed.id)}
        try rejects("empty name"){_ = try store.save(name:"　 ",category:.sales,filters:filters,shared:false)}
        try rejects("long name"){_ = try store.save(name:String(repeating:"名",count:257),category:.sales,filters:filters,shared:false)}
        try rejects("overview is not source saved category"){_ = try store.save(name:"概要",category:.overview,filters:filters,shared:false)}
        try rejects("invalid JSON"){_ = try NativeReportSavedFilters(json:"[]")}
        try rejects("invalid dates"){_ = try NativeReportSavedFilters(json:"{\"from\":\"2026-02-30\"}").period()}
        try rejects("invalid currency"){_ = try NativeReportSavedFilters(json:"{\"currency\":\"JPY'\"}").currency}
        let clock=ISO8601DateFormatter().date(from:"2026-11-19T12:00:00Z")!,fallback=try NativeReportSavedFilters(json:"{}").period(now:clock)
        try check(fallback.to==clock && Calendar.current.dateComponents([.day],from:fallback.from,to:fallback.to).day==30,"source missing period defaults")
        // Inspect metadata without ever materializing an oversized imported JSON.
        let huge=try db.insert("crm_Report_Config",values:["name":.text(String(repeating:"巨大",count:1000)),"category":.text("sales"),"filters":.text("{\"from\":\""+String(repeating:"x",count:200_000)+"\"}"),"createdBy":.text(actor)],actor:actor)
        try rejects("oversized imported record rejected before get"){_ = try adminStore.load(huge["id"].string)}
        let metadata=try adminStore.list(category:.sales)
        try check(metadata.rows.first{$0["id"]==huge["id"]}!["name"].string.unicodeScalars.count==256,"bounded list name")
        try check(metadata.rows.allSatisfy{$0.values["filters"]==nil},"list excludes JSON")
        for i in 0..<105 {_ = try store.save(name:"保存条件\(i)",category:.leads,filters:filters,shared:false)}
        let first=try store.list(category:.leads),second=try store.list(category:.leads,offset:100)
        try check(first.rows.count==100 && second.rows.count==5 && first.total==105,"configuration list pagination")
        try check(Set(first.rows.map{$0["id"].string}).isDisjoint(with:second.rows.map{$0["id"].string}),"configuration pages distinct")
        let schedule=try db.insert("crm_Report_Schedule",values:["reportConfigId":.text(changed.id),"cronExpression":.text("0 9 * * 1"),"recipients":.text("[\"fake@example.invalid\"]"),"format":.text("csv"),"createdBy":.text(actor)],actor:actor)
        try store.delete(changed)
        try check(try db.get("crm_Report_Schedule",key:["id":schedule["id"]])==nil,"source config deletion cascades schedules")
        let user=try db.get("Users",key:["id":.text(alice.identity.id)])!,banned=try db.update(user,changes:["banned":.integer(1)],actor:actor)
        try rejects("revoked list"){_ = try store.list()}
        try rejects("revoked save"){_ = try store.save(name:"不可",category:.sales,filters:filters,shared:false)}
        try db.update(banned,changes:["banned":.integer(0)],actor:actor)
        return checks
    }
}
