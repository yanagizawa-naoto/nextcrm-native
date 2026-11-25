import Foundation
import Darwin

final class AvatarWorkerPermitSampler: @unchecked Sendable {
    private let lock=NSLock(),timer=DispatchSource.makeTimerSource(queue:.global())
    private var peak=0,samples=0
    init(){timer.setEventHandler{[weak self]in guard let self else{return};let count=NativeUserAvatarWorkerClient.testingActivePIDs.count;self.lock.lock();self.peak=max(self.peak,count);self.samples += 1;self.lock.unlock()};timer.schedule(deadline:.now(),repeating:.milliseconds(1));timer.resume()}
    func stop()->(Int,Int){timer.cancel();lock.lock();defer{lock.unlock()};return(peak,samples)}
}

final class AvatarWorkerPendingRefresh: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Data?,Never>?
    var pending:Bool{lock.withLock{continuation != nil}}
    func wait()async->Data?{await withCheckedContinuation{value in lock.withLock{continuation=value}}}
    func resume(_ bytes:Data){let value=lock.withLock{let value=continuation;continuation=nil;return value};value?.resume(returning:bytes)}
}

extension AvatarHelperTests {
    static func eventually(_ label:String,_ predicate:()->Bool)async throws{let start=ProcessInfo.processInfo.systemUptime;while !predicate() && ProcessInfo.processInfo.systemUptime-start<4{try await Task.sleep(nanoseconds:2_000_000)};try check(predicate(),label)}
    static func cancelled(_ task:Task<NativeUserAvatarPlayback,Error>)async throws{do{_ = try await task.value;throw Failure(text:"cancelled admission succeeded")}catch is CancellationError{checks += 1}}
    static func permits(_ dir:URL)async throws {
        let bytes=try Data(contentsOf:dir.appendingPathComponent("wide-infinite.png")),finite=try Data(contentsOf:dir.appendingPathComponent("wide-finite.png")),helper=dir.appendingPathComponent("NextCRMAvatarDecoder")
        let sampler=AvatarWorkerPermitSampler()
        func launch(_ token:NativeUserAvatarPlaybackCancellation)->Task<NativeUserAvatarPlayback,Error>{Task.detached{try await NativeUserAvatarPlayback(data:bytes,helperExecutable:helper,cancellation:token)}}
        let a=NativeUserAvatarPlaybackCancellation(),b=NativeUserAvatarPlaybackCancellation(),c=NativeUserAvatarPlaybackCancellation()
        let first=try await NativeUserAvatarPlayback(data:bytes,helperExecutable:helper,cancellation:a);try check(try first.nextFrame()?.index==0,"first owns permit")
        let firstPID=NativeUserAvatarWorkerClient.testingActivePIDs.first!,starts=NativeUserAvatarWorkerClient.testingLaunchCount
        let second=launch(b);try await eventually("second waits without spawning"){b.isWaiting}
        let third=launch(c);try await eventually("third queued FIFO"){c.isWaiting}
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==starts && NativeUserAvatarWorkerClient.testingActivePIDs.count==1,"waiting uses no worker")
        second.cancel();try await cancelled(second);b.finish();try check(c.isWaiting,"cancelled head leaves next queued")
        a.cancel();a.finish();let thirdValue=try await third.value
        try check(AvatarHelperWireForPermit.gone(firstPID),"reap precedes next spawn")
        try check(try thirdValue.nextFrame()?.index==0 && NativeUserAvatarWorkerClient.testingActivePIDs.count==1,"next owns sole worker")
        let d=NativeUserAvatarPlaybackCancellation(),e=NativeUserAvatarPlaybackCancellation(),f=NativeUserAvatarPlaybackCancellation()
        let fourth=launch(d);try await eventually("FIFO fourth waits"){d.isWaiting}
        let fifth=launch(e);try await eventually("FIFO fifth waits"){e.isWaiting}
        let sixth=launch(f);try await eventually("FIFO sixth waits"){f.isWaiting}
        e.cancel();try await cancelled(fifth);e.finish();c.finish()
        _ = try await fourth.value;try check(f.isWaiting && !d.isWaiting,"FIFO fourth before sixth")
        d.finish();let sixthValue = try await sixth.value;try check(!f.isWaiting && NativeUserAvatarWorkerClient.testingActivePIDs.count==1,"FIFO sixth follows fourth")
        // Queued async tasks must not consume all Swift executor threads. The
        // owner and all cancellations must still make progress with 40 waiters.
        var tokens:[NativeUserAvatarPlaybackCancellation]=[],tasks:[Task<NativeUserAvatarPlayback,Error>]=[]
        for _ in 0..<40{let token=NativeUserAvatarPlaybackCancellation();tokens.append(token);tasks.append(launch(token))}
        try await eventually("forty async waiters do not starve executor"){tokens.allSatisfy{$0.isWaiting}}
        let waitStarts=NativeUserAvatarWorkerClient.testingLaunchCount
        for i in tasks.indices{if i%2==0{tasks[i].cancel()}else{tokens[i].cancel()}}
        for task in tasks{try await cancelled(task)}
        for token in tokens{token.finish()}
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==waitStarts,"queued cancellation never spawns")
        try check(try sixthValue.nextFrame() != nil,"owner continues after queued cancellations")
        f.finish();try await eventually("all cancelled sessions reaped"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        // END releases admission even while both completed playback and client
        // objects remain retained by their callers.
        let endToken=NativeUserAvatarPlaybackCancellation(),afterEnd=NativeUserAvatarPlaybackCancellation()
        let end=try await NativeUserAvatarPlayback(data:finite,helperExecutable:helper,cancellation:endToken)
        let following=launch(afterEnd);try await eventually("next waits for finite END"){afterEnd.isWaiting}
        for i in 0..<end.frameCount{try check(try end.nextFrame()?.index==i,"finite frame")}
        try check(try end.nextFrame()==nil,"finite END closes worker")
        _ = try await following.value;try check(!afterEnd.isWaiting,"finite END releases permit without deinit")
        endToken.finish();afterEnd.finish()
        let crashToken=NativeUserAvatarPlaybackCancellation(),afterCrash=NativeUserAvatarPlaybackCancellation()
        let crashed=try await NativeUserAvatarPlayback(data:bytes,helperExecutable:helper,cancellation:crashToken)
        try check(try crashed.nextFrame() != nil,"crash owner has displayed a frame")
        let crashedPID=NativeUserAvatarWorkerClient.testingActivePIDs.first!,crashWaiter=launch(afterCrash)
        try await eventually("next waits behind a long-delay owner"){afterCrash.isWaiting}
        kill(crashedPID,SIGKILL)
        try await eventually("exit notification reaps and grants without another RPC"){!afterCrash.isWaiting && !NativeUserAvatarWorkerClient.testingActivePIDs.contains(crashedPID)}
        _ = try await crashWaiter.value;try check(AvatarHelperWireForPermit.gone(crashedPID),"crashed child reaped before successor")
        crashToken.finish();afterCrash.finish()
        // Each path after admission must return the permit, including spawn
        // failure, decoder rejection, refreshed permission denial and nil/small.
        let native=dir.deletingLastPathComponent().deletingLastPathComponent(),small=try Data(contentsOf:native.appendingPathComponent("build/avatar-animation/gif-finite.gif"))
        for mode in ["spawn","malformed","denied","nil","small"] {
            let token=NativeUserAvatarPlaybackCancellation()
            do {
                let input=mode=="malformed" ? Data(bytes.dropLast(10)):bytes
                let refresh:(@Sendable ()async throws->Data?)?
                switch mode{case "denied":refresh={throw Failure(text:"permission revoked")};case "nil":refresh={nil};case "small":refresh={small};default:refresh=nil}
                let playback=try await NativeUserAvatarPlayback(data:input,helperExecutable:mode=="spawn" ? dir.appendingPathComponent("missing"):helper,cancellation:token,refreshSource:refresh)
                try check(mode=="nil" ? playback.frameCount==0:mode=="small" && playback.frameCount==3,"refresh to static or inline")
            }catch{try check(["spawn","malformed","denied"].contains(mode),"expected post-admission failure")}
            token.finish()
            let next=NativeUserAvatarPlaybackCancellation();_ = try await NativeUserAvatarPlayback(data:bytes,helperExecutable:helper,cancellation:next);try check(NativeUserAvatarWorkerClient.testingActivePIDs.count==1,"permit returned after "+mode);next.finish()
        }
        // A cancelled, noncooperative reauthorization closure may return much
        // later. Before spawn it must release its reservation immediately.
        for cancelTask in [false,true] {
            let oldToken=NativeUserAvatarPlaybackCancellation(),nextToken=NativeUserAvatarPlaybackCancellation(),pending=AvatarWorkerPendingRefresh()
            let old=Task.detached{try await NativeUserAvatarPlayback(data:bytes,helperExecutable:helper,cancellation:oldToken,refreshSource:{await pending.wait()})}
            try await eventually("reauthorization is suspended"){pending.pending}
            let next=launch(nextToken);try await eventually("next waits behind reservation"){nextToken.isWaiting}
            if cancelTask{old.cancel()}else{oldToken.cancel()}
            try await eventually("cancelled loader releases reservation before returning"){!nextToken.isWaiting && NativeUserAvatarWorkerClient.testingActivePIDs.count==1}
            _ = try await next.value;try check(pending.pending,"old loader still has not returned")
            let count=NativeUserAvatarWorkerClient.testingLaunchCount;pending.resume(bytes);try await cancelled(old)
            try check(NativeUserAvatarWorkerClient.testingLaunchCount==count,"late old loader cannot spawn")
            oldToken.finish();nextToken.finish()
        }
        try await eventually("permit suite final cleanup"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        let measured=sampler.stop();try check(measured.0==1,"sampled maximum one playback helper")
        let report:[String:Any]=["checks":checks,"maxConcurrentPlaybackHelpers":measured.0,"samples":measured.1,"queuedStressCount":40,"scope":"FIFO async permit; wait/task cancellation; finite END; failures; source reauthorization; retained completed object; child reap before successor. Raw clients intentionally independent. Infinite visible holder retains its turn until hidden/replaced/closed."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("permits-result.json"));print("Worker permits: \(checks) checks")
    }
}
private enum AvatarHelperWireForPermit {static func gone(_ pid:pid_t)->Bool{NativeUserAvatarWorkerWire.footprint(pid)==nil}}
