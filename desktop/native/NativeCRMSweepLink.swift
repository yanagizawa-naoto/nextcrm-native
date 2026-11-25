import Foundation

/// A locator only. The open application's current identity must authorize it.
struct NativeCRMSweepLink: Equatable {
    enum Destination: String { case opportunity = "opportunities", targetList = "target-lists" }
    let destination: Destination; let id: String
    init(destination: Destination, id: String) throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() else { throw NativeDBError.message("営業通知の識別子が正しくありません。") }
        self.destination = destination; self.id = uuid.uuidString.lowercased()
    }
    init(text: String) throws {
        guard text.utf8.count <= 4096, let url = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "nextcrm-native", let host = url.host?.lowercased(), let destination = Destination(rawValue: host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath.hasPrefix("/"), !url.percentEncodedPath.dropFirst().contains("/") else { throw NativeDBError.message("NextCRMの営業通知リンクを入力してください。") }
        try self.init(destination: destination, id: String(url.percentEncodedPath.dropFirst()))
    }
    var string: String { "nextcrm-native://" + destination.rawValue + "/" + id }
}
