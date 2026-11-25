import AppKit

@MainActor final class NativePersonalSMTPReviewWindow:NSObject {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:720,height:480),styleMask:[.titled],backing:.buffered,defer:false)
    private let api:NativePersonalProviderReview,ticket:NativePersonalProviderReview.SMTPTicket
    private let outcome=NSPopUpButton(),note=NSTextField(),confirmation=NSButton(checkboxWithTitle:"上の選択を確認しました。旧メールは再送せず、新しい送信は別途作成します。",target:nil,action:nil)
    private let status=NSTextField(wrappingLabelWithString:"")
    private let save=NSButton(title:"確認結果を記録",target:nil,action:nil)
    private let options:[NativePersonalSMTPReview.Outcome]
    init(api:NativePersonalProviderReview,ticket:NativePersonalProviderReview.SMTPTicket){
        self.api=api;self.ticket=ticket
        options=ticket.canConfirmResult ? (ticket.knownAccepted ? [.unknownHeld,.sent]:[.unknownHeld,.sent,.notSent]):[.unknownHeld]
        super.init();window.title="復元したSMTPメールの確認"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:20,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"メールサービスの送信済みフォルダなどで結果を確認してください。分からない場合は旧メールを保留したまま、新しいメールだけを利用できます。この確認だけでは連携を再開しません。")
        let summary=NSTextField(wrappingLabelWithString:"件名：\(ticket.preview.subject)\n差出人：\(ticket.preview.from)\n宛先：\(ticket.preview.recipientsText)\nMessage-ID：\(String((ticket.job.payload["messageID"] ?? "").prefix(1000)))")
        outcome.addItems(withTitles:options.map(\.title));outcome.setAccessibilityLabel("旧SMTPメールの確認結果")
        note.placeholderString="確認した方法、または結果不明のまま保留する理由";note.setAccessibilityLabel("SMTP確認メモ")
        save.target=self;save.action=#selector(record);save.bezelStyle = .rounded
        let cancel=NSButton(title:"取消",target:self,action:#selector(close));cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}"
        status.maximumNumberOfLines=3
        InvoiceMailUI.layout(window,[title,help,summary,outcome,note,confirmation,status,NSStackView(views:[NSView(),cancel,save])])
    }
    func confirmDiscard()->Bool {note.stringValue.isEmpty || InvoiceMailUI.discard("確認結果を保存せずに閉じますか？")}
    @objc private func record(){
        guard confirmation.state == .on,options.indices.contains(outcome.indexOfSelectedItem) else{status.stringValue="確認内容を選び、確認欄にチェックしてください。";return}
        do{_ = try api.recordSMTP(ticket,outcome:options[outcome.indexOfSelectedItem],note:note.stringValue);window.sheetParent?.endSheet(window,returnCode:.OK);window.orderOut(nil)}
        catch{status.stringValue=error.localizedDescription}
    }
    @objc private func close(){guard confirmDiscard() else{return};window.sheetParent?.endSheet(window,returnCode:.cancel);window.orderOut(nil)}
}
