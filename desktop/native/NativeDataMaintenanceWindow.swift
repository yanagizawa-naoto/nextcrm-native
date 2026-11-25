import AppKit

struct NativeDataMaintenanceDialogs {
    var source:(NSWindow,@escaping(URL?)->Void)->Void
    var destination:(NSWindow,NativeDataMaintenanceKind,@escaping(URL?)->Void)->Void
    var reveal:(URL)->Void
    static var system:Self {system(initialDirectory:nil)}
    static func system(initialDirectory:URL?)->Self {.init(source:{window,done in
        let panel=NSOpenPanel();panel.title="バックアップ・準備結果を選択";panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false;panel.directoryURL=initialDirectory
        panel.beginSheetModal(for:window){response in done(response == .OK ? panel.url:nil)}
    },destination:{window,kind,done in
        let panel=NSSavePanel();panel.title=kind == .backup ? "バックアップの保存先":"復元準備フォルダの保存先";panel.message="新しいフォルダ名を指定してください。既存のフォルダは置き換えません。";panel.canCreateDirectories=true;panel.directoryURL=initialDirectory
        let date=DateFormatter();date.dateFormat="yyyyMMdd-HHmmss";date.locale=Locale(identifier:"en_US_POSIX")
        panel.nameFieldStringValue=(kind == .backup ? "NextCRMバックアップ-":"NextCRM復元準備-")+date.string(from:Date())
        panel.beginSheetModal(for:window){response in done(response == .OK ? panel.url:nil)}
    },reveal:{NSWorkspace.shared.activateFileViewerSelecting([$0])})}
}

/// Root owns activation. This window prepares and inspects artifacts; its sole
/// handoff callback requests the separate, fully fenced activation review.
final class NativeDataMaintenanceWindow:NSObject,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:960,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    private let controller:NativeDataMaintenanceController,dialogs:NativeDataMaintenanceDialogs
    private let reader:NativeDataMaintenanceReader
    var onReviewActivation:((NativeDataMaintenanceArtifact)throws->Void)?
    var onPrepared:((NativeDataMaintenanceArtifact)->Void)?
    var onClosed:(()->Void)?
    private let mode=NSPopUpButton(),section=NSPopUpButton(),source=NSTextField(labelWithString:"未選択"),destination=NSTextField(labelWithString:"未選択")
    private let status=NSTextField(wrappingLabelWithString:""),progressLabel=NSTextField(labelWithString:""),pageLabel=NSTextField(labelWithString:""),detail=NSTextField(wrappingLabelWithString:"")
    private let progress=NSProgressIndicator(),table=NSTableView()
    private var refreshButton:NSButton!,startButton:NSButton!,sourceButton:NSButton!,destinationButton:NSButton!,openButton:NSButton!,cancelButton:NSButton!,previousButton:NSButton!,nextButton:NSButton!,revealButton:NSButton!,reviewButton:NSButton!,closeButton:NSButton!
    private var sourceURL:URL?,destinationURL:URL?,artifact:NativeDataMaintenanceArtifact?,page:NativeDataMaintenancePage?,sections:[NativeDataMaintenanceSection]=[]
    private var operation:NativeDataMaintenanceOperation?,task:Task<Void,Never>?,timer:Timer?,busy=false,dialogOpen=false,closed=false,closeRequested=false,authorized=false
    convenience init(service:CRMService,resources:URL,onReviewActivation:((NativeDataMaintenanceArtifact)throws->Void)?=nil){self.init(controller:.init(service:service,resources:resources),onReviewActivation:onReviewActivation)}
    init(controller:NativeDataMaintenanceController,onReviewActivation:((NativeDataMaintenanceArtifact)throws->Void)?=nil,dialogs:NativeDataMaintenanceDialogs = .system){
        self.controller=controller;self.onReviewActivation=onReviewActivation;self.dialogs=dialogs;reader=NativeDataMaintenanceReader(authorize:controller.authorize)
        super.init();window.title="バックアップと復元準備";window.delegate=self;window.minSize=NSSize(width:900,height:800)
        let heading=NSTextField(labelWithString:window.title);heading.font = .systemFont(ofSize:22,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"バックアップにはデータと管理対象の添付を保存します。復元準備では別フォルダに候補を作り、切り替え前に必要な確認事項を整理します。使用中のデータはこの画面では切り替えません。")
        mode.addItems(withTitles:["バックアップを作成","復元候補を準備"]);mode.target=self;mode.action=#selector(modeChanged);mode.setAccessibilityLabel("データ保全の操作")
        sourceButton=button("元のバックアップを選択",#selector(chooseSource));destinationButton=button("保存先を選択",#selector(chooseDestination))
        source.setAccessibilityLabel("元のバックアップ");destination.setAccessibilityLabel("データ保全の保存先")
        for field in [source,destination]{field.lineBreakMode = .byTruncatingMiddle;field.isSelectable=true}
        let sourceRow=NSStackView(views:[sourceButton,source]);sourceRow.spacing=12
        let destinationRow=NSStackView(views:[destinationButton,destination]);destinationRow.spacing=12
        startButton=button("バックアップを作成",#selector(begin));cancelButton=button("中止",#selector(cancel));openButton=button("保存済みの結果を開く",#selector(openExisting))
        refreshButton=button("権限を再確認",#selector(refreshAuthorization))
        let actions=NSStackView(views:[mode,startButton,cancelButton,NSView(),openButton,refreshButton]);actions.spacing=8
        progress.style = .spinning;progress.controlSize = .small;progress.isIndeterminate=true;progress.isDisplayedWhenStopped=false
        progress.widthAnchor.constraint(equalToConstant:18).isActive=true;progress.heightAnchor.constraint(equalToConstant:18).isActive=true
        progressLabel.setAccessibilityLabel("データ保全の進行状況");let running=NSStackView(views:[progress,progressLabel]);running.spacing=8
        status.maximumNumberOfLines=2;status.setAccessibilityLabel("データ保全の結果")
        section.target=self;section.action=#selector(sectionChanged);section.setAccessibilityLabel("データ保全の表示内容")
        for (id,title,width) in [("title","項目・対象",250.0),("value","結果・状態",190.0),("detail","必要な確認",420.0)]{let col=NSTableColumn(identifier:.init(id));col.title=title;col.width=width;col.minWidth=110;table.addTableColumn(col)}
        table.dataSource=self;table.delegate=self;table.rowHeight=52;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle;table.setAccessibilityLabel("データ保全の確認一覧")
        let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.autohidesScrollers=true
        previousButton=button("前の100件",#selector(previous));nextButton=button("次の100件",#selector(next));pageLabel.setAccessibilityLabel("データ保全のページ")
        section.widthAnchor.constraint(equalToConstant:210).isActive=true
        let paging=NSStackView(views:[section,previousButton,pageLabel,NSView(),nextButton]);paging.spacing=8
        detail.maximumNumberOfLines=4;detail.setAccessibilityLabel("選択した確認事項の説明");detail.textColor = .secondaryLabelColor
        revealButton=button("保存場所を表示",#selector(reveal));reviewButton=button("切り替え前の確認へ",#selector(review));closeButton=button("閉じる",#selector(close));closeButton.keyEquivalent="\u{1b}"
        let footer=NSStackView(views:[revealButton,reviewButton,NSView(),closeButton]);footer.spacing=8
        let views:[NSView]=[heading,help,actions,sourceRow,destinationRow,running,status,paging,scroll,detail,footer]
        let root=NSStackView(views:views);root.orientation = .vertical;root.alignment = .leading;root.spacing=8;root.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:16),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-16),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:16),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-16),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220),detail.heightAnchor.constraint(equalToConstant:58)])
        for view in views{view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
        source.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);destination.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        controls()
    }
    deinit{timer?.invalidate();operation?.cancel();task?.cancel()}
    var hasOperation:Bool{busy || dialogOpen}
    func start(){guard !closed,!busy else{return};do{try controller.authorize();authorized=true;status.stringValue="操作と保存先を選択してください。"}catch{deny(error)};controls()}
    func dismissForNavigation(){requestClose()}
    @objc private func refreshAuthorization(){start()}
    private var kind:NativeDataMaintenanceKind{mode.indexOfSelectedItem==1 ? .restore:.backup}
    private func button(_ title:String,_ action:Selector)->NSButton{let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;return b}
    private func controls(){
        let editable = !busy && !dialogOpen && !closed && !closeRequested && authorized
        refreshButton?.isEnabled = !busy && !dialogOpen && !closed && !closeRequested
        mode.isEnabled=editable;sourceButton?.isEnabled=editable && kind == .restore;destinationButton?.isEnabled=editable;openButton?.isEnabled=editable
        startButton?.title=kind == .backup ? "バックアップを作成":"復元候補を準備"
        startButton?.isEnabled=editable && destinationURL != nil && (kind == .backup || sourceURL != nil)
        cancelButton?.isEnabled=busy && operation?.progress.state == .running
        section.isEnabled=editable && artifact != nil
        previousButton?.isEnabled=editable && (page?.offset ?? 0)>0;nextButton?.isEnabled=editable && page?.hasNext==true
        revealButton?.isEnabled=editable && artifact != nil
        reviewButton?.isHidden=onReviewActivation==nil;reviewButton?.isEnabled=editable && artifact?.kind == .restore && onReviewActivation != nil
        closeButton?.title=busy ? "中止して閉じる":"閉じる";closeButton?.isEnabled = !closed && !closeRequested
    }
    private func message(_ error:Error)->String{(error as? NativeMigrationFailure)?.message ?? (error as? NativeDBError)?.localizedDescription ?? "内容を確認できませんでした。元のデータは変更していません。"}
    private func clearResult(){artifact=nil;page=nil;sections=[];section.removeAllItems();table.reloadData();detail.stringValue="";pageLabel.stringValue=""}
    private func deny(_ error:Error){authorized = (try? controller.authorize()) != nil;clearResult();status.textColor = .systemRed;status.stringValue=message(error);controls()}
    @objc private func modeChanged(){sourceURL=nil;destinationURL=nil;source.stringValue="未選択";destination.stringValue="未選択";controls()}
    @objc private func chooseSource(){choose(sourceSelection:true,openResult:false)}
    @objc private func chooseDestination(){choose(sourceSelection:false,openResult:false)}
    @objc private func openExisting(){choose(sourceSelection:true,openResult:true)}
    private func choose(sourceSelection:Bool,openResult:Bool){
        guard !hasOperation,!closed else{return};do{try controller.authorize()}catch{deny(error);return}
        dialogOpen=true;controls()
        let completion:(URL?)->Void = { [weak self] url in
            guard let self else{return};self.dialogOpen=false
            if self.closeRequested{self.finishClose();return}
            guard !self.closed,let url else{self.controls();return}
            do{try self.controller.authorize();if openResult{self.readExisting(url)}else if sourceSelection{self.sourceURL=url;self.source.stringValue=url.path;self.source.toolTip=url.path}else{self.destinationURL=url;self.destination.stringValue=url.path;self.destination.toolTip=url.path};self.controls()}catch{self.deny(error)}
        }
        if sourceSelection{dialogs.source(window,completion)}else{dialogs.destination(window,kind,completion)}
    }
    private func started(_ op:NativeDataMaintenanceOperation){busy=true;operation=op;progress.startAnimation(nil);status.textColor = .secondaryLabelColor;timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in guard let self else{return};self.progressLabel.stringValue=op.progress.message;self.controls()};controls()}
    private func finished(){busy=false;operation=nil;task=nil;timer?.invalidate();timer=nil;progress.stopAnimation(nil);progressLabel.stringValue="";controls()}
    @objc private func begin(){
        guard !hasOperation,!closed,let destinationURL,kind == .backup || sourceURL != nil else{return};do{try controller.authorize()}catch{deny(error);return}
        clearResult();let op=NativeDataMaintenanceOperation(),kind=kind,input=sourceURL,controller=controller;started(op);status.stringValue="完了までこの画面で進行状況を確認できます。"
        task=Task.detached{[weak self] in
            let outcome=controller.perform(kind:kind,backupURL:input,destinationURL:destinationURL,operation:op)
            await MainActor.run{[weak self] in
                guard let self else{return};self.finished()
                do{try controller.authorize()
                    self.status.stringValue=outcome.message+(outcome.cleanupPending ? " 作業用ファイルの回収を管理者が確認する必要があります。":"")
                    self.status.textColor=outcome.state == .failed ? .systemRed:.secondaryLabelColor
                    if let artifact=outcome.artifact{self.install(artifact);self.onPrepared?(artifact)}
                    if self.closeRequested{self.finishClose()}else if self.artifact != nil{self.loadPage(0)}
                }catch{self.deny(error);if self.closeRequested{self.finishClose()}}
            }
        }
    }
    private func readExisting(_ url:URL){
        let op=NativeDataMaintenanceOperation(),reader=reader,controller=controller;started(op);clearResult();status.stringValue="保存された結果を読み込んでいます…"
        task=Task.detached{[weak self] in let value=Result{try reader.open(url)}
            await MainActor.run{[weak self] in guard let self else{return};self.finished();do{try controller.authorize();if op.cancelled{throw CancellationError()};let artifact=try value.get();self.install(artifact);self.status.stringValue="保存された結果を表示しています。切り替え前には内容を再検証します。";if self.closeRequested{self.finishClose()}else{self.loadPage(0)}}catch{if error is CancellationError{self.status.stringValue="読み込みを中止しました。"}else{self.deny(error)};if self.closeRequested{self.finishClose()}}}
        }
    }
    private func install(_ value:NativeDataMaintenanceArtifact){artifact=value;sections=value.kind == .restore ? [.summary,.obligations,.plan,.files,.tables]:[.summary,.files,.tables];section.removeAllItems();section.addItems(withTitles:sections.map(\.title));section.selectItem(at:0);controls()}
    @objc private func sectionChanged(){loadPage(0)}
    @objc private func previous(){loadPage(max(0,(page?.offset ?? 0)-100))}
    @objc private func next(){guard let page,page.hasNext else{return};loadPage(page.offset+100)}
    private func loadPage(_ offset:Int64){
        guard !busy,!closed,!closeRequested,let artifact,sections.indices.contains(section.indexOfSelectedItem) else{return}
        let target=sections[section.indexOfSelectedItem],op=NativeDataMaintenanceOperation(),reader=reader,controller=controller
        page=nil;table.reloadData();detail.stringValue="";pageLabel.stringValue="";started(op)
        task=Task.detached{[weak self] in let value=Result{try reader.page(artifact,section:target,offset:offset,operation:op)}
            await MainActor.run{[weak self] in guard let self else{return};self.finished();do{try controller.authorize();if op.cancelled{throw CancellationError()};let page=try value.get();self.page=page;self.table.reloadData();self.pageLabel.stringValue=page.total==0 ? "0件":"\(page.offset+1)〜\(page.offset+Int64(page.rows.count))件 / \(page.total)件";self.controls()}catch{if error is CancellationError{self.status.stringValue="一覧の読み込みを中止しました。"}else{self.deny(error)}};if self.closeRequested{self.finishClose()}}
        }
    }
    @objc private func cancel(){guard busy else{return};if operation?.cancel()==false{status.stringValue="保存を確定しています。完了結果を確認してから閉じます。"};controls()}
    @objc private func reveal(){guard !hasOperation,let artifact else{return};do{try controller.authorize();dialogs.reveal(artifact.url)}catch{deny(error)}}
    @objc private func review(){guard !hasOperation,let artifact,artifact.kind == .restore else{return};do{try controller.authorize();try onReviewActivation?(artifact)}catch{deny(error)}}
    @objc private func close(){requestClose()}
    private func requestClose(){guard !closed else{return};closeRequested=true;if busy{_ = operation?.cancel();status.stringValue="作成途中の処理を終了してから閉じます。";controls()}else if dialogOpen{if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.cancel)}}else{finishClose()}}
    private func finishClose(){guard !closed,!busy,!dialogOpen else{return};closed=true;timer?.invalidate();timer=nil;if let parent=window.sheetParent{parent.endSheet(window)}else{window.close()};onClosed?()}
    func windowShouldClose(_ sender:NSWindow)->Bool{requestClose();return false}
    func numberOfRows(in tableView:NSTableView)->Int{page?.rows.count ?? 0}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let rows=page?.rows,rows.indices.contains(row) else{return nil};let item=rows[row],key=tableColumn?.identifier.rawValue ?? ""
        let id=NSUserInterfaceItemIdentifier("maintenance-value"),label=tableView.makeView(withIdentifier:id,owner:self) as? NSTextField ?? NSTextField(wrappingLabelWithString:"")
        label.identifier=id;label.maximumNumberOfLines=2;label.font = .systemFont(ofSize:12);label.stringValue=key=="title" ? item.title:key=="value" ? item.value:item.detail;label.toolTip=label.stringValue;return label
    }
    func tableViewSelectionDidChange(_ notification:Notification){guard let rows=page?.rows,rows.indices.contains(table.selectedRow) else{detail.stringValue="";return};detail.stringValue=rows[table.selectedRow].detail}
}
