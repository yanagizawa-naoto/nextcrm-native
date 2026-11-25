import Foundation

/// Frozen original createAutoTask input. Stored in a durable local item job;
/// no HTTP, credentials or actors synthesized from CLI are involved.
struct NativeCRMAutomationTaskInput: Codable, Equatable {
    let title: String, content: String, accountID: String?, opportunityID: String?, assigneeID: String?, due: String
    let dedupAnyStatus: Bool
    var canonicalTitle: String? = nil
}

enum NativeCRMAutomationTasks {
    static let notificationKind = "funnel-auto-task-v1"
    /// Caller may nest this inside its job transaction. BEGIN IMMEDIATE makes
    /// the source title/scope dedup atomic across independent SQLite connections.
    static func create(_ input: NativeCRMAutomationTaskInput, db: NativeDatabase, now: Date,
                       validate: () throws -> Void = {}) throws -> String? {
        try db.transaction {
            try Task.checkCancellation(); try validate()
            guard let assignee = input.assigneeID, !assignee.isEmpty else { return nil }
            var titles: [RecordFilter] = [.equal("title", .text(input.title))]
            if let canonical = input.canonicalTitle, canonical != input.title { titles.append(.equal("title", .text(canonical))) }
            var predicates: [RecordFilter] = [.any(titles)]
            if let opportunity = input.opportunityID, !opportunity.isEmpty { predicates.append(.equal("opportunity_id", .text(opportunity))) }
            else { predicates.append(.equal("account", input.accountID.map(SQLValue.text) ?? .null)) }
            if !input.dedupAnyStatus { predicates.append(.any([.equal("taskStatus", .text("ACTIVE")), .equal("taskStatus", .text("PENDING"))])) }
            if try !db.keysetPage("crm_Accounts_Tasks", fields: [], filter: .every(predicates), limit: 1).isEmpty { return nil }
            let timestamp = try NativeCRMAutomationDates.stamp(now)
            _ = try NativeCRMAutomationDates.parse(input.due)
            let task = try db.insert("crm_Accounts_Tasks", values: [
                "v": .integer(0), "title": .text(input.title), "content": .text(input.content), "priority": .text("high"), "taskStatus": .text("ACTIVE"),
                "account": input.accountID.map(SQLValue.text) ?? .null, "opportunity_id": input.opportunityID.map(SQLValue.text) ?? .null,
                "user": .text(assignee), "createdBy": .text(assignee), "updatedBy": .text(assignee), "dueDateAt": .text(input.due),
                "createdAt": .text(timestamp), "updatedAt": .text(timestamp)
            ], actor: assignee)
            // Source notifies its assignee even when createdBy == assignee, and
            // never notifies account watchers. Frozen content/due reach the
            // existing CRMTaskMail worker via its candidate template extension.
            if let user = try db.keysetPage("Users", fields: ["email", "name"], filter: .equal("id", .text(assignee)), includeDeleted: true, limit: 1).first,
               !user["email"].string.isEmpty {
                try db.enqueue("crm.task_assigned", payload: ["taskId": task["id"].string, "accountId": task["account"].string, "opportunityId": task["opportunity_id"].string,
                    "recipientId": assignee, "recipientEmail": user["email"].string, "actorId": assignee, "actorName": user["name"].string,
                    "taskTitle": input.title, "automationKind": notificationKind, "taskContent": input.content, "taskDueAt": input.due], now: now)
            }
            try Task.checkCancellation(); try validate()
            return task["id"].string
        }
    }
}
