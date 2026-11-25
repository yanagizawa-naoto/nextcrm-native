import AppKit

enum NativeMailComposeMode { case new, reply, forward
    var title:String { switch self { case .new:return "メールを作成"; case .reply:return "メールに返信"; case .forward:return "メールを転送" } }
}

final class NativeMailComposeWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:860,height:655),styleMask:[.titled],backing:.buffered,defer:false)
    private let service:CRMService, accountID:String, original:NativeMailAccountSettings
    private let to = NSTextField(), cc = NSTextField(), bcc = NSTextField(), subject = NSTextField(), body = NSTextView()
    private let message = NSTextField(wrappingLabelWithString:"")
    private let inReplyTo:String?, references:[String]
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.mail-compose")
    private var sendButton:NSButton!, cancelButton:NSButton!, busy = false, initial:[String] = []
    private(set) var queuedID:String?
    var onQueued:((String) -> Void)?
    init(service:CRMService,accountID:String,mode:NativeMailComposeMode = .new,sourceID:String? = nil) throws {
        self.service = service; self.accountID = accountID
        let account = try service.mailAccount(accountID); original = try service.mailSettings(account)
        var initialTo = "", initialSubject = "", initialBody = "", reply:String?
        if mode != .new {
            guard let sourceID else { throw NativeDBError.message("返信元のメールが見つかりません。") }
            let source = try service.mailMessage(sourceID)
            guard try service.mailBodyIsLoaded(source) else { throw NativeDBError.message("元のメールの本文を取得してから、もう一度お試しください。") }
            initialTo = mode == .reply ? source["fromEmail"].string : ""
            initialSubject = (mode == .reply ? "Re: " : "Fwd: ")+source["subject"].string
            let quoted = source["bodyText"] != .null ? source["bodyText"].string : try NativeMailText.quote(html:source["bodyHtml"].string)
            initialBody = "\n\n--- 元のメール ---\n"+quoted
            let id = source["rfcMessageId"].string
            if mode == .reply, id.utf8.count <= 998, id.range(of:"^<[^<>\\s@]+@[^<>\\s@]+>$",options:.regularExpression) != nil { reply = id }
        }
        inReplyTo = reply; references = reply.map{[$0]} ?? []
        super.init(); window.title = mode.title
        let title = NSTextField(labelWithString:mode.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let sender = NSTextField(wrappingLabelWithString:"差出人："+original.username+"（"+original.label+"）"); sender.isSelectable = true
        to.stringValue = initialTo; subject.stringValue = initialSubject; body.string = initialBody
        to.placeholderString = "recipient@example.com"; cc.placeholderString = "任意"; bcc.placeholderString = "他の受信者には表示されません"
        let help = NSTextField(wrappingLabelWithString:"複数の宛先はカンマで区切ります。送信を受け付けると、この画面を閉じて処理を続けます。結果は「送信履歴」で確認できます。")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let text = InvoiceMailUI.textScroll(body,height:260); body.setAccessibilityLabel("メール本文")
        message.maximumNumberOfLines = 3; message.setAccessibilityLabel("メール作成の結果"); message.textColor = .systemRed
        cancelButton = InvoiceMailUI.button("キャンセル",target:self,action:#selector(close)); cancelButton.keyEquivalent = "\u{1b}"
        sendButton = InvoiceMailUI.button("送信",target:self,action:#selector(send)); sendButton.keyEquivalent = "\r"; sendButton.keyEquivalentModifierMask = .command
        let footer = NSStackView(views:[NSView(),cancelButton,sendButton]); footer.spacing = 12
        InvoiceMailUI.layout(window,[title,sender,InvoiceMailUI.row("宛先（To）",to),InvoiceMailUI.row("Cc",cc),InvoiceMailUI.row("Bcc",bcc),InvoiceMailUI.row("件名",subject),help,text,message,footer]); initial = fingerprint
    }
    private var fingerprint:[String] { [to.stringValue,cc.stringValue,bcc.stringValue,subject.stringValue,body.string] }
    func confirmDiscard() -> Bool { !busy && (queuedID != nil || initial == fingerprint || InvoiceMailUI.discard("作成中のメールを保存せずに閉じますか？")) }
    @objc private func close() { guard confirmDiscard() else { return }; window.sheetParent?.endSheet(window) }
    private func controls() { [to,cc,bcc,subject].forEach{$0.isEnabled = !busy}; body.isEditable = !busy; sendButton.isEnabled = !busy && queuedID == nil; cancelButton.isEnabled = !busy }
    @objc private func send() {
        guard !busy && queuedID == nil else { return }
        // Parse in the service, after capturing the whole field. A comma may
        // belong to a quoted display name or quoted local-part.
        func recipients(_ field:NSTextField) -> [String] { [field.stringValue] }
        let draft = NativeMailDraft(to:recipients(to),cc:recipients(cc),bcc:recipients(bcc),subject:subject.stringValue,body:body.string,inReplyTo:inReplyTo,references:references)
        busy = true; controls(); message.stringValue = "送信内容を保存しています…"
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { () -> String in
                let account = try self.service.mailAccount(self.accountID), settings = try self.service.mailSettings(account)
                // Synchronization changes the account revision; only sender and
                // transport changes require recomposing an already open draft.
                guard settings.username == self.original.username && settings.smtp == self.original.smtp else { throw NativeDBError.message("作成中に送信元の設定が変更されました。内容をコピーしてから、作成画面を開き直してください。") }
                return try self.service.queueMailSend(account:account,draft:draft)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                switch result {
                case let .success(id):self.queuedID = id; self.initial = self.fingerprint; self.message.stringValue = "送信待ちに追加しました。"; self.onQueued?(id); self.window.sheetParent?.endSheet(self.window)
                case let .failure(error):self.message.stringValue = error.localizedDescription
                }; self.controls()
            }
        }
    }
}
