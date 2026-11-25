import Foundation

@main enum CampaignAITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func rejects(_ label: String, _ body: () async throws -> Void) async throws { do { try await body() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label) }
    static func response(_ data: Data, status: Int = 200, url: URL = CampaignAIClient.endpoint) -> (Data, HTTPURLResponse) { (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!) }
    static func envelope(_ subject: Any = "件名", _ html: Any = "<p>本文</p>") throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["subject": subject, "html": html]), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }
    static func main() async { do { try await run(); print("CampaignAITests: \(checks) checks passed") } catch { FileHandle.standardError.write(Data("CampaignAITests: \(error)\n".utf8)); exit(1) } }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let reference = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("build/campaign-ai-reference.json"))) as! [String: Any]
        for item in reference["cases"] as! [[String: Any]] {
            let expected = item["request"] as! [String: Any], bytes = try JSONSerialization.data(withJSONObject: item["response"]!)
            let client = CampaignAIClient(apiKey: "qa-campaign-key", request: { req in
                try check(req.url!.absoluteString == expected["url"] as! String && req.httpMethod == expected["method"] as? String, "original endpoint/method")
                let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! NSDictionary
                try check(body.isEqual(to: expected["body"] as! [AnyHashable: Any]), "original model/prompt/tags/temperature")
                try check(req.value(forHTTPHeaderField: "Authorization") == "Bearer qa-campaign-key" && req.value(forHTTPHeaderField: "Content-Type") == "application/json", "original headers")
                try check(req.timeoutInterval == 30, "original deadline")
                return response(bytes)
            })
            if item["rejected"] as? Bool == true { try await rejects("original invalid response") { _ = try await client.generate(item["prompt"] as! String) } }
            else { let draft = try await client.generate(item["prompt"] as! String), wanted = item["expected"] as! [String: Any]; try check(draft.subject == wanted["subject"] as! String && draft.html == wanted["html"] as! String, "original draft output") }
        }
        let good = try envelope()
        for status in [401, 403, 429, 500] {
            let client = CampaignAIClient(apiKey: "qa-secret", request: { _ in response(Data("qa-secret/provider-detail".utf8), status: status) })
            do { _ = try await client.generate("案内"); throw NativeDBError.conflict } catch let error as NativeAIError { try check(error.status == status && !error.localizedDescription.contains("qa-secret"), "status and redaction") }
        }
        for bytes in [try envelope(7), try envelope("件名", ["invalid"]), try envelope("件名", String(repeating: "a", count: 65_537)), try envelope(String(repeating: "a", count: 4097)), Data(repeating: 32, count: 131_073)] {
            try await rejects("invalid or oversized output") { _ = try await CampaignAIClient(apiKey: "qa", request: { _ in response(bytes) }).generate("案内") }
        }
        try await rejects("foreign response origin") { _ = try await CampaignAIClient(apiKey: "qa", request: { _ in response(good, url: URL(string: "https://example.invalid/")!) }).generate("案内") }
        var calls = 0
        let counted = CampaignAIClient(apiKey: "qa", request: { _ in calls += 1; return response(good) })
        for prompt in ["", " \n\u{feff}", String(repeating: "あ", count: 11_000)] { try await rejects("prompt bound") { _ = try await counted.generate(prompt) } }
        try check(calls == 0, "invalid prompts never sent")
        var timed = CampaignAIClient(apiKey: "qa", request: { _ in try await Task.sleep(nanoseconds: 2_000_000_000); return response(good) }); timed.timeoutNanoseconds = 10_000_000
        let start = Date(); try await rejects("hard deadline") { _ = try await timed.generate("案内") }; try check(Date().timeIntervalSince(start) < 1, "deadline cancels provider")
        let task = Task { try await CampaignAIClient(apiKey: "qa", request: { _ in try await Task.sleep(nanoseconds: 2_000_000_000); return response(good) }).generate("案内") }
        task.cancel(); do { _ = try await task.value; throw NativeDBError.conflict } catch is CancellationError { checks += 1 }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignAI-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        var environment = ["OPENAI_API_KEY": "qa-key"]
        let keys = NativeAIKeys(service: service, store: NativeAIQAServices(), environment: .init(lookup: { environment[$0] }))
        var api = CampaignAIService(keys: keys, generate: { prompt, key in try check(prompt == "案内" && key == "qa-key", "resolved key/prompt"); return .init(subject: "AI件名", html: "<p>AI本文</p>") })
        let before = try db.page("crm_campaign_templates", fields: []).total
        let generated = try await api.create(prompt: "案内", context: .template(nil)); try check(generated.draft.subject == "AI件名", "service generates")
        try check(try db.page("crm_campaign_templates", fields: []).total == before && db.jobs(events: CampaignWorkflow.events).isEmpty, "generation neither saves nor sends")
        environment = [:]; try await rejects("missing key") { _ = try await api.create(prompt: "案内", context: .template(nil)) }
        environment = ["OPENAI_API_KEY": "qa-key"]
        api.generate = { _, _ in environment["OPENAI_API_KEY"] = "qa-replaced"; return generated.draft }
        try await rejects("key changes during generation") { _ = try await api.create(prompt: "案内", context: .template(nil)) }
        try await rejects("key changes before UI applies") { try api.validate(context: .template(nil), choice: generated.choice) }
        environment = ["OPENAI_API_KEY": "qa-key"]
        var templateInput: [String: SQLValue] = ["name": .text("共有案内"), "subject_default": .text("元の件名"), "description": .null, "content_html": .text("<p>元の本文</p>"), "content_json": .text("{}")]
        let template = try service.saveCampaignTemplate(nil, input: templateInput)
        api.generate = { _, _ in _ = try service.saveCampaignTemplate(template, input: ["name": .text("他の編集")]); return generated.draft }
        try await rejects("template changes during generation") { _ = try await api.create(prompt: "案内", context: .template(template)) }
        let freshTemplate = try service.campaignTemplate(template["id"].string); templateInput["name"] = freshTemplate["name"]
        var campaign = try service.createCampaign(input: ["name": .text("作成中"), "template_id": template["id"]])
        var step = CampaignStepInput(order: 0, templateID: "", subject: "", delayDays: 0)
        templateInput["subject_default"] = .text("手順の件名")
        var saved = try service.saveCampaignStepDraft(campaign: campaign, original: nil, sourceTemplate: freshTemplate, templateInput: templateInput, stepInput: step)
        try check(saved.step["template_id"] == template["id"] && saved.step["subject"] == .text("手順の件名"), "unchanged body reuses template, custom step subject")
        campaign = saved.campaign; templateInput["content_html"] = .text("<table style=\"color:red\"><tr><td>{{company}}😀</td></tr></table>")
        templateInput["name"] = .text("初回の新しい本文")
        saved = try service.saveCampaignStepDraft(campaign: campaign, original: saved.step, sourceTemplate: freshTemplate, templateInput: templateInput, stepInput: step)
        try check(saved.step["template_id"] != template["id"], "changed body gets independent template")
        try check(try service.campaignTemplate(template["id"].string)["content_html"] == template["content_html"], "shared body not mutated")
        try check(try service.campaignTemplate(saved.step["template_id"].string)["content_html"] == templateInput["content_html"], "raw HTML retained")
        try check(saved.campaign["template_id"] == saved.step["template_id"], "initial edited body updates campaign template like original wizard")
        campaign = saved.campaign
        let reportToken = try db.createReportWorkspace(); defer { db.removeReportWorkspace(reportToken) }
        try db.aggregateReport(reportToken, section: "topTemplates", recipe: "topTemplates", filter: .equal("id", campaign["id"]))
        let reportRows = try db.reportPage(reportToken, section: "topTemplates").rows
        try check(reportRows.count == 1 && reportRows[0]["label"] == templateInput["name"], "template report sees actual first email body")
        var followUpInput = templateInput; followUpInput["name"] = .text("追送の別の本文")
        let followUp = try service.saveCampaignStepDraft(campaign: campaign, original: nil, sourceTemplate: nil, templateInput: followUpInput, stepInput: .init(order: 1, templateID: "", subject: "", delayDays: 3))
        try check(followUp.campaign["template_id"] == campaign["template_id"] && followUp.step["template_id"] != campaign["template_id"], "follow-up does not replace campaign initial template")
        campaign = followUp.campaign
        let blankHeader = try service.createCampaign(input: ["name": .text("テンプレート未選択の下書き")])
        let initial = try service.saveCampaignStepDraft(campaign: blankHeader, original: nil, sourceTemplate: nil, templateInput: templateInput, stepInput: step)
        try check(initial.campaign["template_id"] == initial.step["template_id"] && initial.campaign["template_id"] != .null, "first native draft populates missing campaign template")
        let count = try db.page("crm_campaign_templates", fields: []).total
        step.delayDays = -1
        try await rejects("invalid step rolls template insertion back") { _ = try service.saveCampaignStepDraft(campaign: campaign, original: nil, sourceTemplate: nil, templateInput: templateInput, stepInput: step) }
        try check(try db.page("crm_campaign_templates", fields: []).total == count, "no orphan template")
        api.generate = { _, _ in _ = try service.saveCampaign(campaign, input: ["name": .text("他の変更")]); return generated.draft }
        try await rejects("campaign changes during generation") { _ = try await api.create(prompt: "案内", context: .step(campaign: campaign, original: saved.step)) }
        api.generate = { _, _ in let actor = try db.get("Users", key: ["id": .text(service.identity.id)])!; _ = try db.update(actor, changes: ["banned": .integer(1)], actor: "qa"); return generated.draft }
        try await rejects("account disabled during request") { _ = try await api.create(prompt: "案内", context: .template(nil)) }
    }
}
