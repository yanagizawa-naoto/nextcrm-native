import Foundation

/// Presentation boundary: no secret values are returned to the window.
final class NativePluginsAdmin {
    struct Item {
        let id: String, name: String, description: String, status: String
    }
    struct Detail {
        let item: Item, definition: NativePluginDefinition?
        let installedVersion: String?, revision: Int64?
        let settings: NativePluginRecord, secretFlags: [String: Bool]
        let entries: Int, records: Int, logLines: Int
        var installed: Bool { revision != nil }
        var enabled: Bool { item.status == "ENABLED" }
    }
    struct LogEntry { let date: String, level: String, message: String }
    let service: CRMService, host: NativePluginHost
    private let wake: () async -> Void
    let allowsActions: Bool
    init(service: CRMService, host: NativePluginHost, wake: @escaping () async -> Void = {}, allowsActions: Bool = true) {
        precondition(service.db === host.db); self.service = service; self.host = host; self.wake = wake; self.allowsActions = allowsActions
    }
    private var actor: NativePluginActor { .init(type: .user, userId: service.identity.id, role: service.identity.role) }
    func requireAdmin() throws {
        try service.authenticated()
        guard service.identity.role == "admin" else { throw NativePluginError(message: "連携の設定には管理者権限が必要です。") }
    }
    func list() throws -> [Item] {
        try service.db.transaction {
            try requireAdmin()
            return try host.list().map { row in
                Item(id: row["id"] as! String, name: row["name"] as! String, description: row["description"] as? String ?? "", status: row["status"] as! String)
            }
        }
    }
    func detail(_ id: String) throws -> Detail {
        let initial = try service.db.transaction { () -> (Item, NativeRecord?, NativePluginDefinition?, NativePluginRecord, NativePluginRecord) in
            try requireAdmin()
            guard let item = try list().first(where: { $0.id == id }) else { throw NativePluginError(message: "連携が見つかりません。") }
            let state = try host.state(id), definition = host.definition(id)
            let stored = try state.map { try NativePluginJSON.parse($0["settings"].string) } ?? NativePluginRecord()
            let values = definition?.settings.stored(stored, warn: { _, _ in }) ?? (stored as? NativePluginRecord ?? [:])
            let summary = state == nil ? NativePluginRecord() : try host.summary(id)
            return (item, state, definition, values, summary)
        }
        var flags: [String: Bool] = [:]
        if let state = initial.1, state["secrets"] != .null {
            let secrets = (try? host.secretStore.read(state["secrets"].string)) ?? [:]
            flags = secrets.mapValues { !($0 is NSNull) && ($0 as? String) != "" }
        }
        try service.db.transaction {
            try requireAdmin()
            guard try host.state(id)?.revision == initial.1?.revision else { throw NativeDBError.conflict }
        }
        return Detail(item: initial.0, definition: initial.2, installedVersion: initial.1?["version"].string, revision: initial.1?.revision, settings: initial.3, secretFlags: flags,
                      entries: initial.4["entries"] as? Int ?? 0, records: initial.4["records"] as? Int ?? 0, logLines: initial.4["logLines"] as? Int ?? 0)
    }
    func save(_ detail: Detail, settings: NativePluginRecord, secrets: NativePluginRecord, granted: Bool) async throws {
        try requireAdmin()
        if let revision = detail.revision {
            try host.saveSettings(detail.item.id, actor: actor, settings: settings, secrets: secrets, expectedRevision: revision)
        } else {
            guard granted else { throw NativePluginError(message: "連携が使用する権限を確認してください。") }
            try host.install(detail.item.id, actor: actor, settings: settings, secrets: secrets)
        }
        if allowsActions { await wake() }
    }
    func setEnabled(_ detail: Detail, enabled: Bool) async throws {
        try requireAdmin(); try host.setEnabled(detail.item.id, actor: actor, enabled: enabled); if allowsActions { await wake() }
    }
    func uninstall(_ detail: Detail) async throws {
        try requireAdmin(); try await host.uninstall(detail.item.id, actor: actor); if allowsActions { await wake() }
    }
    func action(_ detail: Detail, id: String) async throws -> String {
        func validate(_ pluginId: String) throws {
            guard allowsActions else { throw NativePluginError(message: "連携の実行は再開の確認待ちです。設定だけを変更できます。") }
            try service.db.transaction {
                try requireAdmin()
                guard pluginId == detail.item.id, let state = try host.state(pluginId),
                      state.revision == detail.revision, state["status"] == .text("ENABLED") else {
                    throw NativePluginError(message: "連携の設定や状態が変更されています。再読み込みしてください。")
                }
            }
        }
        try validate(detail.item.id)
        let result = try await NativePluginExecutionScope.$validate.withValue(validate) {
            try await host.adminAction(detail.item.id, id, input: [:], actor: actor)
        }
        try validate(detail.item.id)
        if allowsActions { await wake() }
        return result as? String ?? "操作を実行しました。"
    }
    func export(_ detail: Detail, to destination: URL) throws {
        try requireAdmin(); try host.exportFile(detail.item.id, to: destination, actor: actor)
    }
    func logs(_ id: String, offset: Int) throws -> (rows: [LogEntry], total: Int) {
        try service.db.transaction {
            try requireAdmin()
            let page = try service.db.mcpPage("PluginLog", fields: ["createdAt", "level", "message"], filter: .equal("pluginId", .text(id)), limit: 100, offset: offset, order: [("createdAt", true), ("id", true)], includeDeleted: true)
            return (page.rows.map { .init(date: $0["createdAt"].string, level: $0["level"].string, message: $0["message"].string) }, page.total)
        }
    }
    static func status(_ value: String) -> String {
        ["ENABLED": "有効", "DISABLED": "無効", "NOT_INSTALLED": "未導入", "MISSING": "連携機能が見つかりません"][value] ?? "状態を確認できません"
    }
    static func label(_ key: String) -> String {
        ["url": "接続先URL", "database": "データベース名", "syncMinutes": "同期間隔（分）", "defaultCountry": "既定の国コード", "currency": "通貨コード", "dryRun": "試行モード（変更を適用しない）", "priceLists": "取り込む価格表のID", "sendOrders": "受注を連携先へ送信", "fillOwners": "担当者を補完", "timeZone": "タイムゾーン", "apiKey": "APIキー", "protectionDays": "担当保護の期間（日）", "contactDays": "連絡が必要な期限（日）", "contactTypes": "保護条件を満たす活動", "warnDays": "期限前の通知（日）", "requireNumber": "法人番号・登録番号を必須にする", "orderMonths": "受注による保護期間（月）"][key] ?? key
    }
    static func hint(_ key: String) -> String? {
        ["priceLists": "複数のIDはカンマで区切ってください。", "defaultCountry": "2文字の国コードを入力します（例：JP、CZ）。", "contactTypes": "call（電話）、meeting（会議）、note（メモ）、email（メール）、visit（訪問）をカンマで区切ります。", "timeZone": "例：Asia/Tokyo、UTC", "dryRun": "連携先のデータを確認し、実際の取り込みや更新を行いません。", "sendOrders": "承認済みの受注を外部の連携先へ送信します。", "orderMonths": "0にすると、受注による保護を使用しません。"][key]
    }
    static func permission(_ value: String) -> String {
        let parts = value.split(separator: ":").map(String.init)
        if parts.count == 2 {
            let nouns = ["accounts": "取引先", "contacts": "連絡先", "leads": "リード", "opportunities": "商談", "orders": "受注", "activities": "活動", "users": "利用者", "products": "商品", "priceLists": "価格表"]
            return (nouns[parts[0]] ?? parts[0]) + (parts[1] == "write" ? "の更新" : "の読み取り")
        }
        return ["notify": "通知メールの送信", "http": "外部サービスとの通信"][value] ?? value
    }
    static func settings(_ fields: [NativePluginSettingsField], values: [String: String], flags: [String: Bool]) throws -> NativePluginRecord {
        var result: NativePluginRecord = [:]
        for field in fields {
            if field.kind == .boolean { result[field.key] = flags[field.key] ?? false; continue }
            let text = values[field.key] ?? ""
            if text.isEmpty && (!field.required || field.kind == .number) { continue }
            if field.kind == .number {
                guard let value = Double(text), value.isFinite else { throw NativePluginError(message: label(field.key) + "に正しい数値を入力してください。") }
                result[field.key] = value
            } else { result[field.key] = text }
        }
        return result
    }
    static func errorMessage(_ error: Error) -> String {
        let message = error.localizedDescription
        for prefix in ["Invalid setting: ", "Required setting missing: "] where message.hasPrefix(prefix) {
            return label(String(message.dropFirst(prefix.count))) + "の入力内容を確認してください。"
        }
        if message == "Plugin already installed" { return "この連携はすでに導入されています。再読み込みしてください。" }
        if message == "Plugin not installed" || message == "Plugin not found" || message == "Not found" { return "連携が見つからないか、現在は利用できません。" }
        if message == "Plugin installation could not be started; please try again." { return "連携の導入を開始できませんでした。もう一度お試しください。" }
        if message.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) { return message }
        return "操作できませんでした。入力内容と接続設定を確認してください。"
    }
}
