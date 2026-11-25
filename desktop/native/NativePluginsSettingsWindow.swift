import AppKit
import UniformTypeIdentifiers

private final class NativePluginFormDocument: NSView { override var isFlipped: Bool { true } }

final class NativePluginsSettingsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 960, height: 730), styleMask: [.titled], backing: .buffered, defer: false)
    private let admin: NativePluginsAdmin
    private let confirm: (String, String) -> Bool
    private let table = NSTableView(), scroll = NSScrollView(), document = NativePluginFormDocument()
    private let result = NSTextField(wrappingLabelWithString: "")
    private var refreshButton: NSButton!, closeButton: NSButton!, saveButton: NSButton?
    private var textInputs: [String: NSTextField] = [:], flagInputs: [String: NSButton] = [:], options: [String: NSPopUpButton] = [:], secrets: [String: NSSecureTextField] = [:]
    private var grant: NSButton?, formControls: [NSControl] = []
    private var items: [NativePluginsAdmin.Item] = [], detail: NativePluginsAdmin.Detail?
    private var operation: Task<Void, Never>?, busy = false, selecting = false, closed = false
    private var logsWindow: NativePluginLogWindow?
    var onOpenDetails: ((NativePluginsAdmin.Detail, NSWindow) -> Void)?

    init(admin: NativePluginsAdmin, confirm: @escaping (String, String) -> Bool = NativePluginsSettingsWindow.ask) {
        self.admin = admin; self.confirm = confirm; super.init()
        window.title = "連携・プラグインの設定"
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 48
        table.setAccessibilityLabel("連携の一覧")
        let column = NSTableColumn(identifier: .init("plugin")); column.width = 220; table.addTableColumn(column)
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.widthAnchor.constraint(equalToConstant: 230).isActive = true
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
        let body = NSStackView(views: [list, scroll]); body.spacing = 12; body.alignment = .top
        refreshButton = button("再読み込み", #selector(refresh)); closeButton = button("閉じる", #selector(close)); closeButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [refreshButton, NSView(), closeButton]); footer.spacing = 8
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        result.maximumNumberOfLines = 2; result.setAccessibilityLabel("連携設定の操作結果")
        let root = NSStackView(views: [title, body, result, footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20), body.widthAnchor.constraint(equalTo: root.widthAnchor), body.heightAnchor.constraint(equalToConstant: 580), list.heightAnchor.constraint(equalTo: body.heightAnchor), scroll.heightAnchor.constraint(equalTo: body.heightAnchor), result.widthAnchor.constraint(equalTo: root.widthAnchor), footer.widthAnchor.constraint(equalTo: root.widthAnchor)])
        window.contentView!.layoutSubtreeIfNeeded()
    }
    deinit { operation?.cancel() }
    static func ask(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "続ける"); alert.addButton(withTitle: "キャンセル")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: selector); value.bezelStyle = .rounded; return value
    }
    func start() { load() }
    private func setBusy(_ value: Bool) {
        busy = value; table.isEnabled = !value; refreshButton.isEnabled = !value; closeButton.isEnabled = !value
        for control in formControls { control.isEnabled = !value }
        updateSave()
    }
    private func show(_ text: String, failed: Bool = false) { result.stringValue = text; result.textColor = failed ? .systemRed : .secondaryLabelColor }
    private func updateSave() { saveButton?.isEnabled = !busy && (detail?.installed == true || grant?.state == .on) }
    @objc private func grantChanged() { updateSave() }
    private var dirty: Bool {
        guard let detail, let definition = detail.definition else { return false }
        if secrets.values.contains(where: { !$0.stringValue.isEmpty }) { return true }
        for field in definition.settings.fields {
            let expected = detail.settings[field.key] ?? field.defaultValue
            if field.kind == .boolean {
                if (flagInputs[field.key]?.state == .on) != (NativePluginJSON.boolean(expected) ?? false) { return true }
            } else {
                let actual = options[field.key]?.titleOfSelectedItem ?? textInputs[field.key]?.stringValue ?? ""
                if actual != (expected.map(NativePluginJSON.string) ?? "") { return true }
            }
        }
        return false
    }
    func confirmDiscard() -> Bool {
        guard !busy, window.attachedSheet == nil else { return false }
        return !dirty || confirm("連携設定の変更を破棄しますか？", "まだ保存していない変更があります。")
    }
    @objc private func refresh() { guard confirmDiscard() else { return }; load(preferred: detail?.item.id) }
    private func load(preferred: String? = nil, message: String? = nil) {
        guard !busy, !closed else { return }; setBusy(true); show("読み込んでいます…")
        let selected = preferred ?? detail?.item.id, admin = admin
        operation = Task.detached { [weak self] in
            let loaded: Result<([NativePluginsAdmin.Item], NativePluginsAdmin.Detail?), Error>
            do {
                let rows = try admin.list(), id = rows.first(where: { $0.id == selected })?.id ?? rows.first?.id
                loaded = .success((rows, try id.map(admin.detail)))
            } catch { loaded = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self, !self.closed else { return }
                self.operation = nil; self.setBusy(false); self.selecting = true
                switch loaded {
                case let .success((rows, value)):
                    self.items = rows; self.detail = value; self.table.reloadData()
                    if let index = rows.firstIndex(where: { $0.id == value?.item.id }) { self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                    self.render(); self.show(message ?? "")
                case let .failure(error):
                    self.items = []; self.detail = nil; self.table.reloadData(); self.render(); self.show(NativePluginsAdmin.errorMessage(error), failed: true)
                }
                self.selecting = false
            }
        }
    }
    private func render() {
        for view in document.subviews { view.removeFromSuperview() }
        textInputs = [:]; flagInputs = [:]; options = [:]; secrets = [:]; formControls = []; grant = nil; saveButton = nil
        let width = max(480, scroll.contentView.bounds.width - 20); var y: CGFloat = 12
        func add(_ view: NSView, height: CGFloat = 26) { view.frame = NSRect(x: 10, y: y, width: width, height: height); document.addSubview(view); y += height + 10 }
        func label(_ text: String, height: CGFloat = 20, heading: Bool = false) {
            let field = NSTextField(wrappingLabelWithString: text); if heading { field.font = .systemFont(ofSize: 16, weight: .semibold) }; add(field, height: height)
        }
        func row(_ buttons: [NSButton]) {
            var x: CGFloat = 10
            for button in buttons {
                let size = max(90, min(200, button.fittingSize.width + 12)); button.frame = NSRect(x: x, y: y, width: size, height: 30); x += size + 8
                document.addSubview(button); formControls.append(button)
            }
            y += 40
        }
        guard let detail else { label("連携を選択してください。"); document.frame = NSRect(x: 0, y: 0, width: width + 20, height: y); return }
        label(detail.item.name, height: 24, heading: true)
        label(detail.item.description, height: 42)
        label("状態：" + NativePluginsAdmin.status(detail.item.status))
        if let version = detail.installedVersion, let current = detail.definition?.version, version != current { label("更新待ち：\(version) → \(current)", height: 24) }
        if detail.item.status == "MISSING" { label("導入済みの連携機能が見つかりません。保存データの書き出しや削除ができます。", height: 42) }
        if detail.installed {
            var buttons: [NSButton] = []
            if detail.definition != nil { buttons.append(button(detail.enabled ? "無効にする" : "有効にする", #selector(toggle))) }
            buttons += [button("書き出す…", #selector(export)), button("ログ…", #selector(openLogs)), button("削除…", #selector(uninstall))]
            row(buttons)
        }
        if detail.enabled, let definition = detail.definition {
            if !admin.allowsActions { label("連携の実行・同期・送信は再開の確認待ちです。設定の変更は保存できます。", height: 42) }
            for slot in definition.slots where slot.kind == .adminAction && admin.allowsActions {
                let title = slot.title.map { admin.host.translate(definition.id, $0, nil, "ja") } ?? slot.id
                let action = button(title, #selector(runAction(_:))); action.identifier = .init(slot.id); row([action])
            }
            if onOpenDetails != nil && definition.slots.contains(where: { $0.kind == .adminSection }) { row([button("連携の状況…", #selector(openDetails))]) }
        }
        if let definition = detail.definition {
            label("設定", heading: true)
            for field in definition.settings.fields {
                let value = detail.settings[field.key] ?? field.defaultValue
                let title = NativePluginsAdmin.label(field.key) + (field.required && field.defaultValue == nil ? " ＊" : "")
                switch field.kind {
                case .boolean:
                    let box = NSButton(checkboxWithTitle: title, target: nil, action: nil); box.state = NativePluginJSON.boolean(value) == true ? .on : .off; flagInputs[field.key] = box; formControls.append(box); add(box)
                case .enumeration:
                    label(title); let popup = NSPopUpButton(); popup.addItems(withTitles: field.options ?? [])
                    if let value { popup.selectItem(withTitle: NativePluginJSON.string(value)) }; popup.setAccessibilityLabel(title); options[field.key] = popup; formControls.append(popup); add(popup)
                case .string, .number:
                    label(title); let input = NSTextField(); input.stringValue = value.map(NativePluginJSON.string) ?? ""; input.setAccessibilityLabel(title); textInputs[field.key] = input; formControls.append(input); add(input)
                }
                if let hint = NativePluginsAdmin.hint(field.key) { label(hint, height: field.key == "contactTypes" ? 42 : 30) }
            }
            if !definition.secrets.fields.isEmpty { label("認証情報", heading: true) }
            for field in definition.secrets.fields {
                label(NativePluginsAdmin.label(field.key)); let input = NSSecureTextField()
                input.placeholderString = detail.secretFlags[field.key] == true ? "設定済み。変更する場合のみ入力" : "未設定"
                input.setAccessibilityLabel(NativePluginsAdmin.label(field.key)); secrets[field.key] = input; formControls.append(input); add(input)
            }
            if !detail.installed {
                label("この連携が使用する権限", heading: true)
                label(definition.permissions.map(NativePluginsAdmin.permission).joined(separator: "・"), height: 64)
                let check = NSButton(checkboxWithTitle: "権限を確認して、この連携を有効にする", target: self, action: #selector(grantChanged))
                grant = check; formControls.append(check); add(check)
            }
            let save = button(detail.installed ? "設定を保存" : "導入する", #selector(save)); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; saveButton = save; row([save])
        }
        document.frame = NSRect(x: 0, y: 0, width: width + 20, height: max(y, scroll.contentView.bounds.height)); scroll.contentView.scroll(to: .zero); updateSave()
    }
    @objc private func save() {
        guard !busy, let detail, let definition = detail.definition else { return }
        do {
            var values = textInputs.mapValues(\.stringValue); for (key, control) in options { values[key] = control.titleOfSelectedItem ?? "" }
            let settings = try NativePluginsAdmin.settings(definition.settings.fields, values: values, flags: flagInputs.mapValues { $0.state == .on })
            let secretValues = secrets.mapValues { $0.stringValue as Any }, granted = grant?.state == .on, admin = admin
            mutate(success: detail.installed ? "設定を保存しました。" : "連携を導入しました。") { try await admin.save(detail, settings: settings, secrets: secretValues, granted: granted); return nil }
        } catch { show(NativePluginsAdmin.errorMessage(error), failed: true) }
    }
    private func mutate(success: String, work: @escaping () async throws -> String?) {
        guard !busy, !closed else { return }; let id = detail?.item.id; setBusy(true); show("処理しています…")
        operation = Task.detached { [weak self] in
            let outcome: Result<String?, Error>
            do { outcome = .success(try await work()) } catch { outcome = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self, !self.closed else { return }; self.operation = nil; self.setBusy(false)
                switch outcome {
                case let .success(message): for input in self.secrets.values { input.stringValue = "" }; self.load(preferred: id, message: message ?? success)
                case let .failure(error): self.show(NativePluginsAdmin.errorMessage(error), failed: true)
                }
            }
        }
    }
    @objc private func toggle() {
        guard confirmDiscard(), let detail else { return }; let admin = admin
        mutate(success: detail.enabled ? "連携を無効にしました。" : "連携を有効にしました。") { try await admin.setEnabled(detail, enabled: !detail.enabled); return nil }
    }
    @objc private func runAction(_ sender: NSButton) {
        guard confirmDiscard(), let detail, let id = sender.identifier?.rawValue else { return }; let admin = admin
        mutate(success: "操作を実行しました。") { try await admin.action(detail, id: id) }
    }
    @objc private func uninstall() {
        guard confirmDiscard(), let detail else { return }
        guard confirm("「\(detail.item.name)」を削除しますか？", "この連携の設定・保存データ\(detail.entries)件（対象\(detail.records)件）・ログを削除します。必要なデータは先に書き出してください。") else { return }
        let admin = admin; mutate(success: "連携を削除しました。") { try await admin.uninstall(detail); return nil }
    }
    @objc private func export() {
        guard confirmDiscard(), let detail else { return }
        let panel = NSSavePanel(); panel.title = "連携データを書き出す"; panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = detail.item.id + ".json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }; let admin = admin
        mutate(success: "連携データを書き出しました。") {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".nextcrm-plugin-" + UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: staging) }
            try admin.export(detail, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging) }
            else { try FileManager.default.moveItem(at: staging, to: destination) }
            return nil
        }
    }
    @objc private func openLogs() {
        guard !busy, window.attachedSheet == nil, let detail else { return }
        let controller = NativePluginLogWindow(admin: admin, id: detail.item.id, name: detail.item.name); logsWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in self?.logsWindow = nil }; controller.start()
    }
    @objc private func openDetails() { guard !busy, window.attachedSheet == nil, let detail else { return }; onOpenDetails?(detail, window) }
    @objc private func close() { guard confirmDiscard() else { return }; closed = true; if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() } }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { selecting || (items.indices.contains(row) && confirmDiscard()) }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, !busy, items.indices.contains(table.selectedRow) else { return }; load(preferred: items[table.selectedRow].id)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let label = NSTextField(wrappingLabelWithString: items[row].name + "\n" + NativePluginsAdmin.status(items[row].status)); label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; return label
    }
}
