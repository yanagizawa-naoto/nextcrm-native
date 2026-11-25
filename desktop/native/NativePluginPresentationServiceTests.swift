import Foundation

@main enum NativePluginPresentationServiceTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; if try !value() { throw NativePluginError(message: message) }
    }
    static func denied(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks += 1; return }
        throw NativePluginError(message: "accepted: " + message)
    }
    static func main() {
        do { try run(); print("{\"exit\":0,\"checks\":\(checks)}") }
        catch { print(try! NativePluginJSON.text(["exit": 1, "checks": checks, "error": error.localizedDescription])); exit(1) }
    }
    static func run() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativePluginRoutes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db: db, identity: identity)
        func user(_ role: String) throws -> CRMService {
            let row = try db.insert("Users", values: ["name": .text(role), "email": .text(UUID().uuidString + "@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE"), "v": .integer(0)], actor: identity.id)
            return CRMService(db: db, identity: .init(id: row["id"].string, role: role, partnerAccountID: nil))
        }
        let ordinary = try user("user"), manager = try user("manager")
        let account = try db.insert("crm_Accounts", values: ["name": .text("連携画面の取引先"), "company_id": .text("12345678"), "assigned_to": .text(ordinary.identity.id), "createdBy": .text(ordinary.identity.id), "v": .integer(0)], actor: identity.id)
        let hidden = try db.insert("crm_Accounts", values: ["name": .text("別の担当者の取引先"), "assigned_to": .text(manager.identity.id), "createdBy": .text(manager.identity.id), "v": .integer(0)], actor: identity.id)
        let product = try db.insert("crm_Products", values: ["name": .text("商品"), "type": .text("PRODUCT"), "status": .text("ACTIVE"), "unit_price": .text("100"), "currency": .text("JPY"), "source": .text("EXTERNAL"), "externalRef": .text("700")], actor: identity.id)
        let series = try db.insert("NumberSeries", values: ["name": .text("連携検証"), "scope": .text("order"), "template": .text("QA-{####}")], actor: identity.id)
        let order = try db.insert("crm_Orders", values: ["number": .text("QA-1"), "seriesId": series["id"], "accountId": account["id"], "ownerId": .text(ordinary.identity.id), "currency": .text("JPY"), "status": .text("DRAFT"), "orderDate": .text("2026-11-01T00:00:00.000Z")], actor: identity.id)
        let definitions = [NativeAccountProtection.definition(), NativeOdooPlugin.definition, NativeOXOConnector.definition()]
        var secretReads = 0, externalCalls = 0
        let host = try NativePluginHost(db: db, definitions: definitions, secretStore: .init(read: { _ in secretReads += 1; throw NativeDBError.conflict }, write: { _,_ in throw NativeDBError.conflict }, remove: { _ in }), sendNotification: { _,_,_ in externalCalls += 1; throw NativeDBError.conflict }, transport: { _,_ in externalCalls += 1; throw NativeDBError.conflict })
        let api = NativePluginPresentationService(service: admin, host: host)
        let userAPI = NativePluginPresentationService(service: ordinary, host: host)
        let managerAPI = NativePluginPresentationService(service: manager, host: host)
        let location = NativePluginLocation.account(account["id"].string)
        try check(try api.choices(location).isEmpty && api.pages().isEmpty, "no routes before installation")
        for definition in definitions {
            let settings: [String: Any] = definition.id == "account-protection" ? [:] : ["url": "https://erp.example.invalid", "database": "qa", "timeZone": "Asia/Tokyo", "currency": "JPY"]
            try db.insert("InstalledPlugin", values: ["id": .text(definition.id), "version": .text(definition.version), "status": .text("ENABLED"), "settings": .text(try NativePluginJSON.text(definition.settings.parse(settings))), "secrets": .text("opaque-reference")], actor: identity.id)
        }
        let accountChoices = try api.choices(location)
        for plugin in ["odoo-connector", "oxo-erp-connector"] {
            let store = NativePluginStore(db: db, pluginId: plugin)
            try store.set("account:" + account["id"].string, ["partnerId": 50, "customerId": 50])
            try store.set("product:" + (plugin == "odoo-connector" ? "700" : product["id"].string), ["productId": product["id"].string, "oxoId": 700, "ref": "QA-700"])
            try store.set("order:" + order["id"].string, ["odooId": 900, "oxoId": 900, "name": "S00900", "number": "S00900", "state": "draft"])
        }
        try check(accountChoices.count == 3 && Set(accountChoices.map(\.pluginID)).count == 3, "account tab and panel merge into one route per plugin")
        try check(try userAPI.choices(location).count == 3, "owned account routes available to ordinary users")
        try denied("primary record ownership") { _ = try userAPI.choices(.account(hidden["id"].string)) }
        for location in [NativePluginLocation.product(product["id"].string), .order(order["id"].string)] {
            let choices = try api.choices(location)
            try check(Set(choices.map(\.pluginID)) == ["odoo-connector", "oxo-erp-connector"], "product and order expose only implemented slots")
            for choice in choices { try check(try api.build(choice) != nil, "native projection dispatch for " + choice.pluginID) }
        }
        for choice in accountChoices { try check(try api.build(choice) != nil, "account projection dispatch for " + choice.pluginID) }
        let pages = try api.pages()
        try check(pages.count == 3 && Set(pages.map(\.pluginID)).count == 3, "duplicate page identifiers remain plugin scoped")
        try check(pages.allSatisfy { !$0.title.contains("needsOwner.") && !$0.title.contains("expiring.") }, "navigation labels are translated")
        try check(try userAPI.pages().isEmpty && managerAPI.pages().count == 3, "page menu respects slot roles")
        for choice in pages {
            try check(try managerAPI.build(choice) != nil, "manager can open authorized page")
            try denied("ordinary role forged page") { try userAPI.authorize(choice) }
        }
        for choice in try api.choices(.admin) { try check(try api.build(choice) != nil, "admin status projection") }
        try denied("manager admin status") { _ = try managerAPI.choices(.admin) }
        try denied("unsupported route") { try api.authorize(.init(pluginID: "ares", title: "", location: .admin)) }
        try denied("unknown page path") { try api.authorize(.init(pluginID: "odoo-connector", title: "", location: .page("unknown"))) }
        let target = NativePluginPresentation.RecordTarget(model: "crm_Accounts", id: account["id"].string)
        try check(try userAPI.record(target)["id"] == account["id"], "navigation resolves current full record")
        try denied("navigation to unrelated account") { _ = try userAPI.record(.init(model: "crm_Accounts", id: hidden["id"].string)) }
        try denied("navigation model allow-list") { _ = try api.record(.init(model: "Users", id: identity.id)) }
        try db.setDeleted(account, deleted: true, actor: identity.id)
        try denied("deleted navigation destination") { _ = try api.record(target) }
        let installed = try db.get("InstalledPlugin", key: ["id": .text("odoo-connector")])!
        try db.update(installed, changes: ["status": .text("DISABLED")], actor: identity.id)
        try check(try api.pages().count == 2, "disabled plugin removed from navigation")
        try denied("retained menu route after disable") { try api.authorize(pages.first { $0.pluginID == "odoo-connector" }!) }
        let managerRow = try db.get("Users", key: ["id": .text(manager.identity.id)])!
        try db.update(managerRow, changes: ["role": .text("user")], actor: identity.id)
        try denied("current database role invalidates cached identity") { _ = try managerAPI.pages() }
        try denied("retained page after role loss") { try managerAPI.authorize(pages.first { $0.pluginID == "account-protection" }!) }
        let current = try db.get("Users", key: ["id": .text(manager.identity.id)])!
        try db.update(current, changes: ["userStatus": .text("INACTIVE")], actor: identity.id)
        try denied("inactive identity") { _ = try managerAPI.pages() }
        try check(secretReads == 0 && externalCalls == 0, "menu and projections never load credentials or contact providers")
    }
}
