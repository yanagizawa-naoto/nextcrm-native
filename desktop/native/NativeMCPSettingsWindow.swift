import AppKit

/// A listener is opened only after saving an enabled configuration. Network
/// lifecycle and Keychain operations run outside the main actor.
final class NativeMCPSettingsWindow: NSObject, NSTextFieldDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
    private let settings: NativeMCPSettingsStore
    private let runtime: NativeMCPRuntime?
    private let allowsWorkerStart: Bool
    private let enabled = NSButton(checkboxWithTitle: "このMacからのMCP接続を有効にする", target: nil, action: nil)
    private let port = NSTextField(), connections = NSTextField()
    private let rotate = NSButton(checkboxWithTitle: "署名キーを再作成する", target: nil, action: nil)
    private let endpoint = NSTextField(labelWithString: ""), runtimeState = NSTextField(labelWithString: ""), status = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!, refreshButton: NSButton!, closeButton: NSButton!, copyButton: NSButton!
    private var saved: NativeMCPSettings?, busy = false, closed = false
    private var operation: Task<Void, Never>?

    init(settings: NativeMCPSettingsStore, runtime: NativeMCPRuntime? = nil, allowsWorkerStart: Bool = true) {
        self.settings = settings; self.runtime = runtime; self.allowsWorkerStart = allowsWorkerStart && runtime != nil
        super.init(); window.title = "MCP接続の設定"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "このMac上の外部ツールからCRMを操作できます。接続先と「APIトークン」で作成したトークンを、外部ツールのMCP設定に入力してください。アプリを終了すると接続も停止します。")
        enabled.target = self; enabled.action = #selector(changed)
        port.setAccessibilityLabel("MCPのポート番号"); connections.setAccessibilityLabel("MCPの最大同時接続数")
        port.delegate = self; connections.delegate = self
        port.widthAnchor.constraint(equalToConstant: 110).isActive = true; connections.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let fields = NSStackView(views: [NSTextField(labelWithString: "ポート番号"), port, NSTextField(labelWithString: "同時接続数"), connections, NSView()]); fields.spacing = 10
        let bounds = NSTextField(labelWithString: "ポート番号：1024〜65535　同時接続数：2〜32"); bounds.textColor = .secondaryLabelColor; bounds.font = .systemFont(ofSize: 11)
        runtimeState.setAccessibilityLabel("MCPの接続状態")
        endpoint.isSelectable = true; endpoint.font = .monospacedSystemFont(ofSize: 12, weight: .regular); endpoint.lineBreakMode = .byTruncatingMiddle; endpoint.setAccessibilityLabel("MCPの接続先")
        copyButton = button("接続先をコピー", #selector(copyEndpoint))
        let address = NSStackView(views: [endpoint, copyButton]); address.spacing = 8
        rotate.target = self; rotate.action = #selector(changed)
        let rotationHelp = NSTextField(wrappingLabelWithString: "キーの再作成は接続の復旧時などに使います。発行済みの文書リンクとMCP用のログインセッションは無効になります。APIトークンはそのまま使えます。")
        rotationHelp.font = .systemFont(ofSize: 11); rotationHelp.textColor = .secondaryLabelColor
        saveButton = button(self.allowsWorkerStart ? "保存して適用" : "設定を保存", #selector(save)); saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = .command
        refreshButton = button("再読み込み", #selector(refresh)); closeButton = button("閉じる", #selector(close)); closeButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [refreshButton, NSView(), closeButton, saveButton]); footer.spacing = 8
        status.maximumNumberOfLines = 3; status.setAccessibilityLabel("MCP設定の操作結果")
        let views: [NSView] = [title, help, enabled, fields, bounds, runtimeState, address, rotate, rotationHelp, status, footer]
        let root = NSStackView(views: views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20)])
        for view in views { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        controls()
    }
    deinit { operation?.cancel() }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .rounded; return b }
    func start() { load() }
    private var dirty: Bool {
        guard let saved else { return false }
        return (enabled.state == .on) != saved.enabled || port.stringValue != String(saved.port) || connections.stringValue != String(saved.maximumConnections) || rotate.state == .on
    }
    private func controls() {
        let editable = saved != nil && !busy
        for control: NSControl in [enabled, port, connections] { control.isEnabled = editable }
        rotate.isEnabled = editable && enabled.state == .on
        saveButton.isEnabled = editable; refreshButton.isEnabled = !busy; closeButton.isEnabled = !busy
        copyButton.isEnabled = !busy && !endpoint.stringValue.isEmpty
    }
    @objc private func changed() { if enabled.state != .on { rotate.state = .off }; controls() }
    func controlTextDidChange(_ obj: Notification) { controls() }
    private func apply(_ value: NativeMCPSettings) {
        saved = value; enabled.state = value.enabled ? .on : .off; port.stringValue = String(value.port); connections.stringValue = String(value.maximumConnections); rotate.state = .off
    }
    private func showHeld() {
        runtimeState.stringValue = "接続受付は再開の確認待ちです。設定の保存だけを行います。"
        endpoint.stringValue = ""
    }
    private func show(_ snapshot: NativeMCPRuntime.Snapshot) {
        switch snapshot.state {
        case .disabled: runtimeState.stringValue = "無効"
        case .stopped: runtimeState.stringValue = "停止中"
        case .starting: runtimeState.stringValue = "起動中…"
        case .running: runtimeState.stringValue = "接続受付中（現在 \(snapshot.connections) 接続）"
        case .stopping: runtimeState.stringValue = "停止しています…"
        case .failed: runtimeState.stringValue = "起動できませんでした"
        }
        endpoint.stringValue = snapshot.endpoint ?? ""
        if let message = snapshot.message { status.stringValue = message; status.textColor = .systemRed }
    }
    private func load() {
        guard !busy, !closed else { return }; busy = true; status.textColor = .secondaryLabelColor; status.stringValue = "読み込んでいます…"; controls()
        operation = Task { @MainActor [self] in
            let result = await Task.detached { [settings] in Result { try settings.snapshot() } }.value
            let state = allowsWorkerStart ? await runtime?.snapshot() : nil
            guard !closed else { return }; busy = false
            switch result {
            case let .success(value): apply(value); status.stringValue = ""; if let state { show(state) } else { showHeld() }
            case let .failure(error): saved = nil; endpoint.stringValue = ""; runtimeState.stringValue = "—"; status.textColor = .systemRed; status.stringValue = error.localizedDescription
            }
            controls(); operation = nil
        }
    }
    @objc private func refresh() { guard !busy, confirmDiscard() else { return }; load() }
    @objc private func save() {
        guard !busy, !closed, let saved else { return }
        guard let port = Int(port.stringValue), (1024...65535).contains(port), let maximum = Int(connections.stringValue), (2...32).contains(maximum) else {
            status.textColor = .systemRed; status.stringValue = NativeMCPSettingsError.invalid.localizedDescription; return
        }
        let enabled = enabled.state == .on, rotateSecret = rotate.state == .on
        busy = true; controls(); status.textColor = .secondaryLabelColor; status.stringValue = "設定を適用しています…"
        operation = Task { @MainActor [self] in
            let result = await Task.detached { [settings] in Result { try settings.save(expected: saved, enabled: enabled, port: port, maximumConnections: maximum, rotateSecret: rotateSecret) } }.value
            switch result {
            case let .failure(error): status.textColor = .systemRed; status.stringValue = error.localizedDescription
            case let .success(value):
                apply(value)
                if !allowsWorkerStart || runtime == nil {
                    status.textColor = .secondaryLabelColor; status.stringValue = "設定を保存しました。接続受付は確認が終わるまで開始しません。"; showHeld()
                } else if let runtime { do {
                    if value.enabled { _ = try await runtime.restart() } else { await runtime.stop() }
                    status.textColor = .secondaryLabelColor; status.stringValue = "設定を保存しました。"; show(await runtime.snapshot())
                } catch {
                    let state = await runtime.snapshot()
                    show(state); status.textColor = .systemRed; status.stringValue = "設定は保存しましたが、接続を開始できませんでした。\(state.message ?? error.localizedDescription)"
                } }
            }
            busy = false; controls(); operation = nil
        }
    }
    @objc private func copyEndpoint() {
        guard !busy, !endpoint.stringValue.isEmpty else { return }
        NSPasteboard.general.clearContents()
        status.textColor = .secondaryLabelColor; status.stringValue = NSPasteboard.general.setString(endpoint.stringValue, forType: .string) ? "接続先をコピーしました。" : "コピーできませんでした。接続先を選択してコピーしてください。"
    }
    func confirmDiscard() -> Bool {
        guard !busy else { return false }; guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "MCP設定の変更を破棄しますか？"; alert.informativeText = "まだ保存していない変更があります。"; alert.addButton(withTitle: "破棄する"); alert.addButton(withTitle: "編集を続ける")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func close() {
        guard confirmDiscard() else { return }; closed = true
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }
}
