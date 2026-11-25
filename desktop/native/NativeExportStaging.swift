import Foundation
import Darwin

/// Registry owns only private, explicitly journaled staging directories. It
/// never discovers names in a user's selected parent or owns published results.
final class NativeExportStagingRegistry {
    typealias F = NativeDataMaintenanceRecoveryFiles
    typealias Fence = NativeDataMaintenanceRecovery.MutationFence
    let recovery:NativeDataMaintenanceRecovery
    let authorize:()throws->Void, fence:Fence, cancelled:()->Bool
    /// Preserve macOS's root-owned /var and /tmp aliases without accepting
    /// arbitrary symlinks in the selected parent's remaining components.
    static func systemAlias(_ url:URL)throws->URL {
        guard url.isFileURL else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        for (alias,target) in [("/var","/private/var"),("/tmp","/private/tmp")] where url.path==alias || url.path.hasPrefix(alias+"/") {
            var st=stat();guard lstat(alias,&st)==0,st.st_uid==0,st.st_mode&S_IFMT==S_IFLNK else{return url}
            var bytes=[CChar](repeating:0,count:128);let n=readlink(alias,&bytes,bytes.count)
            guard n>0,n<bytes.count else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            let link=String(decoding:bytes.prefix(n).map{UInt8(bitPattern:$0)},as:UTF8.self)
            guard link==target || link==String(target.dropFirst()) else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
            return URL(fileURLWithPath:target+String(url.path.dropFirst(alias.count)),isDirectory:true)
        }
        return url
    }
    init(url:URL,authorize:@escaping()throws->Void,mutationFence:@escaping Fence,cancelled:@escaping()->Bool={false})throws {
        self.authorize=authorize;fence=mutationFence;self.cancelled=cancelled
        // Cancellation governs producing/publishing. Cleanup must still run
        // after the actual writer joined; fresh authority remains mandatory.
        recovery=try NativeDataMaintenanceRecovery(url:try Self.systemAlias(url),authorize:authorize,mutationFence:mutationFence)
    }
    func work()throws {try authorize();if cancelled() || Task.isCancelled{throw CancellationError()}}
    func mutate(_ body:()throws->Void)throws {try fence{try work();try body()}}
    func begin(parent:URL)throws->NativeExportStaging {try work();return try NativeExportStaging(registry:self,parent:try Self.systemAlias(parent))}
    func recover(after:String?=nil,limit:Int=100)throws->NativeDataMaintenanceRecoveryPage {try work();return try recovery.recover(after:after,limit:limit)}
}

private final class NativeExportFinishResult {var value:Result<Void,Error>?}

/// Caller owns every writer/codec handle and must cancel+join it, close its
/// content descriptors, then call finish. Deinit only releases FDs/lease. A
/// process crash leaves a durable registry entry, not a prefix-based guess.
final class NativeExportStaging {
    typealias F = NativeDataMaintenanceRecoveryFiles
    let directoryURL:URL
    private let registry:NativeExportStagingRegistry,lease:NativeDataMaintenanceRecoveryLease
    private let parent:Int32,root:Int32,name:String,parentID:NativeDataMaintenanceRecoveryIdentity,rootID:NativeDataMaintenanceRecoveryIdentity
    private let marker:Data,registryID:NativeDataMaintenanceRecoveryIdentity,lockID:NativeDataMaintenanceRecoveryIdentity
    private let mutex=NSRecursiveLock()
    private var finished=false
    fileprivate init(registry:NativeExportStagingRegistry,parent parentURL:URL)throws {
        self.registry=registry
        let p=try F.directory(parentURL);var r:Int32 = -1
        let operation:NativeDataMaintenanceRecoveryLease
        do{operation=try registry.recovery.begin()}catch{close(p);throw error};lease=operation
        let folderName="NextCRMMaintenance-"+UUID().uuidString.lowercased();name=folderName;directoryURL=parentURL.appendingPathComponent(folderName,isDirectory:true)
        do {
            try operation.plan(role:.temporary,parentURL:parentURL,name:name)
            try registry.mutate{guard mkdirat(p,folderName,0o700)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}}
            r=openat(p,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard r>=0 else{throw NativeDataMaintenanceRecoveryFailure.io}
            try F.privateDirectory(F.info(r));try operation.attach(role:.temporary)
            marker=try F.data(r,F.marker,maximum:4096)
            let reg=try F.directory(registry.recovery.url);defer{close(reg)}
            guard let lock=try F.at(reg,operation.id+".lock") else{throw NativeDataMaintenanceRecoveryFailure.changed}
            registryID=F.identity(try F.info(reg));lockID=F.identity(lock)
            parentID=F.identity(try F.info(p));rootID=F.identity(try F.info(r));parent=p;root=r
        } catch {if r>=0{close(r)};close(p);throw error}
    }
    deinit {close(root);close(parent)}
    private func validate()throws {
        guard !finished else{throw NativeDataMaintenanceRecoveryFailure.changed}
        try registry.work()
        let p=try F.directory(directoryURL.deletingLastPathComponent());defer{close(p)}
        guard F.identity(try F.info(p))==parentID,let current=try F.at(parent,name),F.identity(current)==rootID,F.identity(try F.info(root))==rootID else{throw NativeDataMaintenanceRecoveryFailure.changed}
        try F.privateDirectory(current)
        guard try F.data(root,F.marker,maximum:4096)==marker else{throw NativeDataMaintenanceRecoveryFailure.changed}
        let reg=try F.directory(registry.recovery.url);defer{close(reg)}
        guard F.identity(try F.info(reg))==registryID,let lock=try F.at(reg,lease.id+".lock"),F.identity(lock)==lockID else{throw NativeDataMaintenanceRecoveryFailure.changed}
    }
    /// Use for codecs that create an initially absent output themselves. Only
    /// safe single-component names are returned; symlink traversal is forbidden.
    func unusedContentURL(named filename:String)throws->URL {
        mutex.lock();defer{mutex.unlock()};try validate();try F.leaf(filename)
        guard filename != F.marker,try F.at(root,filename)==nil else{throw NativeDataMaintenanceRecoveryFailure.changed}
        return directoryURL.appendingPathComponent(filename)
    }
    /// The caller must close this FD before finish/releasing the lease.
    func createContent(named filename:String)throws->Int32 {
        mutex.lock();defer{mutex.unlock()};_ = try unusedContentURL(named:filename)
        var result:Int32 = -1
        try registry.mutate{try validate();result=try F.openFile(root,filename,O_RDWR|O_CREAT|O_EXCL);guard fsync(root)==0 else{close(result);result = -1;throw NativeDataMaintenanceRecoveryFailure.io}}
        return result
    }
    func publish(content filename:String,to destination:URL,replace:Bool,validateAndPublish:(()throws->Void)throws->Void)throws {
        mutex.lock();defer{mutex.unlock()};try validate();try F.leaf(filename);try F.leaf(destination.lastPathComponent)
        guard destination.isFileURL,filename != F.marker,destination.lastPathComponent != name else{throw NativeDataMaintenanceRecoveryFailure.unsafe}
        let p=try F.directory(NativeExportStagingRegistry.systemAlias(destination.deletingLastPathComponent()));defer{close(p)}
        guard F.identity(try F.info(p))==parentID else{throw NativeDataMaintenanceRecoveryFailure.changed}
        let input=try F.openFile(root,filename,O_RDONLY);defer{close(input)}
        try F.validateTree(root,check:{try self.validate()})
        let contentID=F.identity(try F.info(input));guard fsync(input)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
        try validateAndPublish {
            try registry.mutate {
                try validate()
                guard let file=try F.at(root,filename),F.identity(file)==contentID else{throw NativeDataMaintenanceRecoveryFailure.changed};try F.privateFile(file)
                // Both cases atomically move the payload out of the owned
                // directory. Recovery never traverses the destination name.
                let result = replace ? renameat(root,filename,parent,destination.lastPathComponent) : renameatx_np(root,filename,parent,destination.lastPathComponent,UInt32(RENAME_EXCL))
                guard result==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
                guard fsync(root)==0,fsync(parent)==0 else{throw NativeDataMaintenanceRecoveryFailure.io}
            }
        }
    }
    private func finishOutsideTask()throws {
        mutex.lock();defer{mutex.unlock()};if finished{return}
        // NativeDataMaintenanceRecovery rejects cancellation. GCD has no
        // cancelled Swift task; only fresh auth/readonly fence can stop cleanup.
        try lease.cleanup(role:.temporary);try lease.finish();finished=true
    }
    /// Synchronous producer API: call off MainActor, only after writer join.
    /// The independent cleanup closure completes before this method returns.
    func finish()throws {
        if !Task.isCancelled {try finishOutsideTask();return}
        let done=DispatchSemaphore(value:0),result=NativeExportFinishResult()
        DispatchQueue.global(qos:.utility).async{result.value=Result{try self.finishOutsideTask()};done.signal()}
        done.wait();try result.value!.get()
    }
}
