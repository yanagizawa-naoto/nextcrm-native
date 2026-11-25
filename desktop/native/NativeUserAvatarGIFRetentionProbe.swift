import Foundation
import CoreGraphics
import ImageIO
import Darwin

@main enum NativeUserAvatarGIFRetentionProbe {
    static func memory()->[String:UInt64] { var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);_ = withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}};return ["current":info.phys_footprint,"peak":UInt64(max(0,info.ledger_phys_footprint_peak))] }
    static func main() throws {
        let args=CommandLine.arguments,data=try Data(contentsOf:URL(fileURLWithPath:args[1])),mode=args[2],count=Int(args[3])!
        var source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary)!,samples:[[String:Any]]=[]
        let start=ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            autoreleasepool {
                if mode=="reset" && index%1000==0 {source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary)!}
                if mode=="properties" { _ = CGImageSourceCopyPropertiesAtIndex(source,index,nil);_ = CGImageSourceGetStatusAtIndex(source,index) }
                let image=CGImageSourceCreateThumbnailAtIndex(source,index,[kCGImageSourceShouldCache:false,kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:512] as CFDictionary)!
                let canvas=CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                canvas.draw(image,in:CGRect(x:0,y:0,width:2,height:2))
                CGImageSourceRemoveCacheAtIndex(source,index)
            }
            if index==0 || index==1000 || index%10000==0 || index==count-1 {samples.append(["frame":index,"memory":memory()])}
        }
        let result:[String:Any]=["mode":mode,"count":count,"seconds":ProcessInfo.processInfo.systemUptime-start,"samples":samples,"final":memory()]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
