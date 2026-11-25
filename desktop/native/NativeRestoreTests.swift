import Foundation
import Darwin

@main struct NativeRestoreTests {
    struct Case:Decodable {let name:String,backup:String,destination:String;let failAt:String?;let cancelAt:String?;let occurrence:Int?;let mutateManifest:Bool?;let remoteSchema:Bool?}
    struct Outcome:Encodable {let name:String;let result:NativeRestoreResult;let opened:Bool;let modelsRead:Int}
    static func main()throws {
        guard CommandLine.arguments.count==5 else{fatalError("mode schema sql spec")}
        let schema=URL(fileURLWithPath:CommandLine.arguments[2]),sql=URL(fileURLWithPath:CommandLine.arguments[3]),argument=URL(fileURLWithPath:CommandLine.arguments[4])
        if CommandLine.arguments[1]=="initialize"{let db=try NativeDatabase(url:argument,schemaURL:schema,sqlURL:sql);_ = try db.integrityCheck();return}
        if CommandLine.arguments[1]=="backup" {
            let values=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:argument))
            let db=try NativeDatabase(url:URL(fileURLWithPath:values["source"]!),schemaURL:schema,sqlURL:sql)
            let result=NativeBackup().prepare(source:db,destinationURL:URL(fileURLWithPath:values["destination"]!))
            guard result.candidateCreated else{fatalError("isolated source backup failed: \(result.diagnostics.map(\.code))")};return
        }
        let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:argument)),catalog=try JSONDecoder().decode(NativeMigrationSchema.self,from:Data(contentsOf:schema));var outcomes:[Outcome]=[]
        for item in cases {
            try autoreleasepool {
                var stopped=false,visits:[String:Int]=[:]
                let restore=NativeRestore(cancelled:{stopped},checkpoint:{point in
                    visits[point,default:0]+=1
                    if point=="beforePlan",item.mutateManifest==true {let path=URL(fileURLWithPath:item.backup).appendingPathComponent("snapshot.json");var data=try Data(contentsOf:path);data.append(32);try data.write(to:path)}
                    if item.failAt==point,visits[point]==(item.occurrence ?? 1){throw NativeMigrationFailure("test.failure","隔離fixtureの模擬失敗です。")}
                    if item.cancelAt==point,visits[point]==(item.occurrence ?? 1){stopped=true}
                })
                let result=restore.prepare(backupURL:URL(fileURLWithPath:item.backup),schemaURL:item.remoteSchema==true ? URL(string:"https://invalid.example/never-requested")!:schema,sqlURL:sql,destinationURL:URL(fileURLWithPath:item.destination))
                var opened=false,models=0
                if result.candidateCreated {
                    let db=try NativeDatabase(url:URL(fileURLWithPath:item.destination).appendingPathComponent("crm.sqlite"),schemaURL:schema,sqlURL:sql)
                    guard try db.integrityCheck() else{fatalError("real NativeDatabase integrity failed")}
                    for model in catalog.models {_ = try db.page(model.name,fields:model.primaryKey,includeDeleted:true,limit:1);models+=1}
                    opened=true
                }
                guard !result.activated,!result.workersStarted,!result.keychainAccessed,result.activationGate.phase=="requiresActivationReview",result.activationGate.obligations.count==8 else{fatalError("staging activated runtime")}
                outcomes.append(.init(name:item.name,result:result,opened:opened,modelsRead:models))
            }
        }
        try JSONEncoder().encode(outcomes).write(to:argument.deletingLastPathComponent().appendingPathComponent("results.json"),options:.atomic)
        print("NativeRestoreTests: \(outcomes.count) scenarios")
    }
}
