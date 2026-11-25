import AppKit

@main enum NativeSheetCloseWaitersTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value:Bool,_ message:String) throws {
            guard value else { throw NSError(domain:message,code:1) }; checks += 1
        }
        let close = NativeSheetCloseWaiters()
        var entered = 0, requests = 0, finished = 0
        let tasks = (0..<100).map { _ in Task { @MainActor in
            entered += 1
            await close.wait { requests += 1 }
            finished += 1
        } }
        let deadline = Date().addingTimeInterval(5)
        while entered < 100 && Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        try check(entered == 100,"all overlapping requests entered")
        try check(requests == 1 && finished == 0,"one close request; every waiter remains pending")
        tasks[0].cancel()
        await Task.yield()
        try check(finished == 0,"caller cancellation still awaits actual operation cleanup")
        close.didClose()
        for task in tasks { await task.value }
        try check(finished == 100,"all overlapping requests resumed")
        close.didClose()
        await close.wait { requests += 1 }
        try check(requests == 1,"duplicate completion and late arrival are harmless")
        let idle = NativeSheetCloseWaiters()
        await idle.wait { requests += 1; idle.didClose() }
        try check(requests == 2,"synchronous idle-sheet completion is not lost")
        print("NativeSheetCloseWaitersTests: \(checks) concurrency checks passed")
    }
}
