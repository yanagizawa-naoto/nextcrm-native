import AppKit

/// Admin-only connection settings. The stored secret is never placed in a text
/// control; an empty key means retain it when saving the same endpoint.
final class CRMCampaignRelaySettingsWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:640,height:520),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService
    private let store: CampaignRelayCredentialStore
    private let allowLoopbackHTTP: Bool
    private let request: CampaignRelayClient.Request
    private let clock: () -> Date
    private let address = NSTextField(), appName = NSTextField(), secret = NSSecureTextField()
    private let message = NSTextField(wrappingLabelWithString:"")
    private var saveButton: NSButton!, removeButton: NSButton!, closeButton: NSButton!, cancelButton: NSButton!
    private var initialAddress = "", initialName = "", hasKey = false
    private var busy = false
    private var task: Task<Void,Never>?
    var onSaved: (() -> Void)?

    init(service: CRMService, store: CampaignRelayCredentialStore, allowLoopbackHTTP: Bool = false, request: @escaping CampaignRelayClient.Request = CampaignRelayClient.network, clock: @escaping () -> Date = Date.init) throws {
        self.service = service; self.store = store; self.allowLoopbackHTTP = allowLoopbackHTTP; self.request = request; self.clock = clock
        let settings = try service.campaignRelayPreferences(store:store)
        super.init(); window.title = "キャンペーンの受信窓口"
        let heading = NSTextField(labelWithString:"配信停止・配信結果の受信窓口"); heading.font = .systemFont(ofSize:20,weight:.semibold)
        let explanation = NSTextField(wrappingLabelWithString:"Macを閉じている間も配信停止と配信結果を受け付けるサーバーに接続します。公開URLと、そのサーバーの接続キーを入力してください。")
        explanation.font = .systemFont(ofSize:13)
        address.placeholderString = "https://crm.example.com"; address.setAccessibilityLabel("受信窓口の公開URL")
        appName.setAccessibilityLabel("メールのアプリ名")
        secret.setAccessibilityLabel("受信窓口の接続キー")
        let grid = NSGridView(views:[[NSTextField(labelWithString:"公開URL"),address],[NSTextField(labelWithString:"メールのアプリ名"),appName],[NSTextField(labelWithString:"接続キー"),secret]])
        grid.rowSpacing = 12; grid.columnSpacing = 12; grid.column(at:0).xPlacement = .trailing; grid.column(at:1).xPlacement = .fill
        let keyHelp = NSTextField(wrappingLabelWithString:"保存済みのキーは表示されません。変更しない場合は、接続キーを空欄のまま保存できます。")
        keyHelp.font = .systemFont(ofSize:12); keyHelp.textColor = .secondaryLabelColor
        saveButton = NSButton(title:"接続を確認して保存",target:self,action:#selector(save)); saveButton.keyEquivalent = "\r"
        removeButton = NSButton(title:"接続キーを削除…",target:self,action:#selector(remove))
        cancelButton = NSButton(title:"接続確認を中止",target:self,action:#selector(cancel))
        closeButton = NSButton(title:"閉じる",target:self,action:#selector(close)); closeButton.keyEquivalent = "\u{1b}"
        for button in [saveButton,removeButton,cancelButton,closeButton] { button?.bezelStyle = .rounded }
        let buttons = NSStackView(views:[removeButton,cancelButton,NSView(),closeButton,saveButton]); buttons.spacing = 8
        message.font = .systemFont(ofSize:12); message.maximumNumberOfLines = 4
        let root = NSStackView(views:[heading,explanation,grid,keyHelp,message,NSView(),buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in [explanation,grid,keyHelp,message,buttons] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        apply(settings); controls()
    }
    private func apply(_ value: CRMService.CampaignRelayPreferences) {
        initialAddress = value.publicURL; initialName = value.appName; hasKey = value.configured
        address.stringValue = value.publicURL; appName.stringValue = value.appName; secret.stringValue = ""
        secret.placeholderString = value.configured ? "保存済み（変更時だけ入力）" : "接続キーを入力"
    }
    private func controls() {
        address.isEnabled = !busy; appName.isEnabled = !busy; secret.isEnabled = !busy
        saveButton.isEnabled = !busy; removeButton.isEnabled = !busy && hasKey; closeButton.isEnabled = !busy
        cancelButton.isHidden = !busy; cancelButton.isEnabled = busy
    }
    @objc private func save() {
        guard !busy else { return }
        let url = address.stringValue, name = appName.stringValue, key = secret.stringValue
        busy = true; controls(); message.stringValue = "接続と配信停止ページを確認しています…"; message.textColor = .secondaryLabelColor
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await self.service.saveCampaignRelaySettings(publicURL:url,appName:name,authKey:key,store:self.store,allowLoopbackHTTP:self.allowLoopbackHTTP,request:self.request,clock:self.clock)
                self.apply(try self.service.campaignRelayPreferences(store:self.store))
                self.message.stringValue = "接続を確認して保存しました。"; self.message.textColor = .secondaryLabelColor; self.onSaved?()
            } catch is CancellationError {
                self.message.stringValue = "接続確認を中止しました。"; self.message.textColor = .secondaryLabelColor
            } catch {
                self.message.stringValue = error.localizedDescription; self.message.textColor = .systemRed
            }
            self.busy = false; self.controls(); self.task = nil
        }
    }
    @objc private func cancel() { task?.cancel(); cancelButton.isEnabled = false; message.stringValue = "接続確認を中止しています…" }
    @objc private func remove() {
        guard !busy, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "受信窓口の接続キーを削除しますか？"
        alert.informativeText = "再接続にはキーの入力が必要です。配信停止の履歴と接続先の登録は保持されます。"
        alert.addButton(withTitle:"接続キーを削除"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.service.removeCampaignRelaySettings(store:self.store); self.apply(try self.service.campaignRelayPreferences(store:self.store))
                self.message.stringValue = "接続キーを削除しました。"; self.message.textColor = .secondaryLabelColor; self.controls(); self.onSaved?()
            } catch { self.message.stringValue = error.localizedDescription; self.message.textColor = .systemRed }
        }
    }
    func confirmDiscard() -> Bool {
        guard !busy, window.attachedSheet == nil else { return false }
        guard address.stringValue != initialAddress || appName.stringValue != initialName || !secret.stringValue.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "受信窓口の設定を保存せずに閉じますか？"
        alert.addButton(withTitle:"保存せずに閉じる"); alert.addButton(withTitle:"編集に戻る")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func close() { guard confirmDiscard() else { return }; if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) } }
}
