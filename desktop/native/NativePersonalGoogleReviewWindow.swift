import AppKit

/// Restoration review only. Neither option calls Google or starts a worker.
@MainActor final class NativePersonalGoogleReviewWindow:NSObject {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:720,height:600),styleMask:[.titled],backing:.buffered,defer:false)
    private let api:NativePersonalProviderReview,ticket:NativePersonalProviderReview.GoogleTicket
    private let note=NSTextView(),error=NSTextField(wrappingLabelWithString:"")
    private let confirmed=NSButton(checkboxWithTitle:"対象のGoogleアカウントと予定を確認し、未反映であることを確認しました",target:nil,action:nil)
    private let notApplied=NSButton(title:"未反映の確認を記録",target:nil,action:nil)
    private var saved=false
    init(api:NativePersonalProviderReview,ticket:NativePersonalProviderReview.GoogleTicket) {
        self.api=api;self.ticket=ticket;super.init();window.title="Googleへの旧反映処理を確認"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:20,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"この画面はGoogleへ接続せず、予定を作成・変更・取消しません。反映済み、または確認できない場合は、結果を確定せず保留を記録してください。元の処理と証拠は保持します。")
        let scope=NSTextField(wrappingLabelWithString:ticket.scope.explanation);scope.isSelectable=true;scope.setAccessibilityLabel("保留するGoogle反映の範囲")
        let identifier=NSTextField(wrappingLabelWithString:"処理ID："+ticket.job.id+"\nCRM予定ID："+ticket.scope.activityID+"\nGoogleアカウント："+(ticket.scope.accountEmail ?? "特定できません")+"\nGoogle予定ID："+(ticket.scope.remoteEventID ?? "特定できません"));identifier.isSelectable=true
        let hint=NSTextField(wrappingLabelWithString:"未反映の確認を記録しても、再送用の処理は作成しません。保留の記録でも連携自体は再開しません。確認後は機能の再開画面へ戻ってください。")
        hint.font = .systemFont(ofSize:12);hint.textColor = .secondaryLabelColor
        confirmed.target=self;confirmed.action=#selector(update);confirmed.isEnabled=ticket.canConfirmNotApplied
        note.setAccessibilityLabel("Googleの確認内容");note.font = .systemFont(ofSize:13)
        let scroll=NSScrollView();scroll.documentView=note;scroll.hasVerticalScroller=true;scroll.heightAnchor.constraint(equalToConstant:100).isActive=true;note.isVerticallyResizable=true
        let hold=NSButton(title:"結果を確定せず保留を記録",target:self,action:#selector(saveHeld));hold.bezelStyle = .rounded
        notApplied.target=self;notApplied.action=#selector(saveNotApplied);notApplied.bezelStyle = .rounded
        let cancel=NSButton(title:"キャンセル",target:self,action:#selector(cancel));cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}"
        error.textColor = .systemRed;error.setAccessibilityLabel("Google旧処理の確認結果")
        let actions=NSStackView(views:[cancel,NSView(),notApplied,hold]);actions.spacing=8
        let stack=NSStackView(views:[title,help,identifier,scope,hint,confirmed,NSTextField(labelWithString:"確認した内容・保留の理由（必須・2,000文字以内）"),scroll,error,actions]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=14;stack.translatesAutoresizingMaskIntoConstraints=false
        let content=window.contentView!;content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:20),stack.bottomAnchor.constraint(lessThanOrEqualTo:content.bottomAnchor,constant:-20),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),actions.widthAnchor.constraint(equalTo:stack.widthAnchor)])
        update()
    }
    @objc private func update(){notApplied.isEnabled=ticket.canConfirmNotApplied && confirmed.state == .on}
    func confirmDiscard()->Bool {
        guard !saved, !note.string.isEmpty || confirmed.state == .on else{return true}
        let alert=NSAlert();alert.messageText="確認内容を保存せずに閉じますか？";alert.informativeText="旧処理の状態は変更しません。"
        alert.addButton(withTitle:"入力を続ける");alert.addButton(withTitle:"変更を破棄");return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel(){if confirmDiscard(){window.sheetParent?.endSheet(window)}}
    @objc private func saveNotApplied(){guard ticket.canConfirmNotApplied,confirmed.state == .on else{return};save{_ = try api.recordGoogleNotApplied(ticket,note:note.string)}}
    @objc private func saveHeld(){save{_ = try api.recordGoogleHeld(ticket,note:note.string)}}
    private func save(_ operation:()throws->Void){do{try operation();saved=true;window.sheetParent?.endSheet(window)}catch{self.error.stringValue=error.localizedDescription}}
}
