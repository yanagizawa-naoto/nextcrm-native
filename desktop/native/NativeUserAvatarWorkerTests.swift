import Foundation
import CryptoKit
import Darwin

final class AvatarHelperSampler {
    private let lock=NSLock(),timer:DispatchSourceTimer
    private var samples=0,peak:UInt64=0,parentAtPeak:UInt64=0,childAtPeak:UInt64=0
    init(pid:pid_t){timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"avatar.helper.measure"));timer.setEventHandler{[weak self]in guard let self else{return};let p=NativeUserAvatarWorkerWire.footprint(getpid()) ?? 0,c=NativeUserAvatarWorkerWire.footprint(pid) ?? 0;self.lock.lock();self.samples += 1;if p+c>self.peak{self.peak=p+c;self.parentAtPeak=p;self.childAtPeak=c};self.lock.unlock()};timer.schedule(deadline:.now(),repeating:.milliseconds(2));timer.resume()}
    func stop()->[String:Any]{timer.cancel();lock.lock();defer{lock.unlock()};return["samplePeriodMilliseconds":2,"samples":samples,"combinedPeakSampled":peak,"parentAtPeak":parentAtPeak,"childAtPeak":childAtPeak]}
}

@main enum AvatarHelperTests {
    struct Failure:Error{let text:String}
    static var checks=0
    static func check(_ value:@autoclosure()throws->Bool,_ text:String)throws{guard try value()else{throw Failure(text:text)};checks += 1}
    static func sha(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func main()async{do{try await run()}catch{fputs("Helper tests after \(checks): \(error)\n",stderr);exit(1)}}
    static func run()async throws{
        let dir=URL(fileURLWithPath:CommandLine.arguments[1]),mode=CommandLine.arguments[2]
        if mode=="benchmark"{try benchmark(dir,CommandLine.arguments[3]);return}
        if mode=="safety"{try safety(dir);return}
        if mode=="permits"{try await permits(dir);return}
        if mode=="races"{try await races(dir);return}
        if mode=="reject"{try reject(dir,CommandLine.arguments[3],UInt32(CommandLine.arguments[4])!);return}
        throw Failure(text:"mode")
    }
    static func benchmark(_ dir:URL,_ name:String)throws{
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("fixtures.json")))as! [String:Any],fixture=(reference["fixtures"]as! [[String:Any]]).first{$0["name"]as? String==name}!
        let baseline=NativeUserAvatarWorkerWire.memory(),start=ProcessInfo.processInfo.systemUptime,client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("NextCRMAvatarDecoder")),pid=client.process.processIdentifier,sampler=AvatarHelperSampler(pid:pid)
        defer{client.stop()}
        let metadata=try autoreleasepool{let data=try Data(contentsOf:URL(fileURLWithPath:fixture["file"]as! String));try check(sha(data)==fixture["sha256"]as! String,"fixture digest");return try client.open(data)}
        if let flag=fixture["expectedPoster"]as? Bool{try check(metadata.requiresInitialFrameDisplay==flag,"one-frame poster")}
        let requested=fixture["requested"]as? Int ?? metadata.count*(metadata.iterations ?? 1),expected=fixture["expected"]as? [String]
        var frames:[[String:Any]]=[],maxChildPeak:UInt64=0
        for index in 0..<requested {try autoreleasepool{
            guard let f=try client.next()else{throw Failure(text:"early end")}
            try check(f.index==index%metadata.count,"frame order");try check(f.width<=256 && f.height<=256 && f.rgba.count==f.width*f.height*4,"bounded frame")
            let hash=sha(f.rgba);if let expected{try check(hash==expected[f.index],"source-equivalent preview \(name)/\(f.index): \(hash)")}
            maxChildPeak=max(maxChildPeak,f.childPeak);frames.append(["index":f.index,"sha256":hash,"bytes":f.rgba.count,"childCurrent":f.childCurrent,"childPeak":f.childPeak])
        }}
        let idle=try client.stats(),parentBefore=NativeUserAvatarWorkerWire.memory();usleep(50_000);let beforeStop=NativeUserAvatarWorkerWire.footprint(pid) ?? 0,stopStart=ProcessInfo.processInfo.systemUptime
        if let loops=metadata.iterations,requested==loops*metadata.count{try check(try client.next()==nil,"finite end auto-stops helper")}else{client.stop()}
        let stopSeconds=ProcessInfo.processInfo.systemUptime-stopStart;usleep(50_000)
        try check(!client.process.isRunning,"helper terminated");try check(NativeUserAvatarWorkerWire.footprint(pid)==nil,"child address space no longer present")
        var combined=sampler.stop();let after=NativeUserAvatarWorkerWire.memory();combined["sumOfLedgerPeaksUpperBound"]=after.peak+max(maxChildPeak,idle.1)
        let report:[String:Any]=["name":name,"checks":checks,"helperPID":pid,"sessionID":client.sessionID.uuidString,"frames":frames,"metadata":["count":metadata.count,"iterations":metadata.iterations as Any? ?? NSNull(),"requiresInitialFrameDisplay":metadata.requiresInitialFrameDisplay],"parentBaseline":["current":baseline.current,"peak":baseline.peak],"parentBeforeStop":["current":parentBefore.current,"peak":parentBefore.peak],"parentAfterStop":["current":after.current,"peak":after.peak],"childBeforeStop":beforeStop,"childIdleCurrent":idle.0,"childLedgerPeak":max(maxChildPeak,idle.1),"childPresentAfterStop":false,"sampledCombined":combined,"stopSeconds":stopSeconds,"seconds":ProcessInfo.processInfo.systemUptime-start,"scratchFilesCreated":0]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent(name+"-result.json"));print("Helper \(name): \(checks) checks; child peak \(max(maxChildPeak,idle.1)); stopped \(stopSeconds)s")
    }
    static func safety(_ dir:URL)throws{
        let native=dir.deletingLastPathComponent().deletingLastPathComponent(),valid=try Data(contentsOf:native.appendingPathComponent("build/avatar-animation/gif-finite.gif"))
        for mode in ["badmeta","oversize","badwidth","badindex","truncated","unknown","earlyend"]{
            let client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("fake-"+mode))
            do{_ = try client.open(valid);_ = try client.next();throw Failure(text:"accepted fake "+mode)}catch is NativeUserAvatarWorkerFailure{checks += 1}
            try check(!client.process.isRunning,"reaped bad helper "+mode)
        }
        do{let client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("NextCRMAvatarDecoder"));do{_ = try client.open(Data(count:NativeUserAvatarWorkerWire.inputLimit+1));throw Failure(text:"oversized input")}catch is NativeUserAvatarWorkerFailure{checks += 1};try check(!client.process.isRunning,"over-input helper reaped")}
        do{let client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("NextCRMAvatarDecoder"));_ = try client.open(valid);kill(client.process.processIdentifier,SIGKILL);usleep(20_000);do{_ = try client.next();throw Failure(text:"crashed helper accepted")}catch is NativeUserAvatarWorkerFailure{checks += 1};try check(!client.process.isRunning,"crashed helper reaped")}
        do{var client:NativeUserAvatarWorkerClient?=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("NextCRMAvatarDecoder"));let pid=client!.process.processIdentifier;_ = try client!.open(valid);_ = try client!.next();client=nil;try check(NativeUserAvatarWorkerWire.footprint(pid)==nil,"deinit terminates helper")}
        // Cancel while an RPC waits and while the fake ignores TERM. The caller
        // must not receive a stale frame, and KILL must finish within the bound.
        var cancellation:[[String:Any]]=[]
        for fake in [false,true]{let client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent(fake ? "fake-stalled":"NextCRMAvatarDecoder"));let bytes=fake ? valid:try Data(contentsOf:native.appendingPathComponent("build/avatar-streaming/webp-16mp.webp"));_ = try client.open(bytes)
            let group=DispatchGroup(),lock=NSLock();var returned=false,failed=false;group.enter();DispatchQueue.global().async{do{_ = try client.next();lock.lock();returned=true;lock.unlock()}catch{lock.lock();failed=true;lock.unlock()};group.leave()}
            usleep(fake ? 50_000:1000);let start=ProcessInfo.processInfo.systemUptime;client.stop();let elapsed=ProcessInfo.processInfo.systemUptime-start;try check(group.wait(timeout:.now()+2) == .success,"cancel unblocks RPC");lock.lock();let wasReturned=returned,wasFailed=failed;lock.unlock();try check(!wasReturned && wasFailed,"cancel rejects delivery");try check(!client.process.isRunning,"cancel child reaped");try check(elapsed<1,"bounded cancel");cancellation.append(["fakeIgnoresTERM":fake,"seconds":elapsed,"status":client.process.terminationStatus])
        }
        let report:[String:Any]=["checks":checks,"cancellation":cancellation,"scope":"Untrusted output size/dimensions/index/truncation/kind/meta, caller input cap, child crash, cancel during 16MP decode, TERM-resistant child KILL escalation."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("safety-result.json"));print("Helper safety: \(checks) checks")
    }
    static func reject(_ dir:URL,_ path:String,_ code:UInt32)throws{
        let client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("NextCRMAvatarDecoder"))
        do{_ = try client.open(Data(contentsOf:URL(fileURLWithPath:path)));throw Failure(text:"accepted input boundary")}
        catch NativeUserAvatarWorkerFailure.remote(let actual){try check(actual==code,"typed input rejection")}
        try check(!client.process.isRunning,"rejected child reaped");print("Helper rejected \(URL(fileURLWithPath:path).lastPathComponent): \(checks) checks")
    }
}

import Foundation
import Darwin

extension AvatarHelperTests {
    static func races(_ dir:URL)async throws {
        let native=dir.deletingLastPathComponent().deletingLastPathComponent()
        let valid=try Data(contentsOf:native.appendingPathComponent("build/avatar-animation/gif-finite.gif"))
        var times:[[String:Any]]=[]
        for mode in ["inithang","stallinput","stalled"] {
            let client=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("fake-"+mode),responseTimeout:0.08)
            let start=ProcessInfo.processInfo.systemUptime
            do {
                _ = try client.open(mode=="stallinput" ? Data(count:4*1024*1024):valid)
                _ = try client.next();throw Failure(text:"deadline accepted "+mode)
            } catch NativeUserAvatarWorkerFailure.timedOut { checks += 1 }
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            try check(elapsed<1.2,"bounded RPC deadline "+mode)
            try check(!client.process.isRunning,"deadline reaps "+mode)
            times.append(["mode":mode,"seconds":elapsed])
        }
        // Keep an old blocked RPC and stop/restart overlapping. Reused OS fd
        // numbers must never redirect that RPC into the new helper's channel.
        let baselineFDs=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        for cycle in 0..<12 {
            let old=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("fake-stalled"))
            _ = try old.open(valid)
            let group=DispatchGroup(),lock=NSLock();var failed=false
            group.enter();DispatchQueue.global().async{do{_ = try old.next()}catch{lock.lock();failed=true;lock.unlock()};group.leave()}
            usleep(30_000)
            group.enter();DispatchQueue.global().async{old.stop();group.leave()}
            usleep(5_000)
            let current=try NativeUserAvatarWorkerClient(executable:dir.appendingPathComponent("NextCRMAvatarDecoder"))
            let m=try current.open(valid)
            for i in 0..<m.count{try check(try current.next()?.index==i,"no cross-session packet \(cycle)/\(i)")}
            current.stop()
            try check(group.wait(timeout:.now()+2) == .success,"overlap cancellation finishes")
            let didFail=lock.withLock{failed}
            try check(didFail,"old response never accepted")
            try check(!old.process.isRunning && !current.process.isRunning,"both overlapping helpers reaped")
        }
        let finalFDs=try FileManager.default.contentsOfDirectory(atPath:"/dev/fd").count
        try check(finalFDs<=baselineFDs+2,"descriptor count remains bounded: \(baselineFDs) -> \(finalFDs)")
        let starts=NativeUserAvatarWorkerClient.testingLaunchCount
        do {let token=NativeUserAvatarPlaybackCancellation();defer{token.finish()};let p=try await NativeUserAvatarPlayback(data:valid,helperExecutable:dir.appendingPathComponent("NextCRMAvatarDecoder"),cancellation:token);try check(p.frameCount==3,"small GIF inline");try check(try p.nextFrame()?.index==0,"small inline frame")}
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==starts,"inline never spawns")
        for bytes in [Data(),Data(count:4*1024*1024+1)] {
            let token=NativeUserAvatarPlaybackCancellation();defer{token.finish()}
            do{_ = try await NativeUserAvatarPlayback(data:bytes,helperExecutable:dir.appendingPathComponent("NextCRMAvatarDecoder"),cancellation:token);throw Failure(text:"invalid input accepted")}catch is NativeUserAvatarAnimation.Failure{checks += 1}
        }
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==starts,"malformed/input-cap never spawns")
        let large=try Data(contentsOf:native.appendingPathComponent("build/avatar-streaming/gif-16mp.gif"))
        do{let token=NativeUserAvatarPlaybackCancellation();token.cancel();do{_ = try await NativeUserAvatarPlayback(data:large,helperExecutable:dir.appendingPathComponent("NextCRMAvatarDecoder"),cancellation:token);throw Failure(text:"precancel accepted")}catch is CancellationError{checks += 1};token.finish()}
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==starts,"precancel never spawns")
        do{let token=NativeUserAvatarPlaybackCancellation();defer{token.finish()};do{_ = try await NativeUserAvatarPlayback(data:large,helperExecutable:nil,cancellation:token);throw Failure(text:"missing helper accepted")}catch NativeUserAvatarWorkerFailure.helperUnavailable{checks += 1}}
        do{let token=NativeUserAvatarPlaybackCancellation();defer{token.finish()};let playback=try await NativeUserAvatarPlayback(data:large,helperExecutable:dir.appendingPathComponent("NextCRMAvatarDecoder"),cancellation:token);try check(playback.frameCount>1,"large selected helper");let frame=try playback.nextFrame();try check(frame?.image.width==256 && frame?.image.height==256,"same bounded frame type");token.cancel();token.finish()}
        try check(NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty,"no worker remains")
        let report:[String:Any]=["checks":checks,"deadlineCases":times,"overlappingSessions":12,"fdBaseline":baselineFDs,"fdAfter":finalFDs,"scope":"Formal client: init/read/write deadlines; concurrent cancel/restart with duplicated descriptors; inline-only small GIF; invalid/over-limit/pre-cancel do not spawn; large canvas worker selection and cancellation cleanup."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("races-result.json"))
        print("Worker races: \(checks) checks")
    }
}
