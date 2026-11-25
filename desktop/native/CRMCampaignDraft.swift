import Foundation

extension CRMService {
    func requireCampaignStepDraft(campaign expected: NativeRecord, original: NativeRecord?) throws {
        try db.transaction {
            try authenticated()
            guard ["admin", "manager", "user"].contains(identity.role), expected.model == "crm_campaigns" else { throw NativeDBError.conflict }
            let fresh = try campaign(expected["id"].string)
            guard fresh.revision == expected.revision else { throw NativeDBError.conflict }
            guard fresh["status"] != .text("sending") else { throw NativeDBError.message("配信中のキャンペーンを変更するには、先に一時停止してください。") }
            if let original {
                guard original.model == "crm_campaign_steps", let step = try db.get(original.model, key: ["id": original["id"]]),
                      step.revision == original.revision, step["campaign_id"] == fresh["id"] else { throw NativeDBError.conflict }
            }
        }
    }

    /// Save the body and its step together. Editing a campaign never silently
    /// rewrites a shared template used by another campaign.
    func saveCampaignStepDraft(campaign: NativeRecord, original: NativeRecord?, sourceTemplate: NativeRecord?,
                               templateInput: [String: SQLValue], stepInput: CampaignStepInput) throws -> (campaign: NativeRecord, step: NativeRecord) {
        try db.transaction {
            try requireCampaignStepDraft(campaign: campaign, original: original)
            guard !NativeEmbeddingVector.isBlank(templateInput["content_html"]?.string ?? "") else { throw NativeDBError.message("メールの本文を入力してください。") }
            let source: NativeRecord?
            if let sourceTemplate {
                guard sourceTemplate.model == "crm_campaign_templates" else { throw NativeDBError.conflict }
                let current = try self.campaignTemplate(sourceTemplate["id"].string)
                guard current.revision == sourceTemplate.revision else { throw NativeDBError.conflict }; source = current
            } else { source = nil }
            let fields = ["name", "description", "subject_default", "content_html", "content_json"]
            guard templateInput.keys.allSatisfy(fields.contains) else { throw NativeDBError.conflict }
            // A step's subject is independent from the reusable template's default.
            let same = source.map { record in templateInput.allSatisfy { $0.key == "subject_default" || record[$0.key] == $0.value } } ?? false
            let template = try same ? source! : saveCampaignTemplate(nil, input: templateInput)
            var input = stepInput; input.templateID = template["id"].string; input.subject = templateInput["subject_default"]?.string ?? ""
            let saved = try saveCampaignStep(campaign: campaign, original: original, input: input)
            // The original creation wizard stores the first email's template on
            // both the campaign and order-0 step. Keep the native editor's
            // generated/copied body visible to template reports as well.
            guard input.order == 0, saved.campaign["template_id"] != template["id"] else { return saved }
            let header = try db.update(saved.campaign, changes: ["template_id": template["id"]], actor: identity.id, action: "initial_template_save")
            return (header, saved.step)
        }
    }
}
