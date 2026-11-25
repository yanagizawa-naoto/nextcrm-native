import AppKit

final class NativeE2BSettingsWindow: NSObject {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeE2BSettings
    private let key = NSSecureTextField(), template = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: ""), message = NSTextField(wrappingLabelWithString: "")
    private var snapshot: NativeE2BSetting?, busy = false
    private var buttons: [NSButton] = [], saveButton: NSButton!, removeButton: NSButton!
    var onChanged: (() -> Void)?
    init(api: NativeE2BSettings) throws {
        self.api = api; super.init(); window.title = "企業調査（E2B）の設定"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "営業先・担当者の自動調査で使用する共通設定です。管理者が保存できます。APIキーはこのMacのキーチェーンに保存し、環境設定がある場合はそちらを優先します。")
        status.setAccessibilityLabel("E2Bの利用状況"); status.maximumNumberOfLines = 4
        template.placeholderString = NativeE2BSettings.defaultTemplate
        key.placeholderString = "変更する場合だけ新しいキーを入力"
        let note = NSTextField(wrappingLabelWithString: "実行環境名には、E2B上に用意したNextCRMの調査用テンプレート名を入力してください。この画面で環境の作成や接続テストは行いません。調査を開始すると、AnthropicとE2Bに対象情報が送信され、利用料が発生します。Anthropicのキーは「AI連携の設定」で登録します。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        message.setAccessibilityLabel("E2B設定の結果"); message.maximumNumberOfLines = 3
        saveButton = button("接続設定を保存", #selector(save)); removeButton = button("保存したE2Bキーを削除…", #selector(remove))
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        let edits = NSStackView(views: [removeButton, NSView(), saveButton]); edits.spacing = 12
        let footer = NSStackView(views: [button("再読み込み", #selector(reload)), NSView(), close]); footer.spacing = 12
        InvoiceMailUI.layout(window, [title, help, status, InvoiceMailUI.row("実行環境名", template), InvoiceMailUI.row("E2B APIキー", key), edits, note, message, footer])
        try refresh()
    }
    private var canEdit: Bool { api.service.identity.role == "admin" }
    private func button(_ title: String, _ action: Selector) -> NSButton { let value = InvoiceMailUI.button(title, target: self, action: action); buttons.append(value); return value }
    private func controls() {
        buttons.forEach { $0.isEnabled = !busy }
        for value: NSControl in [key, template] { value.isEnabled = !busy && canEdit }
        saveButton.isEnabled = !busy && canEdit && snapshot != nil
        removeButton.isEnabled = !busy && canEdit && snapshot?.credentialID != nil
    }
    private func refresh() throws {
        snapshot = try api.setting(); template.stringValue = snapshot!.template
        do {
            let choice = try api.source()
            let keyState: String
            if let value = try api.resolve() { keyState = value.choice.source.title + "  " + value.masked }
            else { keyState = "未設定" }
            status.stringValue = "APIキー：" + keyState + "\n使用する実行環境：" + choice.template + (choice.template != snapshot!.template ? "（環境設定が優先されています）" : "") + (canEdit ? "" : "\n設定の変更は管理者に依頼してください。")
        } catch { status.stringValue = "E2Bのキーを読み取れません。管理者が接続設定を保存し直すか、キーチェーンを確認してください。" }
        controls()
    }
    private var dirty: Bool { !key.stringValue.isEmpty || snapshot.map { template.stringValue != $0.template } == true }
    func confirmDiscard() -> Bool { !busy && window.attachedSheet == nil && (!dirty || InvoiceMailUI.discard("入力中のE2B接続設定を保存せずに閉じますか？")) }
    @objc private func close() { if confirmDiscard() { key.stringValue = ""; window.sheetParent?.endSheet(window) } }
    private func run(_ success: String, action: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; controls(); message.textColor = .secondaryLabelColor; message.stringValue = "設定を更新しています…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try action() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                do {
                    try outcome.get(); self.key.stringValue = ""; try self.refresh()
                    self.message.textColor = .labelColor; self.message.stringValue = success; self.onChanged?()
                } catch { self.message.textColor = .systemRed; self.message.stringValue = error.localizedDescription }
                self.controls()
            }
        }
    }
    @objc private func save() {
        guard let snapshot, canEdit else { return }
        let api = api, value = NativeAIEnvironment.trim(key.stringValue), name = NativeAIEnvironment.trim(template.stringValue)
        run("E2Bの接続設定を保存しました。") { try api.save(snapshot, key: value.isEmpty ? nil : value, template: name.isEmpty ? NativeE2BSettings.defaultTemplate : name) }
    }
    @objc private func reload() {
        guard !dirty || InvoiceMailUI.discard("入力中のE2B接続設定を破棄して再読み込みしますか？") else { return }
        key.stringValue = ""
        do { try refresh(); message.textColor = .labelColor; message.stringValue = "設定を再読み込みしました。" }
        catch { snapshot = nil; controls(); message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    }
    @objc private func remove() {
        guard let snapshot, snapshot.credentialID != nil, canEdit, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "保存したE2Bの共通APIキーを削除しますか？"
        alert.informativeText = "環境設定にキーがある場合は、引き続きそのキーを使用します。実行環境名は保持します。"
        alert.addButton(withTitle: "削除する"); alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }; let api = self.api
            self.run("保存したE2Bキーを削除しました。") { try api.removeKey(snapshot) }
        }
    }
}
