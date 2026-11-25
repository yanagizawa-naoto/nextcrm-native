import Foundation
import CoreGraphics
import Darwin

@main enum NativeUserAvatarAPNGMassTests {
    enum Failure:Error{case assertion(String)}
    static func memory()->[String:UInt64]{var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/4);_ = withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return ["current":i.phys_footprint,"peak":UInt64(max(0,i.ledger_phys_footprint_peak))]}
    static func main()throws {
        let path=URL(fileURLWithPath:CommandLine.arguments[1]),native=URL(fileURLWithPath:CommandLine.arguments[2]),count=Int(CommandLine.arguments[3])!,start=ProcessInfo.processInfo.systemUptime,data=try Data(contentsOf:path),d=try NativeUserAvatarAPNGAnimation(data:data),initialized=memory()
        guard data.count==4*1024*1024,d.frameCount==count,d.iterations==1,d.decodedFrameCount==0 else{throw Failure.assertion("metadata")}
        var samples:[[String:Any]]=[],warm:UInt64=0,checks=4
        for i in 0..<count {try autoreleasepool {
            guard let f=try d.nextFrame(),f.index==i,abs(f.delay-0.02)<0.000001 else{throw Failure.assertion("frame \(i)")}
            if i==0 || i==500 || i==1000 || i%10000==0 || i==count-1{var pixel=[UInt8](repeating:0,count:4);pixel.withUnsafeMutableBytes{p in let c=CGContext(data:p.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(f.image,in:CGRect(x:0,y:0,width:1,height:1))};guard pixel==[255,0,0,255]else{throw Failure.assertion("color")};checks += 1}
        };if i==1000{warm=memory()["current"]!};if i==0 || i==1000 || i%10000==0 || i==count-1{samples.append(["frame":i,"memory":memory()])}}
        guard try d.nextFrame()==nil,d.decodedFrameCount==count,memory()["current"]!<=warm+8*1024*1024 else{throw Failure.assertion("end/memory")};checks += 3
        let result:[String:Any]=["checks":checks,"frames":count,"initialized":initialized,"warm":warm,"samples":samples,"final":memory(),"seconds":ProcessInfo.processInfo.systemUptime-start]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:native.appendingPathComponent("build/user-avatar-apng-mass-native.json"));print("APNG mass: \(checks) checks / \(count) frames; \(memory())")
    }
}
