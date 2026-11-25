import AppKit

/// Selects one concrete follow-up operation. The parent performs it only after
/// this sheet has ended and been released, before any Host policy transition.
/// No database, secret store, runtime or background task is owned by this view.
@MainActor final class NativePersonalRuntimeWindow:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    enum Action {case configure,review,resume,stop}
    struct Intent {let group:NativePersonalRuntimeGroup,action:Action}
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:790,height:680),styleMask:[.titled],backing:.buffered,defer:false)
    private(set) var intent:Intent?
    private let groups=NativePersonalRuntimeGroup.allCases
    private let enabled:Set<NativePersonalRuntimeGroup>,settingsAvailable:Set<NativePersonalRuntimeGroup>
    private let reviewReason:String?
    private let table=NSTableView(),detail=NSTextField(wrappingLabelWithString:"")
    private let configure=NSButton(title:"接続・動作の設定…",target:nil,action:nil)
    private let review=NSButton(title:"再開前の確認…",target:nil,action:nil)
    private let resume=NSButton(title:"有効にする…",target:nil,action:nil)
    private let stop=NSButton(title:"停止する…",target:nil,action:nil)
    private let close=NSButton(title:"閉じる",target:nil,action:nil)
    private var closed=false
    init(enabled:Set<NativePersonalRuntimeGroup>,settingsAvailable:Set<NativePersonalRuntimeGroup>,reviewReason:String?) {
        self.enabled=enabled;self.settingsAvailable=settingsAvailable;self.reviewReason=reviewReason
        super.init();window.title="復元後の機能と連携"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:22,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"使う機能を選び、接続先と復元前の処理を確認してから有効にします。設定画面を開くだけでは自動処理は再開しません。取引先など、このMacでの編集は引き続き使えます。")
        help.font = .systemFont(ofSize:12);help.textColor = .secondaryLabelColor
        table.dataSource=self;table.delegate=self;table.rowHeight=29;table.allowsMultipleSelection=false
        table.setAccessibilityLabel("復元後の機能と連携の一覧")
        for (id,title,width) in [("feature","機能",470.0),("state","現在の状態",210.0)] {
            let column=NSTableColumn(identifier:.init(id));column.title=title;column.width=width;table.addTableColumn(column)
        }
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:400).isActive=true
        detail.font = .systemFont(ofSize:12);detail.maximumNumberOfLines=3;detail.setAccessibilityLabel("選択した機能の説明")
        for (button,action) in [(configure,#selector(configureSelected)),(review,#selector(reviewSelected)),(resume,#selector(resumeSelected)),(stop,#selector(stopSelected)),(close,#selector(closeRequested))] {
            button.target=self;button.action=action;button.bezelStyle = .rounded
        }
        close.keyEquivalent="\u{1b}"
        let actions=NSStackView(views:[configure,review,NSView(),resume,stop]);actions.spacing=8
        let footer=NSStackView(views:[NSView(),close]);footer.spacing=8
        InvoiceMailUI.layout(window,[title,help,scroll,detail,actions,footer]);updateControls()
    }
    private var selected:NativePersonalRuntimeGroup? {groups.indices.contains(table.selectedRow) ? groups[table.selectedRow]:nil}
    private func updateControls() {
        let group=selected
        configure.isEnabled = !closed && group.map{settingsAvailable.contains($0)}==true
        review.isEnabled = !closed && group != nil
        resume.isEnabled = !closed && group.map{!enabled.contains($0)}==true
        stop.isEnabled = !closed && group.map{enabled.contains($0)}==true
        if let group {
            detail.stringValue=enabled.contains(group) ? "\(group.title)は有効です。停止すると、新しい処理の開始を止め、実行中の処理が終わるのを待ちます。" : reviewReason ?? "\(group.title)は停止しています。接続・設定と、復元前の予約や同期状態を確認してください。"
        }else{detail.stringValue=reviewReason ?? "使う機能を選んでください。利用しない連携先のアカウントを用意する必要はありません。"}
    }
    private func request(_ action:Action) {
        guard !closed,let group=selected else{return}
        if case .configure=action {guard settingsAvailable.contains(group) else{return}}
        if case .resume=action {guard !enabled.contains(group) else{return}}
        if case .stop=action {guard enabled.contains(group) else{return}}
        intent=Intent(group:group,action:action);finish(.OK)
    }
    @objc private func configureSelected(){request(.configure)}
    @objc private func reviewSelected(){request(.review)}
    @objc private func resumeSelected(){request(.resume)}
    @objc private func stopSelected(){request(.stop)}
    @objc private func closeRequested(){finish(.cancel)}
    func closeAfterConfirmation(){intent=nil;finish(.cancel)}
    func confirmDiscard()->Bool {true}
    private func finish(_ response:NSApplication.ModalResponse) {
        guard !closed else{return};closed=true;updateControls()
        window.sheetParent?.endSheet(window,returnCode:response);window.orderOut(nil)
    }
    func numberOfRows(in tableView:NSTableView)->Int {groups.count}
    func tableViewSelectionDidChange(_ notification:Notification){updateControls()}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        guard groups.indices.contains(row),let column else{return nil}
        let group=groups[row],value=column.identifier.rawValue=="feature" ? group.title : enabled.contains(group) ? "有効" : "停止中"
        let field=NSTextField(labelWithString:value);field.lineBreakMode = .byTruncatingTail;return field
    }
}
