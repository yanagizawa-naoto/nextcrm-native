import AppKit

/// Use only after the owning controllers have accepted unsaved-change checks
/// and all asynchronous sheet operations have drained. Closing a sheet also
/// delivers windowWillClose, which releases staged photos and pending UI work.
enum NativeSheetTermination {
    /// terminateLater enters an AppKit event loop synchronously. Invoke it from
    /// the native run loop, after the calling Swift task has returned, so that
    /// MainActor shutdown tasks can run and deliver the termination reply.
    @MainActor static func scheduleApplicationQuit(_ action:@escaping @MainActor ()->Void) {
        RunLoop.main.perform(inModes:[.common]) { MainActor.assumeIsolated { action() } }
    }
    @MainActor static func dismiss(in parent:NSWindow) {
        while let sheet = parent.attachedSheet {
            dismiss(in:sheet)
            parent.endSheet(sheet)
            sheet.close()
        }
    }
}

/// Multiple termination requests must await the same sheet close without
/// replacing an earlier continuation or cancelling the operation twice.
@MainActor final class NativeSheetCloseWaiters {
    private var waiters:[CheckedContinuation<Void,Never>] = []
    private var closed = false
    func wait(requestClose:()->Void) async {
        guard !closed else { return }
        await withCheckedContinuation { continuation in
            let first = waiters.isEmpty
            waiters.append(continuation)
            if first { requestClose() }
        }
    }
    func didClose() {
        closed = true
        let finished = waiters; waiters.removeAll(keepingCapacity:false)
        for waiter in finished { waiter.resume() }
    }
}
