import AppKit

final class NativeCRMFunnelSettingsWindow: NSObject, NSWindowDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeCRMFunnelSettings
    private let confirm: (String) -> Bool
    private var fields: [String: NSTextField] = [:]
    private var snapshot: NativeCRMFunnelSettings.Snapshot?
    private var original: [String: String] = [:]
    private var busy = false, closed = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "設定を保存", target: nil, action: nil)
    private let reloadButton = NSButton(title: "再読み込み", target: nil, action: nil)
    private let closeButton = NSButton(title: "閉じる", target: nil, action: nil)
    var onChanged: (() -> Void)?

    init(service: CRMService, confirmDiscard: @escaping (String) -> Bool = NativeCRMFunnelSettingsWindow.askDiscard) throws {
        api = NativeCRMFunnelSettings(service: service); confirm = confirmDiscard
        try api.requireAdministrator()
        super.init()
        window.title = "営業フローの実行タイミング"; window.delegate = self
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "変更は今後の段階変更と次回の定期処理に適用されます。予約済みの連絡は元の予定を維持します。日数は1〜365、定期フォローは0〜24回で設定してください。")
        var views: [NSView] = [title, help]
        var groups: [String] = []
        for field in NativeCRMFunnelSettings.fields where !groups.contains(field.group) { groups.append(field.group) }
        for group in groups {
            let heading = NSTextField(labelWithString: group); heading.font = .systemFont(ofSize: 14, weight: .semibold)
            views.append(heading)
            var rows: [[NSView]] = []
            for spec in NativeCRMFunnelSettings.fields where spec.group == group {
                let label = NSTextField(labelWithString: spec.label), field = NSTextField(), unit = NSTextField(labelWithString: spec.unit)
                field.setAccessibilityLabel(spec.label); field.identifier = .init(spec.key)
                field.alignment = .right; field.widthAnchor.constraint(equalToConstant: 72).isActive = true
                field.toolTip = "\(spec.range.lowerBound)〜\(spec.range.upperBound)の整数"
                fields[spec.key] = field; rows.append([label, field, unit])
            }
            let grid = NSGridView(views: rows); grid.columnSpacing = 12; grid.rowSpacing = 8
            grid.xPlacement = .leading; grid.yPlacement = .center; grid.column(at: 0).width = 580
            views.append(grid)
        }
        status.maximumNumberOfLines = 3; status.setAccessibilityLabel("営業フロー設定の操作結果")
        saveButton.target = self; saveButton.action = #selector(save)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        closeButton.target = self; closeButton.action = #selector(close); closeButton.keyEquivalent = "\u{1b}"
        for button in [saveButton, reloadButton, closeButton] { button.bezelStyle = .rounded }
        let actions = NSStackView(views: [reloadButton, NSView(), closeButton, saveButton]); actions.spacing = 8
        views += [status, actions]
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        controls()
    }
    private static func askDiscard(_ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = message
        alert.addButton(withTitle: "編集を続ける"); alert.addButton(withTitle: "変更を破棄")
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func controls() {
        let available = !busy && !closed
        for field in fields.values { field.isEnabled = available && snapshot != nil }
        saveButton.isEnabled = available && snapshot != nil
        reloadButton.isEnabled = available; closeButton.isEnabled = available
    }
    func confirmDiscard() -> Bool {
        guard !busy else { return false }
        let dirty = fields.contains { original[$0.key] != $0.value.stringValue }
        return !dirty || confirm("営業フロー設定の変更を破棄しますか？")
    }
    func start() { load() }
    private func display(_ value: NativeCRMFunnelSettings.Snapshot) {
        snapshot = value
        for spec in NativeCRMFunnelSettings.fields { fields[spec.key]?.stringValue = String(value.settings[keyPath: spec.path]) }
        original = fields.mapValues(\.stringValue)
    }
    private func load() {
        guard !busy, !closed else { return }; busy = true; controls()
        status.stringValue = "読み込んでいます…"; status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try api.load() }
            DispatchQueue.main.async { [self] in
                busy = false; guard !closed else { return }
                switch result {
                case let .success(value): display(value); status.stringValue = value.record == nil ? "初期設定を使用しています。変更する場合は保存してください。" : "設定を読み込みました。"
                case let .failure(error):
                    snapshot = nil; fields.values.forEach { $0.stringValue = "" }; original = fields.mapValues(\.stringValue)
                    status.stringValue = error.localizedDescription; status.textColor = .systemRed
                }
                controls()
            }
        }
    }
    @objc private func reload() { guard confirmDiscard() else { return }; load() }
    @objc private func save() {
        guard !busy, !closed, let expected = snapshot else { return }
        window.makeFirstResponder(nil)
        var value = expected.settings
        for spec in NativeCRMFunnelSettings.fields {
            guard let number = Int(fields[spec.key]!.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), spec.range.contains(number) else {
                status.stringValue = "\(spec.label)は\(spec.range.lowerBound)〜\(spec.range.upperBound)の整数で入力してください。"
                status.textColor = .systemRed; window.makeFirstResponder(fields[spec.key]); return
            }
            value[keyPath: spec.path] = number
        }
        busy = true; controls(); status.stringValue = "保存しています…"; status.textColor = .secondaryLabelColor
        let savedValue = value
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try api.save(savedValue, expected: expected) }
            DispatchQueue.main.async { [self] in
                busy = false; guard !closed else { return }
                switch result {
                case let .success(saved): display(saved); status.stringValue = "営業フローの設定を保存しました。"; onChanged?()
                case let .failure(error): status.stringValue = error.localizedDescription; status.textColor = .systemRed
                }
                controls()
            }
        }
    }
    @objc private func close() {
        guard !closed, confirmDiscard() else { return }; closed = true
        if let parent = window.sheetParent { parent.endSheet(window) }; window.close()
    }
    func windowWillClose(_ notification: Notification) { closed = true }
}
