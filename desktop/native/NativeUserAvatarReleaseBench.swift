import Foundation
import Darwin

@main enum NativeUserAvatarReleaseBench {
    static func memory()->[String:UInt64] { var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size);_ = withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return ["current":i.phys_footprint,"peak":UInt64(max(0,i.ledger_phys_footprint_peak))] }
    static func main(){do{try run()}catch{fputs("Release probe failed: \(error)\n",stderr);exit(1)}}
    static func run()throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])),mode=CommandLine.arguments[2],before=memory()
        weak var weakWebP:AvatarPrototypeWebPPlayer?;weak var weakGIF:AvatarPrototypeGIFPlayer?
        var frames=0,active:[String:UInt64]=[:]
        try autoreleasepool {
            if mode=="gif" { let p=try AvatarPrototypeGIFPlayer(data);weakGIF=p
                while try autoreleasepool(invoking:{try p.next() != nil}) { frames += 1 };active=memory()
            } else { guard let backing=AvatarPrototypeCanvas.Mode(rawValue:mode)else{throw AvatarPrototypeError.invalid};let p=try AvatarPrototypeWebPPlayer(data,mode:backing);weakWebP=p
                while try autoreleasepool(invoking:{try p.next() != nil}) { frames += 1 };active=memory()
            }
        }
        guard weakGIF==nil && weakWebP==nil else{throw AvatarPrototypeError.invalid}
        let released=memory();RunLoop.current.run(until:Date().addingTimeInterval(0.05));let idle=memory()
        let relieved=malloc_zone_pressure_relief(nil,0),afterRelief=memory()
        let result:[String:Any]=["mode":mode,"frames":frames,"before":before,"whileDecoderAlive":active,"afterExplicitRelease":released,"after50ms":idle,"decoderDeallocated":true,"allocatorReliefBytes":relieved,"afterAllocatorRelief":afterRelief]
        print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
    }
}
