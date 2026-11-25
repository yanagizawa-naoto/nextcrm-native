import Foundation
import Darwin

/// No target-folder discovery. All target names come from the private journal.
enum NativeDataMaintenanceRecoveryFiles {
    static let marker=".nextcrm-maintenance-owner.json"
    static func uuid(_ value:String)->Bool{UUID(uuidString:value)?.uuidString.lowercased()==value}
    static func leaf(_ value:String)throws {
        guard !value.isEmpty,value != ".",value != "..",value.utf8.count<=255,!value.contains("/"),!value.contains("\\"),!value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
    }
    static func directory(_ url:URL)throws->Int32 {
        guard url.isFileURL,url.path.hasPrefix("/"),url.path.utf8.count<=4096 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else{throw NativeDataMaintenanceRecoveryFailure.io}
        do{for part in url.path.split(separator:"/"){let name=String(part);try leaf(name);let next=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else{throw NativeDataMaintenanceRecoveryFailure.unsafe};close(fd);fd=next};return fd}catch{close(fd);throw error}
    }
    static func info(_ fd:Int32)throws->stat{var st=stat();guard fstat(fd,&st)==0 else{throw NativeDataMaintenanceRecoveryFailure.io};return st}
    static func identity(_ st:stat)->NativeDataMaintenanceRecoveryIdentity{.init(device:UInt64(bitPattern:Int64(st.st_dev)),inode:UInt64(st.st_ino))}
    static func at(_ fd:Int32,_ name:String)throws->stat?{var st=stat();if fstatat(fd,name,&st,AT_SYMLINK_NOFOLLOW)==0{return st};if errno==ENOENT{return nil};throw NativeDataMaintenanceRecoveryFailure.io}
    static func privateDirectory(_ st:stat)throws{guard st.st_mode&S_IFMT==S_IFDIR,st.st_uid==geteuid(),st.st_mode & 0o077==0 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}}
    static func privateFile(_ st:stat)throws{guard st.st_mode&S_IFMT==S_IFREG,st.st_uid==geteuid(),st.st_mode & 0o077==0,st.st_nlink==1 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}}
    static func openFile(_ parent:Int32,_ name:String,_ flags:Int32)throws->Int32{
        let fd=openat(parent,name,flags|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC,0o600);guard fd>=0 else{throw NativeDataMaintenanceRecoveryFailure.io}
        do{try privateFile(info(fd));return fd}catch{close(fd);throw error}
    }
    static func write(_ data:Data,_ fd:Int32)throws {
        try data.withUnsafeBytes{raw in var offset=0;while offset<raw.count{let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw NativeDataMaintenanceRecoveryFailure.io};offset+=n}}
    }
    static func data(_ parent:Int32,_ name:String,maximum:Int)throws->Data{
        let fd=try openFile(parent,name,O_RDONLY);defer{close(fd)};let before=try info(fd)
        guard before.st_size>=0,before.st_size<=maximum else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        var result=Data(),buffer=[UInt8](repeating:0,count:8192)
        while true{let n=Darwin.read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0,result.count+n<=maximum else{throw NativeDataMaintenanceRecoveryFailure.unsafe};if n==0{break};result.append(contentsOf:buffer.prefix(n))}
        let after=try info(fd);guard let current=try at(parent,name),identity(current)==identity(before),identity(after)==identity(before),after.st_size==before.st_size,after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,result.count==before.st_size else{throw NativeDataMaintenanceRecoveryFailure.changed};return result
    }
    static func decode<T:Decodable>(_ type:T.Type,_ data:Data)throws->T{_ = try NativeMigrationJSON.parse(data);return try JSONDecoder().decode(type,from:data)}
    static func enumerate(_ fd:Int32,_ visit:(String)throws->Void)throws{
        let copied=dup(fd);guard copied>=0 else{throw NativeDataMaintenanceRecoveryFailure.io};guard let dir=fdopendir(copied)else{close(copied);throw NativeDataMaintenanceRecoveryFailure.io};defer{closedir(dir)};rewinddir(dir)
        while let e=readdir(dir){let count=Int(e.pointee.d_namlen)+1;let name=withUnsafePointer(to:&e.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:count){String(cString:$0)}};if name != "." && name != ".."{try autoreleasepool{try leaf(name);try visit(name)}}}
    }
    static func empty(_ fd:Int32)throws->Bool{var value=true;try enumerate(fd){_ in value=false};return value}
    static func validateTree(_ fd:Int32,depth:Int=0,check:()throws->Void)throws{
        guard depth<=6 else{throw NativeDataMaintenanceRecoveryFailure.unsafe};try check();try privateDirectory(info(fd))
        try enumerate(fd){name in try check();guard let st=try at(fd,name),st.st_uid==geteuid(),st.st_mode & 0o077==0 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            if st.st_mode&S_IFMT==S_IFDIR{let child=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard child>=0 else{throw NativeDataMaintenanceRecoveryFailure.io};defer{close(child)};guard try identity(info(child))==identity(st) else{throw NativeDataMaintenanceRecoveryFailure.changed};try validateTree(child,depth:depth+1,check:check)}
            else{guard st.st_mode&S_IFMT==S_IFREG else{throw NativeDataMaintenanceRecoveryFailure.unsafe}} // unlinking an owned pin preserves its other inode references
        }
    }
    static func removeTree(_ fd:Int32,depth:Int=0,rootCheck:@escaping()throws->Void,mutate:(_ body:()throws->Void)throws->Void)throws{
        guard depth<=6 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        try enumerate(fd){name in
            if depth==0 && name==marker{return}
            try rootCheck();guard let before=try at(fd,name) else{throw NativeDataMaintenanceRecoveryFailure.changed}
            if before.st_mode&S_IFMT==S_IFDIR{
                let child=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard child>=0 else{throw NativeDataMaintenanceRecoveryFailure.io};defer{close(child)}
                try privateDirectory(info(child));guard try identity(info(child))==identity(before) else{throw NativeDataMaintenanceRecoveryFailure.changed}
                try removeTree(child,depth:depth+1,rootCheck:{try rootCheck();guard let current=try at(fd,name),identity(current)==identity(before) else{throw NativeDataMaintenanceRecoveryFailure.changed}},mutate:mutate)
                try mutate{try rootCheck();guard let current=try at(fd,name),identity(current)==identity(before),unlinkat(fd,name,AT_REMOVEDIR)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
            }else{
                guard before.st_mode&S_IFMT==S_IFREG,before.st_uid==geteuid(),before.st_mode & 0o077==0 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
                try mutate{try rootCheck();guard let current=try at(fd,name),identity(current)==identity(before),unlinkat(fd,name,0)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
            }
        }
    }
}
