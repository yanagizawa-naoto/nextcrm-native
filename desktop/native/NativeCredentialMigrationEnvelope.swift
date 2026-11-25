import Foundation
import CryptoKit
import Darwin

enum NativeCredentialMigrationFailure: String, Error, LocalizedError {
    case format, integrity, key, changed, unavailable, authority, conflict, unsupported, cleanup
    var errorDescription: String? { "秘密情報の移行を完了できませんでした（" + rawValue + "）。元の暗号化ファイルは保持してください。" }
}

struct NativeCredentialMigrationOwner: Codable, Equatable {
    let model: String
    let key: [String:String]
    let field: String
}
struct NativeCredentialMigrationDescriptor: Codable {
    let version: Int, handoffID: String, path: String
    let entries: Int, bytes: Int64, sha256: String
}

/// One bounded frame at a time. No plaintext is written to disk. A complete
/// authenticated first pass is mandatory before any caller receives plaintext.
final class NativeCredentialMigrationEnvelope {
    struct Header: Codable, Equatable {
        let version: Int, handoffID: String, schemaSHA256: String, snapshotID: String, salt: String
    }
    struct Entry: Codable {
        let version: Int, headerSHA256: String, index: Int, entryID: String
        let kind: String, owner: NativeCredentialMigrationOwner, valueSHA256: String, classification: String
    }
    private struct SealAAD: Codable {let version: Int, headerSHA256: String, index: Int, type: String}
    private struct Seal: Codable {let entries: Int, entryStreamSHA256: String}
    private var fd: Int32 = -1
    private let identity: stat, key: SymmetricKey, descriptor: NativeCredentialMigrationDescriptor
    let header: Header
    static let maximumValueBytes=8*1024*1024
    private let maximumAADBytes=65_536
    private(set) var maximumFrameBytes=0
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func hexadecimal(_ text:String)->Bool {text.utf8.count==64 && text.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)}}
    private static func identifier(_ text:String)->Bool {let b=Array(text.utf8);guard !b.isEmpty,b.count<=128 else{return false};func initial(_ c:UInt8)->Bool{c==95||(65...90).contains(c)||(97...122).contains(c)};return initial(b[0])&&b.dropFirst().allSatisfy{initial($0)||(48...57).contains($0)}}
    static func valid(_ owner:NativeCredentialMigrationOwner)->Bool {
        identifier(owner.model) && identifier(owner.field) && !owner.key.isEmpty && owner.key.count<=16 && owner.key.allSatisfy{identifier($0.key) && $0.value.utf8.count<=4096}
    }
    private static func openDirectory(_ original:URL)throws->Int32 {
        guard original.isFileURL,original.path.hasPrefix("/") else{throw NativeCredentialMigrationFailure.format}
        var path=original.path
        for (alias,target) in [("/var","/private/var"),("/tmp","/private/tmp")] where path==alias || path.hasPrefix(alias+"/") {
            var s=stat();var buffer=[CChar](repeating:0,count:64)
            if lstat(alias,&s)==0,s.st_uid==0,s.st_mode&S_IFMT==S_IFLNK {
                let n=readlink(alias,&buffer,buffer.count-1)
                if n>0 {buffer[Int(n)]=0;let value=String(cString:buffer);if value==String(target.dropFirst())||value==target {path=target+String(path.dropFirst(alias.count))}}
            }
        }
        var parent=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard parent>=0 else{throw NativeCredentialMigrationFailure.unavailable}
        do {for part in path.split(separator:"/"){guard part != ".",part != ".." else{throw NativeCredentialMigrationFailure.format};let next=openat(parent,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else{throw NativeCredentialMigrationFailure.unavailable};close(parent);parent=next};return parent}
        catch {close(parent);throw error}
    }
    init(root:URL,descriptor:NativeCredentialMigrationDescriptor,key:Data,schemaSHA256:String,snapshotID:String,fileName:String="credentials.handoff")throws {
        guard key.count==32 else{throw NativeCredentialMigrationFailure.key}
        guard descriptor.version==1,descriptor.path=="credentials.handoff",UUID(uuidString:descriptor.handoffID) != nil,descriptor.entries>=0,descriptor.bytes>12,Self.hexadecimal(descriptor.sha256),Self.hexadecimal(schemaSHA256) else{throw NativeCredentialMigrationFailure.format}
        let parent=try Self.openDirectory(root);defer{close(parent)}
        guard fileName=="credentials.handoff" || (fileName.utf8.count==44 && fileName.hasSuffix(".handoff") && UUID(uuidString:String(fileName.dropLast(8)))?.uuidString.lowercased()==String(fileName.dropLast(8))) else{throw NativeCredentialMigrationFailure.format}
        let opened=openat(parent,fileName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard opened>=0 else{throw NativeCredentialMigrationFailure.unavailable}
        do {
            var info=stat();guard fstat(opened,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_uid==geteuid(),info.st_mode&0o077==0,info.st_nlink==1,info.st_size==descriptor.bytes else{throw NativeCredentialMigrationFailure.integrity}
            self.fd=opened;identity=info;self.descriptor=descriptor
            guard try Self.read(opened,8)==Data("NCRMSEC1".utf8) else{throw NativeCredentialMigrationFailure.format}
            let size=try Self.number(Self.read(opened,4));guard size>0,size<=65_536 else{throw NativeCredentialMigrationFailure.format}
            let raw=try Self.read(opened,Int(size));let h=try JSONDecoder().decode(Header.self,from:raw)
            guard h.version==1,h.handoffID==descriptor.handoffID,h.schemaSHA256==schemaSHA256,h.snapshotID==snapshotID,let salt=Data(base64Encoded:h.salt),salt.count==16 else{throw NativeCredentialMigrationFailure.integrity}
            header=h;self.key=HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:key),salt:salt,info:Data("nextcrm-credential-handoff/v1".utf8),outputByteCount:32)
            try scan(nil)
        } catch {close(opened);fd = -1;throw error}
    }
    deinit {close(fd)}
    private static func read(_ fd:Int32,_ count:Int)throws->Data {
        guard count>=0,count<=maximumValueBytes else{throw NativeCredentialMigrationFailure.format}
        var data=Data(count:count);var at=0
        try data.withUnsafeMutableBytes{bytes in while at<count {let n=Darwin.read(fd,bytes.baseAddress!.advanced(by:at),count-at);if n<0&&errno==EINTR{continue};guard n>0 else{throw NativeCredentialMigrationFailure.format};at+=n}}
        return data
    }
    private static func number(_ data:Data)throws->UInt64 {guard data.count<=8 else{throw NativeCredentialMigrationFailure.format};return data.reduce(UInt64(0)){($0<<8)|UInt64($1)}}
    private func current()throws {
        var s=stat();guard fstat(fd,&s)==0,s.st_dev==identity.st_dev,s.st_ino==identity.st_ino,s.st_size==identity.st_size,s.st_nlink==1,s.st_mtimespec.tv_sec==identity.st_mtimespec.tv_sec,s.st_mtimespec.tv_nsec==identity.st_mtimespec.tv_nsec,s.st_ctimespec.tv_sec==identity.st_ctimespec.tv_sec,s.st_ctimespec.tv_nsec==identity.st_ctimespec.tv_nsec else{throw NativeCredentialMigrationFailure.changed}
    }
    func forEach(_ body:(Entry,Data)throws->Void)throws {try withoutActuallyEscaping(body){try scan($0)}}
    private func scan(_ body:((Entry,Data)throws->Void)?)throws {
        try current();guard lseek(fd,0,SEEK_SET)==0 else{throw NativeCredentialMigrationFailure.unavailable}
        var full=SHA256(),entriesHash=SHA256(),index=0
        func read(_ n:Int)throws->Data{let b=try Self.read(fd,n);full.update(data:b);return b}
        guard try read(8)==Data("NCRMSEC1".utf8) else{throw NativeCredentialMigrationFailure.format}
        let size=try Self.number(read(4));guard size>0,size<=UInt64(maximumAADBytes) else{throw NativeCredentialMigrationFailure.format}
        let headerRaw=try read(Int(size));guard try JSONDecoder().decode(Header.self,from:headerRaw)==header else{throw NativeCredentialMigrationFailure.integrity}
        let headerHash=Self.hash(headerRaw)
        while true {
            try Task.checkCancellation()
            let type=try read(1);guard type[0]==1||type[0]==255 else{throw NativeCredentialMigrationFailure.format}
            let aadSizeRaw=try read(4),plainSizeRaw=try read(8),aadSize=try Self.number(aadSizeRaw),plainSize=try Self.number(plainSizeRaw)
            guard aadSize>0,aadSize<=UInt64(maximumAADBytes),plainSize<=UInt64(Self.maximumValueBytes) else{throw NativeCredentialMigrationFailure.format}
            let aad=try read(Int(aadSize)),nonce=try read(12),cipher=try read(Int(plainSize)),tag=try read(16)
            guard nonce.prefix(4)==Data(repeating:0,count:4),try Self.number(nonce.suffix(8))==UInt64(index) else{throw NativeCredentialMigrationFailure.integrity}
            let box=try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:nonce),ciphertext:cipher,tag:tag)
            var plaintext:Data
            do {plaintext=try AES.GCM.open(box,using:key,authenticating:aad)}catch{throw NativeCredentialMigrationFailure.integrity}
            defer{plaintext.resetBytes(in:0..<plaintext.count)}
            maximumFrameBytes=max(maximumFrameBytes,cipher.count+plaintext.count+aad.count)
            if type[0]==255 {
                let a=try JSONDecoder().decode(SealAAD.self,from:aad),seal=try JSONDecoder().decode(Seal.self,from:plaintext)
                let sum=entriesHash.finalize().map{String(format:"%02x",$0)}.joined()
                guard a.version==1,a.headerSHA256==headerHash,a.index==index,a.type=="seal",seal.entries==index,index==descriptor.entries,seal.entryStreamSHA256==sum,lseek(fd,0,SEEK_CUR)==descriptor.bytes else{throw NativeCredentialMigrationFailure.integrity}
                let digest=full.finalize().map{String(format:"%02x",$0)}.joined();guard digest==descriptor.sha256 else{throw NativeCredentialMigrationFailure.integrity};try current();return
            }
            for data in [type,aadSizeRaw,plainSizeRaw,aad,nonce,cipher,tag]{entriesHash.update(data:data)}
            let e=try JSONDecoder().decode(Entry.self,from:aad)
            guard e.version==1,e.headerSHA256==headerHash,e.index==index,UUID(uuidString:e.entryID) != nil,Self.valid(e.owner),["credential","opaque-json","credential-url"].contains(e.kind),["known-secret","operator-hold","url-credential"].contains(e.classification),Self.hexadecimal(e.valueSHA256),e.valueSHA256==Self.hash(plaintext),index<Int.max else{throw NativeCredentialMigrationFailure.integrity}
            try body?(e,plaintext);index+=1
        }
    }
    /// Original bytes layout is iv12 + tag16 + ciphertext, not CryptoKit's
    /// combined ordering. Invalid original input remains encrypted-held.
    static func decryptServer(_ value:String,key:Data)throws->Data {
        guard key.count==32,value.utf8.count<=maximumValueBytes else{throw NativeCredentialMigrationFailure.key}
        // Node Buffer.from(value,"base64") accepts URL-safe characters,
        // whitespace and omitted padding. Match that text transport, while
        // requiring the original encrypt() function's full 128-bit tag.
        var packed=Data(),bits=0,accumulator:UInt16=0
        for byte in value.utf8 {
            if byte==61{break}
            let number:UInt16
            switch byte {case 65...90:number=UInt16(byte-65);case 97...122:number=UInt16(byte-97+26);case 48...57:number=UInt16(byte-48+52);case 43,45:number=62;case 47,95:number=63;default:continue}
            accumulator=(accumulator<<6)|number;bits+=6
            if bits>=8 {bits-=8;packed.append(UInt8((accumulator>>bits)&255));accumulator &= UInt16((1<<bits)-1)}
        }
        guard packed.count>=28 else{throw NativeCredentialMigrationFailure.key}
        do {let box=try AES.GCM.SealedBox(nonce:AES.GCM.Nonce(data:packed.prefix(12)),ciphertext:packed.dropFirst(28),tag:packed[12..<28]);return try AES.GCM.open(box,using:SymmetricKey(data:key))}
        catch {throw NativeCredentialMigrationFailure.integrity}
    }
}
