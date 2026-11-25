import Foundation
import CoreGraphics
import Darwin

/// Serial blocking RPC, intended for a utility task, never the main actor.
/// Each RPC owns duplicated descriptors so cancellation cannot redirect an
/// in-flight read/write to a newly opened descriptor with the same integer.
final class NativeUserAvatarWorkerClient: @unchecked Sendable {
    struct Metadata{let count:Int,iterations:Int?,requiresInitialFrameDisplay:Bool}
    struct Frame{let index:Int,width:Int,height:Int,delayMicroseconds:UInt64,rgba:Data,childCurrent:UInt64,childPeak:UInt64}
    let process=Process(),sessionID=UUID()
    private let input=Pipe(),output=Pipe(),rpc=NSLock(),state=NSCondition()
    private var stopped=false,terminated=false,launched=false,timedOut=false
    private var deadline:TimeInterval?,nextIndex=0,delivered:UInt64=0
    private let responseTimeout:TimeInterval
    private let onStopped:(()->Void)?
    private let deadlineTimer:DispatchSourceTimer = {
        let timer=DispatchSource.makeTimerSource(queue:.global(qos:.userInitiated))
        timer.schedule(deadline:.distantFuture);timer.resume();return timer
    }()
    private var metadata:Metadata?

    #if AVATAR_WORKER_TESTING
    private static let testLock=NSLock()
    private static var testPIDs:Set<pid_t>=[]
    private static var testStarts=0
    static var testingActivePIDs:Set<pid_t>{testLock.lock();defer{testLock.unlock()};return testPIDs}
    static var testingLaunchCount:Int{testLock.lock();defer{testLock.unlock()};return testStarts}
    #endif

    static var bundledExecutableURL:URL? {
        guard Bundle.main.bundleURL.pathExtension=="app" else{return nil}
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NextCRMAvatarDecoder")
    }
    init(executable:URL,responseTimeout:TimeInterval=10,onStopped:(()->Void)?=nil)throws {
        self.responseTimeout=responseTimeout;self.onStopped=onStopped
        guard executable.isFileURL,responseTimeout.isFinite,responseTimeout>0 else{throw NativeUserAvatarWorkerFailure.helperUnavailable}
        deadlineTimer.setEventHandler{[weak self]in self?.expire()}
        process.executableURL=executable;process.arguments=["--parent",String(getpid())]
        process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)==0 else{throw NativeUserAvatarWorkerFailure.io}
        do{try process.run()}catch{throw NativeUserAvatarWorkerFailure.helperUnavailable}
        launched=true;input.fileHandleForReading.closeFile();output.fileHandleForWriting.closeFile()
        #if AVATAR_WORKER_TESTING
        Self.testLock.lock();Self.testPIDs.insert(process.processIdentifier);Self.testStarts += 1;Self.testLock.unlock()
        #endif
        // A crash between frames must return admission immediately, even when
        // the encoded delay would otherwise postpone the next RPC for minutes.
        // Never wait from Foundation's termination callback itself.
        process.terminationHandler={ [weak self] _ in DispatchQueue.global(qos:.utility).async{[weak self]in self?.stop()} }
        if !process.isRunning{DispatchQueue.global(qos:.utility).async{[weak self]in self?.stop()}}
    }
    deinit{stop()}
    private func activeLocked()throws{if timedOut{throw NativeUserAvatarWorkerFailure.timedOut};guard !stopped else{throw NativeUserAvatarWorkerFailure.cancelled}}
    private func active()throws{state.lock();defer{state.unlock()};try activeLocked()}
    private func expire(){state.lock();guard !stopped,let deadline,ProcessInfo.processInfo.systemUptime>=deadline else{state.unlock();return};timedOut=true;state.unlock();stop()}
    private func descriptors()throws->(Int32,Int32){
        state.lock();defer{state.unlock()}
        try activeLocked()
        let writeFD=dup(input.fileHandleForWriting.fileDescriptor)
        guard writeFD>=0 else{throw NativeUserAvatarWorkerFailure.io}
        let readFD=dup(output.fileHandleForReading.fileDescriptor)
        guard readFD>=0 else{close(writeFD);throw NativeUserAvatarWorkerFailure.io}
        guard fcntl(writeFD,F_SETFD,FD_CLOEXEC)==0,fcntl(readFD,F_SETFD,FD_CLOEXEC)==0 else{close(writeFD);close(readFD);throw NativeUserAvatarWorkerFailure.io}
        deadline=ProcessInfo.processInfo.systemUptime+responseTimeout
        return(writeFD,readFD)
    }
    private func perform<T>(_ body:(Int32,Int32)throws->T)throws->T {
        rpc.lock();defer{rpc.unlock()}
        do {
            let(writeFD,readFD)=try descriptors()
            deadlineTimer.schedule(deadline:.now()+responseTimeout)
            defer{close(writeFD);close(readFD);state.lock();deadline=nil;state.unlock();deadlineTimer.schedule(deadline:.distantFuture)}
            let result=try body(writeFD,readFD)
            state.lock();defer{state.unlock()}
            if timedOut{throw NativeUserAvatarWorkerFailure.timedOut}
            deadline=nil
            return result
        }catch {
            stop()
            state.lock();let expired=timedOut;state.unlock()
            if expired{throw NativeUserAvatarWorkerFailure.timedOut}
            throw error
        }
    }
    private func packet(_ fd:Int32)throws->(UInt8,Data){let(kind,length)=try NativeUserAvatarWorkerWire.readHeader(fd);let cap:Int
        switch kind{case 0x10:cap=12;case 0x11:cap=NativeUserAvatarWorkerWire.frameLimit;case 0x12:cap=0;case 0x13:cap=16;case 0x7f:cap=4;default:throw NativeUserAvatarWorkerFailure.invalidPacket}
        guard length<=cap else{throw NativeUserAvatarWorkerFailure.tooLarge}
        let data=try NativeUserAvatarWorkerWire.readExactly(fd,length,limit:cap)
        if kind==0x7f{guard length==4 else{throw NativeUserAvatarWorkerFailure.invalidPacket};throw NativeUserAvatarWorkerFailure.remote(UInt32(try NativeUserAvatarWorkerWire.integer(data,0,4)))}
        return(kind,data)
    }
    func open(_ data:Data)throws->Metadata{try perform{writeFD,readFD in
        guard metadata==nil else{throw NativeUserAvatarWorkerFailure.invalidPacket}
        guard !data.isEmpty,data.count<=NativeUserAvatarWorkerWire.inputLimit else{throw NativeUserAvatarWorkerFailure.tooLarge}
        try NativeUserAvatarWorkerWire.write(writeFD,1,data,limit:NativeUserAvatarWorkerWire.inputLimit)
        let(kind,p)=try packet(readFD);guard kind==0x10,p.count==12 else{throw NativeUserAvatarWorkerFailure.invalidPacket}
        let count=Int(try NativeUserAvatarWorkerWire.integer(p,0,4)),loops=Int(try NativeUserAvatarWorkerWire.integer(p,4,4)),flag=try NativeUserAvatarWorkerWire.integer(p,8,4)
        guard count>0,count<=1_000_000,flag<=1 else{throw NativeUserAvatarWorkerFailure.invalidPacket};try active()
        let result=Metadata(count:count,iterations:loops==0 ? nil:loops,requiresInitialFrameDisplay:flag==1);metadata=result;return result
    }}
    func next()throws->Frame?{try perform{writeFD,readFD in
        guard let metadata else{throw NativeUserAvatarWorkerFailure.invalidPacket}
        let expectingEnd=metadata.iterations.map{delivered==UInt64($0)*UInt64(metadata.count)} ?? false
        try NativeUserAvatarWorkerWire.write(writeFD,2,Data(),limit:0);let(kind,p)=try packet(readFD)
        if kind==0x12{guard p.isEmpty,expectingEnd else{throw NativeUserAvatarWorkerFailure.invalidPacket};try active();stop();return nil}
        guard !expectingEnd,kind==0x11,p.count>=32 else{throw NativeUserAvatarWorkerFailure.invalidPacket}
        let index=Int(try NativeUserAvatarWorkerWire.integer(p,0,4)),width=Int(try NativeUserAvatarWorkerWire.integer(p,4,2)),height=Int(try NativeUserAvatarWorkerWire.integer(p,6,2)),delay=try NativeUserAvatarWorkerWire.integer(p,8,8)
        guard index==nextIndex,index<metadata.count,width>0,height>0,width<=256,height<=256,p.count==32+width*height*4,delay>=11000,delay<=86_400_000_000,delivered<UInt64.max else{throw NativeUserAvatarWorkerFailure.invalidPacket}
        try active();nextIndex=(nextIndex+1)%metadata.count;delivered += 1
        return Frame(index:index,width:width,height:height,delayMicroseconds:delay,rgba:Data(p.dropFirst(32)),childCurrent:try NativeUserAvatarWorkerWire.integer(p,16,8),childPeak:try NativeUserAvatarWorkerWire.integer(p,24,8))
    }}
    func stats()throws->(UInt64,UInt64){try perform{writeFD,readFD in
        try NativeUserAvatarWorkerWire.write(writeFD,3,Data(),limit:0);let(kind,p)=try packet(readFD);guard kind==0x13,p.count==16 else{throw NativeUserAvatarWorkerFailure.invalidPacket};try active()
        return(try NativeUserAvatarWorkerWire.integer(p,0,8),try NativeUserAvatarWorkerWire.integer(p,8,8))
    }}
    /// May wait up to the escalation interval; invoke from a utility queue.
    func stop(){
        state.lock();if stopped{while !terminated{state.wait()};state.unlock();return};stopped=true;deadline=nil;state.unlock();deadlineTimer.cancel()
        defer{onStopped?()}
        guard launched else{state.lock();terminated=true;state.broadcast();state.unlock();return}
        input.fileHandleForWriting.closeFile()
        if process.isRunning{process.terminate()}
        let end=ProcessInfo.processInfo.systemUptime+0.3
        while process.isRunning && ProcessInfo.processInfo.systemUptime<end{usleep(2000)}
        if process.isRunning{kill(process.processIdentifier,SIGKILL)}
        process.waitUntilExit();output.fileHandleForReading.closeFile()
        #if AVATAR_WORKER_TESTING
        Self.testLock.lock();Self.testPIDs.remove(process.processIdentifier);Self.testLock.unlock()
        #endif
        state.lock();terminated=true;state.broadcast();state.unlock()
    }
}

/// FIFO admission without blocking a Swift executor thread. Only Playback
/// uses this pool; raw protocol clients remain independent for diagnostics.
/// An infinite visible image keeps its turn until hidden, replaced or closed.
private actor NativeUserAvatarWorkerPermits {
    static let shared=NativeUserAvatarWorkerPermits()
    private struct Waiting {
        let token:NativeUserAvatarPlaybackCancellation
        let changed:@Sendable ()->Void
        let continuation:CheckedContinuation<NativeUserAvatarWorkerPermit,Error>
    }
    private var active:UUID?,queue:[Waiting]=[]
    func acquire(_ token:NativeUserAvatarPlaybackCancellation,changed:@escaping @Sendable ()->Void)async throws->NativeUserAvatarWorkerPermit {
        try Task.checkCancellation()
        guard !token.isCancelled else{throw CancellationError()}
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation{continuation in
                guard !token.isCancelled && !Task.isCancelled else{continuation.resume(throwing:CancellationError());return}
                if active==nil {active=token.permitID;continuation.resume(returning:NativeUserAvatarWorkerPermit(id:token.permitID))}
                else{token.setWaiting(true);queue.append(Waiting(token:token,changed:changed,continuation:continuation));changed()}
            }
        },onCancel:{Task{await Self.shared.cancel(token.permitID)}})
    }
    func cancel(_ id:UUID){
        guard let index=queue.firstIndex(where:{$0.token.permitID==id})else{return}
        let waiter=queue.remove(at:index);waiter.token.setWaiting(false);waiter.changed();waiter.continuation.resume(throwing:CancellationError())
    }
    func release(_ id:UUID){
        guard active==id else{return};active=nil
        while !queue.isEmpty {
            let waiter=queue.removeFirst();waiter.token.setWaiting(false);waiter.changed()
            guard !waiter.token.isCancelled else{waiter.continuation.resume(throwing:CancellationError());continue}
            active=waiter.token.permitID;waiter.continuation.resume(returning:NativeUserAvatarWorkerPermit(id:waiter.token.permitID));break
        }
    }
}

fileprivate final class NativeUserAvatarWorkerPermit: @unchecked Sendable {
    private let lock=NSLock(),id:UUID
    private var released=false
    init(id:UUID){self.id=id}
    deinit{release()}
    func release(){lock.lock();guard !released else{lock.unlock();return};released=true;lock.unlock();let id=id;Task{await NativeUserAvatarWorkerPermits.shared.release(id)}}
}

/// Safe to call cancel() from the main actor. The blocking stop/reap runs on a
/// utility queue, and installation observes cancellation that preceded spawn.
final class NativeUserAvatarPlaybackCancellation: @unchecked Sendable {
    private let lock=NSLock()
    fileprivate let permitID=UUID()
    private var cancelled=false,waiting=false,client:NativeUserAvatarWorkerClient?
    private var reservation:NativeUserAvatarWorkerPermit?
    var isCancelled:Bool{lock.lock();defer{lock.unlock()};return cancelled}
    var isWaiting:Bool{lock.lock();defer{lock.unlock()};return waiting}
    fileprivate func setWaiting(_ value:Bool){lock.lock();waiting=value;lock.unlock()}
    fileprivate func reserve(_ permit:NativeUserAvatarWorkerPermit)throws{lock.lock();defer{lock.unlock()};guard !cancelled else{throw CancellationError()};reservation=permit}
    fileprivate func consume(_ permit:NativeUserAvatarWorkerPermit)throws{lock.lock();defer{lock.unlock()};guard !cancelled,reservation === permit else{throw CancellationError()};reservation=nil}
    fileprivate func discard(_ permit:NativeUserAvatarWorkerPermit){lock.lock();if reservation === permit{reservation=nil};lock.unlock()}
    func install(_ worker:NativeUserAvatarWorkerClient)throws{
        lock.lock();let old=client,shouldCancel=cancelled;client=worker;lock.unlock()
        old?.stop()
        if shouldCancel{worker.stop();throw CancellationError()}
    }
    func cancel(){lock.lock();cancelled=true;let worker=client,permit=reservation;reservation=nil;lock.unlock();permit?.release();let id=permitID;Task{await NativeUserAvatarWorkerPermits.shared.cancel(id)};if let worker{DispatchQueue.global(qos:.userInitiated).async{worker.stop()}}}
    func finish(){lock.lock();cancelled=true;let worker=client,permit=reservation;reservation=nil;client=nil;lock.unlock();permit?.release();let id=permitID;Task{await NativeUserAvatarWorkerPermits.shared.cancel(id)};worker?.stop()}
}

/// Same small output type for both backends. Only the inline canvas-limit
/// failure selects a worker; other malformed/unsupported inputs stay failures.
final class NativeUserAvatarPlayback {
    let frameCount:Int,iterations:Int?,requiresInitialFrameDisplay:Bool
    private let inline:NativeUserAvatarAnimation?,worker:NativeUserAvatarWorkerClient?
    init(data:Data,helperExecutable:URL?,cancellation:NativeUserAvatarPlaybackCancellation,waitingChanged:@escaping @Sendable ()->Void={},refreshSource:(@Sendable ()async throws->Data?)?=nil)async throws{
        try Task.checkCancellation()
        guard !cancellation.isCancelled else{throw CancellationError()}
        do {
            let decoder=try NativeUserAvatarAnimation(data:data)
            inline=decoder;worker=nil;frameCount=decoder.frameCount;iterations=decoder.iterations;requiresInitialFrameDisplay=decoder.requiresInitialFrameDisplay
        }catch NativeUserAvatarAnimation.Failure.canvasLimit{
            guard let helperExecutable else{throw NativeUserAvatarWorkerFailure.helperUnavailable}
            let permit=try await NativeUserAvatarWorkerPermits.shared.acquire(cancellation,changed:waitingChanged)
            defer{cancellation.discard(permit)}
            let client:NativeUserAvatarWorkerClient
            let bytes:Data
            do{try Task.checkCancellation();guard !cancellation.isCancelled else{throw CancellationError()}
                try cancellation.reserve(permit)
                // Admission may have waited behind an infinite visible image.
                // Re-read through the View's authorized source before IPC.
                let refreshed:Data?
                if let refreshSource{refreshed=try await withTaskCancellationHandler(operation:{try await refreshSource()},onCancel:{cancellation.cancel()})}else{refreshed=data}
                try Task.checkCancellation();guard !cancellation.isCancelled else{throw CancellationError()}
                guard let refreshed else{try cancellation.consume(permit);permit.release();inline=nil;worker=nil;frameCount=0;iterations=1;requiresInitialFrameDisplay=false;return}
                bytes=refreshed
                if refreshSource != nil {
                    do{let decoder=try NativeUserAvatarAnimation(data:bytes);try cancellation.consume(permit);permit.release();inline=decoder;worker=nil;frameCount=decoder.frameCount;iterations=decoder.iterations;requiresInitialFrameDisplay=decoder.requiresInitialFrameDisplay;return}
                    catch NativeUserAvatarAnimation.Failure.canvasLimit{}
                }
                // From this point cancellation cannot release admission until
                // the newly spawned process has been stopped and reaped.
                try cancellation.consume(permit)
                client=try NativeUserAvatarWorkerClient(executable:helperExecutable,onStopped:{permit.release()})
            }catch{permit.release();throw error}
            try cancellation.install(client)
            do{try Task.checkCancellation();let metadata=try client.open(bytes);try Task.checkCancellation()
                inline=nil;worker=client;frameCount=metadata.count;iterations=metadata.iterations;requiresInitialFrameDisplay=metadata.requiresInitialFrameDisplay
            }catch{client.stop();if Task.isCancelled || cancellation.isCancelled{throw CancellationError()};throw error}
        }
    }
    func nextFrame()throws->NativeUserAvatarAnimation.Frame?{
        try Task.checkCancellation()
        if frameCount==0{return nil}
        if let inline{return try inline.nextFrame()}
        guard let worker else{throw NativeUserAvatarWorkerFailure.invalidPacket}
        do{guard let frame=try worker.next()else{return nil};try Task.checkCancellation()
            guard let provider=CGDataProvider(data:frame.rgba as CFData),let image=CGImage(width:frame.width,height:frame.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:frame.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)else{throw NativeUserAvatarWorkerFailure.invalidPacket}
            return NativeUserAvatarAnimation.Frame(image:image,index:frame.index,delay:Double(frame.delayMicroseconds)/1_000_000)
        }catch{if Task.isCancelled{throw CancellationError()};throw error}
    }
}
