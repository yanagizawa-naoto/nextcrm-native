import Foundation

struct NativeCRMTaskLink: Equatable {
    let taskID: String
    init(taskID: String) throws {
        guard let id = UUID(uuidString:taskID), id.uuidString.lowercased() == taskID.lowercased() else { throw NativeDBError.message("タスクリンクの識別子が正しくありません。") }
        self.taskID = id.uuidString.lowercased()
    }
    init(text: String) throws {
        guard text.utf8.count <= 4096 else { throw NativeDBError.message("タスクリンクが長すぎます。") }
        guard let url = URLComponents(string:text.trimmingCharacters(in:.whitespacesAndNewlines)),
              url.scheme?.lowercased() == "nextcrm-native", url.host?.lowercased() == "crm-tasks",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.percentEncodedPath.hasPrefix("/"), !url.percentEncodedPath.dropFirst().contains("/") else { throw NativeDBError.message("NextCRMのタスクリンクを入力してください。") }
        try self.init(taskID:String(url.percentEncodedPath.dropFirst()))
    }
    var string: String { "nextcrm-native://crm-tasks/"+taskID }
}

extension CRMService {
    func crmTaskFromLink(_ link: NativeCRMTaskLink) throws -> CRMTaskAccess { try crmTaskAccess(link.taskID) }
}
