import AppKit

/// A campaign's draft body stays in this sheet until the user saves. The same
/// native rich/HTML editor is used by template management and campaign creation.
final class CampaignStepEditor: NSObject, NSTextFieldDelegate {
    private(set) var editor: CampaignTemplateEditor!
    var window: NSPanel { editor.window }
    private let service: CRMService, campaign: NativeRecord, original: NativeRecord?
    private var sourceTemplate: NativeRecord?
    private var picker: CRMReferencePicker?
    let order = NSTextField(), days = NSTextField(), sendTo = NSPopUpButton()
    private let sourceLabel = NSTextField(labelWithString: "テンプレート未選択")
    private let message = NSTextField(wrappingLabelWithString: "")

    init(service: CRMService, campaign: NativeRecord, original: NativeRecord?, nextOrder: Int64 = 0, ai: CampaignAIService? = nil, allowsAI: Bool = true) throws {
        self.service = service; self.campaign = campaign; self.original = original
        try service.requireCampaignStepDraft(campaign: campaign, original: original)
        let templateID = original?["template_id"].string ?? campaign["template_id"].string
        let template = try templateID.isEmpty ? nil : service.campaignTemplate(templateID)
        sourceTemplate = template
        super.init()
        order.stringValue = original?["order"].string ?? String(nextOrder); order.setAccessibilityLabel("順番（初回は0）")
        days.stringValue = original?["delay_days"].string ?? (nextOrder == 0 ? "0" : "3"); days.setAccessibilityLabel("初回配信からの日数")
        order.delegate = self; days.delegate = self
        sendTo.addItems(withTitles: ["全員", "未開封の人のみ"]); sendTo.selectItem(at: original?["send_to"] == .text("non_openers") ? 1 : 0); sendTo.setAccessibilityLabel("配信先の条件")
        sendTo.target = self; sendTo.action = #selector(conditionChanged)
        let choose = NSButton(title: "テンプレートを選択…", target: self, action: #selector(chooseTemplate)); choose.bezelStyle = .rounded
        let row = NSStackView(views: [NSTextField(labelWithString: "順番"), order, NSTextField(labelWithString: "初回からの日数"), days, sendTo, choose]); row.spacing = 8
        order.widthAnchor.constraint(equalToConstant: 65).isActive = true; days.widthAnchor.constraint(equalToConstant: 75).isActive = true
        sourceLabel.stringValue = template.map { "選択中：" + $0["name"].string } ?? "テンプレート未選択（本文を入力するか、AIで作成できます）"
        let hint = NSTextField(wrappingLabelWithString: "初回の順番は0です。本文を変更すると、この手順用のテンプレートとして保存されます。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; message.textColor = .systemRed; message.maximumNumberOfLines = 2
        let extra = NSStackView(views: [row, sourceLabel, hint, message]); extra.orientation = .vertical; extra.alignment = .leading; extra.spacing = 5
        var values = template?.values ?? [:]
        values["name"] = template?["name"] ?? .text(campaign["name"].string + "／メール " + String(nextOrder))
        values["subject_default"] = original?["subject"] ?? template?["subject_default"] ?? .text("")
        let draft = NativeRecord(model: "crm_campaign_templates", values: values, revision: 0)
        editor = try CampaignTemplateEditor(service: service, record: draft, ai: ai, allowsAI: allowsAI, context: .step(campaign: campaign, original: original), extraView: extra,
            title: original == nil ? "配信手順とメールを追加" : "配信手順とメールを編集", onPrepareSave: { [weak self] payload in
                guard let self, let order = Int64(self.order.stringValue), let days = Int64(self.days.stringValue) else { throw NativeDBError.message("順番と日数は整数で入力してください。") }
                let input = CampaignStepInput(order: order, templateID: "", subject: payload["subject_default"]?.string ?? "", delayDays: days, sendTo: self.sendTo.indexOfSelectedItem == 1 ? "non_openers" : "all")
                let source = self.sourceTemplate
                return { [service, campaign, original] in _ = try service.saveCampaignStepDraft(campaign: campaign, original: original, sourceTemplate: source, templateInput: payload, stepInput: input) }
            })
        window.setContentSize(NSSize(width: 1000, height: min(850, (NSScreen.main?.visibleFrame.height ?? 920) - 70)))
    }
    @objc private func chooseTemplate() {
        guard !editor.isSaving, window.attachedSheet == nil else { return }
        let picker = CRMReferencePicker(model: "crm_campaign_templates", service: service) { [weak self] record in
            guard let self else { return }; self.picker = nil
            guard let record else { return }
            do {
                let full = try self.service.campaignTemplate(record["id"].string)
                try self.editor.replaceBody(full["content_html"].string, subject: full["subject_default"].string, json: full["content_json"].string)
                self.editor.name.stringValue = full["name"].string; self.editor.descriptionField.string = full["description"].string
                self.sourceTemplate = full; self.sourceLabel.stringValue = "選択中：" + full["name"].string; self.message.stringValue = ""
            } catch { self.message.stringValue = error.localizedDescription }
        }
        self.picker = picker; picker.window.title = "メールのテンプレートを選択"; window.beginSheet(picker.window); picker.start()
    }
    func confirmDiscard() -> Bool { picker == nil && editor.confirmDiscard() }
    func controlTextDidChange(_ notification: Notification) { editor.markDraftChanged() }
    @objc private func conditionChanged() { editor.markDraftChanged() }
}
