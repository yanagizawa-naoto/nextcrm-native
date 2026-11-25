import Foundation
import SQLite3

enum NativeTargetSpreadsheetServiceTests {
    static var checks = 0
    static func check(_ value: Bool,_ label: String) throws { guard value else { throw NativeTargetSpreadsheetFailure(message:label) }; checks += 1 }
    static func id(_ n:Int)->String { "10000000-0000-4000-8000-" + String(format:"%012d",n) }
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),native = root.deletingLastPathComponent().deletingLastPathComponent()
        let input = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reference.json"))) as! [String:Any]
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TargetSpreadsheetService-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
        var output:[[String:Any]]=[]
        for item in input["imports"] as! [[String:Any]] {
            let db=try NativeDatabase(url:folder.appendingPathComponent((item["id"] as! String)+".sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
            for n in [1,2] {_ = try db.insert("Users",values:["id":.text(id(n)),"email":.text("user\(n)@example.invalid"),"name":.text("担当者"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"fixture")}
            let service=CRMService(db:db,identity:.init(id:id(1),role:"user",partnerAccountID:nil))
            for seed in item["seeds"] as! [[String:Any]] {
                var values:[String:SQLValue]=[:]
                for key in ["id","last_name","email","created_by","deletedAt"] {if let value=seed[key] as? String {values[key] = .text(value)}}
                values["do_not_email"] = .integer(1);_ = try db.insert("crm_Targets",values:values,actor:"fixture")
            }
            let draft=try NativeTargetSpreadsheetDraft()
            for row in item["rows"] as! [[String:String]] {try draft.append(.init(entries:row.map{.init($0.key,$0.value)}))}
            let map=NativeTargetSpreadsheetMapping(columns:(item["mapping"] as! [String:String]).map{.init(header:$0.key,field:$0.value)})
            let api=NativeTargetSpreadsheetService(service:service,admission:{},clock:{Date(timeIntervalSince1970:1795176000)})
            let audit=try db.auditCount("crm_Targets"),result=try api.importRows(draft,mapping:map)
            try check(try db.auditCount("crm_Targets") == audit+Int(result.imported),"native audit")
            let records=try db.keysetPage("crm_Targets",fields:NativeTargetSpreadsheetFields.keys+["created_by","do_not_email","do_not_email_at"],filter:.equal("created_by",.text(id(1))))
            let values:[[String:Any]]=records.map { record in
                var value:[String:Any]=[:]
                for key in NativeTargetSpreadsheetFields.keys+["created_by","do_not_email_at"] {value[key]=record[key] == .null ? NSNull():record[key].string as Any}
                value["do_not_email"]=record["do_not_email"] == .integer(1);return value
            }
            output.append(["id":item["id"]!,"imported":result.imported,"skipped":result.skipped,"suppressed":result.suppressed,"rows":values])
            let export=try NativeTargetSpreadsheetDraft();let count=try api.exportSnapshot(.init(),into:export)
            try check(count==result.imported,"export own filtered all")
            let selected=try NativeTargetSpreadsheetDraft()
            if let one=records.first {try check(try api.exportSnapshot(.init(selectedIDs:[one["id"].string],filter:.none,search:"not-present"),into:selected)==1,"selected export")}
            let hidden=try NativeTargetSpreadsheetDraft()
            do{_ = try api.exportSnapshot(.init(selectedIDs:["20000000-0000-4000-8000-000000000001"]),into:hidden);throw NativeTargetSpreadsheetFailure(message:"hidden export accepted")}catch is NativeDBError{checks += 1}
            let cancelled=try NativeTargetSpreadsheetDraft()
            for i in 0..<201 {try cancelled.append(.init(entries:[.init("last_name","取消\(i)")]))}
            var seen=0
            do {_ = try api.importRows(cancelled,mapping:.init(columns:[]),checkpoint:{if seen>=101{throw CancellationError()}},progress:{seen=Int($0)});throw NativeTargetSpreadsheetFailure(message:"cancel accepted")}catch is CancellationError{checks += 1}
            try check(try db.page("crm_Targets",fields:[],filter:.equal("created_by",.text(id(1)))).total == Int(result.imported),"cancel rolls back all pages")
            try check(try db.auditCount("crm_Targets") == audit+Int(result.imported),"cancel rolls back audit")
            if let one=records.first {
                let snapshot=[one["id"].string,"20000000-0000-4000-8000-000000000001",id(999)]
                let live=try NativeTargetSpreadsheetSelection.liveIDs(snapshot,service:service,checkpoint:{})
                try check(live==[one["id"].string],"selected-only bounded live scope")
                var chosen=NativeTargetSpreadsheetSelection();for id in snapshot{chosen.select(id)}
                chosen.prune(snapshot:snapshot,live:live);try check(chosen.ids==live,"missing and hidden selected IDs removed")
                _ = try db.setDeleted(one,deleted:true,actor:id(1))
                try check(try NativeTargetSpreadsheetSelection.liveIDs(live,service:service,checkpoint:{}).isEmpty,"deleted selection removed")
            }
            let user=try db.get("Users",key:["id":.text(id(1))])!
            _ = try db.update(user,changes:["banned":.integer(1)],actor:"fixture")
            do {_ = try api.importRows(cancelled,mapping:.init(columns:[]));throw NativeTargetSpreadsheetFailure(message:"banned accepted")}catch let error as NativeDBError{_ = error;checks += 1}
        }
        var selection=NativeTargetSpreadsheetSelection()
        for item in input["selection"] as! [[String:Any]] {
            let visible=item["visible"] as! [String],indexes=IndexSet(item["indexes"] as! [Int])
            selection.updatePage(ids:visible,indexes:indexes)
            try check(Set(selection.ids)==Set(item["selected"] as! [String]),"actual TanStack selection "+(item["name"] as! String))
            try check(selection.indexes(in:visible)==indexes,"restore page checkboxes")
        }
        selection.clear();try check(selection.count==0,"model departure clears selection")
        let orderedDB=try NativeDatabase(url:folder.appendingPathComponent("ordered.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        for n in [1,2] {_ = try orderedDB.insert("Users",values:["id":.text(id(n)),"email":.text("order\(n)@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"fixture")}
        let orderedService=CRMService(db:orderedDB,identity:.init(id:id(1),role:"user",partnerAccountID:nil)),orderedAPI=NativeTargetSpreadsheetService(service:orderedService,admission:{})
        for i in 0..<205 {
            let date:SQLValue=i==0 ? .null:.text(i==1 || i==2 ? "2026-01-01T00:00:01Z":i==5 ? "2026-01-01T00:00:00.123456780Z":i==6 ? "2026-01-01T00:00:00.123456789Z":"2026-01-01T00:00:00."+String(format:"%03d",i)+"Z")
            _ = try orderedDB.insert("crm_Targets",values:["id":.text(id(1000+i)),"last_name":.text("target\(i)"),"company":.text(i%2==0 ? "東京 100% _ A\\B":"大阪"),"created_on":date,"created_by":.text(id(1))],actor:"fixture")
        }
        _ = try orderedDB.insert("crm_Targets",values:["id":.text(id(9999)),"last_name":.text("hidden"),"created_by":.text(id(2))],actor:"fixture")
        func surnames(_ draft:NativeTargetSpreadsheetDraft)throws->[String] {var values:[String]=[],after:Int64 = -1;while after<draft.rowCount-1{try draft.rows(after:after){index,row in values.append(row.value("last_name")!.text!);after=index}};return values}
        for term in ["","東京","100%","_","A\\B","no-match"] {
            var expected:[String]=[],offset=0
            while true {let page=try orderedDB.page("crm_Targets",fields:[],search:term,offset:offset,filter:orderedService.scope("crm_Targets"),sort:"id");expected += page.rows.map{$0["id"].string};if page.rows.count<100{break};offset += page.rows.count}
            var actual:[String]=[],after:String?
            while true {let page=try orderedDB.keysetPage("crm_Targets",fields:[],after:after,filter:orderedService.scope("crm_Targets"),search:term);actual += page.map{$0["id"].string};if page.count<100{break};after=page.last!["id"].string}
            try check(expected==actual,"keyset identical literal-search/scope "+term)
            let output=try NativeTargetSpreadsheetDraft();try check(try orderedAPI.exportSnapshot(.init(search:term),into:output)==Int64(expected.count),"filtered-all beyond page "+term)
        }
        let selectedOrder=try NativeTargetSpreadsheetDraft()
        _ = try orderedAPI.exportSnapshot(.init(selectedIDs:[id(1003),id(1002),id(1000),id(1001),id(1005),id(1006)],filter:.none,search:"no-match"),into:selectedOrder)
        try check(try surnames(selectedOrder)==["target0","target1","target2","target6","target5","target3"],"null-first descending, fractional precision, deterministic tie, selection order ignored")
        let entire=try NativeTargetSpreadsheetDraft();_ = try orderedAPI.exportSnapshot(.init(),into:entire)
        let allNames=try surnames(entire)
        try check(allNames.count==205 && Array(allNames.prefix(3))==["target0","target1","target2"],"all export same null/date/tie order")
        try check(allNames.firstIndex(of:"target6")!<allNames.firstIndex(of:"target5")!,"all export submillisecond order")
        for item in input["dates"] as! [[String:Any]] {let instant=try NativeTargetSpreadsheetService.sortInstant(item["input"] as! String);try check(instant.seconds*1000+instant.fraction/1000000==(item["milliseconds"] as! NSNumber).int64Value,"JS Date epoch "+(item["input"] as! String))}
        let sealed=folder.appendingPathComponent("readonly.sqlite");var src:OpaquePointer?,dst:OpaquePointer?
        guard sqlite3_open_v2(orderedDB.url.path,&src,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&dst)==SQLITE_OK,let copy=sqlite3_backup_init(dst,"main",src,"main") else{throw NativeDBError.conflict}
        let copied=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(src);sqlite3_close(dst);try check(copied==SQLITE_DONE,"sealed SQLite snapshot")
        let readonly=try NativeDatabase(readOnlyURL:folder.appendingPathComponent("readonly.sqlite"),schemaURL:native.appendingPathComponent("schema.json"))
        try check(try readonly.keysetPage("crm_Targets",fields:[],search:"東京").count==100,"keyset readonly no mutation")
        var mappings:[[String:Any]]=[]
        for item in input["mapping"] as! [[String:Any]] where (item["id"] as! String)=="none" {
            let mapping=NativeTargetSpreadsheetMapping.fallback(item["headers"] as! [String],japanese:false)
            mappings.append(["id":item["id"]!,"mapping":Dictionary(uniqueKeysWithValues:mapping.columns.map{($0.header,$0.field.map{$0 as Any} ?? NSNull())})])
        }
        for field in NativeTargetSpreadsheetFields.all {try check(NativeTargetSpreadsheetMapping.fuzzy(field.title)==field.key,"Japanese label maps back")}
        try JSONSerialization.data(withJSONObject:["imports":output,"mapping":mappings,"checks":checks],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("service-actual.json"))
        print("Service \(checks) checks")
    }
}
