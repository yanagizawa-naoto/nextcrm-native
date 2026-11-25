import AppKit
import SQLite3
import CryptoKit

@main enum NativePersonalWorkspaceTests {
    @MainActor static func main() async {
        do { try await run() } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), root = URL(fileURLWithPath: CommandLine.arguments[2])
        let seeds = URL(fileURLWithPath: CommandLine.arguments[3])
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message(label) }; checks += 1 }
        func reject(_ label: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("accepted: " + label) }
        func open(_ name: String) throws -> NativeDatabase {
            try NativeDatabase(url: root.appendingPathComponent(name + "/crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        }
        func sql(_ db: URL, _ text: String, ignoreChecks: Bool = false) throws -> [[String: String]] {
            var handle: OpaquePointer?, stmt: OpaquePointer?
            guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NativeDBError.conflict }
            defer { sqlite3_finalize(stmt); sqlite3_close(handle) }
            if ignoreChecks { guard sqlite3_exec(handle, "PRAGMA ignore_check_constraints=ON", nil, nil, nil) == SQLITE_OK else { throw NativeDBError.conflict } }
            guard sqlite3_prepare_v2(handle, text, -1, &stmt, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(handle))) }
            var rows: [[String: String]] = []
            while true { let code = sqlite3_step(stmt); if code == SQLITE_DONE { break }; guard code == SQLITE_ROW else { throw NativeDBError.message(String(cString: sqlite3_errmsg(handle))) }
                var row: [String: String] = [:]; for c in 0..<sqlite3_column_count(stmt) { row[String(cString: sqlite3_column_name(stmt, c))] = sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "<NULL>" }; rows.append(row)
            }; return rows
        }
        func user(_ db: NativeDatabase, _ name: String, role: String = "user", status: String = "ACTIVE", banned: Int64 = 0) throws -> NativeRecord {
            try db.insert("Users", values: ["name": .text(name), "email": .text(name + "@fixture.invalid"), "role": .text(role), "userStatus": .text(status), "banned": .integer(banned)], actor: "fixture")
        }
        func pristine(_ db: NativeDatabase) throws -> Bool { if case .pristine = try NativePersonalWorkspace.inspect(db) { return true }; return false }
        func identity(_ db: NativeDatabase, _ id: String) throws -> CRMIdentity { try NativePersonalWorkspace.bind(NativePersonalWorkspace.select(db, userID: id), to: db, authorize: {}) }
        func snapshot(_ db: NativeDatabase) throws -> [[String: String]] { try sql(db.url, "SELECT * FROM Users ORDER BY id") }
        func snapshotFile(_ file: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined() }
        func backup(_ db: NativeDatabase, to output: URL) throws {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            var input: OpaquePointer?, destination: OpaquePointer?
            guard sqlite3_open_v2(db.url.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  sqlite3_open_v2(output.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw NativeDBError.conflict }
            defer { if let input { sqlite3_close(input) }; if let destination { sqlite3_close(destination) } }
            guard let copy = sqlite3_backup_init(destination, "main", input, "main") else { throw NativeDBError.conflict }
            let code = sqlite3_backup_step(copy, -1); let end = sqlite3_backup_finish(copy)
            guard code == SQLITE_DONE, end == SQLITE_OK, sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw NativeDBError.conflict }
            guard sqlite3_close(destination) == SQLITE_OK else { throw NativeDBError.conflict }; destination = nil
            // SQLite on this OS can retain a detached SHM after changing a
            // backup's WAL header to DELETE. This is our exclusively owned
            // synthetic destination, all connections are closed, and WAL must
            // already be absent before removing that test-fixture sidecar.
            guard !FileManager.default.fileExists(atPath: output.path + "-wal") else { throw NativeDBError.conflict }
            let shm = URL(fileURLWithPath: output.path + "-shm")
            if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
        }
        let fresh = try open("fresh")
        try check(try fresh.isPristinePersonalWorkspace() && pristine(fresh), "strict pristine native DB")
        let first = try CRMService.bootstrap(fresh, resources: seeds)
        try check(first.role == "admin", "fresh owner is admin")
        try check(try fresh.metadata("localActor") == first.id, "fresh owner bound")
        try check(try fresh.metadata("initialConfiguration") == "1" && fresh.metadata("initialOrderSeries") == "1", "fresh seeds committed")
        try check(try fresh.page("Users", fields: []).total == 1, "one initial user")
        try check(try fresh.page("Currency", fields: []).total == 4, "source native currency seeds")
        let firstAudit = try fresh.auditCount("Users")
        try check(try CRMService.bootstrap(fresh, resources: seeds).id == first.id && fresh.auditCount("Users") == firstAudit, "bootstrap idempotent")
        let interrupted = try open("seed-failure")
        interrupted.beforeRecordWrite = { model,_,_,values,_ in if model == "Currency" { throw NativeDBError.conflict }; return values }
        try reject("seed failure", { _ = try CRMService.bootstrap(interrupted, resources: seeds) })
        try check(try interrupted.isPristinePersonalWorkspace(), "all seed changes rollback")
        interrupted.beforeRecordWrite = nil
        try reject("missing resource", { _ = try CRMService.bootstrap(interrupted, resources: root.appendingPathComponent("missing")) })
        try check(try interrupted.isPristinePersonalWorkspace(), "missing seed rollback")
        let legacy = try open("legacy")
        let chosen = try user(legacy, "選択する本人", role: "manager"), history = try user(legacy, "過去の担当者", status: "INACTIVE")
        _ = try legacy.insert("crm_Accounts", values: ["v": .integer(0), "name": .text("過去の取引先"), "assigned_to": history["id"]], actor: history["id"].string)
        let originalRows = try snapshot(legacy), audit = try legacy.auditCount("Users")
        if case .needsSelection(invalidBinding: false) = try NativePersonalWorkspace.inspect(legacy) { checks += 1 } else { throw NativeDBError.conflict }
        try reject("legacy has no fallback admin", { _ = try CRMService.bootstrap(legacy, resources: seeds) })
        try check(try snapshot(legacy) == originalRows && legacy.metadata("localActor") == nil, "failed bootstrap preserves legacy users")
        let selection = try NativePersonalWorkspace.select(legacy, userID: chosen["id"].string)
        try check(selection.identity.role == "manager" && selection.ownerRevision == chosen.revision, "selection is existing actual role/revision")
        try check(try legacy.metadata("localActor") == nil && snapshot(legacy) == originalRows, "selection no DB write")
        try reject("authority denied", { _ = try NativePersonalWorkspace.bind(selection, to: legacy, authorize: { throw NativeDBError.conflict }) })
        try check(try legacy.metadata("localActor") == nil, "authority rejection no binding")
        try reject("outer rollback", { try legacy.transaction { _ = try NativePersonalWorkspace.bind(selection, to: legacy, authorize: {}); throw NativeDBError.conflict } })
        try check(try legacy.metadata("localActor") == nil, "binding rollback follows outer transaction")
        try reject("nested rollback", { try legacy.transaction { try legacy.transaction { _ = try NativePersonalWorkspace.bind(selection, to: legacy, authorize: {}); throw NativeDBError.conflict } } })
        try check(try legacy.metadata("localActor") == nil, "nested binding rollback")
        let bound = try NativePersonalWorkspace.bind(selection, to: legacy, authorize: {})
        try check(bound.id == chosen["id"].string && bound.role == "manager", "explicit binding preserves role")
        try check(try snapshot(legacy) == originalRows && legacy.auditCount("Users") == audit, "bind alters no Users/audit/history")
        try check(try legacy.page("Currency", fields: []).total == 0 && legacy.metadata("initialConfiguration") == nil, "binding adds no seed data")
        try check(try CRMService.bootstrap(legacy, resources: root.appendingPathComponent("missing")).id == bound.id, "existing owner reused without seed resources")
        try check(try legacy.metadata("initialOrderSeries") == nil && legacy.page("NumberSeries", fields: []).total == 0, "existing owner creates no order seed")
        let other = try user(legacy, "別の有効利用者", role: "admin")
        try reject("existing valid owner cannot be replaced", { _ = try NativePersonalWorkspace.select(legacy, userID: other["id"].string) })
        for state in ["PENDING", "INACTIVE", "BANNED", "DANGLING", "BADROLE"] {
            let db = try open("invalid-" + state), row = try user(db, "invalid-" + state, role: "admin", status: ["PENDING", "INACTIVE"].contains(state) ? state : "ACTIVE", banned: state == "BANNED" ? 1 : 0)
            try db.setMetadata("localActor", value: state == "DANGLING" ? UUID().uuidString.lowercased() : row["id"].string)
            if state == "BADROLE" { _ = try sql(db.url, "UPDATE Users SET role='invalid' WHERE id='\(row["id"].string)'", ignoreChecks: true) }
            let before = try snapshot(db)
            try reject("invalid existing " + state, { _ = try NativePersonalWorkspace.reuseExisting(db) })
            try reject("invalid bootstrap " + state, { _ = try CRMService.bootstrap(db, resources: seeds) })
            try check(try snapshot(db) == before && db.page("Users", fields: []).total == 1, "invalid owner untouched " + state)
        }
        for kind in ["business", "softDeleted", "metadata", "outbox", "audit", "cleanup", "unknownTable", "unknownView", "unknownTrigger", "importMarker"] {
            let db = try open("nonempty-" + kind)
            switch kind {
            case "business": _ = try db.insert("Currency", values: ["code": .text("USD"), "name": .text("legacy"), "symbol": .text("$")], actor: "fixture")
            case "softDeleted": _ = try db.insert("crm_Accounts", values: ["v": .integer(0), "name": .text("削除履歴"), "deletedAt": .text("2025-01-01T00:00:00.000Z")], actor: "fixture")
            case "metadata": try db.setMetadata("migration.operational.state", value: "review-required")
            case "outbox": _ = try db.enqueue("fixture", payload: [:])
            case "audit": _ = try sql(db.url, "INSERT INTO native_audit VALUES('one','Users','{}','insert','old','2025-01-01',NULL,NULL)")
            case "cleanup": try db.queueAIKeyCleanup(UUID().uuidString, notBefore: Date())
            case "unknownTable": _ = try sql(db.url, "CREATE TABLE foreign_import(id TEXT)")
            case "unknownView": _ = try sql(db.url, "CREATE VIEW foreign_import AS SELECT id FROM Users")
            case "unknownTrigger": _ = try sql(db.url, "CREATE TRIGGER foreign_import AFTER INSERT ON Users BEGIN SELECT 1; END")
            default: try Data("imported".utf8).write(to: db.url.deletingLastPathComponent().appendingPathComponent(".native-migration-candidate"))
            }
            try check(try !pristine(db), "not pristine " + kind)
            try reject("no automatic admin " + kind, { _ = try CRMService.bootstrap(db, resources: seeds) })
            try check(try db.page("Users", fields: []).total == 0 && db.metadata("localActor") == nil, "zero users retained " + kind)
        }
        let cas = try open("cas"), ca = try user(cas, "CAS本人"), cb = try user(cas, "CAS他人")
        let stale = try NativePersonalWorkspace.select(cas, userID: ca["id"].string)
        _ = try cas.update(ca, changes: ["name": .text("変更後")], actor: "fixture")
        try reject("row revision fence", { _ = try NativePersonalWorkspace.bind(stale, to: cas, authorize: {}) })
        let current = try NativePersonalWorkspace.select(cas, userID: ca["id"].string)
        try cas.setMetadata("localActor", value: cb["id"].string)
        try reject("metadata CAS", { _ = try NativePersonalWorkspace.bind(current, to: cas, authorize: {}) })
        try check(try cas.metadata("localActor") == cb["id"].string, "CAS winner preserved")
        let revoked = try open("revoked"), ra = try user(revoked, "失権本人")
        let rt = try NativePersonalWorkspace.select(revoked, userID: ra["id"].string)
        _ = try revoked.update(ra, changes: ["userStatus": .text("INACTIVE")], actor: "fixture")
        try reject("current revoked", { _ = try NativePersonalWorkspace.bind(rt, to: revoked, authorize: {}) })
        try check(try revoked.metadata("localActor") == nil, "revoked no bind")
        let restoreBound = try open("revived-binding"), previouslyBanned = try user(restoreBound, "復活元本人", banned: 1), replacement = try user(restoreBound, "選択候補")
        try restoreBound.setMetadata("localActor", value: previouslyBanned["id"].string)
        let replacementTicket = try NativePersonalWorkspace.select(restoreBound, userID: replacement["id"].string)
        _ = try restoreBound.update(previouslyBanned, changes: ["banned": .integer(0)], actor: "fixture")
        try reject("revived original binding preserved", { _ = try NativePersonalWorkspace.bind(replacementTicket, to: restoreBound, authorize: {}) })
        let cancelDB = try open("cancel"), cancelUser = try user(cancelDB, "取消本人"), cancelTicket = try NativePersonalWorkspace.select(cancelDB, userID: cancelUser["id"].string)
        let cancelTask = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return try NativePersonalWorkspace.bind(cancelTicket, to: cancelDB, authorize: {})
        }
        cancelTask.cancel()
        do { _ = try await cancelTask.value; throw NativeDBError.message("cancel accepted") } catch is CancellationError { checks += 1 }
        try check(try cancelDB.metadata("localActor") == nil, "cancel no bind")
        let immutable = root.appendingPathComponent("sealed/crm.sqlite")
        try backup(cancelDB, to: immutable)
        let hash = try snapshotFile(immutable), contents = try FileManager.default.contentsOfDirectory(atPath: immutable.deletingLastPathComponent().path)
        let ro = try NativeDatabase(readOnlyURL: immutable, schemaURL: resources.appendingPathComponent("schema.json"))
        if case .needsSelection = try NativePersonalWorkspace.inspect(ro) { checks += 1 } else { throw NativeDBError.conflict }
        try check(try NativePersonalWorkspace.owners(ro).total == 1, "sealed owner list")
        let reviewed = try NativePersonalWorkspace.select(ro, userID: cancelUser["id"].string)
        var readOnlyAuthorizationCalled = false
        try reject("readonly cannot bind", { _ = try NativePersonalWorkspace.bind(reviewed, to: ro, authorize: { readOnlyAuthorizationCalled = true }) })
        try reject("readonly cannot bootstrap", { _ = try CRMService.bootstrap(ro, resources: seeds) })
        try check(!readOnlyAuthorizationCalled, "readonly rejected before authority callback")
        try check(try snapshotFile(immutable) == hash && FileManager.default.contentsOfDirectory(atPath: immutable.deletingLastPathComponent().path) == contents, "sealed DB/sidecars unchanged")
        let committed = root.appendingPathComponent("committed/crm.sqlite")
        try FileManager.default.createDirectory(at: committed.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.copyItem(at: immutable, to: committed)
        let active = try NativeDatabase(url: committed, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        var authority = 0
        try check(try NativePersonalWorkspace.bind(reviewed, to: active, authorize: { authority += 1 }).id == cancelUser["id"].string && authority == 1, "review selection binds only after writable committed open")
        try check(try snapshotFile(immutable) == hash, "source seal remains unchanged after destination bind")
        let descriptorData = try JSONEncoder().encode(reviewed.descriptor)
        let descriptor = try JSONDecoder().decode(NativePersonalWorkspace.BindingDescriptor.self, from: descriptorData)
        try check(descriptor == reviewed.descriptor, "durable snapshot exact Codable roundtrip")
        let activeRow = try active.get("Users", key: ["id": .text(descriptor.ownerID)])!
        _ = try active.update(activeRow, changes: ["name": .text("確定後プロフィール"), "role": .text("manager")], actor: "fixture")
        try reject("ordinary bind remains strict after profile update", { _ = try NativePersonalWorkspace.bind(reviewed, to: active, authorize: {}) })
        let beforeResume = try snapshot(active)
        try check(try NativePersonalWorkspace.resumeBinding(descriptor, to: active, authorize: {}).role == "manager", "pending recovery respects current role/profile")
        try check(try snapshot(active) == beforeResume, "same owner resume writes no Users")
        try reject("resume current authority required", { _ = try NativePersonalWorkspace.resumeBinding(descriptor, to: active, authorize: { throw NativeDBError.conflict }) })
        try reject("resume readonly rejected", { _ = try NativePersonalWorkspace.resumeBinding(descriptor, to: ro, authorize: {}) })
        let committed2 = root.appendingPathComponent("committed2/crm.sqlite")
        try FileManager.default.createDirectory(at: committed2.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.copyItem(at: immutable, to: committed2)
        let active2 = try NativeDatabase(url: committed2, schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        var tampered = try JSONSerialization.jsonObject(with: descriptorData) as! [String: Any]
        tampered["role"] = "admin"
        let changedRole = try JSONDecoder().decode(NativePersonalWorkspace.BindingDescriptor.self, from: JSONSerialization.data(withJSONObject: tampered))
        try reject("pre-bind forged role rejected", { _ = try NativePersonalWorkspace.resumeBinding(changedRole, to: active2, authorize: {}) })
        try check(try active2.metadata("localActor") == nil, "forged role does not bind")
        tampered["version"] = 2
        let future = try JSONDecoder().decode(NativePersonalWorkspace.BindingDescriptor.self, from: JSONSerialization.data(withJSONObject: tampered))
        try reject("unsupported descriptor version", { _ = try NativePersonalWorkspace.resumeBinding(future, to: active2, authorize: {}) })
        try check(try NativePersonalWorkspace.resumeBinding(descriptor, to: active2, authorize: {}).id == descriptor.ownerID, "durable pre-bind recovery completes exact owner")
        let nowInactive = try active2.get("Users", key: ["id": .text(descriptor.ownerID)])!
        _ = try active2.update(nowInactive, changes: ["userStatus": .text("INACTIVE")], actor: "fixture")
        try reject("same-owner recovery still rejects revoked identity", { _ = try NativePersonalWorkspace.resumeBinding(descriptor, to: active2, authorize: {}) })
        let paging = try open("paging")
        try paging.transaction { for i in 0..<205 { _ = try user(paging, String(format: "利用者%03d", i)) }; _ = try user(paging, "inactive", status: "INACTIVE"); _ = try user(paging, "pending", status: "PENDING"); _ = try user(paging, "banned", banned: 1) }
        for (offset, count) in [(0,100),(100,100),(200,5)] { let page = try NativePersonalWorkspace.owners(paging, offset: offset); try check(page.rows.count == count && page.total == 205, "bounded page \(offset)") }
        try check(try NativePersonalWorkspace.owners(paging, search: "利用者204").total == 1, "Japanese name search")
        for offset in [-1,1,Int.max] { try reject("invalid offset", { _ = try NativePersonalWorkspace.owners(paging, offset: offset) }) }
        try reject("bounded search", { _ = try NativePersonalWorkspace.owners(paging, search: String(repeating: "x", count: 513)) })
        let partnerDB = try open("partner"), partner = try user(partnerDB, "本人partner", role: "partner")
        try check(try identity(partnerDB, partner["id"].string).role == "partner", "partner role kept without elevation")
        _ = NSApplication.shared
        var allowed = true, callbacks = 0, result: NativePersonalWorkspace.Selection?
        let window = NativePersonalOwnerWindow(db: paging, authorizeRead: { if !allowed { throw NativeDBError.conflict } })
        window.onFinished = { callbacks += 1; result = $0 }
        try check(window.testState.rows == 100 && window.testState.total == 205, "UI bounded page")
        try check(!window.testState.choose && window.testState.selected == -1, "UI never defaults to first user")
        window.testNext(); try check(window.testState.rows == 100 && window.testState.previous, "UI next page")
        window.testNext(); try check(window.testState.rows == 5 && !window.testState.next, "UI last page")
        window.testSearch("利用者204"); try check(window.testState.rows == 1 && !window.testState.previous, "UI search resets offset")
        window.testSelect(0); try check(window.testState.choose, "UI explicit row enables choice")
        allowed = false; window.testChoose()
        try check(callbacks == 0 && !window.testState.choose, "UI fresh authority rejection")
        allowed = true; window.testSearch("利用者204"); window.testSelect(0); window.testChoose()
        try check(callbacks == 1 && result != nil && paging.metadata("localActor") == nil, "UI selection callback writes nothing")
        window.testCancel(); try check(callbacks == 1, "UI terminal callback once")
        let cancelledWindow = NativePersonalOwnerWindow(db: paging, authorizeRead: {})
        cancelledWindow.onFinished = { callbacks += 1; result = $0 }; cancelledWindow.testCancel()
        try check(callbacks == 2 && result == nil, "UI cancellation returns nil")
        let deniedWindow = NativePersonalOwnerWindow(db: paging, authorizeRead: { throw NativeDBError.conflict })
        try check(deniedWindow.testState.rows == 0 && !deniedWindow.testState.choose && !deniedWindow.testState.next, "UI denied read exposes no users")
        deniedWindow.testCancel()
        try check(!window.window.isVisible && !cancelledWindow.window.isVisible && !deniedWindow.window.isVisible, "all offscreen UI windows closed")
        print("{\"checks\":\(checks),\"status\":\"passed\",\"visibleWindows\":0}")
    }
}
