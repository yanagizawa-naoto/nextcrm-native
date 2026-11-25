import Foundation
import Darwin

/// A durable registry of only this component's unpublished maintenance attempts.
/// `mutationFence` must recheck the current authenticated administrator/session
/// inside the database transaction immediately surrounding each filesystem change.
final class NativeDataMaintenanceRecovery {
    typealias MutationFence = (_ body:()throws->Void)throws->Void
    typealias F = NativeDataMaintenanceRecoveryFiles
    static let purpose="local.nextcrm.data-maintenance.recovery.v1"
    let url:URL,owner:NativeDataMaintenanceRecoveryOwner
    fileprivate let fd:Int32,identity:NativeDataMaintenanceRecoveryIdentity
    fileprivate let authorize:()throws->Void,fence:MutationFence,checkpoint:((String)throws->Void)?,cancelled:()->Bool
    init(url:URL,authorize:@escaping()throws->Void,mutationFence:@escaping MutationFence,cancelled:@escaping()->Bool={false},checkpoint:((String)throws->Void)?=nil)throws {
        self.url=url;self.authorize=authorize;self.fence=mutationFence;self.cancelled=cancelled;self.checkpoint=checkpoint
        try authorize();try F.leaf(url.lastPathComponent)
        let parent=try F.directory(url.deletingLastPathComponent());defer{close(parent)}
        var made=false
        try mutationFence{try authorize();if cancelled(){throw CancellationError()};if mkdirat(parent,url.lastPathComponent,0o700)==0{made=true}else if errno != EEXIST{throw NativeDataMaintenanceRecoveryFailure.io}}
        let root=try F.directory(url)
        do {
            try F.privateDirectory(F.info(root))
            let lock=try F.openFile(root,".registry.lock",O_RDWR|(made ? O_CREAT|O_EXCL:0));defer{close(lock)}
            try checkpoint?("initializationLock")
            if cancelled() || Task.isCancelled{throw CancellationError()};try authorize()
            // Never block startup or termination behind another process. A busy
            // registry stays untouched and can be retried by a later invocation.
            guard flock(lock,LOCK_EX|LOCK_NB)==0 else{
                let code=errno
                if cancelled() || Task.isCancelled{throw CancellationError()}
                if code==EWOULDBLOCK || code==EAGAIN{throw NativeDataMaintenanceRecoveryFailure(code:"recovery.busy",message:"別の処理が作業記録を準備しています。今回は回収せず、記録とファイルを保持しました。")}
                throw NativeDataMaintenanceRecoveryFailure.io
            }
            defer{_ = flock(lock,LOCK_UN)}
            if cancelled() || Task.isCancelled{throw CancellationError()};try authorize()
            if made {
                let value=NativeDataMaintenanceRecoveryOwner(version:1,purpose:Self.purpose,id:UUID().uuidString.lowercased(),uid:geteuid())
                try mutationFence{try authorize();let out=try F.openFile(root,"owner.json",O_WRONLY|O_CREAT|O_EXCL);defer{close(out)};try F.write(JSONEncoder().encode(value),out);guard fsync(out)==0,fsync(root)==0,fsync(parent)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
                owner=value
            }else{owner=try F.decode(NativeDataMaintenanceRecoveryOwner.self,F.data(root,"owner.json",maximum:4096))}
            guard owner.version==1,owner.purpose==Self.purpose,owner.uid==geteuid(),F.uuid(owner.id) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            fd=root;identity=F.identity(try F.info(root))
        }catch{close(root);throw error}
    }
    deinit{close(fd)}
    fileprivate func check(_ point:String="check")throws {
        if cancelled() || Task.isCancelled{throw CancellationError()};try authorize();try checkpoint?(point);if cancelled() || Task.isCancelled{throw CancellationError()};try authorize()
        let current=try F.directory(url);defer{close(current)};try F.privateDirectory(F.info(current))
        guard F.identity(try F.info(current))==identity,try F.decode(NativeDataMaintenanceRecoveryOwner.self,F.data(current,"owner.json",maximum:4096))==owner else{throw NativeDataMaintenanceRecoveryFailure.changed}
    }
    fileprivate func mutate(_ point:String,_ body:()throws->Void)throws{try fence{try check(point);try body()}}
    fileprivate func lock(_ id:String,create:Bool)throws->Int32?{
        try check();guard F.uuid(id) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        let value=try F.openFile(fd,id+".lock",O_RDWR|(create ? O_CREAT|O_EXCL:0))
        guard flock(value,LOCK_EX|LOCK_NB)==0 else{let code=errno;close(value);if code==EWOULDBLOCK || code==EAGAIN{return nil};throw NativeDataMaintenanceRecoveryFailure.io};return value
    }
    func begin()throws->NativeDataMaintenanceRecoveryLease {
        var result:NativeDataMaintenanceRecoveryLease?
        try mutate("begin"){
            let id=UUID().uuidString.lowercased();guard let lock=try self.lock(id,create:true) else{throw NativeDataMaintenanceRecoveryFailure.io}
            let value=NativeDataMaintenanceRecoveryJournal(purpose:Self.purpose,registry:owner.id,id:id,uid:geteuid(),lock:F.identity(try F.info(lock)))
            do{let out=try F.openFile(fd,id+".journal",O_WRONLY|O_CREAT|O_EXCL);defer{close(out)};try F.write(try JSONEncoder().encode(value)+Data([10]),out);guard fsync(out)==0,fsync(fd)==0 else{throw NativeDataMaintenanceRecoveryFailure.io};result=try .init(registry:self,journal:value,lock:lock)}catch{close(lock);throw error}
        }
        return result!
    }
    fileprivate func validate(_ value:NativeDataMaintenanceRecoveryJournal,id:String)throws {
        guard value.version==1,value.purpose==Self.purpose,value.registry==owner.id,value.id==id,value.uid==geteuid(),value.sequence>=0,value.sequence<32,value.entries.count<=2,(value.sequence != 0 || value.entries.isEmpty),Set(value.entries.map(\.role)).count==value.entries.count else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        for e in value.entries {
            try F.leaf(e.name);guard F.uuid(e.nonce),e.parentPath.hasPrefix("/"),e.parentPath.utf8.count<=4096,e.parentPath.split(separator:"/").allSatisfy({$0 != "." && $0 != ".."}) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let prefix=e.role == .temporary ? "NextCRMMaintenance-":".nextcrm-pending-"
            guard e.name.hasPrefix(prefix),F.uuid(String(e.name.dropFirst(prefix.count))) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            if let destination=e.destinationName{try F.leaf(destination);guard e.role == .publication,destination != e.name else{throw NativeDataMaintenanceRecoveryFailure.unsafe}}
            if [.attached,.publishing,.published,.cleaning].contains(e.state){guard e.identity != nil else{throw NativeDataMaintenanceRecoveryFailure.unsafe}}
            if [.publishing,.published].contains(e.state){guard e.destinationName != nil else{throw NativeDataMaintenanceRecoveryFailure.unsafe}}
        }
    }
    fileprivate func read(_ id:String)throws->(NativeDataMaintenanceRecoveryJournal,Int) {
        let bytes=try F.data(fd,id+".journal",maximum:256*1024);var last:NativeDataMaintenanceRecoveryJournal?,start=bytes.startIndex,end=0
        for i in bytes.indices where bytes[i]==10 {
            guard i-start>0,i-start<=32768 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let next=try F.decode(NativeDataMaintenanceRecoveryJournal.self,Data(bytes[start..<i]));try validate(next,id:id)
            guard next.sequence==(last?.sequence ?? -1)+1 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            if let last {try transition(last,next)}
            last=next;start=bytes.index(after:i);end=start
        }
        guard let last,bytes.count-end<=32768 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        // A torn final append did not pass fsync, so the caller could not advance
        // to its next filesystem action. The prior complete state is authoritative.
        return(last,end)
    }
    private func transition(_ old:NativeDataMaintenanceRecoveryJournal,_ new:NativeDataMaintenanceRecoveryJournal)throws {
        guard old.lock==new.lock,new.entries.count>=old.entries.count,new.entries.count<=old.entries.count+1 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        for (a,b) in zip(old.entries,new.entries){
            guard a.role==b.role,a.parentPath==b.parentPath,a.name==b.name,a.parent==b.parent,a.nonce==b.nonce,a.identity==nil || a.identity==b.identity,a.destinationName==nil || a.destinationName==b.destinationName else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let allowed:[NativeDataMaintenanceRecoveryState:[NativeDataMaintenanceRecoveryState]]=[.planned:[.planned,.attached,.removed],.attached:[.attached,.publishing,.cleaning,.removed],.publishing:[.publishing,.published,.cleaning,.removed],.published:[.published],.cleaning:[.cleaning,.removed],.removed:[.removed]]
            guard allowed[a.state]!.contains(b.state) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        }
        if new.entries.count>old.entries.count{guard new.entries.last!.state == .planned else{throw NativeDataMaintenanceRecoveryFailure.unsafe}}
    }
    fileprivate func append(_ value:NativeDataMaintenanceRecoveryJournal,previous:NativeDataMaintenanceRecoveryJournal)throws {
        try validate(value,id:value.id);try transition(previous,value)
        let (current,complete)=try read(value.id);guard current==previous,value.sequence==previous.sequence+1 else{throw NativeDataMaintenanceRecoveryFailure.changed}
        let data=try JSONEncoder().encode(value)+Data([10]);guard complete+data.count<=256*1024 else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        let out=try F.openFile(fd,value.id+".journal",O_WRONLY);defer{close(out)}
        guard ftruncate(out,off_t(complete))==0,lseek(out,off_t(complete),SEEK_SET)==complete else{throw NativeDataMaintenanceRecoveryFailure.io}
        try F.write(data,out);guard fsync(out)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
    }
    /// Bounded page; selection scans only this private registry, never user folders.
    func recover(after:String?=nil,limit:Int=100)throws->NativeDataMaintenanceRecoveryPage {
        try check("scan");guard (1...100).contains(limit),after.map(F.uuid) ?? true else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        var selected:[String]=[],more=false
        try F.enumerate(fd){name in
            try self.check();guard name.hasSuffix(".journal") else{return};let id=String(name.dropLast(8));guard F.uuid(id) else{throw NativeDataMaintenanceRecoveryFailure.unsafe};guard after.map({id>$0}) ?? true else{return}
            selected.append(id);selected.sort();if selected.count>limit{selected.removeLast();more=true}
        }
        var items:[NativeDataMaintenanceRecoveryItem]=[]
        for id in selected {
            var lease:NativeDataMaintenanceRecoveryLease?
            do {
                try check("operation")
                guard let lock=try lock(id,create:false) else{items.append(.init(operation:id,status:.live,code:"recovery.live",message:"別の処理が使用中です。回収していません。"));continue}
                do{let value=try read(id).0;lease=try .init(registry:self,journal:value,lock:lock)}catch{close(lock);throw error}
                try lease!.recover();try lease!.finish()
                items.append(.init(operation:id,status:.recovered,code:"recovery.recovered",message:lease!.removedDirectories>0 ? "未公開の作業用フォルダを\(lease!.removedDirectories)件回収しました。公開済みの保存先は保持しています。":"残っていた作業記録を整理しました。公開済みの保存先は保持しています。",removedDirectories:lease!.removedDirectories))
            }catch is CancellationError{throw CancellationError()}
            catch {try authorize();let failure=error as? NativeDataMaintenanceRecoveryFailure;items.append(.init(operation:id,status:failure?.code=="recovery.io" ? .failed:.pending,code:failure?.code ?? "recovery.pending",message:failure?.message ?? "回収に必要な確認が完了していないため、記録を保持しました。",removedDirectories:lease?.removedDirectories ?? 0))}
        }
        try check();return .init(items:items,nextCursor:more ? selected.last:nil,hasMore:more)
    }
}

final class NativeDataMaintenanceRecoveryLease {
    typealias F = NativeDataMaintenanceRecoveryFiles
    let id:String
    private let registry:NativeDataMaintenanceRecovery,fd:Int32,lockIdentity:NativeDataMaintenanceRecoveryIdentity,mutex=NSRecursiveLock()
    private var value:NativeDataMaintenanceRecoveryJournal,finished=false
    fileprivate(set) var removedDirectories=0
    fileprivate init(registry:NativeDataMaintenanceRecovery,journal:NativeDataMaintenanceRecoveryJournal,lock:Int32)throws{let found=F.identity(try F.info(lock));guard found==journal.lock else{throw NativeDataMaintenanceRecoveryFailure.changed};self.registry=registry;value=journal;id=journal.id;fd=lock;lockIdentity=found}
    deinit{_ = flock(fd,LOCK_UN);close(fd)}
    private func check()throws{try registry.check();guard !finished,let st=try F.at(registry.fd,id+".lock"),F.identity(st)==lockIdentity,try registry.read(id).0==value else{throw NativeDataMaintenanceRecoveryFailure.changed}}
    private func mutate(_ point:String,_ body:()throws->Void)throws{try registry.mutate(point){try check();try body()}}
    private func update(_ body:(inout NativeDataMaintenanceRecoveryJournal)throws->Void)throws{var next=value;try body(&next);next.sequence+=1;try registry.append(next,previous:value);value=next}
    private func index(_ role:NativeDataMaintenanceRecoveryRole)throws->Int{guard let i=value.entries.firstIndex(where:{$0.role==role}) else{throw NativeDataMaintenanceRecoveryFailure.unsafe};return i}
    func plan(role:NativeDataMaintenanceRecoveryRole,parentURL:URL,name:String)throws {
        mutex.lock();defer{mutex.unlock()}
        try mutate("plan"){
            guard value.entries.count<2,!value.entries.contains(where:{$0.role==role}) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            try F.leaf(name);let prefix=role == .temporary ? "NextCRMMaintenance-":".nextcrm-pending-";guard name.hasPrefix(prefix),F.uuid(String(name.dropFirst(prefix.count))) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let parent=try F.directory(parentURL);defer{close(parent)};guard try F.at(parent,name)==nil else{throw NativeDataMaintenanceRecoveryFailure.changed}
            let entry=NativeDataMaintenanceRecoveryEntry(role:role,parentPath:parentURL.path,name:name,parent:F.identity(try F.info(parent)),nonce:UUID().uuidString.lowercased())
            try update{$0.entries.append(entry)}
        }
    }
    private func parent(_ e:NativeDataMaintenanceRecoveryEntry)throws->Int32{let fd=try F.directory(URL(fileURLWithPath:e.parentPath));guard F.identity(try F.info(fd))==e.parent else{close(fd);throw NativeDataMaintenanceRecoveryFailure.changed};return fd}
    private func marker(_ e:NativeDataMaintenanceRecoveryEntry)->NativeDataMaintenanceRecoveryMarker{.init(version:1,registry:registry.owner.id,operation:id,role:e.role,nonce:e.nonce,uid:geteuid())}
    private func markerValid(_ root:Int32,_ e:NativeDataMaintenanceRecoveryEntry)throws{guard try F.decode(NativeDataMaintenanceRecoveryMarker.self,F.data(root,F.marker,maximum:4096))==marker(e) else{throw NativeDataMaintenanceRecoveryFailure.changed}}
    func attach(role:NativeDataMaintenanceRecoveryRole)throws {
        mutex.lock();defer{mutex.unlock()}
        try mutate("attach"){
            let i=try index(role),e=value.entries[i];guard e.state == .planned else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let p=try parent(e);defer{close(p)};let root=openat(p,e.name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard root>=0 else{throw NativeDataMaintenanceRecoveryFailure.io};defer{close(root)}
            try F.privateDirectory(F.info(root));guard try F.empty(root) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let out=try F.openFile(root,F.marker,O_WRONLY|O_CREAT|O_EXCL);defer{close(out)};try F.write(JSONEncoder().encode(marker(e)),out)
            guard fsync(out)==0,fsync(root)==0,fsync(p)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
            let identity=F.identity(try F.info(root));try update{$0.entries[i].identity=identity;$0.entries[i].state = .attached}
        }
    }
    func beginPublication(destinationName:String)throws {
        mutex.lock();defer{mutex.unlock()}
        try mutate("publishing"){
            try F.leaf(destinationName);let i=try index(.publication),e=value.entries[i];guard e.state == .attached,destinationName != e.name else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let root=try openOwned(e);defer{close(root)};try markerValid(root,e)
            try update{$0.entries[i].destinationName=destinationName;$0.entries[i].state = .publishing}
        }
    }
    func didPublish()throws {
        mutex.lock();defer{mutex.unlock()}
        try mutate("published"){
            let i=try index(.publication),e=value.entries[i];guard e.state == .publishing,let name=e.destinationName else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let p=try parent(e);defer{close(p)};guard try F.at(p,e.name)==nil,let st=try F.at(p,name),F.identity(st)==e.identity else{throw NativeDataMaintenanceRecoveryFailure.changed}
            try update{$0.entries[i].state = .published}
        }
    }
    private func openOwned(_ e:NativeDataMaintenanceRecoveryEntry)throws->Int32 {
        let p=try parent(e);defer{close(p)};guard let st=try F.at(p,e.name),F.identity(st)==e.identity else{throw NativeDataMaintenanceRecoveryFailure.changed}
        try F.privateDirectory(st);let root=openat(p,e.name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard root>=0 else{throw NativeDataMaintenanceRecoveryFailure.io}
        guard try F.identity(F.info(root))==e.identity else{close(root);throw NativeDataMaintenanceRecoveryFailure.changed};return root
    }
    func cleanup(role:NativeDataMaintenanceRecoveryRole)throws {
        mutex.lock();defer{mutex.unlock()};try check();try clean(index(role))
    }
    private func clean(_ i:Int)throws {
        var e=value.entries[i]
        if e.state == .removed || e.state == .published{return}
        let p=try parent(e);defer{close(p)}
        if e.state == .publishing,let name=e.destinationName,let destination=try F.at(p,name),F.identity(destination)==e.identity {
            guard try F.at(p,e.name)==nil else{throw NativeDataMaintenanceRecoveryFailure.changed}
            try mutate("observedPublication"){try update{$0.entries[i].state = .published}};return
        }
        guard let st=try F.at(p,e.name) else {
            if e.state == .publishing,let name=e.destinationName,try F.at(p,name) != nil{throw NativeDataMaintenanceRecoveryFailure.changed}
            try mutate("absent"){try update{$0.entries[i].state = .removed}};return
        }
        try F.privateDirectory(st)
        if e.state == .planned {
            let root=openat(p,e.name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard root>=0 else{throw NativeDataMaintenanceRecoveryFailure.io};defer{close(root)}
            guard try F.at(root,F.marker) != nil else{throw NativeDataMaintenanceRecoveryFailure.changed};try markerValid(root,e);var onlyMarker=true;try F.enumerate(root){if $0 != F.marker{onlyMarker=false}};guard onlyMarker else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            try mutate("recoverAttach"){try update{$0.entries[i].identity=F.identity(st);$0.entries[i].state = .attached}};e=value.entries[i]
        }
        let root=try openOwned(e);defer{close(root)}
        func rootCheck()throws{try check();let again=try parent(e);defer{close(again)};guard let now=try F.at(again,e.name),F.identity(now)==e.identity else{throw NativeDataMaintenanceRecoveryFailure.changed};try F.privateDirectory(now)}
        let markerExists=try F.at(root,F.marker) != nil
        if !markerExists {guard e.state == .cleaning,try F.empty(root) else{throw NativeDataMaintenanceRecoveryFailure.changed}}
        else{try markerValid(root,e);try F.validateTree(root,check:rootCheck)}
        if e.state != .cleaning{try mutate("cleaning"){try rootCheck();try update{$0.entries[i].state = .cleaning}};e=value.entries[i]}
        try F.removeTree(root,rootCheck:{try rootCheck();try self.markerValid(root,e)},mutate:{body in try self.mutate("removeEntry",body)})
        try mutate("removeRoot"){
            try rootCheck()
            if try F.at(root,F.marker) != nil{try markerValid(root,e);guard unlinkat(root,F.marker,0)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
            guard unlinkat(p,e.name,AT_REMOVEDIR)==0 else{throw NativeDataMaintenanceRecoveryFailure.io};removedDirectories+=1;guard fsync(p)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
            try update{$0.entries[i].state = .removed}
        }
    }
    fileprivate func recover()throws{mutex.lock();defer{mutex.unlock()};try check();for i in value.entries.indices{try clean(i)}}
    func finish()throws {
        mutex.lock();defer{mutex.unlock()}
        try mutate("finish"){
            guard value.entries.allSatisfy({$0.state == .removed || $0.state == .published}) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            guard unlinkat(registry.fd,id+".journal",0)==0,fsync(registry.fd)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
            finished=true
            // Operation UUIDs are never reused. Waiters re-read the journal only
            // after obtaining this inode's lock, so an old lock cannot authorize work.
            _ = unlinkat(registry.fd,id+".lock",0);_ = fsync(registry.fd)
        }
    }
}
