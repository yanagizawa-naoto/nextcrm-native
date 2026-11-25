import Foundation

/// The app's server actions, not BetterAuth's deliberately disabled admin API.
/// All public records use an allow-list; credential/session values never leave it.
struct NativeUserAdministrationRow {
    let values: [String: SQLValue]
    subscript(_ field: String) -> SQLValue { values[field] ?? .null }
    var id: String { self["id"].string }
    fileprivate init(_ record: NativeRecord) {
        values = Dictionary(uniqueKeysWithValues: NativeUserAdministration.fields.map { ($0, record[$0]) })
    }
}

enum NativeUserAdministrationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

final class NativeUserAdministration {
    let service: CRMService
    private let clock: () -> Date
    private let mail: NativeUserAdministrationMailGateway
    static let fields = ["id", "name", "email", "username", "account_name", "avatar", "role", "userLanguage", "userStatus", "lastLoginAt", "created_on", "updated_at", "partnerAccountId"]
    init(service: CRMService, clock: @escaping () -> Date = Date.init, mail: NativeUserAdministrationMailGateway = .unconfigured) {
        self.service = service; self.clock = clock; self.mail = mail
    }
    private func authenticated(partner: Bool = false) throws {
        do { try service.authenticated() } catch { throw NativeUserAdministrationError.message("ログインが必要です") }
        guard partner || service.identity.role != "partner" else { throw NativeUserAdministrationError.message("ログインが必要です") }
    }
    private func admin() throws {
        try authenticated()
        guard service.identity.role == "admin" else { throw NativeUserAdministrationError.message("操作する権限がありません") }
    }
    private func identifier(_ id: String) throws {
        guard !id.isEmpty else { throw NativeUserAdministrationError.message("ユーザーIDを入力してください") }
    }
    private func user(_ id: String) throws -> NativeRecord {
        guard let user = try service.db.get("Users", key: ["id": .text(id)]) else { throw NativeUserAdministrationError.message("ユーザーが見つかりません") }
        return user
    }
    private func mutation<T>(_ failure: String, _ action: () throws -> T) throws -> T {
        do { return try action() }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeUserAdministrationError.message(failure) }
    }
    /// Bounded equivalent of getUsers. Like the source, non-admin internal users
    /// receive an empty directory. Detail and mutations require admin authority.
    func list(search: String = "", role: String? = nil, status: String? = nil, offset: Int = 0) throws -> (rows: [NativeUserAdministrationRow], total: Int) {
        try service.db.transaction {
            try authenticated()
            guard service.identity.role == "admin" else { return ([], 0) }
            var equal: [String: SQLValue] = [:]
            if let role { equal["role"] = .text(role) }
            if let status { equal["userStatus"] = .text(status) }
            // Search only displayable columns: no password/credential match side channel.
            let filter: RecordFilter = .every(equal.map { .equal($0.key, $0.value) })
            let page = try service.db.mcpPage("Users", fields: Self.fields, filter: filter,
                searchFields: ["name", "email", "username", "account_name"], query: search.isEmpty ? nil : search,
                limit: 100, offset: max(0, offset), order: [("created_on", true), ("id", false)])
            return (page.rows.map(NativeUserAdministrationRow.init), page.total)
        }
    }
    func detail(_ id: String) throws -> NativeUserAdministrationRow {
        try service.db.transaction { try admin(); try identifier(id); return NativeUserAdministrationRow(try user(id)) }
    }
    func currentProfile() throws -> NativeUserAdministrationRow {
        try service.db.transaction { try authenticated(); return NativeUserAdministrationRow(try user(service.identity.id)) }
    }
    func setRole(_ id: String, role: String) throws -> NativeUserAdministrationRow {
        try service.db.transaction {
            try admin(); try identifier(id)
            guard ["admin", "manager", "user", "partner"].contains(role) else { throw NativeUserAdministrationError.message("役割が正しくありません") }
            guard id != service.identity.id || role == "admin" else { throw NativeUserAdministrationError.message("自分自身の管理者権限は解除できません") }
            return try mutation("ユーザーの役割を更新できませんでした") {
                let before = try user(id); var changes: [String: SQLValue] = ["role": .text(role)]
                if before["role"] == .text("partner") && role != "partner" {
                    changes["partnerAccountId"] = .null
                    // Changed rows leave this predicate, so page zero cannot skip
                    // the 101st account. Deleted accounts also lose partner links.
                    while true {
                        let rows = try service.db.page("crm_Accounts", fields: [], equal: ["partnerUserId": .text(id)], includeDeleted: true).rows
                        if rows.isEmpty { break }
                        for row in rows { try Task.checkCancellation(); _ = try service.db.update(row, changes: ["partnerUserId": .null, "updatedBy": .text(service.identity.id)], actor: service.identity.id, action: "user_role_partner_clear") }
                    }
                }
                return NativeUserAdministrationRow(try service.db.update(before, changes: changes, actor: service.identity.id, action: "user_role"))
            }
        }
    }
    func setPartnerAccount(_ id: String, accountID: String?) throws -> NativeUserAdministrationRow {
        try service.db.transaction {
            try admin(); try identifier(id); let before = try user(id)
            guard before["role"] == .text("partner") else { throw NativeUserAdministrationError.message("User is not a partner") }
            if let accountID, !accountID.isEmpty {
                guard let account = try service.db.get("crm_Accounts", key: ["id": .text(accountID)]), account["deletedAt"] == .null else { throw NativeUserAdministrationError.message("取引先が見つかりません") }
                try service.assertAccess("crm_Accounts", id: accountID)
            }
            return try mutation("パートナーの取引先を更新できませんでした") {
                NativeUserAdministrationRow(try service.db.update(before, changes: ["partnerAccountId": accountID.map(SQLValue.text) ?? .null], actor: service.identity.id, action: "user_partner_account"))
            }
        }
    }
    func deactivate(_ id: String) throws -> NativeUserAdministrationRow {
        try service.db.transaction {
            try admin(); try identifier(id)
            guard id != service.identity.id else { throw NativeUserAdministrationError.message("自分自身を無効にすることはできません") }
            return try mutation("ユーザーを無効化できませんでした") {
                try NativeAPITokens(service: service, clock: clock).deactivateUser(id: id)
                return NativeUserAdministrationRow(try user(id))
            }
        }
    }
    func revokeAPITokens(_ id: String) throws -> Int {
        try service.db.transaction {
            try admin(); try identifier(id)
            return try mutation("APIトークンを失効できませんでした") { try NativeAPITokens(service: service, clock: clock).revokeAll(userID: id) }
        }
    }
    func delete(_ id: String) throws -> NativeUserAdministrationRow {
        // The outer transaction is inside mutation so deferred FK failures also
        // become the source action's safe error, and all nullifications roll back.
        try service.db.transaction { try admin(); try identifier(id)
            guard id != service.identity.id else { throw NativeUserAdministrationError.message("自分自身を削除することはできません") }
        }
        return try mutation("ユーザーを削除できませんでした") {
            try service.db.transaction {
                try admin(); let before = try user(id)
                try NativeUserCredentialCleanup.holdPersonalReferences(db: service.db, userID: id, actorID: service.identity.id, now: clock())
                try service.db.deleteAdministrativeUser(before, actor: service.identity.id)
                return NativeUserAdministrationRow(before)
            }
        }
    }
    func updateProfile(_ id: String, name: String, username: String, accountName: String) throws -> NativeUserAdministrationRow {
        try service.db.transaction {
            try authenticated(); try identifier(id)
            guard id == service.identity.id || service.identity.role == "admin" else { throw NativeUserAdministrationError.message("操作する権限がありません") }
            return try mutation("プロフィールを更新できませんでした") {
                NativeUserAdministrationRow(try service.db.update(try user(id), changes: ["name": .text(name), "username": .text(username), "account_name": .text(accountName)], actor: service.identity.id, action: "user_profile"))
            }
        }
    }
    func setLanguage(_ id: String, language: String) throws -> String {
        try service.db.transaction {
            try authenticated(partner: true); try identifier(id)
            guard !language.isEmpty else { throw NativeUserAdministrationError.message("言語を入力してください") }
            guard id == service.identity.id || service.identity.role == "admin" else { throw NativeUserAdministrationError.message("操作する権限がありません") }
            return try mutation("言語を設定できませんでした") {
                _ = try service.db.update(try user(id), changes: ["userLanguage": .text(language)], actor: service.identity.id, action: "user_language"); return language
            }
        }
    }
    func setProfilePhoto(_ avatar: String) throws {
        try service.db.transaction {
            try authenticated()
            guard !avatar.isEmpty else { throw NativeUserAdministrationError.message("No avatar provided") }
            // This is only the source's metadata action. Image validation/file
            // storage belongs to the separate upload boundary, not this setter.
            _ = try service.db.update(try user(service.identity.id), changes: ["avatar": .text(avatar)], actor: service.identity.id, action: "user_avatar")
        }
    }
    func activate(_ id: String) async throws -> NativeUserAdministrationMailResult {
        let row = try service.db.transaction {
            try admin(); try identifier(id)
            return try mutation("ユーザーを有効化できませんでした") {
                NativeUserAdministrationRow(try service.db.update(try user(id), changes: ["userStatus": .text("ACTIVE")], actor: service.identity.id, action: "user_activate"))
            }
        }
        // Source SMTP helper swallows transport rejection. Preserve ACTIVE and
        // report an explicit delivery outcome; never claim a failed mail was sent.
        let message = mail.activation(row)
        try service.db.transaction { try admin(); _ = try user(id) }
        let delivery: NativeUserAdministrationMailResult.Delivery
        do { try Task.checkCancellation(); try await mail.send(message); delivery = .sent }
        catch is CancellationError { throw CancellationError() }
        catch { delivery = mail.isConfigured ? .failed : .notConfigured }
        try service.db.transaction { try admin() }
        return .init(user: row, delivery: delivery)
    }
    func invite(name: String, email: String, language: String) async throws -> NativeUserAdministrationMailResult {
        let inviter = try service.db.transaction { try admin(); return try user(service.identity.id)["name"].string }
        guard !name.isEmpty, !email.isEmpty, !language.isEmpty else { throw NativeUserAdministrationError.message("Name, Email, and Language is required!") }
        // This must precede duplicate lookup, matching the original Resend path.
        try mail.requireInvitationConfiguration()
        let row = try service.db.transaction {
            try admin()
            guard try service.db.page("Users", fields: [], equal: ["email": .text(email)], limit: 1).total == 0 else { throw NativeUserAdministrationError.message("このユーザーは既に登録されています。") }
            return try mutation("ユーザーを招待できませんでした") {
                NativeUserAdministrationRow(try service.db.insert("Users", values: ["name": .text(name), "email": .text(email), "userLanguage": .text(language), "role": .text("user"), "userStatus": .text("ACTIVE")], actor: service.identity.id))
            }
        }
        // A send failure leaves the created row, as the source action does.
        do {
            try service.db.transaction { try admin() }; try Task.checkCancellation()
            try await mail.send(mail.invitation(row, inviter: inviter.isEmpty ? "admin" : inviter))
            try service.db.transaction { try admin() }
            return .init(user: row, delivery: .sent)
        } catch is CancellationError { throw CancellationError() }
        catch { throw NativeUserAdministrationError.message("ユーザーを招待できませんでした") }
    }
}
