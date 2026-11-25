import AppKit

final class NativeAIJobsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 610), styleMask: [.titled], backing: .buffered, defer: false)
    private let keys: NativeAIKeys
    private let table = NSTableView(), detail = NSTextField(wrappingLabelWithString: ""), page = NSTextField(labelWithString: ""), message = NSTextField(wrappingLabelWithString: "")
    private var rows: [NativeJob] = [], total = 0, offset = 0
    private var retry: NSButton!, cancel: NSButton!, previous: NSButton!, next: NSButton!
    private var observer: NSObjectProtocol?
    private var progressObserver: NSObjectProtocol?
    init(keys: NativeAIKeys) throws {
        try keys.service.authenticated(); self.keys = keys; super.init(); window.title = "AI検索の処理"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "CRMの保存・関連メールの取得・文書の取り込みに合わせて検索データを更新します。文書は要約と分類も行います。全件作成の対象は閲覧できるCRM、自分の関連メール、編集できる処理済み文書です。OpenAIのAPI利用料が発生します。")
        for (id, name, width) in [("type", "対象", 180.0), ("status", "状態", 110.0), ("created", "予約日時", 205.0), ("result", "処理結果", 300.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = name; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 26; table.setAccessibilityLabel("AI検索処理の一覧")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        detail.maximumNumberOfLines = 3; detail.setAccessibilityLabel("AI検索処理の詳細"); message.maximumNumberOfLines = 2; message.setAccessibilityLabel("AI検索処理の結果")
        let create = button("全件の作成・更新を予約", #selector(create)), refresh = button("再読み込み", #selector(reload))
        retry = button("選択した処理を再実行", #selector(retrySelected)); cancel = button("選択した予約を取り消す", #selector(cancelSelected))
        let actions = NSStackView(views: [create, retry, cancel]); actions.spacing = 12
        previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward))
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [refresh, NSView(), page, previous, next, close]); footer.spacing = 12
        InvoiceMailUI.layout(window, [title, help, actions, scroll, detail, message, footer])
        observer = NotificationCenter.default.addObserver(forName: InvoiceJobRunner.didProcess, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.keys.service.db.url.path else { return }; self.reload()
        }
        progressObserver = NotificationCenter.default.addObserver(forName: NativeDatabase.aiProgress, object: nil, queue: .main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.keys.service.db.url.path else { return }; self.reload()
        }
        try self.refresh()
    }
    deinit { for token in [observer, progressObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) } }
    private func button(_ text: String, _ action: Selector) -> NSButton { InvoiceMailUI.button(text, target: self, action: action) }
    private var selected: NativeJob? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private static func status(_ job: NativeJob) -> String {
        switch job.status { case "pending": return "待機中"; case "running": return "実行中"; case "retry": return "再試行待ち"; case "failed": return "要確認"; case "cancelled": return "取消済み"; case "done": return job.result["outcome"] == "skipped" ? "対象外" : "完了"; default: return "要確認" }
    }
    private static func outcome(_ job: NativeJob) -> String {
        if let error = job.lastError { return error }
        switch job.result["outcome"] {
        case "embedded": return "検索データを保存しました"
        case "enriched": return "要約・分類・検索データを保存しました（\(job.result["chunks"] ?? "1")件）"
        case "unconfigured": return "AI未設定・ファイル名による分類のみ"
        case "cancelled": return "処理を取り消しました"
        case "unchanged": return "変更なし・API呼び出しなし"
        case "empty": return "検索対象の文章なし"
        case "queued": return "\(job.result["dispatched"] ?? "0")件を予約しました"
        case "skipped": return job.result["reason"] ?? "処理対象外です"
        default:
            if job.event == NativeDatabase.documentAIEvent {
                if job.result["summaryDone"] == "true" { return "要約作成済み・分類中" }
                if job.result["embeddingsDone"] == "true" { return "検索データ作成済み・要約中" }
                if let count = job.result["chunks"] { return "検索データを\(count)件作成済み" }
            }
            return job.result["dispatched"].map { "\($0)件を予約済み" } ?? ""
        }
    }
    private static let dateParser = ISO8601DateFormatter()
    private static let dateDisplay: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "ja_JP"); value.dateFormat = "yyyy/MM/dd HH:mm:ss"; return value
    }()
    private func refresh() throws {
        let id = selected?.id, result = try keys.service.embeddingJobs(offset: offset)
        total = result.total
        if result.rows.isEmpty && offset > 0 { offset = max(0, ((max(1, total) - 1) / 100) * 100); return try refresh() }
        rows = result.rows; table.reloadData()
        if let id, let index = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        page.stringValue = "\(total == 0 ? 0 : offset + 1)–\(offset + rows.count) ／ \(total)件"
        previous.isEnabled = offset > 0; next.isEnabled = offset + rows.count < total; selection()
    }
    private func selection() {
        retry.isEnabled = selected.map { ["failed", "retry"].contains($0.status) } ?? false
        cancel.isEnabled = selected.map { ["pending", "retry", "failed"].contains($0.status) || ($0.event == NativeDatabase.documentAIEvent && $0.status == "running") } ?? false
        detail.stringValue = selected.map(Self.outcome) ?? "確認する処理を選択してください。文書は実行中でも取り消せます。"
    }
    private func show(_ error: Error) { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }
        let job = rows[row]
        switch column?.identifier.rawValue {
        case "type": return NativeEmbeddingJobs.title(job.event)
        case "status": return Self.status(job)
        case "created": return Self.dateParser.date(from: job.createdAt).map { Self.dateDisplay.string(from: $0) } ?? "日時不明"
        default: return Self.outcome(job)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selection() }
    @objc private func reload() { do { try refresh() } catch { rows = []; table.reloadData(); selection(); show(error) } }
    @objc private func create() {
        do {
            guard try keys.resolve(.openai, interactive: true) != nil else { throw NativeAIError(message: "AI連携の設定でOpenAIのAPIキーを保存してください。") }
            _ = try keys.service.requestEmbeddingBackfill(); offset = 0; try refresh(); message.textColor = .labelColor; message.stringValue = "検索データの作成・更新を予約しました。"
        } catch { show(error) }
    }
    @objc private func retrySelected() { guard let job = selected else { return }; do { try keys.service.retryEmbeddingJob(job); try refresh() } catch { show(error) } }
    @objc private func cancelSelected() { guard let job = selected else { return }; do { try keys.service.cancelEmbeddingJob(job); try refresh() } catch { show(error) } }
    @objc private func back() { offset = max(0, offset - 100); reload() }
    @objc private func forward() { offset += 100; reload() }
    @objc private func close() { window.sheetParent?.endSheet(window) }
}
