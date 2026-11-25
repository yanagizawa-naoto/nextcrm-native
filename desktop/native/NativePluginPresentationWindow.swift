import AppKit

/// One recycled table displays the selected section; no view is allocated for
/// every synchronized customer, invoice or log row.
final class NativePluginPresentationWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
    private let load: () throws -> NativePluginPresentation?
    private let authorize: () throws -> Void
    private let heading = NSTextField(labelWithString: "連携の状況"), picker = NSPopUpButton(), table = NSTableView(), status = NSTextField(wrappingLabelWithString: "")
    private var refreshButton: NSButton!, openButton: NSButton!, copyButton: NSButton!
    private let destinationPicker = NSPopUpButton()
    private var presentation: NativePluginPresentation?, operation: Task<Void, Never>?, busy = false, closed = false
    var onOpenRecord: ((NativePluginPresentation.RecordTarget) throws -> Void)?
    init(title: String, authorize: @escaping () throws -> Void, load: @escaping () throws -> NativePluginPresentation?) {
        self.authorize = authorize; self.load = load; super.init(); window.title = title; heading.stringValue = title
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        picker.target = self; picker.action = #selector(changeSection); picker.setAccessibilityLabel("連携情報の種類")
        table.dataSource = self; table.delegate = self; table.rowHeight = 42; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("連携の状況"); table.target = self; table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        refreshButton = button("再読み込み", #selector(refresh)); openButton = button("情報を開く", #selector(openSelected)); copyButton = button("コピー", #selector(copySelected))
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        destinationPicker.setAccessibilityLabel("開く情報を選択")
        destinationPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        destinationPicker.cell?.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [refreshButton, NSView(), destinationPicker, copyButton, openButton, close]); footer.spacing = 8
        let root = NSStackView(views: [heading, picker, scroll, status, footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20), picker.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 400), status.widthAnchor.constraint(equalTo: root.widthAnchor), footer.widthAnchor.constraint(equalTo: root.widthAnchor)])
        status.maximumNumberOfLines = 2; status.setAccessibilityLabel("連携情報の読み込み結果"); updateButtons()
    }
    deinit { operation?.cancel() }
    func start() { refresh() }
    func dismissForNavigation() { close() }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
    private var section: NativePluginPresentation.Section? {
        guard let sections = presentation?.sections, sections.indices.contains(picker.indexOfSelectedItem) else { return nil }; return sections[picker.indexOfSelectedItem]
    }
    private var selected: [NativePluginPresentation.Cell]? {
        guard let rows = section?.rows, rows.indices.contains(table.selectedRow) else { return nil }; return rows[table.selectedRow]
    }
    private func updateButtons() {
        refreshButton?.isEnabled = !busy; picker.isEnabled = !busy && presentation?.sections.isEmpty == false
        copyButton?.isEnabled = !busy && selected != nil
        let links = destinations
        destinationPicker.removeAllItems()
        for (index, cell) in links.enumerated() {
            // Distinct menu items preserve even equally named destinations.
            let item = NSMenuItem(title: cell.text, action: nil, keyEquivalent: ""); item.tag = index
            destinationPicker.menu?.addItem(item)
        }
        if !links.isEmpty { destinationPicker.selectItem(at: 0) }
        destinationPicker.isHidden = links.count <= 1; destinationPicker.isEnabled = !busy
        openButton?.isEnabled = !busy && !links.isEmpty
    }
    private var destinations: [NativePluginPresentation.Cell] {
        (selected ?? []).filter { ($0.record != nil && onOpenRecord != nil) || Self.safeURL($0.url) != nil }
    }
    private static func safeURL(_ url: URL?) -> URL? {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }; return url
    }
    @objc private func refresh() {
        guard !busy, !closed else { return }; busy = true; updateButtons(); status.stringValue = "読み込んでいます…"; status.textColor = .secondaryLabelColor
        let load = load, authorize = authorize, oldTitle = picker.titleOfSelectedItem
        operation = Task.detached { [weak self] in
            let result = Result { try authorize(); let result = try load(); try Task.checkCancellation(); try authorize(); return result }
            await MainActor.run { [weak self] in
                guard let self, !self.closed else { return }; self.operation = nil; self.busy = false
                switch result {
                case let .success(value):
                    self.presentation = value; self.heading.stringValue = value?.title ?? self.window.title; self.picker.removeAllItems()
                    self.picker.addItems(withTitles: value?.sections.map(\.title) ?? [])
                    if let oldTitle { self.picker.selectItem(withTitle: oldTitle) }; self.changeSection()
                case let .failure(error):
                    self.presentation = nil; self.picker.removeAllItems(); self.table.reloadData(); self.status.stringValue = NativePluginsAdmin.errorMessage(error); self.status.textColor = .systemRed; self.updateButtons()
                }
            }
        }
    }
    @objc private func changeSection() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        let columns = section?.columns ?? []
        for (index, title) in columns.enumerated() {
            let column = NSTableColumn(identifier: .init(String(index))); column.title = title
            column.width = max(130, 860 / CGFloat(max(1, columns.count))); column.minWidth = 80; table.addTableColumn(column)
        }
        table.reloadData(); table.deselectAll(nil)
        status.stringValue = section.map { $0.rows.isEmpty ? $0.empty : "\($0.rows.count)件" } ?? "現在利用できる連携情報はありません。"
        status.textColor = .secondaryLabelColor; updateButtons()
    }
    @objc private func copySelected() {
        guard !busy, let selected else { return }
        do { try authorize(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.map(\.text).joined(separator: "\t"), forType: .string) }
        catch { status.stringValue = NativePluginsAdmin.errorMessage(error); status.textColor = .systemRed }
    }
    @objc private func openSelected() {
        let links = destinations
        let index = links.count > 1 ? destinationPicker.indexOfSelectedItem : 0
        guard !busy, links.indices.contains(index) else { return }
        do {
            try authorize()
            let cell = links[index]
            if let target = cell.record, let onOpenRecord { try onOpenRecord(target); return }
            if let url = Self.safeURL(cell.url), !NSWorkspace.shared.open(url) { status.stringValue = "リンクを開けませんでした。" }
        } catch { status.stringValue = NativePluginsAdmin.errorMessage(error); status.textColor = .systemRed }
    }
    @objc private func close() { closed = true; operation?.cancel(); if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() } }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func numberOfRows(in tableView: NSTableView) -> Int { section?.rows.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let rows = section?.rows, rows.indices.contains(row), let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }), rows[row].indices.contains(column) else { return nil }
        let id = NSUserInterfaceItemIdentifier("pluginStatusValue")
        let label = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(wrappingLabelWithString: "")
        label.identifier = id; label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; label.stringValue = rows[row][column].text
        label.toolTip = label.stringValue; label.setAccessibilityValue(label.stringValue); return label
    }
}
