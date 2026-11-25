import Foundation

final class NativePluginPresentationService {
    struct Choice { let pluginID: String, title: String, location: NativePluginLocation }
    let service: CRMService, host: NativePluginHost
    init(service: CRMService, host: NativePluginHost) { precondition(service.db === host.db); self.service = service; self.host = host }
    private static let supported: Set<String> = ["account-protection", "odoo-connector", "oxo-erp-connector"]
    static func location(model: String, id: String) -> NativePluginLocation? {
        switch model { case "crm_Accounts": return .account(id); case "crm_Products": return .product(id); case "crm_Orders": return .order(id); default: return nil }
    }
    private func primaryAccess(_ location: NativePluginLocation) throws {
        try service.authenticated()
        switch location {
        case .admin: guard service.identity.role == "admin" else { throw NativeDBError.message("連携の管理情報は管理者のみ確認できます。") }
        case let .account(id): try service.assertAccess("crm_Accounts", id: id)
        case let .product(id): try service.assertAccess("crm_Products", id: id)
        case let .order(id): try service.assertAccess("crm_Orders", id: id)
        case .page: break
        }
    }
    private func matches(_ slot: NativePluginSlot, _ location: NativePluginLocation) -> Bool {
        guard slot.roles.contains(service.identity.role) else { return false }
        switch location {
        case .admin: return slot.kind == .adminSection
        case .account: return slot.kind == .accountPanel || slot.kind == .accountTab
        case .product: return slot.kind == .productPanel
        case .order: return slot.kind == .orderPanel
        case let .page(path): return slot.kind == .page && slot.id == path
        }
    }
    func choices(_ location: NativePluginLocation) throws -> [Choice] {
        try service.db.transaction {
            try primaryAccess(location)
            return try host.enabled().filter { Self.supported.contains($0.id) && $0.slots.contains { matches($0, location) } }.map { .init(pluginID: $0.id, title: $0.name, location: location) }
        }
    }
    func pages() throws -> [Choice] {
        try service.db.transaction {
            try service.authenticated()
            return try host.enabled().filter { Self.supported.contains($0.id) }.flatMap { definition in
                definition.slots.filter { $0.kind == .page && $0.roles.contains(service.identity.role) }.map { slot in
                    let title = host.translate(definition.id, slot.nav ?? slot.title ?? slot.id, nil, "ja")
                    return Choice(pluginID: definition.id, title: definition.name + "：" + title, location: .page(slot.id))
                }
            }
        }
    }
    func authorize(_ choice: Choice) throws {
        try service.db.transaction {
            try primaryAccess(choice.location)
            guard Self.supported.contains(choice.pluginID), let definition = host.definition(choice.pluginID),
                  try host.state(choice.pluginID)?["status"] == .text("ENABLED"), definition.slots.contains(where: { matches($0, choice.location) }) else {
                throw NativeDBError.message("この連携は現在利用できないか、表示する権限がありません。")
            }
        }
    }
    func build(_ choice: Choice) throws -> NativePluginPresentation? {
        try service.db.transaction {
            try authorize(choice)
            switch choice.pluginID {
            case "account-protection": return try NativeAccountProtectionPresentation.build(service: service, host: host, location: choice.location)
            case "odoo-connector": return try NativeOdooPresentation.build(service: service, host: host, location: choice.location)
            case "oxo-erp-connector": return try NativeOXOPresentation.build(service: service, host: host, location: choice.location)
            default: return nil
            }
        }
    }
    func record(_ target: NativePluginPresentation.RecordTarget) throws -> NativeRecord {
        try service.db.transaction {
            try service.authenticated()
            guard ["crm_Accounts", "crm_Contacts", "crm_Orders", "crm_Products", "Invoices"].contains(target.model) else { throw NativeDBError.message("この情報は開けません。") }
            try service.assertAccess(target.model, id: target.id)
            guard let row = try service.db.get(target.model, key: ["id": .text(target.id)]) else { throw NativeDBError.conflict }
            return try service.fullRecord(row)
        }
    }
}
