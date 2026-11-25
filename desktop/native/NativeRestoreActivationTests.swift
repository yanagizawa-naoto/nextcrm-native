import Foundation
import Darwin

private actor ActivationGate {
    private var started = false, released = false
    private var startWaiter: CheckedContinuation<Void,Never>?, releaseWaiter: CheckedContinuation<Void,Never>?
    func pause() async { started=true;startWaiter?.resume();startWaiter=nil;if !released { await withCheckedContinuation{releaseWaiter=$0} } }
    func wait() async { if !started { await withCheckedContinuation{startWaiter=$0} } }
    func release() { released=true;releaseWaiter?.resume();releaseWaiter=nil }
}

private actor ActivationHost {
    let base: URL, resources: URL, mode: String
    private var oldWorker: Task<Void,Never>?, callback: Task<Void,Never>?, newWorker: Task<Void,Never>?, mailWorker:Task<Void,Never>?
    private var paused: NativeBackupSQLite?
    private var listenerAccepts = false, draft = "", reviewed = 0, finalMutation = false
    var gate: ActivationGate?
    init(base: URL, resources: URL, mode: String) { self.base=base;self.resources=resources;self.mode=mode }
    func db(_ root: String) throws -> NativeDatabase { try NativeDatabase(url:base.appendingPathComponent(root+"/crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")) }
    func read(_ root: String, _ sql: String, _ values: [NativeBackupSQLite.Value] = []) throws -> String? {
        let path=base.appendingPathComponent(root+"/crm.sqlite").path
        return try NativeBackupSQLite(path:path,readOnly:true,immutable:!FileManager.default.fileExists(atPath:path+"-wal")).first(sql,values)
    }
    func hash(_ text: String) -> String { NativeMigrationCodec.hash(Data(text.utf8)) }
    func json(_ name: String) throws -> [String:Any] { try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent(name))) as! [String:Any] }
    func startOld() async throws {
        if try read("old","SELECT value FROM native_metadata WHERE key='activation.fixture.savedDraft'") == nil { draft="未保存の編集" }
        if oldWorker == nil {
            let database = try db("old")
            oldWorker = Task.detached {
                var value = Int((try? database.metadata("activation.fixture.oldTicks")) ?? "0") ?? 0
                while !Task.isCancelled {
                    value += 1;try? database.setMetadata("activation.fixture.oldTicks",value:String(value))
                    do { try await Task.sleep(nanoseconds:10_000_000) } catch { break }
                }
            }
        }
        if callback == nil {
            let database = try db("old")
            callback = Task.detached { do { try await Task.sleep(nanoseconds:5_000_000_000);try Task.checkCancellation();try database.setMetadata("activation.fixture.staleCallback",value:"ran") } catch {} }
        }
        listenerAccepts=true
        try await Task.sleep(nanoseconds:30_000_000)
    }
    func authorize() throws {
        if mode == "secretAuthorize" {throw NativeRestoreActivationFailure("never-a-real-key")}
        guard try read("old","SELECT role||':'||userStatus||':'||banned FROM Users WHERE id=?",[.text(NativeRestoreActivationTests.userID)]) == "admin:ACTIVE:0" else { throw NativeRestoreActivationFailure("host.authorization") }
        if ["finalCandidateMutation","finalWAL"].contains(mode),!finalMutation,
           let journal=try? json("control/activation.json"),journal["phase"] as? String == "ready" {
            finalMutation=true
            if mode == "finalWAL" {
                let file=base.appendingPathComponent("candidate/crm.sqlite-wal");try Data("unsealed pages".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            } else { try db("candidate").setMetadata("unexpected.final.write",value:"changed during last authorization await") }
        }
    }
    func capture(_ ctx: NativeRestoreActivationContext) throws -> [String] { oldWorker == nil ? [] : ["local"] }
    func recoveryQuiescence(_ ctx: NativeRestoreActivationContext, _ selected: NativeRestoreActivationSelection) throws -> NativeRestoreActivationDrain {
        guard oldWorker == nil,newWorker == nil,mailWorker == nil,callback == nil,paused == nil,!listenerAccepts,draft.isEmpty else { throw NativeRestoreActivationFailure("recovery.notQuiescent") }
        return .init(root:selected.root,participants:["editor","callback","listener","worker","database"],previouslyRunning:[],unfinishedTasks:0,openWritableHandles:0,unsavedEditors:0,pendingCallbacks:0,evidenceSHA256:hash("actual-actor-task-list-empty:listener-closed:no-drafts:no-db-handles"))
    }
    func drain(_ ctx: NativeRestoreActivationContext) async throws -> NativeRestoreActivationDrain {
        if mode == "unsaved" { return .init(root:ctx.previous.root,participants:["editor","callback","listener","worker","database"],previouslyRunning:ctx.previousRunning,unfinishedTasks:1,openWritableHandles:1,unsavedEditors:1,pendingCallbacks:1,evidenceSHA256:hash("actual tasks still running")) }
        if !draft.isEmpty { try db("old").setMetadata("activation.fixture.savedDraft",value:draft);draft="" }
        listenerAccepts=false;callback?.cancel();await callback?.value;callback=nil
        oldWorker?.cancel();await oldWorker?.value;oldWorker=nil
        let before=try read("old","SELECT value FROM native_metadata WHERE key='activation.fixture.oldTicks'")
        try await Task.sleep(nanoseconds:35_000_000)
        guard before == (try read("old","SELECT value FROM native_metadata WHERE key='activation.fixture.oldTicks'")) else { throw NativeRestoreActivationFailure("host.writerStillRunning") }
        if mode == "drain" { throw NativeRestoreActivationFailure("host.drainInjected") }
        return .init(root:ctx.previous.root,participants:["editor","callback","listener","worker","database"],previouslyRunning:ctx.previousRunning,unfinishedTasks:oldWorker == nil ? 0:1,openWritableHandles:oldWorker == nil ? 0:1,unsavedEditors:draft.isEmpty ? 0:1,pendingCallbacks:callback == nil ? 0:1,evidenceSHA256:hash((before ?? "")+":closed-producer:"+String(!listenerAccepts)))
    }
    func review(_ kind: String, _ ctx: NativeRestoreActivationContext) async throws -> NativeRestoreActivationEvidence {
        if mode == "secretFailure" {throw NativeRestoreActivationFailure("never-a-real-key")}
        if kind == "sourceProvenance",let gate { await gate.pause() }
        var bytes: Data, blocked: [String] = []
        switch kind {
        case "sourceProvenance", "pendingAssets", "runtimeStartup":
            let approval=try json("approval.json")
            guard approval["snapshotID"] as? String == ctx.seal.snapshotID,approval["restoreHash"] as? String == ctx.seal.restoreSHA256,approval["actor"] as? String == NativeRestoreActivationTests.userID,
                  Set(approval["runtimes"] as! [String]) == Set(ctx.runtimeCatalog.map(\.id)),
                  Set(approval["acceptedPending"] as! [String]) == Set(ctx.inheritedPending.map(\.rawValue)) else { throw NativeRestoreActivationFailure("review.approval") }
            bytes=try Data(contentsOf:base.appendingPathComponent("approval.json"))
        case "credentials":
            let vault=try json("fake-vault.json")
            guard vault["namespace"] as? String == ctx.seal.finalNamespaceSHA256,let reference=vault["reference"] as? String,
                  try read("candidate","SELECT encryptedKey FROM ApiKeys LIMIT 1") == reference else { throw NativeRestoreActivationFailure("review.credentialBinding") }
            if vault["available"] as? Bool != true { blocked=["mail"] }
            bytes=try Data(contentsOf:base.appendingPathComponent("fake-vault.json"))
        case "relayAndPluginState":
            let remote=try json("fake-provider.json"),local=try read("candidate","SELECT value FROM native_metadata WHERE key='campaignRelay.binding.v1'")!
            let binding=try JSONSerialization.jsonObject(with:Data(local.utf8)) as! [String:Any]
            guard binding["instance"] as? String == remote["instance"] as? String,(remote["head"] as! Int) >= (binding["head"] as! Int) else { blocked=["mail"];bytes=Data(local.utf8);break }
            bytes=try Data(contentsOf:base.appendingPathComponent("fake-provider.json"))
        case "jobs":
            let unknown=try read("candidate","SELECT count(*) FROM native_outbox WHERE event='fixture.remote' AND status='running' AND delivery_started_at IS NOT NULL")
            let done=try read("candidate","SELECT count(*) FROM native_outbox WHERE event='fixture.remote' AND status='done'")
            guard unknown == "1" || (mode == "receiptResolved" && done == "1") else { throw NativeRestoreActivationFailure("review.jobFixture") }
            bytes=Data((unknown!+":"+(try read("candidate","SELECT result FROM native_outbox WHERE event='fixture.remote'") ?? "null")).utf8)
        default:throw NativeRestoreActivationFailure("review.unknown")
        }
        return .init(kind:kind,subjectSHA256:mode == "wrongScope" ? String(repeating:"0",count:64):try NativeRestoreActivation.subject(ctx),evidenceSHA256:NativeMigrationCodec.hash(bytes),checkedAt:Date().addingTimeInterval(-1),validUntil:Date().addingTimeInterval(mode == "expired" ? -1:120),blockedRuntimes:blocked,disposition:blocked.isEmpty ? "verified":"explicitlyDeferred")
    }
    func reviewRow(_ row: NativeRestorePlanEntry, _ hash: String, _ ctx: NativeRestoreActivationContext) throws -> NativeRestoreActivationRowDecision {
        reviewed += 1
        if mode == "authorityRevoked",reviewed == 1 { let database=try db("old");let user=try database.get("Users",key:["id":.text(NativeRestoreActivationTests.userID)])!;_ = try database.update(user,changes:["banned":.integer(1)],actor:NativeRestoreActivationTests.userID) }
        if mode == "mutateCandidate",reviewed == 1 { try db("candidate").setMetadata("unexpected.write",value:"changed") }
        var blocked:[String]=[],disposition="preserved",proof=""
        if row.kind == "credential",let key=row.key,let field=row.field {
            let value=try read("candidate","SELECT "+NativeBackupSQLite.quote(field)+" FROM "+NativeBackupSQLite.quote(row.model)+" WHERE id=?",[.text(key)])
            guard value == (try json("fake-vault.json")["reference"] as? String) else { throw NativeRestoreActivationFailure("review.missingCredential") };proof=value!
        } else if ["job","terminalReceipt"].contains(row.kind),let key=row.key {
            let state=try read("candidate","SELECT status||':'||coalesce(result,'null') FROM native_outbox WHERE id=?",[.text(key)])
            guard let state else { throw NativeRestoreActivationFailure("review.missingJob") };proof=state
            if row.event == "fixture.remote" {
                if mode == "receiptResolved" {
                    guard try json("control/active-root.json")["generation"] as? String == ctx.candidate.generation,
                          try json("fake-provider.json")["deliveredJob"] as? String == key else {throw NativeRestoreActivationFailure("review.receiptMismatch")}
                    let database=try db("candidate")
                    try database.transaction {
                        guard let current=try database.job(id:key) else{throw NativeRestoreActivationFailure("review.missingJob")}
                        if current.status == "running",current.deliveryStartedAt != nil {try database.finishJob(current,result:["receipt":"synthetic-already-delivered"])}
                        else{guard current.status == "done",current.result["receipt"] == "synthetic-already-delivered" else{throw NativeRestoreActivationFailure("review.receiptMismatch")}}
                    }
                    disposition="reconciled";proof="confirmed:"+key+":synthetic-already-delivered"
                } else {disposition="explicitlyDeferred";blocked=mode == "wrongEvent" ? ["local"]:["mail"]}
            }
        } else if row.model == "native_metadata",let key=row.key {
            guard let value=try read("candidate","SELECT value FROM native_metadata WHERE key=?",[.text(key)]) else { throw NativeRestoreActivationFailure("review.missingSetting") };proof=value
        } else if row.kind == "keychainOnlySettings" { proof=String(decoding:try Data(contentsOf:base.appendingPathComponent("fake-vault.json")),as:UTF8.self) }
        else { throw NativeRestoreActivationFailure("review.unhandledPlanRow") }
        return .init(rowSHA256:mode == "wrongRow" ? String(repeating:"0",count:64):hash,evidenceSHA256:NativeMigrationCodec.hash(Data(proof.utf8)),disposition:disposition,blockedRuntimes:blocked)
    }
    func prepare(_ ctx: NativeRestoreActivationContext, _ permitted: [String]) throws {
        paused=try NativeBackupSQLite(path:ctx.candidate.root.url.appendingPathComponent("crm.sqlite").path,readOnly:true,immutable:true)
        guard try paused!.first("PRAGMA integrity_check") == "ok",try paused!.first("SELECT count(*) FROM Users") == "1" else { throw NativeRestoreActivationFailure("host.candidateOpen") }
        if ["prepare","prepareAndRecovery"].contains(mode) { throw NativeRestoreActivationFailure("host.prepareInjected") }
    }
    func start(_ ctx: NativeRestoreActivationContext, _ permitted: [String]) async throws -> NativeRestoreActivationStartup {
        paused=nil
        guard !permitted.contains("mail") || mode == "receiptResolved" else { throw NativeRestoreActivationFailure("host.unreconciledSend") }
        if permitted.contains("local"),newWorker == nil {
            let database=try db("candidate")
            newWorker=Task.detached {
                while !Task.isCancelled {
                    do {
                        if let job=try database.claimJob(events:["fixture.local"]) {
                            try database.transaction {
                                try database.finishJob(job,result:["computed":"yes"])
                                let count=Int(try database.metadata("activation.fixture.localCompleted") ?? "0") ?? 0
                                try database.setMetadata("activation.fixture.localCompleted",value:String(count+1))
                            }
                        }
                        try await Task.sleep(nanoseconds:10_000_000)
                    } catch { break }
                }
            }
        }
        if permitted.contains("mail"),mailWorker == nil {
            let database=try db("candidate")
            mailWorker=Task.detached {
                while !Task.isCancelled {
                    do {
                        if let job=try database.claimJob(events:["fixture.remote"]) {
                            let calls=Int(try database.metadata("activation.fixture.providerCalls") ?? "0") ?? 0
                            try database.setMetadata("activation.fixture.providerCalls",value:String(calls+1))
                            try database.finishJob(job,result:["receipt":"synthetic-new-delivery"])
                        }
                        let scans=Int(try database.metadata("activation.fixture.mailScans") ?? "0") ?? 0
                        try database.setMetadata("activation.fixture.mailScans",value:String(scans+1))
                        try await Task.sleep(nanoseconds:10_000_000)
                    } catch {break}
                }
            }
        }
        try await Task.sleep(nanoseconds:45_000_000)
        if mode == "start" { throw NativeRestoreActivationFailure("host.startInjected") }
        let count=try read("candidate","SELECT value FROM native_metadata WHERE key='activation.fixture.localCompleted'") ?? "0"
        guard permitted.isEmpty || (newWorker != nil && count == "1") else { throw NativeRestoreActivationFailure("host.noActualWork") }
        if permitted.contains("mail") {guard mailWorker != nil,Int(try read("candidate","SELECT value FROM native_metadata WHERE key='activation.fixture.mailScans'") ?? "0")! > 0 else{throw NativeRestoreActivationFailure("host.noActualWork")}}
        return .init(started:permitted,held:permitted.contains("mail") ? []:["mail"],evidenceSHA256:hash("local-completed:"+count+":external-sends:0"))
    }
    func closeCandidate(_ context: NativeRestoreActivationContext) async { newWorker?.cancel();mailWorker?.cancel();await newWorker?.value;await mailWorker?.value;newWorker=nil;mailWorker=nil;paused=nil }
    func resume(_ ctx: NativeRestoreActivationContext, _ drain: NativeRestoreActivationDrain?) async throws -> NativeRestoreActivationStartup {
        if mode == "prepareAndRecovery" { throw NativeRestoreActivationFailure("host.resumeInjected") }
        if ctx.previousRunning.contains("local") { try await startOld() }
        return .init(started:oldWorker == nil ? []:["local"],held:[],evidenceSHA256:hash("old-ticks:"+(try read("old","SELECT value FROM native_metadata WHERE key='activation.fixture.oldTicks'") ?? "0")))
    }
    func stop() async { oldWorker?.cancel();callback?.cancel();newWorker?.cancel();mailWorker?.cancel();await oldWorker?.value;await callback?.value;await newWorker?.value;await mailWorker?.value;oldWorker=nil;callback=nil;newWorker=nil;mailWorker=nil;paused=nil;listenerAccepts=false;draft="" }
    nonisolated func hooks() -> NativeRestoreActivationHooks {
        .init(runtimes:[.init(id:"local",events:["fixture.local"],canProduceExternalEffects:false),.init(id:"mail",events:["fixture.remote"],canProduceExternalEffects:true)],writerParticipants:["editor","callback","listener","worker","database"],authorize:{try await self.authorize()},capturePreviousRunning:{try await self.capture($0)},drain:{try await self.drain($0)},verifyRecoveryQuiescence:{try await self.recoveryQuiescence($0,$1)},review:{try await self.review($0,$1)},reviewRow:{try await self.reviewRow($0,$1,$2)},preparePaused:{try await self.prepare($0,$1)},resumeCommitted:{try await self.start($0,$1)},closeCandidate:{await self.closeCandidate($0)},resumePrevious:{try await self.resume($0,$1)})
    }
    func setGate(_ gate: ActivationGate) { self.gate=gate }
}

@main enum NativeRestoreActivationTests {
    static let userID="c4000000-0000-4000-8000-000000000001"
    static var checks=0
    static func check(_ value: Bool,_ label: String) throws { guard value else { throw NativeMigrationFailure("test.assert",label) };checks += 1 }
    static func writeJSON(_ value: Any,_ url: URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:url,options:.atomic) }
    static func publicationMarker(_ base:URL,role:NativeDataMaintenanceRecoveryRole = .publication)throws {
        let marker=NativeDataMaintenanceRecoveryMarker(version:1,registry:UUID().uuidString.lowercased(),operation:UUID().uuidString.lowercased(),role:role,nonce:UUID().uuidString.lowercased(),uid:geteuid())
        let file=base.appendingPathComponent("candidate/"+NativeRestoreActivationVerifier.publicationMarker)
        try JSONEncoder().encode(marker).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func prepare(_ base: URL,_ resources: URL,publication:Bool=false) throws {
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let old=base.appendingPathComponent("old",isDirectory:true),candidate=base.appendingPathComponent("candidate",isDirectory:true)
        do {
            let database=try NativeDatabase(url:old.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
            _ = try database.insert("Users",values:["id":.text(userID),"email":.text("isolated@example.invalid"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:userID)
            _ = try database.insert("ApiKeys",values:["scope":.text("SYSTEM"),"provider":.text("OPENAI"),"encryptedKey":.text("native-ai-keychain:synthetic-reference")],actor:userID)
            try database.setMetadata("campaignRelay.binding.v1",value:"{\"instance\":\"synthetic\",\"head\":10}")
            try database.setMetadata("localActor",value:userID)
            _ = try database.enqueue("fixture.local",payload:["purpose":"isolated local operation"])
            _ = try database.enqueue("fixture.remote",payload:["purpose":"unknown delivery; never resend"])
            let remote=try database.claimJob(events:["fixture.remote"])!;_ = try database.markJobDeliveryStarted(remote)
            let avatarID="c4000000-0000-4000-8000-000000000002",folder=old.appendingPathComponent("native-avatars")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let png=Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            for suffix in [".png",".original.png"] { let file=folder.appendingPathComponent(avatarID+suffix);try png.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:file.path) }
            let user=try database.get("Users",key:["id":.text(userID)])!;_ = try database.update(user,changes:["avatar":.text("native-avatar:v1:"+avatarID+".png")],actor:userID)
            let backup=NativeBackup().prepare(source:database,destinationURL:base.appendingPathComponent("backup"))
            guard backup.candidateCreated else { throw NativeMigrationFailure("test.backup",backup.diagnostics.map(\.code).joined(separator:",")) }
        }
        let restored=NativeRestore().prepare(backupURL:base.appendingPathComponent("backup"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),destinationURL:candidate)
        guard restored.candidateCreated else { throw NativeMigrationFailure("test.restore",restored.diagnostics.map(\.code).joined(separator:",")) }
        if publication{try publicationMarker(base)}
        let verifier=NativeRestoreActivationVerifier(schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{false})
        let value=try verifier.inspect(candidate)
        try writeJSON(["snapshotID":restored.snapshotID,"restoreHash":value.seal.restoreSHA256,"actor":userID,"acceptedPending":restored.inheritedPending.map(\.rawValue),"runtimes":["local","mail"]],base.appendingPathComponent("approval.json"))
        try writeJSON(["namespace":value.seal.finalNamespaceSHA256,"reference":"native-ai-keychain:synthetic-reference","available":true,"syntheticSecret":"never-a-real-key"],base.appendingPathComponent("fake-vault.json"))
        try writeJSON(["instance":"synthetic","head":12,"externalRequests":0],base.appendingPathComponent("fake-provider.json"))
    }
    static func engine(_ base: URL,_ resources: URL,crash: String? = nil,fail: String? = nil,cancel: String? = nil) throws -> NativeRestoreActivation {
        try .init(controlURL:base.appendingPathComponent("control"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),checkpoint:{point in if crash == point { _exit(72) };if fail == point { throw NativeRestoreActivationFailure("test.checkpoint") };if cancel == point { withUnsafeCurrentTask{$0?.cancel()} }})
    }
    static func scalar(_ base: URL,_ root: String,_ sql: String) throws -> String? { let path=base.appendingPathComponent(root+"/crm.sqlite").path;return try NativeBackupSQLite(path:path,readOnly:true,immutable:!FileManager.default.fileExists(atPath:path+"-wal")).first(sql) }
    static func unknown(_ base: URL,_ root: String) throws -> String { try scalar(base,root,"SELECT id||':'||status||':'||lease_token||':'||delivery_started_at||':'||coalesce(result,'null') FROM native_outbox WHERE event='fixture.remote'")! }
    static func run(_ resources: URL) async throws {
        let temporary=try NativeMigrationImportWorkspace.resolvedTemporaryDirectory()
        let suite=temporary.appendingPathComponent("NextCRMActivationTests-"+UUID().uuidString.lowercased());defer{try? FileManager.default.removeItem(at:suite)}
        let modes=["normal","publication","drain","unsaved","prepare","prepareAndRecovery","start","expired","wrongScope","wrongRow","wrongEvent","authorityRevoked","mutateCandidate","finalCandidateMutation","finalWAL","wrongNamespace","secretFailure"]
        for mode in modes {
            print("Activation case: "+mode)
            let base=suite.appendingPathComponent(mode);try prepare(base,resources,publication:mode == "publication")
            if mode == "wrongNamespace" {
                var vault=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("fake-vault.json"))) as! [String:Any]
                vault["namespace"]=String(repeating:"0",count:64);try writeJSON(vault,base.appendingPathComponent("fake-vault.json"))
            }
            let before=try unknown(base,"candidate"),host=ActivationHost(base:base,resources:resources,mode:mode)
            try await host.startOld();let hooks=host.hooks(),engine=try engine(base,resources)
            let result=try await engine.activate(candidateURL:base.appendingPathComponent("candidate"),currentRootURL:base.appendingPathComponent("old"),hooks:hooks)
            try check(try unknown(base,"candidate") == before,"individual unknown job/lease/result unchanged "+mode)
            try check(try scalar(base,"old","SELECT status FROM native_outbox WHERE event='fixture.local'") == "pending","old queue unchanged "+mode)
            if ["normal","publication","start"].contains(mode) {
                try check(result.activated,"candidate selected "+mode)
                try check(result.journal.phase == (mode == "start" ? .activeDegraded:.active),"postcommit result "+mode)
                try check(try scalar(base,"candidate","SELECT value FROM native_metadata WHERE key='activation.fixture.localCompleted'") == "1","actual permitted local job executed "+mode)
                let ticks=try scalar(base,"old","SELECT value FROM native_metadata WHERE key='activation.fixture.oldTicks'");try await Task.sleep(nanoseconds:40_000_000)
                try check(try scalar(base,"old","SELECT value FROM native_metadata WHERE key='activation.fixture.oldTicks'") == ticks,"old writer remains stopped after commit "+mode)
                try check(result.journal.heldRuntimes == ["mail"] && result.journal.permittedRuntimes == ["local"],"explicit event-specific resume policy")
            } else {
                try check(!result.activated,"failed switch preserves old selection "+mode)
                try check(result.journal.phase == (mode == "prepareAndRecovery" ? .recoveryRequired:.previousRestored),"accurate old recovery state "+mode)
                try check(try scalar(base,"candidate","SELECT status FROM native_outbox WHERE event='fixture.local'") == "pending","no candidate effects before commit "+mode)
            }
            try check(try scalar(base,"old","SELECT value FROM native_metadata WHERE key='activation.fixture.staleCallback'") == nil,"delayed callback fenced "+mode)
            if mode == "secretFailure" {
                try check(result.journal.failureCode == "activation.reviewing.failed" && !(String(decoding:try JSONEncoder().encode(result.journal),as:UTF8.self).contains("never-a-real-key")),"provider error code cannot leak secret into durable journal")
            }
            if mode == "normal" {
                do { _ = try await engine.recover(hooks:hooks);throw NativeMigrationFailure("test.liveRecovery","live runtimes accepted as cold restart") }
                catch let error as NativeRestoreActivationFailure { try check(error.code == "recovery.notQuiescent","live host rejected from cold recovery") }
                await host.stop()
                let cold=try await engine.recover(hooks:hooks)!
                try check(cold.activated && cold.journal.phase == .activeDegraded,"successful journal is held on cold restart")
                let resumed=try await engine.resumeRecovered(hooks:hooks)
                try check(resumed.journal.phase == .active && (try scalar(base,"candidate","SELECT value FROM native_metadata WHERE key='activation.fixture.localCompleted'")) == "1","fresh recovery restarts without duplicate local effects")
                await host.stop()
                var receipt=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("fake-provider.json"))) as! [String:Any]
                receipt["deliveredJob"]=try scalar(base,"candidate","SELECT id FROM native_outbox WHERE event='fixture.remote'")!
                try writeJSON(receipt,base.appendingPathComponent("fake-provider.json"))
                let reconciled=ActivationHost(base:base,resources:resources,mode:"receiptResolved"),fresh=reconciled.hooks()
                _ = try await engine.recover(hooks:fresh)
                let permitted=try await engine.resumeRecovered(hooks:fresh)
                try check(permitted.journal.phase == .active && permitted.journal.heldRuntimes.isEmpty && permitted.journal.permittedRuntimes == ["local","mail"],"held provider can resume after actual receipt reconciliation")
                try check(try scalar(base,"candidate","SELECT status||':'||json_extract(result,'$.receipt') FROM native_outbox WHERE event='fixture.remote'") == "done:synthetic-already-delivered","only receipted job is CAS-completed")
                try check(try scalar(base,"candidate","SELECT value FROM native_metadata WHERE key='activation.fixture.providerCalls'") == nil,"resumed provider does not resend delivered work")
                try check(try scalar(base,"old","SELECT status FROM native_outbox WHERE event='fixture.remote'") == "running","old unknown job is preserved even when candidate receipt resolves")
                await reconciled.stop()
            }
            await host.stop()
        }
        do {
            let base=suite.appendingPathComponent("secretAuthorize");try prepare(base,resources)
            let host=ActivationHost(base:base,resources:resources,mode:"secretAuthorize")
            do{_ = try await engine(base,resources).activate(candidateURL:base.appendingPathComponent("candidate"),currentRootURL:base.appendingPathComponent("old"),hooks:host.hooks());throw NativeMigrationFailure("test.secret","authorization error ignored")}
            catch let error as NativeRestoreActivationFailure{try check(error.code == "host.authorization" && !error.localizedDescription.contains("never-a-real-key"),"provider authorization error is safe for UI")}
        }
        for point in ["pointerCommitted","committed","providersStarted"] {
            let base=suite.appendingPathComponent("cancel-"+point);try prepare(base,resources)
            let host=ActivationHost(base:base,resources:resources,mode:"normal");try await host.startOld()
            let hooks=host.hooks(),activation=try engine(base,resources,cancel:point)
            let task=Task{try await activation.activate(candidateURL:base.appendingPathComponent("candidate"),currentRootURL:base.appendingPathComponent("old"),hooks:hooks)}
            let result=try await task.value
            try check(result.activated,"postcommit cancellation never restores old selection "+point)
            try check(result.journal.phase == (point == "providersStarted" ? .active:.activeDegraded),"completed provider success retained; incomplete start held "+point)
            try check(try scalar(base,"candidate","SELECT status FROM native_outbox WHERE event='fixture.local'") == (point == "providersStarted" ? "done":"pending"),"postcommit cancel has accurate effect outcome "+point)
            await host.stop()
        }
        for test in ["cancel","parallel"] {
            let base=suite.appendingPathComponent(test);try prepare(base,resources)
            let host=ActivationHost(base:base,resources:resources,mode:"normal"),gate=ActivationGate();await host.setGate(gate);try await host.startOld()
            let hooks=host.hooks(),first=try engine(base,resources),task=Task{try await first.activate(candidateURL:base.appendingPathComponent("candidate"),currentRootURL:base.appendingPathComponent("old"),hooks:hooks)}
            await gate.wait()
            if test == "cancel" { task.cancel() }
            else {
                do { _ = try await engine(base,resources).activate(candidateURL:base.appendingPathComponent("candidate"),currentRootURL:base.appendingPathComponent("old"),hooks:hooks);throw NativeMigrationFailure("test.parallel","switch lock bypass") } catch let error as NativeRestoreActivationFailure { try check(error.code == "control.busy","cross-controller flock excludes concurrent activation") }
            }
            await gate.release();let result=try await task.value
            try check(result.journal.phase == (test == "cancel" ? .previousRestored:.active),"cancel compensation independent of cancelled task / parallel completion")
            await host.stop()
        }
        for test in ["unlistedAsset","linkedDatabase"] {
            let base=suite.appendingPathComponent(test);try prepare(base,resources)
            let verifier=NativeRestoreActivationVerifier(schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{false})
            let candidate=try verifier.inspect(base.appendingPathComponent("candidate"))
            if test == "unlistedAsset" {
                let file=base.appendingPathComponent("candidate/native-avatars/c4000000-0000-4000-8000-000000000003.png")
                try Data("not in snapshot".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
            } else { try FileManager.default.linkItem(at:base.appendingPathComponent("candidate/crm.sqlite"),to:base.appendingPathComponent("shared-database")) }
            do{try verifier.unchanged(candidate);throw NativeMigrationFailure("test.tree","unsealed candidate accepted")}
            catch let error as NativeRestoreActivationFailure{try check(error.code == (test == "unlistedAsset" ? "candidate.fileCount":"candidate.fileType"),"unsealed filesystem rejected "+test)}
        }
        for test in ["markerChanged","markerWrongRole"] {
            let base=suite.appendingPathComponent(test);try prepare(base,resources,publication:true)
            let verifier=NativeRestoreActivationVerifier(schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{false})
            let candidate=try verifier.inspect(base.appendingPathComponent("candidate"))
            try publicationMarker(base,role:test == "markerWrongRole" ? .temporary:.publication)
            do{try verifier.unchanged(candidate);throw NativeMigrationFailure("test.marker","changed publication marker accepted")}
            catch let error as NativeRestoreActivationFailure{try check(error.code == (test == "markerWrongRole" ? "candidate.publicationMarker":"candidate.changed"),"inert publication marker is validated and sealed "+test)}
        }
        // Rehashing a dishonest plan does not make it match actual DB state.
        let base=suite.appendingPathComponent("planForgery");try prepare(base,resources)
        let plan=base.appendingPathComponent("candidate/resume-plan.ndjson"),raw=try Data(contentsOf:plan)
        let lines=String(decoding:raw,as:UTF8.self).split(separator:"\n").dropFirst().joined(separator:"\n")+"\n";try Data(lines.utf8).write(to:plan)
        var result=try JSONDecoder().decode(NativeRestoreResult.self,from:Data(contentsOf:base.appendingPathComponent("candidate/restore.json")))
        result.planRows -= 1;result.resumePlanSHA256=NativeMigrationCodec.hash(Data(lines.utf8));try JSONEncoder().encode(result).write(to:base.appendingPathComponent("candidate/restore.json"))
        let verifier=NativeRestoreActivationVerifier(schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"),cancelled:{false})
        do { try verifier.validate(verifier.inspect(base.appendingPathComponent("candidate")));throw NativeMigrationFailure("test.forgery","false plan accepted") } catch is NativeRestoreActivationFailure { checks += 1 }
        print("Native restore activation: \(checks) checks passed")
    }
    static func main() async {
        do {
            let resources=URL(fileURLWithPath:CommandLine.arguments[1])
            if CommandLine.arguments.count == 2 { try await run(resources);return }
            let mode=CommandLine.arguments[2],base=URL(fileURLWithPath:CommandLine.arguments[3])
            if mode == "prepare" { try prepare(base,resources);return }
            let host=ActivationHost(base:base,resources:resources,mode:"normal"),hooks=host.hooks()
            let engine=try engine(base,resources,crash:mode == "crash" ? CommandLine.arguments[4]:nil)
            if mode == "crash" { try await host.startOld();_ = try await engine.activate(candidateURL:base.appendingPathComponent("candidate"),currentRootURL:base.appendingPathComponent("old"),hooks:hooks);throw NativeMigrationFailure("test.crash","checkpoint not reached") }
            let recovered=try await engine.recover(hooks:hooks)!
            var result=recovered
            if recovered.activated,recovered.journal.phase == .activeDegraded { result=try await engine.resumeRecovered(hooks:hooks) }
            try check(result.journal.phase == (result.activated ? .active:.previousRestored),"crash recovery reaches real usable root")
            if result.activated { try check(try scalar(base,"candidate","SELECT value FROM native_metadata WHERE key='activation.fixture.localCompleted'") == "1","postcommit recovery does not duplicate local job") }
            try check(try scalar(base,"candidate","SELECT status FROM native_outbox WHERE event='fixture.remote'") == "running","recovery preserves unknown external outcome")
            await host.stop();print("Native restore recovery: \(checks) checks passed; activated=\(result.activated)")
        } catch { fputs("\(error)\n",stderr);exit(1) }
    }
}
