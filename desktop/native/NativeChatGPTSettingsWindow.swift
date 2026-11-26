import AppKit

/// On-demand AppKit UI. No web view, browser profile, Node runtime or background timer.
@MainActor final class NativeChatGPTSettingsWindow: NSObject {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 740, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
    let session: NativeChatGPTSession
    var onChanged: (() -> Void)?, onClosed: (() -> Void)?
    private let account = NSPopUpButton(), model = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "接続設定を読み込みます。"), message = NSTextField(wrappingLabelWithString: "")
    private let background = NSButton(checkboxWithTitle: "明示した自動文章処理にChatGPTプランを使用する", target: nil, action: nil)
    private let prompt = NSTextView(), output = NSTextView()
    private var ids: [String] = [], models: [NativeChatGPTInference.Model] = []
    private var controls: [NSControl] = [], task: Task<Void, Never>?, lastState: NativeChatGPTSession.State?, closed = false
    private let openBrowser: NativeChatGPTSession.OpenBrowser
    init(session: NativeChatGPTSession, openBrowser: @escaping NativeChatGPTSession.OpenBrowser = { url in
        try await MainActor.run { guard NSWorkspace.shared.open(url) else { throw NativeChatGPTError.invalid("ブラウザを開けません。標準ブラウザを確認してください。") } }
    }) {
        self.session = session; self.openBrowser = openBrowser; super.init(); window.title = "ChatGPT接続と文章作成"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: "ご本人のChatGPTプラン・クレジットを使用します。利用可否と上限はアカウント・ワークスペースの設定に従います。APIキー方式とは別の利用枠です。認証情報はこのMacのキーチェーンに保存します。")
        account.target = self; account.action = #selector(changeAccount); model.target = self; model.action = #selector(changeModel)
        account.setAccessibilityLabel("ChatGPTアカウント"); model.setAccessibilityLabel("ChatGPTモデル")
        controls += [account, model, background]
        background.target = self; background.action = #selector(changeBackground)
        status.setAccessibilityLabel("ChatGPT利用状態"); message.setAccessibilityLabel("ChatGPT操作結果"); message.maximumNumberOfLines = 3
        let login = button("Continue with ChatGPT", #selector(signIn)), reconnect = button("選択したアカウントに再接続", #selector(reconnect)), out = button("サインアウト", #selector(signOut))
        let use = button("ChatGPTプランを使用", #selector(usePlan)), api = button("APIキー方式を使用", #selector(useAPI)), usage = button("利用状況を管理 ↗", #selector(openUsage))
        let note = NSTextField(wrappingLabelWithString: "ログインでは既存の予約処理を開始しません。自動処理には個別の実行許可も必要です。検索用の埋め込み・企業調査など、この接続が対応しない機能にはAPIキーが必要です。入力した文章はOpenAIに送信されます。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let input = textBox(prompt, editable: true, height: 100), result = textBox(output, editable: false, height: 130)
        prompt.setAccessibilityLabel("ChatGPTへの文章または指示"); output.setAccessibilityLabel("ChatGPTの生成結果")
        let summary = button("要約する", #selector(summarize)), generate = button("文章を作成", #selector(generate))
        let cancel = NSButton(title: "処理を中止", target: self, action: #selector(cancelOperation))
        let close = NSButton(title: "閉じる", target: self, action: #selector(closeWindow)); close.keyEquivalent = "\u{1b}"
        let root = NSStackView(views: [title, help, row(login, reconnect, out), row(NSTextField(labelWithString: "アカウント"), account), status, row(use, api, usage), row(NSTextField(labelWithString: "モデル"), model, button("モデル再読込", #selector(reloadModels))), background, note, NSTextField(labelWithString: "文章・作成指示（64KBまで）"), input, row(summary, generate), result, message, row(cancel, NSView(), close)])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false
        let viewport = NSScrollView(frame: window.contentView!.bounds); viewport.hasVerticalScroller = true; viewport.autoresizingMask = [.width, .height]
        let content = NativeChatGPTFlippedView(frame: NSRect(x: 0, y: 0, width: 724, height: 980)); viewport.documentView = content; window.contentView = viewport; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22), root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title: title, target: self, action: action); controls.append(b); return b }
    private func row(_ views: NSView...) -> NSStackView { let s = NSStackView(views: views); s.spacing = 8; s.distribution = .fill; return s }
    private func textBox(_ text: NSTextView, editable: Bool, height: CGFloat) -> NSScrollView {
        text.isEditable = editable; text.isRichText = false; text.font = .systemFont(ofSize: 13); text.isVerticallyResizable = true
        text.textContainerInset = NSSize(width: 6, height: 6); text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = text
        text.autoresizingMask = [.width]; scroll.heightAnchor.constraint(equalToConstant: height).isActive = true; return scroll
    }
    func showSheet(on parent: NSWindow) { parent.beginSheet(window) { [weak self] _ in self?.onClosed?() }; start() }
    func start() { run { try await self.refresh(loadModels: true) } }
    func confirmDiscard() -> Bool { task == nil && window.attachedSheet == nil }
    func cancelAndDrain() async {
        closed = true; task?.cancel()
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        let owned = task; await owned?.value; task = nil; output.string = ""; prompt.string = ""
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !closed, task == nil else { return }; controls.forEach { $0.isEnabled = false }; prompt.isEditable = false
        message.textColor = .secondaryLabelColor; message.stringValue = "処理しています…"
        task = Task { [weak self] in
            guard let self else { return }
            do { try await work(); try Task.checkCancellation(); if self.message.stringValue == "処理しています…" { self.message.stringValue = "完了しました。" }; self.onChanged?() }
            catch is CancellationError { self.message.stringValue = "処理を中止しました。" }
            catch { self.message.textColor = .systemRed; self.message.stringValue = error.localizedDescription }
            self.task = nil
            if !self.closed { self.controls.forEach { $0.isEnabled = true }; self.prompt.isEditable = true }
        }
    }
    private func refresh(loadModels: Bool = false) async throws {
        let state = try await session.state(); try Task.checkCancellation(); lastState = state
        account.removeAllItems(); ids = state.accounts.map(\.id); account.addItems(withTitles: state.accounts.map(\.label))
        if let id = state.selected, let i = ids.firstIndex(of: id) { account.selectItem(at: i) }
        let selected = state.accounts.first { $0.id == state.selected }
        status.stringValue = selected == nil ? "未接続です。" : selected!.signedIn ? (selected!.planAllowed ? (state.useChatGPT ? "Using ChatGPT plan — ChatGPTプランを使用中" : "接続済み。文章生成はAPIキー方式です。") : "接続済みですがChatGPTプランの利用は未許可です。再接続して許可するか、APIキー方式を選んでください。") : "サインアウトしています。再接続できます。"
        background.state = selected?.backgroundConsent == true ? .on : .off
        if loadModels, selected?.planAllowed == true {
            models = try await session.models(); try Task.checkCancellation(); model.removeAllItems(); model.addItems(withTitles: models.map(\.name))
            if let slug = selected?.model, let index = models.firstIndex(where: { $0.slug == slug }) { model.selectItem(at: index) }
            else { model.selectItem(at: -1) }
        } else if selected?.planAllowed != true { models = []; model.removeAllItems() }
    }
    private func selectedID() throws -> String { guard ids.indices.contains(account.indexOfSelectedItem) else { throw NativeChatGPTError.invalid("アカウントを選択してください。") }; return ids[account.indexOfSelectedItem] }
    private func connect(id: String?) {
        run {
            try await self.session.signIn(registrationID: id, reconsent: id != nil && self.lastState?.accounts.first(where: { $0.id == id })?.planAllowed == false, openBrowser: self.openBrowser)
            try await self.refresh(loadModels: true)
            if let state = self.lastState, let account = state.accounts.first(where: { $0.id == state.selected }), account.planAllowed, !account.welcomed {
                let alert = NSAlert(); alert.messageText = "ChatGPTプランを使用します"; alert.informativeText = "対応する文章生成は、ご本人のChatGPTプラン・クレジットを利用します。利用状況と上限は「利用状況を管理」で確認できます。既存の自動処理は開始しません。"; alert.addButton(withTitle: "了解")
                _ = await self.confirm(alert); try Task.checkCancellation(); try await self.session.acknowledgeWelcome()
            }
        }
    }
    private func confirm(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler(operation: { await withCheckedContinuation { c in
            if Task.isCancelled || closed { c.resume(returning: .cancel); return }
            alert.beginSheetModal(for: window) { c.resume(returning: $0) }
        } }, onCancel: { Task { @MainActor [weak self] in if let self, self.window.attachedSheet === alert.window { self.window.endSheet(alert.window, returnCode: .cancel) } } })
    }
    @objc private func signIn() { connect(id: nil) }
    @objc private func reconnect() { if let id = try? selectedID() { connect(id: id) } }
    @objc private func changeAccount() { guard let id = try? selectedID() else { return }; run { try await self.session.selectAccount(id); try await self.refresh(loadModels: true) } }
    @objc private func changeModel() { guard models.indices.contains(model.indexOfSelectedItem) else { return }; let slug = models[model.indexOfSelectedItem].slug; run { try await self.session.selectModel(slug); try await self.refresh() } }
    @objc private func reloadModels() { run { try await self.refresh(loadModels: true) } }
    @objc private func usePlan() { run { try await self.session.useChatGPTPlan(); try await self.refresh(loadModels: true) } }
    @objc private func useAPI() { run { try await self.session.useAPIKey(); try await self.refresh() } }
    @objc private func changeBackground() {
        let allowed = background.state == .on
        run {
            if allowed {
                let alert = NSAlert(); alert.messageText = "自動文章処理にChatGPTプランを使用しますか？"; alert.informativeText = "実行を許可した自動処理では対象の文章をOpenAIへ送信し、ChatGPTの利用枠・クレジットを使います。この変更だけでは処理を開始しません。"; alert.addButton(withTitle: "許可する"); alert.addButton(withTitle: "キャンセル")
                guard await self.confirm(alert) == .alertFirstButtonReturn else { try await self.refresh(); return }
            }
            try await self.session.setBackgroundConsent(allowed); try await self.refresh()
        }
    }
    @objc private func signOut() {
        guard let id = try? selectedID() else { return }
        run { let remote = try await self.session.signOut(id); try await self.refresh(); self.message.stringValue = remote ? "サインアウトしました。" : "このMacからサインアウトしました。接続の失効は確認できませんでした。ChatGPTの設定でもアプリの接続を解除してください。" }
    }
    private func create(_ summary: Bool) {
        let input = prompt.string; output.string = ""
        run {
            let result = try await self.session.generate(instruction: summary ? "次の文章の目的と重要な内容を日本語で簡潔に要約してください。" : "ユーザーの指示に従い、日本語の文章を作成してください。事実を捏造しないでください。", input: input)
            try await self.session.validate(result.receipt); self.output.string = result.text
        }
    }
    @objc private func summarize() { create(true) }
    @objc private func generate() { create(false) }
    @objc private func cancelOperation() { task?.cancel() }
    @objc private func closeWindow() {
        guard !closed else { return }
        Task { [weak self] in guard let self else { return }; await self.cancelAndDrain(); if let parent = self.window.sheetParent { parent.endSheet(self.window) } else { self.window.close(); self.onClosed?() } }
    }
    @objc private func openUsage() { _ = NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }
}
private final class NativeChatGPTFlippedView: NSView { override var isFlipped: Bool { true } }
