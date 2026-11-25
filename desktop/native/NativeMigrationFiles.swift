import Foundation
import Darwin
import CryptoKit

final class NativeMigrationFiles {
    private let root:Int32
    init(root url:URL) throws {
        guard url.isFileURL,url.path.hasPrefix("/") else {throw Self.badPath}
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard fd>=0 else {throw Self.io}
        do {
            for part in url.path.split(separator:"/",omittingEmptySubsequences:true) {
                guard part != ".",part != "..",!part.utf8.contains(0) else {throw Self.badPath}
                let next=openat(fd,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else {throw Self.badPath};close(fd);fd=next
            }
            root=fd
        } catch {close(fd);throw error}
    }
    deinit {close(root)}
    static var badPath:NativeMigrationFailure {.init("path.unsafe","入力パスが安全な相対パスではないか、シンボリックリンクが含まれています。")}
    static var io:NativeMigrationFailure {.init("file.read","入力ファイルを読み取れません。欠落・権限・形式を確認してください。")}
    static func path(_ path:String) throws -> [String] {
        guard !path.isEmpty,path.utf8.count<=1024,!path.hasPrefix("/"),!path.contains("\\"),!path.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {throw badPath}
        let parts=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else {throw badPath};return parts
    }
    private func descriptor(_ path:String) throws -> Int32 {
        let parts=try Self.path(path);var dir=dup(root);guard dir>=0 else {throw Self.io};defer{close(dir)}
        for part in parts.dropLast(){let next=openat(dir,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else {throw Self.badPath};close(dir);dir=next}
        let fd=openat(dir,parts.last!,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw Self.io}
        var info=stat();guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG else {close(fd);throw Self.io};return fd
    }
    struct Fingerprint:Equatable {
        let device:UInt64,inode:UInt64,size:Int64,modified:Int64,modifiedNanos:Int64,changed:Int64,changedNanos:Int64
        init(_ i:stat){device=UInt64(bitPattern:Int64(i.st_dev));inode=UInt64(i.st_ino);size=i.st_size;modified=Int64(i.st_mtimespec.tv_sec);modifiedNanos=Int64(i.st_mtimespec.tv_nsec);changed=Int64(i.st_ctimespec.tv_sec);changedNanos=Int64(i.st_ctimespec.tv_nsec)}
    }
    @discardableResult func read(_ path:String,maximum:Int64?=nil,cancelled:()->Bool,chunk:(Data)throws->Void) throws -> (bytes:Int64,sha256:String) {
        let fd=try descriptor(path);defer{close(fd)};var initial=stat();guard fstat(fd,&initial)==0 else {throw Self.io}
        let before=Fingerprint(initial);if let maximum,initial.st_size>maximum {throw NativeMigrationFailure("limit.file","入力ファイルが検査上限を超えています。")}
        var hash=SHA256(),count:Int64=0;var buffer=[UInt8](repeating:0,count:65536)
        while true {
            if cancelled(){throw CancellationError()}
            let n=Darwin.read(fd,&buffer,buffer.count)
            if n<0 && errno==EINTR {continue};guard n>=0 else {throw Self.io};if n==0{break}
            let (next,overflow)=count.addingReportingOverflow(Int64(n));guard !overflow,maximum.map({next<=$0}) ?? true else {throw NativeMigrationFailure("limit.file","入力ファイルが検査上限を超えています。")};count=next
            let data=Data(buffer.prefix(n));hash.update(data:data);try chunk(data)
        }
        var final=stat();guard fstat(fd,&final)==0,before==Fingerprint(final),count==initial.st_size else {throw NativeMigrationFailure("file.changed","検査中に入力ファイルが変更されました。")}
        // Reopen relative to pinned root to detect rename/replacement, too.
        let fresh=try descriptor(path);defer{close(fresh)};var current=stat()
        guard fstat(fresh,&current)==0,before==Fingerprint(current) else {throw NativeMigrationFailure("file.changed","検査中に入力ファイルが置換されました。")}
        return(count,hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    func data(_ path:String,maximum:Int,cancelled:()->Bool) throws -> Data {var data=Data();try read(path,maximum:Int64(maximum),cancelled:cancelled){data.append($0)};return data}
    func lines(_ file:NativeMigrationManifest.File,limit:Int,cancelled:()->Bool,line:(Data,Int64)throws->Void) throws -> Int64 {
        var pending=Data();var rows:Int64=0
        let actual=try read(file.path,cancelled:cancelled) {chunk in
            var start=chunk.startIndex
            for i in chunk.indices where chunk[i]==10 {
                guard pending.count+chunk.distance(from:start,to:i)<=limit else {throw NativeMigrationFailure("limit.line","1行の大きさが検査上限を超えています。")}
                pending.append(chunk[start..<i]);guard !pending.isEmpty else {throw NativeMigrationFailure("json.blank_line","空行はレコードとして扱えません。")}
                rows+=1;try line(pending,rows);pending.removeAll(keepingCapacity:true);start=chunk.index(after:i)
            }
            pending.append(chunk[start..<chunk.endIndex]);guard pending.count<=limit else {throw NativeMigrationFailure("limit.line","1行の大きさが検査上限を超えています。")}
        }
        guard pending.isEmpty else {throw NativeMigrationFailure("json.line_end","最後のレコードに改行がありません。")}
        guard actual.bytes==file.bytes,actual.sha256==file.sha256,rows==file.rows else {throw NativeMigrationFailure("file.digest","ファイルの件数・サイズ・SHA256がmanifestと一致しません。")};return rows
    }
}
