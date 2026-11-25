import Foundation

extension NativeCRMStageTests {
    static func producerChecks(native: URL, open: (String) throws -> NativeDatabase) async throws {
        let db = try open("producers"), actor = try CRMService.bootstrap(db, resources: native.appendingPathComponent("../../prisma"))
        let service = CRMService(db: db, identity: actor), module = CRMModule.find("crm_Opportunities")!
        let care = try db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("検証・導入後"), "stage_kind": .text("care"), "order": .integer(-999)], actor: actor.id)
        let alternative = try db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("検証・導入後2"), "stage_kind": .text("care"), "order": .integer(-998)], actor: actor.id)
        let qualified = try db.insert("crm_Opportunities_Sales_Stages", values: ["name": .text("検証・見積"), "stage_kind": .text("qualified")], actor: actor.id)
        let account = try db.insert("crm_Accounts", values: ["v": .integer(0), "name": .text("入口検証の取引先"), "assigned_to": .text(actor.id)], actor: actor.id)
        func verifyHead(_ record: NativeRecord, stage: SQLValue, label: String) throws -> String {
            guard let head = try db.opportunityStageEventHead(recordID: record["id"].string), let event = try db.job(id: head) else { throw Failure.assertion("missing producer head " + label) }
            try check(event.event == NativeCRMStageJobs.transitionEvent && event.payload["record_id"] == record["id"].string && event.payload["to_stage"] == stage.string, "actual " + label + " publishes canonical shape")
            try check(Set(event.payload.keys) == ["record_id", "to_stage"], "actual " + label + " preserves original event.data fields")
            try check(try db.opportunityStageEventTimestamp(recordID: record["id"].string, eventID: head)?.count == 24, "actual " + label + " keeps private millisecond timestamp")
            return head
        }
        // Real UI service path, including its own authentication/parent/revision
        // and stage approval rules; no mocked producer functions.
        let ui = try service.save(module, original: nil, input: ["name": .text("画面入口"), "account": account["id"], "assigned_to": .text(actor.id), "sales_stage": care["id"]])
        let uiFirst = try verifyHead(ui, stage: care["id"], label: "CRMService.create")
        let changed = try service.save(module, original: db.get(ui.model, key: ["id": ui["id"]])!, input: ["sales_stage": alternative["id"]])
        let uiSecond = try verifyHead(changed, stage: alternative["id"], label: "CRMService.update")
        try check(uiFirst != uiSecond, "UI stage change publishes new head")
        let renamed = try service.save(module, original: db.get(ui.model, key: ["id": ui["id"]])!, input: ["name": .text("名前だけ変更")])
        try check(try db.opportunityStageEventHead(recordID: renamed["id"].string) == uiSecond, "UI same stage does not create generation")
        let before = try db.get(ui.model, key: ["id": ui["id"]])!
        do { try db.transaction { _ = try service.save(module, original: before, input: ["sales_stage": care["id"]]); throw Failure.injected } } catch Failure.injected { checks += 1 }
        let uiRestored = try db.get(ui.model, key: ["id": ui["id"]])!
        try check(try uiRestored.values == before.values && uiRestored.revision == before.revision && db.opportunityStageEventHead(recordID: ui["id"].string) == uiSecond, "UI outer rollback preserves record/head")
        do { _ = try service.save(module, original: before, input: ["sales_stage": qualified["id"]]); throw Failure.assertion("unapproved UI transition accepted") } catch let error as NativeDBError { _ = error; checks += 1 }
        try check(try db.opportunityStageEventHead(recordID: ui["id"].string) == uiSecond, "approval rejection does not publish generation")
        // Actual MCP operation implementation executes inside the same enclosing
        // access transaction used by the request router (token proof is separate).
        let created = try db.transaction { try NativeMCPOpportunities.run("crm_create_opportunity", arguments: ["name": "MCP入口", "sales_stage_id": care["id"].string], service: service) } as! [String: Any]
        let apiID = (created["data"] as! [String: Any])["id"] as! String
        let api = try db.get("crm_Opportunities", key: ["id": .text(apiID)])!
        let apiFirst = try verifyHead(api, stage: care["id"], label: "MCP.create")
        _ = try db.transaction { try NativeMCPOpportunities.run("crm_update_opportunity", arguments: ["id": apiID, "sales_stage_id": alternative["id"].string], service: service) }
        let apiSecond = try verifyHead(db.get(api.model, key: ["id": .text(apiID)])!, stage: alternative["id"], label: "MCP.update")
        try check(apiFirst != apiSecond, "MCP stage change publishes new head")
        let apiBefore = try db.get(api.model, key: ["id": .text(apiID)])!
        do { try db.transaction { _ = try NativeMCPOpportunities.run("crm_update_opportunity", arguments: ["id": apiID, "sales_stage_id": care["id"].string], service: service); throw Failure.injected } } catch Failure.injected { checks += 1 }
        let apiRestored = try db.get(api.model, key: ["id": .text(apiID)])!
        try check(try apiRestored.values == apiBefore.values && apiRestored.revision == apiBefore.revision && db.opportunityStageEventHead(recordID: apiID) == apiSecond, "MCP outer rollback preserves record/head")
        // Actual target conversion path chooses its initial stage and emits the
        // same durable head as UI/API writes, in its existing outer transaction.
        let target = try db.insert("crm_Targets", values: ["last_name": .text("営業対象"), "company": .text("変換テスト"), "email": .text("target@example.invalid"), "tags": .text("[]"), "notes": .text("[]"), "created_by": .text(actor.id)], actor: actor.id)
        let converted = try service.convertTarget(target, createOpportunity: true)
        guard let opportunity = converted.opportunity else { throw Failure.assertion("conversion no opportunity") }
        _ = try verifyHead(opportunity, stage: care["id"], label: "target-conversion")
        try check(opportunity["sales_stage"] == care["id"], "conversion chosen initial stage retained")
        let secondTarget = try db.insert("crm_Targets", values: ["last_name": .text("取消対象"), "tags": .text("[]"), "notes": .text("[]"), "created_by": .text(actor.id)], actor: actor.id)
        let count = try jobs(db, events: [NativeCRMStageJobs.transitionEvent]).count
        do { try db.transaction { _ = try service.convertTarget(secondTarget, createOpportunity: true); throw Failure.injected } } catch Failure.injected { checks += 1 }
        let targetRestored = try db.get("crm_Targets", key: ["id": secondTarget["id"]])!
        try check(jobs(db, events: [NativeCRMStageJobs.transitionEvent]).count == count && targetRestored.values == secondTarget.values && targetRestored.revision == secondTarget.revision, "conversion outer rollback removes published head/event/rows")
        // Finally the real retained consumer accepts all three real producers.
        while try NativeCRMStageJobs.runNext(db: db) {}
        try check(jobs(db, events: [NativeCRMStageJobs.transitionEvent]).allSatisfy { $0.status == "done" }, "actual three producer queues consumed")
        try check(jobs(db, events: [NativeCRMStageJobs.touchEvent]).filter { $0.status == "pending" }.count == 3, "one current schedule per produced opportunity")
    }
}
