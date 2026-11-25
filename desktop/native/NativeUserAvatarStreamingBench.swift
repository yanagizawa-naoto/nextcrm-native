import Foundation
import CoreGraphics
import CryptoKit
import Darwin

@main enum NativeUserAvatarStreamingBench {
    static func memory()->[String:UInt64] { var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);let r=withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return r==KERN_SUCCESS ? ["current":i.phys_footprint,"peak":UInt64(max(0,i.ledger_phys_footprint_peak))]:[:] }
    static func footprint()->UInt64 { memory()["current"] ?? 0 }
    static func hash(_ d:Data)->String { SHA256.hash(data:d).map { String(format:"%02x",$0) }.joined() }
    static func rgba(_ image:CGImage)throws->Data { var data=Data(repeating:0,count:image.width*image.height*4);try data.withUnsafeMutableBytes { p in guard let c=CGContext(data:p.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw AvatarPrototypeError.io};c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height)) };return data }
    static func main(){do{try run()}catch{fputs("Prototype failed: \(error)\n",stderr);exit(1)}}
    static func run()throws {
        let file=URL(fileURLWithPath:CommandLine.arguments[1]),mode=CommandLine.arguments[2],raw=try Data(contentsOf:file),start=ProcessInfo.processInfo.systemUptime,baseline=footprint()
        var frames:[[String:Any]]=[],count=0,initSeconds:Double=0,w=0,h=0,orientation=1,reads=0,writes=0,providerRequest=0,phases:[String:[String:UInt64]]=[:]
        var lastFootprint=baseline
        if mode=="gif" {
            let player=try AvatarPrototypeGIFPlayer(raw);w=player.width;h=player.height;initSeconds=ProcessInfo.processInfo.systemUptime-start
            for i in 0..<player.count { try autoreleasepool { guard let image=try player.next() else { throw AvatarPrototypeError.invalid };count += 1
                if [0,499,500,999,1000].contains(i)||player.count<10 { let d=try rgba(image);frames.append(["index":i,"sha256":hash(d),"preview":d.base64EncodedString(),"side":image.width]) }
                lastFootprint=max(lastFootprint,footprint())
            } }
        } else {
            let honor=mode != "ram-browser"
            guard let backing=AvatarPrototypeCanvas.Mode(rawValue:honor ? mode:"ram")else{throw AvatarPrototypeError.invalid}
            let player=try AvatarPrototypeWebPPlayer(raw,mode:backing,honorOrientation:honor);w=player.stream.width;h=player.stream.height;orientation=player.stream.orientation;initSeconds=ProcessInfo.processInfo.systemUptime-start
            phases["after-init"]=memory();player.phase = { name in let current=memory();var old=phases[name] ?? [:];for (key,value) in current { old[key]=max(old[key] ?? 0,value) };phases[name]=old }
            for i in 0..<player.stream.count { try autoreleasepool { guard let preview=try player.next() else { throw AvatarPrototypeError.invalid };count += 1
                if [0,499,500,999,1000].contains(i)||player.stream.count<10 { frames.append(["index":i,"sha256":try player.canvas.hash(),"preview":preview.base64EncodedString(),"side":min(256,w,h)]) }
                lastFootprint=max(lastFootprint,footprint())
            } }
            reads=player.canvas.ioReadBytes;writes=player.canvas.ioWriteBytes;providerRequest=player.canvas.largestProviderRequest
        }
        let result:[String:Any]=["mode":mode,"width":w,"height":h,"orientation":orientation,"count":count,"initSeconds":initSeconds,"totalSeconds":ProcessInfo.processInfo.systemUptime-start,"baselineFootprint":baseline,"maxSampledFootprint":lastFootprint,"finalFootprint":footprint(),"readBytes":reads,"writeBytes":writes,"frames":frames,"canvasFileBytes":mode.hasPrefix("disk") ? w*h*4:0,"phases":phases,"largestProviderRequest":providerRequest]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
