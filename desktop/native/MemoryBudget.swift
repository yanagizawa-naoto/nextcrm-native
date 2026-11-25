import Foundation
import Darwin

/// Return allocator-owned, unused pages after a major screen transition. This does not
/// discard live objects or disable system caches. Never run on each keystroke or draw.
final class MemoryBudget {
    /// Drain Foundation/AppKit temporary objects at the end of each background
    /// operation, rather than waiting for a global worker thread's pool to drain.
    /// The alternate setting exists only for matched, same-binary measurements.
    static func queue(label: String) -> DispatchQueue {
        let frequency: DispatchQueue.AutoreleaseFrequency = ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_QUEUE_AUTORELEASE"] == "inherit" ? .inherit : .workItem
        return DispatchQueue(label:label,qos:.userInitiated,autoreleaseFrequency:frequency)
    }
    private var pending: DispatchWorkItem?
    func settle() {
        pending?.cancel()
        let work = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    deinit { pending?.cancel() }
}
