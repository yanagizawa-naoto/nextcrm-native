import Foundation
import Darwin
import CryptoKit

enum LargeTests {
    static func run(out:URL,kind:String,size:Int)throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MIMELarge-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:temp)}
        let prefix=Data("Content-Type: text/plain; charset=utf-8\r\n\r\n".utf8),bodyBytes=kind=="text" ? size:size-prefix.count,mimeBytes=bodyBytes+prefix.count
        guard bodyBytes>=0 else{throw NativeMailFailure.malformed}
        let file=try NativeMailResponseFile(temporaryRoot:temp)
        func write(_ fd:Int32,_ data:Data)throws {
            try data.withUnsafeBytes{bytes in var p=0;while p<bytes.count{try Task.checkCancellation();let n=Darwin.write(fd,bytes.baseAddress!.advanced(by:p),bytes.count-p);if n<0 && errno==EINTR{continue};guard n>0 else{throw NativeMailResponseFile.fileError};p += n}}
        }
        try file.withDescriptor { fd in
            try write(fd,Data("* 1 FETCH (UID 1 BODY[] {\(mimeBytes)}\r\n".utf8));try write(fd,prefix)
            let chunk=Data(repeating:120,count:32_768);var remaining=bodyBytes
            while remaining>0{let n=min(remaining,chunk.count);try write(fd,chunk.prefix(n));remaining -= n}
            try write(fd,Data(")\r\nA OK done\r\n".utf8))
        }
        let response=NativeMailReply(body:Data(),protocolHeaders:Data("* OK [UIDVALIDITY 1] selected\r\n".utf8),serverCode:200,responseBytes:0)
        guard let body=try NativeMailClient.decodeBodyFile(response,file:file,validity:1,uid:1,temporaryRoot:temp),let text=body.text,text.utf8.count==bodyBytes,body.html==nil else{throw NativeMailFailure.invalid("Large body mismatch")}
        var digest=SHA256(),chunk=Data();chunk.reserveCapacity(32_768)
        for byte in text.utf8{chunk.append(byte);if chunk.count==32_768{digest.update(data:chunk);chunk.removeAll(keepingCapacity:true)}}
        digest.update(data:chunk);let hex=digest.finalize().map{String(format:"%02x",$0)}.joined()
        let result:[String:Any]=["kind":kind,"size":size,"mimeBytes":mimeBytes,"textBytes":text.utf8.count,"textSHA256":hex,"html":NSNull()]
        try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:out.appendingPathComponent("large-native-\(kind)-\(size).json"))
        print("Large native \(kind) \(size): exact body retained")
    }
}
