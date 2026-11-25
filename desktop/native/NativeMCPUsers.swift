import Foundation

enum NativeMCPUsers {
    static var handlers: [String: NativeMCPRequestRouter.Handler] {
        ["crm_list_users": { session, arguments in try session.withAccess { try list(arguments, service: $0) } }]
    }
    static func list(_ arguments: [String: Any], service: CRMService) throws -> Any {
        try service.authenticated()
        let privileged = service.identity.elevated
        let status = privileged ? arguments["status"] as? String ?? "ACTIVE" : "ACTIVE"
        let fields = ["id", "name", "avatar"] + (privileged ? ["email", "role", "userStatus", "lastLoginAt"] : [])
        let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
        let page = try service.db.mcpPage("Users", fields: fields, filter: status == "ALL" ? .all : .equal("userStatus", .text(status)), searchFields: ["name"], query: arguments["query"] as? String, limit: limit, offset: offset, order: [("name", false), ("id", false)])
        let model = try service.db.schema.model("Users")
        // Select and serialize only this explicit projection. Never load or
        // expose passwords, ban reasons or other private identity fields.
        let rows: [[String: Any]] = try page.rows.map { row in
            try Dictionary(uniqueKeysWithValues: fields.map { ($0, try NativeMCPWire.value(row[$0], field: model.field($0)!)) })
        }
        return ["data": rows, "total": page.total, "offset": offset]
    }
}
