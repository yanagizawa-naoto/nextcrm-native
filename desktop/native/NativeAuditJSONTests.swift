import Foundation

@main enum AuditEquivalenceTests {
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ name:String)throws{guard try value() else{throw NativeDBError.message("Audit JSON: "+name)};checks += 1}
    static func main()throws {
        let n=URL(fileURLWithPath:CommandLine.arguments[1]),out=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        let root=URL(fileURLWithPath:CommandLine.arguments[4]);defer{try? FileManager.default.removeItem(at:root)}
        let db=try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:n.appendingPathComponent("schema.json"),sqlURL:n.appendingPathComponent("schema.sql"))
        var snapshots:[[String:Any]]=[]
        func snapshot(_ name:String,model:String="Email",values:[String:SQLValue],before:[String:SQLValue]?=nil)throws {
            let row=NativeRecord(model:model,values:values,revision:1),old=before.map{NativeRecord(model:model,values:$0,revision:0)}
            try db.transaction{try db.auditProbeWrite(before:old,after:row)}
            let expected=try db.auditProbeOriginal(before:old,after:row)
            let result=try db.auditProbeLast()
            for field in ["record_key","before_json","after_json"]{try check(result[field]==expected[field],"original bytes/values/order "+name+" "+field)}
            snapshots.append(["case":name,"model":model,"recordKey":result["record_key"]!.json,"before":result["before_json"]!.json,"after":result["after_json"]!.json])
            try check(result["action"] == .text("probe") && result["actor"] == .text("synthetic"),"actor/action retained")
        }
        for model in db.schema.models {
            var values:[String:SQLValue]=[:]
            for field in model.fields {
                if field.array{values[field.name] = .text("[\"日本語\",\"/\"]")}
                else{switch field.type {case "Int","BigInt","Boolean":values[field.name] = .integer(42);case "Float":values[field.name] = .real(0.12345678901234567);case "Bytes":values[field.name] = .blob(Data([0,255,254,253]));default:values[field.name] = .text("値/😀\n"+field.name)}}
            }
            try snapshot("schema-"+model.name,model:model.name,values:values,before:values)
        }
        let controls=String(String.UnicodeScalarView((0...31).map{UnicodeScalar($0)!})),unicode="日本語😀é e\u{301} / \\\"   <>& \u{7f}"
        var variants:[SQLValue]=[.null,.integer(Int64.min),.integer(Int64.max),.integer(0),.integer(1),.real(-0.0),.real(0.12345678901234567),.real(Double.leastNonzeroMagnitude),.real(Double.greatestFiniteMagnitude),.real(1.000000000000001),.real(9007199254740992),.real(1e-7),.real(-1e21),.text(""),.text(controls),.text(unicode),.text(String(repeating:unicode,count:1000)),.text("{\"value\":1}"),.blob(Data()),.blob(Data((0...255).map(UInt8.init)))]
        for i in 0..<80{variants.append(.real(Double(bitPattern:0x3ff0000000000000+UInt64(i*37))))}
        for (i,value) in variants.enumerated(){try snapshot("value-\(i)",values:["id":.text("id/\(i)"),"value":value,"password":.text("hidden"),"token":.text("hidden"),"null":.null])}
        let keys=["a","A","a2","a10","Z","_","bodyHtml","bodyText","iCalUID","id","日本語","😀","e\u{301}","é","a/","a\n"]
        var keyValues=Dictionary(keys.enumerated().map{($0.element,SQLValue.integer(Int64($0.offset)))},uniquingKeysWith:{a,_ in a});keyValues["id"] = .text("history/slash")
        try snapshot("key-order",values:keyValues)
        try check(try db.history(.init(model:"Email",values:["id":.text("history/slash")],revision:0)).count==1,"canonical record-key lookup")
        for value in (mode=="after" ? [Double.nan,Double.infinity,-Double.infinity]:[]) {
            let before=try db.auditCount("Email");var failed=false
            do{try db.transaction{try db.auditProbeWrite(before:nil,after:.init(model:"Email",values:["id":.text("invalid"),"value":.real(value)],revision:0))}}catch{failed=true}
            try check(failed && (try db.auditCount("Email"))==before,"nonfinite rejects and rolls back")
        }
        var beforeHooks=0,afterHooks=0,commits=0,rollbacks=0
        db.beforeRecordWrite={_,_,_,changes,_ in beforeHooks += 1;return changes};db.afterRecordWrite={_,_,_,_,_,_ in afterHooks += 1}
        let row=try db.insert("crm_Accounts",values:["name":.text("変更前"),"v":.integer(0)],actor:"synthetic"),count=try db.auditCount("crm_Accounts")
        do{try db.transaction{_ = try db.update(row,changes:["name":.text("取消")],actor:"synthetic");db.deferUntilTransactionEnds(onCommit:{commits += 1},onRollback:{rollbacks += 1});throw NativeDBError.conflict}}catch{}
        try check(try db.auditCount("crm_Accounts")==count && db.get("crm_Accounts",key:["id":row["id"]])?["name"] == row["name"],"outer rollback retains row and audit")
        try db.transaction{_ = try db.update(row,changes:["name":.text("変更後/")],actor:"synthetic");db.deferUntilTransactionEnds(onCommit:{commits += 1},onRollback:{rollbacks += 1})}
        try check(commits==1 && rollbacks==1 && beforeHooks==3 && afterHooks==3,"hooks and transaction callbacks unchanged")
        let current=try db.get("crm_Accounts",key:["id":row["id"]])!,history=try db.history(current)
        let latest=try JSONSerialization.jsonObject(with:Data(history[0]["after_json"]!.string.utf8)) as! [String:Any],previous=try JSONSerialization.jsonObject(with:Data(history[0]["before_json"]!.string.utf8)) as! [String:Any]
        try check(latest["name"] as? String=="変更後/" && previous["name"] as? String=="変更前","newest audit order before/after")
        try db.auditProbeSQL("CREATE TRIGGER reject_audit BEFORE INSERT ON native_audit BEGIN SELECT RAISE(ABORT,'injected'); END")
        var rejected=false;do{_ = try db.update(current,changes:["name":.text("失敗")],actor:"synthetic")}catch{rejected=true}
        try check(try rejected && db.get("crm_Accounts",key:["id":row["id"]])?.values==current.values && db.auditCount("crm_Accounts")==count+1,"audit insert failure rolls row back")
        try JSONSerialization.data(withJSONObject:["checks":checks,"schemaModels":db.schema.models.count,"snapshots":snapshots],options:[.sortedKeys]).write(to:out.appendingPathComponent(mode+"-audit.json"));print("audit \(checks) checks / \(snapshots.count) snapshots")
    }
}
