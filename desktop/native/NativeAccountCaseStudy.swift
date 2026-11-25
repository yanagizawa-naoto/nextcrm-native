import Foundation

enum NativeAccountCaseStudyFailure: String, Error, LocalizedError {
    case login, forbidden, unavailable, candidateRequired
    var errorDescription: String? {
        switch self {
        case .login: return "ログインが必要です"
        case .forbidden: return "操作する権限がありません"
        case .unavailable: return "取引先が見つかりません"
        case .candidateRequired: return "先にこの取引先を導入事例の候補にしてください。"
        }
    }
}
struct NativeAccountCaseStudyState {
    let account: NativeRecord
    let canSetCandidate: Bool, canApprove: Bool
    var candidate: Bool { account["case_study_candidate"] == .integer(1) }
    var approved: Bool { account["case_study_approved"] == .integer(1) }
    var label: String { approved ? "承認済み" : candidate ? "候補" : "未登録" }
}
extension CRMService {
    func accountCaseStudy(_ id: String) throws -> NativeAccountCaseStudyState {
        try db.transaction {
            try authenticated(); try assertAccess("crm_Accounts",id:id)
            guard let account=try db.get("crm_Accounts",key:["id":.text(id)]),account["deletedAt"] == .null else {throw NativeAccountCaseStudyFailure.unavailable}
            return .init(account:account,canSetCandidate:!db.isReadOnly && ["user","manager","admin"].contains(identity.role),canApprove:!db.isReadOnly && identity.elevated)
        }
    }
    @discardableResult func setAccountCaseStudyCandidate(_ expected: NativeRecord, candidate: Bool) throws -> NativeRecord {
        try setAccountCaseStudy(expected,field:"case_study_candidate",value:candidate)
    }
    @discardableResult func setAccountCaseStudyApproved(_ expected: NativeRecord, approved: Bool) throws -> NativeRecord {
        try setAccountCaseStudy(expected,field:"case_study_approved",value:approved)
    }
    private func setAccountCaseStudy(_ expected: NativeRecord, field: String, value: Bool) throws -> NativeRecord {
        try db.transaction {
            let approval=field == "case_study_approved"
            do {try authenticated();guard identity.role != "partner" else {throw NativeAccountCaseStudyFailure.login}}
            catch {throw approval ? NativeAccountCaseStudyFailure.forbidden:NativeAccountCaseStudyFailure.login}
            if approval && !identity.elevated {throw NativeAccountCaseStudyFailure.forbidden}
            guard expected.model == "crm_Accounts" else {throw NativeAccountCaseStudyFailure.unavailable}
            let id=expected["id"].string
            if !approval {
                do {try assertAccess("crm_Accounts",id:id,write:true)}
                catch {throw NativeAccountCaseStudyFailure.unavailable}
            }
            guard let current=try db.get("crm_Accounts",key:["id":.text(id)]),current["deletedAt"] == .null else {throw NativeAccountCaseStudyFailure.unavailable}
            guard current.revision == expected.revision else {throw NativeDBError.conflict}
            if approval && value && current["case_study_candidate"] != .integer(1) {throw NativeAccountCaseStudyFailure.candidateRequired}
            var changes:[String:SQLValue]=[field:.integer(value ? 1:0),"updatedBy":.text(identity.id)]
            if !approval && !value {changes["case_study_approved"] = .integer(0)}
            let result=try db.update(current,changes:changes,actor:identity.id)
            // Original action logs exactly its requested field, including no-op
            // updates. Source audit is best effort; native_audit above is mandatory.
            let change:[[String:Any]]=[["field":field,"old":current[field] == .integer(1),"new":value]]
            let json=String(decoding:try JSONSerialization.data(withJSONObject:change,options:.sortedKeys),as:UTF8.self)
            _ = try? db.insert("crm_AuditLog",values:["entityType":.text("account"),"entityId":current["id"],"action":.text("updated"),"changes":.text(json),"userId":.text(identity.id)],actor:identity.id)
            return result
        }
    }
}
