import AppKit
import ImageIO

@main enum WorkerViewTests {
    struct Failure:Error{let text:String}
    static var checks=0
    @MainActor static func check(_ value:@autoclosure()throws->Bool,_ text:String)throws{guard try value()else{throw Failure(text:text)};checks += 1}
    @MainActor static func wait(_ label:String,_ predicate:()->Bool)async throws{let start=ProcessInfo.processInfo.systemUptime;while !predicate() && ProcessInfo.processInfo.systemUptime-start<8{try await Task.sleep(nanoseconds:10_000_000)};try check(predicate(),label)}
    @MainActor static func color(_ v:NSView)->[Int]{let rep=v.bitmapImageRepForCachingDisplay(in:v.bounds)!;v.cacheDisplay(in:v.bounds,to:rep);let c=rep.colorAt(x:rep.pixelsWide/2,y:rep.pixelsHigh/2)!.usingColorSpace(.sRGB)!;return [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent].map{Int(($0*255).rounded())}}
    @MainActor static func dominant(_ v:NSView,_ ch:Int)->Bool{let c=color(v);return c[ch]>=180 && (0..<3).filter{$0 != ch}.allSatisfy{c[ch]-c[$0]>=80} && c[3]==255}
    @MainActor static func main(){_ = NSApplication.shared;NSApp.setActivationPolicy(.accessory);Task{@MainActor in do{try await run();print("Worker view: \(checks) checks passed");exit(0)}catch{fputs("Worker view after \(checks): \(error)\n",stderr);exit(1)}};NSApp.run()}
    @MainActor static func run()async throws {
        let dir=URL(fileURLWithPath:CommandLine.arguments[1]),native=dir.deletingLastPathComponent().deletingLastPathComponent()
        let helper=dir.appendingPathComponent("NextCRMAvatarDecoder")
        func data(_ path:String)throws->Data{try Data(contentsOf:native.appendingPathComponent(path))}
        func own(_ name:String)throws->Data{try Data(contentsOf:dir.appendingPathComponent(name+".png"))}
        let context=CGContext(data:nil,width:4,height:4,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:4,height:4));let poster=context.makeImage()!
        let window=NSWindow(contentRect:NSRect(x:140,y:140,width:340,height:260),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="Isolated avatar helper candidate";window.isReleasedWhenClosed=false
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:240,height:190),styleMask:[.titled,.closable],backing:.buffered,defer:false);panel.isReleasedWhenClosed=false
        let container=NSView(frame:NSRect(x:0,y:0,width:240,height:190));panel.contentView=container
        let view=NativeUserAvatarView(frame:NSRect(x:50,y:30,width:128,height:128));view.decoderExecutableURL=helper;container.addSubview(view);view.set(image:poster,name:"候補")
        var trace:[String]=[];view.onAnimationStatusChange={s in trace.append("\(s) frames=\(String(describing:view.animationFrameIndex)) pids=\(NativeUserAvatarWorkerClient.testingActivePIDs)")}
        defer{view.onAnimationStatusChange=nil;view.stopAnimation();window.endSheet(panel);panel.orderOut(nil);window.orderOut(nil)}
        var reads=0,allowed=true
        view.setAnimationSource{reads += 1;guard allowed else{throw Failure(text:"permission denied")};return try own("wide-single-poster")}
        try await Task.sleep(nanoseconds:70_000_000);try check(reads==0 && NativeUserAvatarWorkerClient.testingLaunchCount==0,"hidden never reads or spawns")
        NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);window.beginSheet(panel,completionHandler:nil)
        try await wait("one-frame excluded poster rendered"){view.animationStatus == .staticImage && view.animationFrameIndex==0}
        try check(dominant(view,1),"helper frame replaces blue poster: \(color(view))")
        try await wait("one-frame releases child"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        try check(reads==2 && NativeUserAvatarWorkerClient.testingLaunchCount==1,"authorized read repeated after admission")
        let oneFrameWebP=Data(base64Encoded:"UklGRpAAAABXRUJQVlA4WAoAAAAaAAAACwAABwAAQU5JTQYAAAAAAAAAAQBBTk1GQgAAAAAAAAAAAAsAAAcAAJABAAJWUDhMKgAAAC8LwAEAHyAQSNofeo35FxAU+T/a/AdfJIBMwEJJt2puJX3LENH/eAzqAEVYSUYaAAAASUkqAAgAAAABABIBAwABAAAABgAAAAAAAAA=")!
        view.set(image:poster,name:"動くWebPの初回表示");let smallStarts=NativeUserAvatarWorkerClient.testingLaunchCount
        view.setAnimationSource{oneFrameWebP}
        try await wait("one-frame oriented WebP draws its actual first frame"){view.animationStatus == .staticImage && view.animationFrameIndex==0}
        try check(!dominant(view,2) && NativeUserAvatarWorkerClient.testingLaunchCount==smallStarts,"one-frame WebP replaces rotated poster inline")
        view.set(image:poster,name:"大画像の初回表示");view.setAnimationSource{try data("build/avatar-worker/webp-oriented-single.webp")}
        try await wait("16MP one-frame oriented WebP draws once"){view.animationStatus == .staticImage && view.animationFrameIndex==0}
        try await wait("16MP one-frame helper released"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        try check(!dominant(view,2),"large one-frame first image replaces thumbnail")
        view.setAnimationSource{reads += 1;guard allowed else{throw Failure(text:"permission denied")};return try own("wide-infinite")}
        try await wait("wide infinite plays"){view.animationStatus == .playing && view.animationFrameIndex==1}
        let firstPIDs=NativeUserAvatarWorkerClient.testingActivePIDs
        try check(!firstPIDs.isEmpty && dominant(view,1),"helper infinite green output")
        view.isHidden=true;view.refreshAnimationVisibility()
        try await wait("hide releases child"){view.animationStatus == .paused && NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        let hiddenReads=reads;try await Task.sleep(nanoseconds:100_000_000);try check(reads==hiddenReads && view.animationFrameIndex==nil,"no hidden loader/frame")
        view.isHidden=false;view.refreshAnimationVisibility();try await wait("resume fresh source and child"){reads==hiddenReads+2 && view.animationStatus == .playing}
        try check(firstPIDs.isDisjoint(with:NativeUserAvatarWorkerClient.testingActivePIDs),"resume uses new PID")
        container.isHidden=true;view.refreshAnimationVisibility();try await wait("hidden ancestor releases child"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty && view.animationStatus == .paused}
        allowed=false;let deniedStarts=NativeUserAvatarWorkerClient.testingLaunchCount;container.isHidden=false;view.refreshAnimationVisibility()
        try await wait("fresh auth rejects resume"){if case .unavailable=view.animationStatus{return true};return false}
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==deniedStarts && NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty,"denied source never sent")
        allowed=true
        var measured:[[String:Any]]=[]
        for (label,path) in [("gif","build/avatar-streaming/gif-16mp.gif"),("webp","build/avatar-streaming/webp-16mp.webp"),("apng","build/avatar-worker/apng-16mp.png")] {
            let before=NativeUserAvatarWorkerClient.testingLaunchCount,start=ProcessInfo.processInfo.systemUptime
            view.setAnimationSource{reads += 1;return try data(path)}
            try await wait(label+" finite END"){view.animationStatus == .finished}
            try await wait(label+" finite child gone"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
            try check(view.animationFrameIndex==1 && NativeUserAvatarWorkerClient.testingLaunchCount==before+1,label+" final frame retained")
            measured.append(["kind":label,"seconds":ProcessInfo.processInfo.systemUptime-start])
        }
        for path in ["build/avatar-animation/gif-infinite.gif","build/avatar-animation/webp-finite.webp","build/avatar-apng/infinite.png"]{
            let before=NativeUserAvatarWorkerClient.testingLaunchCount;view.setAnimationSource{try data(path)}
            try await wait("small inline playing"){view.animationStatus == .playing}
            try check(NativeUserAvatarWorkerClient.testingLaunchCount==before,"small inline never launches")
        }
        view.setAnimationSource{try own("wide-infinite")};try await wait("first visible permit holder"){view.animationStatus == .playing}
        let queued=NativeUserAvatarView(frame:NSRect(x:0,y:0,width:40,height:40));queued.decoderExecutableURL=helper;container.addSubview(queued);queued.set(image:poster,name:"待機")
        var queuedAllowed=true,queuedReads=0
        queued.setAnimationSource{queuedReads += 1;guard queuedAllowed else{throw Failure(text:"revoked while waiting")};return try own("wide-infinite")}
        try await wait("second visible image reports waiting"){queued.animationStatus == .waiting}
        try check(queued.animationStatus.message.contains("待機") && queuedReads==1 && NativeUserAvatarWorkerClient.testingActivePIDs.count==1,"waiting retains thumbnail and starts no second worker")
        queued.isHidden=true;queued.refreshAnimationVisibility();try await wait("cancel queued visible image"){queued.animationStatus == .paused}
        try check(NativeUserAvatarWorkerClient.testingActivePIDs.count==1,"queued cancel leaves running owner")
        queued.isHidden=false;queued.refreshAnimationVisibility();try await wait("resumed queued image waits again"){queued.animationStatus == .waiting}
        queuedAllowed=false;let launchesBeforeRevocation=NativeUserAvatarWorkerClient.testingLaunchCount
        view.isHidden=true;view.refreshAnimationVisibility()
        try await wait("authorization rechecked after permit"){if case .unavailable=queued.animationStatus{return true};return false}
        try check(queuedReads==3 && NativeUserAvatarWorkerClient.testingLaunchCount==launchesBeforeRevocation,"queued permission loss never reaches IPC")
        try await wait("revoked waiter releases admission"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        queued.stopAnimation();queued.removeFromSuperview();view.isHidden=false;view.refreshAnimationVisibility()
        view.setAnimationSource{try own("wide-infinite")};try await wait("helper for detach"){view.animationStatus == .playing && !NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        view.removeFromSuperview();try await wait("detach reaps"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty && view.animationStatus == .paused}
        container.addSubview(view);try await wait("reattach resumes"){view.animationStatus == .playing}
        window.endSheet(panel);panel.orderOut(nil);view.refreshAnimationVisibility();try await wait("sheet end reaps"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty && view.animationStatus == .paused}
        window.beginSheet(panel,completionHandler:nil);try await wait("sheet redisplay"){view.animationStatus == .playing}
        var started=false,returned=false
        view.setAnimationSource{started=true;let bytes=try own("wide-infinite");return await withCheckedContinuation{c in DispatchQueue.main.asyncAfter(deadline:.now()+0.15){returned=true;c.resume(returning:bytes)}}}
        try await wait("noncooperative load starts"){started};let beforeCancel=NativeUserAvatarWorkerClient.testingLaunchCount;view.set(image:poster,name:"取消")
        try await wait("old loader returned"){returned};try await Task.sleep(nanoseconds:60_000_000)
        try check(view.animationStatus == .staticImage && view.animationFrameIndex==nil && dominant(view,2),"generation rejects stale loaded source")
        try check(NativeUserAvatarWorkerClient.testingLaunchCount==beforeCancel && NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty,"cancelled load never launches")
        view.decoderExecutableURL=dir.appendingPathComponent("fake-stalled");view.setAnimationSource{try own("wide-infinite")}
        try await wait("TERM-resistant worker started"){!NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        try await Task.sleep(nanoseconds:80_000_000)
        let cancelStart=ProcessInfo.processInfo.systemUptime;view.set(image:poster,name:"非同期取消")
        let synchronousCancel=ProcessInfo.processInfo.systemUptime-cancelStart
        try check(synchronousCancel<0.05,"main-actor cancel never waits for worker: \(synchronousCancel)")
        try await wait("resistant worker killed off-main"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        view.decoderExecutableURL=helper
        for _ in 0..<8{view.setAnimationSource{try own("wide-infinite")};try await Task.sleep(nanoseconds:30_000_000);view.isHidden=true;view.refreshAnimationVisibility();view.isHidden=false;view.refreshAnimationVisibility()}
        view.set(image:poster,name:"停止");try await wait("rapid replacement drains all children"){NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        try await Task.sleep(nanoseconds:80_000_000);try check(view.animationStatus == .staticImage && dominant(view,2),"rapid replace retains correct poster")
        var transient:NativeUserAvatarView?=NativeUserAvatarView(frame:NSRect(x:50,y:30,width:128,height:128));weak var weakView=transient
        transient!.decoderExecutableURL=helper;container.addSubview(transient!);transient!.setAnimationSource{try own("wide-infinite")}
        try await wait("transient worker running"){transient?.animationStatus == .playing};transient!.removeFromSuperview();transient=nil
        try await wait("deallocated view stops helper"){weakView==nil && NativeUserAvatarWorkerClient.testingActivePIDs.isEmpty}
        let proof:[String:Any]=["checks":checks,"reads":reads,"launchCount":NativeUserAvatarWorkerClient.testingLaunchCount,"remainingPIDs":Array(NativeUserAvatarWorkerClient.testingActivePIDs),"mainActorCancelSeconds":synchronousCancel,"finite16MP":measured,"trace":trace,"scope":"Candidate copies only, actual NSPanel sheet, current AppKit/Store loader contract; small inline + 16MP worker; auth/visibility/generation; noncooperative load; TERM-resistant cancel; finite END; detach and deallocation. No CRM app/data."]
        try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("view-native.json"))
    }
}
