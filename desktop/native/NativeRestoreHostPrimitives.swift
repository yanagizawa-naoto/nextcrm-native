import Foundation
import Darwin

enum NativeRestoreHostFailure:Error,LocalizedError,Equatable {
    case busy, invalid, system, identity, protocolViolation, closed, alreadyWaiting
    var errorDescription:String? {
        switch self {
        case .busy:return "別のアプリがこのデータを使用しています。終了を確認してから再試行してください。"
        case .identity:return "引継ぎ元のプロセスまたは保存場所を確認できません。切替を保留します。"
        case .closed:return "この引継ぎ用の接続は既に閉じています。"
        case .alreadyWaiting:return "このプロセスの終了確認は既に開始されています。"
        case .protocolViolation:return "引継ぎの取消通知を確認できません。切替を保留します。"
        case .invalid:return "引継ぎ用の保存場所または接続が安全な条件を満たしていません。"
        case .system:return "プロセスの引継ぎを完了できませんでした。切替を保留します。"
        }
    }
    static func check(_ code:Int32)throws {
        switch Int(code) {case NCH_OK:return;case NCH_BUSY:throw Self.busy;case NCH_INVALID:throw Self.invalid;case NCH_IDENTITY:throw Self.identity;case NCH_PROTOCOL:throw Self.protocolViolation;default:throw Self.system}
    }
}

/// Owning descriptor, close-on-exec at rest. The only inheritance is explicit spawn dup2.
final class NativeRestoreHostDescriptor:@unchecked Sendable {
    private let lock=NSLock();private var descriptor:Int32
    init(consuming descriptor:Int32)throws {
        guard descriptor>=3 else{throw NativeRestoreHostFailure.invalid}
        guard fcntl(descriptor,F_SETFD,FD_CLOEXEC)==0 else{Darwin.close(descriptor);throw NativeRestoreHostFailure.system}
        self.descriptor=descriptor
    }
    deinit{close()}
    func close(){lock.lock();let fd=descriptor;descriptor = -1;lock.unlock();if fd>=0{Darwin.close(fd)}}
    func withDescriptor<T>(_ body:(Int32)throws->T)throws->T {lock.lock();defer{lock.unlock()};guard descriptor>=0 else{throw NativeRestoreHostFailure.closed};return try body(descriptor)}
    func duplicate()throws->NativeRestoreHostDescriptor {try withDescriptor{fd in let copy=fcntl(fd,F_DUPFD_CLOEXEC,3);guard copy>=0 else{throw NativeRestoreHostFailure.system};return try .init(consuming:copy)}}
    fileprivate func consume()throws->Int32 {lock.lock();defer{lock.unlock()};guard descriptor>=0 else{throw NativeRestoreHostFailure.closed};let fd=descriptor;descriptor = -1;return fd}
}

struct NativeRestoreHostLeaseIdentity:Codable,Equatable,Sendable {
    let controlDevice:UInt64,controlInode:UInt64,leaseDevice:UInt64,leaseInode:UInt64,uid:UInt32
    fileprivate init(_ raw:NCHLeaseIdentity){controlDevice=raw.control_device;controlInode=raw.control_inode;leaseDevice=raw.lease_device;leaseInode=raw.lease_inode;uid=raw.uid}
    fileprivate var raw:NCHLeaseIdentity{.init(control_device:controlDevice,control_inode:controlInode,lease_device:leaseDevice,lease_inode:leaseInode,uid:uid)}
}

/// Instance lifetime gate only. It issues no administrator authority and never
/// reads/modifies .activation.lock, a journal, the root pointer, or a database.
final class NativeRestoreHostInstanceLease:@unchecked Sendable {
    let identity:NativeRestoreHostLeaseIdentity
    private let lock=NSLock();private var handle:OpaquePointer?
    private init(_ handle:OpaquePointer,identity:NativeRestoreHostLeaseIdentity){self.handle=handle;self.identity=identity}
    deinit{close()}
    private static func path(_ control:URL)throws->String {guard control.isFileURL,!control.path.utf8.contains(0) else{throw NativeRestoreHostFailure.invalid};return control.path}
    static func open(existingPrivateControl control:URL)throws->NativeRestoreHostInstanceLease {
        var handle:OpaquePointer?,identity=NCHLeaseIdentity();let path=try path(control)
        try NativeRestoreHostFailure.check(path.withCString{nch_lease_open($0,&handle,&identity)})
        guard let handle else{throw NativeRestoreHostFailure.system};return .init(handle,identity:.init(identity))
    }
    static func adopt(existingPrivateControl control:URL,expected:NativeRestoreHostLeaseIdentity,consuming descriptor:NativeRestoreHostDescriptor)throws->NativeRestoreHostInstanceLease {
        let fd=try descriptor.consume();let path:String
        do{path=try self.path(control)}catch{Darwin.close(fd);throw error};var handle:OpaquePointer?
        try NativeRestoreHostFailure.check(path.withCString{nch_lease_adopt($0,fd,expected.raw,&handle)})
        guard let handle else{throw NativeRestoreHostFailure.system};return .init(handle,identity:expected)
    }
    func validate()throws {lock.lock();defer{lock.unlock()};guard let handle else{throw NativeRestoreHostFailure.closed};try NativeRestoreHostFailure.check(nch_lease_validate(handle))}
    func handoffDescriptor()throws->NativeRestoreHostDescriptor {
        lock.lock();defer{lock.unlock()};guard let handle else{throw NativeRestoreHostFailure.closed};var fd:Int32 = -1
        try NativeRestoreHostFailure.check(nch_lease_duplicate(handle,&fd));return try .init(consuming:fd)
    }
    /// Closing this duplicate must not unlock another holder of the same lease.
    func close(){lock.lock();let current=handle;handle=nil;lock.unlock();if let current{nch_lease_close(current)}}
}

struct NativeRestoreHostProcessIdentity:Codable,Equatable,Sendable {
    let pid:Int32,uid:UInt32,startSeconds:UInt64,startMicroseconds:UInt64
    fileprivate init(_ raw:NCHProcessIdentity){pid=raw.pid;uid=raw.uid;startSeconds=raw.start_seconds;startMicroseconds=raw.start_microseconds}
    fileprivate var raw:NCHProcessIdentity{.init(pid:pid,uid:uid,start_seconds:startSeconds,start_microseconds:startMicroseconds)}
    static func current(_ pid:Int32)throws->Self {var raw=NCHProcessIdentity();try NativeRestoreHostFailure.check(nch_process_identity(pid,&raw));return .init(raw)}
    static func parent()throws->Self {try current(getppid())}
}

/// A fresh registration receipt, not persistent permission or a commit token.
struct NativeRestoreHostExitRegistration:Equatable,Sendable {
    let id:UUID,process:NativeRestoreHostProcessIdentity
}
struct NativeRestoreHostExitEvidence:Equatable,Sendable {
    let registration:NativeRestoreHostExitRegistration,kernelWaitStatus:Int32
}
enum NativeRestoreHostExitOutcome:Equatable,Sendable {
    case exited(NativeRestoreHostExitEvidence),cancelled,peerClosed,timedOut
}

/// Dedicated nonblocking pipe. A peer may only send C or close its writer.
final class NativeRestoreHostCancellationChannel:@unchecked Sendable {
    let reader:NativeRestoreHostDescriptor,writer:NativeRestoreHostDescriptor
    init()throws {
        var r:Int32 = -1,w:Int32 = -1;try NativeRestoreHostFailure.check(nch_make_cancel_pipe(&r,&w))
        do{reader=try .init(consuming:r)}catch{Darwin.close(w);throw error}
        writer=try .init(consuming:w)
    }
    func cancel(){try? writer.withDescriptor{nch_signal_cancel($0)}}
    func closeWriter(){writer.close()}
}

final class NativeRestoreHostParentExitMonitor:@unchecked Sendable {
    let registration:NativeRestoreHostExitRegistration
    private let lock=NSLock(),cancellation:NativeRestoreHostCancellationChannel
    private let queueDescriptor:NativeRestoreHostDescriptor,peer:NativeRestoreHostDescriptor?
    private var started=false,finished=false
    /// Caller keeps the old parent alive until this returns and the receipt is ACKed.
    /// peerCancellation is a dedicated O_NONBLOCK pipe reader with no other consumer.
    init(register process:NativeRestoreHostProcessIdentity,peerCancellation:NativeRestoreHostDescriptor?=nil)throws {
        cancellation=try .init();var q:Int32 = -1
        try NativeRestoreHostFailure.check(nch_watch_register(process.raw,&q));queueDescriptor=try .init(consuming:q)
        if let peerCancellation {var fd:Int32 = -1;try peerCancellation.withDescriptor{try NativeRestoreHostFailure.check(nch_duplicate_pipe_reader($0,&fd))};peer=try .init(consuming:fd)}else{peer=nil}
        registration = .init(id:UUID(),process:process)
    }
    func cancel(){lock.lock();let active = !finished;lock.unlock();if active{cancellation.cancel()}}
    private func begin()throws{lock.lock();defer{lock.unlock()};guard !started else{throw NativeRestoreHostFailure.alreadyWaiting};started=true}
    private func finish(){lock.lock();finished=true;lock.unlock();queueDescriptor.close();peer?.close();cancellation.writer.close();cancellation.reader.close()}
    func wait(timeout:TimeInterval?=nil)async throws->NativeRestoreHostExitOutcome {
        guard timeout == nil || timeout!.isFinite && timeout!>=0 && timeout!<=Double(Int32.max) else{throw NativeRestoreHostFailure.invalid}
        try begin()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation{continuation in
                DispatchQueue.global(qos:.utility).async { [self] in
                    let result=Result { ()throws->NativeRestoreHostExitOutcome in
                        defer{finish()};var status:Int32=0
                        let code=try queueDescriptor.withDescriptor{q in try cancellation.reader.withDescriptor{c in
                            if let peer{return try peer.withDescriptor{nch_watch_wait(q,registration.process.raw,c,$0,timeout ?? -1,&status)}}
                            return nch_watch_wait(q,registration.process.raw,c,-1,timeout ?? -1,&status)
                        }}
                        switch Int(code) {
                        case NCH_EXITED:return .exited(.init(registration:registration,kernelWaitStatus:status))
                        case NCH_CANCELLED:return .cancelled
                        case NCH_PEER_CLOSED:return .peerClosed
                        case NCH_TIMED_OUT:return .timedOut
                        default:try NativeRestoreHostFailure.check(-code);throw NativeRestoreHostFailure.system
                        }
                    };continuation.resume(with:result)
                }
            }
        },onCancel:{self.cancel()})
    }
}

struct NativeRestoreHostInheritedDescriptor {
    let descriptor:NativeRestoreHostDescriptor,target:Int32
}
struct NativeRestoreHostChildExit:Equatable,Sendable {
    let rawStatus:Int32,cancelled:Bool
    var exitCode:Int32?{rawStatus&0x7f==0 ? (rawStatus>>8)&0xff:nil}
    var signal:Int32?{let value=rawStatus&0x7f;return value != 0 && value != 0x7f ? value:nil}
}

/// Sole reaper of this exact unreaped direct child. No kill-by-CLI-PID API.
final class NativeRestoreHostOwnedChild:@unchecked Sendable {
    let pid:Int32
    func processIdentity()throws->NativeRestoreHostProcessIdentity{try .current(pid)}
    private let lock=NSLock(),cancellation:NativeRestoreHostCancellationChannel
    private var waiting=false,finished=false
    private init(pid:Int32)throws {
        self.pid=pid;do{cancellation=try .init()}catch{nch_child_abandon(pid);throw error}
    }
    deinit {if !finished{let pid=pid;DispatchQueue.global(qos:.utility).async{nch_child_abandon(pid)}}}
    static func spawn(executable:URL,arguments:[String],inheriting:[NativeRestoreHostInheritedDescriptor]=[])throws->NativeRestoreHostOwnedChild {
        guard executable.isFileURL,executable.path.hasPrefix("/"),inheriting.count<=32,!([executable.path]+arguments).contains(where:{$0.utf8.contains(0)}) else{throw NativeRestoreHostFailure.invalid}
        // Duplicate first: concurrent close of an original cannot reuse its fd
        // between validation and posix_spawn. The C bridge avoids mapping cycles.
        let held=try inheriting.map{try $0.descriptor.duplicate()};defer{held.forEach{$0.close()}}
        let sources=try held.map{try $0.withDescriptor{$0}},targets=inheriting.map(\.target)
        let strings=([executable.path]+arguments).map{strdup($0)};defer{strings.forEach{free($0)}}
        guard strings.allSatisfy({$0 != nil})else{throw NativeRestoreHostFailure.system};var argv=strings+[nil],pid:Int32=0
        let code=executable.path.withCString{path in nch_spawn(path,&argv,sources,targets,Int32(sources.count),&pid)}
        try NativeRestoreHostFailure.check(code);return try .init(pid:pid)
    }
    func cancel(){lock.lock();let active = !finished;lock.unlock();if active{cancellation.cancel()}}
    private func begin()throws{lock.lock();defer{lock.unlock()};guard !waiting else{throw NativeRestoreHostFailure.alreadyWaiting};waiting=true}
    private func finish(){lock.lock();finished=true;lock.unlock();cancellation.writer.close();cancellation.reader.close()}
    func wait(cancellationGrace:TimeInterval=0.5)async throws->NativeRestoreHostChildExit {
        guard cancellationGrace.isFinite,cancellationGrace>=0,cancellationGrace<=10 else{throw NativeRestoreHostFailure.invalid};try begin()
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation{continuation in
                DispatchQueue.global(qos:.utility).async { [self] in
                    let result=Result { ()throws->NativeRestoreHostChildExit in
                        defer{finish()};var status:Int32=0,cancelled:Int32=0
                        let code=try cancellation.reader.withDescriptor{nch_child_wait(pid,$0,cancellationGrace,&status,&cancelled)}
                        if code != Int32(NCH_OK){nch_child_abandon(pid)}
                        try NativeRestoreHostFailure.check(code);return .init(rawStatus:status,cancelled:cancelled != 0)
                    };continuation.resume(with:result)
                }
            }
        },onCancel:{self.cancel()})
    }
}
