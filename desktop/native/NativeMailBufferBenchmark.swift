import Foundation
import CryptoKit
import Darwin

/// Separate-process synthetic MIME benchmark; never starts an app or connects
/// to a mail server. The same harness compiles against both source versions.
@main struct NativeMailBufferBenchmark {
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        let body:String
        switch scenario {
        case "ascii": body = String(repeating:"a",count:8_000_000)
        case "newlines": body = String(repeating:"\n",count:4_000_000)
        case "japanese": body = String(repeating:"日本語の本文です。abc\r\n次の行\r最後\n",count:120_000)
        default: throw NativeMailFailure.malformed
        }
        let start = Date()
        let mime = try NativeMailMIME.outgoing(from:"sender@example.test",to:["receiver@example.test"],subject:"大容量本文の検証",body:body,messageID:"<buffer-benchmark@example.test>",date:Date(timeIntervalSince1970:0))
        let seconds = Date().timeIntervalSince(start)
        let hash = SHA256.hash(data:mime).map{String(format:"%02x",$0)}.joined()
        var usage = rusage(); guard getrusage(RUSAGE_SELF,&usage) == 0 else { throw NativeMailFailure.malformed }
        let result:[String:Any] = ["scenario":scenario,"bodyBytes":body.utf8.count,"mimeBytes":mime.count,"mimeSHA256":hash,"encodeSeconds":seconds,"peakRSSBytes":usage.ru_maxrss]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
}
