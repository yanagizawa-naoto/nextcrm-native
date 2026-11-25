import Foundation
import Darwin
import CryptoKit

enum FileTests {
    static func run(out:URL)async throws->Int {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MIMEFile-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:temp)}
        var checks=0
        func check(_ value:Bool)throws{guard value else{throw NativeMailFailure.invalid("File reader assertion failed")};checks += 1}
        func rejects(_ action:()throws->Void)throws{do{try action()}catch{checks += 1;return};throw NativeMailFailure.invalid("File reader expected rejection")}
        func write(_ fd:Int32,_ data:Data)throws {
            try data.withUnsafeBytes { bytes in
                var offset=0
                while offset<bytes.count{try Task.checkCancellation();let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw NativeMailResponseFile.fileError};offset += n}
            }
        }
        func file(_ data:Data)throws->NativeMailResponseFile{let f=try NativeMailResponseFile(temporaryRoot:temp);try f.withDescriptor{try write($0,data)};return f}
        func reply(_ validity:UInt32=1)->NativeMailReply{.init(body:Data(),protocolHeaders:Data("* OK [UIDVALIDITY \(validity)] selected\r\n".utf8),serverCode:200,responseBytes:0)}
        func fetch(_ body:String,uid:UInt32=1,section:String="BODY[]",after:Bool=false)->String {
            "* 1 FETCH ("+(after ? "":"UID \(uid) ")+section+" {\(body.utf8.count)}\r\n"+body+(after ? " UID \(uid)":"")+")\r\n"
        }
        let raw="Content-Type: text/plain\r\n\r\n本文"
        do {
            let f=try file(Data(fetch(raw,after:true).utf8));try check(try NativeMailClient.decodeBodyFile(reply(),file:f,validity:1,uid:1)?.text=="本文")
            try rejects{_ = try NativeMailClient.decodeBodyFile(reply(2),file:f,validity:1,uid:1)}
            try rejects{_ = try NativeMailClient.decodeBodyFile(reply(),file:f,validity:1,uid:2)}
        }
        for value in [fetch(raw)+fetch(raw),fetch(raw,section:"BODY[HEADER]"),"* 1 FETCH (UID 1 BODY[] {999}\r\nx)","* 1 FETCH (UID 1 BODY[] {999999999999999999999999999999}\r\nx)","* 1 FETCH (UID 1 BODY[] {0}\r\n"] {
            let f=try file(Data(value.utf8));try rejects{_ = try NativeMailClient.decodeBodyFile(reply(),file:f,validity:1,uid:1)}
        }
        do {
            let f=try file(Data(("* 2 FETCH (UID 999 FLAGS (\\Seen))\r\n"+fetch(raw)).utf8));try check(try NativeMailClient.decodeBodyFile(reply(),file:f,validity:1,uid:1)?.text=="本文")
        }
        do {
            let wire=fetch("Subject: second\r\n\r\n",uid:2,section:"BODY[HEADER]")+fetch("Subject: first\r\n\r\n",uid:1,section:"BODY[HEADER]",after:true)
            let f=try file(Data(wire.utf8));var ids:[UInt32]=[],names:[String]=[]
            try NativeMailIMAPFile(file:f).headers(expected:[1,2]){ids.append($0.uid);names.append($0.headers.subject)}
            try check(ids==[1,2]);try check(names==["first","second"])
        }
        let consumer=try JSONSerialization.jsonObject(with:Data(contentsOf:out.appendingPathComponent("consumer-reference.json"))) as! [String:Any]
        for row in consumer["cases"] as! [[String:Any]] {
            let f=try file(Data(fetch(row["raw"] as! String).utf8)),value=try NativeMailClient.decodeBodyFile(reply(),file:f,validity:1,uid:1,temporaryRoot:temp)
            try check(value?.text == row["text"] as? String);try check(value?.html == row["html"] as? String)
        }
        var mapped:Data?
        do {let f=try file(Data(fetch(raw).utf8));mapped=try NativeMailIMAPFile(file:f).body(expected:1)}
        try check(mapped==Data(raw.utf8));mapped=nil
        do {let f=try file(Data(fetch(raw).utf8));var value=try NativeMailIMAPFile(file:f).body(expected:1)!;value[value.startIndex]=88;try check(value.first==88);try check(try NativeMailIMAPFile(file:f).body(expected:1)==Data(raw.utf8))}

        var release:AsyncStream<Void>.Continuation!
        let gate=AsyncStream<Void>{release=$0}
        let cancelled=Task.detached {let f=try NativeMailResponseFile(temporaryRoot:temp);var iterator=gate.makeAsyncIterator();_ = await iterator.next();try Task.checkCancellation();return try NativeMailIMAPFile(file:f).body(expected:1)}
        cancelled.cancel();release.finish();var cancellation=false;do{_ = try await cancelled.value}catch is CancellationError{cancellation=true};try check(cancellation)
        let many=Data(("Content-Type: multipart/mixed; boundary=x\r\n\r\n"+String(repeating:"--x\r\nContent-Type: text/plain\r\n\r\npart\r\n",count:100000)+"--x--").utf8)
        let processing=Task.detached{try NativeMailMIME.body(many,recoverIncoming:true,temporaryRoot:temp)}
        var active=false
        for _ in 0..<1000 {
            let files=FileManager.default.enumerator(at:temp,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
            if files.contains(where:{$0.lastPathComponent=="mime.sqlite"}){active=true;break}
            try await Task.sleep(nanoseconds:1_000_000)
        }
        processing.cancel();var interrupted=false;do{_ = try await processing.value}catch is CancellationError{interrupted=true}
        try check(active);try check(interrupted)
        let remaining=FileManager.default.enumerator(at:temp,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []
        try check(!remaining.contains{UUID(uuidString:$0.lastPathComponent) != nil})
        try JSONSerialization.data(withJSONObject:["checks":checks,"cleanup":true],options:[.sortedKeys]).write(to:out.appendingPathComponent("file-result.json"))
        return checks
    }
}
