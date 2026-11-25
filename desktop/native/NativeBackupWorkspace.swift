import Foundation
import Darwin
import CryptoKit

final class NativeBackupWorkspace {
    let output:NativeMigrationImportWorkspace
    private let sourceRoot:Int32,pins:Int32
    let sourceURL:URL
    init(sourceURL:URL,destination:URL)throws {
        self.sourceURL=sourceURL
        let source=try Self.openDirectory(sourceURL)
        do {
            let candidate=try NativeMigrationImportWorkspace(destination:destination,bundle:sourceURL)
            try candidate.makeAssets()
            guard mkdirat(candidate.root,"pins",0o700)==0 else {throw NativeMigrationFiles.io}
            let opened=openat(candidate.root,"pins",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard opened>=0 else {_ = unlinkat(candidate.root,"pins",AT_REMOVEDIR);throw NativeMigrationFiles.io}
            sourceRoot=source;output=candidate;pins=opened
        } catch {close(source);throw error}
    }
    deinit {removePins();close(pins);close(sourceRoot)}
    static func openDirectory(_ url:URL)throws->Int32 {
        guard url.isFileURL,url.path.hasPrefix("/") else {throw NativeMigrationFiles.badPath}
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else {throw NativeMigrationFiles.io}
        do{for part in url.path.split(separator:"/",omittingEmptySubsequences:true){guard part != ".",part != "..",!part.utf8.contains(0) else {throw NativeMigrationFiles.badPath};let next=openat(fd,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else {throw NativeMigrationFiles.badPath};close(fd);fd=next};return fd}catch{close(fd);throw error}
    }
    private func parent(_ path:String)throws->(Int32,String) {
        let parts=try NativeMigrationFiles.path(path)
        guard parts.count==2,["native-documents","native-avatars","invoice-pdfs","mail-outbox","native-credential-archives"].contains(parts[0]) else {throw NativeMigrationFailure("backup.path","管理対象ファイルの保存キーが不正です。")}
        let suffix=parts[0]=="native-credential-archives" ? #"\.(?:handoff|holds)"# : parts[0]=="native-avatars" ? #"(?:\.png|\.original\.(?:png|jpg|gif|webp))"# : parts[0]=="invoice-pdfs" ? #"\.pdf"# : parts[0]=="mail-outbox" ? #"\.json"# : #"\.[a-z0-9]{1,16}"#
        guard NativeMigrationCodec.matches(#"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#+suffix+#"\z"#,parts[1]) else {throw NativeMigrationFailure("backup.path","管理対象ファイルの識別子が不正です。") }
        let fd=openat(sourceRoot,parts[0],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw NativeMigrationFiles.io};return(fd,parts[1])
    }
    func originalAvatar(for thumbnail:String)throws->String? {
        let (directory,leaf)=try parent(thumbnail);defer{close(directory)};let stem=String(leaf.dropLast(4));var found:String?
        for ext in ["png","jpg","gif","webp"] {
            let name=stem+".original."+ext;var value=stat()
            if fstatat(directory,name,&value,AT_SYMLINK_NOFOLLOW) != 0 {if errno==ENOENT{continue};throw NativeMigrationFiles.io}
            guard found==nil,value.st_mode&S_IFMT==S_IFREG,value.st_nlink==1,value.st_uid==geteuid(),value.st_mode & 0o077==0,value.st_size>0,value.st_size<=4*1024*1024 else {throw NativeMigrationFailure("backup.avatar_pair","写真の元画像が複数あるか、保存形式・権限が不正です。")}
            found="native-avatars/"+name
        }
        return found
    }
    private static func info(_ fd:Int32)throws->stat {var value=stat();guard fstat(fd,&value)==0,value.st_mode&S_IFMT==S_IFREG,value.st_size>=0 else {throw NativeMigrationFiles.io};return value}
    static func signature(_ s:stat)->String {"\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec)"}
    struct Pin {let name:String,signature:String;let bytes:Int64;let linked:Bool,cloned:Bool}
    func pin(_ path:String,expectedBytes:Int64?,expectedSHA:String?,forceCopy:Bool,cancelled:()->Bool,progress:()throws->Void)throws->Pin {
        let (directory,leaf)=try parent(path);defer{close(directory)}
        let fd=openat(directory,leaf,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw NativeMigrationFiles.io};defer{close(fd)}
        let before=try Self.info(fd)
        guard expectedBytes.map({$0==before.st_size}) ?? true else {throw NativeMigrationFailure("backup.size","公開されたファイルサイズと実体が一致しません。")}
        let name=UUID().uuidString.lowercased()+".pin"
        let avatar=path.hasPrefix("native-avatars/"),archive=path.hasPrefix("native-credential-archives/")
        if archive {guard before.st_nlink==1,before.st_uid==geteuid(),before.st_mode & 0o077==0 else{throw NativeMigrationFailure("backup.credential_file","暗号化保全ファイルの権限・link数が不正です。")}}
        if avatar {guard before.st_nlink==1,before.st_uid==geteuid(),before.st_mode & 0o077==0,before.st_size>0,before.st_size<=(leaf.contains(".original.") ? 4*1024*1024:1024*1024) else {throw NativeMigrationFailure("backup.avatar","写真ファイルの権限・サイズ・link数が不正です。")}}
        if (avatar || archive) && !forceCopy && fclonefileat(fd,pins,name,0)==0 {
            let copied=openat(pins,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard copied>=0 else {throw NativeMigrationFiles.io};defer{close(copied)}
            let state=try Self.info(copied)
            guard state.st_size==before.st_size,state.st_nlink==1,Self.signature(try Self.info(fd))==Self.signature(before) else {throw NativeMigrationFailure("backup.avatar","写真の複製中に入力が変更されました。")}
            return .init(name:name,signature:Self.signature(state),bytes:state.st_size,linked:false,cloned:true)
        }
        let linked = !forceCopy && !avatar && !archive && linkat(directory,leaf,pins,name,0)==0
        if linked {
            let pinned=openat(pins,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard pinned>=0 else {throw NativeMigrationFiles.io};defer{close(pinned)}
            let state=try Self.info(pinned)
            guard Self.signature(state)==Self.signature(before) else {throw NativeMigrationFailure("backup.changed","固定中にファイルの実体が変更されました。")}
            return .init(name:name,signature:Self.signature(state),bytes:state.st_size,linked:true,cloned:false)
        }
        guard forceCopy || avatar || archive || errno==EXDEV else {throw NativeMigrationFailure("backup.pin","ファイルのsnapshot参照を固定できません。")}
        let out=openat(pins,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard out>=0 else {throw NativeMigrationFiles.io};defer{close(out)}
        let copied=try Self.transfer(fd,to:out,cancelled:cancelled,progress:progress)
        guard Self.signature(try Self.info(fd))==Self.signature(before),copied.bytes==before.st_size,expectedSHA.map({$0==copied.sha256}) ?? true,fsync(out)==0 else {throw NativeMigrationFailure("backup.changed","固定中にファイルの内容が変更されました。")}
        let stored=try Self.info(out);return .init(name:name,signature:Self.signature(stored),bytes:stored.st_size,linked:false,cloned:false)
    }
    private static func transfer(_ fd:Int32,to output:Int32,cancelled:()->Bool,progress:()throws->Void)throws->(bytes:Int64,sha256:String) {
        var hash=SHA256(),count:Int64=0;var buffer=[UInt8](repeating:0,count:65536)
        while true{if cancelled(){throw CancellationError()};try progress();let n=Darwin.read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else {throw NativeMigrationFiles.io};if n==0{break};let chunk=Data(buffer.prefix(n));hash.update(data:chunk);try NativeMigrationImportWorkspace.write(chunk,to:output);count+=Int64(n)}
        return(count,hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    func copyPin(_ pin:String,signature:String,expectedBytes:Int64,expectedSHA:String?,cancelled:()->Bool,progress:()throws->Void)throws->(path:String,bytes:Int64,sha256:String) {
        guard NativeMigrationCodec.matches(#"\A[0-9a-f-]{36}\.pin\z"#,pin) else {throw NativeMigrationFiles.badPath}
        let fd=openat(pins,pin,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw NativeMigrationFiles.io};defer{close(fd)}
        guard Self.signature(try Self.info(fd))==signature else {throw NativeMigrationFailure("backup.changed","固定後にファイルが変更されました。")}
        let path="assets/"+NativeMigrationCodec.hash(Data(UUID().uuidString.utf8))+".blob",out=try output.create(path);defer{close(out)}
        let copied=try Self.transfer(fd,to:out,cancelled:cancelled,progress:progress)
        guard Self.signature(try Self.info(fd))==signature,copied.bytes==expectedBytes,expectedSHA.map({$0==copied.sha256}) ?? true,fsync(out)==0 else {throw NativeMigrationFailure("backup.hash","snapshotファイルのサイズ・hashが一致しません。")}
        guard lseek(out,0,SEEK_SET)==0 else {throw NativeMigrationFiles.io}
        var actual=SHA256(),bytes:Int64=0;var buffer=[UInt8](repeating:0,count:65536)
        while true{if cancelled(){throw CancellationError()};let n=Darwin.read(out,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else {throw NativeMigrationFiles.io};if n==0{break};actual.update(data:Data(buffer.prefix(n)));bytes+=Int64(n)}
        guard bytes==copied.bytes,actual.finalize().map({String(format:"%02x",$0)}).joined()==copied.sha256 else {throw NativeMigrationFailure("backup.readback","snapshotファイルのreadbackが一致しません。")}
        return(path,copied.bytes,copied.sha256)
    }
    func removePins() {
        let duplicate=dup(pins);guard duplicate>=0 else {return};guard let entries=fdopendir(duplicate) else {close(duplicate);return};defer{closedir(entries)};rewinddir(entries)
        while let entry=readdir(entries){let length=Int(entry.pointee.d_namlen)+1;let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:length){String(cString:$0)}};if NativeMigrationCodec.matches(#"\A[0-9a-f-]{36}\.pin\z"#,name){_ = unlinkat(pins,name,0)}}
        _ = unlinkat(output.root,"pins",AT_REMOVEDIR)
    }
}
