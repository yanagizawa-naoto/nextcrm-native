import AppKit

final class NativeCRMConfigurationWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 630), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeCRMConfiguration
    private let confirm: (String) -> Bool
    private let kindControl = NSPopUpButton(), search = NSSearchField(), table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: ""), count = NSTextField(labelWithString: "")
    private var rows: [NativeCRMConfiguration.Value] = [], kind = NativeCRMConfiguration.Kind.industry
    private var offset = 0, total = 0, dictionaryTotal = 0, busy = false, closed = false, permitted = true
    private var buttons: [String: NSButton] = [:]
    private var editor: NativeCRMConfigurationEditor?
    var onChanged: (() -> Void)?

    init(service: CRMService, confirmDiscard: @escaping (String) -> Bool = NativeCRMConfigurationWindow.askDiscard) throws {
        try service.authenticated()
        guard service.identity.role == "admin" else { throw NativeDBError.message("CRMの選択肢は管理者が設定してください。") }
        api = NativeCRMConfiguration(service: service); confirm = confirmDiscard
        super.init(); window.title = "CRMの選択肢設定"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "企業・連絡先・リード・商談で使用する選択肢を管理します。使用件数には、削除済みのデータも含まれます。")
        kindControl.addItems(withTitles: NativeCRMConfiguration.Kind.allCases.map(\.title))
        kindControl.setAccessibilityLabel("選択肢の種類"); kindControl.target = self; kindControl.action = #selector(kindChanged)
        search.placeholderString = "名称で検索"; search.setAccessibilityLabel("選択肢の検索"); search.target = self; search.action = #selector(searchChanged)
        let toolbar = NSStackView(views: [kindControl, search, button("追加…", #selector(add)), button("再読み込み", #selector(refresh))]); toolbar.spacing = 8
        kindControl.widthAnchor.constraint(equalToConstant: 190).isActive = true
        for (id, title, width) in [("name", "名称", 440.0), ("usage", "使用件数", 110.0), ("stage", "自動処理のきっかけ", 230.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.allowsMultipleSelection = false
        table.setAccessibilityLabel("CRMの選択肢一覧")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        let actions = NSStackView(views: [button("編集…", #selector(edit)), button("削除…", #selector(remove)), NSView()]); actions.spacing = 8
        let footer = NSStackView(views: [button("前の100件", #selector(previous)), count, button("次の100件", #selector(next)), NSView(), button("閉じる", #selector(close))]); footer.spacing = 8
        buttons["閉じる"]?.keyEquivalent = "\u{1b}"
        status.maximumNumberOfLines = 3; status.setAccessibilityLabel("選択肢設定の操作結果")
        Self.stack([title, help, toolbar, scroll, actions, status, footer], in: window)
        controls()
    }
    static func askDiscard(_ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = message
        alert.addButton(withTitle: "編集を続ける"); alert.addButton(withTitle: "変更を破棄")
        return alert.runModal() == .alertSecondButtonReturn
    }
    fileprivate static func stack(_ views: [NSView], in window: NSWindow) {
        let root = NSStackView(views: views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        for view in views { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded; buttons[title] = value; return value
    }
    private var selected: NativeCRMConfiguration.Value? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func controls() {
        let enabled = !busy && editor == nil && !closed
        kindControl.isEnabled = enabled; search.isEnabled = enabled; table.isEnabled = enabled
        for button in buttons.values { button.isEnabled = enabled }
        buttons["追加…"]?.isEnabled = enabled && permitted
        buttons["編集…"]?.isEnabled = enabled && permitted && selected != nil
        buttons["削除…"]?.isEnabled = enabled && permitted && selected != nil && dictionaryTotal > 1
        buttons["削除…"]?.toolTip = dictionaryTotal <= 1 ? "最後の項目は削除できません" : nil
        buttons["前の100件"]?.isEnabled = enabled && offset > 0
        buttons["次の100件"]?.isEnabled = enabled && offset + rows.count < total
    }
    func start() { load() }
    func confirmDiscard() -> Bool { !busy && (editor?.confirmDiscard() ?? true) }
    private func load(message: String = "項目を選択して編集・削除できます。") {
        guard !busy, !closed, editor == nil else { return }; busy = true; controls()
        let kind = kind, offset = offset, query = search.stringValue
        status.stringValue = "読み込んでいます…"; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try api.searchPage(kind, search: query, offset: offset) }
            DispatchQueue.main.async { [self] in
                busy = false; guard !closed else { return }
                switch result {
                case let .success(result):
                    permitted = true
                    if result.page.values.isEmpty && offset > 0 { self.offset = max(0, ((result.page.total - 1) / 100) * 100); load(message: message); return }
                    rows = result.page.values; total = result.page.total; dictionaryTotal = result.dictionaryTotal
                    count.stringValue = "\(total == 0 ? 0 : offset + 1)〜\(offset + rows.count) ／ \(total)件"
                    status.stringValue = total == 0 ? "該当する項目がありません。" : message
                case let .failure(error):
                    permitted = false; rows = []; total = 0; dictionaryTotal = 0; self.offset = 0; count.stringValue = "—"
                    status.stringValue = error.localizedDescription; status.textColor = .systemRed
                }
                table.deselectAll(nil); table.reloadData(); controls()
            }
        }
    }
    @objc private func kindChanged() { guard !busy, editor == nil else { return }; kind = NativeCRMConfiguration.Kind.allCases[kindControl.indexOfSelectedItem]; offset = 0; search.stringValue = ""; load() }
    @objc private func searchChanged() { guard !busy, editor == nil else { return }; offset = 0; load() }
    @objc private func refresh() { load() }
    @objc private func previous() { guard !busy, offset > 0 else { return }; offset = max(0, offset - 100); load() }
    @objc private func next() { guard !busy, offset + rows.count < total else { return }; offset += 100; load() }
    @objc private func add() { present(nil, deleting: false) }
    @objc private func edit() { if let selected { present(selected, deleting: false) } }
    @objc private func remove() { if dictionaryTotal > 1, let selected { present(selected, deleting: true) } }
    private func present(_ value: NativeCRMConfiguration.Value?, deleting: Bool) {
        guard !busy, editor == nil, permitted else { return }
        do {
            try api.service.authenticated()
            guard api.service.identity.role == "admin" else { throw NativeDBError.message("操作する権限がありません") }
            let child = NativeCRMConfigurationEditor(api: api, kind: kind, value: value, deleting: deleting, confirm: confirm)
            editor = child; controls()
            window.beginSheet(child.window) { [weak self] response in
                guard let self else { return }; self.editor = nil; self.controls()
                if response == .OK { self.onChanged?(); self.load(message: deleting ? "項目を削除しました。" : "項目を保存しました。") }
            }
            child.start()
        } catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    }
    @objc private func close() { guard !busy, editor == nil, confirmDiscard() else { return }; closed = true; if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls() }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row], key = column?.identifier.rawValue ?? "name"
        let value = key == "usage" ? "\(item.usageCount)件" : key == "stage" ? (kind == .salesStage ? NativeCRMConfiguration.stageTitle(item.stageKind) : "—") : item.name
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingTail; field.toolTip = value; return field
    }
}

private final class NativeCRMConfigurationEditor: NSObject {
    let window: NSPanel
    private let api: NativeCRMConfiguration, kind: NativeCRMConfiguration.Kind, value: NativeCRMConfiguration.Value?, deleting: Bool
    private let confirm: (String) -> Bool
    private let name = NSTextField(), stage = NSPopUpButton(), replacement = NSPopUpButton(), search = NSSearchField()
    private let status = NSTextField(wrappingLabelWithString: ""), range = NSTextField(labelWithString: "")
    private var save: NSButton!, cancel: NSButton!, previous: NSButton!, next: NSButton!
    private var replacements: [NativeCRMConfiguration.Value] = [], offset = 0, total = 0, busy = false, initialName = "", initialStage = 0
    private var selectedReplacement: String?
    private var needsReplacement: Bool { deleting && kind.allowsReassignment && (value?.usageCount ?? 0) > 0 }
    init(api: NativeCRMConfiguration, kind: NativeCRMConfiguration.Kind, value: NativeCRMConfiguration.Value?, deleting: Bool, confirm: @escaping (String) -> Bool) {
        self.api = api; self.kind = kind; self.value = value; self.deleting = deleting; self.confirm = confirm
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: deleting ? (kind.allowsReassignment && (value?.usageCount ?? 0) > 0 ? 470 : 370) : (kind == .salesStage ? 420 : 340)), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(); window.title = deleting ? "\(kind.title)を削除" : value == nil ? "\(kind.title)を追加" : "\(kind.title)を編集"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 20, weight: .semibold)
        var views: [NSView] = [title]
        if deleting, let value {
            let message = needsReplacement ? "「\(value.name)」は\(value.usageCount)件で使用中です。置き換え先を選択してから削除してください。" : value.usageCount > 0 ? "「\(value.name)」を削除すると、使用中の\(value.usageCount)件でこの選択肢が未設定になります。この種類は置き換えに対応していません。" : "「\(value.name)」を削除します。この操作は取り消せません。"
            let help = NSTextField(wrappingLabelWithString: message); help.setAccessibilityLabel("削除の説明"); views.append(help)
            if needsReplacement {
                search.placeholderString = "置き換え先の名称で検索"; search.setAccessibilityLabel("置き換え先の検索"); search.target = self; search.action = #selector(searchChanged)
                replacement.setAccessibilityLabel("置き換え先"); replacement.target = self; replacement.action = #selector(replacementChanged)
                previous = button("前の候補100件", #selector(previousPage)); next = button("次の候補100件", #selector(nextPage))
                let pages = NSStackView(views: [previous, range, next]); pages.spacing = 8
                views += [search, replacement, pages]
            }
        } else {
            name.stringValue = value?.name ?? ""; initialName = name.stringValue; name.setAccessibilityLabel("選択肢の名称")
            views += [NSTextField(labelWithString: "名称（100文字以内）"), name]
            if kind == .salesStage {
                stage.addItems(withTitles: ["なし"] + NativeCRMConfiguration.stageKinds.map { NativeCRMConfiguration.stageTitle($0) })
                if let current = value?.stageKind {
                    if let index = NativeCRMConfiguration.stageKinds.firstIndex(of: current) { stage.selectItem(at: index + 1) }
                    else { stage.addItem(withTitle: "未対応の設定（保持）"); stage.selectItem(at: stage.numberOfItems - 1) }
                }
                initialStage = stage.indexOfSelectedItem; stage.setAccessibilityLabel("自動処理のきっかけ")
                views += [NSTextField(labelWithString: "自動処理のきっかけ"), stage]
            }
        }
        initialStage = stage.indexOfSelectedItem
        status.maximumNumberOfLines = 3; status.setAccessibilityLabel("選択肢編集の操作結果")
        cancel = button("キャンセル", #selector(close)); cancel.keyEquivalent = "\u{1b}"
        save = button(deleting ? (needsReplacement ? "割り当てを変更して削除" : "削除する") : "保存", #selector(commit))
        if !deleting { save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command }
        let footer = NSStackView(views: [NSView(), cancel, save]); footer.spacing = 10
        views += [NSView(), status, footer]; NativeCRMConfigurationWindow.stack(views, in: window); controls()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let value = NSButton(title: title, target: self, action: action); value.bezelStyle = .rounded; return value }
    func start() { if needsReplacement { loadReplacements() } }
    func confirmDiscard() -> Bool {
        guard !busy else { return false }; window.makeFirstResponder(nil)
        return deleting || (name.stringValue == initialName && stage.indexOfSelectedItem == initialStage) || confirm("入力した変更を破棄しますか？")
    }
    private func controls() {
        for control: NSControl in [name, stage, replacement, search, save, cancel] { control.isEnabled = !busy }
        save.isEnabled = !busy && (!needsReplacement || selectedReplacement != nil)
        previous?.isEnabled = !busy && offset > 0; next?.isEnabled = !busy && offset + replacements.count < total
    }
    private func loadReplacements() {
        guard !busy, let value else { return }; busy = true; selectedReplacement = nil; controls()
        let offset = offset, query = search.stringValue
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try api.searchPage(kind, search: query, excludingID: value.id, offset: offset) }
            DispatchQueue.main.async { [self] in
                busy = false; replacements = []; replacement.removeAllItems(); replacement.addItem(withTitle: "置き換え先を選択…")
                switch result {
                case let .success(result):
                    if result.page.values.isEmpty && offset > 0 {
                        self.offset = max(0, ((result.page.total - 1) / 100) * 100)
                        loadReplacements(); return
                    }
                    replacements = result.page.values; total = result.page.total
                    replacement.addItems(withTitles: replacements.map(\.name)); range.stringValue = "\(total == 0 ? 0 : offset + 1)〜\(offset + replacements.count) ／ \(total)件"
                    status.stringValue = total == 0 ? "置き換え先が見つかりません。" : ""; status.textColor = .secondaryLabelColor
                case let .failure(error): total = 0; range.stringValue = "—"; status.stringValue = error.localizedDescription; status.textColor = .systemRed
                }
                controls()
            }
        }
    }
    @objc private func searchChanged() { guard !busy else { return }; offset = 0; loadReplacements() }
    @objc private func previousPage() { guard !busy, offset > 0 else { return }; offset = max(0, offset - 100); loadReplacements() }
    @objc private func nextPage() { guard !busy, offset + replacements.count < total else { return }; offset += 100; loadReplacements() }
    @objc private func replacementChanged() {
        let index = replacement.indexOfSelectedItem - 1; selectedReplacement = replacements.indices.contains(index) ? replacements[index].id : nil; controls()
    }
    @objc private func close() { if confirmDiscard() { window.sheetParent?.endSheet(window, returnCode: .cancel) } }
    @objc private func commit() {
        guard !busy, !needsReplacement || selectedReplacement != nil else { return }; window.makeFirstResponder(nil)
        let text = name.stringValue, index = stage.indexOfSelectedItem, replacementID = selectedReplacement
        let change: NativeCRMConfiguration.StageKindChange = kind != .salesStage || index > NativeCRMConfiguration.stageKinds.count ? .unchanged : .set(index <= 0 ? nil : NativeCRMConfiguration.stageKinds[index - 1])
        busy = true; controls(); status.stringValue = deleting ? "削除しています…" : "保存しています…"; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result {
                if deleting, let value { try api.deleteFromUI(kind, value: value, replacementID: replacementID) }
                else if let value { _ = try api.update(kind, id: value.id, name: text, stageKind: change, expectedRevision: value.record.revision) }
                else { _ = try api.create(kind, name: text, stageKind: change) }
            }
            DispatchQueue.main.async { [self] in
                busy = false; controls()
                switch result {
                case .success: window.sheetParent?.endSheet(window, returnCode: .OK)
                case let .failure(error): status.stringValue = error.localizedDescription; status.textColor = .systemRed
                }
            }
        }
    }
}
