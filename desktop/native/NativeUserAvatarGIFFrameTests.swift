import Foundation
import CoreGraphics
import CryptoKit
import Darwin

@main enum NativeUserAvatarGIFFrameTests {
    static func memory()->[String:UInt64] {var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/4);_ = withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return ["current":i.phys_footprint,"peak":UInt64(max(0,i.ledger_phys_footprint_peak))]}
    static func sha(_ image:CGImage)->String {var bytes=[UInt8](repeating:0,count:image.width*image.height*4);bytes.withUnsafeMutableBytes{p in let c=CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))};return SHA256.hash(data:Data(bytes)).map{String(format:"%02x",$0)}.joined()}
    static func main()throws {
        let native=URL(fileURLWithPath:CommandLine.arguments[1]),reference=try JSONSerialization.jsonObject(with:Data(contentsOf:native.appendingPathComponent("build/user-avatar-gif-frame-reference.json"))) as! [String:Any]
        var checks=0,failures:[String]=[],samples:[[String:Any]]=[];let start=ProcessInfo.processInfo.systemUptime
        let browserCases=reference["browserCases"] as! [[String:Any]]
        for c in reference["cases"] as! [[String:Any]] {try autoreleasepool {let d=try NativeUserAvatarGIFFramePrototype(data:Data(contentsOf:URL(fileURLWithPath:c["file"] as! String))),name=c["name"] as! String,expected=(browserCases.first{$0["name"] as? String==name}?["frames"] ?? c["frames"]) as! [String]
            if d.frameCount != expected.count {failures.append(name+" count")};checks += 1
            for index in expected.indices {try autoreleasepool {let image=try d.image(at:index);if sha(image) != expected[index] {failures.append(name+" frame \(index)")};checks += 1}}
        }}
        if CommandLine.arguments.count>2 {let d=try NativeUserAvatarGIFFramePrototype(data:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])));var warm:UInt64=0
            for index in 0..<d.frameCount {try autoreleasepool{_ = try d.image(at:index)};if index==0 || index==1000 || index%10000==0 || index==d.frameCount-1 {samples.append(["frame":index,"memory":memory()])}}
            warm=(samples.first{($0["frame"] as? Int)==1000}!["memory"] as! [String:UInt64])["current"]!;if memory()["current"]!>warm+8*1024*1024{failures.append("unbounded memory growth")};checks += 1
        }
        let report:[String:Any]=["checks":checks,"failures":failures,"samples":samples,"final":memory(),"seconds":ProcessInfo.processInfo.systemUptime-start]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-gif-frame-native.json"));print("GIF frame prototype: \(checks) checks; failures \(failures.count); \(memory())")
        if !failures.isEmpty{print(failures.prefix(12).joined(separator:","));exit(1)}
    }
}
