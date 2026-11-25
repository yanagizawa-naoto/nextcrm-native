import AppKit

/// A bounded source-job list. The existing receipt editor owns the actual form.
@MainActor final class NativePersonalProviderReviewWindow:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:900,height:580),styleMask:[.titled],backing:.buffered,defer:false)
    private let api:NativePersonalProviderReview
    private let activities:NativeRestoreParentActivities?
    private let table=NSTableView(),status=NSTextField(wrappingLabelWithString:""),count=NSTextField(labelWithString:"")
    private let review=NSButton(title:"処理結果を確認…",target:nil,action:nil)
    private let previous=NSButton(title:"前の100件",target:nil,action:nil),next=NSButton(title:"次の100件",target:nil,action:nil)
    private let closeButton=NSButton(title:"閉じる",target:nil,action:nil)
    private var rows:[NativePersonalProviderReview.Row]=[],offset=0,total=0,busy=false,closing=false,closed=false
    private var work:Task<Void,Never>?,reviewWindow:CRMJobReviewWindow?
    private var smtpReviewWindow:NativePersonalSMTPReviewWindow?
    private var googleReviewWindow:NativePersonalGoogleReviewWindow?
    init(api:NativePersonalProviderReview,activities:NativeRestoreParentActivities? = nil){
        self.api=api;self.activities=activities;super.init();window.title="復元した旧処理の確認"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:22,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"旧データに保存されていた処理を確認します。表示は復元時の状態です。確認結果を記録しても外部連携は再開せず、この画面から再送もしません。")
        help.font = .systemFont(ofSize:12);help.textColor = .secondaryLabelColor
        table.dataSource=self;table.delegate=self;table.rowHeight=34;table.allowsMultipleSelection=false;table.setAccessibilityLabel("復元した旧処理の一覧")
        for(id,title,width) in [("event","種類",230.0),("id","処理ID",350.0),("state","復元時の状態",180.0)] {let col=NSTableColumn(identifier:.init(id));col.title=title;col.width=width;table.addTableColumn(col)}
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        for(button,action) in [(review,#selector(openReview)),(previous,#selector(previousPage)),(next,#selector(nextPage)),(closeButton,#selector(closeRequested))] {button.target=self;button.action=action;button.bezelStyle = .rounded}
        closeButton.keyEquivalent="\u{1b}"
        let actions=NSStackView(views:[review,NSView()]);actions.spacing=10
        let footer=NSStackView(views:[previous,count,next,NSView(),closeButton]);footer.spacing=10
        status.font = .systemFont(ofSize:12);status.maximumNumberOfLines=3;status.setAccessibilityLabel("旧処理の確認状態")
        InvoiceMailUI.layout(window,[title,help,scroll,actions,status,footer]);controls()
    }
    func start(){load()}
    /// The host has already obtained discard confirmation, or is tearing down a
    /// failed launch. Cancellation is a request; accepted index work is joined.
    func closeAfterConfirmationAndDrain()async {
        closing=true;controls();work?.cancel()
        if let task=work {await task.value}
        if let editor=reviewWindow {window.endSheet(editor.window,returnCode:.cancel);reviewWindow=nil}
        if let editor=smtpReviewWindow {window.endSheet(editor.window,returnCode:.cancel);smtpReviewWindow=nil}
        if let editor=googleReviewWindow {window.endSheet(editor.window,returnCode:.cancel);googleReviewWindow=nil}
        finishClose()
    }
    func confirmDiscard()->Bool {!busy && (reviewWindow?.confirmDiscard() ?? true) && (smtpReviewWindow?.confirmDiscard() ?? true) && (googleReviewWindow?.confirmDiscard() ?? true)}
    private var selected:NativePersonalProviderReview.Row? {rows.indices.contains(table.selectedRow) ? rows[table.selectedRow]:nil}
    private func controls(){
        let idle = !busy && !closing && !closed && reviewWindow==nil && smtpReviewWindow==nil && googleReviewWindow==nil
        table.isEnabled=idle;review.isEnabled=idle && selected.map{$0.eventLabel != "未対応の処理（保留）"}==true
        previous.isEnabled=idle && offset>0;next.isEnabled=idle && offset+rows.count<total
        closeButton.title=busy ? "読み込みを中止して閉じる":"閉じる"
    }
    private func load(){
        guard !busy,!closed,!closing,reviewWindow==nil && smtpReviewWindow==nil && googleReviewWindow==nil else{return};busy=true;controls();status.stringValue="復元計画と現在の利用権限を確認しています…"
        let position=offset,api=self.api
        let operation: @MainActor ()async->Void = { [weak self] in
            guard let self else{return}
            let child=Task.detached(priority:.userInitiated){try api.page(offset:position)}
            let result=await withTaskCancellationHandler(operation:{await child.result},onCancel:{child.cancel()})
            self.work=nil;self.busy=false
            if self.closing {self.finishClose();return}
            switch result {
            case let .success(page):
                self.rows=page.rows;self.total=page.total;self.count.stringValue="\(page.total==0 ? 0:position+1)〜\(position+page.rows.count) ／ \(page.total)件"
                self.status.stringValue="確認する処理を選んでください。隔離済みの旧メール・Google予定は結果を確認できます。未対応・送信開始の記録がない処理は保持します。確認画面は5分以内に記録してください。"
            case let .failure(error):self.rows=[];self.total=0;self.count.stringValue="—";self.status.stringValue=error.localizedDescription
            }
            self.table.deselectAll(nil);self.table.reloadData();self.controls()
        }
        if let activities {
            work=activities.spawn(owner:"personal-provider-review",kind:.readOnly){await operation()}
            if work==nil {busy=false;status.stringValue="終了準備中のため、確認画面を読み込めません。";controls()}
        }else{work=Task{await operation()}}
    }
    @objc private func previousPage(){guard !busy,offset>0 else{return};offset=max(0,offset-100);load()}
    @objc private func nextPage(){guard !busy,offset+rows.count<total else{return};offset+=100;load()}
    @objc private func openReview(){
        guard !busy,!closed,!closing,reviewWindow==nil && smtpReviewWindow==nil && googleReviewWindow==nil,let row=selected else{return}
        do {
            if row.event==NativeMailDelivery.event {
                let editor=NativePersonalSMTPReviewWindow(api:api,ticket:try api.prepareSMTP(row));smtpReviewWindow=editor;controls()
                window.beginSheet(editor.window){[weak self] _ in
                    guard let self else{return};self.smtpReviewWindow=nil
                    if self.closing{self.finishClose()}else{self.status.stringValue="SMTPの確認画面を閉じました。旧メールは再送しません。機能の再開は利用設定で確認してください。";self.controls()}
                };return
            }
            if row.event==GoogleCalendarOutbound.event {
                let editor=NativePersonalGoogleReviewWindow(api:api,ticket:try api.prepareGoogle(row));googleReviewWindow=editor;controls()
                window.beginSheet(editor.window){[weak self] _ in
                    guard let self else{return};self.googleReviewWindow=nil
                    if self.closing{self.finishClose()}else{self.status.stringValue="Googleの確認画面を閉じました。外部連携は自動再開しません。";self.controls()}
                };return
            }
            let ticket=try api.prepare(row)
            let editor=CRMJobReviewWindow(service:api.service,job:ticket.job,record:{[api] job,outcome,providerID,note in
                _ = try api.record(ticket,expected:job,outcome:outcome,providerID:providerID,note:note)
            });reviewWindow=editor;controls()
            window.beginSheet(editor.window){[weak self] _ in
                guard let self else{return};self.reviewWindow=nil
                if self.closing{self.finishClose()}else{self.status.stringValue="確認画面を閉じました。外部連携の保留は継続しています。";self.controls()}
            }
        }catch{status.stringValue=error.localizedDescription}
    }
    @objc private func closeRequested(){
        guard !closed else{return}
        if busy{closing=true;controls();status.stringValue="読み込みを中止しています…";work?.cancel();return}
        guard confirmDiscard() else{return};closing=true
        if let reviewWindow{window.endSheet(reviewWindow.window,returnCode:.cancel)}else if let smtpReviewWindow{window.endSheet(smtpReviewWindow.window,returnCode:.cancel)}else if let editor=googleReviewWindow{window.endSheet(editor.window,returnCode:.cancel)}else{finishClose()}
    }
    private func finishClose(){
        guard !busy,work==nil,!closed else{return};closed=true;api.close();window.sheetParent?.endSheet(window);window.orderOut(nil)
    }
    func numberOfRows(in tableView:NSTableView)->Int{rows.count}
    func tableViewSelectionDidChange(_ notification:Notification){controls()}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
        guard rows.indices.contains(row),let column else{return nil};let value=rows[row]
        let text:String
        switch column.identifier.rawValue {
        case "event":text=value.eventLabel
        case "id":text=value.displayID
        default:text=["pending":"待機中","running":"実行中の記録","retry":"再試行待ち","needs_review":"結果確認が必要","failed":"失敗","done":"完了","cancelled":"取消済み"][value.restoredState] ?? "不明（保持）"
        }
        let field=NSTextField(labelWithString:text);field.lineBreakMode = .byTruncatingMiddle;field.isSelectable=true;return field
    }
}
