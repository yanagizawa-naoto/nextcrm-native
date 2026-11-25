import Foundation
import CoreGraphics
import Darwin

@main enum NativeUserAvatarWorkerMain {
    static var parentWatch:DispatchSourceProcess?
    static func main(){
        signal(SIGPIPE,SIG_DFL)
        guard CommandLine.arguments.count==3,CommandLine.arguments[1]=="--parent",let expected=Int32(CommandLine.arguments[2]),expected>1,getppid()==expected else{_exit(70)}
        let watch=DispatchSource.makeProcessSource(identifier:expected,eventMask:.exit,queue:.global(qos:.userInitiated));watch.setEventHandler{_exit(0)};parentWatch=watch;watch.resume()
        guard getppid()==expected else{_exit(0)}
        let slot=NativeUserAvatarWorkerCommandSlot()
        Thread.detachNewThread {
            do{while true{
                let(kind,length)=try NativeUserAvatarWorkerWire.readHeader(STDIN_FILENO)
                if kind==4{guard length==0 else{throw NativeUserAvatarWorkerFailure.invalidPacket};_exit(0)}
                guard kind==1 || kind==2 || kind==3 else{throw NativeUserAvatarWorkerFailure.invalidPacket}
                guard kind==1 ? length>0 && length<=NativeUserAvatarWorkerWire.inputLimit:length==0 else{throw NativeUserAvatarWorkerFailure.tooLarge}
                let data=try NativeUserAvatarWorkerWire.readExactly(STDIN_FILENO,length,limit:NativeUserAvatarWorkerWire.inputLimit)
                try slot.offer((kind,data))
            }}catch NativeUserAvatarWorkerFailure.eof{_exit(0)}catch{_exit(71)}
        }
        do{try run(slot)}catch{
            let code:UInt32
            switch error {case NativeUserAvatarAnimation.Failure.inputLimit:code=2;case NativeUserAvatarAnimation.Failure.canvasLimit:code=3;case NativeUserAvatarAnimation.Failure.orientation:code=4;default:code=1}
            try? NativeUserAvatarWorkerWire.write(STDOUT_FILENO,0x7f,NativeUserAvatarWorkerWire.number(UInt64(code),4),limit:4);_exit(72)
        }
    }
    static func run(_ slot:NativeUserAvatarWorkerCommandSlot)throws{
        var decoder:NativeUserAvatarAnimation?
        while true{
            let(kind,payload)=slot.next()
            switch kind{
            case 1:
                guard decoder==nil else{throw NativeUserAvatarWorkerFailure.invalidPacket}
                decoder=try autoreleasepool{try NativeUserAvatarAnimation(data:payload)}
                let d=decoder!
                // Canvas dimensions are validated by the copied decoders. The
                // wire needs only playback count, loop and initial-poster flag.
                var meta=NativeUserAvatarWorkerWire.number(UInt64(d.frameCount),4);meta.append(NativeUserAvatarWorkerWire.number(UInt64(d.iterations ?? 0),4));meta.append(NativeUserAvatarWorkerWire.number(d.requiresInitialFrameDisplay ? 1:0,4))
                try NativeUserAvatarWorkerWire.write(STDOUT_FILENO,0x10,meta,limit:12)
            case 2:
                guard let d=decoder else{throw NativeUserAvatarWorkerFailure.invalidPacket}
                let frame:Data?=try autoreleasepool{
                    guard let f=try d.nextFrame()else{return nil}
                    let width=f.image.width,height=f.image.height
                    guard width>0,height>0,width<=256,height<=256,f.delay.isFinite,f.delay>=0.011,f.delay<=86400 else{throw NativeUserAvatarWorkerFailure.invalidPacket}
                    var pixels=Data(count:width*height*4)
                    try pixels.withUnsafeMutableBytes{raw in guard let c=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{throw NativeUserAvatarWorkerFailure.io};c.draw(f.image,in:CGRect(x:0,y:0,width:width,height:height))}
                    var bytes=NativeUserAvatarWorkerWire.number(UInt64(f.index),4);bytes.append(NativeUserAvatarWorkerWire.number(UInt64(width),2));bytes.append(NativeUserAvatarWorkerWire.number(UInt64(height),2));bytes.append(NativeUserAvatarWorkerWire.number(UInt64((f.delay*1_000_000).rounded()),8));bytes.append(Data(count:16));bytes.append(pixels);return bytes
                }
                if var frame{
                    let memory=NativeUserAvatarWorkerWire.memory();frame.replaceSubrange(16..<24,with:NativeUserAvatarWorkerWire.number(memory.current,8));frame.replaceSubrange(24..<32,with:NativeUserAvatarWorkerWire.number(memory.peak,8))
                    try NativeUserAvatarWorkerWire.write(STDOUT_FILENO,0x11,frame,limit:NativeUserAvatarWorkerWire.frameLimit)
                }else{try NativeUserAvatarWorkerWire.write(STDOUT_FILENO,0x12,Data(),limit:0)}
            case 3:
                let m=NativeUserAvatarWorkerWire.memory();try NativeUserAvatarWorkerWire.write(STDOUT_FILENO,0x13,NativeUserAvatarWorkerWire.number(m.current,8)+NativeUserAvatarWorkerWire.number(m.peak,8),limit:16)
            default:throw NativeUserAvatarWorkerFailure.invalidPacket
            }
        }
    }
}
