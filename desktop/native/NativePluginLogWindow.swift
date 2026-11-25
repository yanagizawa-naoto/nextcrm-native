import AppKit

final class NativePluginLogWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
    private let admin: NativePluginsAdmin, id: String
    private let table = NSTableView(), status = NSTextField(labelWithString: "")
    private var back: NSButton!, next: NSButton!, refresh: NSButton!
    private var rows: [NativePluginsAdmin.LogEntry] = [], offset = 0, total = 0, busy = false, closed = false
    private var operation: Task<Void, Never>?
    init(admin: NativePluginsAdmin, id: String, name: String) {
        self.admin = admin; self.id = id; super.init(); window.title = name + " — ログ"
        table.dataSource = self; table.delegate = self; table.rowHeight = 42; table.setAccessibilityLabel("連携のログ")
        for (name, title, width) in [("date", "日時（UTC）", 155.0), ("level", "種類", 65.0), ("message", "内容", 560.0)] {
            let c = NSTableColumn(identifier: .init(name)); c.title = title; c.width = width; table.addTableColumn(c)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        back = NSButton(title: "前へ", target: self, action: #selector(previous)); next = NSButton(title: "次へ", target: self, action: #selector(forward)); refresh = NSButton(title: "再読み込み", target: self, action: #selector(reload))
        let close = NSButton(title: "閉じる", target: self, action: #selector(close)); close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [status, NSView(), refresh, back, next, close]); footer.spacing = 8
        let root = NSStackView(views: [scroll, footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20), scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 420), footer.widthAnchor.constraint(equalTo: root.widthAnchor)])
    }
    deinit { operation?.cancel() }
    func start() { load() }
    private func load() {
        guard !busy, !closed else { return }; busy = true; back.isEnabled = false; next.isEnabled = false; refresh.isEnabled = false; status.stringValue = "読み込んでいます…"
        let admin = admin, id = id, offset = offset
        operation = Task.detached { [weak self] in
            let result = Result { try admin.logs(id, offset: offset) }
            await MainActor.run { [weak self] in
                guard let self, !self.closed else { return }; self.busy = false; self.operation = nil; self.refresh.isEnabled = true
                switch result {
                case let .success(page): self.rows = page.rows; self.total = page.total; self.status.stringValue = "\(offset + (page.rows.isEmpty ? 0 : 1))–\(offset + page.rows.count) ／ \(page.total)件"
                case let .failure(error): self.rows = []; self.total = 0; self.offset = 0; self.status.stringValue = NativePluginsAdmin.errorMessage(error)
                }
                self.table.reloadData(); self.back.isEnabled = self.offset > 0; self.next.isEnabled = self.offset + self.rows.count < self.total
            }
        }
    }
    @objc private func previous() { guard !busy else { return }; offset = max(0, offset - 100); load() }
    @objc private func forward() { guard !busy else { return }; offset += 100; load() }
    @objc private func reload() { guard !busy else { return }; offset = 0; load() }
    @objc private func close() { closed = true; operation?.cancel(); if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let value = rows[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "date": text = value.date.replacingOccurrences(of: "T", with: " ").prefix(19).description
        case "level": text = ["debug": "詳細", "info": "情報", "warn": "注意", "error": "エラー"][value.level] ?? value.level
        default: text = value.message
        }
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: 11); label.maximumNumberOfLines = 2; label.toolTip = text; label.setAccessibilityValue(text); return label
    }
}
