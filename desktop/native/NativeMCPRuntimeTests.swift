import Foundation
import Darwin
import SQLite3

private final class RuntimeSecrets: NativeMCPSecretStore, @unchecked Sendable {
    var values: [String: Data] = [:]
    var loads = 0, saves = 0, removes = 0
    var failSave = false, failRemove = false
    var afterSave: (() throws -> Void)?
    func load(id: String) throws -> Data? { loads += 1; return values[id] }
    func save(id: String, data: Data) throws {
        saves += 1; guard !failSave, values[id] == nil else { throw NativeMCPSettingsError.credentials }
        values[id] = data; try afterSave?()
    }
    func remove(id: String) throws { removes += 1; if failRemove { throw NativeMCPSettingsError.credentials }; values.removeValue(forKey: id) }
}
private actor RuntimeGate {
    var entered = false
    private var resume: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { resume = $0 } }
    func release() { resume?.resume(); resume = nil }
}
private actor RuntimeWake {
    var count = 0
    func wake() { count += 1 }
}
@main enum NativeMCPRuntimeTests {
    static var checks = 0
    static var lastCheck = "initial"
    static func check(_ condition: Bool, _ label: String) throws { checks += 1; lastCheck = label; if !condition { throw NativeDBError.message("Failed: " + label) } }
    static func reject(_ label: String, _ block: () throws -> Void) throws {
        do { try block() } catch { try check(true, label); return }; try check(false, label)
    }
    static func rejectAsync(_ label: String, _ block: () async throws -> Void) async throws {
        var failed = false
        do { try await block() } catch { failed = true }
        try check(failed, label)
    }
    static func sql(_ text: String, db: NativeDatabase) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(db.url.path,&connection,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw NativeDBError.conflict }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection,text,nil,nil,nil) == SQLITE_OK else { throw NativeDBError.conflict }
    }
    static func connect(_ port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeDBError.conflict }
        var noSignal: Int32 = 1; _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw NativeDBError.conflict }; return fd
    }
    static func request(_ url: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: url)!); r.httpMethod = method; r.httpBody = body; r.timeoutInterval = 5
        for (k,v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data,response) = try await URLSession.shared.data(for: r)
        return ((response as! HTTPURLResponse).statusCode,data)
    }
    static func tool(_ name: String, _ args: [String:Any], endpoint: String, bearer: String) async throws -> [String:Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":name,"arguments":args]])
        let (status,data) = try await request(endpoint,method:"POST",headers:["authorization":bearer,"content-type":"application/json","accept":"application/json, text/event-stream"],body:body)
        guard status == 200, let line = String(decoding:data,as:UTF8.self).components(separatedBy:"\n").first(where:{$0.hasPrefix("data:")}),
              let value = try JSONSerialization.jsonObject(with:Data(line.dropFirst(5).utf8)) as? [String:Any], let result = value["result"] as? [String:Any] else { throw NativeDBError.message("Missing tool response") }
        return result
    }
    static func value(_ response: [String:Any]) throws -> [String:Any] {
        guard response["isError"] as? Bool != true, let content = response["content"] as? [[String:Any]], let text = content.first?["text"] as? String,
              let object = try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any] else { throw NativeDBError.message("Tool error") }
        return object
    }
    static func main() async {
        do { try await run() } catch { let e = error as NSError; print("Runtime verification failed after \(lastCheck): \(e.domain) code \(e.code)"); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources:resources)
        defer { f.close() }
        let secret = RuntimeSecrets(), settings = NativeMCPSettingsStore(service:f.admin,secretStore:secret,clock:{ f.now })
        let wake = RuntimeWake(), qa = NativeAIQAServices()
        let makeRuntime = { (catalog:URL) in NativeMCPRuntime(db:f.db,catalogURL:catalog,secretStore:secret,enrichmentStore:{ _ in qa },enrichmentEnvironment:NativeAIEnvironment { _ in nil },wakeJobs:{ await wake.wake() },clock:{ f.now }) }
        let catalog = resources.appendingPathComponent("MCPToolCatalog.json")
        var snapshot = try settings.snapshot()
        try check(!snapshot.enabled && !snapshot.hasSigningSecret && snapshot.port == 53180,"disabled defaults")
        let disabled = makeRuntime(f.root.appendingPathComponent("no-catalog"))
        try check(try await disabled.start().state == .disabled,"disabled no catalog")
        try check(secret.loads == 0 && secret.saves == 0 && secret.removes == 0,"disabled no Keychain")
        try check(try f.db.metadata(NativeMCPSettingsStore.metadataKey) == nil,"read does not persist")
        try check(try f.db.metadata("document.storage.bucket") == nil,"disabled no bucket mutation")
        for (port,connections) in [(0,4),(1023,4),(65536,4),(53180,0),(53180,1),(53180,33)] {
            try reject("invalid bounds") { _ = try settings.save(expected:snapshot,enabled:false,port:port,maximumConnections:connections) }
        }
        let userID = "00000000-0000-4000-8000-000000000001"
        let normal = CRMService(db:f.db,identity:.init(id:userID,role:"user",partnerAccountID:nil))
        try reject("nonadmin snapshot") { _ = try NativeMCPSettingsStore(service:normal,secretStore:secret).snapshot() }
        try reject("nonadmin save") { _ = try NativeMCPSettingsStore(service:normal,secretStore:secret).save(expected:snapshot,enabled:true,port:53180,maximumConnections:4) }
        let probe = try NativeMCPHTTPServer { _ in .init(status:204) }
        let free = try await probe.start(), port = free.port!; await probe.stop()
        try sql("CREATE TRIGGER fail_reservation BEFORE INSERT ON native_metadata WHEN NEW.key='mcp.signing.cleanup.v1' BEGIN SELECT RAISE(ABORT,'fixture'); END",db:f.db)
        let beforeReservation = secret.saves
        try reject("reservation DB failure") { _ = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2) }
        try check(secret.saves == beforeReservation,"no key before durable reservation")
        try sql("DROP TRIGGER fail_reservation",db:f.db)
        secret.afterSave = { try sql("CREATE TRIGGER fail_publication BEFORE INSERT ON native_metadata WHEN NEW.key='mcp.settings.v1' BEGIN SELECT RAISE(ABORT,'fixture'); END",db:f.db) }
        try reject("publication DB failure") { _ = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2) }
        try check(try settings.snapshot() == snapshot && secret.values.isEmpty,"failed DB publication rolls back key reference and cleans secret")
        try sql("DROP TRIGGER fail_publication",db:f.db); secret.afterSave = nil
        secret.failSave = true
        try reject("Keychain write rollback") { _ = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2) }
        try check(try settings.snapshot() == snapshot && secret.values.isEmpty,"failed publication keeps defaults")
        secret.failSave = false; secret.failRemove = true
        secret.afterSave = { throw NativeDBError.conflict }
        try reject("post-write failure") { _ = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2) }
        try check(secret.values.count == 1,"failed cleanup preserves retry")
        try check(try settings.cleanup().pending == 1,"durable cleanup remains")
        secret.afterSave = nil; secret.failRemove = false
        try check(try settings.cleanup().removed == 1 && secret.values.isEmpty,"cleanup retries")
        secret.afterSave = { throw CancellationError() }
        try reject("cancel after Keychain write") { _ = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2) }
        try check(try settings.snapshot() == snapshot && secret.values.isEmpty,"cancel publication cleans secret")
        secret.afterSave = {
            try f.change("Users",id:f.admin.identity.id,values:["role":.text("user")])
        }
        try reject("authority changed during key write") { _ = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2) }
        try check(secret.values.isEmpty,"revoked admin key cleanup")
        try f.change("Users",id:f.admin.identity.id,values:["role":.text("admin")]); secret.afterSave = nil
        try f.db.setMetadata("document.storage.bucket",value:"existing-bucket")
        snapshot = try settings.snapshot()
        let expected = snapshot
        snapshot = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2)
        try check(snapshot.hasSigningSecret && snapshot.revision == 1,"enabled credential publication")
        try check(snapshot.bucket == "existing-bucket" && (try f.db.metadata("document.storage.bucket")) == "existing-bucket","existing bucket preserved")
        try reject("stale setting save") { _ = try settings.save(expected:expected,enabled:false,port:port,maximumConnections:2) }
        let id = snapshot.credentialID!, seedData = secret.values[id]!, seed = seedData.base64EncodedString()
        let raw = try f.db.metadata(NativeMCPSettingsStore.metadataKey)!
        try check(!raw.contains(seed),"no plaintext secret metadata")
        let reopen = try NativeDatabase(url:f.db.url,schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try NativeMCPSettingsStore.read(db:reopen) == snapshot,"persist settings")
        let docSecret = NativeMCPRuntime.derivedSecret(seed,purpose:"document-storage")
        try check(docSecret != NativeMCPRuntime.derivedSecret(seed,purpose:"better-auth-cookie"),"purpose separation")
        let runtime = makeRuntime(catalog)
        let active = try await runtime.start()
        try check(active.state == .running && active.endpoint == snapshot.endpoint,"fixed loopback endpoint")
        try check(await wake.count == 1,"startup wakes existing jobs")
        let list = try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0","id":2,"method":"tools/list"])
        let discovery = try await request(snapshot.endpoint,method:"POST",headers:["content-type":"application/json","accept":"application/json, text/event-stream"],body:list)
        let lines = String(decoding:discovery.1,as:UTF8.self).components(separatedBy:"\n").filter{$0.hasPrefix("data:")}
        let rpc = try JSONSerialization.jsonObject(with:Data(lines[0].dropFirst(5).utf8)) as! [String:Any]
        try check((rpc["result"] as? [String:Any])?["tools"] is [[String:Any]],"discovery valid")
        try check(((rpc["result"] as? [String:Any])?["tools"] as? [[String:Any]])?.count == 123,"full registry gate")
        let signed = try NativeMCPDocumentLocalSigner(appURL:snapshot.origin,secret:docSecret,clock:{ f.now })
        let put = try signed.url(key:"runtime-fixture.txt",method:"PUT",expiresIn:600,contentType:"text/plain")
        let get = try signed.url(key:"runtime-fixture.txt",method:"GET",expiresIn:3600)
        let data = Data("再起動の前後で同じ文書".utf8)
        try check(try await request(put,method:"PUT",headers:["content-type":"text/plain"],body:data).0 == 200,"signed upload")
        try check(try await request(get).1 == data,"signed download")
        for _ in 0..<100 { if await runtime.snapshot().retainedPeers == 0 { break }; try await Task.sleep(nanoseconds:10_000_000) }
        let peers = try (0..<3).map { _ in try connect(port) }
        defer { peers.forEach { Darwin.close($0) } }
        for _ in 0..<100 { if await runtime.snapshot().rejected > 0 { break }; try await Task.sleep(nanoseconds:10_000_000) }
        let admission = await runtime.snapshot()
        try check(admission.connections == 2 && admission.peakConnections <= 2 && admission.rejected >= 1,"bounded admission")
        let target = URLComponents(string:put)!
        let partial = Data(("PUT " + target.percentEncodedPath + "?" + target.percentEncodedQuery! + " HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: text/plain\r\nContent-Length: 100\r\n\r\nabc").utf8)
        let sent = partial.withUnsafeBytes { Darwin.send(peers[0],$0.baseAddress,partial.count,0) }
        try check(sent == partial.count,"partial upload admitted")
        let filesURL = f.root.appendingPathComponent("native-documents")
        func stageCount() throws -> Int { try FileManager.default.contentsOfDirectory(atPath:filesURL.path).filter{$0.hasPrefix(".stage-")}.count }
        for _ in 0..<100 { if try stageCount() > 0 { break }; try await Task.sleep(nanoseconds:10_000_000) }
        try check(try stageCount() == 1,"partial upload remains staged")
        await runtime.stop()
        try check(try stageCount() == 0,"stop cancels and removes partial upload")
        try check(await runtime.snapshot().state == .stopped,"stop state")
        try check(await runtime.snapshot().retainedPeers == 0,"stop drains peers")
        let loads = secret.loads, saves = secret.saves
        try check(try await runtime.start().endpoint == active.endpoint,"same fixed port restart")
        try check(secret.loads == loads + 1 && secret.saves == saves,"restart reuses immutable secret")
        try check(try await request(get).1 == data,"unexpired signed URL survives restart")
        let created = try value(try await tool("crm_create_document",["document_name":"Runtime","contentType":"text/plain"],endpoint:snapshot.endpoint,bearer:f.header(userID)))
        try check(!created.isEmpty,"actual write handler")
        try check(await wake.count >= 4,"postcommit wake")
        // A saved setting belongs to the service, not the administrator's later role.
        try f.change("Users",id:f.admin.identity.id,values:["role":.text("user")])
        await runtime.stop(); try check(try await runtime.start().state == .running,"admin demotion does not revoke config")
        try reject("stale admin cannot save") { _ = try settings.save(expected:snapshot,enabled:false,port:port,maximumConnections:2) }
        try f.change("Users",id:f.admin.identity.id,values:["role":.text("admin")])
        snapshot = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2,rotateSecret:true)
        try check(snapshot.credentialID != id && secret.values[id] == nil,"explicit rotation retires key")
        try check(try await request(get).0 == 503,"stale running config fenced")
        _ = try await runtime.restart()
        try check(try await request(get).0 == 403,"rotated secret rejects old URL")
        await runtime.stop()
        let occupied = try NativeMCPHTTPServer(configuration:.init(port:UInt16(port))) { _ in .init(status:204) }
        _ = try await occupied.start()
        try await rejectAsync("port collision") { _ = try await runtime.start() }
        let collision = await runtime.snapshot()
        try check(collision.state == .failed && runtimeMessage(collision),"collision visible")
        await occupied.stop(); _ = try await runtime.start(); await runtime.stop()
        let disabledLoads = secret.loads, disabledDeletes = secret.removes
        snapshot = try settings.save(expected:snapshot,enabled:false,port:port,maximumConnections:2)
        try check(try await runtime.start().state == .disabled,"disabled launch")
        try check(secret.loads == disabledLoads && secret.removes == disabledDeletes,"disabled retains key without accessing")
        let portFree = try NativeMCPHTTPServer(configuration:.init(port:UInt16(port))) { _ in .init(status:204) }
        _ = try await portFree.start(); await portFree.stop(); try check(true,"disabled no listener")
        snapshot = try settings.save(expected:snapshot,enabled:true,port:port,maximumConnections:2)
        let cancel = Task { try await runtime.start() }; cancel.cancel()
        do { _ = try await cancel.value; try check(false,"start cancellation") } catch is CancellationError { try check(true,"start cancellation") }
        try check(await runtime.snapshot().state == .stopped,"cancel drains listener")
        _ = try await runtime.start(); await runtime.stop(); try check(true,"restart after cancellation")
        let gate = RuntimeGate()
        let waiting = NativeMCPRuntime(db:f.db,catalogURL:catalog,secretStore:secret,enrichmentStore:{ _ in qa },enrichmentEnvironment:NativeAIEnvironment { _ in nil },wakeJobs:{ await gate.pause() },clock:{ f.now })
        let midStart = Task { try await waiting.start() }
        for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(nanoseconds:10_000_000) }
        try check(await gate.entered,"listener ready before startup cancellation")
        midStart.cancel(); await gate.release()
        do { _ = try await midStart.value; try check(false,"cancel during startup wake") } catch is CancellationError { try check(true,"cancel during startup wake") }
        try check(await waiting.snapshot().state == .stopped,"startup cancellation closes active listener")
        let currentID = snapshot.credentialID!, savedKey = secret.values.removeValue(forKey:currentID)!
        try await rejectAsync("missing migrated secret") { _ = try await runtime.start() }
        try check(await runtime.snapshot().state == .failed,"missing key explicit failure")
        secret.values[currentID] = savedKey
        let invalidCatalog = f.root.appendingPathComponent("partial.json")
        var rawCatalog = try JSONSerialization.jsonObject(with:Data(contentsOf:catalog)) as! [String:Any]
        if var tools = rawCatalog["tools"] as? [[String:Any]] { tools.removeLast(); rawCatalog["tools"] = tools }
        try JSONSerialization.data(withJSONObject:rawCatalog).write(to:invalidCatalog)
        let invalid = makeRuntime(invalidCatalog)
        try await rejectAsync("partial catalog gate") { _ = try await invalid.start() }
        try check(await invalid.snapshot().state == .failed,"invalid registry fails before listen")
        await invalid.stop(); await disabled.stop()
        print("Native MCP runtime/settings: \(checks) checks passed; isolated DB/fake Keychain, real loopback TCP, no external providers")
    }
    static func runtimeMessage(_ value: NativeMCPRuntime.Snapshot) -> Bool { value.message?.contains("ポート") == true }
}
