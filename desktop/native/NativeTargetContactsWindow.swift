import AppKit

final class NativeTargetAcquiredContactsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
    private let contacts: [NativeTargetAgentOutput.Contact], requireAccess: () throws -> Void
    private let table = NSTableView(), page = NSTextField(labelWithString: ""), message = NativeEnrichmentUI.label("")
    private var offset = 0, previous: NSButton!, next: NSButton!, source: NSButton!, accessible = true
    private let openURL: (URL) -> Void
    init(contacts: [NativeTargetAgentOutput.Contact], requireAccess: @escaping () throws -> Void, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.contacts = contacts; self.requireAccess = requireAccess; self.openURL = openURL; super.init(); window.title = "取得した担当者"
        table.dataSource = self; table.delegate = self
        let list = NativeEnrichmentUI.table(table, label: "取得した担当者一覧", columns: [("name", "氏名", 130), ("title", "役職", 130), ("email", "メール", 180), ("phone", "電話", 100), ("linkedin", "LinkedIn", 220), ("source", "出典", 190)], height: 300)
        previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward)); source = button("出典を開く", #selector(openSource))
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        NativeEnrichmentUI.layout(window, [NativeEnrichmentUI.label(window.title, title: true), NativeEnrichmentUI.label("調査時の候補です。本人を特定できない候補や手動編集と競合した候補は、保存・反映されていない場合があります。"), list, message, NativeEnrichmentUI.row([source, NSView(), page, previous, next, close])]); refresh()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NativeEnrichmentUI.button(title, target: self, action: action) }
    private var count: Int { accessible ? max(0, min(100, contacts.count - offset)) : 0 }
    private var selected: NativeTargetAgentOutput.Contact? { (0..<count).contains(table.selectedRow) ? contacts[offset + table.selectedRow] : nil }
    private var sourceURL: URL? {
        guard let value = selected?.source, let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }; return url
    }
    private func refresh() {
        do { try requireAccess(); accessible = true } catch { accessible = false; NativeEnrichmentUI.message(message, error) }
        table.reloadData(); page.stringValue = accessible ? "\(contacts.isEmpty ? 0 : offset + 1)–\(offset + count) ／ \(contacts.count)件" : "閲覧できません"
        previous.isEnabled = accessible && offset > 0; next.isEnabled = accessible && offset + count < contacts.count; source.isEnabled = sourceURL != nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard (0..<count).contains(row) else { return nil }; let item = contacts[offset + row]
        switch column?.identifier.rawValue { case "name": return item.name ?? ""; case "title": return item.title ?? ""; case "email": return item.email ?? ""; case "phone": return item.phone ?? ""; case "linkedin": return item.linkedinUrl ?? ""; default: return item.source ?? "" }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { source.isEnabled = sourceURL != nil }
    @objc private func openSource() { do { try requireAccess(); if let url = sourceURL { openURL(url) } } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func back() { offset = max(0, offset - 100); refresh() }
    @objc private func forward() { if offset + count < contacts.count { offset += 100; refresh() } }
    @objc private func close() { NativeEnrichmentUI.close(window) }
}

final class NativeTargetContactsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeTargetEnrichmentService, targetID: String
    private let table = NSTableView(), search = NSSearchField(), page = NSTextField(labelWithString: ""), message = NativeEnrichmentUI.label("")
    private let name = NSTextField(), email = NSTextField(), phone = NSTextField(), linkedin = NSTextField()
    private var rows: [NativeRecord] = [], offset = 0, total = 0, previous: NSButton!, next: NSButton!, enrich: NSButton!, add: NSButton!, open: NSButton!
    private let openURL: (URL) -> Void
    private var historyWindow: NativeTargetEnrichmentHistoryWindow?, observers: [NSObjectProtocol] = [], refreshWork: DispatchWorkItem?
    var onChanged: (() -> Void)?
    init(api: NativeTargetEnrichmentService, targetID: String, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) throws {
        self.api = api; self.targetID = targetID; self.openURL = openURL; let target = try api.readTarget(targetID); super.init(); window.title = "営業先の担当者"
        table.dataSource = self; table.delegate = self
        search.placeholderString = "氏名・メール・役職で検索"; search.setAccessibilityLabel("営業先の担当者を検索"); search.target = self; search.action = #selector(find)
        let list = NativeEnrichmentUI.table(table, label: "営業先の担当者一覧", columns: [("name", "氏名", 115), ("title", "役職", 110), ("email", "メール", 180), ("phone", "電話", 110), ("linkedinUrl", "LinkedIn", 185), ("source", "登録元", 100), ("enrichStatus", "取得状況", 100)], height: 270)
        for (field, title) in [(name, "担当者の氏名"), (email, "担当者のメール"), (phone, "担当者の電話"), (linkedin, "担当者のLinkedIn")] { field.placeholderString = title; field.setAccessibilityLabel(title) }
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true; phone.widthAnchor.constraint(equalToConstant: 220).isActive = true
        previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward)); enrich = button("選択した担当者を調べる", #selector(enrichSelected)); add = button("担当者を追加", #selector(addContact))
        open = button("LinkedInを開く", #selector(openLinkedIn))
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        message.setAccessibilityLabel("営業先担当者の操作結果"); message.maximumNumberOfLines = 2
        NativeEnrichmentUI.layout(window, [NativeEnrichmentUI.label(CRMModule.displayName(target) + "の担当者", title: true),
            NativeEnrichmentUI.label("担当者を手動で追加できます。調査では氏名・メール・会社情報をAnthropicとE2Bに送り、役職・LinkedIn・電話の空欄を補完します。API・実行環境の利用料が発生します。"),
            search, list, NativeEnrichmentUI.row([enrich, button("調査履歴…", #selector(history)), open, NSView(), page, previous, next]),
            NativeEnrichmentUI.row([name, email]), NativeEnrichmentUI.row([phone, linkedin]), message,
            NativeEnrichmentUI.row([button("再読み込み", #selector(reload)), add, NSView(), close])])
        for notification in [InvoiceJobRunner.didProcess, NativeDatabase.aiProgress] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                guard let self, note.userInfo?["database"] as? String == self.api.db.url.path else { return }
                self.refreshWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.reload() }; self.refreshWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            })
        }
        try refresh()
    }
    deinit { refreshWork?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    private func button(_ title: String, _ action: Selector) -> NSButton { NativeEnrichmentUI.button(title, target: self, action: action) }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var linkedinURL: URL? {
        guard let row = selected, let url = URL(string: row["linkedinUrl"].string), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }; return url
    }
    private func controls() { let writable = (try? api.target(targetID)) != nil; add.isEnabled = writable; enrich.isEnabled = writable && selected != nil; open.isEnabled = linkedinURL != nil }
    @objc private func openLinkedIn() { do { _ = try api.readTarget(targetID); if let url = linkedinURL { openURL(url) } } catch { NativeEnrichmentUI.message(message, error) } }
    private func refresh() throws {
        let id = selected?["id"], values = try api.contactsPage(targetID: targetID, search: search.stringValue, offset: offset); total = values.total
        if values.rows.isEmpty && offset > 0 { offset = max(0, ((max(1, total) - 1) / 100) * 100); return try refresh() }
        rows = values.rows; table.reloadData(); if let id, let index = rows.firstIndex(where: { $0["id"] == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        page.stringValue = "\(total == 0 ? 0 : offset + 1)–\(offset + rows.count) ／ \(total)件"; previous.isEnabled = offset > 0; next.isEnabled = offset + rows.count < total; controls()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row], key = column?.identifier.rawValue ?? "name"
        if key == "source" { return record[key].string == "manual" ? "手動追加" : record[key].string }
        if key == "enrichStatus" { return ["PENDING": "未取得", "RUNNING": "取得中", "COMPLETED": "取得済み", "FAILED": "要確認", "SKIPPED": "対象外"][record[key].string] ?? record[key].string }
        return record[key].string
    }
    func tableViewSelectionDidChange(_ notification: Notification) { controls() }
    @objc private func addContact() {
        do { _ = try api.addContact(targetID: targetID, name: name.stringValue, email: email.stringValue, phone: phone.stringValue, linkedinURL: linkedin.stringValue)
            [name, email, phone, linkedin].forEach { $0.stringValue = "" }; search.stringValue = ""; offset = 0; try refresh(); message.textColor = .labelColor; message.stringValue = "担当者を追加しました。"; onChanged?()
        } catch { NativeEnrichmentUI.message(message, error) }
    }
    private func openHistory(_ id: String? = nil) {
        guard window.attachedSheet == nil else { return }
        do { let controller = try NativeTargetEnrichmentHistoryWindow(api: api, targetID: targetID, focusedID: id); historyWindow = controller
            controller.onChanged = { [weak self] in self?.onChanged?() }; window.beginSheet(controller.window) { [weak self] _ in self?.historyWindow = nil; self?.reload() }
        } catch { NativeEnrichmentUI.message(message, error) }
    }
    @objc private func enrichSelected() { guard let selected else { return }; do { let id = try api.requestContact(selected["id"].string, targetID: targetID); openHistory(id) } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func history() { openHistory() }
    @objc private func reload() { do { try refresh() } catch { rows = []; table.reloadData(); controls(); NativeEnrichmentUI.message(message, error) } }
    @objc private func find() { offset = 0; reload() }
    @objc private func back() { offset = max(0, offset - 100); reload() }
    @objc private func forward() { offset += 100; reload() }
    func confirmDiscard() -> Bool {
        guard [name, email, phone, linkedin].contains(where: { !$0.stringValue.isEmpty }) else { return true }
        let alert = NSAlert(); alert.messageText = "入力中の担当者を破棄しますか？"; alert.informativeText = "追加していない内容は保存されません。"; alert.addButton(withTitle: "破棄する"); alert.addButton(withTitle: "入力を続ける"); return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func close() { if confirmDiscard() { NativeEnrichmentUI.close(window) } }
}
