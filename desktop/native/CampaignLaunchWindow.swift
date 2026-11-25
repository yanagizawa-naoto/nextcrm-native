import AppKit

/// Coalesce actual job notifications; there is no repeating UI timer.
final class CampaignJobUpdates {
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    init(db: NativeDatabase, changed: @escaping () -> Void) {
        for name in [NativeDatabase.jobsDidChange,InvoiceJobRunner.didProcess] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
                guard let self, note.userInfo?["database"] as? String == db.url.path else { return }
                self.pending?.cancel(); let work = DispatchWorkItem(block:changed); self.pending = work
                DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
            })
        }
    }
    deinit { pending?.cancel(); observers.forEach{NotificationCenter.default.removeObserver($0)} }
}

final class CampaignLaunchWindow: NSObject {
    static func validateDefault(service: CRMService) async throws {
        let runtime = CampaignRuntime(db:service.db,mailStore:KeychainInvoiceMailCredentials(databaseURL:service.db.url))
        try await runtime.validateForLaunch()
    }
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:680,height:600),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let expected: NativeRecord; private let action: CampaignLaunchAction
    private let readiness: () async throws -> Void
    private let summary = NSTextField(wrappingLabelWithString:"対象を確認中…")
    private let date = NSDatePicker(); private let message = NSTextField(wrappingLabelWithString:"")
    private let confirm = NSButton(); private let cancel = NSButton()
    private var loading = true; private var busy = false; private var closed = false; private var task: Task<Void,Never>?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.campaign-launch")
    init(service: CRMService, campaign: NativeRecord, action: CampaignLaunchAction, readiness: @escaping () async throws -> Void) {
        self.service = service; expected = campaign; self.action = action; self.readiness = readiness; super.init()
        window.title = action.confirmationTitle
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let name = NSTextField(wrappingLabelWithString:campaign["name"].string); name.font = .systemFont(ofSize:16,weight:.medium)
        summary.setAccessibilityLabel("送信前の対象件数"); summary.font = .systemFont(ofSize:13)
        date.datePickerStyle = .textFieldAndStepper; date.datePickerElements = [.yearMonthDay,.hourMinute]; date.locale = Locale(identifier:"ja_JP"); date.timeZone = .current
        date.dateValue = CampaignWorkflow.date(campaign["scheduled_at"]).flatMap{$0 > Date() ? $0 : nil} ?? Date().addingTimeInterval(3600)
        date.setAccessibilityLabel("初回の予約日時")
        let dateLabel = NSTextField(labelWithString:"初回の予約日時（"+TimeZone.current.identifier+"）")
        let help = NSTextField(wrappingLabelWithString:"送信設定と配信停止の受信窓口を確認してから登録します。実際の送信時にも、権限・宛先・配信停止を確認します。\n\n予約日時にMacやアプリが停止している場合は、次の起動・復帰後に処理します。すでに送信したメールや、取消・結果確認で終了したメールは再送しません。"+(action == .resume ? "\n\n再開すると、フォローアップの予定日時は再開した日時から数え直します。" : ""))
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 4; message.textColor = .systemRed; message.setAccessibilityLabel("送信登録の結果")
        confirm.title = action.title; confirm.bezelStyle = .rounded; confirm.target = self; confirm.action = #selector(submit)
        cancel.title = "戻る"; cancel.bezelStyle = .rounded; cancel.target = self; cancel.action = #selector(cancelAction); cancel.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views:[NSView(),cancel,confirm]); actions.spacing = 12
        var content: [NSView] = [title,name,summary]
        if action == .schedule { content += [dateLabel,date] }
        content += [help,message,NSView(),actions]; InvoiceMailUI.layout(window,content); controls()
        queue.async { [weak self] in guard let self else { return }; let result = Result{try service.campaignLaunchSummary(campaign,action:action)}
            DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.loading = false
                switch result {
                case let .success(value): self.summary.stringValue = "初回の対象候補：\(value.candidates)件\n配信停止：\(value.suppressed)件 ／ アドレス未登録：\(value.withoutEmail)件を除外\n配信手順：\(value.steps)件（初回とフォローアップ）"
                case let .failure(error): self.message.stringValue = error.localizedDescription; self.loading = true
                }
                self.controls()
            }
        }
    }
    deinit { task?.cancel() }
    private func controls() { confirm.isEnabled = !loading && !busy; date.isEnabled = !busy; cancel.title = busy ? "確認を中止" : "戻る" }
    @objc private func submit() {
        guard !loading && !busy else { return }; busy = true; message.stringValue = "接続設定を確認しています…"; message.textColor = .secondaryLabelColor; controls()
        let due = action == .schedule ? date.dateValue : nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.service.launchCampaign(self.expected,action:self.action,at:due,readiness:self.readiness)
                self.task = nil; self.busy = false; self.closed = true; self.window.sheetParent?.endSheet(self.window,returnCode:.OK)
            } catch {
                self.task = nil; self.busy = false; self.message.textColor = .systemRed
                self.message.stringValue = error is CancellationError ? "確認を中止しました。送信処理は登録していません。" : error.localizedDescription; self.controls()
            }
        }
    }
    func confirmDiscard() -> Bool { !busy }
    @objc private func cancelAction() {
        if busy { task?.cancel(); return }
        closed = true; window.sheetParent?.endSheet(window,returnCode:.cancel)
    }
}
