import Foundation
import CoreFoundation

/// The MCP campaign contract differs from editor validation. Its durable events
/// feed the existing dispatch/mail workers, retaining their run fences, provider
/// idempotency, opt-out checks and delivery-review behavior.
enum NativeMCPCampaigns {
    struct Event: Equatable { let name: String; let campaignID: String }
    typealias EventSink = (Event, CRMService, Date) throws -> Void
    static let names: Set<String> = ["campaigns_list", "campaigns_get", "campaigns_create", "campaigns_update", "campaigns_delete", "campaigns_send", "campaigns_pause", "campaigns_resume", "campaigns_list_templates", "campaigns_get_template", "campaigns_create_template", "campaigns_update_template", "campaigns_delete_template", "campaigns_create_step", "campaigns_update_step", "campaigns_delete_step", "campaigns_assign_target_list", "campaigns_remove_target_list", "campaigns_get_stats"]
    static var handlers: [String: NativeMCPRequestRouter.Handler] { handlers(events: persist, clock: Date.init) }
    static func handlers(events: @escaping EventSink, clock: @escaping () -> Date) -> [String: NativeMCPRequestRouter.Handler] {
        Dictionary(uniqueKeysWithValues: names.map { name in (name, { session, arguments in try session.withAccess { try run(name, arguments: arguments, service: $0, events: events, now: clock()) } }) })
    }
    static func persist(_ event: Event, service: CRMService, now: Date) throws {
        let token = UUID().uuidString.lowercased(), db = service.db
        // Pause/deletion are cancellation signals in Inngest. Existing native
        // workers observe the run-token change before resuming or sending.
        guard [CampaignWorkflow.sendEvent, "campaigns/paused", "campaigns/deleted"].contains(event.name) else { throw NativeMCPFailure.internalError }
        try db.setMetadata(CampaignWorkflow.runKey(event.campaignID), value: token)
        if event.name == CampaignWorkflow.sendEvent {
            try db.enqueue(event.name, payload: ["campaignId": event.campaignID, "runToken": token, "actorId": service.identity.id, "dispatchAt": NativeAPITokens.timestamp(now)], now: now)
        }
    }
    private static func json(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] {
            guard !object.keys.contains(where: { $0.contains("\0") }) else { throw NativeMCPFailure.internalError }
            return try object.mapValues(json)
        }
        if let array = value as? [Any] { return try array.map(json) }
        if let string = value as? String { guard !string.contains("\0") else { throw NativeMCPFailure.internalError }; return string }
        if value is NSNull { return NSNull() }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            guard number.doubleValue.isFinite else { throw NativeMCPFailure.internalError }; return number.doubleValue
        }
        throw NativeMCPFailure.internalError
    }
    static func run(_ name: String, arguments: [String: Any], service: CRMService, events: EventSink = persist, now: Date = Date()) throws -> Any {
        try Task.checkCancellation(); try service.authenticated()
        let db = service.db, actor = service.identity.id, campaigns = "crm_campaigns", templates = "crm_campaign_templates", steps = "crm_campaign_steps", sends = "crm_campaign_sends", links = "CampaignToTargetLists"
        func fields(_ model: String) throws -> [String] { try db.schema.model(model).fields.map(\.name) }
        func visible(_ model: String, _ id: String) throws -> NativeRecord {
            guard let row = try db.page(model, fields: fields(model), equal: ["id": .text(id)], filter: service.scope(model), limit: 1).rows.first else { throw NativeMCPFailure.notFound }; return row
        }
        func template() throws { if let id = arguments["template_id"] as? String { _ = try visible(templates, id) } }
        func values(_ keys: [String]) throws -> [String: SQLValue] {
            var result: [String: SQLValue] = [:]
            for key in keys where arguments[key] != nil {
                guard let value = arguments[key] as? String, !value.contains("\0") else { throw NativeMCPFailure.internalError }; result[key] = .text(value)
            }
            return result
        }
        func response(_ row: NativeRecord) throws -> Any { ["data": try NativeMCPWire.record(row, schema: db.schema)] }
        func rows(_ model: String, equal: [String: SQLValue], sort: String? = nil, selected: [String]? = nil, visit: (NativeRecord) throws -> Void) throws {
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try db.page(model, fields: selected ?? fields(model), equal: equal, includeDeleted: true, offset: offset, sort: sort, insertionOrderForTies: true)
                for row in page.rows { try visit(row) }; if page.rows.count < 100 { return }; offset += page.rows.count
            }
        }
        func count(_ model: String, _ id: SQLValue) throws -> Int { try db.page(model, fields: [], equal: ["campaign_id": id], includeDeleted: true, limit: 1).total }
        func included(_ row: NativeRecord, detail: Bool) throws -> [String: Any] {
            var data = try NativeMCPWire.record(row, schema: db.schema)
            var counts = ["sends": try count(sends, row["id"])]
            if !detail { counts["steps"] = try count(steps, row["id"]) }
            data["_count"] = counts
            if detail {
                var sequence: [[String: Any]] = [], targets: [[String: Any]] = []
                try rows(steps, equal: ["campaign_id": row["id"]], sort: "order") { step in
                    var item = try NativeMCPWire.record(step, schema: db.schema)
                    guard let template = try db.get(templates, key: ["id": step["template_id"]]) else { throw NativeMCPFailure.internalError }
                    item["template"] = try NativeMCPWire.record(template, schema: db.schema); sequence.append(item)
                }
                try rows(links, equal: ["campaign_id": row["id"]]) { link in
                    var item = try NativeMCPWire.record(link, schema: db.schema)
                    guard let target = try db.get("crm_TargetLists", key: ["id": link["target_list_id"]]) else { throw NativeMCPFailure.internalError }
                    item["target_list"] = try NativeMCPWire.record(target, schema: db.schema); targets.append(item)
                }
                data["steps"] = sequence; data["target_lists"] = targets
            }; return data
        }
        func firstStep(_ id: String) throws {
            guard try db.page(steps, fields: [], equal: ["campaign_id": .text(id), "order": .integer(0)], limit: 1).total > 0 else { throw NativeMCPFailure.conflict("Campaign has no first step (step 0)") }
        }
        func removable(_ campaign: NativeRecord) throws {
            guard campaign["status"] == .text("draft") else { throw NativeMCPFailure.conflict("Step 0 can only be deleted or moved while the campaign is a draft") }
        }
        func stepValues() throws -> [String: SQLValue] {
            var result = try values(["template_id", "subject", "send_to"])
            for field in ["order", "delay_days"] { if let value = arguments[field] { result[field] = .integer(Int64(try NativeMCPWire.integer(value, range: (field == "order" ? 1 : 0)...Int(Int32.max)))) } }
            return result
        }
        func templateValues() throws -> [String: SQLValue] {
            var result = try values(["name", "description", "subject_default", "content_html"])
            if let value = arguments["content_json"] {
                result["content_json"] = .text(String(decoding: try JSONSerialization.data(withJSONObject: json(value), options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self))
            }; return result
        }
        switch name {
        case "campaigns_list", "campaigns_list_templates":
            let model = name == "campaigns_list" ? campaigns : templates
            let limit = try NativeMCPWire.integer(arguments["limit"], range: 1...100), offset = try NativeMCPWire.integer(arguments["offset"], range: 0...Int(Int32.max))
            var filter = service.scope(model)
            if let status = arguments["status"] as? String { filter = .every([filter, .equal("status", .text(status))]) }
            let page = try db.mcpPage(model, fields: fields(model), filter: filter, limit: limit, offset: offset, order: [("created_on", true), ("id", true)])
            return ["data": try page.rows.map { model == campaigns ? try included($0, detail: false) : try NativeMCPWire.record($0, schema: db.schema) }, "total": page.total, "offset": offset]
        case "campaigns_get": return ["data": try included(visible(campaigns, arguments["id"] as! String), detail: true)]
        case "campaigns_get_template": return try response(visible(templates, arguments["id"] as! String))
        case "campaigns_create":
            try template(); var data = try values(["name", "description", "from_name", "reply_to", "template_id"])
            data["v"] = .integer(0); data["status"] = .text("draft"); data["created_by"] = .text(actor)
            return try response(db.insert(campaigns, values: data, actor: actor))
        case "campaigns_update":
            let row = try visible(campaigns, arguments["id"] as! String)
            guard row["status"] != .text("sending") else { throw NativeMCPFailure.conflict("Cannot update a campaign that is currently sending") }
            try template(); return try response(db.update(row, changes: values(["name", "description", "from_name", "reply_to", "template_id"]), actor: actor))
        case "campaigns_delete", "campaigns_delete_template":
            let id = arguments["id"] as! String, model = name == "campaigns_delete" ? campaigns : templates, row = try visible(model, id)
            if model == campaigns, row["status"] == .text("sending") { throw NativeMCPFailure.conflict("Cannot delete a campaign that is currently sending") }
            let stamp = NativeAPITokens.timestamp(now)
            _ = try db.update(row, changes: ["deletedAt": .text(stamp), "deletedBy": .text(actor)], actor: actor, action: "delete")
            if model == campaigns { try events(Event(name: "campaigns/deleted", campaignID: id), service, now) }
            return ["data": ["id": id, "deletedAt": stamp]]
        case "campaigns_send", "campaigns_resume", "campaigns_pause":
            if name != "campaigns_pause", !service.identity.elevated { throw NativeMCPFailure.forbidden }
            let id = arguments["id"] as! String, row = try visible(campaigns, id), status = row["status"] == .null ? "null" : row["status"].string
            let allowed = name == "campaigns_send" ? ["draft", "scheduled"] : name == "campaigns_pause" ? ["sending"] : ["paused"]
            guard allowed.contains(status) else {
                let verb = name == "campaigns_send" ? "send" : name == "campaigns_pause" ? "pause" : "resume"
                throw NativeMCPFailure.conflict("Cannot \(verb) campaign in status: \(status)")
            }
            if name != "campaigns_pause" { try firstStep(id) }
            if name == "campaigns_resume" {
                // Updating status removes rows from this predicate; restart at
                // offset zero so more than 100 abandoned claims are released.
                while true {
                    try Task.checkCancellation()
                    let batch = try db.page(sends, fields: fields(sends), equal: ["campaign_id": .text(id), "status": .text("sending")]).rows
                    for send in batch { _ = try db.update(send, changes: ["status": .text("queued")], actor: actor) }
                    if batch.count < 100 { break }
                }
            }
            var changes: [String: SQLValue] = ["status": .text(name == "campaigns_pause" ? "paused" : "sending")]
            if name == "campaigns_send" { changes["scheduled_at"] = .text(NativeAPITokens.timestamp(now)) }
            _ = try db.update(row, changes: changes, actor: actor)
            try events(Event(name: name == "campaigns_pause" ? "campaigns/paused" : CampaignWorkflow.sendEvent, campaignID: id), service, now)
            return ["data": ["id": id, "status": changes["status"]!.string]]
        case "campaigns_create_template":
            var data = try templateValues(); data["created_by"] = .text(actor)
            return try response(db.insert(templates, values: data, actor: actor))
        case "campaigns_update_template":
            return try response(db.update(visible(templates, arguments["id"] as! String), changes: templateValues(), actor: actor))
        case "campaigns_create_step":
            _ = try visible(campaigns, arguments["campaign_id"] as! String); try template()
            var data = try stepValues(); data["campaign_id"] = .text(arguments["campaign_id"] as! String)
            return try response(db.insert(steps, values: data, actor: actor))
        case "campaigns_update_step", "campaigns_delete_step":
            let id = arguments["id"] as! String
            guard let row = try db.get(steps, key: ["id": .text(id)]) else { throw NativeMCPFailure.notFound }
            let campaign = try visible(campaigns, row["campaign_id"].string)
            if row["order"] == .integer(0), name == "campaigns_delete_step" || arguments["order"] != nil { try removable(campaign) }
            if name == "campaigns_update_step" { try template(); return try response(db.update(row, changes: stepValues(), actor: actor)) }
            try db.remove(row, actor: actor); return ["data": ["id": id, "deleted": true]]
        case "campaigns_assign_target_list", "campaigns_remove_target_list":
            let id = arguments["campaign_id"] as! String, target = arguments["target_list_id"] as! String; _ = try visible(campaigns, id)
            let key: [String: SQLValue] = ["campaign_id": .text(id), "target_list_id": .text(target)]
            var data: [String: Any] = ["campaign_id": id, "target_list_id": target]
            if name == "campaigns_assign_target_list" { _ = try visible("crm_TargetLists", target); _ = try db.insert(links, values: key, actor: actor) }
            else { guard let row = try db.get(links, key: key) else { throw NativeMCPFailure.internalError }; try db.remove(row, actor: actor); data["removed"] = true }
            return ["data": data]
        case "campaigns_get_stats":
            let row = try visible(campaigns, arguments["id"] as! String)
            var stats = Dictionary(uniqueKeysWithValues: ["total", "sent", "delivered", "bounced", "failed", "opened", "clicked", "unsubscribed"].map { ($0, 0) })
            try rows(sends, equal: ["campaign_id": row["id"]], selected: ["status", "opened_at", "clicked_at", "unsubscribed_at"]) { send in
                stats["total"]! += 1
                if ["sent", "delivered"].contains(send["status"].string) { stats["sent"]! += 1 }
                for key in ["delivered", "bounced", "failed"] where send["status"] == .text(key) { stats[key]! += 1 }
                for (column, key) in [("opened_at", "opened"), ("clicked_at", "clicked"), ("unsubscribed_at", "unsubscribed")] where send[column] != .null { stats[key]! += 1 }
            }; return ["data": stats]
        default: throw NativeMCPFailure.internalError
        }
    }
}
