import Foundation

/// Main-queue owner of asynchronous cancellation callbacks. Duplicate keys are
/// coalesced while running; distinct requests are never silently discarded.
/// This does not impose a hard bound on a burst of distinct cancellation IDs.
final class NativeRuntimeControlTasks {
    private struct Entry {let generation:UUID,token:UUID,task:Task<Void,Never>}
    private var generation=UUID(),entries:[String:Entry]=[:],closed=false
    var pendingCount:Int {entries.count}
    var isClosed:Bool {closed}
    deinit {entries.values.forEach{$0.task.cancel()}}
    @discardableResult func performControl(key:String,operation:@escaping () async -> Void)->Bool {
        dispatchPrecondition(condition:.onQueue(.main));guard !closed else{return false}
        if entries[key] != nil{return true}
        let epoch=generation,token=UUID()
        let task=Task{@MainActor [weak self] in
            if !Task.isCancelled {await operation()}
            self?.finished(key:key,epoch:epoch,token:token)
        }
        entries[key] = .init(generation:epoch,token:token,task:task)
        return true
    }
    private func finished(key:String,epoch:UUID,token:UUID){
        guard let entry=entries[key],entry.generation==epoch,entry.token==token else{return}
        entries.removeValue(forKey:key)
    }
    func close(){
        dispatchPrecondition(condition:.onQueue(.main));guard !closed else{return}
        closed=true;generation=UUID();entries.values.forEach{$0.task.cancel()}
    }
    @MainActor func closeAndDrain() async {
        close()
        // No new operations can enter after close. Caller cancellation must not
        // abandon operations already executing or their final file/DB writes.
        let current=Array(entries.values)
        for entry in current {await entry.task.value}
    }
}
