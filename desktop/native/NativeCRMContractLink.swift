import Foundation

struct NativeCRMContractLink: Equatable {
    let contractID: String
    init(contractID: String) throws {
        guard let id = UUID(uuidString:contractID), id.uuidString.lowercased() == contractID.lowercased() else { throw NativeDBError.message("契約リンクの識別子が正しくありません。") }
        self.contractID = id.uuidString.lowercased()
    }
    init(text: String) throws {
        guard text.utf8.count <= 4096 else { throw NativeDBError.message("契約リンクが長すぎます。") }
        guard let url = URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              url.scheme?.lowercased() == "nextcrm-native", url.host?.lowercased() == "contracts",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath.hasPrefix("/"), !url.percentEncodedPath.dropFirst().contains("/") else { throw NativeDBError.message("NextCRMの契約リンクを入力してください。") }
        try self.init(contractID:String(url.percentEncodedPath.dropFirst()))
    }
    var string: String { "nextcrm-native://contracts/"+contractID }
}

/// A single latest navigation request; no credentials or source URL are retained.
struct NativeCRMContractLinkInbox {
    private var pending:Result<NativeCRMContractLink,Error>?
    var hasPending:Bool {pending != nil}
    mutating func receive(_ text:String) {pending=Result {try NativeCRMContractLink(text:text)}}
    mutating func take(ready:Bool)throws->NativeCRMContractLink? {
        guard ready,let result=pending else{return nil}
        pending=nil;return try result.get()
    }
}
