import Foundation
import Darwin
import CryptoKit

/// Owns only a freshly-created private directory. Directory descriptors fence
/// every file operation; cleanup never follows a link or replaces an old root.
final class NativeDataMaintenanceDirectory {
    let url:URL,fd:Int32
    private let parent:Int32,name:String,device:dev_t,inode:ino_t
    private var published=false
    var didPublish:Bool{published}
    init(parentURL:URL,name:String)throws {
        let parts=try NativeMigrationFiles.path(name);guard parts.count==1,name.utf8.count<=180 else{throw NativeMigrationFiles.badPath}
        parent=try NativeBackupWorkspace.openDirectory(parentURL);self.name=name;url=parentURL.appendingPathComponent(name,isDirectory:true)
        guard mkdirat(parent,name,0o700)==0 else{close(parent);throw NativeMigrationFailure("maintenance.exists","保存先が既に存在するか、新規フォルダを作成できません。別の名前を指定してください。")}
        let opened=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);var st=stat()
        guard opened>=0,fstat(opened,&st)==0 else{if opened>=0{close(opened)};_ = unlinkat(parent,name,AT_REMOVEDIR);close(parent);throw NativeMigrationFiles.io}
        fd=opened;device=st.st_dev;inode=st.st_ino
    }
    deinit{if !published{_ = cleanup()};close(fd);close(parent)}
    private func identity()throws {var st=stat();guard fstatat(parent,name,&st,AT_SYMLINK_NOFOLLOW)==0,st.st_mode&S_IFMT==S_IFDIR,st.st_dev==device,st.st_ino==inode else{throw NativeMigrationFailure("maintenance.changed","作業フォルダの識別情報が変更されています。")}}
    func validate()throws {
        try identity();let current=try NativeBackupWorkspace.openDirectory(url.deletingLastPathComponent());defer{close(current)};var a=stat(),b=stat()
        guard fstat(current,&a)==0,fstat(parent,&b)==0,a.st_dev==b.st_dev,a.st_ino==b.st_ino else{throw NativeMigrationFailure("maintenance.changed","保存先の親フォルダが変更されています。")}
    }
    static func enumerate(_ fd:Int32,_ visit:(String)throws->Void)throws {
        let copy=dup(fd);guard copy>=0 else{throw NativeMigrationFiles.io};guard let entries=fdopendir(copy)else{close(copy);throw NativeMigrationFiles.io};defer{closedir(entries)};rewinddir(entries)
        while let e=readdir(entries){let n=Int(e.pointee.d_namlen)+1;let name=withUnsafePointer(to:&e.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:n){String(cString:$0)}};if name != "." && name != ".."{try autoreleasepool{try visit(name)}}}
    }
    private static func removeContents(_ fd:Int32,depth:Int)throws {
        guard depth<=4 else{throw NativeMigrationFiles.badPath}
        try enumerate(fd){name in
            var st=stat();guard fstatat(fd,name,&st,AT_SYMLINK_NOFOLLOW)==0 else{throw NativeMigrationFiles.io}
            if st.st_mode&S_IFMT==S_IFDIR {
                let child=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard child>=0 else{throw NativeMigrationFiles.io};defer{close(child)}
                try removeContents(child,depth:depth+1);var current=stat()
                guard fstatat(fd,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==st.st_dev,current.st_ino==st.st_ino,unlinkat(fd,name,AT_REMOVEDIR)==0 else{throw NativeMigrationFiles.io}
            }else{guard unlinkat(fd,name,0)==0 else{throw NativeMigrationFiles.io}}
        }
    }
    @discardableResult func cleanup()->Bool {
        do{try Self.removeContents(fd,depth:0);try identity();return unlinkat(parent,name,AT_REMOVEDIR)==0 || errno==ENOENT}catch{return false}
    }
    func commit(to destination:URL)throws {
        try validate();guard destination.deletingLastPathComponent().path==url.deletingLastPathComponent().path else{throw NativeMigrationFiles.badPath}
        _ = try NativeMigrationFiles.path(destination.lastPathComponent)
        guard fsync(fd)==0 else{throw NativeMigrationFiles.io}
        guard renameatx_np(parent,name,parent,destination.lastPathComponent,UInt32(RENAME_EXCL))==0 else{throw NativeMigrationFailure("maintenance.publish","保存先を確定できません。既存の保存先は置き換えていません。")}
        // The directory is fully durable before the atomic publication. A parent
        // fsync error is surfaced; the caller owns rollback before exposing it.
        published=true
        guard fsync(parent)==0 else{throw NativeMigrationFiles.io}
        let current=try NativeBackupWorkspace.openDirectory(destination.deletingLastPathComponent());defer{close(current)};var a=stat(),b=stat()
        guard fstat(current,&a)==0,fstat(parent,&b)==0,a.st_dev==b.st_dev,a.st_ino==b.st_ino else{throw NativeMigrationFailure("maintenance.changed","公開中に保存先の親フォルダが変更されました。")}
        var target=stat();guard fstatat(current,destination.lastPathComponent,&target,AT_SYMLINK_NOFOLLOW)==0,target.st_dev==device,target.st_ino==inode else{throw NativeMigrationFailure("maintenance.changed","公開したフォルダが変更されました。")}
    }
    func rollbackPublished(at destination:URL)->Bool {
        var st=stat();guard fstatat(parent,destination.lastPathComponent,&st,AT_SYMLINK_NOFOLLOW)==0,st.st_mode&S_IFMT==S_IFDIR,st.st_dev==device,st.st_ino==inode else{return false}
        do{try Self.removeContents(fd,depth:0);return unlinkat(parent,destination.lastPathComponent,AT_REMOVEDIR)==0}catch{return false}
    }
}

struct NativeDataMaintenancePublication {
    let source:URL;let kind:NativeDataMaintenanceKind;let destination:NativeDataMaintenanceDirectory
    let check:()throws->Void
    func copy()throws {
        let input=try NativeMigrationFiles(root:source),sourceFD=try NativeBackupWorkspace.openDirectory(source);defer{close(sourceFD)}
        let flat=kind == .backup ? [".native-backup-candidate","database.sqlite","tables.ndjson","files.ndjson","snapshot.json"] : [".native-restore-candidate","crm.sqlite","tables.ndjson","files.ndjson","backup-snapshot.json","restore.json","resume-plan.ndjson"]
        func file(_ relative:String,_ parent:Int32,_ leaf:String)throws {
            try check();try destination.validate()
            let fd=openat(parent,leaf,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw NativeMigrationFiles.io};defer{close(fd)}
            let copied=try input.read(relative,cancelled:{false}){try check();try NativeMigrationImportWorkspace.write($0,to:fd)}
            guard fsync(fd)==0 else{throw NativeMigrationFiles.io}
            guard lseek(fd,0,SEEK_SET)==0 else{throw NativeMigrationFiles.io}
            var digest=SHA256(),bytes:Int64=0,buffer=[UInt8](repeating:0,count:65536)
            while true{try check();let n=Darwin.read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw NativeMigrationFiles.io};if n==0{break};digest.update(data:Data(buffer.prefix(n)));bytes+=Int64(n)}
            let readback=(bytes,digest.finalize().map{String(format:"%02x",$0)}.joined());try check()
            guard readback.0==copied.bytes,readback.1==copied.sha256 else{throw NativeMigrationFailure("maintenance.copy","保存先へのコピーを確認できません。")}
            if relative.hasPrefix("native-documents/") || relative.hasPrefix("native-avatars/"){guard fchmod(fd,0o400)==0 else{throw NativeMigrationFiles.io}}
        }
        for path in flat{try file(path,destination.fd,path)}
        for folder in kind == .backup ? ["assets"]:["assets"]+NativeRestoreWorkspace.names {
            try check();let from=openat(sourceFD,folder,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard from>=0 else{throw NativeMigrationFiles.io};defer{close(from)}
            guard mkdirat(destination.fd,folder,0o700)==0 else{throw NativeMigrationFiles.io};let target=openat(destination.fd,folder,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard target>=0 else{throw NativeMigrationFiles.io};defer{close(target)}
            try NativeDataMaintenanceDirectory.enumerate(from){leaf in
                if folder=="assets"{guard NativeMigrationCodec.matches(#"\A[0-9a-f]{64}\.blob\z"#,leaf) else{throw NativeMigrationFiles.badPath}}
                else{_ = try NativeRestoreWorkspace.path(folder+"/"+leaf)}
                try file(folder+"/"+leaf,target,leaf)
            }
            guard fsync(target)==0 else{throw NativeMigrationFiles.io}
        }
    }
}
