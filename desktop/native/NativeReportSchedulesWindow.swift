import AppKit

private enum ReportScheduleUI {
    static func button(_ title:String,_ target:AnyObject,_ action:Selector)->NSButton {let value=NSButton(title:title,target:target,action:action);value.bezelStyle = .rounded;return value}
    static func layout(_ window:NSWindow,_ views:[NSView]) {
        let root=NSStackView(views:views);root.orientation = .vertical;root.alignment = .leading;root.spacing=12;root.translatesAutoresizingMaskIntoConstraints=false
        let content=window.contentView!;content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:content.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20)])
        for view in views {view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
    }
    static func date(_ value:String?)->String {
        guard let value,let date=ISO8601DateFormatter().date(from:value) else{return "—"}
        let f=DateFormatter();f.locale=Locale(identifier:"ja_JP");f.dateFormat="yyyy/MM/dd HH:mm";return f.string(from:date)
    }
    static func status(_ job:NativeJob)->String {
        if job.status=="done" {return ["sent":"受付済み","skipped":"対象外","not_sent":"未送信を確認","unconfirmed":"結果不明で終了"][job.result["outcome"] ?? ""] ?? "完了"}
        return ["pending":"予約済み","running":"処理中","retry":"再試行待ち","failed":"失敗","needs_review":"結果の確認待ち","cancelled":"取り消し済み"][job.status] ?? "不明"
    }
    static func frequency(_ expression:String)->String {["0 9 * * *":"毎日 9:00","0 9 * * 1":"毎週月曜 9:00","0 9 * * 5":"毎週金曜 9:00","0 9 1 * *":"毎月1日 9:00"][expression] ?? ("詳細指定："+expression)}
}

final class NativeReportScheduleEditor:NSObject {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:700,height:620),styleMask:[.titled],backing:.buffered,defer:false)
    private let store:NativeReportSchedules,configID:String,original:NativeReportSchedule?
    private let preset=NSPopUpButton(),cron=NSTextField(),zone=NSTextField(),format=NSPopUpButton(),recipients=NSTextView(),enabled=NSButton(checkboxWithTitle:"この定期送信を有効にする",target:nil,action:nil),status=NSTextField(wrappingLabelWithString:"")
    private let expressions=["0 9 * * *","0 9 * * 1","0 9 * * 5","0 9 1 * *",""]
    private var saveButton:NSButton!,cancelButton:NSButton!,previewButton:NSButton!,task:Task<Void,Never>?,baseline:[String]=[]
    private(set) var saved:NativeReportSchedule?
    init(store:NativeReportSchedules,configID:String,name:String,schedule:NativeReportSchedule?=nil) {
        self.store=store;self.configID=configID;original=schedule;super.init()
        window.title=schedule==nil ? "レポートの定期送信を作成" : "レポートの定期送信を編集"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:20,weight:.semibold)
        let report=NSTextField(wrappingLabelWithString:"レポート："+String(name.prefix(256)));report.maximumNumberOfLines=2;report.setAccessibilityLabel("送信するレポート名")
        preset.addItems(withTitles:["毎日 9:00","毎週月曜 9:00","毎週金曜 9:00","毎月1日 9:00","詳細な日時を指定"]);preset.target=self;preset.action = #selector(presetChanged);preset.setAccessibilityLabel("定期送信の頻度")
        cron.setAccessibilityLabel("送信日時のcron式");cron.placeholderString="分 時 日 月 曜日（例：0 9 * * 1）"
        zone.setAccessibilityLabel("定期送信のタイムゾーン");zone.stringValue=schedule?.settings.timeZone.identifier ?? TimeZone.current.identifier
        let timing=NSStackView(views:[preset,cron]);timing.spacing=8;cron.widthAnchor.constraint(greaterThanOrEqualToConstant:290).isActive=true
        timing.heightAnchor.constraint(equalToConstant:28).isActive=true
        let zoneRow=NSStackView(views:[NSTextField(labelWithString:"タイムゾーン"),zone]);zoneRow.spacing=10
        zoneRow.heightAnchor.constraint(equalToConstant:26).isActive=true
        format.addItems(withTitles:["CSV","PDF","CSV と PDF"]);format.setAccessibilityLabel("定期送信の添付形式");format.selectItem(at:schedule?.settings.format == .csv ? 0 : schedule?.settings.format == .pdf ? 1 : 2)
        recipients.isRichText=false;recipients.isAutomaticQuoteSubstitutionEnabled=false;recipients.font = .systemFont(ofSize:13);recipients.setAccessibilityLabel("定期送信の宛先");recipients.string=schedule?.settings.recipients.joined(separator:"\n") ?? ""
        let scroll=NSScrollView();scroll.documentView=recipients;scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.heightAnchor.constraint(equalToConstant:125).isActive=true
        recipients.isVerticallyResizable=true;recipients.isHorizontallyResizable=false;recipients.autoresizingMask = .width;recipients.textContainer?.widthTracksTextView=true
        enabled.state=schedule?.isActive == false ? .off : .on;enabled.isEnabled=schedule != nil
        let selected=schedule?.settings.cron.expression ?? expressions[0];preset.selectItem(at:expressions.firstIndex(of:selected) ?? 4);cron.stringValue=selected;presetChanged()
        let help=NSTextField(wrappingLabelWithString:"このMacでアプリが起動している間に送信します。終了・スリープ中の予約は、再開時に直近までの未処理分を1回にまとめます。集計期間は保存したレポート条件に従います。");help.font = .systemFont(ofSize:12);help.textColor = .secondaryLabelColor
        saveButton=ReportScheduleUI.button("保存",self,#selector(save));cancelButton=ReportScheduleUI.button("キャンセル",self,#selector(cancel));cancelButton.keyEquivalent="\u{1b}";previewButton=ReportScheduleUI.button("次回日時を確認",self,#selector(preview))
        status.maximumNumberOfLines=3;status.setAccessibilityLabel("定期送信の入力状態")
        let buttons=NSStackView(views:[previewButton,NSView(),cancelButton,saveButton]);buttons.spacing=8
        let spacer=NSView();spacer.setContentHuggingPriority(.init(1),for:.vertical);spacer.setContentCompressionResistancePriority(.init(1),for:.vertical)
        ReportScheduleUI.layout(window,[title,report,timing,zoneRow,format,NSTextField(labelWithString:"宛先（1〜50件・改行またはカンマ区切り）"),scroll,enabled,help,status,spacer,buttons]);baseline=values
    }
    deinit {task?.cancel()}
    private var values:[String] {[cron.stringValue,zone.stringValue,String(format.indexOfSelectedItem),recipients.string,enabled.state == .on ? "1" : "0"]}
    private func settings(_ values:[String])throws->NativeReportScheduleSettings {
        let addresses=values[3].components(separatedBy:CharacterSet(charactersIn:",;、\n\r")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}
        return try .init(expression:values[0],recipients:addresses,format:["csv","pdf","both"][Int(values[2])!],timeZone:values[1].trimmingCharacters(in:.whitespacesAndNewlines))
    }
    @objc private func presetChanged(){let index=max(0,preset.indexOfSelectedItem);if index<4 {cron.stringValue=expressions[index]};cron.isEnabled=index==4;cron.isHidden=index != 4}
    @objc private func preview(){do {let settings=try settings(values),date=try settings.next(after:Date()),f=DateFormatter();f.locale=Locale(identifier:"ja_JP");f.timeZone=settings.timeZone;f.dateFormat="yyyy/MM/dd（EEE）HH:mm";status.textColor = .secondaryLabelColor;status.stringValue="次回："+f.string(from:date)+"（"+settings.timeZone.identifier+"）"}catch{show(error)}}
    private func busy(_ value:Bool){for control in [preset,cron,zone,format,enabled,saveButton!,cancelButton!,previewButton!] as [NSControl]{control.isEnabled = !value};recipients.isEditable = !value;if !value {presetChanged();enabled.isEnabled=original != nil}}
    @objc private func save(){
        guard task==nil else{return};let input=values,store=store,original=original,id=configID;busy(true);status.stringValue="保存しています…"
        task=Task.detached(priority:.userInitiated){[weak self] in
            guard let self else{return};let result=Result {()throws->NativeReportSchedule in
                let settings=try self.settings(input);try Task.checkCancellation()
                if let original{return try store.update(original,settings:settings,isActive:input[4]=="1")}
                return try store.create(configID:id,settings:settings)
            }
            await MainActor.run{self.task=nil;switch result{case let .success(saved):self.saved=saved;self.window.sheetParent?.endSheet(self.window);self.window.orderOut(nil);case let .failure(error):self.busy(false);self.show(error)}}
        }
    }
    private func show(_ error:Error){status.textColor = .systemRed;status.stringValue=error.localizedDescription}
    func confirmDiscard()->Bool {
        guard task==nil else{return false};guard saved==nil,values != baseline else{return true}
        let alert=NSAlert();alert.messageText="入力した定期送信を保存せずに閉じますか？";alert.addButton(withTitle:"入力を続ける");alert.addButton(withTitle:"変更を破棄");return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel(){if confirmDiscard(){window.sheetParent?.endSheet(window);window.orderOut(nil)}}
}

final class NativeReportSchedulesWindow:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    private let activities:NativeRestoreParentActivities
    typealias Review=(NativeJob,NSWindow,@escaping()->Void)->Void
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:1050,height:640),styleMask:[.titled],backing:.buffered,defer:false)
    private let store:NativeReportSchedules,mode=NSPopUpButton(),table=NSTableView(),header=LightweightTableCell(),detail=NSTextField(wrappingLabelWithString:""),status=NSTextField(wrappingLabelWithString:""),count=NSTextField(labelWithString:"")
    private var schedules:[NativeRecord]=[],jobs:[NativeJob]=[],names:[String:String]=[:],nextDates:[String:String]=[:],offset=0,total=0,generation=0,scopeID:String?,task:Task<Void,Never>?,mutating=false
    private var add:NSButton!,edit:NSButton!,toggle:NSButton!,remove:NSButton!,history:NSButton!,retry:NSButton!,cancelJob:NSButton!,review:NSButton!,previous:NSButton!,next:NSButton!
    private var chooser:NativeReportConfigurationsWindow?,editor:NativeReportScheduleEditor?,observer:NSObjectProtocol?
    var onReview:Review?
    private var isHistory:Bool {mode.indexOfSelectedItem==1}
    private var columns:[NativeColumn] {isHistory ? [.init(title:"レポート",fraction:0.35),.init(title:"予約日時",fraction:0.22),.init(title:"状態",fraction:0.20),.init(title:"受付日時",fraction:0.23)] : [.init(title:"レポート",fraction:0.35),.init(title:"送信日時の指定",fraction:0.22),.init(title:"状態",fraction:0.13),.init(title:"次回の予約日時",fraction:0.30)]}
    init(store:NativeReportSchedules,activities:NativeRestoreParentActivities = .init())throws {
        try store.service.authenticated();self.store=store;self.activities=activities;super.init();window.title="レポートの定期送信"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:20,weight:.semibold)
        mode.addItems(withTitles:["定期送信の予約","送信履歴（削除した予約を含む）"]);mode.setAccessibilityLabel("定期送信の表示内容");mode.target=self;mode.action = #selector(modeChanged)
        let col=NSTableColumn(identifier:.init("reportSchedules"));col.width=1000;table.addTableColumn(col);table.headerView=nil;table.rowHeight=34;table.delegate=self;table.dataSource=self;table.allowsMultipleSelection=false;table.setAccessibilityLabel("定期送信と履歴の一覧")
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:230).isActive=true
        header.heightAnchor.constraint(equalToConstant:25).isActive=true
        add=button("新規…",#selector(create));edit=button("編集…",#selector(editSelected));toggle=button("停止",#selector(toggleSelected));remove=button("削除…",#selector(deleteSelected));history=button("この予約の履歴",#selector(showHistory));retry=button("再試行",#selector(retrySelected));cancelJob=button("予約を取り消す…",#selector(cancelSelected));review=button("送信結果を記録…",#selector(reviewSelected))
        let actions=NSStackView(views:[add,edit,toggle,remove,history,retry,cancelJob,review,NSView()]);actions.spacing=8
        detail.maximumNumberOfLines=4;detail.isSelectable=true;detail.font = .systemFont(ofSize:12);detail.setAccessibilityLabel("定期送信の詳細")
        status.maximumNumberOfLines=2;status.setAccessibilityLabel("定期送信の一覧状態")
        previous=button("前の100件",#selector(previousPage));next=button("次の100件",#selector(nextPage));let footer=NSStackView(views:[previous,count,next,NSView(),button("更新",#selector(refresh)),button("閉じる",#selector(close))]);footer.spacing=8
        let help=NSTextField(wrappingLabelWithString:"一覧の日時は、このMacのタイムゾーンで表示します。送信にはアプリの起動とメール送信設定が必要です。結果の確認待ちがある予約は、確認が済むまで次の送信を保留します。");help.font = .systemFont(ofSize:12);help.textColor = .secondaryLabelColor
        ReportScheduleUI.layout(window,[title,mode,header,scroll,actions,detail,status,help,footer]);selectionChanged()
        observer=NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main){[weak self] note in guard let self,note.userInfo?["database"] as? String==self.store.service.db.url.path,self.window.attachedSheet==nil,!self.mutating else{return};self.reload()}
    }
    deinit{task?.cancel();if let observer {NotificationCenter.default.removeObserver(observer)}}
    private func button(_ title:String,_ action:Selector)->NSButton {ReportScheduleUI.button(title,self,action)}
    func start(){reload()}
    private var row:NativeRecord? {schedules.indices.contains(table.selectedRow) ? schedules[table.selectedRow] : nil}
    private var job:NativeJob? {jobs.indices.contains(table.selectedRow) ? jobs[table.selectedRow] : nil}
    private func selectionChanged(){
        let ready=task==nil && !mutating
        for button in [add,edit,toggle,remove,history] {button?.isHidden=isHistory}
        for button in [retry,cancelJob,review] {button?.isHidden = !isHistory}
        add.isEnabled=ready;for button in [edit,toggle,remove,history]{button?.isEnabled=ready && row != nil}
        toggle.title=row?["isActive"] == .integer(1) ? "停止" : "再開"
        retry.isEnabled=ready && job.map{["failed","retry"].contains($0.status)}==true
        cancelJob.isEnabled=ready && job.map{["pending","retry","failed"].contains($0.status) && $0.deliveryStartedAt==nil}==true
        review.isEnabled=ready && onReview != nil && job?.canReviewMail==true
        if isHistory,let job {detail.stringValue="処理ID：nextcrm/report/"+job.id+"\n"+(job.lastError ?? job.result["reason"] ?? job.result["reviewNote"] ?? "")+"\n宛先："+(job.result["to"] ?? "準備前")}
        else if let row {detail.stringValue="最終受付："+ReportScheduleUI.date(row["lastSentAt"] == .null ? nil : row["lastSentAt"].string)}else{detail.stringValue=""}
        detail.toolTip=detail.stringValue
    }
    @objc private func modeChanged(){guard !mutating else{return};scopeID=nil;offset=0;reload()}
    @objc private func refresh(){guard !mutating else{return};reload()}
    @objc private func previousPage(){offset=max(0,offset-100);reload()}
    @objc private func nextPage(){offset+=100;reload()}
    @objc private func showHistory(){guard let row else{return};scopeID=row["id"].string;mode.selectItem(at:1);offset=0;reload()}
    private func reload(){
        guard !mutating else{return};task?.cancel();generation+=1;let version=generation,store=store,offset=offset,history=isHistory,id=scopeID
        schedules=[];jobs=[];table.reloadData();header.configure(columns:columns,values:columns.map(\.title),heading:true);previous.isEnabled=false;next.isEnabled=false;status.textColor = .secondaryLabelColor;status.stringValue="読み込んでいます…"
        task=Task.detached(priority:.userInitiated){[weak self] in
            let result=Result {()throws->([NativeRecord],[NativeJob],[String:String],[String:String],Int) in
                if history {let page=try store.history(scheduleID:id,offset:offset);return([],page.rows,[:],[:],page.total)}
                let page=try store.list(offset:offset),service=store.service;var names:[String:String]=[:],dates:[String:String]=[:]
                try service.db.transaction {
                    try service.authenticated()
                    for row in page.rows {
                        try Task.checkCancellation();let key=row["reportConfigId"].string,scope:RecordFilter=service.identity.elevated ? .all : .any([.equal("createdBy",.text(service.identity.id)),.equal("isShared",.integer(1))])
                        names[key]=try service.db.keysetPage("crm_Report_Config",fields:["name"],filter:.every([scope,.equal("id",.text(key))]),limit:1,maximumTextCharacters:["name":256]).first?["name"].string ?? "参照できないレポート"
                        if row["isActive"] == .integer(1),let jobID=try service.db.reportScheduleState("job",id:row["id"].string),let job=try service.db.job(id:jobID){dates[row["id"].string]=job.payload["occurrence"]}
                    }
                };return(page.rows,[],names,dates,page.total)
            }
            guard !Task.isCancelled else{return}
            await MainActor.run{[weak self] in guard let self,self.generation==version else{return};self.task=nil
                switch result {case let .success(page):
                    if page.0.isEmpty && page.1.isEmpty && offset>0 {self.offset=max(0,((page.4-1)/100)*100);self.reload();return}
                    self.schedules=page.0;self.jobs=page.1;self.names=page.2;self.nextDates=page.3;self.total=page.4;self.table.reloadData();let size=history ? page.1.count : page.0.count
                    self.count.stringValue="\(page.4==0 ? 0 : offset+1)〜\(offset+size) ／ \(page.4)件";self.previous.isEnabled=offset>0;self.next.isEnabled=offset+size<page.4;self.status.stringValue=id==nil ? "" : "選択した予約の履歴です。表示内容を切り替えると全件に戻ります。"
                case let .failure(error):self.show(error)};self.selectionChanged()
            }
        };selectionChanged()
    }
    @objc private func create(){
        guard window.attachedSheet==nil else{return}
        do {let chooser=try NativeReportConfigurationsWindow(store:.init(service:store.service),category:nil,selectForSchedule:true,activities:activities);self.chooser=chooser
            window.beginSheet(chooser.window){[weak self,weak chooser] _ in guard let self else{return};self.chooser=nil;if let config=chooser?.selected {self.openEditor(configID:config.id,name:config.name)}};chooser.start()
        }catch{show(error)}
    }
    private func openEditor(configID:String,name:String,schedule:NativeReportSchedule?=nil){
        let editor=NativeReportScheduleEditor(store:store,configID:configID,name:name,schedule:schedule);self.editor=editor
        window.beginSheet(editor.window){[weak self] _ in self?.editor=nil;self?.reload()}
    }
    @objc private func editSelected(){guard let row else{return};do {let schedule=try store.load(row["id"].string);guard schedule.record.revision==row.revision else{throw NativeDBError.conflict};openEditor(configID:row["reportConfigId"].string,name:names[row["reportConfigId"].string] ?? "レポート",schedule:schedule)}catch{show(error)}}
    private func perform(_ operation:@escaping (NativeReportSchedules)throws->Void){
        guard !mutating else{return};mutating=true;task?.cancel();generation+=1;let version=generation,store=store;mode.isEnabled=false;previous.isEnabled=false;next.isEnabled=false;selectionChanged();status.stringValue="処理しています…"
        task=Task.detached(priority:.userInitiated){[weak self] in let result=Result{try Task.checkCancellation();try operation(store)}
            await MainActor.run{[weak self] in guard let self,self.generation==version else{return};self.task=nil;self.mutating=false;self.mode.isEnabled=true;switch result{case .success:self.reload();case let .failure(error):self.selectionChanged();self.show(error)}}
        }
    }
    @objc private func toggleSelected(){
        guard let row else{return}
        do {
            // A migrated schedule's display fallback is not confirmation of its
            // time zone. Require the editor before either pause/resume can save it.
            guard try store.service.db.reportScheduleTimeZone(row["id"].string) != nil else {editSelected();status.stringValue="移行した予約のタイムゾーンを確認して保存してください。";return}
        }catch{show(error);return}
        perform{store in let fresh=try store.load(row["id"].string);guard fresh.record.revision==row.revision else{throw NativeDBError.conflict};_ = try store.update(fresh,settings:fresh.settings,isActive:!fresh.isActive)}
    }
    private func confirm(_ title:String,_ message:String,action:String,_ work:@escaping()->Void){let alert=NSAlert();alert.messageText=title;alert.informativeText=message;alert.addButton(withTitle:action);alert.addButton(withTitle:"キャンセル");alert.beginSheetModal(for:window){if $0 == .alertFirstButtonReturn {work()}}}
    @objc private func deleteSelected(){guard let row else{return};confirm("定期送信を削除しますか？","今後の予約を取り消します。既に送信を開始した処理と履歴は残ります。",action:"削除"){[weak self] in self?.perform{try $0.delete(row)}}}
    @objc private func retrySelected(){guard let job else{return};perform{try $0.retry(job.id)}}
    @objc private func cancelSelected(){guard let job else{return};confirm("この回の送信予約を取り消しますか？","定期送信の設定は維持します。全ての送信を止める場合は、予約一覧で停止してください。",action:"取り消す"){[weak self] in self?.perform{try $0.cancel(job.id)}}}
    @objc private func reviewSelected(){guard let job,let onReview else{return};onReview(job,window){[weak self] in self?.reload()}}
    private func show(_ error:Error){status.textColor = .systemRed;status.stringValue=error.localizedDescription}
    func confirmDiscard()->Bool {!mutating && editor?.confirmDiscard() != false}
    @objc private func close(){guard window.attachedSheet==nil,confirmDiscard() else{return};task?.cancel();task=nil;generation+=1;window.sheetParent?.endSheet(window);window.orderOut(nil)}
    func numberOfRows(in tableView:NSTableView)->Int {isHistory ? jobs.count : schedules.count}
    func tableViewSelectionDidChange(_ notification:Notification){selectionChanged()}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let values:[String]
        if isHistory {guard jobs.indices.contains(row) else{return nil};let job=jobs[row];values=[job.result["reportName"] ?? job.payload["reportName"] ?? "レポート（送信準備前）",ReportScheduleUI.date(job.payload["occurrence"]),ReportScheduleUI.status(job),ReportScheduleUI.date(job.result["acceptedAt"] ?? (job.result["outcome"]=="sent" ? job.result["reviewedAt"] : nil))]}
        else {guard schedules.indices.contains(row) else{return nil};let value=schedules[row];values=[names[value["reportConfigId"].string] ?? "レポート",ReportScheduleUI.frequency(value["cronExpression"].string),value["isActive"] == .integer(1) ? "有効" : "停止",ReportScheduleUI.date(nextDates[value["id"].string]) ]}
        let id=NSUserInterfaceItemIdentifier("reportSchedule"),cell=tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell();cell.identifier=id;cell.configure(columns:columns,values:values);return cell
    }
}
