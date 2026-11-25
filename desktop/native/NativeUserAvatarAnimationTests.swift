import AppKit
import ImageIO
import Darwin

@main enum NativeUserAvatarAnimationTests {
    final class AppDelegate:NSObject,NSApplicationDelegate {
        func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { trace.append("AppKit requested termination (blocked for fixture)");return .terminateCancel }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    }
    static let delegate = AppDelegate()
    struct Failure: Error, LocalizedError { let text:String;var errorDescription:String? { text } }
    static var checks = 0
    static var trace:[String]=[]
    static func check(_ value:@autoclosure()throws->Bool,_ label:String)throws { guard try value() else { throw Failure(text:label) };checks += 1 }
    static func rejects(_ expected:NativeUserAvatarAnimation.Failure,_ label:String,_ body:()throws->Void)throws {
        do { try body() } catch let failure as NativeUserAvatarAnimation.Failure { try check(failure == expected,label);return }
        throw Failure(text:"accepted "+label)
    }
    static func color(_ image:CGImage,_ x:Int,_ y:Int)->[Int] {
        var pixel = [UInt8](repeating:0,count:4)
        pixel.withUnsafeMutableBytes { p in
            let context = CGContext(data:p.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none;context.draw(image.cropping(to:CGRect(x:x,y:y,width:1,height:1))!,in:CGRect(x:0,y:0,width:1,height:1))
        }
        return pixel.map(Int.init)
    }
    static func footprint()->UInt64 {
        var info = task_vm_info_data_t(),count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func matches(_ actual:[Int],_ expected:[Int],_ tolerance:Int)->Bool {
        let premultiplied=expected.enumerated().map { $0.offset==3 ? $0.element:Int((Double($0.element)*Double(expected[3])/255).rounded()) }
        return zip(actual,premultiplied).allSatisfy { abs($0-$1)<=tolerance }
    }
    @MainActor static func wait(_ label:String,timeout:Double=3,_ predicate:()->Bool)async throws {
        let start=Date();while !predicate() && Date().timeIntervalSince(start)<timeout { try await Task.sleep(nanoseconds:10_000_000) }
        try check(predicate(),label)
    }
    @MainActor static func main() {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.accessory);NSApp.delegate=delegate
        Task { @MainActor in
            do { try await run();print("Avatar animation: \(checks) decoder, lifecycle and bounds checks passed");exit(0) }
            catch { fputs("After \(checks): \(error.localizedDescription)\n\(trace.suffix(16).joined(separator:" | "))\n",stderr);exit(1) }
        }
        NSApp.run();fputs("AppKit run loop ended before fixture completion\n",stderr);exit(1)
    }
    @MainActor static func run()async throws {
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try JSONSerialization.jsonObject(with:Data(contentsOf:native.appendingPathComponent("build/user-avatar-animation-reference.json"))) as! [String:Any]
        let fixtures=reference["fixtures"] as! [[String:Any]]
        func data(_ name:String)throws->Data { try Data(contentsOf:native.appendingPathComponent(fixtures.first{$0["name"] as? String == name}!["file"] as! String)) }
        var metadata:[[String:Any]]=[]
        for fixture in fixtures {
            let name=fixture["name"] as! String,bytes=try data(name)
            if name.hasSuffix("oversize") { try rejects(.canvasLimit,name){_ = try NativeUserAvatarAnimation(data:bytes)};continue }
            let decoder=try NativeUserAvatarAnimation(data:bytes),expectedCount=fixture["frameCount"] as! Int,iterations=fixture["iterations"] as! Int
            try check(decoder.decodedFrameCount == 0,name+" no eager pixel decode")
            try check(decoder.frameCount == expectedCount,name+" frame count")
            try check(decoder.iterations == (iterations == 0 ? nil : iterations),name+" loops")
            let expected=fixture["samples"] as! [[String:Any]],delays=fixture["delay"] as! [Double],tolerance=fixture["tolerance"] as? Int ?? 0
            for i in 0..<(expectedCount*(iterations == 0 ? 3:iterations)) {
                try autoreleasepool {
                    let frame=try decoder.nextFrame()!
                    try check(frame.index == i%expectedCount,name+" sequential index")
                    try check(frame.image.width<=256 && frame.image.height<=256 && frame.image.bytesPerRow*frame.image.height<=262144,name+" independent bitmap bound")
                    try check(matches(color(frame.image,frame.image.width/2,frame.image.height/2),expected[frame.index]["center"] as! [Int],tolerance),name+" composite center")
                    let corner=color(frame.image,1,1),expectedCorner=expected[frame.index]["corner"] as! [Int]
                    try check(matches(corner,expectedCorner,tolerance),name+" delta/disposal corner frame \(frame.index): \(corner) != \(expectedCorner)")
                    try check(abs(frame.delay-NativeUserAvatarAnimation.delay(delays[frame.index]/1000))<0.000001,name+" delay")
                }
            }
            if iterations>0 { try check(try decoder.nextFrame()==nil,name+" final frame stops") }
            metadata.append(["name":name,"frames":decoder.frameCount,"iterations":decoder.iterations as Any? ?? NSNull(),"decoded":decoder.decodedFrameCount])
        }
        for (value,expected) in [(nil,0.1),(Double.nan,0.1),(Double.infinity,0.1),(-1.0,0.1),(0.0,0.1),(0.01,0.1),(0.02,0.02),(655.35,655.35),(16777.215,16777.215)] as [(Double?,Double)] {
            try check(NativeUserAvatarAnimation.delay(value)==expected,"delay boundary")
        }
        try rejects(.invalid,"empty"){_ = try NativeUserAvatarAnimation(data:Data())}
        try rejects(.invalid,"junk"){_ = try NativeUserAvatarAnimation(data:Data("not an image".utf8))}
        try rejects(.inputLimit,"compressed cap"){_ = try NativeUserAvatarAnimation(data:Data(repeating:0,count:4*1024*1024+1))}
        let gif=try data("gif-infinite"),webp=try data("webp-infinite")
        func parserRejects(_ label:String,_ bytes:Data,decode:Bool=false)throws {
            do { let p=try NativeUserAvatarWebPAnimation(data:bytes);if decode { _ = try p.image(at:0) } }
            catch is NativeUserAvatarAnimation.Failure { checks += 1;return }
            throw Failure(text:"accepted WebP "+label)
        }
        for count in [0,4,11,29,webp.count-1] { try parserRejects("truncation \(count)",webp.prefix(count)) }
        let extended=webp.range(of:Data("VP8X".utf8))!.lowerBound,animation=webp.range(of:Data("ANIM".utf8))!.lowerBound,frame=webp.range(of:Data("ANMF".utf8))!.lowerBound
        for (label,offset,bytes) in [("RIFF length",4,[255,255,255,255]),("chunk length",extended+4,[255,255,255,255]),("reserved flags",extended+8,[255]),("oversize canvas",extended+12,[255,255,255]),("ANIM length",animation+4,[5]),("frame outside canvas",frame+8,[255,255,255]),("frame extent",frame+14,[255,255,255]),("frame reserved flags",frame+23,[4]),("subchunk overflow",frame+28,[255,255,255,255]),("missing frame pixels",frame+24,[88,88,88,88])] as [(String,Int,[UInt8])] {
            var bad=webp;bad.replaceSubrange(offset..<(offset+bytes.count),with:bytes);try parserRejects(label,bad)
        }
        var corruptPixels=webp;corruptPixels[frame+32]=0
        try parserRejects("corrupt compressed frame",corruptPixels,decode:true)
        let prefixed=Data([255])+webp
        try check(try NativeUserAvatarWebPAnimation(data:prefixed.suffix(webp.count)).frameCount==3,"nonzero-index Data slice")
        do { _ = try NativeUserAvatarWebPAnimation(data:webp).image(at:99);throw Failure(text:"accepted bad frame index") }
        catch is NativeUserAvatarAnimation.Failure { checks += 1 }
        try rejects(.invalid,"truncated header"){_ = try NativeUserAvatarAnimation(data:gif.prefix(10))}
        var canvasHeader=gif;canvasHeader[6]=0xff;canvasHeader[7]=0xff
        try rejects(.canvasLimit,"global GIF canvas larger than delta frame"){_ = try NativeUserAvatarAnimation(data:canvasHeader)}
        var padded=gif;padded.append(Data(repeating:0,count:4*1024*1024-padded.count))
        try check(try NativeUserAvatarAnimation(data:padded).compressedBytes==4*1024*1024,"exact input cap")
        padded.removeAll()
        var maximumLoop=gif;let loopOffset=maximumLoop.range(of:Data("NETSCAPE2.0".utf8))!.lowerBound+13
        maximumLoop[loopOffset]=0xff;maximumLoop[loopOffset+1]=0xff
        try check(try NativeUserAvatarAnimation(data:maximumLoop).iterations==65536,"ImageIO normalizes maximum GIF repeat count")
        let cancelled=Task.detached { ()throws->Bool in
            try await Task.sleep(nanoseconds:50_000_000)
            _ = try NativeUserAvatarAnimation(data:gif);return false
        };cancelled.cancel()
        do { _ = try await cancelled.value;throw Failure(text:"cancel accepted") } catch is CancellationError { checks += 1 }
        var ready=false
        let pause=AsyncStream<Void> { _ in }
        let cancelledDecode=Task.detached { ()throws->Bool in
            let decoder=try NativeUserAvatarAnimation(data:gif)
            await MainActor.run { ready=true }
            for await _ in pause { }
            _ = try decoder.nextFrame();return false
        }
        try await wait("decoder reached cancellation boundary"){ready};cancelledDecode.cancel()
        do { _ = try await cancelledDecode.value;throw Failure(text:"cancelled frame accepted") } catch is CancellationError { checks += 1 }
        var retained:CGImage?,weakDecoder:NativeUserAvatarAnimation?
        weak var released:NativeUserAvatarAnimation?
        weakDecoder=try NativeUserAvatarAnimation(data:gif);released=weakDecoder
        retained=try weakDecoder?.nextFrame()?.image;weakDecoder=nil
        try check(released==nil && retained != nil,"display frame does not retain decoder");retained=nil
        // Real bounded-canvas repeated decode: warm the codec then compare growth.
        var memory:[String:Any]=[:]
        for format in ["gif","webp"] {
            let large=try data(format+"-large"),start=ProcessInfo.processInfo.systemUptime
            var decoder:NativeUserAvatarAnimation?=try NativeUserAvatarAnimation(data:large)
            // Finite fixture is reopened after two passes; no decoded frame survives.
            func frames(_ n:Int)throws {
                for _ in 0..<n { try autoreleasepool { if try decoder!.nextFrame()==nil { decoder=try NativeUserAvatarAnimation(data:large);_ = try decoder!.nextFrame() } } }
            }
            try frames(24);let warm=footprint();try frames(120);let middle=footprint();try frames(240);let end=footprint();decoder=nil
            try check(warm>0 && end < warm+16*1024*1024,"bounded repeated decode "+format)
            memory[format]=["warmBytes":warm,"after120Bytes":middle,"after240MoreBytes":end,"seconds":ProcessInfo.processInfo.systemUptime-start,"canvas":"1024x1024","frames":384]
        }
        if CommandLine.arguments.contains("--decoder-only") {
            let report:[String:Any]=["checks":checks,"metadata":metadata,"memory":memory,"decoderOnly":true]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-animation-native-decoder.json"));return
        }
        let window=NSWindow(contentRect:NSRect(x:80,y:80,width:180,height:180),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.title="隔離アバター再生検証";window.level = .floating
        let container=NSView(frame:NSRect(x:0,y:0,width:180,height:180));window.contentView=container
        var avatar:NativeUserAvatarView?=NativeUserAvatarView(frame:NSRect(x:30,y:30,width:100,height:100))
        var loads=0;let thumbnail=try NativeUserAvatarAnimation(data:gif).nextFrame()!.image
        avatar!.onAnimationStatusChange = { status in trace.append("\(status) loads=\(loads) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue)");try? trace.joined(separator:"\n").write(to:native.appendingPathComponent("build/user-avatar-animation-progress.txt"),atomically:true,encoding:.utf8) }
        avatar!.set(image:thumbnail,name:"表示試験")
        avatar!.setAnimationSource { loads += 1;return gif }
        try await Task.sleep(nanoseconds:50_000_000);try check(loads==0,"detached view performs no load")
        avatar!.isHidden=true;container.addSubview(avatar!);window.orderFrontRegardless()
        try await Task.sleep(nanoseconds:80_000_000);try check(loads==0,"initially hidden view performs no load")
        avatar!.isHidden=false
        try await wait("visible starts playback"){avatar!.animationStatus == .playing}
        for _ in 0..<10 { avatar!.refreshAnimationVisibility() };try check(loads==1,"visibility updates do not duplicate tasks")
        container.isHidden=true
        try await wait("hidden ancestor pauses"){avatar!.animationStatus == .paused}
        try check(avatar!.animationFrameIndex==nil,"pause releases animated frame")
        try await Task.sleep(nanoseconds:150_000_000);try check(loads==1 && avatar!.animationStatus == .paused,"hidden remains idle")
        let restoredStart=ProcessInfo.processInfo.systemUptime;container.isHidden=false
        try await wait("ancestor restoration restarts"){avatar!.animationStatus == .playing && loads==2}
        let restartMS=(ProcessInfo.processInfo.systemUptime-restoredStart)*1000
        window.orderOut(nil);try await wait("orderOut pauses"){avatar!.animationStatus == .paused}
        window.orderFrontRegardless();try await wait("orderFront restarts"){avatar!.animationStatus == .playing && loads>=3}
        // Real WindowServer occlusion, separate from hide/orderOut.
        let cover=NSWindow(contentRect:window.frame,styleMask:.borderless,backing:.buffered,defer:false)
        cover.isReleasedWhenClosed=false;cover.level=NSWindow.Level(rawValue:window.level.rawValue+1);cover.backgroundColor = .black;cover.isOpaque=true;cover.orderFrontRegardless()
        try await wait("covered window pauses",timeout:5){avatar!.animationStatus == .paused}
        let beforeUncover=loads;cover.close();try await wait("uncovered window restarts"){avatar!.animationStatus == .playing && loads>beforeUncover}
        window.miniaturize(nil);try await wait("miniaturize pauses"){avatar!.animationStatus == .paused}
        let beforeDeminiaturize=loads;window.deminiaturize(nil);window.orderFrontRegardless();try await wait("deminiaturize restarts"){avatar!.animationStatus == .playing && loads>beforeDeminiaturize}
        avatar!.removeFromSuperview();try await wait("removed view pauses"){avatar!.animationStatus == .paused}
        let beforeReattach=loads;container.addSubview(avatar!);try await wait("reattached view restarts"){avatar!.animationStatus == .playing && loads>beforeReattach}
        avatar!.setAnimationSource { throw Failure(text:"secret path MUST NOT APPEAR") }
        try await wait("load failure is visible"){if case .unavailable = avatar!.animationStatus { return true };return false}
        try check(!avatar!.animationStatus.message.contains("secret"),"failure text is sanitized")
        avatar!.setAnimationSource { try data("gif-oversize") }
        try await wait("large helper-unavailable reason"){avatar!.animationStatus.message == NativeUserAvatarWorkerFailure.helperUnavailable.errorDescription}
        // A late, noncooperative async load may finish, but cannot publish a frame.
        var pending:CheckedContinuation<Data?,Error>?
        avatar!.setAnimationSource { try await withCheckedThrowingContinuation { pending=$0 } }
        try await wait("pending load began"){pending != nil}
        avatar!.set(image:thumbnail,name:"差替え");pending!.resume(returning:webp);pending=nil
        try await Task.sleep(nanoseconds:80_000_000)
        try check(avatar!.animationStatus == .staticImage && avatar!.animationFrameIndex==nil,"stale load cannot override replacement")
        let finite=try data("webp-once");avatar!.setAnimationSource { finite }
        try await wait("finite playback ends",timeout:3){avatar!.animationStatus == .finished}
        try check(avatar!.animationFrameIndex==2,"finite loop retains final frame")
        try await Task.sleep(nanoseconds:100_000_000);try check(avatar!.animationStatus == .finished,"completed task does not auto-restart")
        var hiddenLoad=0
        avatar!.setAnimationSource { hiddenLoad += 1;return gif };avatar!.isHidden=true
        try await Task.sleep(nanoseconds:60_000_000);try check(hiddenLoad==0,"immediate hide cancels before original read")
        avatar!.isHidden=false
        avatar!.setAnimationSource { gif };try await wait("release test playing"){avatar!.animationStatus == .playing}
        weak var weakView=avatar;avatar!.removeFromSuperview();avatar=nil
        try await Task.sleep(nanoseconds:50_000_000);try check(weakView==nil,"active playback does not retain view")
        var pendingView:NativeUserAvatarView?=NativeUserAvatarView(frame:NSRect(x:0,y:0,width:100,height:100));container.addSubview(pendingView!)
        pendingView!.setAnimationSource { try await withCheckedThrowingContinuation { pending=$0 } }
        try await wait("pending release begins"){pending != nil}
        weak var weakPending=pendingView;pendingView!.removeFromSuperview();pendingView=nil
        try await Task.sleep(nanoseconds:50_000_000)
        try check(weakPending==nil,"pending async load does not retain view");pending!.resume(returning:gif);pending=nil
        // Real NSPanel sheets (including a nested administrative/profile sheet),
        // as used by the application rather than only standalone NSWindow.
        NSApp.activate(ignoringOtherApps:true)
        let administration=NSPanel(contentRect:NSRect(x:0,y:0,width:240,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        let profile=NSPanel(contentRect:NSRect(x:0,y:0,width:220,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        administration.isReleasedWhenClosed=false;profile.isReleasedWhenClosed=false
        let sheetAvatar=NativeUserAvatarView(frame:NSRect(x:40,y:30,width:104,height:104));profile.contentView!.addSubview(sheetAvatar)
        var sheetLoads=0;sheetAvatar.set(image:thumbnail,name:"シート試験")
        sheetAvatar.setAnimationSource { sheetLoads += 1;return gif }
        window.beginSheet(administration,completionHandler:nil);administration.beginSheet(profile,completionHandler:nil)
        try await wait("nested NSPanel sheet starts playback"){sheetAvatar.animationStatus == .playing}
        let sheetState:[String:Any]=["active":NSApp.isActive,"hidden":NSApp.isHidden,"visible":profile.isVisible,"occlusion":profile.occlusionState.rawValue,"parentVisible":administration.isVisible,"boundsWidth":sheetAvatar.bounds.width,"visibleWidth":sheetAvatar.visibleRect.width]
        sheetAvatar.isHidden=true;try await wait("sheet hidden view pauses"){sheetAvatar.animationStatus == .paused}
        let oldSheetLoads=sheetLoads;sheetAvatar.isHidden=false
        try await wait("sheet shown view restarts"){sheetAvatar.animationStatus == .playing && sheetLoads>oldSheetLoads}
        // A source selected while a child sheet is present must resume after it
        // ends; no Store or NSOpenPanel filesystem authority is involved here.
        let selection=NSPanel(contentRect:NSRect(x:0,y:0,width:220,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false);selection.isReleasedWhenClosed=false
        profile.beginSheet(selection,completionHandler:nil);sheetAvatar.set(image:thumbnail,name:"再選択");sheetAvatar.setAnimationSource { sheetLoads += 1;return webp }
        profile.endSheet(selection);selection.orderOut(nil);selection.close()
        try await wait("selection child sheet completion resumes"){sheetAvatar.animationStatus == .playing}
        administration.endSheet(profile);profile.orderOut(nil)
        try await wait("ending profile sheet pauses"){sheetAvatar.animationStatus == .paused}
        profile.close();window.endSheet(administration);administration.orderOut(nil);administration.close()
        window.close()
        try await Task.sleep(nanoseconds:50_000_000)
        let report:[String:Any]=["checks":checks,"metadata":metadata,"memory":memory,"visibilityReloads":loads,"restartFirstFrameMS":restartMS,"sheetState":sheetState,"sheetLoads":sheetLoads,"limitations":["A synchronous ImageIO decode already in progress finishes before cancellation; no later frame publishes.","ImageIO internal composition/caches are opaque. Per-frame bitmap <=256KiB and input/canvas caps are enforced; whole-process memory is measured, not guaranteed.","Visibility restoration rereads/revalidates compressed bytes and frame metadata and restarts at frame 0; playback progress is deliberately not retained offscreen."]]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-animation-native.json"))
    }
}
