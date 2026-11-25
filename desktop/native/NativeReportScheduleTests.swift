import Foundation

enum NativeReportScheduleTests {
    static func run(db:NativeDatabase,services:[String:CRMService],resources:URL)throws->Int {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("build/report-schedules-reference.json"))) as! [String:Any]
        let users=reference["users"] as! [[String:String]],admin=services[users[0]["id"]!]!,actor=admin.identity.id,now=ISO8601DateFormatter().date(from:"2026-11-19T00:00:00Z")!
        let adminStore=NativeReportSchedules(service:admin),settings=try NativeReportScheduleSettings(expression:"0 9 * * 1",recipients:[" recipient@example.invalid ","RECIPIENT@example.invalid"],format:"both",timeZone:"Asia/Tokyo")
        var checks=0
        func check(_ value:@autoclosure()throws->Bool,_ label:String)throws {guard try value()else{throw NativeDBError.message("FAIL schedule: "+label)};checks+=1}
        func rejects(_ label:String,_ work:()throws->Void)throws {do{try work()}catch{checks+=1;return};throw NativeDBError.message("FAIL schedule accepted: "+label)}
        func sql(_ value:Any)throws->SQLValue {if let value=value as? String{return .text(value)};if let value=value as? NSNumber{return .integer(value.int64Value)};return .text(String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self))}
        for config in reference["configs"] as! [[String:Any]] {_ = try db.insert("crm_Report_Config",values:config.mapValues(sql),actor:actor)}
        for row in reference["schedules"] as! [[String:Any]] {_ = try db.insert("crm_Report_Schedule",values:row.mapValues(sql),actor:actor)}
        try check(settings.recipients==["recipient@example.invalid"],"trim and deduplicate recipients")
        for item in reference["lists"] as! [[String:Any]] {let store=NativeReportSchedules(service:services[item["user"] as! String]!);try check(Set(try store.list().rows.map{$0["id"].string})==Set(item["ids"] as! [String]),"original list scope")}
        for item in reference["creates"] as! [[String:Any]] {
            let service=services[item["user"] as! String]!,store=NativeReportSchedules(service:service),configID=item["config"] as! String
            if item["allowed"] as! Bool {
                let row=try store.create(configID:configID,settings:settings,now:now)
                try check(row.record["createdBy"] == .text(service.identity.id),"original creator")
                try check(try store.load(row.id).settings.timeZone.identifier=="Asia/Tokyo","timezone persists")
                try store.delete(row.record)
            } else {try rejects("original create denial"){_ = try store.create(configID:configID,settings:settings,now:now)}}
        }
        for item in reference["scopes"] as! [[String:Any]] {
            let store=NativeReportSchedules(service:services[item["user"] as! String]!),id=item["schedule"] as! String
            if item["update"] as! Bool {
                let old=try store.load(id),changed=try store.update(old,settings:settings,isActive:false,now:now)
                try check(!changed.isActive,"source update scope")
                try rejects("stale edit"){_ = try store.update(old,settings:settings,isActive:false,now:now)}
            } else {try rejects("source read/update denial"){let row=try store.load(id);_ = try store.update(row,settings:settings,isActive:false,now:now)}}
            let current=try adminStore.load(id)
            if item["delete"] as! Bool {
                try db.transaction {try store.delete(current.record);try check(try db.get("crm_Report_Schedule",key:["id":.text(id)])==nil,"source delete scope");_ = try db.insert("crm_Report_Schedule",values:current.record.values,actor:actor)}
            } else {try rejects("source delete denial"){try store.delete(current.record)}}
        }
        let alice=services[users[2]["id"]!]!,bob=services[users[3]["id"]!]!,store=NativeReportSchedules(service:bob),configs=NativeReportConfigurations(service:alice)
        let filters=try NativeReportSavedFilters(json:"{}"),shared=try configs.save(name:"予約共有条件",category:.sales,filters:filters,shared:true)
        let created=try store.create(configID:shared.id,settings:settings,now:now),generation=try db.metadata("reportSchedule.generation."+created.id)
        _ = try configs.share(shared,enabled:false)
        try rejects("revoked config cannot activate"){_ = try store.update(created,settings:settings,isActive:true,now:now)}
        let disabled=try store.update(created,settings:settings,isActive:false,now:now)
        try check(try db.metadata("reportSchedule.generation."+created.id) != generation,"edits fence old generation")
        try check(try store.list().rows.contains{$0["id"] == .text(created.id)},"owner can manage revoked config schedule")
        try store.delete(disabled.record);try check(try db.metadata("reportSchedule.timezone."+created.id)==nil,"delete cleans timezone")
        for recipients in [[],["invalid"],["a@example.invalid\r\nBcc:x@example.invalid"],Array(repeating:"x@example.invalid",count:51)] {
            try rejects("invalid recipients"){_ = try NativeReportScheduleSettings(expression:"0 9 * * *",recipients:recipients,format:"pdf",timeZone:"Asia/Tokyo")}
        }
        try rejects("invalid format"){_ = try NativeReportScheduleSettings(expression:"0 9 * * *",recipients:["x@example.invalid"],format:"zip",timeZone:"Asia/Tokyo")}
        try rejects("invalid zone"){_ = try NativeReportScheduleSettings(expression:"0 9 * * *",recipients:["x@example.invalid"],format:"pdf",timeZone:"invalid")}
        let own=try NativeReportConfigurations(service:bob).save(name:"予約検証",category:.sales,filters:filters,shared:false)
        let impossible=try NativeReportScheduleSettings(expression:"0 9 31 APR *",recipients:["x@example.invalid"],format:"pdf",timeZone:"Asia/Tokyo")
        try rejects("impossible date"){_ = try store.create(configID:own.id,settings:impossible,now:now)}
        let userConfig=try NativeReportConfigurations(service:admin).save(name:"利用者",category:.users,filters:filters,shared:true)
        try rejects("directory gate"){_ = try store.create(configID:userConfig.id,settings:settings,now:now)}
        for _ in 0..<105 {_ = try store.create(configID:own.id,settings:settings,now:now)}
        let a=try store.list(),b=try store.list(offset:100)
        try check(a.rows.count==100 && b.rows.count>=5 && Set(a.rows.map{$0["id"].string}).isDisjoint(with:b.rows.map{$0["id"].string}),"bounded distinct pages")
        try check(a.rows.allSatisfy{$0.values["recipients"]==nil},"list excludes recipient JSON")
        let huge=try db.insert("crm_Report_Schedule",values:["reportConfigId":.text(own.id),"cronExpression":.text("0 9 * * *"),"format":.text("csv"),"recipients":.text("[\""+String(repeating:"x",count:200_000)+"\"]"),"createdBy":.text(bob.identity.id)],actor:actor)
        try rejects("huge imported schedule"){_ = try store.load(huge["id"].string)}
        try store.delete(huge);try check(try db.get("crm_Report_Schedule",key:["id":huge["id"]])==nil,"oversize invalid schedule remains removable")
        let user=try db.get("Users",key:["id":.text(bob.identity.id)])!,banned=try db.update(user,changes:["banned":.integer(1)],actor:actor)
        try rejects("revoked current user"){_ = try store.list()};try db.update(banned,changes:["banned":.integer(0)],actor:actor)
        return checks
    }
}
