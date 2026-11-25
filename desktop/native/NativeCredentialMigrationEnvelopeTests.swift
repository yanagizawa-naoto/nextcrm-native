import Foundation
import CryptoKit
import Darwin

@main enum NativeCredentialMigrationEnvelopeTests {
    static var checks=0
    static func check(_ b:@autoclosure()throws->Bool,_ label:String)throws{guard try b() else{throw NativeCredentialMigrationFailure.conflict};checks+=1}
    static func reject(_ body:()throws->Void)throws{do{try body()}catch{checks+=1;return};throw NativeCredentialMigrationFailure.conflict}
    static func hex(_ text:String)->Data {Data(stride(from:0,to:text.count,by:2).map{i in let a=text.index(text.startIndex,offsetBy:i),b=text.index(a,offsetBy:2);return UInt8(text[a..<b],radix:16)!})}
    static func fdCount()->Int{(0..<512).filter{fcntl(Int32($0),F_GETFD)>=0}.count}
    static func main()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),fixtures=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("handoff-fixture.json"))) as! [String:Any]
        let source=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reference.json"))) as! [String:Any],key=hex(source["handoffKeyHex"] as! String),serverKey=hex(source["serverKeyHex"] as! String)
        let descriptor=try JSONDecoder().decode(NativeCredentialMigrationDescriptor.self,from:JSONSerialization.data(withJSONObject:fixtures["descriptor"]!)),schema=fixtures["schemaSHA256"] as! String,snapshot=fixtures["snapshotID"] as! String
        let directory=root.appendingPathComponent("handoff"),original=try Data(contentsOf:directory.appendingPathComponent("credentials.handoff")),items=fixtures["items"] as! [[String:Any]]
        let startFD=fdCount()
        do {
            let reader=try NativeCredentialMigrationEnvelope(root:directory,descriptor:descriptor,key:key,schemaSHA256:schema,snapshotID:snapshot)
            var count=0
            try reader.forEach {entry,bytes in
                let expected=items[count],owner=try JSONDecoder().decode(NativeCredentialMigrationOwner.self,from:JSONSerialization.data(withJSONObject:expected["owner"]!))
                try check(entry.owner==owner,"owner exact");try check(entry.index==count,"ordered index");try check(bytes==Data(base64Encoded:expected["originalBytes"] as! String),"original bytes exact");count+=1
            }
            try check(count==12,"all entries");try check(reader.maximumFrameBytes<65_536,"small fixture is one bounded frame");try check(reader.header.snapshotID==snapshot,"source snapshot bound")
        }
        try check(fdCount()==startFD,"reader releases descriptor")
        try reject{_ = try NativeCredentialMigrationEnvelope(root:directory,descriptor:descriptor,key:Data(repeating:0,count:32),schemaSHA256:schema,snapshotID:snapshot)}
        try reject{_ = try NativeCredentialMigrationEnvelope(root:directory,descriptor:descriptor,key:key,schemaSHA256:schema,snapshotID:"other")}
        try reject{_ = try NativeCredentialMigrationEnvelope(root:directory,descriptor:descriptor,key:key,schemaSHA256:String(repeating:"0",count:64),snapshotID:snapshot)}
        try check(fdCount()==startFD,"failed initialization releases descriptor")
        for mode in ["tamper","truncated","append","length"] {
            let folder=root.appendingPathComponent("swift-"+mode);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var data=original
            if mode=="tamper" {data[data.count-20]^=1}
            if mode=="truncated" {data.removeLast(80)}
            if mode=="append" {data.append(0)}
            if mode=="length" {data.replaceSubrange(8..<12,with:Data(repeating:255,count:4))}
            let file=folder.appendingPathComponent("credentials.handoff");try data.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            let changed=NativeCredentialMigrationDescriptor(version:1,handoffID:descriptor.handoffID,path:descriptor.path,entries:descriptor.entries,bytes:Int64(data.count),sha256:NativeCredentialMigrationEnvelope.hash(data))
            try reject{_ = try NativeCredentialMigrationEnvelope(root:folder,descriptor:changed,key:key,schemaSHA256:schema,snapshotID:snapshot)}
            try check(fdCount()==startFD,"malformed stream releases descriptor")
        }
        let symlink=root.appendingPathComponent("swift-link");try FileManager.default.createDirectory(at:symlink,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try FileManager.default.createSymbolicLink(at:symlink.appendingPathComponent("credentials.handoff"),withDestinationURL:directory.appendingPathComponent("credentials.handoff"))
        try reject{_ = try NativeCredentialMigrationEnvelope(root:symlink,descriptor:descriptor,key:key,schemaSHA256:schema,snapshotID:snapshot)}
        let hard=root.appendingPathComponent("swift-hard");try FileManager.default.createDirectory(at:hard,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);guard link(directory.appendingPathComponent("credentials.handoff").path,hard.appendingPathComponent("credentials.handoff").path)==0 else{throw NativeCredentialMigrationFailure.unavailable}
        try reject{_ = try NativeCredentialMigrationEnvelope(root:hard,descriptor:descriptor,key:key,schemaSHA256:schema,snapshotID:snapshot)};try FileManager.default.removeItem(at:hard.appendingPathComponent("credentials.handoff"))
        for example in source["cases"] as! [[String:Any]] {
            if example["family"] as? String=="email-crypto" {let raw=try NativeCredentialMigrationEnvelope.decryptServer(example["ciphertext"] as! String,key:serverKey);try check(String(data:raw,encoding:.utf8)==example["decoded"] as? String,"actual original AES layout")}
            if example["family"] as? String=="invalid" {try reject{_ = try NativeCredentialMigrationEnvelope.decryptServer(example["ciphertext"] as! String,key:serverKey)}}
        }
        try check(try Data(contentsOf:directory.appendingPathComponent("credentials.handoff"))==original,"archive unchanged")
        for stress in fixtures["stress"] as! [[String:Any]] {
            let d=try JSONDecoder().decode(NativeCredentialMigrationDescriptor.self,from:JSONSerialization.data(withJSONObject:stress["descriptor"]!))
            let r=try NativeCredentialMigrationEnvelope(root:root.appendingPathComponent(stress["label"] as! String),descriptor:d,key:key,schemaSHA256:schema,snapshotID:stress["snapshotID"] as! String);var count=0,last=""
            try r.forEach{e,data in count+=1;last=e.valueSHA256;try check(data.count<=NativeCredentialMigrationEnvelope.maximumValueBytes,"each plaintext frame bounded")}
            try check(count==d.entries&&last==stress["lastHash"] as? String,"stress values exact, no truncation")
            try check(r.maximumFrameBytes<=2*NativeCredentialMigrationEnvelope.maximumValueBytes+65_536,"bounded explicit frame storage, not process peak")
        }
        try check(fdCount()==startFD,"all resources closed")
        print("{\"checks\":\(checks),\"entries\":12,\"sourceCases\":\((source["cases"] as! [Any]).count),\"largeBytes\":8388608,\"manyEntries\":1000}")
    }
}
