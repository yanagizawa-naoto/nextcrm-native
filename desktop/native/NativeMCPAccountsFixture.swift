import Foundation

/// Shared isolated test data. Never opens the installed app's database.
final class NativeMCPAccountsFixture {
    let root: URL, db: NativeDatabase, admin: CRMService, catalog: NativeMCPInputCatalog
    // Exact whole-second clock keeps expiry-equality tests independent of
    // ISO8601 millisecond rounding of the host wall clock.
    let reference: [String: Any], now = Date(timeIntervalSince1970: 1_795_046_400)
    var initial: [String: NativeRecord] = [:], credentials: [String: (raw: String, id: String)] = [:]
    init(resources: URL) throws {
        reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-accounts-reference.json"))) as! [String: Any]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MCPAccounts-" + UUID().uuidString)
        db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let actor = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        admin = CRMService(db: db, identity: actor)
        catalog = try NativeMCPInputCatalog(data: Data(contentsOf: resources.appendingPathComponent("MCPToolCatalog.json")))
        for user in reference["users"] as! [[String: Any]] {
            let row = try db.insert("Users", values: Self.values(user), actor: actor.id)
            let id = row["id"].string, raw = "nxtc__" + String(repeating: "a", count: 16) + id.replacingOccurrences(of: "-", with: "")
            let token = try db.insert("ApiToken", values: ["name": .text("isolated test"), "userId": .text(id), "tokenHash": .text(NativeAPITokens.hash(raw)), "tokenPrefix": .text("aaaaaaaa")], actor: actor.id)
            credentials[id] = (raw, token["id"].string)
        }
        for seed in reference["seeds"] as! [[String: Any]] {
            let row = try db.insert("crm_Accounts", values: Self.values(seed), actor: actor.id); initial[row["id"].string] = row
        }
        for watcher in reference["watchers"] as! [[String: Any]] { _ = try db.insert("AccountWatchers", values: Self.values(watcher), actor: actor.id) }
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    static func values(_ object: [String: Any]) -> [String: SQLValue] {
        object.mapValues { value in
            if value is NSNull { return .null }
            if let number = value as? NSNumber { return .integer(number.int64Value) }
            return .text(value as! String)
        }
    }
    func router(handlers: [String: NativeMCPRequestRouter.Handler] = NativeMCPAccounts.handlers) throws -> NativeMCPRequestRouter {
        try NativeMCPRequestRouter(catalog: catalog, db: db, handlers: handlers, requireFull: false, clock: { [now] in now })
    }
    func header(_ user: String) -> String { "Bearer " + credentials[user]!.raw }
    func resetAccounts() throws {
        let rows = try db.page("crm_Accounts", fields: [], includeDeleted: true).rows
        for item in rows {
            let id = item["id"].string
            guard let original = initial[id] else { try db.remove(item, actor: admin.identity.id); continue }
            let current = try db.get("crm_Accounts", key: ["id": .text(id)])!
            let fields = original.values.filter { !["id", "updatedAt"].contains($0.key) }
            if fields.contains(where: { current[$0.key] != $0.value }) { _ = try db.update(current, changes: fields, actor: admin.identity.id) }
        }
    }
    func change(_ model: String, id: String, values: [String: SQLValue]) throws {
        let row = try db.get(model, key: ["id": .text(id)])!; _ = try db.update(row, changes: values, actor: admin.identity.id)
    }
}
