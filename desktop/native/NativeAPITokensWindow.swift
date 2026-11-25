import AppKit

final class NativeAPITokensWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
    private let store: NativeAPITokens
    private let name = NSTextField(), expiry = NSDatePicker(), table = NSTableView(), filter = NSPopUpButton()
    private let useExpiry = NSButton(checkboxWithTitle: "有効期限を設定", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: ""), count = NSTextField(labelWithString: "")
    private var rows: [NativeAPITokenRow] = [], offset = 0, total = 0, busy = false, closed = false
    private var create: NSButton!, revoke: NSButton!, previous: NSButton!, next: NSButton!, refresh: NSButton!, closeButton: NSButton!
    private let columns = [NativeColumn(title: "名称", fraction: 0.20), NativeColumn(title: "接頭辞", fraction: 0.19), NativeColumn(title: "作成", fraction: 0.16), NativeColumn(title: "有効期限", fraction: 0.19), NativeColumn(title: "最終利用", fraction: 0.16), NativeColumn(title: "状態", fraction: 0.10)]
    private let dateFormat: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"; return f }()

    init(store: NativeAPITokens) throws {
        try store.service.authenticated(); self.store = store
        super.init(); window.title = "APIトークン"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "外部ツールに渡す、自分専用の接続用トークンを管理します。有効なトークンは10個までです。トークンを持つ相手は、あなたの権限でCRMを操作できます。")
        name.placeholderString = "接続名（例：Claude Desktop）"; name.setAccessibilityLabel("トークン名")
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        useExpiry.target = self; useExpiry.action = #selector(expiryChanged)
        expiry.datePickerStyle = .textFieldAndStepper; expiry.datePickerElements = [.yearMonthDay, .hourMinute]
        expiry.locale = Locale(identifier: "ja_JP"); expiry.timeZone = .current
        expiry.dateValue = Date().addingTimeInterval(30 * 86400); expiry.isEnabled = false; expiry.setAccessibilityLabel("トークンの有効期限")
        create = button("作成", #selector(issue)); create.keyEquivalent = "s"; create.keyEquivalentModifierMask = .command
        let form = NSStackView(views: [name, useExpiry, expiry, create]); form.spacing = 8
        filter.addItems(withTitles: ["有効なトークン", "すべて（失効・期限切れを含む）"]); filter.target = self; filter.action = #selector(filterChanged); filter.setAccessibilityLabel("トークンの表示範囲")
        let header = LightweightTableCell(); header.configure(columns: columns, values: columns.map(\.title), heading: true); header.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let column = NSTableColumn(identifier: .init("token")); column.width = 860; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 34; table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = false; table.setAccessibilityLabel("APIトークンの一覧")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        revoke = button("選択したトークンを失効…", #selector(remove)); refresh = button("再読み込み", #selector(reloadAction))
        let actions = NSStackView(views: [revoke, refresh, NSView()]); actions.spacing = 8
        previous = button("前の100件", #selector(previousPage)); next = button("次の100件", #selector(nextPage)); closeButton = button("閉じる", #selector(close)); closeButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [previous, count, next, NSView(), closeButton]); footer.spacing = 8
        status.maximumNumberOfLines = 2; status.setAccessibilityLabel("APIトークンの操作結果")
        let views: [NSView] = [title, help, form, filter, header, scroll, actions, status, footer]
        let root = NSStackView(views: views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        for view in views { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        controls()
    }
    func start() { reload() }
    private func button(_ title: String, _ selector: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: selector); b.bezelStyle = .rounded; return b }
    private var selected: NativeAPITokenRow? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func controls() {
        for control: NSControl in [name, useExpiry, filter, refresh, closeButton] { control.isEnabled = !busy }
        create.isEnabled = !busy && store.service.identity.role != "partner"
        expiry.isEnabled = !busy && useExpiry.state == .on
        revoke.isEnabled = !busy && selected.map { $0.revokedAt == nil } == true
        previous.isEnabled = !busy && offset > 0; next.isEnabled = !busy && offset + rows.count < total
    }
    private func show(_ error: Error) { status.textColor = .systemRed; status.stringValue = error.localizedDescription }
    @objc private func expiryChanged() { controls() }
    @objc private func filterChanged() { offset = 0; reload() }
    @objc private func previousPage() { offset = max(0, offset - 100); reload() }
    @objc private func nextPage() { offset += 100; reload() }
    @objc private func reloadAction() { reload() }
    private func reload(message: String = "トークンの全文は作成時に一度だけ表示します。") {
        guard !busy, !closed else { return }; busy = true; controls()
        let offset = offset, active = filter.indexOfSelectedItem == 0
        status.textColor = .secondaryLabelColor; status.stringValue = "読み込んでいます…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try store.list(offset: offset, activeOnly: active) }
            DispatchQueue.main.async { [self] in
                busy = false; guard !closed else { return }
                switch result {
                case let .success(page):
                    if page.rows.isEmpty && offset > 0 { self.offset = max(0, ((page.total - 1) / 100) * 100); reload(message: message); return }
                    rows = page.rows; total = page.total; table.reloadData(); count.stringValue = "\(total == 0 ? 0 : offset + 1)〜\(offset + rows.count) ／ \(total)件"; status.stringValue = message
                case let .failure(error):
                    rows = []; total = 0; self.offset = 0; count.stringValue = "—"
                    table.reloadData(); show(error)
                }
                controls()
            }
        }
    }
    @objc private func issue() {
        guard !busy else { return }
        let text = name.stringValue, expiresAt = useExpiry.state == .on ? expiry.dateValue : nil
        if let expiresAt, expiresAt <= Date() { show(NativeAPITokenError.expiry); return }
        busy = true; controls(); status.stringValue = "作成しています…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try store.issue(name: text, expiresAt: expiresAt) }
            DispatchQueue.main.async { [self] in
                busy = false
                switch result {
                case let .success(issued):
                    name.stringValue = ""; controls(); reveal(issued.rawToken)
                case let .failure(error): controls(); show(error)
                }
            }
        }
    }
    private func reveal(_ raw: String, copyFailed: Bool = false) {
        #if RESTORE_PARENT_TESTING
        if suppressRevealForTesting{return}
        #endif
        let alert = NSAlert(); alert.messageText = "トークンを作成しました"
        alert.informativeText = (copyFailed ? "コピーできませんでした。もう一度お試しください。\n" : "") + "今すぐコピーして保管してください。閉じるとトークンの全文は再表示できません。"
        let value = NSTextField(labelWithString: raw); value.font = .monospacedSystemFont(ofSize: 12, weight: .regular); value.isSelectable = true; value.frame = NSRect(x: 0, y: 0, width: 500, height: 44); value.maximumNumberOfLines = 2; value.lineBreakMode = .byCharWrapping; value.setAccessibilityLabel("作成したAPIトークン")
        alert.accessoryView = value; alert.addButton(withTitle: "コピーして閉じる"); alert.addButton(withTitle: "コピーせず閉じる")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                if !NSPasteboard.general.setString(value.stringValue, forType: .string) {
                    let retry = value.stringValue; value.stringValue = ""
                    DispatchQueue.main.async { [weak self] in self?.reveal(retry, copyFailed: true) }; return
                }
            }
            value.stringValue = ""; self?.offset = 0; self?.reload(message: "トークンを作成しました。不要になったら失効してください。")
        }
    }
    @objc private func remove() {
        guard !busy, let row = selected else { return }
        let alert = NSAlert(); alert.messageText = "APIトークンを失効しますか？"; alert.informativeText = "「\(row.name)」を使う接続は利用できなくなります。この操作は取り消せません。"; alert.addButton(withTitle: "失効"); alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.busy = true; self.controls()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = Result { try self.store.revoke(id: row.id) }
                DispatchQueue.main.async { [self] in
                    self.busy = false
                    switch result { case .success: self.reload(message: "トークンを失効しました。"); case let .failure(error): self.controls(); self.show(error) }
                }
            }
        }
    }
    @objc private func close() { guard !busy else { return }; closed = true; rows = []; table.reloadData(); window.sheetParent?.endSheet(window); window.orderOut(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let value = rows[row]
        let state = value.revokedAt != nil ? "失効済み" : value.active(at: Date()) ? "有効" : "期限切れ"
        let id = NSUserInterfaceItemIdentifier("apiToken"), cell = tableView.makeView(withIdentifier: id, owner: self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        cell.configure(columns: columns, values: [value.name, "nxtc__" + value.prefix + "…", dateFormat.string(from: value.createdAt), value.expiresAt.map(dateFormat.string) ?? "無期限", value.lastUsedAt.map(dateFormat.string) ?? "未使用", state]); return cell
    }
    func confirmDiscard()->Bool {!busy && window.attachedSheet == nil}

    #if RESTORE_PARENT_TESTING
    private var suppressRevealForTesting=false
    func issueForTesting(){suppressRevealForTesting=true;name.stringValue="隔離検証";issue()}
    var busyForTesting:Bool {busy}
    #endif

}
