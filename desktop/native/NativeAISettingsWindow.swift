import AppKit

final class NativeAISettingsWindow: NSObject {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
    private let keys: NativeAIKeys
    private let provider = NSPopUpButton(), scope = NSPopUpButton(), key = NSSecureTextField()
    private let saved = NSTextField(wrappingLabelWithString: ""), message = NSTextField(wrappingLabelWithString: "")
    private var statuses: [NativeAIProvider: NSTextField] = [:]
    private var setting: NativeAIKeySetting?
    private var buttons: [NSButton] = [], removeButton: NSButton!
    private var busy = false, selectedProvider = 0, selectedScope = 0
    var onChanged: (() -> Void)?
    var onE2BSettings: ((NSWindow) -> Void)?
    var onChatGPTSettings: ((NSWindow) -> Void)? { didSet { controls() } }
    private var chatGPTButton: NSButton?

    init(keys: NativeAIKeys) throws {
        try keys.service.authenticated(); self.keys = keys
        super.init(); window.title = "AI連携の設定"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "APIキーはこのMacのキーチェーンに保存します。環境設定、共通キー、個人キーの順に優先して使用します。共通キーは管理者が設定できます。")
        var views: [NSView] = [title, help]
        for item in NativeAIProvider.allCases {
            provider.addItem(withTitle: item.title)
            let status = NSTextField(labelWithString: "未設定"); status.setAccessibilityLabel(item.title + "の利用状況"); status.lineBreakMode = .byTruncatingMiddle
            statuses[item] = status; views.append(InvoiceMailUI.row(item.title, status))
        }
        scope.addItems(withTitles: ["個人キー"])
        if keys.service.identity.role == "admin" { scope.addItem(withTitle: "共通キー（管理者）") }
        provider.target = self; provider.action = #selector(selectionChanged); scope.target = self; scope.action = #selector(selectionChanged)
        key.placeholderString = "新しいAPIキーを入力"; key.setAccessibilityLabel("AIのAPIキー")
        saved.setAccessibilityLabel("保存済みAPIキーの状態"); saved.textColor = .secondaryLabelColor
        message.setAccessibilityLabel("AI設定の結果"); message.maximumNumberOfLines = 3
        let note = NSTextField(wrappingLabelWithString: "保存したキーは、予約済みのAI処理でも使用します。検索データの更新や情報補完では対象の文章が外部サービスに送信され、API利用料が発生します。検索・文書の処理は「AI検索の処理」、連絡先の情報補完は「連絡先」メニューの「情報補完の履歴」で確認できます。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let reload = button("再読み込み", #selector(reload)), close = button("閉じる", #selector(close)), save = button("キーを保存", #selector(save))
        close.keyEquivalent = "\u{1b}"; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        removeButton = button("保存したキーを削除…", #selector(remove))
        let edits = NSStackView(views: [removeButton, NSView(), save]); edits.spacing = 12
        let e2b = button("企業調査（E2B）の設定…", #selector(openE2B))
        let chatGPT = button("ChatGPTで接続…", #selector(openChatGPT))
        chatGPTButton = chatGPT
        let footer = NSStackView(views: [reload, chatGPT, e2b, NSView(), close]); footer.spacing = 12
        views += [InvoiceMailUI.row("サービス", provider), InvoiceMailUI.row("保存先", scope), saved, InvoiceMailUI.row("APIキー", key), edits, note, message, footer]
        InvoiceMailUI.layout(window, views)
        try refresh()
    }
    private var selected: NativeAIProvider { NativeAIProvider.allCases[provider.indexOfSelectedItem] }
    private var selectedKeyScope: NativeAIKeyScope { scope.indexOfSelectedItem == 1 ? .system : .user }
    private func button(_ title: String, _ action: Selector) -> NSButton { let button = InvoiceMailUI.button(title, target: self, action: action); buttons.append(button); return button }
    private func controls() {
        for control: NSControl in [provider, scope, key] { control.isEnabled = !busy }
        buttons.forEach { $0.isEnabled = !busy }; removeButton.isEnabled = !busy && setting?.isSet == true
        chatGPTButton?.isEnabled = !busy && onChatGPTSettings != nil
    }
    private func refresh() throws {
        try keys.service.authenticated()
        setting = try keys.setting(selected, scope: selectedKeyScope)
        saved.stringValue = setting!.needsReplacement ? "以前の設定を読み取れないか、重複しています。新しいキーを保存して置き換えてください。" : setting!.isSet ? "この保存先にはキーが保存されています。変更する場合だけ新しいキーを入力してください。" : "この保存先のキーは未設定です。"
        for provider in NativeAIProvider.allCases {
            do {
                if let current = try keys.resolve(provider) { statuses[provider]?.stringValue = current.choice.source.title + "  " + current.masked }
                else { statuses[provider]?.stringValue = "未設定" }
            } catch { statuses[provider]?.stringValue = (try? keys.source(provider).title).map { $0 + "・読み取りを確認してください" } ?? "設定を確認してください" }
        }
        controls()
    }
    private func show(_ error: Error) { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    private func run(success: String, _ action: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; controls(); message.textColor = .secondaryLabelColor; message.stringValue = "設定を更新しています…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try action() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                switch result {
                case .success:
                    self.key.stringValue = ""
                    do { try self.refresh(); self.message.textColor = .labelColor; self.message.stringValue = success; self.onChanged?() } catch { self.show(error) }
                case let .failure(error): self.show(error)
                }
                self.controls()
            }
        }
    }
    func confirmDiscard() -> Bool { !busy && window.attachedSheet == nil && (key.stringValue.isEmpty || InvoiceMailUI.discard("入力中のAPIキーを保存せずに閉じますか？")) }
    @objc private func close() { if confirmDiscard() { key.stringValue = ""; window.sheetParent?.endSheet(window) } }
    @objc private func openE2B() { if !busy && window.attachedSheet == nil { onE2BSettings?(window) } }
    @objc private func openChatGPT() { if !busy && window.attachedSheet == nil { onChatGPTSettings?(window) } }
    @objc private func selectionChanged() {
        if !key.stringValue.isEmpty && !InvoiceMailUI.discard("入力中のAPIキーを破棄して、設定先を切り替えますか？") { provider.selectItem(at: selectedProvider); scope.selectItem(at: selectedScope); return }
        key.stringValue = ""; selectedProvider = provider.indexOfSelectedItem; selectedScope = scope.indexOfSelectedItem; message.stringValue = ""
        do { try refresh() } catch { setting = nil; show(error); controls() }
    }
    @objc private func reload() {
        guard key.stringValue.isEmpty || InvoiceMailUI.discard("入力中のAPIキーを破棄して再読み込みしますか？") else { return }
        key.stringValue = ""
        do { try refresh(); message.stringValue = "設定を再読み込みしました。"; message.textColor = .labelColor } catch { setting = nil; show(error); controls() }
    }
    @objc private func save() {
        guard let setting else { return }
        let value = NativeAIEnvironment.trim(key.stringValue), keys = keys
        run(success: "APIキーを保存しました。") { try keys.save(setting, key: value) }
    }
    @objc private func remove() {
        guard let setting, setting.isSet, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = selected.title + "の" + (selectedKeyScope == .system ? "共通キー" : "個人キー") + "を削除しますか？"
        alert.informativeText = "ほかの保存先にキーがある場合は、優先順位に従って切り替わります。"
        alert.addButton(withTitle: "削除する"); alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }; let keys = self.keys
            self.run(success: "保存したAPIキーを削除しました。") { try keys.remove(setting) }
        }
    }
}
