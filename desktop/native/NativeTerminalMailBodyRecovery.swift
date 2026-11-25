import Foundation
import Darwin
import CryptoKit

/// Recovers only a known committed terminal job's exact published transport
/// body. Unknown/unpublished files and resumable/uncertain jobs are never owners.
/// One directory cursor is retained for the pass, never an array of filenames.
final class NativeTerminalMailBodyRecovery {
    struct Result {var scanned=0,removed=0,held=0,failed=0;var finished=false,readOnly=false}
    static let events:Set<String>=["invoice.email_requested","orders.approval_requested","orders.approval_decided","projects.task_assigned","projects.task_updated","projects.task_commented","crm.task_assigned","crm.task_watched","crm.lead_assigned","campaigns/send-step","reports.scheduled","crm.automation.kill.notice","crm.automation.recycle.notice"]
    private let db:NativeDatabase,checkpoint:(String)throws->Void
    private var parent:Int32 = -1,directory:Int32 = -1,entries:UnsafeMutablePointer<DIR>?,identity:stat?
    init(db:NativeDatabase,checkpoint:@escaping(String)throws->Void={_ in}){self.db=db;self.checkpoint=checkpoint}
    deinit{closePass()}
    private func closePass(){if let entries{closedir(entries)};entries=nil;if directory>=0{close(directory)};directory = -1;if parent>=0{close(parent)};parent = -1;identity=nil}
    private func openPass()throws->Bool {
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd>=0 else{throw NativeDBError.message("送信本文の保存先を確認できません。")}
        do {
            for component in db.url.deletingLastPathComponent().path.split(separator:"/") {
                guard component != ".",component != ".." else{throw NativeDBError.conflict}
                let next=openat(fd,String(component),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard next>=0 else{throw NativeDBError.conflict};close(fd);fd=next
            }
            var owner=stat();guard fstat(fd,&owner)==0,owner.st_uid==geteuid(),owner.st_mode & 0o077 == 0 else{throw NativeDBError.conflict}
            let child=openat(fd,"mail-outbox",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            if child<0 && errno==ENOENT{close(fd);return false}
            guard child>=0 else{throw NativeDBError.conflict}
            var info=stat();guard fstat(child,&info)==0,info.st_uid==geteuid(),info.st_mode & 0o077==0 else{close(child);throw NativeDBError.conflict}
            let duplicate=dup(child);guard duplicate>=0,let stream=fdopendir(duplicate) else{if duplicate>=0{close(duplicate)};close(child);throw NativeDBError.conflict}
            parent=fd;directory=child;entries=stream;identity=info;return true
        } catch{close(fd);throw error}
    }
    private func sameDirectory()->Bool {
        guard let expected=identity else{return false};var actual=stat()
        return fstatat(parent,"mail-outbox",&actual,AT_SYMLINK_NOFOLLOW)==0 && actual.st_mode & S_IFMT==S_IFDIR && actual.st_dev==expected.st_dev && actual.st_ino==expected.st_ino && actual.st_uid==geteuid() && actual.st_mode & 0o077==0
    }
    static func terminal(_ job:NativeJob)->Bool {
        guard events.contains(job.event) else{return false}
        let r=job.result
        if job.status=="cancelled" {
            return job.deliveryStartedAt==nil && r["providerID"]==nil && r["relayProviderIDHint"]==nil && (job.event != "campaigns/send-step" || !(r["cancelledBy"] ?? "").isEmpty)
        }
        guard job.status=="done" else{return false}
        if r["outcome"]=="skipped" {
            return job.event != "campaigns/send-step" && job.deliveryStartedAt==nil && r["providerID"]==nil && r["relayProviderIDHint"]==nil && !(r["reason"] ?? "").isEmpty
        }
        if let review=r["reviewOutcome"] {
            guard ["accepted","notSent","unknown"].contains(review),!(r["reviewedBy"] ?? "").isEmpty,
                  !(r["reviewNote"] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,date(r["reviewedAt"]),
                  ["failed","retry","needs_review"].contains(r["reviewPreviousStatus"] ?? "") else{return false}
            return review=="accepted" ? r["providerID"].flatMap(UUID.init(uuidString:)) != nil && r["outcome"]=="sent" : r["providerID"]==nil && r["outcome"]==(review=="notSent" ? "not_sent":"unconfirmed")
        }
        return (r["outcome"]==nil || r["outcome"]=="sent") && job.deliveryStartedAt != nil && r["providerID"].flatMap(UUID.init(uuidString:)) != nil && date(r["acceptedAt"])
    }
    private static func date(_ value:String?)->Bool {guard let value else{return false};let f=ISO8601DateFormatter();if f.date(from:value) != nil{return true};f.formatOptions.insert(.withFractionalSeconds);return f.date(from:value) != nil}
    private static func same(_ a:stat,_ b:stat)->Bool {a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec}
    private func reclaim(_ name:String,id:String)throws->Bool {
        try Task.checkCancellation()
        return try db.withCommittedMailBodyRecovery(id:id,events:Self.events.sorted()){job in
            guard Self.terminal(job),let digest=job.result["sha256"] ?? job.payload["sha256"],digest.utf8.count==64,digest.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
                  let raw=job.result["bytes"] ?? job.payload["bytes"],let count=Int(raw),count>=0,count<=InvoiceMail.maximumBytes,raw==String(count),self.sameDirectory() else{return false}
            let file=openat(self.directory,name,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);guard file>=0 else{if errno==ENOENT{return false};throw NativeDBError.conflict};defer{close(file)}
            var before=stat();guard fstat(file,&before)==0,before.st_mode & S_IFMT==S_IFREG,before.st_uid==geteuid(),before.st_mode & 0o077==0,before.st_size==count else{return false}
            try self.checkpoint("beforeHash");var hash=SHA256(),size=0,buffer=[UInt8](repeating:0,count:65536)
            while true {try Task.checkCancellation();let read=Darwin.read(file,&buffer,buffer.count);if read<0 && errno==EINTR{continue};guard read>=0 else{throw NativeDBError.conflict};if read==0{break};size+=read;guard size<=count else{return false};hash.update(data:Data(buffer.prefix(read)));try self.checkpoint("chunk")}
            guard size==count,hash.finalize().map({String(format:"%02x",$0)}).joined()==digest else{return false}
            try self.checkpoint("beforeUnlink");try Task.checkCancellation()
            var current=stat(),named=stat()
            guard self.sameDirectory(),fstat(file,&current)==0,Self.same(before,current),fstatat(self.directory,name,&named,AT_SYMLINK_NOFOLLOW)==0,named.st_mode & S_IFMT==S_IFREG,Self.same(current,named) else{return false}
            // Backup pins/clones remain valid: remove only this directory entry,
            // never truncate the inode and never follow a replaced symlink.
            guard unlinkat(self.directory,name,0)==0 else{throw NativeDBError.message("完了した送信本文を削除できませんでした。次の回収時に再確認します。")}
            return true
        } ?? false
    }
    func step(maximumEntries:Int=64)throws->Result {
        do{return try stepImpl(maximumEntries:maximumEntries)}catch{closePass();throw error}
    }
    func reset(){closePass()}
    private func stepImpl(maximumEntries:Int)throws->Result {
        guard !db.isReadOnly else{return .init(finished:true,readOnly:true)}
        try Task.checkCancellation();var result=Result()
        if entries==nil {if try !openPass(){return .init(finished:true)}}
        guard sameDirectory(),let entries else{closePass();throw NativeDBError.conflict}
        for _ in 0..<min(256,max(1,maximumEntries)) {
            try Task.checkCancellation();errno=0
            guard let entry=readdir(entries) else {guard errno==0 else{closePass();throw NativeDBError.conflict};closePass();result.finished=true;return result}
            result.scanned+=1
            let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(entry.pointee.d_namlen)+1){String(cString:$0)}}
            guard name.utf8.count==41,name.hasSuffix(".json"),let uuid=UUID(uuidString:String(name.dropLast(5))),uuid.uuidString.lowercased()+".json"==name else{result.held+=1;continue}
            do {if try reclaim(name,id:uuid.uuidString.lowercased()){result.removed+=1}else{result.held+=1}}
            catch is CancellationError {throw CancellationError()}
            catch {result.failed+=1}
        }
        return result
    }
}
