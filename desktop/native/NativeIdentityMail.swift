import Foundation
import CryptoKit

/// Composition supplies the real workspace authority. A URL alone never makes
/// a login provider usable; the authority resolver must validate every intent.
struct NativeIdentityMailConfiguration {
    let workspace: NativeIdentityWorkspace
    let applicationName: String, sender: String
    let loginURL: URL?
    init(workspace: NativeIdentityWorkspace, applicationName: String, sender: String, loginURL: URL?) throws {
        guard !applicationName.isEmpty, !applicationName.contains("\r"), !applicationName.contains("\n") else { throw NativeIdentityMailError.configuration }
        self.workspace = workspace; self.applicationName = applicationName
        self.sender = try InvoiceMail.mailbox(sender)
        if let loginURL {
            guard let url = URLComponents(url: loginURL, resolvingAgainstBaseURL: false),
                  url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  let issuer = URLComponents(string: workspace.issuer),
                  issuer.scheme == "https", url.host?.lowercased() == issuer.host?.lowercased(),
                  (url.port ?? 443) == (issuer.port ?? 443) else { throw NativeIdentityMailError.configuration }
        }
        self.loginURL = loginURL
    }
}

enum NativeIdentityMailError: Error, LocalizedError, Equatable {
    case configuration, invalidIntent, unavailable, changed, expired
    var errorDescription: String? {
        switch self {
        case .configuration: return "認証メールの送信元・ログイン先を設定してください。"
        case .invalidIntent: return "認証メールの要求を確認できません。"
        case .unavailable: return "認証の状態が変わりました。必要な場合はもう一度操作してください。"
        case .changed: return "送信開始後に認証メールの内容や設定が変わりました。送信結果を確認してください。"
        case .expired: return "認証コードの有効期限が切れました。新しいコードを取得してください。"
        }
    }
}

/// Only nonsecret identifiers enter the persistent queue. Neither OTPs nor
/// prepared mail bodies are Codable, logged, written to a spool, or backed up.
struct NativeIdentityMailIntent: Codable, Equatable {
    enum Kind: String, Codable {
        case signInCode, verifyEmailCode, resetPasswordCode
        case invitation, activation, newUserNotice
        var isCode: Bool { [.signInCode, .verifyEmailCode, .resetPasswordCode].contains(self) }
    }
    let id: String, workspaceID: String, issuer: String, referenceID: String, recipient: String
    let kind: Kind, issuedAt: Date
    let expiresAt: Date?
    init(id: String = UUID().uuidString.lowercased(), workspace: NativeIdentityWorkspace,
         referenceID: String, recipient: String, kind: Kind, issuedAt: Date, expiresAt: Date?) throws {
        self.id = id; workspaceID = workspace.id; issuer = workspace.issuer
        self.referenceID = referenceID; self.kind = kind; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        let mailbox = try InvoiceMail.mailbox(recipient)
        self.recipient = kind.isCode ? mailbox.lowercased() : mailbox
        try validate()
    }
    func validate() throws {
        guard UUID(uuidString: id)?.uuidString.lowercased() == id,
              UUID(uuidString: referenceID)?.uuidString.lowercased() == referenceID,
              !workspaceID.isEmpty, workspaceID.utf8.count <= 1024, !workspaceID.contains("\0"),
              !issuer.isEmpty, issuer.utf8.count <= 4096, !issuer.contains("\0"),
              issuedAt.timeIntervalSince1970.isFinite,
              (try InvoiceMail.mailbox(recipient)) == recipient else { throw NativeIdentityMailError.invalidIntent }
        if kind.isCode {
            guard recipient == recipient.lowercased(), let expiresAt,
                  expiresAt.timeIntervalSince1970.isFinite,
                  expiresAt > issuedAt, expiresAt.timeIntervalSince(issuedAt) <= 300 else { throw NativeIdentityMailError.invalidIntent }
        } else if let expiresAt {
            guard expiresAt.timeIntervalSince1970.isFinite, expiresAt > issuedAt else { throw NativeIdentityMailError.invalidIntent }
        }
    }
    func valid(at date: Date) -> Bool { date >= issuedAt && (expiresAt.map { date < $0 } ?? true) }
}

struct NativeIdentityMailContent: CustomStringConvertible, CustomDebugStringConvertible {
    let subject: String, text: String
    var description: String { "<認証メール本文>" }
    var debugDescription: String { description }
    static func code(_ code: String) throws -> Self {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw NativeIdentityMailError.invalidIntent }
        return .init(subject: "NextCRM 認証コード：" + code,
                     text: "認証コード：" + code + "\n\n有効期限は5分です。\nこのメールに心当たりがない場合は、破棄してください。")
    }
    static func notification(_ kind: NativeIdentityMailIntent.Kind, name: String, inviter: String,
                             configuration: NativeIdentityMailConfiguration) throws -> Self {
        guard !kind.isCode, let url = configuration.loginURL else { throw NativeIdentityMailError.configuration }
        let app = configuration.applicationName
        switch kind {
        case .invitation:
            return .init(subject: app + "への招待", text: name + " 様\n\n" + inviter + "さんから" + app + "への招待が届きました。\n招待されたメールアドレスでログインしてください。\n" + url.absoluteString + "\n\n心当たりがない場合は、このメールを破棄してください。")
        case .activation:
            return .init(subject: app + "の利用が承認されました", text: name + " 様\n\n" + app + "の利用が承認されました。\n次のURLからログインできます。\n" + url.absoluteString)
        case .newUserNotice:
            return .init(subject: app + "への新しい利用申請", text: name + "さんから利用申請が届きました。\n管理画面で申請内容を確認してください。\n" + url.absoluteString)
        default: throw NativeIdentityMailError.invalidIntent
        }
    }
    func data(intent: NativeIdentityMailIntent, configuration: NativeIdentityMailConfiguration) throws -> Data {
        guard !subject.isEmpty, !subject.contains("\r"), !subject.contains("\n"), subject.utf8.count <= 998 else { throw NativeIdentityMailError.invalidIntent }
        return try JSONSerialization.data(withJSONObject: ["from": configuration.sender, "to": [intent.recipient], "subject": subject, "text": text], options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// A keyed binding prevents an offline six-digit brute-force against the queue.
/// The authority supplies a stable secret; this type performs no implicit lookup.
struct NativeIdentityMailBinding {
    private let key: SymmetricKey
    init(secret: Data) throws {
        guard secret.count >= 32 else { throw NativeIdentityMailError.configuration }
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(), info: Data("NextCRM identity mail body v1".utf8), outputByteCount: 32)
    }
    func digest(_ data: Data, intent: NativeIdentityMailIntent) -> String {
        var authentication = HMAC<SHA256>(key: key)
        for value in [intent.workspaceID, intent.issuer, intent.id, intent.referenceID] {
            authentication.update(data: Data((String(value.utf8.count) + ":" + value).utf8))
        }
        authentication.update(data: data)
        return authentication.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
