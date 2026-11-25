import Foundation

extension NativeMCPLeadsTests {
    static func uiSaveCases() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), f = try NativeMCPAccountsFixture(resources: resources); defer { f.close() }
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/mcp-leads-reference.json"))) as! [String: Any]
        let db = f.db, module = CRMModule.find("crm_Leads")!, event = NativeMCPLeads.assignedEvent
        var initial: [String: NativeRecord] = [:]
        for seed in reference["seeds"] as! [[String: Any]] {
            var fields = try values(seed); fields["lead_status_id"] = .null
            let row = try db.insert("crm_Leads", values: fields, actor: f.admin.identity.id); initial[row["id"].string] = row
        }
        for sample in reference["uiCases"] as! [[String: Any]] {
            for row in try db.page("crm_Leads", fields: try db.schema.model("crm_Leads").fields.map(\.name), includeDeleted: true).rows {
                if let original = initial[row["id"].string] {
                    let changes = original.values.filter { $0.key != "id" && $0.key != "updatedAt" && row[$0.key] != $0.value }
                    if !changes.isEmpty { _ = try db.update(row, changes: changes, actor: f.admin.identity.id) }
                } else { try db.remove(row, actor: f.admin.identity.id) }
            }
            let user = sample["user"] as! String, actor = try db.get("Users", key: ["id": .text(user)])!
            let service = CRMService(db: db, identity: .init(id: user, role: actor["role"].string, partnerAccountID: nil))
            let create = sample["create"] as! Bool, input = sample["input"] as! [String: Any]
            let original = create ? nil : try db.get("crm_Leads", key: ["id": .text(input["id"] as! String)])
            var native: [String: SQLValue] = ["lastName": .text(input[create ? "last_name" : "lastName"] as! String)]
            if let name = input["first_name"] as? String { native["firstName"] = .text(name) }
            if let assigned = input["assigned_to"] as? String { native["assigned_to"] = .text(assigned) }
            let previous = Set(try db.jobs(events: [event]).map(\.id)); var saved: NativeRecord?, failed = false
            do { saved = try service.save(module, original: original, input: native) } catch is NativeDBError { failed = true }
            let expected = sample["result"] as! [String: Any], mails = sample["mails"] as! [[String: Any]]
            try check(failed == (expected["error"] != nil), "UI source success/permission result \(sample)")
            let jobs = try db.jobs(events: [event]).filter { !previous.contains($0.id) }
            try check(jobs.count == mails.count, "UI source notification count")
            if let job = jobs.first {
                try check(job.payload["recipientEmail"] == mails[0]["to"] as? String && job.payload["recipientId"] == input["assigned_to"] as? String, "UI source exact recipient")
                try check(job.payload["leadId"] == saved?["id"].string && job.payload["actorID"] == user, "UI notification current lead and actor")
                let name = [saved!["firstName"].string, saved!["lastName"].string].filter { !$0.isEmpty }.joined(separator: " ")
                try check(job.payload["leadName"] == name, "UI notification name uses saved form text")
            }
        }
        let owner = CRMService(db: db, identity: .init(id: id(1), role: "user", partnerAccountID: nil))
        let original = try owner.save(module, original: nil, input: ["lastName": .text("UI atomicity")])
        let before = try db.jobs(events: [event]).count
        try sql(db, "CREATE TRIGGER reject_ui_lead_saved BEFORE INSERT ON native_outbox WHEN NEW.event='crm/lead.saved' BEGIN SELECT RAISE(ABORT,'synthetic UI queue failure'); END")
        do { _ = try owner.save(module, original: original, input: ["assigned_to": .text(id(2))]); throw Failure.assertion("UI failure accepted") } catch is NativeDBError { checks += 1 }
        try check(try db.get("crm_Leads", key: ["id": original["id"]])!.values == original.values && db.jobs(events: [event]).count == before, "UI row and notification roll back together")
        try sql(db, "DROP TRIGGER reject_ui_lead_saved")
        _ = try owner.save(module, original: original, input: ["lastName": .text("new revision")])
        do { _ = try owner.save(module, original: original, input: ["assigned_to": .text(id(2))]); throw Failure.assertion("stale form accepted") } catch is NativeDBError { checks += 1 }
        try check(try db.jobs(events: [event]).count == before, "stale form does not notify")
        let current = try db.get("crm_Leads", key: ["id": original["id"]])!
        try f.change("Users", id: id(2), values: ["email": .text("")])
        _ = try owner.save(module, original: current, input: ["assigned_to": .text(id(2))])
        try check(try db.jobs(events: [event]).count == before, "empty mailbox does not notify")
        print("Compared \((reference["uiCases"] as! [Any]).count) original lead UI actions for permissions and assignment notification decisions")
    }
}
