import Foundation
import SQLite3

@main enum NativeCRMConfigurationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
    }
    static func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { checks += 1; return }
        throw NativeDBError.message("FAIL: accepted " + label)
    }
    struct Row: Decodable { let id: String, name: String; let v: Int; let stage_kind: String?; let order: Int?; let probability: Int? }
    struct Ref: Decodable { let id: String; let value: String?; let updatedAt: String; let deletedAt: String? }
    struct Listed: Decodable { let id: String, name: String; let usageCount: Int; let stageKind: String? }
    struct Expected: Decodable { let error: String?; let rows: [Row]; let refs: [Ref]; let list: [Listed]? }
    struct Case: Decodable {
        let label: String, kind: String, op: String, role: String, status: String, name: String, id: String
        let banned: Bool, stageProvided: Bool
        let stageKind: String?, replacementID: String?, failure: String?
        let seed: [Row]; let references: Int; let expected: Expected
    }
    struct Reference: Decodable { let old: String; let stageKinds: [String]; let cases: [Case] }
    static func id(_ value: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", value) }
    static func category(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("権限") || text.contains("この利用者") { return "denied" }
        if text.contains("名称") || text.contains("100文字") { return "name" }
        if text.contains("自動処理") { return "stage" }
        if text.contains("differ") { return "same" }
        if text.contains("support") { return "unsupported" }
        if text.contains("見つかりません") { return "missing" }
        if text.contains("UNIQUE") { return "unique" }
        if text.contains("FOREIGN KEY") { return "fk" }
        if text.contains("fixture-failure") { return "injected" }
        return text
    }
    static func main() {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/admin-crm-configuration-reference.json")))
            try check(reference.stageKinds == NativeCRMConfiguration.stageKinds, "source stage-kind enum")
            for item in reference.cases { try run(item, reference: reference, resources: resources) }
            try nativeGuards(resources: resources)
            print("{\"cases\":\(reference.cases.count),\"checks\":\(checks),\"exit\":0}")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func fixture(_ resources: URL, body: (NativeDatabase, OpaquePointer, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-AdminDictionary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        var connection: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("crm.sqlite").path, &connection) == SQLITE_OK, let connection else { throw NativeDBError.message("fixture connection") }
        defer { sqlite3_close(connection) }
        try body(db, connection, root)
    }
    static func sql(_ connection: OpaquePointer, _ text: String) throws {
        guard sqlite3_exec(connection, text, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(connection))) }
    }
    static func integer(_ connection: OpaquePointer, _ text: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, text, -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeDBError.message("fixture query") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NativeDBError.message("fixture query row") }
        return Int(sqlite3_column_int64(statement, 0))
    }
    static func user(_ db: NativeDatabase, role: String = "admin", status: String = "ACTIVE", banned: Bool = false) throws -> CRMService {
        let user = try db.insert("Users", values: ["id": .text(id(5000)), "name": .text("隔離管理者"), "email": .text("admin-fixture@example.invalid"), "role": .text(role), "userStatus": .text(status), "banned": .integer(banned ? 1 : 0)], actor: id(5000))
        return CRMService(db: db, identity: .init(id: user["id"].string, role: role, partnerAccountID: nil))
    }
    static func seedReference(_ db: NativeDatabase, kind: NativeCRMConfiguration.Kind, number: Int, old: String) throws -> NativeRecord {
        let reference = kind.reference
        var values: [String: SQLValue] = ["id": .text(id(1000 + number)), "v": .integer(0), reference.field: .text(id(1)), "updatedAt": .text(old), "deletedAt": number % 2 == 0 ? .null : .text(old)]
        switch reference.model {
        case "crm_Accounts": values["name"] = .text("別の担当者の企業")
        case "crm_Contacts": values["last_name"] = .text("連絡先")
        case "crm_Leads": values["lastName"] = .text("リード")
        default: values["name"] = .text("商談")
        }
        return try db.insert(reference.model, values: values, actor: id(5000))
    }
    static func run(_ item: Case, reference: Reference, resources: URL) throws {
        try fixture(resources) { db, connection, root in
            let service = try user(db, role: item.role, status: item.status, banned: item.banned)
            let kind = NativeCRMConfiguration.Kind(rawValue: item.kind)!, api = NativeCRMConfiguration(service: service)
            for row in item.seed {
                var values: [String: SQLValue] = ["id": .text(row.id), "name": .text(row.name), "v": .integer(Int64(row.v))]
                if kind == .salesStage { values["stage_kind"] = row.stage_kind.map(SQLValue.text) ?? .null }
                if kind == .salesStage || kind == .opportunityType { values["order"] = row.order.map { .integer(Int64($0)) } ?? .null }
                if kind == .salesStage { values["probability"] = row.probability.map { .integer(Int64($0)) } ?? .null }
                _ = try db.insert(kind.model, values: values, actor: service.identity.id)
            }
            for i in 0..<item.references { _ = try seedReference(db, kind: kind, number: i, old: reference.old) }
            if item.failure == "delete" { try sql(connection, "CREATE TRIGGER fixture_fail BEFORE DELETE ON \(kind.model) BEGIN SELECT RAISE(ABORT, 'fixture-failure'); END") }
            let beforeAudit = try db.auditCount(kind.model) + db.auditCount(kind.reference.model)
            var committed: [(String, String, String)] = []
            db.afterRecordWrite = { model, operation, _, _, _, actor in
                db.deferUntilTransactionEnds(onCommit: { committed.append((model, operation, actor)) }, onRollback: {})
            }
            defer { db.afterRecordWrite = nil }
            var error: String?, createdID: String?, listed: [NativeCRMConfiguration.Value] = []
            let stage: NativeCRMConfiguration.StageKindChange = item.stageProvided ? .set(item.stageKind) : .unchanged
            do {
                switch item.op {
                case "list":
                    var offset = 0
                    while true {
                        let page = try api.page(kind, offset: offset, limit: 37)
                        try check(page.values.count <= 37 && page.offset == offset, item.label + " bounded page")
                        listed += page.values; offset += page.values.count
                        if offset >= page.total || page.values.isEmpty { break }
                    }
                case "create": createdID = try api.create(kind, name: item.name, stageKind: stage)["id"].string
                case "update": _ = try api.update(kind, id: item.id, name: item.name, stageKind: stage)
                default: try api.delete(kind, id: item.id, replacementID: item.replacementID)
                }
            } catch let caught { error = category(caught) }
            try check(error == item.expected.error, item.label + " outcome \(error ?? "success") vs \(item.expected.error ?? "success")")
            let model = try db.schema.model(kind.model)
            var nativeRows: [NativeRecord] = [], offset = 0
            while true {
                let page = try db.mcpPage(kind.model, fields: model.fields.map(\.name), filter: .all, limit: 100, offset: offset, order: [("id", false)], includeDeleted: true)
                nativeRows += page.rows; offset += page.rows.count
                if offset >= page.total || page.rows.isEmpty { break }
            }
            try check(nativeRows.count == item.expected.rows.count, item.label + " dictionary count")
            for expected in item.expected.rows {
                let id = expected.id == "created" ? createdID ?? "absent" : expected.id
                guard let actual = nativeRows.first(where: { $0["id"].string == id }) else { throw NativeDBError.message("FAIL: \(item.label) missing dictionary \(id)") }
                try check(actual["name"] == .text(expected.name), item.label + " name/trim")
                try check(actual["v"] == .integer(Int64(expected.v)), item.label + " v unchanged")
                try check(actual["stage_kind"] == (expected.stage_kind.map(SQLValue.text) ?? .null), item.label + " stage kind")
                try check(actual["order"] == (expected.order.map { .integer(Int64($0)) } ?? .null), item.label + " order preserved")
                try check(actual["probability"] == (expected.probability.map { .integer(Int64($0)) } ?? .null), item.label + " probability preserved")
            }
            for expected in item.expected.refs {
                guard let actual = try db.get(kind.reference.model, key: ["id": .text(expected.id)]) else { throw NativeDBError.message("FAIL: missing reference") }
                try check(actual[kind.reference.field] == (expected.value.map(SQLValue.text) ?? .null), item.label + " foreign key")
                try check((actual["updatedAt"].string == reference.old ? "original" : "changed") == expected.updatedAt, item.label + " business timestamp")
                try check(actual["deletedAt"] == (expected.deletedAt.map(SQLValue.text) ?? .null), item.label + " trash included/preserved")
                try check(actual["updatedBy"] == .null, item.label + " no invented updater")
                let changed = item.expected.error == nil && item.op == "delete"
                try check(actual.revision == (changed ? 2 : 1), item.label + " revision fences retained editor")
            }
            if let expected = item.expected.list {
                try check(listed.count == expected.count, item.label + " source list length")
                for (actual, expected) in zip(listed, expected) {
                    try check(actual.id == expected.id && actual.name == expected.name, item.label + " source ordering")
                    try check(actual.usageCount == expected.usageCount, item.label + " count including trash")
                    try check(actual.stageKind == expected.stageKind, item.label + " list stage")
                }
            }
            let saves = error == nil && item.op != "list" ? 1 + (item.op == "delete" && !(item.replacementID ?? "").isEmpty ? item.references : 0) : 0
            try check(try db.auditCount(kind.model) + db.auditCount(kind.reference.model) - beforeAudit == saves, item.label + " native audit atomicity")
            try check(committed.count == saves && committed.allSatisfy { $0.2 == service.identity.id }, item.label + " committed hook actor and count")
            try check(try integer(connection, "SELECT count(*) FROM native_outbox") == 0, item.label + " no invented business jobs")
            // Persistence must not depend on a retained service object.
            let reopened = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
            try check(try reopened.mcpPage(kind.model, fields: [], filter: .all, limit: 1, offset: 0, order: [("id", false)]).total == item.expected.rows.count, item.label + " reopen")
        }
    }
    static func nativeGuards(resources: URL) throws {
        try fixture(resources) { db, connection, _ in
            let service = try user(db), api = NativeCRMConfiguration(service: service)
            let row = try api.create(.salesStage, name: "段階", stageKind: .set("care"))
            _ = try api.update(.salesStage, id: row["id"].string, name: "最新", expectedRevision: row.revision)
            try rejects("stale editor update") { _ = try api.update(.salesStage, id: row["id"].string, name: "古い", expectedRevision: row.revision) }
            try rejects("stale editor delete") { try api.delete(.salesStage, id: row["id"].string, expectedRevision: row.revision) }
            try rejects("invalid pagination") { _ = try api.page(.industry, offset: -1) }
            try rejects("overlarge pagination") { _ = try api.page(.industry, limit: 101) }
            let admin = try db.get("Users", key: ["id": .text(service.identity.id)])!
            try rejects("DB helper allowlist") { try db.deleteCRMConfiguration(admin, actor: service.identity.id) }
            let dict = try db.insert("crm_Lead_Statuses", values: ["id": .text(id(1)), "name": .text("元")], actor: service.identity.id)
            let child = try seedReference(db, kind: .leadStatus, number: 0, old: "2025-01-02T03:04:05.000Z")
            try sql(connection, "CREATE TRIGGER fixture_audit BEFORE INSERT ON native_audit WHEN NEW.model='crm_Lead_Statuses' BEGIN SELECT RAISE(ABORT,'fixture-audit'); END")
            try rejects("mandatory audit rollback") { try api.delete(.leadStatus, id: dict["id"].string) }
            try check(try db.get("crm_Leads", key: ["id": child["id"]])?.revision == child.revision, "cascade revision rolled back after audit failure")
            try check(try db.get("crm_Leads", key: ["id": child["id"]])?["lead_status_id"] == dict["id"], "cascade FK rolled back after audit failure")
            try sql(connection, "DROP TRIGGER fixture_audit")
            // A blocked before-hook must also restore the silently nulled child.
            db.beforeRecordWrite = { model, operation, _, changes, _ in
                if model == "crm_Lead_Statuses" && operation == "delete" { throw NativeDBError.message("fixture-rule") }; return changes
            }
            try rejects("blocking rule rollback") { try api.delete(.leadStatus, id: dict["id"].string) }
            db.beforeRecordWrite = nil
            try check(try db.get("crm_Leads", key: ["id": child["id"]])?["lead_status_id"] == dict["id"], "blocking rule restores cascade")
            _ = try db.update(admin, changes: ["role": .text("manager")], actor: service.identity.id)
            for operation in ["list", "create", "update", "delete"] {
                try rejects("fresh role " + operation) {
                    switch operation {
                    case "list": _ = try api.page(.salesStage)
                    case "create": _ = try api.create(.salesStage, name: "不可")
                    case "update": _ = try api.update(.salesStage, id: row["id"].string, name: "不可")
                    default: try api.delete(.salesStage, id: row["id"].string)
                    }
                }
            }
        }
    }
}
