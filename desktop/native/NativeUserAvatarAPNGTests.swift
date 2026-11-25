import Foundation
import CoreGraphics
import CryptoKit
import Darwin

@main enum NativeUserAvatarAPNGTests {
    struct Failure:Error {let text:String}
    static var checks=0
    static func check(_ test:@autoclosure()throws->Bool,_ text:String)throws{guard try test()else{throw Failure(text:text)};checks += 1}
    static func pixels(_ image:CGImage)->[UInt8]{var bytes=[UInt8](repeating:0,count:image.width*image.height*4);bytes.withUnsafeMutableBytes{p in let c=CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};return bytes}
    static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func memory()->[String:UInt64]{var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/4);_ = withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return ["current":i.phys_footprint,"peak":UInt64(max(0,i.ledger_phys_footprint_peak))]}
    static func main()async{do{try await run()}catch{fputs("APNG after \(checks): \(error)\n",stderr);exit(1)}}
    static func run()async throws{
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try JSONSerialization.jsonObject(with:Data(contentsOf:native.appendingPathComponent("build/user-avatar-apng-reference.json"))) as! [String:Any]
        var results:[[String:Any]]=[],differences:[[String:Any]]=[]
        for c in reference["cases"] as! [[String:Any]]{try autoreleasepool{
            let name=c["name"] as! String,data=try Data(contentsOf:URL(fileURLWithPath:c["file"]as! String)),decoder=try NativeUserAvatarAPNGAnimation(data:data),browser=c["browser"]as! [String:Any],frames=browser["frames"]as! [[String:Any]],plays=c["plays"]as! Int
            try check(hash(data)==c["sha256"]as! String,name+" input hash");try check(decoder.frameCount==frames.count,name+" count");try check(decoder.iterations==(plays==0 ? nil:plays),name+" loop");try check(decoder.defaultIsFirstFrame==c["defaultIsFirstFrame"]as! Bool,name+" default image");try check(decoder.decodedFrameCount==0,name+" no eager pixels")
            for i in 0..<(frames.count*(plays==0 ? 3:plays)){try autoreleasepool{guard let f=try decoder.nextFrame()else{throw Failure(text:name+" missing frame")};let expected=frames[i%frames.count],bytes=pixels(f.image),sha=hash(Data(bytes));try check(f.index==i%frames.count,name+" sequence")
                if sha != expected["sha256"]as! String {let raw=expected["rgba"]as? [Int] ?? [],premult=raw.enumerated().map{j,v in j%4==3 ? v:Int((Double(v)*Double(raw[j-j%4+3])/255).rounded())},maxDiff=zip(bytes,premult).map{abs(Int($0)-$1)}.max() ?? 0;differences.append(["name":name,"frame":f.index,"maxChannelDifference":maxDiff,"native":Array(bytes.prefix(24)),"browser":Array(premult.prefix(24))])}else{checks += 1}
                if let duration=expected["duration"]as? NSNumber {let rawDelay=duration.doubleValue/1_000_000,delay=rawDelay<0.011 ? 0.1:rawDelay;try check(abs(f.delay-delay)<0.0000001,name+" delay")}else{try check(frames.count==1,name+" static one-frame timing")}
            }}
            if plays>0{try check(try decoder.nextFrame()==nil,name+" final stop")};results.append(["name":name,"frames":decoder.frameCount,"decoded":decoder.decodedFrameCount])
        }}
        if !differences.isEmpty{print(differences.prefix(4))}
        let valid=try Data(contentsOf:native.appendingPathComponent("build/avatar-apng/once.png")),prefixed=Data([255])+valid
        try check(try NativeUserAvatarAPNGAnimation(data:prefixed.suffix(valid.count)).frameCount==3,"Data slice normalized")
        for length in [0,1,7,8,12,32,valid.count-1]{do{_ = try NativeUserAvatarAPNGAnimation(data:valid.prefix(length));throw Failure(text:"truncation accepted \(length)")}catch is NativeUserAvatarAPNGAnimation.Failure{checks += 1}}
        for file in try FileManager.default.contentsOfDirectory(at:native.appendingPathComponent("build/avatar-apng-invalid"),includingPropertiesForKeys:nil){do{let d=try NativeUserAvatarAPNGAnimation(data:Data(contentsOf:file));while try d.nextFrame() != nil{};throw Failure(text:"invalid accepted "+file.lastPathComponent)}catch is NativeUserAvatarAPNGAnimation.Failure{checks += 1}}
        let task=Task.detached{try await Task.sleep(nanoseconds:50_000_000);return try NativeUserAvatarAPNGAnimation(data:valid)};task.cancel();do{_ = try await task.value;throw Failure(text:"cancel init")}catch is CancellationError{checks += 1}
        let task2=Task.detached{let d=try NativeUserAvatarAPNGAnimation(data:valid);withUnsafeCurrentTask{$0?.cancel()};return try d.nextFrame()};do{_ = try await task2.value;throw Failure(text:"cancel decode")}catch is CancellationError{checks += 1}
        let report:[String:Any]=["checks":checks,"cases":results,"differences":differences,"memory":memory(),"scope":"Independent APNG prototype: exact premultiplied RGBA and delay/loop metadata against actual Chrome; malformed framing/CRC/decoded payload, cancellation, Data slices." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-apng-native.json"));print("APNG: \(checks) checks; RGBA differences \(differences.count)")
        if !differences.isEmpty{print(differences.prefix(6));exit(1)}
    }
}
