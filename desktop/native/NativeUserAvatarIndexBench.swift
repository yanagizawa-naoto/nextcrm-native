import Foundation
import ImageIO
import CryptoKit
import Darwin

@main enum NativeUserAvatarIndexBench {
    static func memory()->[String:UInt64] { var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);_ = withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return ["current":i.phys_footprint,"peak":UInt64(max(0,i.ledger_phys_footprint_peak))] }
    static func main(){do{try run()}catch{fputs("Index benchmark: \(error)\n",stderr);exit(1)}}
    static func run()throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),start=ProcessInfo.processInfo.systemUptime
        let index=try AvatarPrototypeWebPIndex(data),initSeconds=ProcessInfo.processInfo.systemUptime-start
        let afterInit=memory()
        var count=0,last:AvatarPrototypeWebPIndex.Frame?
        while let frame=try index.next(){count += 1;last=frame}
        guard count==index.count,let last else{throw AvatarPrototypeError.invalid}
        let afterScan=memory()
        let still=index.still(last)
        guard let source=CGImageSourceCreateWithData(still as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil),image.width==2 && image.height==2 else{throw AvatarPrototypeError.invalid}
        var pixel=Data(repeating:0,count:16)
        pixel.withUnsafeMutableBytes { p in let c=CGContext(data:p.baseAddress,width:2,height:2,bitsPerComponent:8,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.draw(image,in:CGRect(x:0,y:0,width:2,height:2)) }
        let afterDecode=memory()
        var over=data;over.append(0)
        do{_ = try AvatarPrototypeWebPIndex(over);throw AvatarPrototypeError.invalid}catch AvatarPrototypeError.limit{}
        let report:[String:Any]=["inputBytes":data.count,"frames":count,"initSeconds":initSeconds,"scanSeconds":ProcessInfo.processInfo.systemUptime-start-initSeconds,"lastRGBA":Array(pixel),"retainedDescriptorLimit":2,"inputPlusOneRejected":true,"afterInit":afterInit,"afterScan":afterScan,"afterLastDecode":afterDecode,"afterOversizeFixtureCopy":memory()]
        print(String(data:try JSONSerialization.data(withJSONObject:report),encoding:.utf8)!)
    }
}
