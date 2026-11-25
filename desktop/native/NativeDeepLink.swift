import Foundation

/// A link is only a record locator. It cannot supply credentials, a database
/// path, or a state-changing command. Authorization always uses the open CRM.
struct NativeDeepLink: Equatable {
    let orderID: String
    init(orderID: String) throws {
        guard let id = UUID(uuidString:orderID), id.uuidString.lowercased() == orderID.lowercased() else { throw NativeDBError.message("受注リンクの識別子が正しくありません。") }
        self.orderID = id.uuidString.lowercased()
    }
    init(text: String) throws {
        guard text.utf8.count <= 4096 else { throw NativeDBError.message("受注リンクが長すぎます。") }
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let url = URLComponents(string:value), url.scheme?.lowercased() == "nextcrm-native", url.host?.lowercased() == "orders",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath.hasPrefix("/"), !url.percentEncodedPath.dropFirst().contains("/") else { throw NativeDBError.message("NextCRMの受注リンクを入力してください。") }
        try self.init(orderID:String(url.percentEncodedPath.dropFirst()))
    }
    var string: String { "nextcrm-native://orders/"+orderID }
}

/// Main-thread owned, bounded to the latest navigation intent. Incoming links
/// wait through startup or any sheet; they never dismiss or save an editor.
struct NativeLinkInbox {
    private var pending: Result<NativeDeepLink,Error>?
    var hasPending: Bool { pending != nil }
    mutating func receive(_ text: String) { pending = Result { try NativeDeepLink(text:text) } }
    mutating func take(ready: Bool) throws -> NativeDeepLink? {
        guard ready, let result = pending else { return nil }
        pending = nil; return try result.get()
    }
}

extension CRMService {
    func orderLink(_ record: NativeRecord) throws -> NativeDeepLink {
        let current = try orderAccess(record)
        return try NativeDeepLink(orderID:current["id"].string)
    }
    func orderFromLink(_ link: NativeDeepLink) throws -> NativeRecord {
        try authenticated()
        guard let record = try db.get("crm_Orders",key:["id":.text(link.orderID)]) else { throw NativeDBError.message("この受注はこのMacのデータに見つかりません。通知元と同じCRMデータを開いているか確認してください。") }
        return try orderAccess(record)
    }
}
