import AppKit

final class NativeCRMAutomationJobsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    private let service: CRMService
    private let allowsMailRetry: Bool
    private let table = NSTableView(), detail = NSTextView()
    private let page = NSTextField(labelWithString: ""), message = NSTextField(wrappingLabelWithString: "")
    private var retry: NSButton!, cancel: NSButton!, review: NSButton!, previous: NSButton!, next: NSButton!
    private var rows: [NativeJob] = [], offset = 0
    private var observers: [NSObjectProtocol] = []
    private var reviewWindow: CRMJobReviewWindow?
    private static let columns = [NativeColumn(title: "作成日時", fraction: 0.24), NativeColumn(title: "処理", fraction: 0.30), NativeColumn(title: "状態", fraction: 0.24), NativeColumn(title: "試行回数", fraction: 0.22)]

    init(service: CRMService, allowsMailRetry: Bool = true) throws {
        self.allowsMailRetry = allowsMailRetry
        self.service = service
        rows = try service.crmAutomationJobs()
        super.init()
        window.title = "営業の自動処理と通知"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "商談のフォロー、契約更新、休眠商談の終了、営業先の再開対象登録を確認できます。取消しは選んだ処理だけが対象です。次回の定期処理や、作成済みのタスクは残ります。")
        help.font = .systemFont(ofSize: 12); help.textColor = .secondaryLabelColor
        let header = LightweightTableCell(); header.horizontalInset = 16
        header.configure(columns: Self.columns, values: Self.columns.map(\.title), heading: true)
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 34; table.style = .inset
        table.setAccessibilityLabel("営業の自動処理一覧")
        let column = NSTableColumn(identifier: .init("automation-job")); column.width = 890; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder; scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        detail.setAccessibilityLabel("営業の自動処理の詳細")
        let details = InvoiceMailUI.textScroll(detail, height: 100, editable: false)
        retry = button("再試行", #selector(retrySelected)); cancel = button("予約を取消", #selector(cancelSelected))
        review = button("確認結果を記録…", #selector(reviewSelected))
        previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward))
        let refresh = button("再読み込み", #selector(reload)), close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [retry, cancel, review, NSView(), refresh]); actions.spacing = 12
        let footer = NSStackView(views: [page, NSView(), previous, next, close]); footer.spacing = 12
        message.textColor = .systemRed; message.maximumNumberOfLines = 2; message.setAccessibilityLabel("営業の自動処理の操作結果")
        InvoiceMailUI.layout(window, [title, help, actions, header, scroll, details, message, footer], spacing: 10)
        for name in [InvoiceJobRunner.didProcess, NativeDatabase.jobsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, note.userInfo?["database"] as? String == self.service.db.url.path else { return }
                self.reload()
            })
        }
        render()
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    private func button(_ title: String, _ action: Selector) -> NSButton { InvoiceMailUI.button(title, target: self, action: action) }
    private var selected: NativeJob? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    func confirmDiscard() -> Bool { reviewWindow?.confirmDiscard() != false }
    @objc private func close() { if window.attachedSheet == nil { window.sheetParent?.endSheet(window) } }

    private func render(selectedID: String? = nil) {
        table.reloadData()
        if let id = selectedID, let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        page.stringValue = rows.isEmpty ? "処理の履歴はありません" : "\(offset + 1)–\(offset + rows.count)件"
        previous.isEnabled = offset > 0; next.isEnabled = rows.count == 100
        selection()
    }
    @objc private func reload() {
        let id = selected?.id
        do {
            var loaded = try service.crmAutomationJobs(offset: offset)
            if loaded.isEmpty && offset > 0 { offset = max(0, offset - 100); loaded = try service.crmAutomationJobs(offset: offset) }
            rows = loaded; render(selectedID: id); message.stringValue = ""
        } catch {
            rows = []; offset = 0; render(); message.stringValue = error.localizedDescription
        }
    }
    private func selection() {
        guard let job = selected else {
            retry.isEnabled = false; cancel.isEnabled = false; review.isEnabled = false
            detail.string = "確認する処理を選択してください。"; return
        }
        let isMail = NativeCRMAutomationJobs.mailEvents.contains(job.event)
        let withinRetryWindow = job.deliveryStartedAt.map { Date() >= $0 && Date().timeIntervalSince($0) < 23 * 3600 } ?? true
        retry.isEnabled = isMail ? allowsMailRetry && ["failed", "retry"].contains(job.status) && (withinRetryWindow || job.result["providerID"] != nil) : NativeCRMAutomationJobs.canRetry(job)
        cancel.isEnabled = isMail ? ["pending", "failed", "retry"].contains(job.status) && job.deliveryStartedAt == nil : NativeCRMAutomationJobs.canCancel(job)
        review.isEnabled = isMail && job.canReviewMail
        var lines = [NativeCRMAutomationJobs.title(job.event) + "：" + NativeCRMAutomationJobs.status(job)]
        if let due = job.nextRunAt { lines.append("次の実行予定：" + Self.date(due)) }
        if let error = job.lastError { lines.append(error) }
        if let reason = job.result["reason"] { lines.append(reason) }
        if let to = job.result["to"] ?? job.payload["to"] ?? job.payload["recipientEmail"] { lines.append("宛先：" + to) }
        else if let raw = job.payload["recipientCount"], let count = Int(raw), count >= 0 { lines.append("宛先：\(count)人") }
        if let subject = job.result["subject"] ?? job.payload["subject"] { lines.append("件名：" + subject) }
        lines.append(isMail ? "通知の完了は送信サービスによる受付です。結果が不明な通知は、送信サービスで確認してから確認結果を記録してください。" : "試行回数は今回の実行分です。手動で再試行すると、新たに最大5回まで自動で試行します。")
        if isMail && !allowsMailRetry { lines.append("通知の送信は確認待ちです。「機能・連携を再開」で通知の再開を確認してください。履歴の確認・予約の取消・送信結果の記録は利用できます。") }
        detail.string = lines.joined(separator: "\n")
    }
    @objc private func retrySelected() {
        guard window.attachedSheet == nil, let job = selected else { return }
        do {
            if NativeCRMAutomationJobs.mailEvents.contains(job.event) {
                guard allowsMailRetry else { throw NativeDBError.message("通知の送信は確認待ちです。「機能・連携を再開」で通知の再開を確認してください。") }
                try service.retryCRMSweepNotice(job)
            }
            else { try service.retryCRMAutomationJob(job) }
            reload()
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func cancelSelected() {
        guard window.attachedSheet == nil, let job = selected else { return }
        do {
            if NativeCRMAutomationJobs.mailEvents.contains(job.event) { try service.cancelCRMSweepNotice(job) }
            else { try service.cancelCRMAutomationJob(job) }
            reload()
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func reviewSelected() {
        guard window.attachedSheet == nil, let job = selected, NativeCRMAutomationJobs.mailEvents.contains(job.event), job.canReviewMail else { return }
        do {
            guard try service.crmSweepNoticeAccess(job.id) == job else { throw NativeDBError.conflict }
            let service = service
            let controller = CRMJobReviewWindow(service: service, job: job, record: { job, outcome, receipt, note in
                try service.reviewCRMSweepNotice(job, outcome: outcome, providerID: receipt, note: note)
            })
            reviewWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.reviewWindow = nil; self?.reload() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func back() { offset = max(0, offset - 100); reload() }
    @objc private func forward() { offset += 100; reload() }
    private static func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); var date = parser.date(from: value)
        if date == nil { parser.formatOptions.insert(.withFractionalSeconds); date = parser.date(from: value) }
        guard let date else { return "日時不明" }
        let display = DateFormatter(); display.locale = Locale(identifier: "ja_JP"); display.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return display.string(from: date)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selection() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let job = rows[row], id = NSUserInterfaceItemIdentifier("automation-job")
        let view = tableView.makeView(withIdentifier: id, owner: self) as? LightweightTableCell ?? LightweightTableCell(); view.identifier = id
        view.configure(columns: Self.columns, values: [Self.date(job.createdAt), NativeCRMAutomationJobs.title(job.event), NativeCRMAutomationJobs.status(job), String(job.attempts)])
        return view
    }
}
