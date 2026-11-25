import Foundation
import Darwin
import CryptoKit

/// New producer-owned preparations only. Never adopts legacy mail-outbox or
/// report-staging paths. A live flock spans every writer/request callback.
enum NativeMailPreparationFiles {
    enum Kind:String,Codable {case plugin,report}
    struct Identity:Codable,Equatable {let device:UInt64,inode:UInt64;init(_ s:stat){device=UInt64(s.st_dev);inode=UInt64(s.st_ino)}}
    struct Owner:Codable {let version:Int,kind:Kind,uid:UInt32,id:String;let parent:Identity,root:Identity,directory:Identity,lease:Identity}
    struct Publication:Codable {let version:Int,jobID:String,jobLease:String,sha256:String,bytes:Int;let body:Identity,finalDirectory:Identity}
    static let namespace="mail-preparations-v1"
    static let failure=NativeDBError.message("メールの準備ファイルを確認できません。処理中のファイルは保持します。")
    struct Busy:LocalizedError{var errorDescription:String?{"メールの準備領域を別の処理が使用しています。次の実行時に再確認します。"}}
    static let busy=Busy()
    static func info(_ fd:Int32)throws->stat{var s=stat();guard fstat(fd,&s)==0 else{throw failure};return s}
    static func at(_ fd:Int32,_ name:String)throws->stat?{var s=stat();if fstatat(fd,name,&s,AT_SYMLINK_NOFOLLOW)==0{return s};if errno==ENOENT{return nil};throw failure}
    static func directory(_ s:stat)->Bool{s.st_mode & S_IFMT==S_IFDIR && s.st_uid==geteuid() && s.st_mode & 0o077==0}
    static func file(_ s:stat,linked:Bool=false)->Bool{s.st_mode & S_IFMT==S_IFREG && s.st_uid==geteuid() && s.st_mode & 0o077==0 && (linked || s.st_nlink==1)}
    static func same(_ fd:Int32,_ name:String,_ identity:Identity)throws->Bool{try at(fd,name).map{Identity($0)==identity} ?? false}
    static func lock(_ fd:Int32)throws->Bool{while flock(fd,LOCK_EX|LOCK_NB) != 0{if errno==EINTR{continue};if errno==EWOULDBLOCK{return false};throw failure};return true}
    static func openDirectory(_ path:URL)throws->Int32 {
        guard path.isFileURL,let resolved=realpath(path.path,nil) else{throw failure};let text=String(cString:resolved);free(resolved)
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw failure}
        do{for part in text.split(separator:"/"){let next=openat(fd,String(part),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else{throw failure};close(fd);fd=next};return fd}catch{close(fd);throw error}
    }
    static func write<T:Encodable>(_ value:T,fd:Int32)throws {
        let data=try JSONEncoder().encode(value);guard data.count<=4096 else{throw failure}
        try data.withUnsafeBytes{b in var offset=0;while offset<b.count{let n=Darwin.write(fd,b.baseAddress!.advanced(by:offset),b.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw failure};offset+=n}}
        guard fsync(fd)==0 else{throw failure}
    }
    static func read<T:Decodable>(_ type:T.Type,fd:Int32)throws->T {
        let before=try info(fd);guard file(before),(1...4096).contains(before.st_size) else{throw failure}
        var bytes=[UInt8](repeating:0,count:Int(before.st_size)),offset=0
        while offset<bytes.count{let n=bytes.withUnsafeMutableBytes{pread(fd,$0.baseAddress!.advanced(by:offset),$0.count-offset,off_t(offset))};if n<0 && errno==EINTR{continue};guard n>0 else{throw failure};offset+=n}
        let after=try info(fd);guard Identity(before)==Identity(after),before.st_size==after.st_size,before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec else{throw failure}
        return try JSONDecoder().decode(type,from:Data(bytes))
    }
    static func names(_ fd:Int32)throws->[String] {
        let copy=openat(fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard copy>=0 else{throw failure}
        guard let stream=fdopendir(copy) else{close(copy);throw failure};defer{closedir(stream)};var result:[String]=[]
        while let name=try next(stream){guard result.count<8 else{throw failure};result.append(name)};return result
    }
    static func next(_ stream:UnsafeMutablePointer<DIR>)throws->String? {
        while true{errno=0;guard let e=readdir(stream)else{if errno != 0{throw failure};return nil};let name=withUnsafePointer(to:&e.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(e.pointee.d_namlen)+1){String(cString:$0)}};if name != "." && name != ".."{return name}}
    }
    final class Root {
        let base:URL,url:URL,parent:Int32,fd:Int32,lockFD:Int32,parentID:Identity,rootID:Identity,lockID:Identity
        init(_ base:URL,create:Bool)throws {
            self.base=base;url=base.appendingPathComponent(namespace);let p=try openDirectory(base);var r:Int32 = -1,l:Int32 = -1
            do{guard directory(try info(p)) else{throw failure};if create && mkdirat(p,namespace,0o700) != 0 && errno != EEXIST{throw failure}
                r=openat(p,namespace,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard r>=0,directory(try info(r)) else{throw failure}
                l=openat(r,".lock",O_RDWR|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(create ? O_CREAT:0),0o600);guard l>=0,file(try info(l)) else{throw failure}
                parent=p;fd=r;lockFD=l;parentID=Identity(try info(p));rootID=Identity(try info(r));lockID=Identity(try info(l))
            }catch{if l>=0{close(l)};if r>=0{close(r)};close(p);throw error}
        }
        deinit{close(lockFD);close(fd);close(parent)}
        func validate()throws{let current=try openDirectory(base);defer{close(current)};guard Identity(try info(current))==parentID,try same(parent,namespace,rootID),try same(fd,".lock",lockID),directory(try info(fd)),file(try info(lockFD)) else{throw failure}}
    }
    final class Lease {
        let id:String,url:URL,kind:Kind
        fileprivate let root:Root,fd:Int32,lease:Int32,owner:Owner
        fileprivate var resolved=false
        fileprivate init(root:Root,fd:Int32,lease:Int32,owner:Owner){self.root=root;self.fd=fd;self.lease=lease;self.owner=owner;id=owner.id;kind=owner.kind;url=root.url.appendingPathComponent(id)}
        deinit{if (try? lock(root.lockFD))==true{defer{flock(root.lockFD,LOCK_UN)};_ = try? remove(root:root,fd:fd,lease:lease,owner:owner,publicationResolved:resolved)};close(lease);close(fd)}
        /// Called inside the current job transaction, after all fresh authority /
        /// snapshot checks. Durable intent precedes the first final-directory link.
        func publish(_ body:InvoiceMailBody,job:NativeJob,db:NativeDatabase,checkpoint:(String)throws->Void={_ in})throws {
            guard kind == .report,job.event=="reports.scheduled",UUID(uuidString:job.id) != nil,let token=job.leaseToken,!token.isEmpty,db.url.deletingLastPathComponent().path==root.base.path else{throw failure}
            guard try lock(root.lockFD) else{throw busy};defer{flock(root.lockFD,LOCK_UN)};try validate(root:root,fd:fd,lease:lease,owner:owner)
            let staging=openat(fd,"mail-outbox",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard staging>=0 else{throw failure};defer{close(staging)}
            let source=id+".json";guard let info=try at(staging,source),file(info),body.url.path==url.appendingPathComponent("mail-outbox/"+source).path else{throw failure}
            try InvoiceMail.verify(body.url,sha256:body.sha256,bytes:body.bytes)
            if mkdirat(root.parent,"mail-outbox",0o700) != 0 && errno != EEXIST{throw failure}
            let final=openat(root.parent,"mail-outbox",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard final>=0,directory(try selfInfo(final)) else{if final>=0{close(final)};throw failure};defer{close(final)}
            let intent=Publication(version:1,jobID:job.id,jobLease:token,sha256:body.sha256,bytes:body.bytes,body:Identity(info),finalDirectory:Identity(try selfInfo(final)))
            let marker=openat(fd,".publication",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard marker>=0 else{throw failure};defer{close(marker)}
            try write(intent,fd:marker);guard fsync(fd)==0,fsync(root.parent)==0 else{throw failure};try checkpoint("intent")
            guard linkat(staging,source,final,job.id.lowercased()+".json",0)==0 else{throw failure}
            // Register before any later throwing checkpoint/DB result write.
            db.deferUntilTransactionEnds(onCommit:{[self] in resolved=true},onRollback:{[self] in
                if (try? reconcile(root:root,fd:fd,owner:owner,intent:intent,db:db))==true{resolved=true}
            })
            guard fsync(final)==0 else{throw failure};try checkpoint("linked")
        }
        private func selfInfo(_ fd:Int32)throws->stat{try NativeMailPreparationFiles.info(fd)}
    }
    static func create(_ kind:Kind,root base:URL)throws->Lease {
        let root=try Root(base,create:true);guard try lock(root.lockFD) else{throw busy};defer{flock(root.lockFD,LOCK_UN)};try root.validate()
        let id=UUID().uuidString.lowercased();guard mkdirat(root.fd,id,0o700)==0 else{throw failure}
        let d=openat(root.fd,id,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard d>=0 else{throw failure};var l:Int32 = -1
        do{l=openat(d,".lease",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard l>=0,try lock(l) else{throw busy}
            let owner=Owner(version:1,kind:kind,uid:geteuid(),id:id,parent:root.parentID,root:root.rootID,directory:Identity(try info(d)),lease:Identity(try info(l)))
            try write(owner,fd:l);guard fsync(d)==0,fsync(root.fd)==0 else{throw failure};return Lease(root:root,fd:d,lease:l,owner:owner)
        }catch{if l>=0{close(l)};close(d);throw error}
    }
    static func validate(root:Root,fd:Int32,lease:Int32,owner:Owner)throws {
        try root.validate();guard owner.version==1,owner.uid==geteuid(),UUID(uuidString:owner.id)?.uuidString.lowercased()==owner.id,owner.parent==root.parentID,owner.root==root.rootID,
            directory(try info(fd)),file(try info(lease)),Identity(try info(fd))==owner.directory,Identity(try info(lease))==owner.lease,try same(root.fd,owner.id,owner.directory),try same(fd,".lease",owner.lease) else{throw failure}
    }
    static func reportTemporary(_ name:String)->Bool{guard name.hasPrefix(".nextcrm-report-"),name.hasSuffix(".tmp") else{return false};return UUID(uuidString:String(name.dropFirst(16).dropLast(4))) != nil}
    /// Preflight the bounded allow-list before deleting anything. The durable,
    /// private directory lease owns only these newly generated producer names.
    static func remove(root:Root,fd:Int32,lease:Int32,owner:Owner,publicationResolved:Bool)throws->Bool {
        try validate(root:root,fd:fd,lease:lease,owner:owner)
        var files:[(Int32,String,Identity)]=[],outbox:Int32 = -1,outboxID:Identity?
        defer{if outbox>=0{close(outbox)}}
        for name in try names(fd){
            if name==".lease"{continue}
            if name==".publication"{guard owner.kind == .report,publicationResolved,let s=try at(fd,name),file(s) else{throw failure};files.append((fd,name,Identity(s)));continue}
            if name=="mail-outbox"{outbox=openat(fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard outbox>=0,directory(try info(outbox)) else{throw failure};outboxID=Identity(try info(outbox))
                for body in try names(outbox){guard body==owner.id+".json",let s=try at(outbox,body),file(s,linked:owner.kind == .report) else{throw failure};files.append((outbox,body,Identity(s)))};continue}
            guard owner.kind == .report,(name=="report.csv" || name=="report.pdf" || reportTemporary(name)),let s=try at(fd,name),file(s) else{throw failure};files.append((fd,name,Identity(s)))
        }
        for (parent,name,id) in files{guard try same(parent,name,id) else{throw failure}}
        for (parent,name,id) in files{guard try same(parent,name,id),unlinkat(parent,name,0)==0 else{throw failure}}
        if let outboxID{guard try same(fd,"mail-outbox",outboxID),unlinkat(fd,"mail-outbox",AT_REMOVEDIR)==0 else{throw failure}}
        guard try same(fd,".lease",owner.lease),unlinkat(fd,".lease",0)==0,try same(root.fd,owner.id,owner.directory),unlinkat(root.fd,owner.id,AT_REMOVEDIR)==0 else{throw failure};return true
    }
    /// Lease is held by the caller or collector. Never erase a published final
    /// body; a dead unpublished intent may erase only its exact linked inode.
    static func reconcile(root:Root,fd:Int32,owner:Owner,intent:Publication,db:NativeDatabase)throws->Bool {
        try root.validate()
        guard Identity(try info(fd))==owner.directory,try same(root.fd,owner.id,owner.directory),try same(fd,".lease",owner.lease) else{return false}
        guard owner.kind == .report,intent.version==1,UUID(uuidString:intent.jobID)?.uuidString.lowercased()==intent.jobID.lowercased(),!intent.jobLease.isEmpty,intent.sha256.count==64,intent.bytes>=0,intent.bytes<=InvoiceMail.maximumBytes else{return false}
        return try db.withCommittedReportPreparationRecovery(id:intent.jobID){job in
            let final=openat(root.parent,"mail-outbox",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard final>=0 else{return false};defer{close(final)}
            guard directory(try info(final)),Identity(try info(final))==intent.finalDirectory else{return false}
            let name=intent.jobID.lowercased()+".json",published=job.result["sha256"]==intent.sha256 && job.result["bytes"]==String(intent.bytes)
            if let hash=job.result["sha256"],hash != intent.sha256{return false}
            guard published || (job.result["sha256"]==nil && job.deliveryStartedAt==nil && job.result["providerID"]==nil && job.result["relayProviderIDHint"]==nil && ["pending","running","retry","failed","cancelled","done"].contains(job.status)) else{return false}
            guard let named=try at(final,name) else{return !published || NativeTerminalMailBodyRecovery.terminal(job)}
            guard file(named,linked:true),Identity(named)==intent.body,named.st_size==intent.bytes else{return false}
            let source=openat(final,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);guard source>=0 else{return false};defer{close(source)}
            guard Identity(try info(source))==intent.body else{return false}
            var digest=SHA256(),buffer=[UInt8](repeating:0,count:65536),count=0
            while true{try Task.checkCancellation();let n=Darwin.read(source,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw failure};if n==0{break};count+=n;guard count<=intent.bytes else{return false};digest.update(data:Data(buffer.prefix(n)))}
            guard count==intent.bytes,digest.finalize().map({String(format:"%02x",$0)}).joined()==intent.sha256,try same(final,name,intent.body) else{return false}
            if published{return true};try Task.checkCancellation();guard unlinkat(final,name,0)==0 else{throw failure};return true
        } ?? false
    }
    struct Page{var examined=0,removed=0,live=0,preserved=0;var busy=false,finished=false}
    final class Recovery {
        let db:NativeDatabase
        private let root:Root,stream:UnsafeMutablePointer<DIR>
        private var finished=false
        init(db:NativeDatabase)throws{guard !db.isReadOnly else{throw failure};self.db=db;root=try Root(db.url.deletingLastPathComponent(),create:false);let fd=openat(root.fd,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else{throw failure};guard let value=fdopendir(fd)else{close(fd);throw failure};stream=value}
        deinit{closedir(stream)}
        func step(maximumEntries:Int=64)throws->Page {
            guard !db.isReadOnly else{return .init(finished:true)};guard (1...256).contains(maximumEntries) else{throw failure};if finished{return .init(finished:true)}
            var page=Page();guard try lock(root.lockFD)else{page.busy=true;return page};defer{flock(root.lockFD,LOCK_UN)};try root.validate()
            while page.examined<maximumEntries{try Task.checkCancellation();guard let name=try next(stream)else{finished=true;page.finished=true;break};page.examined+=1
                if name==".lock"{continue};guard UUID(uuidString:name)?.uuidString.lowercased()==name else{page.preserved+=1;continue}
                let d=openat(root.fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard d>=0 else{page.preserved+=1;continue};defer{close(d)}
                let l=openat(d,".lease",O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);guard l>=0 else{page.preserved+=1;continue};defer{close(l)}
                guard file(try info(l)) else{page.preserved+=1;continue};guard try lock(l) else{page.live+=1;continue}
                do{let owner=try read(Owner.self,fd:l);try validate(root:root,fd:d,lease:l,owner:owner)
                    var resolved=false
                    if try at(d,".publication") != nil{let marker=openat(d,".publication",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);guard marker>=0 else{throw failure};defer{close(marker)}
                        let intent=try read(Publication.self,fd:marker);guard try reconcile(root:root,fd:d,owner:owner,intent:intent,db:db) else{throw failure};resolved=true}
                    if try remove(root:root,fd:d,lease:l,owner:owner,publicationResolved:resolved){page.removed+=1}
                }catch is CancellationError{throw CancellationError()}catch{page.preserved+=1}
            };return page
        }
    }
}
