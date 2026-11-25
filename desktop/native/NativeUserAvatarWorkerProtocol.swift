import Foundation
import Darwin

enum NativeUserAvatarWorkerFailure:Error,LocalizedError {
    case invalidPacket,tooLarge,eof,io,cancelled,timedOut,helperUnavailable,remote(UInt32)
    var errorDescription:String? {
        switch self {
        case .tooLarge:return "写真が4 MiBを超えるため、元画像を保持して静止画を表示しています。"
        case .timedOut:return "写真の読み込みに時間がかかったため、静止画を表示しています。"
        case .cancelled:return "写真の再生を中断しました。"
        case .remote(3):return "写真の大きさが対応範囲を超えるため、元画像を保持して静止画を表示しています。"
        case .remote(4):return "回転情報付きの動くWebPは静止画で表示しています。元画像は保持しています。"
        default:return "写真を再生できないため、元画像を保持して静止画を表示しています。"
        }
    }
}
enum NativeUserAvatarWorkerWire {
    static let headerBytes=12,inputLimit=4*1024*1024,frameLimit=32+256*256*4
    static let magic=Data([65,86,72,49]) // AVH1
    static func number(_ value:UInt64,_ count:Int)->Data{Data((0..<count).map{UInt8((value>>($0*8))&255)})}
    static func integer(_ data:Data,_ offset:Int,_ count:Int)throws->UInt64{guard offset>=0,count>=0,count<=8,offset<=data.count-count else{throw NativeUserAvatarWorkerFailure.invalidPacket};var v:UInt64=0;for i in 0..<count{v |= UInt64(data[data.startIndex+offset+i])<<UInt64(i*8)};return v}
    static func readExactly(_ fd:Int32,_ count:Int,limit:Int)throws->Data {
        guard count>=0,count<=limit else{throw NativeUserAvatarWorkerFailure.tooLarge}
        var data=Data(count:count),offset=0
        try data.withUnsafeMutableBytes{raw in while offset<count{let n=Darwin.read(fd,raw.baseAddress!.advanced(by:offset),count-offset);if n<0 && errno==EINTR{continue};if n==0{throw NativeUserAvatarWorkerFailure.eof};guard n>0 else{throw NativeUserAvatarWorkerFailure.io};offset += n}}
        return data
    }
    static func readHeader(_ fd:Int32)throws->(UInt8,Int){let h=try readExactly(fd,headerBytes,limit:headerBytes);guard h.prefix(4)==magic,h[5]==0,h[6]==0,h[7]==0 else{throw NativeUserAvatarWorkerFailure.invalidPacket};return(h[4],Int(try integer(h,8,4)))}
    static func writeAll(_ fd:Int32,_ data:Data)throws{try data.withUnsafeBytes{raw in var p=0;while p<raw.count{let n=Darwin.write(fd,raw.baseAddress!.advanced(by:p),raw.count-p);if n<0 && errno==EINTR{continue};guard n>0 else{throw NativeUserAvatarWorkerFailure.io};p += n}}}
    static func header(_ kind:UInt8,_ length:Int)throws->Data{guard length>=0,length<=Int(UInt32.max)else{throw NativeUserAvatarWorkerFailure.tooLarge};return magic+Data([kind,0,0,0])+number(UInt64(length),4)}
    static func write(_ fd:Int32,_ kind:UInt8,_ payload:Data,limit:Int)throws{guard payload.count<=limit else{throw NativeUserAvatarWorkerFailure.tooLarge};try writeAll(fd,header(kind,payload.count));try writeAll(fd,payload)}
    static func memory()->(current:UInt64,peak:UInt64){var i=task_vm_info_data_t(),n=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/4);_ = withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:integer_t.self,capacity:Int(n)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&n)}};return(i.phys_footprint,UInt64(max(0,i.ledger_phys_footprint_peak)))}
    static func footprint(_ pid:pid_t)->UInt64?{var i=rusage_info_v4();let r=withUnsafeMutablePointer(to:&i){$0.withMemoryRebound(to:rusage_info_t?.self,capacity:1){proc_pid_rusage(pid,RUSAGE_INFO_V4,$0)}};return r==0 ? i.ri_phys_footprint:nil}
}

/// Exactly one queued command; the reader stays independent of pixel decoding
/// and blocked stdout writes so EOF/STOP can end the process immediately.
final class NativeUserAvatarWorkerCommandSlot {
    private let condition=NSCondition()
    private var pending:(UInt8,Data)?
    func offer(_ command:(UInt8,Data))throws{condition.lock();defer{condition.unlock()};guard pending==nil else{throw NativeUserAvatarWorkerFailure.invalidPacket};pending=command;condition.signal()}
    func next()->(UInt8,Data){condition.lock();defer{condition.unlock()};while pending==nil{condition.wait()};let command=pending!;pending=nil;return command}
}
