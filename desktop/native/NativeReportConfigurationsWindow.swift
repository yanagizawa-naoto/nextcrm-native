import AppKit

final class NativeReportConfigurationsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let activities:NativeRestoreParentActivities
    private let activityOwner=UUID().uuidString
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:820,height:560),styleMask:[.titled],backing:.buffered,defer:false)
    private let store:NativeReportConfigurations,category=NSPopUpButton(),table=NSTableView(),status=NSTextField(wrappingLabelWithString:""),count=NSTextField(labelWithString:"")
    private var rows:[NativeRecord]=[],offset=0,total=0,generation=0,task:Task<Void,Never>?
    private var applyButton:NSButton!,duplicateButton:NSButton!,shareButton:NSButton!,deleteButton:NSButton!,previous:NSButton!,next:NSButton!
    private let categories=NativeReportCategory.allCases.filter{$0 != .overview}
    private let columns=[NativeColumn(title:"名前",fraction:0.55),NativeColumn(title:"種類",fraction:0.3),NativeColumn(title:"共有",fraction:0.15)]
    private(set) var selected:NativeReportConfiguration?
    private(set) var didModify=false
    init(store:NativeReportConfigurations,category initial:NativeReportCategory?,selectForSchedule:Bool=false,activities:NativeRestoreParentActivities = .init()) throws {
        try store.service.authenticated();self.store=store;self.activities=activities;super.init();window.title="保存したレポート"
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:20,weight:.semibold)
        category.addItems(withTitles:["すべての種類"]+categories.map(\.title));category.setAccessibilityLabel("保存したレポートの種類");category.target=self;category.action = #selector(filterChanged)
        if let initial,let index=categories.firstIndex(of:initial){category.selectItem(at:index+1)}
        let header=LightweightTableCell();header.configure(columns:columns,values:columns.map(\.title),heading:true);header.heightAnchor.constraint(equalToConstant:25).isActive=true
        let col=NSTableColumn(identifier:.init("configuration"));col.width=760;table.addTableColumn(col);table.headerView=nil;table.rowHeight=34;table.delegate=self;table.dataSource=self;table.allowsMultipleSelection=false;table.setAccessibilityLabel("保存したレポートの一覧");table.target=self;table.doubleAction = #selector(apply)
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:240).isActive=true
        applyButton=button("この条件で集計",#selector(apply));duplicateButton=button("複製…",#selector(duplicate));shareButton=button("共有する",#selector(share));deleteButton=button("削除…",#selector(remove))
        if selectForSchedule {window.title="定期送信するレポートを選択";title.stringValue=window.title;applyButton.title="このレポートを定期送信"}
        let actions=NSStackView(views:[applyButton,duplicateButton,shareButton,deleteButton,NSView()]);actions.spacing=8
        previous=button("前の100件",#selector(previousPage));next=button("次の100件",#selector(nextPage));let footer=NSStackView(views:[previous,count,next,NSView(),button("閉じる",#selector(close))]);footer.spacing=8
        status.maximumNumberOfLines=2;status.setAccessibilityLabel("保存したレポートの状態")
        let views:[NSView]=[title,category,header,scroll,actions,status,footer],root=NSStackView(views:views);root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.translatesAutoresizingMaskIntoConstraints=false
        let content=window.contentView!;content.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:content.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20)]);for view in views {view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
        selectionChanged()
    }
    deinit{task?.cancel()}
    private func button(_ title:String,_ selector:Selector)->NSButton{let b=NSButton(title:title,target:self,action:selector);b.bezelStyle = .rounded;return b}
    func start(){reload()}
    private var row:NativeRecord?{rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil}
    private func selectionChanged(){let selected=row != nil,writable=row.map{store.service.identity.elevated || $0["createdBy"] == .text(store.service.identity.id)} ?? false;applyButton.isEnabled=selected;duplicateButton.isEnabled=selected;shareButton.isEnabled=writable;deleteButton.isEnabled=writable;shareButton.title=row?["isShared"] == .integer(1) ? "共有を解除" : "共有する"}
    @objc private func filterChanged(){offset=0;reload()}
    @objc private func previousPage(){offset=max(0,offset-100);reload()}
    @objc private func nextPage(){offset+=100;reload()}
    private func reload(selectedID:String?=nil){
        guard !activities.isSealed else{return}
        task?.cancel();generation+=1;let version=generation,offset=offset,store=store,filter=category.indexOfSelectedItem>0 ? categories[category.indexOfSelectedItem-1] : nil
        rows=[];table.reloadData();selectionChanged();previous.isEnabled=false;next.isEnabled=false;status.textColor = .secondaryLabelColor;status.stringValue="保存した条件を読み込んでいます…"
        task=activities.spawn(owner:activityOwner,kind:.readOnly){[weak self] in
            let result=Result{try store.list(category:filter,offset:offset)};guard !Task.isCancelled else{return}
            await MainActor.run{[weak self] in guard let self,self.generation==version else{return};self.task=nil
                switch result{case let .success(page):
                    if page.rows.isEmpty,offset>0 {self.offset=max(0,((page.total-1)/100)*100);self.reload();return}
                    self.rows=page.rows;self.total=page.total;self.table.reloadData();if let selectedID,let i=page.rows.firstIndex(where:{$0["id"].string==selectedID}){self.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false)}
                    self.selectionChanged();self.count.stringValue="\(page.total==0 ? 0 : offset+1)〜\(offset+page.rows.count) ／ \(page.total)件";self.previous.isEnabled=offset>0;self.next.isEnabled=offset+page.rows.count<page.total;self.status.stringValue="共有された条件も、現在の自分の閲覧権限で集計します。"
                case let .failure(error):self.show(error)}
            }
        }
    }
    private func perform(_ work:@escaping (NativeReportConfigurations,NativeReportConfiguration)throws->NativeReportConfiguration?,applies:Bool=false){
        guard !activities.isSealed,activities.pendingWrites(owner:activityOwner)==0 else{return}
        guard let row else{return};let store=store,version=generation
        applyButton.isEnabled=false;duplicateButton.isEnabled=false;shareButton.isEnabled=false;deleteButton.isEnabled=false;status.stringValue="処理しています…"
        task=activities.spawn(owner:activityOwner,kind:.acceptedWrite){[weak self] in
            let result=Result{()->NativeReportConfiguration? in let current=try store.load(row["id"].string);guard current.record.revision==row.revision else{throw NativeDBError.conflict};try Task.checkCancellation();return try work(store,current)}
            guard !Task.isCancelled else{return}
            await MainActor.run{[weak self] in guard let self,self.generation==version else{return};self.task=nil
                switch result{case let .success(value):if applies{self.selected=value;self.close()}else{self.didModify=true;self.reload(selectedID:value?.id)}
                case let .failure(error):self.selectionChanged();self.show(error)}
            }
        }
    }
    @objc private func apply(){perform({_,current in current},applies:true)}
    @objc private func share(){guard let row else{return};let enabled=row["isShared"] != .integer(1);perform{try $0.share($1,enabled:enabled)}}
    @objc private func duplicate(){
        guard let row else{return};let alert=NSAlert();alert.messageText="レポート条件を複製";alert.informativeText="複製は自分専用として保存します。"
        let name=NSTextField(frame:NSRect(x:0,y:0,width:420,height:26));name.stringValue=String(row["name"].string.prefix(240))+"の複製";name.setAccessibilityLabel("複製するレポート名");alert.accessoryView=name;alert.addButton(withTitle:"複製");alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window){[weak self] response in guard response == .alertFirstButtonReturn else{return};let text=name.stringValue;self?.perform{try $0.duplicate($1,name:text)}}
    }
    @objc private func remove(){
        guard let row else{return};let alert=NSAlert();alert.messageText="保存したレポートを削除しますか？";alert.informativeText="「\(row["name"].string)」と、この条件に紐づく定期送信予約を削除します。";alert.addButton(withTitle:"削除");alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window){[weak self] response in guard response == .alertFirstButtonReturn else{return};self?.perform{try $0.delete($1);return nil}}
    }
    private func show(_ error:Error){status.textColor = .systemRed;status.stringValue=error.localizedDescription}
    func confirmDiscard()->Bool {activities.pendingWrites(owner:activityOwner)==0 && window.attachedSheet==nil}
    @objc private func close(){guard confirmDiscard() else{return};task?.cancel();task=nil;generation+=1;window.sheetParent?.endSheet(window);window.orderOut(nil)}
    func numberOfRows(in tableView:NSTableView)->Int{rows.count}
    func tableViewSelectionDidChange(_ notification:Notification){selectionChanged()}
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{
        guard rows.indices.contains(row)else{return nil};let value=rows[row],id=NSUserInterfaceItemIdentifier("savedReport")
        let cell=tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell();cell.identifier=id;cell.configure(columns:columns,values:[value["name"].string,NativeReportCategory(rawValue:value["category"].string)?.title ?? "不明",value["isShared"] == .integer(1) ? "共有" : "自分専用"]);return cell
    }
}
