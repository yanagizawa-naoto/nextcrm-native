import AppKit

final class NativeAdminAuditWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x:0,y:0,width:960,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let api: NativeAdminAudit, confirmRestore: (String)->Bool
    private let source = NSPopUpButton(), entity = NSPopUpButton(), action = NSPopUpButton(), dateFrom = NSTextField(), dateTo = NSTextField(), userName = NSTextField(labelWithString:"すべての利用者")
    private let table = NSTableView(), descriptionLabel = NSTextField(wrappingLabelWithString:""), status = NSTextField(wrappingLabelWithString:""), count = NSTextField(labelWithString:"")
    private var buttons: [String:NSButton] = [:], entries: [NativeAdminAudit.Entry] = [], pageNumber = 1, total = 0, userID: String?, busy = false, closed = false, permitted = true
    private var child: NSObject?
    var onChanged: (()->Void)?
    init(service: CRMService, confirmRestore: @escaping (String)->Bool = NativeAdminAuditWindow.askRestore) throws {
        api = .init(service:service); self.confirmRestore = confirmRestore; try api.requireAdmin(); super.init()
        window.title = "全体の変更履歴"
        let title = NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:22,weight:.semibold)
        source.addItems(withTitles:NativeAdminAudit.Source.allCases.map(\.title));source.setAccessibilityLabel("履歴の保存元");source.target=self;source.action=#selector(changed)
        entity.addItems(withTitles:["すべての種別"]+NativeAdminAudit.entities.map { $0.1 });entity.setAccessibilityLabel("履歴の種別");entity.target=self;entity.action=#selector(changed)
        action.addItems(withTitles:["すべての操作"]+NativeAdminAudit.actions.map { $0.1 });action.setAccessibilityLabel("履歴の操作");action.target=self;action.action=#selector(changed)
        let kinds = NSStackView(views:[source,entity,action,NSView()]);kinds.spacing=8
        dateFrom.placeholderString="開始日時（UTC）";dateFrom.setAccessibilityLabel("履歴の開始日時");dateTo.placeholderString="終了日時（UTC）";dateTo.setAccessibilityLabel("履歴の終了日時")
        for field in [dateFrom,dateTo] { field.target=self;field.action=#selector(changed);field.widthAnchor.constraint(equalToConstant:220).isActive=true }
        let dates=NSStackView(views:[dateFrom,NSTextField(labelWithString:"〜"),dateTo,button("日時を適用",#selector(changed)),button("条件を解除",#selector(clear)),NSView()]);dates.spacing=8
        let help=NSTextField(wrappingLabelWithString:"日時は UTC の「2026-11-20 17:00:00」形式です。日付だけの場合はその日の00:00:00まで／からを含めます。")
        help.textColor = .secondaryLabelColor;help.font = .systemFont(ofSize:12)
        userName.setAccessibilityLabel("履歴の利用者条件");let users=NSStackView(views:[userName,button("利用者を選択…",#selector(chooseUser)),button("利用者条件を解除",#selector(clearUser)),NSView(),button("再読み込み",#selector(refresh))]);users.spacing=8
        table.dataSource=self;table.delegate=self;table.rowHeight=30;table.columnAutoresizingStyle = .noColumnAutoresizing;table.setAccessibilityLabel("全体履歴の一覧")
        for (id,title,width) in [("entity","データ",180.0),("action","操作",150),("actor","実行者",240),("date","日時（UTC）",240)] { let c=NSTableColumn(identifier:.init(id));c.title=title;c.width=width;c.minWidth=100;table.addTableColumn(c) }
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:280).isActive=true
        let footer=NSStackView(views:[button("前の50件",#selector(previous)),count,button("次の50件",#selector(next)),NSView(),button("詳細…",#selector(details)),button("閉じる",#selector(close))]);footer.spacing=8
        status.setAccessibilityLabel("履歴の操作結果");status.maximumNumberOfLines=2
        NativeAdminAuditLayout.install([title,kinds,descriptionLabel,dates,help,users,scroll,status,footer],window:window);controls()
    }
    static func askRestore(_ text: String)->Bool { let alert=NSAlert();alert.messageText=text;alert.informativeText="削除時点から変更があった場合は復元を中止します。";alert.addButton(withTitle:"キャンセル");alert.addButton(withTitle:"復元");return alert.runModal() == .alertSecondButtonReturn }
    private func button(_ title:String,_ action:Selector)->NSButton { let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;buttons[title]=b;return b }
    private var selected:NativeAdminAudit.Entry? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }
    func start(){load()}
    func confirmDiscard()->Bool{!busy && child == nil}
    private func controls(){let idle = !busy && child == nil && !closed;[source,entity,action].forEach{$0.isEnabled=idle};[dateFrom,dateTo].forEach{$0.isEnabled=idle};buttons.values.forEach{$0.isEnabled=idle};buttons["前の50件"]?.isEnabled=idle && pageNumber>1;buttons["次の50件"]?.isEnabled=idle && pageNumber*50<total;buttons["詳細…"]?.isEnabled=idle && permitted && selected != nil;buttons["利用者を選択…"]?.isEnabled=idle && permitted;table.isEnabled=idle}
    private func filters()throws->NativeAdminAudit.Filters {
        .init(source:NativeAdminAudit.Source.allCases[source.indexOfSelectedItem],entityType:entity.indexOfSelectedItem>0 ? NativeAdminAudit.entities[entity.indexOfSelectedItem-1].0:nil,action:action.indexOfSelectedItem>0 ? NativeAdminAudit.actions[action.indexOfSelectedItem-1].0:nil,userID:userID,dateFrom:try NativeAdminAuditLayout.date(dateFrom.stringValue),dateTo:try NativeAdminAuditLayout.date(dateTo.stringValue),page:pageNumber)
    }
    private func load(){guard !busy,child == nil,!closed else{return};let filters:NativeAdminAudit.Filters
        do{filters=try self.filters()}catch{status.stringValue=error.localizedDescription;return}
        busy=true;controls();descriptionLabel.stringValue=filters.source.explanation;status.stringValue="読み込んでいます…"
        DispatchQueue.global(qos:.userInitiated).async{[self] in let result=Result{try api.page(filters)};DispatchQueue.main.async{[self] in busy=false;guard !closed else{return}
            switch result{case let .success(page):permitted=true;if page.entries.isEmpty && page.page>1{pageNumber=max(1,page.totalPages);load();return};entries=page.entries;total=page.total;count.stringValue="\(page.page) ／ \(max(1,page.totalPages))ページ・\(page.total)件";status.stringValue="行を選んで詳細を開くと、変更内容や復元可能なデータを確認できます。"
            case let .failure(error):permitted=false;entries=[];total=0;count.stringValue="—";status.stringValue=error.localizedDescription}
            table.deselectAll(nil);table.reloadData();NativeAdminAuditLayout.fit(table,window:window);controls()
        }}
    }
    @objc private func changed(){pageNumber=1;load()}
    @objc private func clear(){entity.selectItem(at:0);action.selectItem(at:0);dateFrom.stringValue="";dateTo.stringValue="";userID=nil;userName.stringValue="すべての利用者";changed()}
    @objc private func clearUser(){userID=nil;userName.stringValue="すべての利用者";changed()}
    @objc private func refresh(){load()}
    @objc private func previous(){if pageNumber>1{pageNumber-=1;load()}}
    @objc private func next(){if pageNumber*50<total{pageNumber+=1;load()}}
    @objc private func close(){guard confirmDiscard() else{return};closed=true;if let parent=window.sheetParent{parent.endSheet(window)}else{window.close()}}
    @objc private func chooseUser(){guard !busy,child == nil else{return};let picker=NativeAdminAuditUserWindow(api:api);child=picker;controls();window.beginSheet(picker.window){[weak self,weak picker] response in guard let self else{return};if response == .OK,let user=picker?.selection{self.userID=user.id;self.userName.stringValue=user.name;self.pageNumber=1};self.child=nil;self.controls();self.load()};picker.start()}
    @objc private func details(){guard let selected,!busy,child == nil else{return};let detail=NativeAdminAuditDetailWindow(api:api,entry:selected,confirm:confirmRestore);child=detail;controls();detail.onRestore={[weak self] in self?.onChanged?()};window.beginSheet(detail.window){[weak self] _ in self?.child=nil;self?.controls();self?.load()};detail.start()}
    func numberOfRows(in tableView:NSTableView)->Int{entries.count}
    func tableViewSelectionDidChange(_ notification:Notification){controls()}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{guard entries.indices.contains(row) else{return nil};let e=entries[row],text:String;switch column?.identifier.rawValue{case"entity":text=e.entityTitle;case"action":text=e.actionTitle;case"actor":text=e.actorName;default:text=NativeAdminAuditLayout.timestamp(e.createdAt)};let f=NSTextField(labelWithString:text);f.lineBreakMode = .byTruncatingTail;f.toolTip=text;return f}
}

private enum NativeAdminAuditLayout {
    static func install(_ views:[NSView],window:NSWindow){let stack=NSStackView(views:views);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)]);views.forEach{$0.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}}
    static func fit(_ table:NSTableView,window:NSWindow){window.contentView?.layoutSubtreeIfNeeded();if let width=table.enclosingScrollView?.contentView.bounds.width,width>0{table.setFrameSize(.init(width:width,height:table.frame.height));table.sizeLastColumnToFit();table.tile()}}
    static func date(_ input:String)throws->Date?{let text=input.trimmingCharacters(in:.whitespacesAndNewlines);if text.isEmpty{return nil};let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.calendar=Calendar(identifier:.gregorian);f.timeZone=TimeZone(secondsFromGMT:0);f.isLenient=false;f.dateFormat=text.count==10 ? "yyyy-MM-dd":"yyyy-MM-dd HH:mm:ss";guard let date=f.date(from:text),f.string(from:date)==text else{throw NativeDBError.message("日時を「2026-11-20 17:00:00」の形式で入力してください。")};return date}
    static func timestamp(_ value:String)->String{value.replacingOccurrences(of:"T",with:" ").prefix(19).description}
}

private final class NativeAdminAuditUserWindow:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:620,height:520),styleMask:[.titled],backing:.buffered,defer:false)
    private let api:NativeAdminAudit,search=NSSearchField(),table=NSTableView(),status=NSTextField(labelWithString:"")
    private var rows:[NativeAdminAudit.User]=[],page=1,total=0,busy=false,buttons:[String:NSButton]=[:]
    var selection:NativeAdminAudit.User?{rows.indices.contains(table.selectedRow) ? rows[table.selectedRow]:nil}
    init(api:NativeAdminAudit){self.api=api;super.init();window.title="履歴の利用者を選択";search.placeholderString="名前で検索";search.setAccessibilityLabel("履歴利用者の検索");search.target=self;search.action=#selector(searchChanged);table.dataSource=self;table.delegate=self;table.rowHeight=30;let c=NSTableColumn(identifier:.init("name"));c.title="利用者名";c.width=540;table.addTableColumn(c);let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:260).isActive=true;let footer=NSStackView(views:[button("前へ",#selector(previous)),button("次へ",#selector(next)),NSView(),button("キャンセル",#selector(cancel)),button("選択",#selector(choose))]);footer.spacing=8;NativeAdminAuditLayout.install([search,scroll,status,footer],window:window);controls()}
    private func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;buttons[title]=b;return b}
    private func controls(){buttons.values.forEach{$0.isEnabled = !busy};search.isEnabled = !busy;table.isEnabled = !busy;buttons["選択"]?.isEnabled = !busy && selection != nil;buttons["前へ"]?.isEnabled = !busy && page>1;buttons["次へ"]?.isEnabled = !busy && page*50<total}
    func start(){load()}
    private func load(){guard !busy else{return};busy=true;controls();let text=search.stringValue,page=page;DispatchQueue.global(qos:.userInitiated).async{[self] in let result=Result{try api.users(search:text,page:page)};DispatchQueue.main.async{[self] in busy=false;switch result{case let .success(value):rows=value.rows;total=value.total;status.stringValue="\(total)件・\(page)ページ";case let .failure(error):rows=[];total=0;status.stringValue=error.localizedDescription};table.deselectAll(nil);table.reloadData();NativeAdminAuditLayout.fit(table,window:window);controls()}}}
    @objc private func searchChanged(){page=1;load()};@objc private func previous(){page-=1;load()};@objc private func next(){page+=1;load()}
    @objc private func cancel(){window.sheetParent?.endSheet(window)};@objc private func choose(){guard selection != nil else{return};window.sheetParent?.endSheet(window,returnCode:.OK)}
    func numberOfRows(in tableView:NSTableView)->Int{rows.count};func tableViewSelectionDidChange(_ notification:Notification){controls()}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{rows.indices.contains(row) ? NSTextField(labelWithString:rows[row].name):nil}
}

private final class NativeAdminAuditDetailWindow:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:840,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let api:NativeAdminAudit,entry:NativeAdminAudit.Entry,confirm:(String)->Bool,table=NSTableView(),side=NSPopUpButton(),text=NSTextView(),status=NSTextField(wrappingLabelWithString:""),notice=NSTextField(wrappingLabelWithString:""),count=NSTextField(labelWithString:"")
    private var detail:NativeAdminAudit.Detail?,value:NativeAdminAudit.Value?,page=1,offset=0,busy=false,buttons:[String:NSButton]=[:]
    var onRestore:(()->Void)?
    init(api:NativeAdminAudit,entry:NativeAdminAudit.Entry,confirm:@escaping(String)->Bool){self.api=api;self.entry=entry;self.confirm=confirm;super.init();window.title="変更内容";let title=NSTextField(labelWithString:"\(entry.entityTitle)・\(entry.actionTitle)　\(entry.actorName)");title.font = .systemFont(ofSize:17,weight:.semibold);let date=NSTextField(labelWithString:"\(NativeAdminAuditLayout.timestamp(entry.createdAt)) UTC ／ \(entry.source.title)")
        table.delegate=self;table.dataSource=self;table.rowHeight=28;table.setAccessibilityLabel("変更項目の一覧");let c=NSTableColumn(identifier:.init("field"));c.title="項目";c.width=760;table.addTableColumn(c);let fields=NSScrollView();fields.documentView=table;fields.hasVerticalScroller=true;fields.heightAnchor.constraint(equalToConstant:170).isActive=true
        let pages=NSStackView(views:[button("前の項目",#selector(previousField)),count,button("次の項目",#selector(nextField)),NSView()]);pages.spacing=8
        side.addItems(withTitles:["変更前","変更後"]);side.selectItem(at:1);side.setAccessibilityLabel("変更内容の前後");side.target=self;side.action=#selector(sideChanged)
        let values=NSStackView(views:[side,button("前の4,096文字",#selector(previousValue)),button("次の4,096文字",#selector(nextValue)),NSView()]);values.spacing=8
        text.isEditable=false;text.isSelectable=true;text.font = .systemFont(ofSize:13);text.setAccessibilityLabel("安全な変更内容");let scroll=NSScrollView();scroll.documentView=text;scroll.hasVerticalScroller=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:150).isActive=true;text.autoresizingMask = .width;text.textContainer?.widthTracksTextView=true
        status.setAccessibilityLabel("変更内容の操作結果");notice.font = .systemFont(ofSize:12);notice.textColor = .secondaryLabelColor
        let footer=NSStackView(views:[button("このデータを復元…",#selector(restore)),NSView(),button("閉じる",#selector(close))]);footer.spacing=8
        NativeAdminAuditLayout.install([title,date,fields,pages,values,scroll,notice,status,footer],window:window);controls()
    }
    private func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;buttons[title]=b;return b}
    private var field:NativeAdminAudit.Field?{guard let detail,detail.fields.indices.contains(table.selectedRow) else{return nil};return detail.fields[table.selectedRow]}
    private func controls(){buttons.values.forEach{$0.isEnabled = !busy};table.isEnabled = !busy;side.isEnabled = !busy && field != nil;buttons["前の項目"]?.isEnabled = !busy && page>1;buttons["次の項目"]?.isEnabled = !busy && page*50<(detail?.total ?? 0);buttons["前の4,096文字"]?.isEnabled = !busy && offset>0;buttons["次の4,096文字"]?.isEnabled = !busy && value?.hasNext == true;buttons["このデータを復元…"]?.isEnabled = !busy && detail?.restorable != nil}
    func start(){load()}
    private func load(){guard !busy else{return};busy=true;value=nil;text.string="";controls();let page=page;DispatchQueue.global(qos:.userInitiated).async{[self] in let result=Result{try api.detail(entry,page:page)};DispatchQueue.main.async{[self] in busy=false;switch result{case let .success(d):detail=d;notice.stringValue=d.notice;count.stringValue="\(d.total)項目・\(page)ページ";status.stringValue="項目を選択すると、安全に表示できる値だけを読み込みます。";case let .failure(error):detail=nil;notice.stringValue="";count.stringValue="—";status.stringValue=error.localizedDescription};table.deselectAll(nil);table.reloadData();NativeAdminAuditLayout.fit(table,window:window);controls()}}}
    private func loadValue(){guard !busy,let field else{return};busy=true;text.string="";value=nil;controls();let offset=offset,side:NativeAdminAudit.Side=side.indexOfSelectedItem==0 ? .before:.after;DispatchQueue.global(qos:.userInitiated).async{[self] in let result=Result{try api.value(entry,field:field,side:side,offset:offset)};DispatchQueue.main.async{[self] in busy=false;switch result{case let .success(v):value=v;text.string=v.text;status.stringValue=v.protected ? "この値は公開しません。元の記録は保持されています。":"\(field.label)・\(side.title)　\(v.total==0 ? 0:offset+1)〜\(min(offset+4096,v.total)) ／ \(v.total)文字";case let .failure(error):detail=nil;value=nil;text.string="";status.stringValue=error.localizedDescription};controls()}}}
    @objc private func previousField(){page-=1;load()};@objc private func nextField(){page+=1;load()}
    @objc private func sideChanged(){offset=0;loadValue()};@objc private func previousValue(){offset=max(0,offset-4096);loadValue()};@objc private func nextValue(){offset+=4096;loadValue()}
    @objc private func close(){guard !busy else{return};window.sheetParent?.endSheet(window)}
    @objc private func restore(){guard !busy,let detail,detail.restorable != nil,confirm("この\(entry.entityTitle)を復元しますか？") else{return};busy=true;text.string="";controls();DispatchQueue.global(qos:.userInitiated).async{[self] in let result=Result{try api.restore(detail)};DispatchQueue.main.async{[self] in busy=false;switch result{case .success:onRestore?();load();case let .failure(error):self.detail=nil;value=nil;text.string="";status.stringValue=error.localizedDescription;controls()}}}}
    func numberOfRows(in tableView:NSTableView)->Int{detail?.fields.count ?? 0}
    func tableViewSelectionDidChange(_ notification:Notification){offset=0;value=nil;text.string="";controls();if field != nil{loadValue()}}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{guard let detail,detail.fields.indices.contains(row) else{return nil};return NSTextField(labelWithString:detail.fields[row].label)}
}
