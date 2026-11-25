import Foundation
import Darwin

private final class MailTemporaryRuntimeSecrets:NativeMailSecretStore {
    private let lock=NSLock();private var values:[String:Data]=[:]
    func load(id:String,interactive:Bool)throws->Data?{lock.lock();defer{lock.unlock()};return values[id]}
    func save(id:String,data:Data)throws{lock.lock();defer{lock.unlock()};guard values[id]==nil else{throw NativeDBError.conflict};values[id]=data}
    func remove(id:String)throws{lock.lock();defer{lock.unlock()};values.removeValue(forKey:id)}
}
private final class MailTemporaryRuntimeGate:@unchecked Sendable {
    private let lock=NSLock();private var opened=false,entered=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    var hasEntered:Bool{lock.lock();defer{lock.unlock()};return entered}
    func hold()async{await withCheckedContinuation{continuation in
        lock.lock();entered=true
        if opened{lock.unlock();continuation.resume()}else{waiters.append(continuation);lock.unlock()}
    }}
    func release(){lock.lock();opened=true;let pending=waiters;waiters=[];lock.unlock();pending.forEach{$0.resume()}}
}

private final class SpoolBusyReceiver:NativeMailReceiving {
    let base:URL
    init(_ base:URL){self.base=base}
    func status(mailbox:String)async throws->(validity:UInt32,next:UInt32){(77,2)}
    func discover(mailbox:String,validity:UInt32,after:UInt32,through:UInt32,since:Date?)async throws->NativeMailUIDSpool {
        let file=try NativeMailResponseFile(temporaryRoot:base)
        let bytes=Data("* SEARCH\r\nNCRM2 OK SEARCH complete\r\n".utf8)
        let count=file.withDescriptor { fd in bytes.withUnsafeBytes { write(fd,$0.baseAddress,$0.count) } }
        guard count==bytes.count else{throw NativeMailFailure.malformed}
        return try NativeMailUIDSpool(response:file,after:after,through:through,temporaryRoot:base)
    }
    func headers(mailbox:String,validity:UInt32,uids:[UInt32])async throws->[NativeMailIMAPHeader]{throw NativeMailFailure.malformed}
    func body(mailbox:String,validity:UInt32,uid:UInt32)async throws->NativeMailBody?{throw NativeMailFailure.malformed}
}

@main @MainActor enum NativeMailTemporaryRuntimeTests {
    static var checks=0
    static func check(_ value:Bool,_ label:String)throws {guard value else{throw NativeDBError.message("Mail temporary runtime: "+label)};checks += 1}
    static func until(_ label:String,_ condition:()throws->Bool)async throws {
        let deadline=Date().addingTimeInterval(8)
        while try !condition(){guard Date()<deadline else{throw NativeDBError.message("Mail temporary runtime timeout: "+label)};try await Task.sleep(nanoseconds:5_000_000)}
    }
    static func settle()async throws {try await Task.sleep(nanoseconds:35_000_000)}
    static func main()async {
        do {
            let args=CommandLine.arguments
            if args[1]=="hold-root" {
                let base=URL(fileURLWithPath:args[2]),fd=open(base.appendingPathComponent(NativeMailTemporaryFiles.namespace).appendingPathComponent(".lock").path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
                guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else{throw NativeMailFailure.malformed}
                defer{close(fd)};print("locked");fflush(stdout);_ = readLine();return
            }
            if args[1]=="child" {
                let base=URL(fileURLWithPath:args[2]),response=try NativeMailResponseFile(temporaryRoot:base)
                let bytes=Data("* SEARCH 1 2\r\nNCRM2 OK SEARCH complete\r\n".utf8)
                let count=response.withDescriptor{fd in bytes.withUnsafeBytes{write(fd,$0.baseAddress,$0.count)}}
                guard count==bytes.count else{throw NativeMailFailure.malformed}
                let spool=try NativeMailUIDSpool(response:response,after:0,through:2,temporaryRoot:base)
                guard try spool.page(after:0)==[1,2] else{throw NativeMailFailure.malformed}
                print("ready");fflush(stdout);_ = readLine();withExtendedLifetime((response,spool)){};return
            }
            try await run(URL(fileURLWithPath:args[1]),spools:URL(fileURLWithPath:args[2]),producer:URL(fileURLWithPath:args[0]))
            print("{\"checks\":\(checks)}")
        } catch {FileHandle.standardError.write(Data("\(error)\n".utf8));exit(1)}
    }
    static func run(_ resources:URL,spools:URL,producer:URL)async throws {
        let root=spools.deletingLastPathComponent().appendingPathComponent("runtime-db")
        func database(_ name:String)throws->NativeDatabase { try NativeDatabase(url:root.appendingPathComponent(name+"/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
        let check=NativeMailTemporaryRuntimeTests.check
        do {
            let db=try database("locked-producer"),secrets=MailTemporaryRuntimeSecrets()
            let service=CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")))
            let base=spools.deletingLastPathComponent().appendingPathComponent("producer-locked")
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            do {let seed=try NativeMailResponseFile(temporaryRoot:base);withExtendedLifetime(seed){}}
            let child=Process(),input=Pipe(),output=Pipe();child.executableURL=producer;child.arguments=["hold-root",base.path];child.standardInput=input;child.standardOutput=output;child.standardError=FileHandle.standardError
            try child.run()
            defer { if child.isRunning {kill(child.processIdentifier,SIGCONT);child.terminate();child.waitUntilExit()} }
            try check(try output.fileHandleForReading.read(upToCount:7)==Data("locked\n".utf8),"separate process owns namespace lock")
            try check(kill(child.processIdentifier,SIGSTOP)==0,"lock owner is actually suspended")
            let settings=NativeMailAccountSettings(label:"作業領域停止検証",username:"owner@example.invalid",imap:.init(host:"imap.example.invalid",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.invalid",port:587,tls:.startTLS),sentFolder:"Sent")
            let account=try service.createMailAccount(settings,password:"synthetic-only",store:secrets)
            let jobID=try service.requestMailSync(account),receiver=SpoolBusyReceiver(base)
            let runtime=NativeMailRuntime(db:db,store:secrets,makeClient:{_,_ in receiver},send:{_ in throw NativeDBError.conflict},recoverTemporary:{try await NativeMailTemporaryFiles.recover(base:base)})
            runtime.resume();try await NativeMailTemporaryRuntimeTests.until("busy spool retries instead of blocking actual worker"){try db.job(id:jobID)?.status=="retry"}
            try check(try db.job(id:jobID)?.attempts==1,"typed spool busy uses existing finite retry policy")
            try check(NativeMailJobs.retryable(NativeMailFailure.spoolBusy),"typed busy is retryable")
            try check(!NativeMailJobs.retryable(NativeMailResponseFile.fileError),"ordinary disk failure classification unchanged")
            var done=false;let drained=Task{@MainActor in await runtime.stopAndDrain();done=true}
            try await NativeMailTemporaryRuntimeTests.until("worker stop finite while external owner remains stopped"){done}
            await drained.value
            try check(runtime.isStopped && !runtime.isScanning && !runtime.isRunning,"actual worker and cleanup joined before external lock release")
            try check(try db.job(id:jobID)?.status=="retry","stop preserves retryable job")
            try check(kill(child.processIdentifier,SIGCONT)==0,"resume lock owner")
            try input.fileHandleForWriting.write(contentsOf:Data("exit\n".utf8));child.waitUntilExit()
            try check(child.terminationStatus==0,"root lock owner exits normally")
            _ = try service.requestMailSync(account)
            let next=NativeMailRuntime(db:db,store:secrets,makeClient:{_,_ in receiver},send:{_ in throw NativeDBError.conflict},recoverTemporary:{try await NativeMailTemporaryFiles.recover(base:base)})
            next.resume();try await NativeMailTemporaryRuntimeTests.until("real worker retry after unlock"){try db.job(id:jobID)?.status=="done"}
            await next.stopAndDrain()
            try check(try db.job(id:jobID)?.attempts==2,"same persisted job completes after unlock")
            try check(try FileManager.default.contentsOfDirectory(atPath:base.appendingPathComponent(NativeMailTemporaryFiles.namespace).path)==[".lock"],"successful retry closes response and SQLite before cleanup")
        }
        do {
            let db=try database("join"),gate=MailTemporaryRuntimeGate();defer{gate.release()}
            let receipt=root.appendingPathComponent("cleanup.receipt")
            let r=NativeMailRuntime(db:db,store:MailTemporaryRuntimeSecrets(),runners:[],clock:Date.init,interval:0.1,enqueueDue:{_,_,_ in 0},recoverTemporary:{
                await gate.hold() // deliberately ignores cancellation
                try Data("completed".utf8).write(to:receipt)
            })
            r.resume();try await NativeMailTemporaryRuntimeTests.until("cleanup accepted"){gate.hasEntered}
            for _ in 0..<3 {r.resume()}
            var a=false,b=false
            let first=Task{@MainActor in await r.stopAndDrain();a=true}
            try await NativeMailTemporaryRuntimeTests.settle();first.cancel()
            let second=Task{@MainActor in await r.stopAndDrain();b=true}
            try await NativeMailTemporaryRuntimeTests.settle()
            try check(!a && !b && r.isScanning && r.isStopped,"cleanup stop/concurrent stop/cancelled caller all wait")
            try check(!FileManager.default.fileExists(atPath:receipt.path),"cleanup side effect still pending")
            gate.release();await first.value;await second.value
            try check(a && b && !r.isScanning && r.nextScan==nil,"cleanup completion and main callbacks joined")
            try check(try Data(contentsOf:receipt)==Data("completed".utf8),"cancellation-ignoring cleanup effect joined")
            r.resume();try await NativeMailTemporaryRuntimeTests.settle()
            try check(!r.isScanning && r.nextScan==nil,"terminal stop fences later cleanup/wake")
        }
        do {
            let db=try database("real-spools")
            let r=NativeMailRuntime(db:db,store:MailTemporaryRuntimeSecrets(),makeClient:{_,_ in fatalError("unexpected provider")},send:{_ in fatalError("unexpected send")},recoverTemporary:{try await NativeMailTemporaryFiles.recover(base:spools)})
            let namespace=spools.appendingPathComponent(NativeMailTemporaryFiles.namespace)
            let before=try FileManager.default.contentsOfDirectory(atPath:namespace.path)
            try check(before.filter{UUID(uuidString:$0) != nil}.count==2,"runtime receives real SIGKILL response and SQLite leftovers")
            r.resume();try await NativeMailTemporaryRuntimeTests.until("paged real cleanup"){!r.isScanning}
            let after=try FileManager.default.contentsOfDirectory(atPath:namespace.path)
            try check(after.filter{UUID(uuidString:$0) != nil}.isEmpty,"normal runtime resume really reclaims owned files")
            try check(after.filter{$0.hasPrefix("unknown-")}.count==150,"background cursor preserves all unknown entries across pages")
            try check(r.nextScan==nil,"no extra permanent timer for empty accounts")
            await r.stopAndDrain()
            try check(!r.isRunning && !r.isScanning && r.isStopped,"real recovery cursor released before stop returns")
        }
        do {
            let db=try database("missing"),missing=root.appendingPathComponent("not-created")
            try await NativeMailTemporaryFiles.recover(base:missing)
            try check(!FileManager.default.fileExists(atPath:missing.path),"absent namespace has no filesystem effect")
            let r=NativeMailRuntime(db:db,store:MailTemporaryRuntimeSecrets(),runners:[],clock:Date.init,interval:0.1,enqueueDue:{_,_,_ in 0},recoverTemporary:{throw NativeDBError.conflict})
            var errors=0;r.onError={_ in errors += 1;r.stop()}
            r.resume();try await NativeMailTemporaryRuntimeTests.until("cleanup error callback"){errors==1 && !r.isScanning}
            await r.stopAndDrain()
            try check(errors==1 && r.isStopped && r.nextScan==nil,"cleanup error reentrant stop preserves lifecycle")
        }
    }
}
