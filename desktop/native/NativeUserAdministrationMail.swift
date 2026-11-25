import Foundation

struct NativeUserAdministrationMail {
    enum Kind: String { case activation, invitation }
    let kind: Kind
    let userID: String, to: String, from: String, subject: String, text: String, language: String
    let applicationURL: String
}
struct NativeUserAdministrationMailResult {
    enum Delivery: String { case sent, failed, notConfigured }
    let user: NativeUserAdministrationRow
    let delivery: Delivery
}
/// Explicit injection boundary, with no implicit network or Keychain access.
/// Native sign-in URL/provider and reviewed durable mail runtime are integration
/// gates; an unconfigured invitation cannot silently create an unusable account.
struct NativeUserAdministrationMailGateway {
    let applicationName: String, applicationURL: String, from: String
    let isConfigured: Bool
    let send: (NativeUserAdministrationMail) async throws -> Void
    static let unconfigured = Self(applicationName: "NextCRM", applicationURL: "", from: "", isConfigured: false, send: { _ in
        throw NativeUserAdministrationError.message("利用者への通知メールが設定されていません。")
    })
    func requireInvitationConfiguration() throws {
        guard isConfigured else { throw NativeUserAdministrationError.message("Resend API key is not configured. Please add it in Admin settings or set RESEND_API_KEY environment variable.") }
    }
    func activation(_ row: NativeUserAdministrationRow) -> NativeUserAdministrationMail {
        let email = row["email"].string, language = row["userLanguage"].string
        let text: String
        if language == "cz" {
            text = "Váš účet v aplikaci \(applicationName) byl aktivován. \n\n Vaše uživatelské jméno je: \(email) \n\n  Prosím přihlašte se na \(applicationURL) \n\n Děkujeme \n\n \(applicationName)"
        } else {
            text = "You account has been activated in \(applicationName) \n\n Your username is: \(email) \n\n Please login to \(applicationURL) \n\n Thank you \n\n \(applicationName)"
        }
        return .init(kind: .activation, userID: row.id, to: email, from: from, subject: "Invitation to \(applicationName)", text: text, language: language, applicationURL: applicationURL)
    }
    func invitation(_ row: NativeUserAdministrationRow, inviter: String) -> NativeUserAdministrationMail {
        // Accessible text version of emails/InviteUser.tsx, whose current en and
        // non-en branches both contain these Japanese instructions.
        let text = "\(inviter)さんからNextCRMへの招待が届きました\n\nチームへの招待が届きました\n\(row["name"].string) 様\n\(inviter)さんから招待が届きました：\n\(applicationName) アプリ：\(applicationURL).\n招待を受けるには、下のボタンからメールアドレスでログインしてください。\nチームに参加：\(applicationURL)\nまたは、次のURLをブラウザで開いてください：\(applicationURL)\nこの招待の宛先：\(row["name"].string). この招待に心当たりがない場合は、メールを破棄してください。不明な点はCRMの管理者にお問い合わせください。"
        return .init(kind: .invitation, userID: row.id, to: row["email"].string, from: "\(applicationName) <\(from)>", subject: "You have been invited to \(applicationName)", text: text, language: row["userLanguage"].string, applicationURL: applicationURL)
    }
}
