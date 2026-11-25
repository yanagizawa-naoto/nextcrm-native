import Foundation

/// Original lib/authz/scopes/crm.ts documentReadScopeWhere, restricted to the
/// internal roles accepted by NativeAPISession. Native UI version-root sharing
/// intentionally remains separate; this API predicate follows each row's own
/// ownership and linked entities without filtering deleted linked parents.
enum NativeMCPDocumentAccess {
    static func readScope(_ service: CRMService) -> RecordFilter {
        let live = RecordFilter.equal("deletedAt", .null)
        if service.identity.elevated { return live }
        guard service.identity.role == "user" else { return .none }
        let actor = service.identity.id
        let owner = RecordFilter.any([.equal("assigned_to", .text(actor)), .equal("createdBy", .text(actor))])
        var allowed: [RecordFilter] = [.equal("created_by_user", .text(actor)), .equal("createdBy", .text(actor)), .equal("assigned_user", .text(actor)), .equal("visibility", .text("public"))]
        for (junction, foreign, model) in [("DocumentsToAccounts", "account_id", "crm_Accounts"), ("DocumentsToLeads", "lead_id", "crm_Leads"), ("DocumentsToContacts", "contact_id", "crm_Contacts"), ("DocumentsToOpportunities", "opportunity_id", "crm_Opportunities")] {
            allowed.append(.relation(model: junction, local: "id", foreign: "document_id", matching: .relation(model: model, local: foreign, foreign: "id", matching: model == "crm_Accounts" ? service.scope(model) : owner)))
        }
        return .every([live, .any(allowed)])
    }
    /// Fields default to the primary key, so an authorization check does not
    /// load document bodies. Internal-token write authority equals read scope.
    static func requireRead(_ id: String, service: CRMService, fields: [String] = []) throws -> NativeRecord {
        try service.authenticated()
        guard let row = try service.db.page("Documents", fields: fields, equal: ["id": .text(id)], filter: readScope(service), limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
    }
    static func requireWrite(_ id: String, service: CRMService, fields: [String] = []) throws -> NativeRecord { try requireRead(id, service: service, fields: fields) }
}
