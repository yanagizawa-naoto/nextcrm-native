import Foundation
import Darwin
import CryptoKit

final class NativeMigrationImportWorkspace {
    let url:URL;private let parent:Int32;let root:Int32;private let name:String;private let identity:NativeMigrationFiles.Fingerprint
    private var files:[String]=[];private var kept=false;private var assetsFD:Int32 = -1
    static func resolvedTemporaryDirectory() throws -> URL {
        guard let raw=realpath(FileManager.default.temporaryDirectory.path,nil) else {throw NativeMigrationFailure("candidate.temporary","一時保存先を確認できません。")};defer{free(raw)}
        return URL(fileURLWithPath:String(cString:raw),isDirectory:true)
    }
    private static func directory(_ url:URL)throws->Int32 {
        guard url.isFileURL,url.path.hasPrefix("/") else {throw NativeMigrationFiles.badPath}
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else {throw NativeMigrationFiles.io}
        do{for part in url.path.split(separator:"/",omittingEmptySubsequences:true){guard part != ".",part != "..",!part.utf8.contains(0) else {throw NativeMigrationFiles.badPath};let next=openat(fd,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else {throw NativeMigrationFiles.badPath};close(fd);fd=next};return fd}
        catch{close(fd);throw error}
    }
    init(destination:URL,bundle:URL)throws {
        let temporary=try Self.resolvedTemporaryDirectory().path
        guard destination.isFileURL,destination.path.hasPrefix(temporary+"/"),!destination.path.hasPrefix(bundle.path+"/"),destination.path != bundle.path else {throw NativeMigrationFailure("candidate.location","候補は入力と重ならない新規一時フォルダに作成してください。")}
        name=destination.lastPathComponent;_ = try NativeMigrationFiles.path(name)
        guard name.utf8.count<=128 else {throw NativeMigrationFiles.badPath}
        parent=try Self.directory(destination.deletingLastPathComponent());url=destination
        guard mkdirat(parent,name,0o700)==0 else {close(parent);throw NativeMigrationFailure("candidate.exists","保存先が既に存在するか、新規フォルダを作成できません。")}
        let fd=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else {_ = unlinkat(parent,name,AT_REMOVEDIR);close(parent);throw NativeMigrationFiles.io}
        root=fd;var statValue=stat()
        guard fstat(fd,&statValue)==0 else {close(fd);_ = unlinkat(parent,name,AT_REMOVEDIR);close(parent);throw NativeMigrationFiles.io}
        identity=NativeMigrationFiles.Fingerprint(statValue)
    }
    deinit {if !kept{cleanup()};if assetsFD>=0{close(assetsFD)};close(root);close(parent)}
    private func checkRoot()throws {
        var info=stat();guard fstatat(parent,name,&info,AT_SYMLINK_NOFOLLOW)==0,info.st_mode&S_IFMT==S_IFDIR,UInt64(info.st_ino)==identity.inode,UInt64(bitPattern:Int64(info.st_dev))==identity.device else {throw NativeMigrationFailure("candidate.changed","候補フォルダの識別子が変更されました。")}
    }
    private func checkAssets()throws {
        var actual=stat(),pinned=stat()
        guard assetsFD>=0,fstat(assetsFD,&pinned)==0,fstatat(root,"assets",&actual,AT_SYMLINK_NOFOLLOW)==0,actual.st_mode&S_IFMT==S_IFDIR,actual.st_dev==pinned.st_dev,actual.st_ino==pinned.st_ino else {throw NativeMigrationFailure("candidate.changed","添付候補フォルダの識別子が変更されました。")}
    }
    func makeAssets()throws {try checkRoot();guard mkdirat(root,"assets",0o700)==0 else {throw NativeMigrationFiles.io};assetsFD=openat(root,"assets",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);try checkAssets()}
    func create(_ path:String)throws->Int32 {
        try checkRoot();let parts=try NativeMigrationFiles.path(path);guard parts.count==1 || (parts.count==2 && parts[0]=="assets") else {throw NativeMigrationFiles.badPath}
        let dir:Int32
        if parts.count==2 {try checkAssets();dir=dup(assetsFD)} else {dir=dup(root)}
        guard dir>=0 else {throw NativeMigrationFiles.io}
        defer{close(dir)};let fd=openat(dir,parts.last!,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw NativeMigrationFailure("candidate.file","候補ファイルを新規作成できません。")};if !path.contains("/"){files.append(path)};return fd
    }
    static func write(_ data:Data,to fd:Int32)throws {
        try data.withUnsafeBytes{raw in var offset=0;while offset<raw.count {let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if n<0 && errno==EINTR {continue};guard n>0 else {throw NativeMigrationFailure("candidate.write","候補ファイルを書き込めません。空き容量を確認してください。")};offset+=n}}
    }
    func put(_ data:Data,path:String)throws {let fd=try create(path);defer{close(fd)};try Self.write(data,to:fd);guard fsync(fd)==0 else {throw NativeMigrationFiles.io}}
    func copy(_ path:String,from source:NativeMigrationFiles,to destination:String,expectedBytes:Int64,expectedHash:String,cancelled:()->Bool,progress:(()throws->Void)?=nil)throws {
        let fd=try create(destination);defer{close(fd)}
        let actual=try source.read(path,cancelled:cancelled){try Self.write($0,to:fd);try progress?()}
        guard actual.bytes==expectedBytes,actual.sha256==expectedHash,fsync(fd)==0 else {throw NativeMigrationFailure("candidate.asset","コピーした添付のサイズ・hashが一致しません。")}
        guard lseek(fd,0,SEEK_SET)==0 else {throw NativeMigrationFiles.io};var digest=SHA256(),bytes:Int64=0;var buffer=[UInt8](repeating:0,count:65536)
        while true {if cancelled(){throw CancellationError()};let n=Darwin.read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else {throw NativeMigrationFiles.io};if n==0{break};digest.update(data:Data(buffer.prefix(n)));bytes+=Int64(n)}
        guard bytes==expectedBytes,digest.finalize().map({String(format:"%02x",$0)}).joined()==expectedHash else {throw NativeMigrationFailure("candidate.asset","候補添付のreadbackが一致しません。")}
    }
    func publish()throws {try checkRoot();try checkAssets();guard fsync(assetsFD)==0,fsync(root)==0,fsync(parent)==0 else {throw NativeMigrationFiles.io};kept=true}
    private func cleanup() {
        // Only names created by this instance, relative to pinned directories.
        let assets=assetsFD>=0 ? dup(assetsFD):-1
        if assets>=0 {
            let duplicate=dup(assets)
            if let entries=fdopendir(duplicate) {
                while let entry=readdir(entries) {
                    let count=Int(entry.pointee.d_namlen)+1
                    let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:count){String(cString:$0)}}
                    if NativeMigrationCodec.matches(#"\A[0-9a-f]{64}\.blob\z"#,name){_ = unlinkat(assets,name,0)}
                }
                closedir(entries)
            } else if duplicate>=0 {close(duplicate)}
            close(assets)
        }
        for path in files where !path.contains("/"){_ = unlinkat(root,path,0)}
        _ = unlinkat(root,"assets",AT_REMOVEDIR)
        if (try? checkRoot()) != nil {_ = unlinkat(parent,name,AT_REMOVEDIR)}
    }
}
