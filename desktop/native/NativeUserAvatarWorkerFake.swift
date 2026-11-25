import Foundation
import Darwin

@main enum AvatarHelperFakeWorker {
    static func main()throws{
        let mode=URL(fileURLWithPath:CommandLine.arguments[0]).lastPathComponent
        if mode.contains("stallinput"){signal(SIGTERM,SIG_IGN);usleep(3_000_000);return}
        let(_,size)=try NativeUserAvatarWorkerWire.readHeader(0);_ = try NativeUserAvatarWorkerWire.readExactly(0,size,limit:NativeUserAvatarWorkerWire.inputLimit)
        if mode.contains("inithang"){signal(SIGTERM,SIG_IGN);usleep(3_000_000);return}
        let count=mode.contains("badmeta") ? 0:3
        try NativeUserAvatarWorkerWire.write(1,0x10,NativeUserAvatarWorkerWire.number(UInt64(count),4)+NativeUserAvatarWorkerWire.number(1,4)+NativeUserAvatarWorkerWire.number(0,4),limit:12)
        _ = try NativeUserAvatarWorkerWire.readHeader(0)
        if mode.contains("stalled"){signal(SIGTERM,SIG_IGN);usleep(3_000_000);return}
        if mode.contains("earlyend"){try NativeUserAvatarWorkerWire.write(1,0x12,Data(),limit:0);usleep(3_000_000);return}
        if mode.contains("oversize"){try NativeUserAvatarWorkerWire.writeAll(1,NativeUserAvatarWorkerWire.header(0x11,NativeUserAvatarWorkerWire.frameLimit+1))}
        else if mode.contains("truncated"){try NativeUserAvatarWorkerWire.writeAll(1,NativeUserAvatarWorkerWire.header(0x11,48));try NativeUserAvatarWorkerWire.writeAll(1,Data(count:10));return}
        else if mode.contains("unknown"){try NativeUserAvatarWorkerWire.write(1,0x55,Data(),limit:0)}
        else{
            let index=mode.contains("badindex") ? 2:0,width=mode.contains("badwidth") ? 65535:2
            let p=NativeUserAvatarWorkerWire.number(UInt64(index),4)+NativeUserAvatarWorkerWire.number(UInt64(width),2)+NativeUserAvatarWorkerWire.number(2,2)+NativeUserAvatarWorkerWire.number(100000,8)+Data(count:16+16)
            try NativeUserAvatarWorkerWire.write(1,0x11,p,limit:NativeUserAvatarWorkerWire.frameLimit)
        }
        usleep(3_000_000)
    }
}
