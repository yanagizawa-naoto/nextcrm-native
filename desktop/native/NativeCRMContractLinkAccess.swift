import Foundation

extension CRMService {
    /// Resolve only within the already-open workspace and its current authority.
    /// The URL is a locator, never a credential, a write, or a workspace selector.
    func contractFromLink(_ link:NativeCRMContractLink)throws->NativeRecord {
        try db.transaction {
            try assertAccess("crm_Contracts",id:link.contractID)
            guard let record=try db.get("crm_Contracts",key:["id":.text(link.contractID)]),
                  record["deletedAt"] == .null else {throw NativeDBError.message("対象が見つからないか、操作する権限がありません。")}
            return record
        }
    }
}
