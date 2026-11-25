import Foundation

@main struct NativeMigrationImportTests {
    struct Case:Decodable {let name:String,bundle:String,destination:String;let failAt:String?;let cancelAt:String?;let mutateAt:String?}
    struct Outcome:Encodable {let name:String;let result:NativeMigrationImportResult}
    static func main()throws {
        guard CommandLine.arguments.count==5 else {fatalError("schema sql cases output")}
        let schema=URL(fileURLWithPath:CommandLine.arguments[1]),sql=URL(fileURLWithPath:CommandLine.arguments[2])
        let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
        var outcomes:[Outcome]=[]
        for item in cases {
            var cancelled=false,mutated=false
            let importer=NativeMigrationImport(cancelled:{cancelled},checkpoint:{point in
                if item.cancelAt==point {cancelled=true}
                if item.failAt==point {throw NativeMigrationFailure("test.failure","隔離テストの模擬失敗です。")}
                if item.mutateAt==point && !mutated {
                    let manifestURL=URL(fileURLWithPath:item.bundle).appendingPathComponent("manifest.json")
                    var bytes=try Data(contentsOf:manifestURL);bytes.append(32);try bytes.write(to:manifestURL,options:.atomic);mutated=true
                }
            })
            let result=importer.prepare(bundleURL:URL(fileURLWithPath:item.bundle),schemaURL:schema,sqlURL:sql,destinationURL:URL(fileURLWithPath:item.destination))
            outcomes.append(.init(name:item.name,result:result))
            guard !result.applicationRestored,!result.workersStarted,!result.keychainWritten else {fatalError("preparation crossed boundary")}
        }
        try JSONEncoder().encode(outcomes).write(to:URL(fileURLWithPath:CommandLine.arguments[4]),options:.atomic)
        print("NativeMigrationImportTests: \(outcomes.count) scenarios completed")
    }
}
