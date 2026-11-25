import Foundation

@main enum NativeAresPluginTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) throws {
        checks += 1
        if !condition { throw NativePluginError(message: label) }
    }
    static func main() async {
        do { try await run() }
        catch { print(try! NativePluginJSON.text(["checks": checks, "error": error.localizedDescription])); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAresPlugin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        let service = CRMService(db: db, identity: identity), actor = NativePluginActor(type: .user, userId: identity.id, role: identity.role)
        let id = NativeAresPlugin.id, definition = NativeAresPlugin.definition()
        var requests = 0, hook: (() throws -> Void)?, responseCode = 200, response: NativePluginRecord = ["obchodniJmeno": "日本語の企業", "sidlo": ["nazevObce": "Praha"]]
        let host = try NativePluginHost(db: db, definitions: [definition], sendNotification: { _, _, _ in throw NativePluginError(message: "Unexpected notification") }, transport: { plugin, request in
            try check(plugin == id, "HTTP receives the calling plugin ID")
            requests += 1
            try hook?()
            return (try NativePluginJSON.data(response), HTTPURLResponse(url: request.url!, statusCode: responseCode, httpVersion: "HTTP/1.1", headerFields: [:])!)
        })
        host.attach()
        let registry = NativeCompanyRegistry(service: service, host: host)
        try check(try registry.countries().isEmpty, "uninstalled provider hidden")
        try check(try !registry.canValidateVat(), "uninstalled VAT hidden")
        try check(try await registry.lookup(country: "CZ", number: "19") == nil, "uninstalled lookup refused")
        try check(requests == 0, "uninstalled provider makes no request")
        try host.install(id, actor: actor, settings: [:], secrets: [:])
        try host.setEnabled(id, actor: actor, enabled: true)
        try check(try registry.countries() == ["CZ"], "enabled countries from real InstalledPlugin")
        try check(try registry.canValidateVat(), "enabled VAT from definition")
        let company = try await registry.lookup(country: " cz ", number: " 19 ")
        try check(company?["name"] as? String == "日本語の企業", "company data through real host/context")
        try check(company?["registrationNumber"] as? String == "00000019", "padded IČO")
        try check(company?["city"] as? String == "Praha", "address projection")
        response = ["valid": true]
        try check(try await registry.validateVat("DE123").rawValue == "valid", "VAT accepts other EU country")
        responseCode = 503
        try check(try await registry.validateVat("CZ19").rawValue == "unavailable", "network failure never reports invalid")
        try check(try db.page("PluginLog", fields: [], equal: ["pluginId": .text(id)]).total == 1, "provider error recorded once")
        responseCode = 200
        hook = { try host.setEnabled(id, actor: actor, enabled: false) }
        try check(try await registry.validateVat("CZ19").rawValue == "unavailable", "mid-flight disabling withholds result")
        let disabledRequests = requests
        try check(try await registry.validateVat("CZ19").rawValue == "noProvider", "disabled provider removed immediately")
        try check(requests == disabledRequests, "disabled provider no HTTP")
        hook = nil
        try host.setEnabled(id, actor: actor, enabled: true)
        var forbidden = definition; forbidden.permissions = []
        let forbiddenContext = try host.context(forbidden, actor: actor)
        do { _ = try await forbidden.companyRegistries[0].validateVat!("CZ19", forbiddenContext); throw NativePluginError(message: "Missing permission accepted") }
        catch { try check(error.localizedDescription.contains("lacks permission http"), "shared HTTP permission gate") }
        try check(requests == disabledRequests, "permission refusal before transport")
        hook = {
            let user = try db.get("Users", key: ["id": .text(identity.id)])!
            try db.update(user, changes: ["userStatus": .text("INACTIVE")], actor: identity.id)
        }
        try check(try await registry.validateVat("CZ19").rawValue == "unavailable", "mid-flight user deactivation withholds result")
        let inactiveRequests = requests
        do { _ = try registry.countries(); throw NativePluginError(message: "Inactive identity accepted") }
        catch { try check(error.localizedDescription.contains("管理者"), "fresh identity check before selection") }
        try check(requests == inactiveRequests, "inactive user no additional HTTP")
        let user = try db.get("Users", key: ["id": .text(identity.id)])!
        try db.update(user, changes: ["userStatus": .text("ACTIVE")], actor: identity.id); hook = nil
        let reopened = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        try check(try reopened.get("InstalledPlugin", key: ["id": .text(id)])?["status"] == .text("ENABLED"), "enabled configuration persists across database reopen")
        try check(try reopened.page("crm_Accounts", fields: []).total == 0, "lookup never saves a business record")
        print(try NativePluginJSON.text(["checks": checks, "requests": requests, "exit": 0]))
    }
}
