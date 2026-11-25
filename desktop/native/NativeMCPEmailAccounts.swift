import Foundation

enum NativeMCPEmailAccounts {
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        ["crm_list_email_accounts": { session, arguments in
            try session.withAccess { service in
                let fields = ["id", "label", "imapHost", "imapPort", "imapSsl", "smtpHost", "smtpPort", "smtpSsl", "username", "isActive", "sentFolderName", "lastSyncedAt", "createdAt", "updatedAt"]
                let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
                // A manager/admin has no extra access to another user's mail.
                let scope = RecordFilter.every([.equal("userId", .text(service.identity.id)), .equal("isActive", .integer(1))])
                let page = try service.db.mcpPage("EmailAccount", fields: fields, filter: scope, limit: limit, offset: offset)
                let model = try service.db.schema.model("EmailAccount")
                let data: [[String: Any]] = try page.rows.map { row in
                    try Dictionary(uniqueKeysWithValues: fields.map { ($0, try NativeMCPWire.value(row[$0], field: model.field($0)!)) })
                }
                return ["data": data, "total": page.total, "offset": offset]
            }
        }]
    }
}
