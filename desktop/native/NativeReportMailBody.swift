import Foundation
import CryptoKit
import Darwin

struct NativeReportMailAttachment {let filename:String,url:URL}

enum NativeReportMailBody {
    /// Call with a fresh staging UUID. The worker publishes this immutable body
    /// to the job's final path only while holding its current database lease.
    static func prepare(root:URL,id:String,from:String,to:[String],subject:String,message:String,attachments:[NativeReportMailAttachment])throws->InvoiceMailBody {
        let sender=try InvoiceMail.mailbox(from)
        guard (1...50).contains(to.count),(1...2).contains(attachments.count),!subject.isEmpty,!subject.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),subject.utf8.count<=998,message.utf8.count<=InvoiceMail.maximumBytes else {throw NativeDBError.message("宛先・件名・本文・添付の数を確認してください。")}
        let recipients=try to.map(InvoiceMail.mailbox)
        let destination=try InvoiceMail.bodyURL(root:root,id:id)
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=Darwin.open(destination.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw NativeDBError.message("送信用ファイルを作成できません。")}
        let output=FileHandle(fileDescriptor:fd,closeOnDealloc:true);var complete=false,written=0,hash=SHA256()
        defer{try? output.close();if !complete{try? FileManager.default.removeItem(at:destination)}}
        func write(_ bytes:Data)throws {
            try Task.checkCancellation()
            guard bytes.count<=InvoiceMail.maximumBytes-written else {throw NativeDBError.message("添付を含めたメールが40 MBを超えています。")}
            try output.write(contentsOf:bytes);hash.update(data:bytes);written+=bytes.count
        }
        var metadata=try JSONSerialization.data(withJSONObject:["from":sender,"to":recipients,"subject":subject],options:[.sortedKeys,.withoutEscapingSlashes]);metadata.removeLast()
        try write(metadata);try write(Data(",\"text\":\"".utf8))
        var escaped=Data();escaped.reserveCapacity(64*1024+6);let hex=Array("0123456789abcdef".utf8)
        for byte in message.utf8 {
            switch byte {
            case 34,92:escaped.append(92);escaped.append(byte)
            case 0...31:escaped.append(contentsOf:[92,117,48,48,hex[Int(byte)/16],hex[Int(byte)%16]])
            default:escaped.append(byte)
            }
            if escaped.count>=64*1024 {try write(escaped);escaped.removeAll(keepingCapacity:true)}
        }
        try write(escaped);try write(Data("\",\"attachments\":[".utf8))
        for (index,attachment) in attachments.enumerated() {
            try autoreleasepool {
                guard attachment.url.isFileURL,!attachment.filename.isEmpty,attachment.filename.utf8.count<=255,!attachment.filename.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),!attachment.filename.contains("/"),!attachment.filename.contains("\\") else {throw NativeDBError.message("添付ファイルの名前を確認してください。")}
                let descriptor=Darwin.open(attachment.url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
                guard descriptor>=0 else {throw NativeDBError.message("添付ファイルを開けません。")}
                let input=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer{try? input.close()}
                var info=stat()
                guard fstat(descriptor,&info)==0,info.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),info.st_size>0,info.st_size<=Int64(InvoiceMail.maximumBytes/4*3) else {throw NativeDBError.message("添付ファイルの種類またはサイズを確認してください。")}
                let filename=try JSONSerialization.data(withJSONObject:attachment.filename,options:.fragmentsAllowed)
                if index>0 {try write(Data([44]))};try write(Data("{\"filename\":".utf8));try write(filename);try write(Data(",\"content\":\"".utf8))
                let size=Int(info.st_size)
                guard (size+2)/3*4+5<=InvoiceMail.maximumBytes-written else {throw NativeDBError.message("添付を含めたメールが40 MBを超えています。")}
                var carry=Data(),read=0
                while let chunk=try input.read(upToCount:48*1024),!chunk.isEmpty {
                    try autoreleasepool {
                        try Task.checkCancellation();read+=chunk.count
                        guard read<=size else {throw NativeDBError.message("添付ファイルが変更されました。")}
                        carry.append(chunk);let count=carry.count/3*3
                        if count>0 {try write(carry.prefix(count).base64EncodedData());carry=Data(carry.dropFirst(count))}
                    }
                }
                guard read==size else {throw NativeDBError.message("添付ファイルが変更されました。")}
                if !carry.isEmpty {try write(carry.base64EncodedData())};try write(Data("\"}".utf8))
            }
        }
        try write(Data("]}".utf8));try output.synchronize();complete=true
        return .init(url:destination,bytes:written,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
}
