import Foundation
import Darwin

@main struct NativeMailTemporaryFilesTests {
    static func output(_ value:[String:Any]) throws {
        print(String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)!); fflush(stdout)
    }
    static let sample = Data("* SEARCH 7 3 7 2 1\r\nNCRM2 OK SEARCH complete\r\n".utf8)
    static func fill(_ file:NativeMailResponseFile,_ bytes:Data=sample) throws {
        try file.withDescriptor { fd in
            let count = bytes.withUnsafeBytes { write(fd,$0.baseAddress,$0.count) }
            guard count == bytes.count else { throw NativeMailFailure.malformed }
        }
    }
    static func paths(_ base:URL) throws -> [String:String] {
        let root=base.appendingPathComponent(NativeMailTemporaryFiles.namespace);var result:[String:String]=[:]
        for name in try FileManager.default.contentsOfDirectory(atPath:root.path) where name != ".lock" {
            let dir=root.appendingPathComponent(name)
            for kind in ["response","uids.sqlite"] where FileManager.default.fileExists(atPath:dir.appendingPathComponent(kind).path) { result[kind]=dir.path }
        };return result
    }
    static func main() {
        do {try run()} catch {FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
    }
    static func run() throws {
        let mode=CommandLine.arguments[1],base=URL(fileURLWithPath:CommandLine.arguments[2]);var checks=0
        func check(_ value:Bool,_ name:String)throws { guard value else { throw NSError(domain:"SpoolTests",code:1,userInfo:[NSLocalizedDescriptionKey:name]) }; checks += 1 }
        if mode == "hold-root" {
            let fd=open(base.appendingPathComponent(NativeMailTemporaryFiles.namespace).appendingPathComponent(".lock").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else {throw NativeMailFailure.malformed}
            defer{close(fd)};print("locked");fflush(stdout);_ = readLine();return
        }
        if mode == "producer" {
            let response=try NativeMailResponseFile(temporaryRoot:base);try fill(response)
            try output(["ready":true])
            while let line=readLine(),line != "exit" {
                let start=Date();var statuses:[String]=[]
                do { let file=try NativeMailResponseFile(temporaryRoot:base);statuses.append("response-ok");withExtendedLifetime(file){} }
                catch NativeMailFailure.spoolBusy {statuses.append("response-busy")}
                do { let spool=try NativeMailUIDSpool(response:response,after:1,through:9,temporaryRoot:base);guard try spool.page(after:1)==[2,3,7] else {throw NativeMailFailure.malformed};statuses.append("uids-ok") }
                catch NativeMailFailure.spoolBusy {statuses.append("uids-busy")}
                try output(["statuses":statuses,"elapsedMilliseconds":Date().timeIntervalSince(start)*1000])
            }
            withExtendedLifetime(response){};return
        }
        if mode == "child" {
            let response=try NativeMailResponseFile(temporaryRoot:base);try fill(response)
            let spool=try NativeMailUIDSpool(response:response,after:1,through:9,temporaryRoot:base)
            try output(["paths":try paths(base)])
            while let line=readLine() {
                if line == "exit" { break }
                try check(try spool.page(after:1)==[2,3,7],"live SQLite unchanged")
                try check(response.withDescriptor { lseek($0,0,SEEK_END) } == sample.count,"live fd unchanged")
                try output(["checks":checks])
            }
            withExtendedLifetime((response,spool)) {};return
        }
        if mode == "sweep" || mode == "cursor" {
            let scan=try NativeMailTemporaryFiles.Recovery(base:base)
            var examined=0,removed=0,live=0,preserved=0,calls=0,busy=false,finished=false
            repeat {
                let page=try scan.step(maximumEntries:mode == "cursor" ? 3:64)
                guard page.examined <= (mode == "cursor" ? 3:64) else { fatalError("unbounded page") }
                calls += 1;examined += page.examined;removed += page.removed;live += page.live;preserved += page.preserved;busy=page.busy;finished=page.finished
            } while mode == "cursor" && !busy && !finished
            try output(["examined":examined,"removed":removed,"live":live,"preserved":preserved,"busy":busy,"finished":finished,"calls":calls]);return
        }
        if mode == "core" {
            let root=base.appendingPathComponent(NativeMailTemporaryFiles.namespace)
            do {
                let response=try NativeMailResponseFile(temporaryRoot:base);try fill(response)
                let spool=try NativeMailUIDSpool(response:response,after:1,through:9,temporaryRoot:base)
                try check(try spool.page(after:1)==[2,3,7],"actual SQLite sorted/deduplicated")
                try check(try spool.page(after:2,limit:1)==[3],"actual SQLite keyset")
                let live=try NativeMailTemporaryFiles.Recovery(base:base).step()
                try check(live.live==2 && live.removed==0,"same-process live leases")
                try check(try spool.page(after:3)==[7],"SQLite usable after sweep")
                try check(try paths(base).count==2,"both private files retained")
                withExtendedLifetime((response,spool)) {}
            }
            try check(try FileManager.default.contentsOfDirectory(atPath:root.path)==[".lock"],"close SQLite/fd before lease normal cleanup")
            do {
                let response=try NativeMailResponseFile(temporaryRoot:base);try fill(response,Data("* SEARCH 2 1\r\n".utf8))
                do { _ = try NativeMailUIDSpool(response:response,after:0,through:10,temporaryRoot:base);throw NSError(domain:"unexpected",code:1) }
                catch NativeMailFailure.malformed { checks += 1 }
                try check(try paths(base).keys.sorted()==["response"],"failed parse discards its SQLite only")
            }
            try check(try FileManager.default.contentsOfDirectory(atPath:root.path)==[".lock"],"failed parse response also released")
            let empty=try NativeMailTemporaryFiles.Recovery(base:base);let last=try empty.step(maximumEntries:1)
            try check(last.examined<=1 && last.removed==0,"bounded empty scan")
            var finished=last.finished;while !finished { finished=try empty.step(maximumEntries:1).finished }
            try check(try empty.step().finished,"completed cursor remains complete")
            do { _ = try empty.step(maximumEntries:257);throw NSError(domain:"unexpected",code:1) }
            catch NativeMailFailure.invalid { checks += 1 }
            // A cursor pins directory identities; moving/replacing its root
            // after opening it cannot authorize deletion through old handles.
            let moved=base.appendingPathComponent("moved-root")
            let cursor=try NativeMailTemporaryFiles.Recovery(base:base)
            try FileManager.default.moveItem(at:root,to:moved)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            do { _ = try cursor.step();throw NSError(domain:"unexpected",code:1) }
            catch NativeMailFailure.invalid { checks += 1 }
            try check(FileManager.default.fileExists(atPath:moved.appendingPathComponent(".lock").path),"old root preserved after cursor path replacement")
            try output(["checks":checks]);return
        }
        fatalError("unknown test mode")
    }
}
