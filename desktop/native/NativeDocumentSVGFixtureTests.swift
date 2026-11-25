import Foundation
import Darwin

@main enum FakeSVG {
    static func main() {
        let name = URL(fileURLWithPath:CommandLine.arguments[0]).lastPathComponent
        if name.contains("Sandbox") {
            let root=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
            let protectedPath=root.appendingPathComponent("fixtures/canary.txt").path
            for path in [protectedPath,"/System/Volumes/Data"+protectedPath] where FileManager.default.fileExists(atPath:path) {
                let readFD=open(path,O_RDONLY)
                guard readFD < 0 && [EPERM,EACCES].contains(errno) else { if readFD >= 0 { close(readFD) };exit(10) }
            }
            let writeFD=open(root.appendingPathComponent("forbidden-write").path,O_WRONLY|O_CREAT,0o600)
            guard writeFD < 0 && [EPERM,EACCES].contains(errno) else { if writeFD >= 0 { close(writeFD) };exit(11) }
            let fd=socket(AF_INET,SOCK_STREAM,0)
            if fd >= 0 {
                var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(1).bigEndian
                inet_pton(AF_INET,"127.0.0.1",&address.sin_addr)
                let status=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                let reason=errno;close(fd)
                guard status < 0 && [EPERM,EACCES].contains(reason) else { exit(12) }
            } else { guard [EPERM,EACCES].contains(errno) else { exit(13) } }
            FileHandle.standardOutput.write(Data("sandbox read/write/network denied\n".utf8));return
        }
        if name.contains("Hang") {
            signal(SIGTERM,SIG_IGN)
            FileHandle.standardOutput.write(Data("started \(getpid())\n".utf8))
            while true { usleep(100_000) }
        }
        if name.contains("Oversized") { FileHandle.standardOutput.write(Data(repeating:65,count:1024*1024+1)) }
        else { FileHandle.standardOutput.write(Data("invalid PNG".utf8)) }
    }
}
