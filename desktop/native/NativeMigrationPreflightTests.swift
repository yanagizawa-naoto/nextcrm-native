import Foundation
import Darwin

@main struct NativeMigrationPreflightTests {
    struct Case:Decodable {let name:String;let bundle:String;let probe:String?;let lineLimit:Int?;let diagnosticLimit:Int?;let cancelAfter:Int?}
    struct Outcome:Encodable {let name:String;let result:NativeMigrationResult}
    static func main() throws {
        guard CommandLine.arguments.count==4 else {fatalError("schema scenarios output")}
        let schemaURL=URL(fileURLWithPath:CommandLine.arguments[1]),cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        var outcomes:[Outcome]=[]
        var unitChecks=0
        func check(_ condition:Bool) {precondition(condition);unitChecks+=1}
        let blob=NativeMigrationSchema.Field(name:"blob",column:"blob",type:"Bytes",optional:false,array:false,attributes:"")
        check(try NativeMigrationCodec.cell(.object(["base64":.string("AP8=")]),field:blob,enums:[:])==Data([98,0,255]))
        check(NativeMigrationCodec.date("1900-02-29T00:00:00Z",dateOnly:false)==false)
        check(NativeMigrationCodec.date("2000-02-29T00:00:00Z",dateOnly:false))
        check(NativeMigrationCodec.date("9999-12-31",dateOnly:true))
        let mutationRoot=FileManager.default.temporaryDirectory.appendingPathComponent("NativeMigrationMutation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:mutationRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:mutationRoot)}
        let mutationFile=mutationRoot.appendingPathComponent("asset.bin")
        try Data(repeating:65,count:200000).write(to:mutationFile)
        guard let resolved=realpath(mutationRoot.path,nil) else {fatalError("fixture realpath")};defer{free(resolved)}
        let reader=try NativeMigrationFiles(root:URL(fileURLWithPath:String(cString:resolved)))
        var changed=false
        do {
            try reader.read("asset.bin",cancelled:{false}) { _ in
                if !changed {changed=true;try Data(repeating:66,count:200000).write(to:mutationFile,options:.atomic)}
            }
            preconditionFailure("replacement undetected")
        } catch let error as NativeMigrationFailure {check(error.code=="file.changed")}
        do {_ = try reader.data("asset.bin",maximum:1024,cancelled:{false});preconditionFailure("size limit ignored")}
        catch let error as NativeMigrationFailure {check(error.code=="limit.file")}
        do {try reader.read("asset.bin",cancelled:{true}){_ in};preconditionFailure("cancel ignored")}
        catch is CancellationError {check(true)}

        let temporary=FileManager.default.temporaryDirectory
        let before=Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter{$0.hasPrefix("NativeMigrationPreflight-")})
        for test in cases {
            var calls=0;var options=NativeMigrationOptions()
            if let limit=test.lineLimit {options.maximumLineBytes=limit};if let limit=test.diagnosticLimit {options.maximumDiagnostics=limit}
            let scanner=NativeMigrationPreflight(options:options,secretAvailability:{_ in test.probe=="present" ? .present:test.probe=="missing" ? .missing:.unknown},cancelled:{calls+=1;return test.cancelAfter.map{calls>$0} ?? false})
            let result=scanner.inspect(bundleURL:URL(fileURLWithPath:test.bundle),schemaURL:schemaURL)
            guard !result.migrationPerformed else {fatalError("preflight must not mutate")}
            outcomes.append(.init(name:test.name,result:result))
        }
        let after=Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter{$0.hasPrefix("NativeMigrationPreflight-")})
        guard before==after else {fatalError("scratch index leaked")}
        try JSONEncoder().encode(outcomes).write(to:URL(fileURLWithPath:CommandLine.arguments[3]),options:.atomic)
        print("NativeMigrationPreflightTests: \(outcomes.count) scenarios, \(unitChecks) unit checks, scratch cleanup passed")
    }
}
