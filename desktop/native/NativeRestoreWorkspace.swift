import Foundation
import Darwin
import CryptoKit

final class NativeRestoreWorkspace {
    let output:NativeMigrationImportWorkspace
    private var folders:[String:Int32]=[:]
    static let names=["native-documents","native-avatars","invoice-pdfs","mail-outbox","native-credential-archives"]
    init(destination:URL,backup:URL)throws {
        output=try NativeMigrationImportWorkspace(destination:destination,bundle:backup)
        do {
            try output.makeAssets()
            for name in Self.names {
                guard mkdirat(output.root,name,0o700)==0 else{throw NativeMigrationFiles.io}
                let fd=openat(output.root,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard fd>=0 else{_ = unlinkat(output.root,name,AT_REMOVEDIR);throw NativeMigrationFiles.io}
                folders[name]=fd
            }
        } catch {cleanup();for fd in folders.values{close(fd)};folders=[:];throw error}
    }
    private var published=false
    deinit {if !published{cleanup()};for fd in folders.values{close(fd)}}
    static func path(_ value:String)throws->(String,String) {
        let p=try NativeMigrationFiles.path(value)
        guard p.count==2,names.contains(p[0]) else{throw NativeMigrationFailure("restore.path","復元先の管理ファイルパスが不正です。")}
        let suffix=p[0]=="native-credential-archives" ? #"\.(?:handoff|holds)"# : p[0]=="native-avatars" ? #"(?:\.png|\.original\.(?:png|jpg|gif|webp))"# : p[0]=="invoice-pdfs" ? #"\.pdf"# : p[0]=="mail-outbox" ? #"\.json"# : #"\.[a-z0-9]{1,16}"#
        guard NativeMigrationCodec.matches(#"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#+suffix+#"\z"#,p[1]) else{throw NativeMigrationFailure("restore.path","管理ファイルの識別子が不正です。")}
        return(p[0],p[1])
    }
    private func folder(_ name:String)throws->Int32 {
        guard let fd=folders[name] else{throw NativeMigrationFiles.badPath};var current=stat(),pinned=stat()
        guard fstat(fd,&pinned)==0,fstatat(output.root,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_mode&S_IFMT==S_IFDIR,current.st_dev==pinned.st_dev,current.st_ino==pinned.st_ino else{throw NativeMigrationFailure("restore.changed","復元先フォルダが置換されています。")}
        return fd
    }
    static func digest(_ fd:Int32,cancelled:()->Bool)throws->(Int64,String) {
        guard lseek(fd,0,SEEK_SET)==0 else{throw NativeMigrationFiles.io};var hash=SHA256(),bytes:Int64=0,buffer=[UInt8](repeating:0,count:65536)
        while true{if cancelled(){throw CancellationError()};let n=Darwin.read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw NativeMigrationFiles.io};if n==0{break};hash.update(data:Data(buffer.prefix(n)));bytes+=Int64(n)}
        return(bytes,hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    static func copy(from source:NativeMigrationFiles,path:String,to fd:Int32,bytes:Int64,hash:String,cancelled:()->Bool,progress:()throws->Void)throws {
        let actual=try source.read(path,cancelled:cancelled){try NativeMigrationImportWorkspace.write($0,to:fd);try progress()}
        guard actual.bytes==bytes,actual.sha256==hash,fsync(fd)==0 else{throw NativeMigrationFailure("restore.hash","保存ファイルのサイズ・hashが一致しません。")}
        let readback=try digest(fd,cancelled:cancelled)
        guard readback.0==bytes,readback.1==hash else{throw NativeMigrationFailure("restore.readback","復元候補の読み戻しが一致しません。")}
    }
    func copyAsset(_ asset:NativeBackupFile,source:NativeMigrationFiles,cancelled:()->Bool,progress:()throws->Void)throws {
        let (name,leaf)=try Self.path(asset.sourcePath),dir=try folder(name)
        let fd=openat(dir,leaf,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw NativeMigrationFiles.io};defer{close(fd)}
        try Self.copy(from:source,path:asset.archivePath,to:fd,bytes:asset.bytes,hash:asset.sha256,cancelled:cancelled,progress:progress)
        if name=="native-avatars" || name=="native-documents" || name=="native-credential-archives"{guard fchmod(fd,0o400)==0 else{throw NativeMigrationFiles.io}}
    }
    func publish()throws {for name in Self.names{guard fsync(try folder(name))==0 else{throw NativeMigrationFiles.io}};try output.publish();published=true}
    private func cleanup() {
        for (name,fd) in folders {
            let duplicate=dup(fd);if duplicate<0{continue}
            if let entries=fdopendir(duplicate){rewinddir(entries);while let e=readdir(entries){let n=Int(e.pointee.d_namlen)+1;let leaf=withUnsafePointer(to:&e.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:n){String(cString:$0)}};if (try? Self.path(name+"/"+leaf)) != nil{_ = unlinkat(fd,leaf,0)}};closedir(entries)}else{close(duplicate)}
            if (try? folder(name)) != nil{_ = unlinkat(output.root,name,AT_REMOVEDIR)}
        }
    }
}
