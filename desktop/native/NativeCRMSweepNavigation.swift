import Foundation

extension CRMService {
    /// Link possession grants no access, and deleted records are not restored.
    func crmSweepRecord(from link: NativeCRMSweepLink) throws -> NativeRecord {
        try db.transaction {
            let model = link.destination == .opportunity ? "crm_Opportunities" : "crm_TargetLists"
            try assertAccess(model,id:link.id)
            guard let row = try db.get(model,key:["id":.text(link.id)]) else { throw NativeDBError.conflict }
            return row
        }
    }
}
