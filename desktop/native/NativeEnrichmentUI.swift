import AppKit

enum NativeEnrichmentUI {
    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let result = NSButton(title: title, target: target, action: action); result.bezelStyle = .rounded; return result
    }
    static func row(_ views: [NSView]) -> NSStackView { let result = NSStackView(views: views); result.spacing = 10; return result }
    static func column(_ views: [NSView]) -> NSStackView {
        let result = NSStackView(views: views); result.orientation = .vertical; result.alignment = .leading; result.spacing = 8
        for view in views { view.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true }; return result
    }
    static func label(_ text: String, title: Bool = false) -> NSTextField {
        let result = NSTextField(wrappingLabelWithString: text)
        if title { result.font = .systemFont(ofSize: 21, weight: .semibold) }; return result
    }
    static func layout(_ window: NSWindow, _ views: [NSView]) {
        let root = NSStackView(views: views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)])
        for view in views { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    static func table(_ table: NSTableView, label: String, columns: [(String, String, CGFloat)], height: CGFloat) -> NSScrollView {
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 4, height: 2)
        for (key, title, width) in columns { let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width; column.isEditable = false; table.addTableColumn(column) }
        table.rowHeight = 28; table.setAccessibilityLabel(label)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true; return scroll
    }
    static func cell(_ text: String) -> NSTextField {
        let value = NSTextField(labelWithString: text); value.lineBreakMode = .byTruncatingTail; value.toolTip = text; return value
    }
    static func message(_ field: NSTextField, _ error: Error) {
        field.textColor = .systemRed; field.stringValue = error.localizedDescription
    }
    static func close(_ window: NSWindow) { if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) } }
    static let dateParser: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f }()
    static let dateFallback = ISO8601DateFormatter()
    static let dateDisplay: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm:ss"; return f }()
    static func date(_ text: String) -> String { (dateParser.date(from: text) ?? dateFallback.date(from: text)).map(dateDisplay.string) ?? "日時不明" }
}

/// Selection is bounded to 100 IDs even when browsing a much larger database.
/// Request admission rechecks every contact and the credentials atomically.
final class NativeContactEnrichmentRequestWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSPanel
    private let api: NativeContactEnrichmentService, contactID: String?
    private let fieldsTable = NSTableView(), contactsTable = NSTableView(), search = NSSearchField()
    private let name = NSTextField(), customDescription = NSTextField(), summary = NSTextField(labelWithString: ""), page = NSTextField(labelWithString: ""), message = NativeEnrichmentUI.label("")
    private var fields = NativeEnrichmentField.contactPresets, selectedFields = NativeEnrichmentPresentation.defaults
    private var contacts: [NativeRecord] = [], selectedContacts = Set<String>(), offset = 0, total = 0
    private var previous: NSButton!, next: NSButton!, start: NSButton!, remove: NSButton!
    var onStarted: (([String]) -> Void)?, onSettings: ((NSWindow) -> Void)?
    private(set) var requestedIDs: [String] = []
    init(api: NativeContactEnrichmentService, contactID: String? = nil) throws {
        try api.internalAccess(); self.api = api; self.contactID = contactID
        let record = try contactID.map { try api.contact($0, mode: .review) }
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: contactID == nil ? 700 : 620), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(); window.title = contactID == nil ? "連絡先の一括情報補完" : "連絡先の情報補完"
        var views: [NSView] = [NativeEnrichmentUI.label(window.title, title: true)]
        var contactColumn: NSStackView?
        if let record {
            views.append(NativeEnrichmentUI.label(CRMModule.displayName(record) + "  " + record["email"].string))
            views.append(NativeEnrichmentUI.label("取得後に現在の値と比較して、反映する項目を選べます。OpenAIとFirecrawlにメールアドレス・調査項目を送り、API利用料が発生します。"))
        } else {
            views.append(NativeEnrichmentUI.label("最大100件を選択できます。取得した情報は空欄だけに自動反映します。OpenAIとFirecrawlにメールアドレス・調査項目を送り、API利用料が発生します。"))
            search.placeholderString = "氏名・メールアドレスで検索"; search.setAccessibilityLabel("補完する連絡先を検索"); search.target = self; search.action = #selector(findContacts)
            previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward))
            contactsTable.dataSource = self; contactsTable.delegate = self
            contactColumn = NativeEnrichmentUI.column([search, NativeEnrichmentUI.table(contactsTable, label: "補完する連絡先", columns: [("check", "選択", 40), ("name", "氏名", 130), ("email", "メールアドレス", 210)], height: 200),
                NativeEnrichmentUI.row([page, NSView(), previous, next]),
                NativeEnrichmentUI.row([button("このページを選択", #selector(selectPage)), button("連絡先の選択を解除", #selector(clearContacts))])])
            contactColumn!.widthAnchor.constraint(equalToConstant: 400).isActive = true
        }
        fieldsTable.dataSource = self; fieldsTable.delegate = self
        let fieldColumn = NativeEnrichmentUI.column([NativeEnrichmentUI.label("調べる項目（任意項目は履歴に保存）"),
            NativeEnrichmentUI.table(fieldsTable, label: "補完する項目", columns: [("check", "選択", 40), ("name", "項目", 170), ("description", "調査内容", contactID == nil ? 240 : 620)], height: contactID == nil ? 280 : 220)])
        if let contactColumn { let row = NativeEnrichmentUI.row([contactColumn, fieldColumn]); row.alignment = .top; row.distribution = .fill; views.append(row) } else { views.append(fieldColumn) }
        name.placeholderString = "任意の項目名"; name.setAccessibilityLabel("任意の項目名")
        customDescription.placeholderString = "調査内容（省略可）"; customDescription.setAccessibilityLabel("任意項目の調査内容")
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        remove = button("選択行の任意項目を削除", #selector(removeCustom))
        views.append(NativeEnrichmentUI.row([name, customDescription, button("項目を追加", #selector(addCustom)), remove]))
        summary.setAccessibilityLabel("情報補完の選択件数"); message.setAccessibilityLabel("情報補完の予約結果"); message.maximumNumberOfLines = 2
        start = button("情報補完を開始", #selector(begin)); let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        views += [summary, message, NativeEnrichmentUI.row([button("AI連携の設定…", #selector(settings)), NSView(), close, start])]
        NativeEnrichmentUI.layout(window, views)
        if contactID == nil { try loadContacts() }; selection()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NativeEnrichmentUI.button(title, target: self, action: action) }
    private func selection() {
        summary.stringValue = "連絡先 \(contactID == nil ? selectedContacts.count : 1)件 ／ 調査項目 \(selectedFields.count)件"
        start.isEnabled = !selectedFields.isEmpty && (contactID != nil || !selectedContacts.isEmpty) && requestedIDs.isEmpty
        remove.isEnabled = fields.indices.contains(fieldsTable.selectedRow) && fieldsTable.selectedRow >= NativeEnrichmentField.contactPresets.count
    }
    private func loadContacts() throws {
        let result = try api.contactsPage(search: search.stringValue, offset: offset); total = result.total
        if result.rows.isEmpty && offset > 0 { offset = max(0, ((max(1, total) - 1) / 100) * 100); return try loadContacts() }
        contacts = result.rows; contactsTable.reloadData(); page.stringValue = "\(total == 0 ? 0 : offset + 1)–\(offset + contacts.count) ／ \(total)件"
        previous.isEnabled = offset > 0; next.isEnabled = offset + contacts.count < total
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === fieldsTable ? fields.count : contacts.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let field = tableView === fieldsTable
        guard row >= 0, row < (field ? fields.count : contacts.count) else { return nil }
        if column?.identifier.rawValue == "check" {
            let value = NSButton(checkboxWithTitle: "", target: self, action: field ? #selector(toggleField(_:)) : #selector(toggleContact(_:))); value.tag = row
            value.state = (field ? selectedFields.contains(fields[row].name) : selectedContacts.contains(contacts[row]["id"].string)) ? .on : .off
            value.setAccessibilityLabel((field ? fields[row].displayName : CRMModule.displayName(contacts[row])) + "を選択"); return value
        }
        if field { return NativeEnrichmentUI.cell(column?.identifier.rawValue == "name" ? fields[row].displayName : fields[row].description) }
        return NativeEnrichmentUI.cell(column?.identifier.rawValue == "name" ? CRMModule.displayName(contacts[row]) : contacts[row]["email"].string)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selection() }
    @objc private func toggleField(_ button: NSButton) { guard fields.indices.contains(button.tag) else { return }; let key = fields[button.tag].name; if button.state == .on { selectedFields.insert(key) } else { selectedFields.remove(key) }; selection() }
    @objc private func toggleContact(_ button: NSButton) {
        guard contacts.indices.contains(button.tag) else { return }; let id = contacts[button.tag]["id"].string
        if button.state == .on && selectedContacts.count >= 100 { button.state = .off; NativeEnrichmentUI.message(message, NativeAIError(message: "一度に選択できる連絡先は100件までです。")); return }
        if button.state == .on { selectedContacts.insert(id) } else { selectedContacts.remove(id) }; selection()
    }
    @objc private func addCustom() { do { let field = try NativeEnrichmentPresentation.custom(name: name.stringValue, description: customDescription.stringValue, existing: fields); fields.append(field); selectedFields.insert(field.name); fieldsTable.reloadData(); name.stringValue = ""; customDescription.stringValue = ""; message.stringValue = ""; selection() } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func removeCustom() { let row = fieldsTable.selectedRow; guard row >= NativeEnrichmentField.contactPresets.count, fields.indices.contains(row) else { return }; selectedFields.remove(fields[row].name); fields.remove(at: row); fieldsTable.reloadData(); selection() }
    @objc private func selectPage() {
        let addition = Set(contacts.map { $0["id"].string }); guard selectedContacts.union(addition).count <= 100 else { NativeEnrichmentUI.message(message, NativeAIError(message: "選択済みの連絡先と合わせて100件を超えます。選択を解除するか個別に選んでください。")); return }
        selectedContacts.formUnion(addition); contactsTable.reloadData(); selection()
    }
    @objc private func clearContacts() { selectedContacts.removeAll(); contactsTable.reloadData(); selection() }
    @objc private func findContacts() { offset = 0; reloadContacts() }
    private func reloadContacts() { do { try loadContacts() } catch { contacts = []; contactsTable.reloadData(); NativeEnrichmentUI.message(message, error) } }
    @objc private func back() { offset = max(0, offset - 100); reloadContacts() }
    @objc private func forward() { offset += 100; reloadContacts() }
    @objc private func settings() { onSettings?(window) }
    @objc private func begin() {
        guard requestedIDs.isEmpty else { return }
        do {
            requestedIDs = try api.request(contactIDs: contactID.map { [$0] } ?? selectedContacts.sorted(), fields: fields.filter { selectedFields.contains($0.name) }, mode: contactID == nil ? .bulk : .review)
            selection(); onStarted?(requestedIDs); NativeEnrichmentUI.close(window)
        } catch { NativeEnrichmentUI.message(message, error) }
    }
    @objc private func close() { NativeEnrichmentUI.close(window) }
}
