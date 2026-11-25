import AppKit

final class NativeCurrencyAdministrationWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeCurrencyAdministration
    private let allowsECB: Bool
    private let allowsECBSettings: Bool
    private let confirm: (String) -> Bool
    private let mode = NSPopUpButton(), search = NSSearchField(), table = NSTableView()
    private let ecb = NSButton(checkboxWithTitle: "ECBの為替レートを自動更新する（平日17時・UTC）", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: ""), jobStatus = NSTextField(wrappingLabelWithString: ""), count = NSTextField(labelWithString: "")
    private var rows: [NativeRecord] = [], offset = 0, total = 0, busy = false, permitted = true, closed = false
    private var settings: NativeCurrencyAdministration.Settings?, lastJob: NativeJob?
    private var buttons: [String: NSButton] = [:], editor: NativeCurrencyAdministrationEditor?
    var onChanged: (() -> Void)?
    init(service: CRMService, confirmDiscard: @escaping (String) -> Bool = NativeCurrencyAdministrationWindow.ask, allowsECB: Bool = true, allowsECBSettings: Bool? = nil) throws {
        self.allowsECB = allowsECB; self.allowsECBSettings = allowsECBSettings ?? allowsECB; api = NativeCurrencyAdministration(service: service); confirm = confirmDiscard; try api.requireAdmin()
        super.init(); window.title = "通貨と為替レートの設定"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "通貨の有効状態と新規データの既定通貨を設定します。保存済みの受注・請求書の通貨や金額は変更されません。")
        mode.addItems(withTitles: ["通貨", "為替レート"]); mode.setAccessibilityLabel("通貨設定の表示"); mode.target = self; mode.action = #selector(modeChanged)
        mode.widthAnchor.constraint(equalToConstant: 150).isActive = true
        search.placeholderString = "コード・名称で検索"; search.setAccessibilityLabel("通貨設定の検索"); search.target = self; search.action = #selector(searchChanged)
        let toolbar = NSStackView(views: [mode, search, button("追加…", #selector(add)), button("再読み込み", #selector(refresh))]); toolbar.spacing = 8
        table.delegate = self; table.dataSource = self; table.rowHeight = 30; table.allowsMultipleSelection = false; table.columnAutoresizingStyle = .noColumnAutoresizing; table.setAccessibilityLabel("通貨設定の一覧")
        configureColumns()
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let actions = NSStackView(views: [button("有効・無効を切替", #selector(toggle)), button("既定の通貨に設定", #selector(makeDefault)), button("レートを編集…", #selector(editRate)), NSView()]); actions.spacing = 8
        ecb.target = self; ecb.action = #selector(toggleECB); ecb.setAccessibilityLabel("ECBの自動更新")
        let explanation = NSTextField(wrappingLabelWithString: "ECB更新ではEURとの直接・逆換算レートを更新します。その他の通貨間で手動設定したレートは保持します。自動更新中のECBレートは編集できません。")
        explanation.textColor = .secondaryLabelColor; explanation.font = .systemFont(ofSize: 12)
        let jobs = NSStackView(views: [button("今すぐECB更新", #selector(requestUpdate)), button("更新をキャンセル", #selector(cancelUpdate)), button("更新を再試行", #selector(retryUpdate)), NSView()]); jobs.spacing = 8
        jobStatus.maximumNumberOfLines = 2; jobStatus.setAccessibilityLabel("ECB更新の状態")
        status.maximumNumberOfLines = 2; status.setAccessibilityLabel("通貨設定の操作結果")
        let footer = NSStackView(views: [button("前の100件", #selector(previous)), count, button("次の100件", #selector(next)), NSView(), button("閉じる", #selector(close))]); footer.spacing = 8
        buttons["閉じる"]?.keyEquivalent = "\u{1b}"
        Self.layout([title, help, toolbar, scroll, actions, ecb, explanation, jobs, jobStatus, status, footer], in: window); controls()
    }
    static func ask(_ message: String) -> Bool { let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "編集を続ける"); alert.addButton(withTitle: "変更を破棄"); return alert.runModal() == .alertSecondButtonReturn }
    fileprivate static func layout(_ views: [NSView], in window: NSWindow) {
        let root = NSStackView(views: views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        views.forEach { $0.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded; buttons[title] = value; return value }
    private var isRates: Bool { mode.indexOfSelectedItem == 1 }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func configureColumns() {
        table.tableColumns.forEach(table.removeTableColumn)
        let columns: [(String, String, CGFloat)] = isRates ? [("fromCurrency", "元通貨", 70), ("toCurrency", "換算先", 70), ("rate", "元通貨1単位の換算額", 190), ("source", "登録元", 70), ("effectiveDate", "適用日時", 180), ("updatedAt", "更新日時", 180)] : [("code", "コード", 110), ("name", "名称", 430), ("symbol", "記号", 100), ("isEnabled", "有効", 100), ("isDefault", "既定", 100)]
        for (key, title, width) in columns { let c = NSTableColumn(identifier: .init(key)); c.title = title; c.minWidth = isRates ? width : min(width, 70); c.width = width; c.resizingMask = .userResizingMask; table.addTableColumn(c) }
        table.tableColumns.last?.resizingMask = [.userResizingMask, .autoresizingMask]
    }
    private func fitColumns() {
        window.contentView?.layoutSubtreeIfNeeded()
        if let width = table.enclosingScrollView?.contentView.bounds.width, width > 0 {
            table.setFrameSize(NSSize(width: width, height: table.frame.height)); table.sizeLastColumnToFit(); table.tile()
        }
    }
    private func controls() {
        let idle = !busy && editor == nil && !closed
        mode.isEnabled = idle; search.isEnabled = idle; table.isEnabled = idle
        buttons.values.forEach { $0.isEnabled = idle }; ecb.isEnabled = idle && permitted && allowsECBSettings
        buttons["追加…"]?.isEnabled = idle && permitted
        buttons["有効・無効を切替"]?.isHidden = isRates; buttons["既定の通貨に設定"]?.isHidden = isRates; buttons["レートを編集…"]?.isHidden = !isRates
        buttons["有効・無効を切替"]?.isEnabled = idle && permitted && selected != nil && selected?["isDefault"] != .integer(1)
        buttons["既定の通貨に設定"]?.isEnabled = idle && permitted && selected != nil && selected?["isDefault"] != .integer(1)
        buttons["レートを編集…"]?.isEnabled = idle && permitted && selected != nil && !(settings?.enabled == true && selected?["source"] == .text("ECB"))
        buttons["今すぐECB更新"]?.isEnabled = idle && permitted && allowsECB && settings?.enabled == true
        buttons["更新をキャンセル"]?.isEnabled = idle && permitted && allowsECB && lastJob.map { ["pending", "retry", "failed"].contains($0.status) } == true
        buttons["更新を再試行"]?.isEnabled = idle && permitted && allowsECB && lastJob.map { ["failed", "retry"].contains($0.status) } == true
        buttons["前の100件"]?.isEnabled = idle && offset > 0; buttons["次の100件"]?.isEnabled = idle && offset + rows.count < total
    }
    func start() { load() }
    func confirmDiscard() -> Bool { !busy && (editor?.confirmDiscard() ?? true) }
    private func load(message: String = "通貨は削除せず、有効・無効を切り替えて管理します。") {
        guard !busy, editor == nil, !closed else { return }; busy = true; controls()
        let rates = isRates, offset = offset, text = search.stringValue
        status.stringValue = "読み込んでいます…"; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try api.service.db.transaction { (try rates ? api.rates(offset: offset, search: text) : api.currencies(offset: offset, search: text), try api.settings(), try api.updateJobs().first) } }
            DispatchQueue.main.async { [self] in
                busy = false; guard !closed else { return }
                switch result {
                case let .success((page, config, job)):
                    permitted = true
                    if page.rows.isEmpty && offset > 0 { self.offset = max(0, ((page.total - 1) / 100) * 100); load(message: message); return }
                    rows = page.rows; total = page.total; settings = config; lastJob = job; ecb.state = config.enabled ? .on : .off
                    count.stringValue = "\(total == 0 ? 0 : offset + 1)〜\(offset + rows.count) ／ \(total)件"; status.stringValue = message
                    jobStatus.stringValue = Self.jobText(job)
                case let .failure(error): permitted = false; rows = []; total = 0; self.offset = 0; settings = nil; lastJob = nil; count.stringValue = "—"; jobStatus.stringValue = ""; show(error)
                }
                table.deselectAll(nil); table.reloadData(); fitColumns(); controls()
            }
        }
    }
    private static func jobText(_ job: NativeJob?) -> String {
        guard let job else { return "ECB更新：まだ実行していません。" }
        let title = ["pending": "待機中", "running": "更新中", "retry": "再試行待ち", "failed": "失敗", "done": "完了", "cancelled": "キャンセル済み"][job.status] ?? "状態を確認してください"
        return "ECB更新：\(title)" + (job.result["updated"].map { "（\($0)件）" } ?? "") + (job.result["reason"].map { " — " + $0 } ?? "") + (job.lastError.map { " — " + $0 } ?? "")
    }
    private func show(_ error: Error) { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    private func mutate(_ message: String, _ body: @escaping () throws -> Void) {
        guard !busy, editor == nil, !closed else { return }; busy = true; controls(); status.stringValue = "保存しています…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try body() }
            DispatchQueue.main.async { [self] in
                busy = false; controls()
                switch result { case .success: onChanged?(); load(message: message)
                case let .failure(error): ecb.state = settings?.enabled == true ? .on : .off; show(error) }
            }
        }
    }
    @objc private func modeChanged() { guard !busy, editor == nil else { return }; offset = 0; search.stringValue = ""; configureColumns(); load() }
    @objc private func searchChanged() { guard !busy else { return }; offset = 0; load() }
    @objc private func refresh() { load() }
    @objc private func previous() { guard !busy, offset > 0 else { return }; offset = max(0, offset - 100); load() }
    @objc private func next() { guard !busy, offset + rows.count < total else { return }; offset += 100; load() }
    @objc private func toggle() { guard let row = selected, !isRates else { return }; mutate("通貨の有効状態を保存しました。") { [api] in try api.setEnabled(code: row["code"].string, enabled: row["isEnabled"] != .integer(1), expectedRevision: row.revision, protectDefault: true) } }
    @objc private func makeDefault() { guard let row = selected, !isRates else { return }; mutate("既定の通貨を変更しました。保存済みデータの通貨はそのままです。") { [api] in try api.setDefault(code: row["code"].string, expectedRevision: row.revision) } }
    @objc private func toggleECB() { guard allowsECBSettings else { ecb.state = settings?.enabled == true ? .on : .off; status.stringValue="「機能・連携を再開」からECBの接続設定を確認してください。通貨と手動レートの設定は利用できます。"; return }; guard let settings else { return }; let enabled = ecb.state == .on; mutate(enabled ? "ECBの自動更新を有効にしました。" : "ECBの自動更新を無効にしました。") { [api] in try api.setECBEnabled(enabled, expected: settings) } }
    @objc private func requestUpdate() { guard allowsECB else { status.stringValue="復元したECB接続は確認待ちです。通貨と手動レートの設定は利用できます。"; return }; mutate("ECB更新を予約しました。") { [api] in _ = try api.requestECBUpdate() } }
    @objc private func cancelUpdate() { guard allowsECB else { status.stringValue="復元したECB接続は確認待ちです。通貨と手動レートの設定は利用できます。"; return }; guard let job = lastJob else { return }; mutate("ECB更新をキャンセルしました。") { [api] in try api.cancelUpdate(job) } }
    @objc private func retryUpdate() { guard allowsECB else { status.stringValue="復元したECB接続は確認待ちです。通貨と手動レートの設定は利用できます。"; return }; guard let job = lastJob else { return }; mutate("ECB更新の再試行を予約しました。") { [api] in try api.retryUpdate(job) } }
    @objc private func add() { present(nil) }
    @objc private func editRate() { if isRates, let selected { present(selected) } }
    private func present(_ original: NativeRecord?) {
        guard !busy, editor == nil, permitted else { return }
        do {
            try api.requireAdmin()
            let child = NativeCurrencyAdministrationEditor(api: api, rates: isRates, original: original, confirm: confirm)
            editor = child; controls()
            window.beginSheet(child.window) { [weak self] response in
                guard let self else { return }; self.editor = nil; self.controls()
                if response == .OK { self.onChanged?(); self.load(message: "保存しました。") }
            }
        } catch { show(error) }
    }
    @objc private func close() { guard editor == nil, confirmDiscard() else { return }; closed = true; if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let key = column?.identifier.rawValue else { return nil }
        let value = rows[row][key], text: String
        if ["isEnabled", "isDefault"].contains(key) { text = value == .integer(1) ? "はい" : "—" }
        else if key == "source" { text = value == .text("ECB") ? "ECB" : "手動" }
        else if key.hasSuffix("Date") || key == "updatedAt" { text = value.string.replacingOccurrences(of: "T", with: " ").prefix(19).description + " UTC" }
        else { text = value.string }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail; field.toolTip = text; return field
    }
}

private final class NativeCurrencyAdministrationEditor: NSObject {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeCurrencyAdministration, rates: Bool, original: NativeRecord?, confirm: (String) -> Bool
    private let first = NSTextField(), second = NSTextField(), third = NSTextField(), status = NSTextField(wrappingLabelWithString: "")
    private var initial: [String] = [], busy = false, save: NSButton!, cancel: NSButton!
    init(api: NativeCurrencyAdministration, rates: Bool, original: NativeRecord?, confirm: @escaping (String) -> Bool) {
        self.api = api; self.rates = rates; self.original = original; self.confirm = confirm; super.init()
        window.title = rates ? (original == nil ? "為替レートを追加" : "為替レートを編集") : "通貨を追加"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 20, weight: .semibold)
        var views: [NSView] = [title]
        let labels = rates ? ["元通貨のコード", "換算先のコード", "元通貨1単位の換算額"] : ["通貨コード（3文字）", "通貨の名称", "通貨記号"]
        for (label, field) in zip(labels, [first, second, third]) { field.setAccessibilityLabel(label); views += [NSTextField(labelWithString: label), field] }
        if let original { first.stringValue = original["fromCurrency"].string; second.stringValue = original["toCurrency"].string; third.stringValue = original["rate"].string }
        initial = values
        status.setAccessibilityLabel("通貨編集の操作結果"); status.maximumNumberOfLines = 2
        save = NSButton(title: "保存", target: self, action: #selector(commit)); save.bezelStyle = .rounded; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        cancel = NSButton(title: "キャンセル", target: self, action: #selector(close)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [NSView(), cancel, save]); footer.spacing = 10; views += [NSView(), status, footer]
        NativeCurrencyAdministrationWindow.layout(views, in: window); controls()
    }
    private var values: [String] { [first.stringValue, second.stringValue, third.stringValue] }
    private func controls() { first.isEnabled = !busy && original == nil; second.isEnabled = !busy && original == nil; third.isEnabled = !busy; save.isEnabled = !busy; cancel.isEnabled = !busy }
    func confirmDiscard() -> Bool { guard !busy else { return false }; window.makeFirstResponder(nil); return values == initial || confirm("入力した変更を破棄しますか？") }
    @objc private func close() { if confirmDiscard() { window.sheetParent?.endSheet(window, returnCode: .cancel) } }
    @objc private func commit() {
        guard !busy else { return }; window.makeFirstResponder(nil); let input = values
        busy = true; controls(); status.stringValue = "保存しています…"; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result {
                if rates { _ = try api.saveRate(from: input[0], to: input[1], input: input[2], expected: original, protectAutomatic: true) }
                else { _ = try api.create(code: input[0], name: input[1], symbol: input[2]) }
            }
            DispatchQueue.main.async { [self] in
                busy = false; controls()
                switch result { case .success: window.sheetParent?.endSheet(window, returnCode: .OK)
                case let .failure(error): status.stringValue = error.localizedDescription; status.textColor = .systemRed }
            }
        }
    }
}
