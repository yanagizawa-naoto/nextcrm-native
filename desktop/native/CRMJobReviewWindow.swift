import AppKit

final class CRMJobReviewWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:680,height:630),styleMask:[.titled],backing:.buffered,defer:false)
    typealias Record = (NativeJob, MailReviewOutcome, String, String) throws -> Void
    private let record: Record?
    private var automationNotice: Bool { ["crm.automation.kill.notice", "crm.automation.recycle.notice"].contains(job.event) }
    private let service: CRMService; private let job: NativeJob
    private let outcome = NSPopUpButton(); private let receipt = NSTextField()
    private let note = NSTextView(); private let hint = NSTextField(wrappingLabelWithString:"")
    private let error = NSTextField(wrappingLabelWithString:"")
    private var saved = false
    init(service: CRMService, job: NativeJob, record: Record? = nil) {
        self.service = service; self.job = job; self.record = record; super.init()
        window.title = "メールの送信結果を記録"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"送信サービスの管理画面などで、処理ID・宛先・件名が一致するメールを確認してください。この操作ではメールを再送しません。")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let namespace = automationNotice ? "crm-automation" : job.event == "invoice.email_requested" ? "invoice" : job.event == "reports.scheduled" ? "report" : job.event == NativeMCPLeads.assignedEvent ? "lead" : CRMService.crmTaskJobEvents.contains(job.event) ? "crm-task" : CRMService.projectJobEvents.contains(job.event) ? "project" : "order"
        let requestID = job.event == CampaignWorkflow.sendStepEvent ? "campaign-send/"+job.id : "nextcrm/"+namespace+"/"+job.id
        let remote = job.result["relayProviderIDHint"].map { "\n受信窓口に残る未確認の受付ID："+$0 } ?? ""
        let recipientCount = job.payload["recipientCount"].flatMap { Int($0) }.flatMap { $0 >= 0 ? "\($0)人" : nil }
        let context = NSTextField(wrappingLabelWithString:"処理ID："+requestID+"\n宛先："+(job.result["to"] ?? job.payload["to"] ?? job.payload["recipientEmail"] ?? recipientCount ?? "—")+"\n件名："+(job.result["subject"] ?? job.payload["subject"] ?? "—")+remote)
        context.font = .systemFont(ofSize:12); context.isSelectable = true
        outcome.addItems(withTitles:MailReviewOutcome.allCases.map(\.label)); outcome.setAccessibilityLabel("確認結果"); outcome.target = self; outcome.action = #selector(selectionChanged)
        receipt.placeholderString = "送信サービスのメールID（UUID）"; receipt.setAccessibilityLabel("送信サービスの受付ID"); receipt.stringValue = job.result["providerID"] ?? ""
        note.setAccessibilityLabel("確認した内容"); let notes = InvoiceMailUI.textScroll(note,height:100,editable:true)
        hint.font = .systemFont(ofSize:12); hint.textColor = .secondaryLabelColor; error.textColor = .systemRed
        let cancel = InvoiceMailUI.button("キャンセル",target:self,action:#selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        let save = InvoiceMailUI.button("記録して終了",target:self,action:#selector(save))
        let buttons = NSStackView(views:[NSView(),cancel,save]); buttons.spacing = 12
        InvoiceMailUI.layout(window,[title,help,context,outcome,receipt,hint,NSTextField(labelWithString:"確認した内容（必須・2,000文字以内）"),notes,error,buttons])
        selectionChanged()
    }
    private var selection: MailReviewOutcome { MailReviewOutcome.allCases[outcome.indexOfSelectedItem] }
    @objc private func selectionChanged() {
        receipt.isEnabled = selection == .accepted
        let unchanged = automationNotice ? "商談・営業先リストの状態は変更しません。" : job.event == "reports.scheduled" ? "この回の処理を終了します。次回以降の送信は、予約の有効・停止状態に従います。" : job.event == CampaignWorkflow.sendStepEvent ? "このメールの処理は終了し、再開しても再送しません。" : job.event == "invoice.email_requested" ? "請求書の状態は変更しません。" : job.event == NativeMCPLeads.assignedEvent ? "見込み客の状態は変更しません。": (CRMService.projectJobEvents+CRMService.crmTaskJobEvents).contains(job.event) ? "タスクの状態は変更しません。" : "受注の状態は変更しません。"
        switch selection {
        case .accepted: hint.stringValue = "受付IDを記録します。宛先への到着を保証するものではありません。"+(job.event == "invoice.email_requested" ? "発行済みの請求書は送信済みになります。" : unchanged)
        case .notSent: hint.stringValue = "送信されていないことを確認した根拠を記入してください。"+unchanged
        case .unknown: hint.stringValue = "結果が不明であることを残して終了します。別のメールを送ると重複する可能性があります。"+unchanged
        }
    }
    func confirmDiscard() -> Bool {
        guard !saved, !note.string.isEmpty || receipt.stringValue != (job.result["providerID"] ?? "") || selection != .accepted else { return true }
        let alert = NSAlert(); alert.messageText = "送信結果の記録を保存せずに閉じますか？"; alert.informativeText = "入力した確認内容は保存されません。"
        alert.addButton(withTitle:"入力を続ける"); alert.addButton(withTitle:"変更を破棄"); return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel() { if confirmDiscard() { window.sheetParent?.endSheet(window) } }
    @objc private func save() {
        do {
            if let record {
                try record(job, selection, selection == .accepted ? receipt.stringValue : "", note.string)
            } else if job.event == CampaignWorkflow.sendStepEvent {
                try service.reviewCampaignMailJob(job,outcome:selection,providerID:selection == .accepted ? receipt.stringValue : "",note:note.string)
            } else {
                try service.reviewMailJob(job,outcome:selection,providerID:selection == .accepted ? receipt.stringValue : "",note:note.string)
            }
            saved = true; window.sheetParent?.endSheet(window)
        } catch { self.error.stringValue = error.localizedDescription }
    }
}
