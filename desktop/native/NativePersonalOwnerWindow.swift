import AppKit

/// Selects an existing business identity only. No credential input, session
/// issuance, role change, binding or default selection occurs in this window.
@MainActor final class NativePersonalOwnerWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    var onFinished: ((NativePersonalWorkspace.Selection?) -> Void)?
    private let db: NativeDatabase
    private let authorizeRead: () throws -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let count = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let previous = NSButton(title: "前の100件", target: nil, action: nil)
    private let next = NSButton(title: "次の100件", target: nil, action: nil)
    private let choose = NSButton(title: "この利用者を選ぶ", target: nil, action: nil)
    private var rows: [NativePersonalWorkspace.Owner] = []
    private var total = 0
    private var offset = 0
    private var finished = false
    private var permitted = false
    init(db: NativeDatabase, authorizeRead: @escaping () throws -> Void) {
        self.db = db; self.authorizeRead = authorizeRead
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 730, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "このMacで使う利用者"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 630, height: 440); window.delegate = self
        let intro = NSTextField(wrappingLabelWithString: "取り込んだデータの中から、自分として使う利用者を選んでください。過去の担当者・履歴・権限は変更しません。復元内容の確認中は、まだ保存しません。")
        intro.setContentCompressionResistancePriority(.required, for: .vertical)
        search.placeholderString = "名前・メールアドレスで検索"; search.target = self; search.action = #selector(searchChanged)
        search.sendsWholeSearchString = true; search.sendsSearchStringImmediately = false
        for (key, title, width) in [("name", "名前", 230.0), ("email", "メールアドレス", 300.0), ("role", "権限", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 26
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        choose.target = self; choose.action = #selector(selectOwner)
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancelSelection)); cancel.keyEquivalent = "\u{1b}"
        let pager = NSStackView(views: [previous, count, next]); pager.orientation = .horizontal; pager.spacing = 12
        let footer = NSStackView(views: [cancel, choose]); footer.orientation = .horizontal; footer.spacing = 12
        status.textColor = .secondaryLabelColor
        let root = NSView(); window.contentView = root
        [intro, search, scroll, pager, status, footer].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 18), intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18), intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            search.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12), search.leadingAnchor.constraint(equalTo: intro.leadingAnchor), search.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), scroll.leadingAnchor.constraint(equalTo: intro.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            pager.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10), pager.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
            status.topAnchor.constraint(equalTo: pager.bottomAnchor, constant: 10), status.leadingAnchor.constraint(equalTo: intro.leadingAnchor), status.trailingAnchor.constraint(equalTo: intro.trailingAnchor),
            footer.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12), footer.trailingAnchor.constraint(equalTo: intro.trailingAnchor), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170)
        ])
        reload()
    }
    func start(parent: NSWindow? = nil) {
        guard !finished else { return }
        if let parent { parent.beginSheet(window) } else { window.center(); window.makeKeyAndOrderFront(nil) }
    }
    private func reload() {
        guard !finished else { return }
        do {
            try authorizeRead()
            let page = try NativePersonalWorkspace.owners(db, search: search.stringValue, offset: offset)
            rows = page.rows; total = page.total; permitted = true
            status.stringValue = total == 0 ? "選べる有効な利用者がいません。履歴や権限は変更していません。" : "利用者を選択し、内容を確認してから進んでください。"
        } catch { rows = []; total = 0; permitted = false; status.stringValue = error.localizedDescription }
        table.deselectAll(nil); table.reloadData()
        count.stringValue = "\(total == 0 ? 0 : offset + 1)〜\(offset + rows.count) / \(total) 件"
        controls()
    }
    private func controls() {
        previous.isEnabled = !finished && permitted && offset > 0
        next.isEnabled = !finished && permitted && offset + rows.count < total
        choose.isEnabled = !finished && permitted && rows.indices.contains(table.selectedRow)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let key = column?.identifier.rawValue else { return nil }
        let owner = rows[row]
        let text = key == "name" ? owner.name : key == "email" ? owner.email : ["admin": "管理者", "manager": "マネージャー", "user": "一般ユーザー", "partner": "パートナー"][owner.role] ?? owner.role
        let label = NSTextField(labelWithString: text.isEmpty ? "—" : text); label.lineBreakMode = .byTruncatingTail; label.toolTip = text; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { controls() }
    @objc private func searchChanged() { offset = 0; reload() }
    @objc private func previousPage() { offset = max(0, offset - 100); reload() }
    @objc private func nextPage() { guard offset <= Int(Int32.max) - 200 else { return }; offset += 100; reload() }
    @objc private func selectOwner() {
        guard !finished, rows.indices.contains(table.selectedRow) else { return }
        do { try authorizeRead(); let selection = try NativePersonalWorkspace.select(db, userID: rows[table.selectedRow].id); complete(selection) }
        catch { status.stringValue = error.localizedDescription; choose.isEnabled = false }
    }
    @objc private func cancelSelection() { complete(nil) }
    private func complete(_ selection: NativePersonalWorkspace.Selection?) {
        guard !finished else { return }; finished = true; controls()
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil); window.close()
        let callback = onFinished; onFinished = nil; callback?(selection)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { complete(nil); return false }
    func windowWillClose(_ notification: Notification) { if !finished { complete(nil) } }
#if PERSONAL_OWNER_TEST
    func testSelect(_ index: Int) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); controls() }
    func testSearch(_ value: String) { search.stringValue = value; searchChanged() }
    func testNext() { next.performClick(nil) }
    func testChoose() { choose.performClick(nil) }
    func testCancel() { cancelSelection() }
    var testState: (rows: Int, total: Int, choose: Bool, previous: Bool, next: Bool, status: String, selected: Int) { (rows.count, total, choose.isEnabled, previous.isEnabled, next.isEnabled, status.stringValue, table.selectedRow) }
#endif
}
