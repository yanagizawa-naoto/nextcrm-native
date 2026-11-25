import Foundation
import SQLite3

enum NativeTargetSpreadsheetControllerTests {
    final class Secrets:NativeAISecretStore {
        var reads=0
        func load(id:String,interactive:Bool)throws->Data?{reads += 1;throw NativeDBError.conflict}
        func save(id:String,data:Data)throws{throw NativeDBError.conflict}
        func remove(id:String)throws{throw NativeDBError.conflict}
    }
    static var checks=0
    static func check(_ value:Bool,_ label:String)throws{guard value else{throw NativeTargetSpreadsheetFailure(message:label)};checks += 1}
    static func main()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),native=root.deletingLastPathComponent().deletingLastPathComponent()
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("TargetSpreadsheetController-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:folder)}
        let db=try NativeDatabase(url:folder.appendingPathComponent("crm.sqlite"),schemaURL:native.appendingPathComponent("schema.json"),sqlURL:native.appendingPathComponent("schema.sql"))
        let actor=try db.insert("Users",values:["name":.text("担当者"),"email":.text("actor@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:"fixture")
        let service=CRMService(db:db,identity:.init(id:actor["id"].string,role:"user",partnerAccountID:nil)),store=Secrets()
        var keys=NativeAIKeys(service:service,store:store);keys.environment = .init(lookup:{_ in nil})
        let controller=NativeTargetSpreadsheetController(service:service,keys:keys,admission:{})
        controller.request={_ in throw NativeTargetSpreadsheetFailure(message:"unexpected network")}
        let session=try await controller.load(root.appendingPathComponent("source-fixtures/basic.csv"),operation:.init())
        try check(session.draft.rowCount==1,"real staged CSV")
        let location=session.staging.directoryURL
        let suggestion=try await controller.suggest(session,operation:.init())
        try check(!suggestion.usedAI && store.reads==0,"unconfigured fallback no Keychain/no network")
        let result=try await controller.importRows(session,mapping:suggestion.mapping,operation:.init())
        try check(result.imported==1,"actual import")
        for format in [NativeTargetSpreadsheetExport.Format.csv,.xlsx] {
            let output=folder.appendingPathComponent(format == .csv ? "export.csv":"export.xlsx")
            let value=try await controller.export(.init(),to:output,format:format,replace:false,operation:.init())
            try check(value.rows==1 && !value.cleanupPending && FileManager.default.fileExists(atPath:output.path),"published export")
            let imported=try await controller.load(output,operation:.init()),headers=try await controller.headers(imported,operation:.init())
            let mapping=NativeTargetSpreadsheetMapping.fallback(headers)
            let preview=try await controller.preview(imported,mapping:mapping,after:-1,operation:.init())
            try check(preview.count==1 && preview[0].values["last_name"]=="山田" && preview[0].values["email"]=="hana@example.invalid","Japanese export reimport")
            try await controller.close(imported)
        }
        try await controller.close(session);try check(!FileManager.default.fileExists(atPath:location.path),"joined cleanup")
        let op=NativeTargetSpreadsheetOperation();op.cancel()
        do{_ = try await controller.load(root.appendingPathComponent("source-fixtures/basic.csv"),operation:op);throw NativeDBError.conflict}catch is CancellationError{checks += 1}
        keys.environment = .init(lookup:{$0 == "OPENAI_API_KEY" ? "synthetic-only":nil})
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reference.json"))) as! [String:Any]
        let headers=(reference["mapping"] as! [[String:Any]])[0]["headers"] as! [String]
        for scenario in ["success","invalidField","invalidJSON","empty","throw"] {
            let old=(reference["mapping"] as! [[String:Any]]).first{$0["id"] as? String==scenario}!
            var ai=NativeTargetSpreadsheetAI(keys:keys,admission:{})
            ai.request={ request in
                let sent=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
                try check(sent["model"] as? String=="gpt-4o-mini" && (sent["temperature"] as? Int)==0,"AI source model/temperature")
                let messages=sent["messages"] as! [[String:String]]
                let expected=(old["calls"] as! [[String:Any]])[0]["messages"] as! [[String:String]]
                try check(messages==expected,"exact original headers-only prompt")
                if scenario=="throw"{throw NativeDBError.conflict}
                let body:String
                if scenario=="empty"{body=""}else if scenario=="invalidJSON"{body="not-json"}else{
                    body=String(decoding:try JSONSerialization.data(withJSONObject:Dictionary(uniqueKeysWithValues:headers.map{($0,scenario=="invalidField" ? "not_field":"company")})),as:UTF8.self)
                }
                let bytes=try JSONSerialization.data(withJSONObject:["choices":[["message":["content":body]]]])
                return (bytes,HTTPURLResponse(url:NativeTargetSpreadsheetAI.endpoint,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }
            let value=try await ai.suggest(headers)
            if ["success","invalidField"].contains(scenario) {
                let expected=(old["result"] as! [String:Any])["mapping"] as! [String:Any]
                for column in value.mapping.columns {try check(column.field == expected[column.header] as? String,"source AI mapping")}
            }else{try check(!value.usedAI && value.mapping.columns.first?.field=="last_name","provider fallback")}
        }
        var changingKey="synthetic-before"
        var changing=keys;changing.environment = .init(lookup:{$0=="OPENAI_API_KEY" ? changingKey:nil})
        var rekey=NativeTargetSpreadsheetAI(keys:changing,admission:{})
        rekey.request={_ in changingKey="synthetic-after";throw NativeDBError.conflict}
        do{_ = try await rekey.suggest(headers);throw NativeTargetSpreadsheetFailure(message:"changed key fell back")}catch is NativeDBError{checks += 1}
        let big=folder.appendingPathComponent("large.csv")
        try ("last_name,company\n"+String(repeating:"山田,株式会社サンプル\n",count:10000)).write(to:big,atomically:true,encoding:.utf8)
        let original=try Data(contentsOf:big),largeOp=NativeTargetSpreadsheetOperation()
        let load=Task{try await controller.load(big,operation:largeOp)}
        try await Task.sleep(nanoseconds:10_000_000);load.cancel()
        do{let value=try await load.value;try await controller.close(value);throw NativeTargetSpreadsheetFailure(message:"large parse finished before cancellation fixture")}catch is CancellationError{checks += 1}
        try check(try Data(contentsOf:big)==original,"cancel source unchanged")
        let protected=folder.appendingPathComponent("protected.csv");try Data("existing".utf8).write(to:protected)
        do{_ = try await controller.export(.init(),to:protected,format:.csv,replace:false,operation:.init());throw NativeTargetSpreadsheetFailure(message:"existing destination overwritten")}catch{try check(try Data(contentsOf:protected)==Data("existing".utf8),"failed publication preserves existing bytes")}
        let seal=NativeTargetSpreadsheetOperation();try seal.seal();seal.cancel();try check(!seal.cancelled,"late cancel does not change committed outcome")
        try check(try NativeTargetSpreadsheetMapping.fromAI("[\"email\"]",headers:["0"]).columns.first?.field=="email","source array-property mapping")
        do{_ = try NativeTargetSpreadsheetMapping.fromAI("null",headers:["x"]);throw NativeDBError.conflict}catch is NativeTargetSpreadsheetFailure{checks += 1}
        let unicode=try NativeTargetSpreadsheetMapping.fromAI("{\"é\":\"last_name\",\"é\":\"company\"}",headers:["é","é"])
        try check(unicode.columns.map(\.field)==["last_name","company"],"exact UTF16 header keys")
        // Same sealed read-only opener used by the actual restored workspace.
        let sealed=folder.appendingPathComponent("sealed.sqlite");var src:OpaquePointer?,dst:OpaquePointer?
        guard sqlite3_open_v2(db.url.path,&src,SQLITE_OPEN_READONLY,nil)==SQLITE_OK,sqlite3_open(sealed.path,&dst)==SQLITE_OK,let copy=sqlite3_backup_init(dst,"main",src,"main") else{throw NativeDBError.conflict}
        let copied=sqlite3_backup_step(copy,-1);sqlite3_backup_finish(copy);sqlite3_close(src);sqlite3_close(dst);try check(copied==SQLITE_DONE,"sealed actual SQLite snapshot")
        let readOnly=try NativeDatabase(readOnlyURL:sealed,schemaURL:native.appendingPathComponent("schema.json")),sealedBytes=try Data(contentsOf:sealed)
        let heldService=CRMService(db:readOnly,identity:service.identity),heldKeys=NativeAIKeys(service:CRMService(db:readOnly,identity:service.identity),store:store,environment:.init(lookup:{_ in nil}))
        let held=NativeTargetSpreadsheetController(service:heldService,keys:heldKeys,admission:{})
        do{_ = try await held.load(big,operation:.init());throw NativeDBError.conflict}catch is NativeTargetSpreadsheetFailure{checks += 1}
        do{_ = try await held.export(.init(),to:folder.appendingPathComponent("held.csv"),format:.csv,replace:false,operation:.init());throw NativeDBError.conflict}catch is NativeTargetSpreadsheetFailure{checks += 1}
        try check(try Data(contentsOf:sealed)==sealedBytes && !FileManager.default.fileExists(atPath:folder.appendingPathComponent("held.csv").path),"held refusal before filesystem/credential effects")
        var bad=NativeTargetSpreadsheetAI(keys:keys,admission:{})
        bad.request={_ in let old=try db.get("Users",key:["id":actor["id"]])!;_ = try db.update(old,changes:["banned":.integer(1)],actor:"fixture");throw NativeDBError.conflict}
        do{_ = try await bad.suggest(headers);throw NativeTargetSpreadsheetFailure(message:"fresh auth failed open")}catch is NativeDBError{checks += 1}
        try check(store.reads==0,"synthetic environment only")
        try JSONSerialization.data(withJSONObject:["checks":checks],options:.prettyPrinted).write(to:root.appendingPathComponent("controller-actual.json"))
        print("Controller \(checks) checks")
    }
}
