import AppKit
import ImageIO

@main enum NativeUserAvatarAPNGViewTests {
    struct Failure:Error{let text:String}
    static var checks=0
    @MainActor static func check(_ test:@autoclosure()throws->Bool,_ text:String)throws{guard try test()else{throw Failure(text:text)};checks += 1}
    @MainActor static func wait(_ label:String,_ predicate:()->Bool)async throws{let start=ProcessInfo.processInfo.systemUptime;while !predicate() && ProcessInfo.processInfo.systemUptime-start<4{try await Task.sleep(nanoseconds:10_000_000)};try check(predicate(),label)}
    @MainActor static func color(_ view:NSView)->[Int]{let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:rep);let c=rep.colorAt(x:rep.pixelsWide/2,y:rep.pixelsHigh/2)!.usingColorSpace(.sRGB)!;return [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent].map{Int(($0*255).rounded())}}
    @MainActor static func dominant(_ view:NSView,_ channel:Int)->Bool{let c=color(view);return c[channel]>=180 && (0..<3).filter{$0 != channel}.allSatisfy{c[channel]-c[$0]>=80} && c[3]==255}
    @MainActor static func main(){_ = NSApplication.shared;NSApp.setActivationPolicy(.accessory);Task{@MainActor in do{try await run();print("APNG view: \(checks) checks passed");exit(0)}catch{fputs("APNG view after \(checks): \(error)\n",stderr);exit(1)}};NSApp.run()}
    @MainActor static func run()async throws{
        let native=URL(fileURLWithPath:CommandLine.arguments[1])
        func data(_ name:String)throws->Data{try Data(contentsOf:native.appendingPathComponent("build/avatar-apng/"+name+".png"))}
        for (name,expected) in [("singleIncluded",false),("singleExcluded",true),("singleExcludedInfinite",true),("excludedPoster",true)]{let decoder=try NativeUserAvatarAnimation(data:data(name));try check(decoder.requiresInitialFrameDisplay==expected,name+" poster flag")}
        let wrapper=try NativeUserAvatarAnimation(data:data("finite"));var frames=0;while let f=try wrapper.nextFrame(){try check(f.index==frames%3,"wrapper loop index");try check(abs(f.delay-0.1)<0.000001,"wrapper delay");try check(f.image.width==4 && f.image.height==4,"wrapper center crop");frames += 1};try check(frames==6 && wrapper.decodedFrameCount==6,"wrapper finite end")
        let context=CGContext(data:nil,width:6,height:4,bitsPerComponent:8,bytesPerRow:24,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;context.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));context.fill(CGRect(x:0,y:0,width:6,height:4));let poster=context.makeImage()!
        let window=NSWindow(contentRect:NSRect(x:120,y:130,width:320,height:250),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="APNG isolated avatar checks";window.isReleasedWhenClosed=false
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:220,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false);panel.isReleasedWhenClosed=false
        let view=NativeUserAvatarView(frame:NSRect(x:45,y:25,width:128,height:128));panel.contentView!.addSubview(view);view.set(image:poster,name:"検証")
        var reads=0;view.setAnimationSource{reads += 1;return try data("singleExcluded")}
        try await Task.sleep(nanoseconds:60_000_000);try check(reads==0,"hidden never reads original")
        NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);window.beginSheet(panel,completionHandler:nil)
        try await wait("single-frame APNG replaces poster in sheet"){view.animationStatus == .staticImage && view.animationFrameIndex==0}
        try check(reads==1,"one authorized read");try check(dominant(view,1),"actual view shows animation green: \(color(view))")
        view.isHidden=true;view.refreshAnimationVisibility();try await wait("hidden pauses"){view.animationStatus == .paused && view.animationFrameIndex==nil}
        let hiddenReads=reads;try await Task.sleep(nanoseconds:80_000_000);try check(reads==hiddenReads,"hidden has no reread/timer")
        view.isHidden=false;view.refreshAnimationVisibility();try await wait("single-frame visible rereads"){reads==2 && view.animationFrameIndex==0 && view.animationStatus == .staticImage};try check(dominant(view,1),"restored APNG frame")
        view.setAnimationSource{reads += 1;return try data("infinite")};try await wait("APNG multi-frame playing"){view.animationStatus == .playing && view.animationFrameIndex==1};try check(dominant(view,1),"multiframe green rendered")
        view.setAnimationSource{reads += 1;return try data("singleExcludedInfinite")};try await wait("one-frame infinite is static after first display"){view.animationStatus == .staticImage && view.animationFrameIndex==0};let once=reads;try await Task.sleep(nanoseconds:220_000_000);try check(reads==once,"one-frame APNG has no ongoing loader/timer")
        var pendingStarted=false,pendingReturned=false
        view.setAnimationSource{pendingStarted=true;let bytes=try data("singleExcluded");return await withCheckedContinuation{continuation in DispatchQueue.main.asyncAfter(deadline:.now()+0.15){pendingReturned=true;continuation.resume(returning:bytes)}}}
        try await wait("noncooperative loader started"){pendingStarted};view.set(image:poster,name:"取消")
        try await wait("old loader returned"){pendingReturned};try await Task.sleep(nanoseconds:50_000_000);try check(view.animationStatus == .staticImage && view.animationFrameIndex==nil,"cancel fences old APNG");try check(dominant(view,2),"cancel leaves replacement poster")
        view.setAnimationSource{try data("singleExcluded")};try await wait("sheet redraw"){view.animationFrameIndex==0};window.endSheet(panel);panel.orderOut(nil);view.refreshAnimationVisibility();try await wait("closed sheet pauses"){view.animationStatus == .paused};window.orderOut(nil)
        let report:[String:Any]=["checks":checks,"scope":"Current production wrapper/APNG/View with real nested NSPanel sheet; single excluded-poster frame including infinite declaration, actual center pixel, hidden/read/resume, loop, noncooperative cancellation and sheet end."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-apng-view-native.json"))
    }
}
