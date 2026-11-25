import AppKit
import Darwin

@main
final class NativeCRMApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow!
    private var store: AccountStore!
    private let table = NSTableView()
    private let search = NSSearchField()
    private let filter = NSPopUpButton()
    private let counter = NSTextField(labelWithString: "読み込み中…")
    private let note = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "前へ", target: nil, action: nil)
    private let next = NSButton(title: "次へ", target: nil, action: nil)
    private let edit = NSButton(title: "編集", target: nil, action: nil)
    private var rows: [Account] = []
    private var currentPage = 0
    private var total = 0
    private var queryVersion = 0
    private var queryWork: DispatchWorkItem?
    private let reads = DispatchQueue(label: "local.nextcrm.native.reads", qos: .userInitiated)
    private var editor: AccountEditor?
    private let number = NumberFormatter()
    private let memoryBudget = MemoryBudget()

    static func main() {
        umask(0o077)
        let app = NSApplication.shared
        let delegate = NativeCRMApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NextCRMNative", isDirectory: true)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { store = try AccountStore(url: support.appendingPathComponent("accounts.sqlite")) }
        catch {
            let alert = NSAlert(); alert.messageText = "取引先データを開けませんでした"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        number.numberStyle = .decimal; number.locale = Locale(identifier: "ja_JP")
        installMenus()
        createWindow()
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        memoryBudget.settle()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let editor, !editor.confirmDiscard() { return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { queryWork?.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { editor?.confirmDiscard() ?? true }

    private func installMenus() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [(String, Selector?, String)]) {
            let top = NSMenuItem(); let sub = NSMenu(title: title); top.submenu = sub; main.addItem(top)
            for (name, action, key) in items {
                if name.isEmpty { sub.addItem(.separator()); continue }
                let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
                sub.addItem(item)
            }
        }
        menu("NextCRM Native", [("NextCRM Nativeについて", #selector(about), ""), ("",nil,""), ("NextCRM Nativeを隠す", #selector(NSApplication.hide(_:)), "h"), ("NextCRM Nativeを終了", #selector(NSApplication.terminate(_:)), "q")])
        menu("ファイル", [("新規取引先", #selector(newAccount), "n"), ("取引先を編集", #selector(editAccount), "e"), ("",nil,""), ("データフォルダを開く", #selector(openData), ""), ("ウインドウを閉じる", #selector(NSWindow.performClose(_:)), "w")])
        menu("編集", [("元に戻す", Selector(("undo:")), "z"), ("やり直す", Selector(("redo:")), "Z"), ("",nil,""), ("切り取り", #selector(NSText.cut(_:)), "x"), ("コピー", #selector(NSText.copy(_:)), "c"), ("貼り付け", #selector(NSText.paste(_:)), "v"), ("すべて選択", #selector(NSText.selectAll(_:)), "a"), ("検索", #selector(focusSearch), "f")])
        menu("表示", [("再読み込み", #selector(refresh), "r")])
        menu("ヘルプ", [("使い方", #selector(openGuide), "")])
        NSApp.mainMenu = main
    }
    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "NextCRM Native — 取引先"; window.minSize = NSSize(width: 900, height: 550)
        window.setFrameAutosaveName("NextCRMNativeAccounts"); window.center(); window.delegate = self
        let title = NSTextField(labelWithString: "取引先"); title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(labelWithString: "顧客・企業情報をまとめて管理"); subtitle.textColor = .secondaryLabelColor; subtitle.font = .systemFont(ofSize: 13)
        let heading = NSStackView(views: [title, subtitle]); heading.orientation = .vertical; heading.alignment = .leading; heading.spacing = 5
        let local = NSTextField(labelWithString: "このMacに保存"); local.textColor = .secondaryLabelColor; local.font = .systemFont(ofSize: 12)
        let spacer = NSView()
        let header = NSStackView(views: [heading, spacer, local]); header.alignment = .centerY
        search.placeholderString = "会社名・メール・電話で検索"; search.delegate = self
        search.setAccessibilityLabel("取引先を検索"); search.identifier = NSUserInterfaceItemIdentifier("account-search")
        search.sendsSearchStringImmediately = true; search.sendsWholeSearchString = false
        filter.addItems(withTitles: ["すべての状態", "有効", "無効"]); filter.target = self; filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("状態で絞り込み")
        let create = NSButton(title: "新規取引先", target: self, action: #selector(newAccount)); create.bezelStyle = .rounded
        create.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil); create.imagePosition = .imageLeading
        create.contentTintColor = .controlAccentColor
        let toolbar = NSStackView(views: [search, filter, create]); toolbar.spacing = 12
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filter.setContentHuggingPriority(.required, for: .horizontal); create.setContentHuggingPriority(.required, for: .horizontal)
        table.delegate = self; table.dataSource = self; table.style = .inset; table.rowHeight = 40
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(editAccount); table.setAccessibilityLabel("取引先一覧")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("summary"))
        column.width = 1000; column.minWidth = 600; table.addTableColumn(column); table.headerView = nil
        let columnHeader = LightweightTableCell()
        columnHeader.horizontalInset = 16
        columnHeader.configure(columns: NativeColumn.accounts, values: NativeColumn.accounts.map(\.title), heading: true)
        columnHeader.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let listing = NSStackView(views: [columnHeader, scroll]); listing.orientation = .vertical; listing.alignment = .leading; listing.spacing = 4
        columnHeader.widthAnchor.constraint(equalTo: listing.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: listing.widthAnchor).isActive = true
        counter.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); counter.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        previous.target = self; previous.action = #selector(previousPage); previous.bezelStyle = .rounded
        next.target = self; next.action = #selector(nextPage); next.bezelStyle = .rounded
        edit.target = self; edit.action = #selector(editAccount); edit.bezelStyle = .rounded; edit.isEnabled = false
        let footerSpacer = NSView()
        let footer = NSStackView(views: [counter, footerSpacer, previous, next, edit]); footer.spacing = 10
        let stack = NSStackView(views: [header, toolbar, listing, note, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listing.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }
    private func formatted(_ count: Int) -> String { number.string(from: NSNumber(value: count)) ?? String(count) }
    private func reload(reset: Bool = false, delay: Double = 0, selectID: String? = nil) {
        if reset { currentPage = 0 }
        queryWork?.cancel(); queryVersion += 1
        let version = queryVersion; let term = search.stringValue
        let status = filter.indexOfSelectedItem == 1 ? "Active" : filter.indexOfSelectedItem == 2 ? "Inactive" : ""
        let page = currentPage
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let result = try self.store.page(search: term, status: status, index: page)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queryVersion == version else { return }
                    self.rows = result.rows; self.total = result.total; self.currentPage = result.page
                    self.table.reloadData()
                    if let selectID, let index = self.rows.firstIndex(where: { $0.id == selectID }) {
                        self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    }
                    self.previous.isEnabled = result.page > 0
                    self.next.isEnabled = (result.page + 1) * result.pageSize < result.total
                    let start = result.total == 0 ? 0 : result.page * result.pageSize + 1
                    let end = min(result.total, (result.page + 1) * result.pageSize)
                    self.counter.stringValue = "\(self.formatted(start))–\(self.formatted(end)) ／ \(self.formatted(result.total))件"
                    self.note.stringValue = result.total == 0 ? (term.isEmpty && status.isEmpty ? "「新規取引先」から、最初の取引先を登録できます。" : "条件に一致する取引先はありません。") : "取引先をダブルクリックすると編集できます。"
                    self.edit.isEnabled = self.table.selectedRow >= 0
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.queryVersion == version else { return }
                    self.showError(error)
                }
            }
        }
        queryWork = work; reads.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func controlTextDidChange(_ notification: Notification) { reload(reset: true, delay: 0.18) }
    @objc private func filterChanged() { reload(reset: true) }
    @objc private func previousPage() { currentPage = max(0, currentPage - 1); reload() }
    @objc private func nextPage() { if (currentPage + 1) * AccountStore.pageSize < total { currentPage += 1; reload() } }
    @objc private func refresh() { reload() }
    @objc private func focusSearch() { window.makeFirstResponder(search) }
    @objc private func openData() { NSWorkspace.shared.open(support) }
    @objc private func openGuide() { if let url = Bundle.main.url(forResource: "使い方", withExtension: "txt") { NSWorkspace.shared.open(url) } }
    @objc private func about() {
        let alert = NSAlert(); alert.messageText = "NextCRM Native"; alert.informativeText = "取引先管理のネイティブ版 0.1\n\n一覧・検索・登録・編集・保存\nNextCRM © Pavel Dovhomilja — MIT License"
        alert.beginSheetModal(for: window)
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "操作を完了できませんでした"; alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
    @objc private func newAccount() { openEditor(Account()) }
    @objc private func editAccount() {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        do { if let account = try store.get(rows[table.selectedRow].id) { openEditor(account) } }
        catch { showError(error) }
    }
    private func openEditor(_ account: Account) {
        guard editor == nil else { return }
        let controller = AccountEditor(account: account, store: store)
        editor = controller
        window.beginSheet(controller.window) { [weak self, weak controller] _ in
            guard let self else { return }
            let saved = controller?.savedAccount
            self.editor = nil
            self.memoryBudget.settle()
            if let saved {
                self.reload(selectID: saved.id)
                self.note.stringValue = "「\(saved.name)」を保存しました。"
            }
        }
        controller.focusName()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        edit.isEnabled = table.selectedRow >= 0
        table.enumerateAvailableRowViews { view, _ in view.subviews.forEach { $0.needsDisplay = true } }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let identifier = tableColumn.identifier
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LightweightTableCell ?? LightweightTableCell()
        cell.identifier = identifier
        let item = rows[row]
        cell.configure(columns: NativeColumn.accounts, values: [item.name, item.owner, item.email, item.phone, item.statusLabel],
                       positiveColumn: item.status.lowercased() == "active" ? 4 : nil)
        return cell
    }
}

final class AccountEditor: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let store: AccountStore
    private let original: Account
    private var fields: [String: NSTextField] = [:]
    private let status = NSPopUpButton()
    private var statusValues = ["Active", "Inactive"]
    private let notes = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    var savedAccount: Account?

    init(account: Account, store: AccountStore) {
        original = account; self.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = account.revision == 0 ? "新しい取引先" : "取引先の編集"; window.delegate = self
        let heading = NSTextField(labelWithString: window.title); heading.font = .systemFont(ofSize: 21, weight: .semibold)
        var gridRows: [[NSView]] = []
        func field(_ key: String, _ label: String, _ value: String, _ placeholder: String = "") {
            let control = NSTextField(string: value); control.placeholderString = placeholder
            control.setAccessibilityLabel(label); control.identifier = NSUserInterfaceItemIdentifier(key)
            fields[key] = control
            let title = NSTextField(labelWithString: label); title.textColor = .secondaryLabelColor
            gridRows.append([title, control])
        }
        field("name", "会社名（必須）", account.name, "例：山田商事株式会社")
        field("email", "メール", account.email, "contact@example.jp")
        field("phone", "電話番号", account.phone, "03-1234-5678")
        field("website", "Webサイト", account.website, "https://")
        status.addItems(withTitles: ["有効", "無効"])
        if let index = statusValues.firstIndex(where: { $0.lowercased() == account.status.lowercased() }) { status.selectItem(at: index) }
        else { statusValues.append(account.status); status.addItem(withTitle: account.statusLabel); status.selectItem(at: 2) }
        status.setAccessibilityLabel("取引先の状態")
        gridRows.append([NSTextField(labelWithString: "状態"), status])
        field("industry", "業種", account.industry)
        field("postal", "郵便番号", account.postalCode)
        field("prefecture", "都道府県", account.prefecture)
        field("city", "市区町村", account.city)
        field("street", "番地・建物", account.street)
        field("country", "国・地域", account.country)
        let owner = NSTextField(labelWithString: account.owner.isEmpty ? "未割り当て" : account.owner)
        gridRows.append([NSTextField(labelWithString: "担当者"), owner])
        notes.string = account.notes; notes.font = .systemFont(ofSize: 13); notes.isRichText = false; notes.allowsUndo = true
        notes.isAutomaticQuoteSubstitutionEnabled = false; notes.isAutomaticDashSubstitutionEnabled = false
        notes.textContainerInset = NSSize(width: 5, height: 5); notes.setAccessibilityLabel("メモ")
        let scroll = NSScrollView(); scroll.documentView = notes; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        notes.minSize = NSSize(width: 0, height: 72); notes.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        notes.isVerticallyResizable = true; notes.isHorizontallyResizable = false; notes.autoresizingMask = [.width]
        notes.textContainer?.widthTracksTextView = true
        gridRows.append([NSTextField(labelWithString: "メモ"), scroll])
        let grid = NSGridView(views: gridRows); grid.rowSpacing = 9; grid.columnSpacing = 18
        grid.column(at: 0).width = 112; grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill; grid.yPlacement = .center
        let cancel = NSButton(title: "キャンセル", target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(save)); save.bezelStyle = .rounded
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        save.contentTintColor = .controlAccentColor
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        let buttons = NSStackView(views: [NSView(), cancel, save]); buttons.spacing = 10
        let stack = NSStackView(views: [heading, grid, errorLabel, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor), errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    func focusName() { if let name = fields["name"] { window.makeFirstResponder(name) } }
    private func draft() -> Account {
        var row = original
        row.name = fields["name"]!.stringValue; row.email = fields["email"]!.stringValue; row.phone = fields["phone"]!.stringValue
        row.website = fields["website"]!.stringValue; row.industry = fields["industry"]!.stringValue
        row.postalCode = fields["postal"]!.stringValue; row.prefecture = fields["prefecture"]!.stringValue
        row.city = fields["city"]!.stringValue; row.street = fields["street"]!.stringValue; row.country = fields["country"]!.stringValue
        row.notes = notes.string; row.status = statusValues[status.indexOfSelectedItem]
        return row
    }
    func confirmDiscard() -> Bool {
        window.makeFirstResponder(nil)
        guard draft() != original else { return true }
        let alert = NSAlert(); alert.messageText = "変更を保存せずに閉じますか？"; alert.informativeText = "編集中の内容は保存されません。"
        alert.addButton(withTitle: "編集を続ける"); alert.addButton(withTitle: "変更を破棄")
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel() { if confirmDiscard() { window.sheetParent?.endSheet(window, returnCode: .cancel) } }
    @objc private func save() {
        window.makeFirstResponder(nil)
        do { savedAccount = try store.save(draft()); window.sheetParent?.endSheet(window, returnCode: .OK) }
        catch { errorLabel.stringValue = error.localizedDescription }
    }
}
