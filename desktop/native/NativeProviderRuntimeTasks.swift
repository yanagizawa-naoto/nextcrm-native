import Foundation

/// A run-scoped owner of provider tasks, including notifications arriving on
/// arbitrary threads. Cancellation never drops a live task. A closed instance
/// cannot be reopened: a deliberate new runtime start creates a new owner.
final class NativeProviderRuntimeTasks: @unchecked Sendable {
    typealias Sleep = (UInt64) async throws -> Void
    private struct Entry {
        let task:Task<Void,Never>, key:String?
        var dirty:Bool
    }
    private let lock=NSLock()
    private var accepting=true,entries:[UUID:Entry]=[:],keys:[String:UUID]=[:]
    private var accepted=0,completed=0,peak=0,rejected=0
    struct Snapshot {let accepting:Bool,pending:Int,accepted:Int,completed:Int,peak:Int,rejected:Int}
    var snapshot:Snapshot {
        lock.lock();defer{lock.unlock()}
        return .init(accepting:accepting,pending:entries.count,accepted:accepted,completed:completed,peak:peak,rejected:rejected)
    }
    /// A key coalesces only notification wakeups. A dirty iteration rechecks
    /// work if another notification arrived while its wake was in flight.
    @discardableResult func submit(key:String?=nil,_ operation:@escaping ()async->Void)->Task<Void,Never>? {
        lock.lock();defer{lock.unlock()}
        guard accepting else{rejected += 1;return nil}
        if let key,let id=keys[key],var entry=entries[id] {
            entry.dirty=true;entries[id]=entry;return entry.task
        }
        let id=UUID()
        // Preserve the caller task-local context and priority, as the original
        // runtime Task constructors did; isolation lives in the operation.
        let task=Task { [self] in
            repeat {await operation()} while self.nextIteration(id)
        }
        entries[id] = .init(task:task,key:key,dirty:false)
        if let key{keys[key]=id};accepted += 1;peak=max(peak,entries.count)
        return task
    }
    private func nextIteration(_ id:UUID)->Bool {
        lock.lock();defer{lock.unlock()}
        guard var entry=entries[id] else{return false}
        if accepting,entry.dirty,!Task.isCancelled {entry.dirty=false;entries[id]=entry;return true}
        entries.removeValue(forKey:id)
        if let key=entry.key,keys[key]==id {keys.removeValue(forKey:key)}
        completed += 1;return false
    }
    /// The callback admission gate closes under the same lock that registers
    /// accepted tasks. Even a callback already copied by NotificationCenter
    /// either registers before this snapshot or is rejected without a Task.
    func close()->[Task<Void,Never>] {
        lock.lock();accepting=false;let tasks=entries.values.map(\.task);lock.unlock()
        for task in tasks{task.cancel()}
        return tasks
    }
}
