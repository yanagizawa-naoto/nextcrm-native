import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import Darwin

@main enum NativeUserAvatarMetadataTests {
    struct Error:Swift.Error { let label:String }
    static var checks=0
    static func check(_ test:@autoclosure()throws->Bool,_ label:String)throws { guard try test()else{throw Error(label:label)};checks += 1 }
    static func memory()->[String:UInt64] { var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);_ = withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}};return ["current":info.phys_footprint,"peak":UInt64(max(0,info.ledger_phys_footprint_peak))] }
    static func color(_ image:CGImage)->[UInt8] { var value=[UInt8](repeating:0,count:4);value.withUnsafeMutableBytes { let c=CGContext(data:$0.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:1,height:1)) };return value }
    static func main()async { do{try await run()}catch{fputs("Metadata test after \(checks): \(error)\n",stderr);exit(1)} }
    static func run()async throws {
        let input=URL(fileURLWithPath:CommandLine.arguments[1]),expected=Int(CommandLine.arguments[2])!,native=URL(fileURLWithPath:CommandLine.arguments[3]),data=try Data(contentsOf:input),suffix=input.pathExtension=="gif" ? "-gif":""
        let start=ProcessInfo.processInfo.systemUptime,decoder=try NativeUserAvatarAnimation(data:data),initialized=memory()
        try check(data.count==4*1024*1024,"maximum original bytes")
        try check(decoder.frameCount==expected && expected>80000,"frame count from bounded scan")
        try check(decoder.decodedFrameCount==0,"metadata never decodes frame pixels")
        try check(decoder.iterations==1,"finite original ANIM loop")
        var samples:[[String:Any]]=[],warm:UInt64=0
        for i in 0..<expected {
            try autoreleasepool {
                guard let frame=try decoder.nextFrame(),frame.index==i,abs(frame.delay-0.02)<0.000001 else{throw Error(label:"frame order/delay \(i)")}
                if i==0 || i==500 || i==1000 || i%10000==0 || i==expected-1 {
                    try check(frame.image.width==2 && frame.image.height==2 && color(frame.image)==[255,0,0,255],"original opaque red frame \(i)")
                }
            }
            if i==1000 {warm=memory()["current"]!}
            if i==0 || i%10000==0 || i==expected-1 { samples.append(["frame":i,"memory":memory()]) }
        }
        try check(decoder.decodedFrameCount==expected,"all original frames decoded")
        try check(try decoder.nextFrame()==nil,"finite stream ends at last frame")
        try check(memory()["current"]! <= warm+8*1024*1024,"no per-frame retained allocation growth")
        // ImageIO ignores ANIMEXTS1.0, but the original browser recognizes it.
        // Compare playback with actual source-style browser behavior and record
        // the old ImageIO difference separately.
        let fixture=try Data(contentsOf:native.appendingPathComponent("build/avatar-animation/gif-finite.gif"))
        var gifs:[Data]=[fixture]
        let marker=fixture.range(of:Data("NETSCAPE2.0".utf8))!,appStart=marker.lowerBound-3,appEnd=marker.lowerBound+16
        let extensionBytes=Data(fixture[appStart..<appEnd])
        var alternate=fixture;alternate.replaceSubrange(marker,with:Data("ANIMEXTS1.0".utf8));gifs.append(alternate)
        for position in [appStart,fixture.count-1] {
            var extra=extensionBytes;extra[16]=3;extra[17]=0
            var duplicate=fixture;duplicate.insert(contentsOf:extra,at:position);gifs.append(duplicate)
        }
        let browser=try JSONSerialization.jsonObject(with:Data(contentsOf:native.appendingPathComponent("build/user-avatar-gif-loop-reference.json"))) as! [String:Any]
        let loopCases=browser["cases"] as! [[String:Any]];var loopResults:[[String:Any]]=[]
        for (i,gif) in gifs.enumerated() {
            let source=CGImageSourceCreateWithData(gif as CFData,nil)!,p=CGImageSourceCopyProperties(source,nil) as! [String:Any],dict=p[kCGImagePropertyGIFDictionary as String] as! [String:Any]
            let loop=(dict[kCGImagePropertyGIFLoopCount as String] as? NSNumber)?.intValue ?? 1,expectedLoop=loopCases[i]["iterations"] as! Int
            let actual=try NativeUserAvatarAnimation(data:gif)
            try check(SHA256.hash(data:gif).map{String(format:"%02x",$0)}.joined()==loopCases[i]["sha256"] as! String,"browser/native same GIF \(i)")
            try check(actual.iterations==expectedLoop,"GIF loop extension original browser \(i)")
            loopResults.append(["case":i,"browserIterations":expectedLoop,"nativeIterations":actual.iterations as Any? ?? NSNull(),"oldImageIOIterations":loop])
        }
        // Existing metadata skip rules must not let malformed framing allocate
        // or index past the immutable compressed input.
        for end in [0,1,6,10,12,20,fixture.count-1] {
            do{_ = try NativeUserAvatarAnimation(data:fixture.prefix(end));throw Error(label:"truncated GIF accepted \(end)")}
            catch is NativeUserAvatarAnimation.Failure {checks += 1}
        }
        var bad=fixture;let imageSeparator=bad.firstIndex(of:0x2c)!;bad[imageSeparator+1]=255;bad[imageSeparator+2]=255
        do{_ = try NativeUserAvatarAnimation(data:bad);throw Error(label:"out of canvas GIF accepted")}
        catch is NativeUserAvatarAnimation.Failure {checks += 1}
        let report:[String:Any]=["checks":checks,"decodedFrames":expected,"format":input.pathExtension,"initializedMemory":initialized,"warmMemory":warm,"samples":samples,"finalMemory":memory(),"gifLoops":loopResults,"seconds":ProcessInfo.processInfo.systemUptime-start,"scope":"Current production two-file decoder, max4MiB input, all frames decoded without delay waits. GIF loop extension oracle uses actual original-style browser playback and records old ImageIO differences." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-metadata-native"+suffix+".json"))
        print("Metadata: \(checks) checks; \(expected) frames decoded")
    }
}
