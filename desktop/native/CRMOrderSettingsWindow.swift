import AppKit

final class CRMOrderSettingsWindow: NSObject, NSTextFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:720,height:510),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let original: NativeRecord
    private let name = NSTextField(); private let template = NSTextField(); private let reset = NSPopUpButton()
    private let active = NSButton(checkboxWithTitle:"この採番設定を有効にする",target:nil,action:nil)
    private let emails = NSButton(checkboxWithTitle:"承認申請・承認結果をメールで通知する",target:nil,action:nil)
    private let preview = NSTextField(labelWithString:""); private let errorLabel = NSTextField(wrappingLabelWithString:"")
    private var initial: [String] = []
    init(service: CRMService) throws {
        guard service.identity.role == "admin" else { throw NativeDBError.message("受注の設定は管理者が行ってください。") }
        self.service = service
        guard let series = try service.db.page("NumberSeries",fields:service.db.schema.model("NumberSeries").fields.map(\.name),equal:["scope":.text("order"),"isDefault":.integer(1)],sort:"createdAt").rows.first else { throw NativeDBError.message("受注の採番設定が見つかりません。") }
        original = series; super.init(); window.title = "受注の設定"
        name.stringValue = series["name"].string; template.stringValue = series["template"].string
        reset.addItems(withTitles:["毎年リセット","リセットしない"]); reset.selectItem(at:series["resetPolicy"] == .text("YEARLY") ? 0 : 1)
        reset.target = self; reset.action = #selector(updatePreview); template.delegate = self
        active.state = series["active"] == .integer(1) ? .on : .off
        emails.state = try service.db.get("crm_SystemSettings",key:["key":.text("orders_approval_emails")])?["value"] == .text("false") ? .off : .on
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"{YYYY}は年、{####}は4桁の連番です。毎年リセットする場合は年を含めてください。保存済みの受注番号は変更されません。")
        var views: [NSView] = [title,help]
        for (label,control) in [("設定名",name as NSView),("採番書式",template as NSView),("リセット",reset as NSView)] {
            let text = NSTextField(labelWithString:label); text.widthAnchor.constraint(equalToConstant:110).isActive = true
            control.setAccessibilityLabel(label); control.widthAnchor.constraint(equalToConstant:530).isActive = true
            let row = NSStackView(views:[text,control]); row.spacing = 12; views.append(row)
        }
        let info = NSTextField(wrappingLabelWithString:"有効にすると管理者・マネージャーへ承認依頼、作成者へ承認結果を送信します。「メール送信の設定」で差出人とAPIキーを設定してください。処理状況は各受注の「通知状況」で確認できます。")
        info.textColor = .secondaryLabelColor; info.font = .systemFont(ofSize:12)
        views += [preview,active,emails,info,errorLabel]
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize:12)
        let cancel = NSButton(title:"キャンセル",target:self,action:#selector(cancel)); cancel.keyEquivalent = "\u{1b}"; cancel.bezelStyle = .rounded
        let save = NSButton(title:"設定を保存",target:self,action:#selector(save)); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; save.bezelStyle = .rounded
        let footer = NSStackView(views:[NSView(),cancel,save]); footer.spacing = 12; views.append(footer)
        let root = NSStackView(views:views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 16; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in [help,preview,info,errorLabel,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        initial = values; updatePreview()
    }
    private var values: [String] { [name.stringValue,template.stringValue,String(reset.indexOfSelectedItem),String(active.state.rawValue),String(emails.state.rawValue)] }
    @objc private func updatePreview() {
        let year = OrderNumber.year(Date()); let old = Int64(original["counter"].string) ?? 0
        let counter = reset.indexOfSelectedItem == 0 && original["currentYear"] != .integer(Int64(year)) ? 1 : old+1
        preview.stringValue = "次回の番号（参考）："+OrderNumber.format(template.stringValue,year:year,counter:counter)+"\n使用済み連番：\(old)"
    }
    func controlTextDidChange(_ notification: Notification) { updatePreview() }
    func confirmDiscard() -> Bool {
        window.makeFirstResponder(nil); guard values != initial else { return true }
        let alert = NSAlert(); alert.messageText = "設定の変更を破棄しますか？"; alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"変更を破棄"); return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel() { if confirmDiscard() { window.sheetParent?.endSheet(window) } }
    @objc private func save() {
        window.makeFirstResponder(nil)
        do { _ = try service.saveOrderSettings(original,name:name.stringValue,template:template.stringValue,reset:reset.indexOfSelectedItem == 0 ? "YEARLY" : "NEVER",active:active.state == .on,emails:emails.state == .on); window.sheetParent?.endSheet(window) }
        catch { errorLabel.stringValue = error.localizedDescription }
    }
}
