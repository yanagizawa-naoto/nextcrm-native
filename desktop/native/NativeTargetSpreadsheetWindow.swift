import AppKit
import UniformTypeIdentifiers

@MainActor final class NativeTargetSpreadsheetWindow:NSObject,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSComboBoxDataSource,NSComboBoxDelegate {
    let window=NSPanel(contentRect:NSRect(x:0,y:0,width:920,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    let controller:NativeTargetSpreadsheetController
    let selection:NativeTargetSpreadsheetService.ExportSelection
    var onClosed:(()->Void)?
    private(set) var imported=false
    private(set) var busy=false,closed=false
    private var closing=false
    private var task:Task<Void,Never>?,progressTask:Task<Void,Never>?,closeTask:Task<Void,Never>?,drainTask:Task<Void,Never>?
    private var operation:NativeTargetSpreadsheetOperation?,session:NativeTargetSpreadsheetSession?
    private var headers:[String]=[],popups:[NSComboBox]=[]
    private var rows:[(position:Int64,values:[String:String],valid:Bool)]=[],notes:[(Int64,String)]=[]
    private var page:Int64=0,results=false
    private var noteCursors:[Int64]=[-1]
    private let status=NSTextField(wrappingLabelWithString:"CSVまたはExcelファイルを選択してください。一覧の選択行、または絞り込んだ全件の書き出しもできます。")
    private let file=NSTextField(labelWithString:"ファイル未選択")
    private let choose=NSButton(title:"ファイルを選択…",target:nil,action:nil)
    private let ai=NSButton(title:"AIで列を提案",target:nil,action:nil)
    private let preview=NSButton(title:"対応を確認",target:nil,action:nil)
    private let run=NSButton(title:"この内容で取り込む",target:nil,action:nil)
    private let csv=NSButton(title:"CSVを書き出す…",target:nil,action:nil)
    private let xlsx=NSButton(title:"Excelを書き出す…",target:nil,action:nil)
    private let previous=NSButton(title:"前の100行",target:nil,action:nil)
    private let next=NSButton(title:"次の100行",target:nil,action:nil)
    private let cancel=NSButton(title:"処理を中止",target:nil,action:nil)
    private let closeButton=NSButton(title:"閉じる",target:nil,action:nil)
    private let mapStack=NSStackView(),table=NSTableView()
    private let pageLabel=NSTextField(labelWithString:"内容の確認：100行ずつ表示（長いセルは先頭500文字）")
    init(controller:NativeTargetSpreadsheetController,selection:NativeTargetSpreadsheetService.ExportSelection = .init()) {
        self.controller=controller;self.selection=selection;super.init()
        window.title="営業対象の取り込み・書き出し";window.delegate=self;window.minSize=NSSize(width:800,height:660)
        let title=NSTextField(labelWithString:window.title);title.font = .systemFont(ofSize:21,weight:.semibold)
        let help=NSTextField(wrappingLabelWithString:"1. ファイル選択 → 2. 列の対応 → 3. 内容確認 → 4. 取り込み。姓または会社名が必要です。同じメールアドレスの行も新規登録し、過去の配信停止は引き継ぎます。AI提案では列名だけをOpenAIへ送信します。")
        let tools=NSStackView(views:[choose,ai,preview,NSView(),csv,xlsx]);tools.spacing=8
        mapStack.orientation = .vertical;mapStack.alignment = .leading;mapStack.spacing=6
        for field in NativeTargetSpreadsheetFields.all {
            let label=NSTextField(labelWithString:field.title);label.widthAnchor.constraint(equalToConstant:155).isActive=true
            let popup=NSComboBox();popup.usesDataSource=true;popup.dataSource=self;popup.delegate=self;popup.isEditable=false;popup.selectItem(at:0);popup.target=self;popup.action=#selector(mappingChanged);popup.setAccessibilityLabel("列の対応："+field.title)
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant:430).isActive=true;popups.append(popup)
            let row=NSStackView(views:[label,popup]);row.spacing=10;mapStack.addArrangedSubview(row)
        }
        let mapScroll=NSScrollView();mapScroll.documentView=mapStack;mapScroll.hasVerticalScroller=true;mapScroll.borderType = .bezelBorder
        mapStack.translatesAutoresizingMaskIntoConstraints=false;NSLayoutConstraint.activate([mapStack.leadingAnchor.constraint(equalTo:mapScroll.contentView.leadingAnchor,constant:8),mapStack.trailingAnchor.constraint(equalTo:mapScroll.contentView.trailingAnchor,constant:-8),mapStack.topAnchor.constraint(equalTo:mapScroll.contentView.topAnchor,constant:8)])
        mapScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:145).isActive=true
        table.dataSource=self;table.delegate=self;table.rowHeight=25;table.usesAlternatingRowBackgroundColors=true
        for (key,label,width) in [("_line","行",60.0),("_state","確認",90.0)]+NativeTargetSpreadsheetFields.all.map({($0.key,$0.title,145.0)}) {
            let column=NSTableColumn(identifier:.init(key));column.title=label;column.width=width;column.minWidth=40;table.addTableColumn(column)
        }
        table.setAccessibilityLabel("取り込み内容と結果")
        let tableScroll=NSScrollView();tableScroll.documentView=table;tableScroll.hasVerticalScroller=true;tableScroll.hasHorizontalScroller=true;tableScroll.borderType = .bezelBorder;tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:185).isActive=true
        let pager=NSStackView(views:[pageLabel,NSView(),previous,next]);pager.spacing=8
        let buttons=NSStackView(views:[NSView(),cancel,run,closeButton]);buttons.spacing=10
        for (button,action) in [(choose,#selector(selectFile)),(ai,#selector(suggest)),(preview,#selector(showPreview)),(run,#selector(importRows)),(csv,#selector(exportCSV)),(xlsx,#selector(exportXLSX)),(previous,#selector(previousPage)),(next,#selector(nextPage)),(cancel,#selector(cancelWork)),(closeButton,#selector(requestClose))] {button.target=self;button.action=action;button.bezelStyle = .rounded;button.setAccessibilityLabel(button.title)}
        closeButton.keyEquivalent="\u{1b}";file.lineBreakMode = .byTruncatingMiddle;status.setAccessibilityLabel("処理状況")
        let root=NSStackView(views:[title,help,tools,file,mapScroll,pager,tableScroll,status,buttons]);root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:18),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-18),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:18),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-18)])
        for view in [help,tools,file,mapScroll,pager,tableScroll,status,buttons]{view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
        refresh()
    }
    private func refresh() {
        let ready = !busy && !closing && !closed
        choose.isEnabled=ready;csv.isEnabled=ready;xlsx.isEnabled=ready
        let mappingReady=ready && session != nil && !results
        ai.isEnabled=mappingReady && controller.allowsAI;preview.isEnabled=mappingReady
        for popup in popups{popup.isEnabled=mappingReady}
        run.isEnabled=ready && session != nil && !results && !rows.isEmpty
        previous.isEnabled=ready && page>0
        next.isEnabled=ready && (results ? notes.count==100 : (page+1)*100 < (session?.draft.rowCount ?? 0))
        cancel.isEnabled=busy && !closing;closeButton.isEnabled = !closed
    }
    private func start(_ body:@escaping(NativeTargetSpreadsheetOperation)async throws->Void) {
        guard !busy,!closing,!closed else{return};let op=NativeTargetSpreadsheetOperation();operation=op;busy=true;refresh()
        progressTask=Task{[weak self] in
            while !Task.isCancelled {try? await Task.sleep(nanoseconds:150_000_000);guard !Task.isCancelled,let self,self.busy else{return};self.status.stringValue=op.message}
        }
        task=Task{[weak self] in
            guard let self else{return}
            do{try await body(op)}catch is CancellationError{self.status.stringValue="処理を中止しました。"}catch{self.status.stringValue=error.localizedDescription}
            self.progressTask?.cancel();self.progressTask=nil;self.busy=false;self.operation=nil;self.task=nil;self.refresh()
        }
    }
    /// Entry used by the actual picker and isolated lifecycle fixtures.
    func load(url:URL) {
        start{[self] op in
            if let previous=session{try await controller.close(previous);session=nil}
            let loaded=try await controller.load(url,operation:op);session=loaded
            headers=try await controller.headers(loaded,operation:op);try controller.revalidate();try op.check();file.stringValue=loaded.fileName+"（\(loaded.draft.rowCount)行）";results=false;rows=[];notes=[];page=0
            for popup in popups{popup.reloadData()}
            apply(.fallback(headers));status.stringValue="列の対応を確認し、「対応を確認」を押してください。";table.reloadData()
        }
    }
    private func apply(_ mapping:NativeTargetSpreadsheetMapping) {
        for (i,field) in NativeTargetSpreadsheetFields.all.enumerated() {
            let header=mapping.columns.first{$0.field==field.key}?.header
            let index=header.flatMap{h in headers.firstIndex{NativeTargetSpreadsheetFields.same($0,h)}}
            popups[i].selectItem(at:index.map{$0+1} ?? 0)
        }
    }
    private func mapping()->NativeTargetSpreadsheetMapping {
        var columns:[NativeTargetSpreadsheetMapping.Column]=[]
        for (i,popup) in popups.enumerated() where popup.indexOfSelectedItem>0 {
            let header=headers[popup.indexOfSelectedItem-1];columns.removeAll{NativeTargetSpreadsheetFields.same($0.header,header)}
            columns.append(.init(header:header,field:NativeTargetSpreadsheetFields.all[i].key))
        }
        // Empty UI selections mean import no columns, not the action's raw
        // canonical-header shortcut used only by programmatic empty mapping.
        if columns.isEmpty{columns=[.init(header:"",field:nil)]};return .init(columns:columns)
    }
    @objc private func mappingChanged(){rows=[];notes=[];page=0;table.reloadData();status.stringValue="対応を変更しました。もう一度内容を確認してください。";refresh()}
    @objc private func selectFile(){guard !busy,!closing else{return};let panel=NSOpenPanel();panel.allowedContentTypes=[.commaSeparatedText,UTType(filenameExtension:"xlsx")!];panel.allowsMultipleSelection=false;panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};self.load(url:url)}}
    @objc private func suggest(){guard controller.allowsAI,let session else{return};start{[self] op in let value=try await controller.suggest(session,operation:op);try controller.revalidate();try op.check();apply(value.mapping);rows=[];table.reloadData();status.stringValue=value.note ?? "AIの提案を反映しました。対応を確認してから取り込んでください。"}}
    @objc private func showPreview(){page=0;loadPage()}
    private func loadPage(){guard let session else{return};let map=mapping(),current=page
        start{[self] op in
            if results{notes=try await controller.notes(session,after:noteCursors[Int(current)],operation:op);rows=[];status.stringValue="取り込まなかった行の理由を表示しています。"}
            else{rows=try await controller.preview(session,mapping:map,after:current*100-1,operation:op);notes=[];status.stringValue="姓または会社名のない行は取り込まれません。元のセル値は省略せず保存します。"}
            try controller.revalidate();try op.check()
            pageLabel.stringValue="\(current*100+1)行目から表示（100行ずつ・セルは先頭500文字）";table.reloadData()
        }
    }
    @objc private func previousPage(){if page>0{page -= 1;loadPage()}}
    @objc private func nextPage(){if results,Int(page+1)>=noteCursors.count,let last=notes.last{noteCursors.append(last.0)};page += 1;loadPage()}
    @objc private func importRows(){guard let session else{return};let map=mapping();start{[self] op in
        let result=try await controller.importRows(session,mapping:map,operation:op);imported = imported || result.imported>0;results=true;page=0;noteCursors=[-1]
        // This read follows a committed operation. A subsequent Close/Cancel
        // cannot rewrite the outcome to 'nothing saved'.
        let reader=NativeTargetSpreadsheetOperation();notes=(try? await controller.notes(session,after:-1,operation:reader)) ?? [];rows=[];table.reloadData()
        status.stringValue="取り込み完了：\(result.imported)件、スキップ：\(result.skipped)件、配信停止を継承：\(result.suppressed)件。";pageLabel.stringValue="取り込まなかった行の理由（100行ずつ）"
    }}
    @objc private func exportCSV(){chooseExport(.csv)}
    @objc private func exportXLSX(){chooseExport(.xlsx)}
    private func chooseExport(_ format:NativeTargetSpreadsheetExport.Format){guard !busy,!closing else{return};let panel=NSSavePanel();panel.allowedContentTypes=[format == .csv ? .commaSeparatedText:UTType(filenameExtension:"xlsx")!];panel.nameFieldStringValue=format == .csv ? "営業対象.csv":"営業対象.xlsx";panel.beginSheetModal(for:window){[weak self] response in guard let self,response == .OK,let url=panel.url else{return};self.export(to:url,format:format,replace:FileManager.default.fileExists(atPath:url.path))}}
    func export(to url:URL,format:NativeTargetSpreadsheetExport.Format,replace:Bool){start{[self] op in let result=try await controller.export(selection,to:url,format:format,replace:replace,operation:op);status.stringValue="\(result.rows)件を書き出しました：\(result.url.path)"+(result.cleanupPending ? "\n作業用フォルダの回収は次回起動時に再試行します。":"")}}
    @objc private func cancelWork(){operation?.cancel();task?.cancel()}
    func stop(){closing=true;refresh();operation?.cancel();task?.cancel()}
    func confirmDiscard()->Bool {
        guard busy else{return true};let alert=NSAlert();alert.messageText="処理を中止して閉じますか？";alert.informativeText="保存の確定が始まっている場合は、完了を待って閉じます。";alert.addButton(withTitle:"中止して閉じる");alert.addButton(withTitle:"続ける");return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func requestClose(){guard confirmDiscard() else{return};if closeTask==nil{closeTask=Task{[self] in await stopAndDrain()}}}
    func windowShouldClose(_ sender:NSWindow)->Bool{requestClose();return false}
    /// Root Quit/restore drain calls this after its own confirmation. No new
    /// action is admitted; concurrent callers all join the same accepted work.
    func stopAndDrain()async {
        if let drainTask {await drainTask.value;return}
        guard !closed else{return}
        let task=Task{[self] in await finishClose()};drainTask=task;await task.value
    }
    private func finishClose()async {
        guard !closed else{return};closing=true;refresh();operation?.cancel();task?.cancel()
        if let child=window.attachedSheet{window.endSheet(child,returnCode:.cancel)}
        let accepted=task;await accepted?.value
        if let session{self.session=nil;do{try await controller.close(session)}catch{status.stringValue="作業用フォルダを回収できませんでした。次回起動時に再試行します。"}}
        guard !closed else{return};closed=true;progressTask?.cancel();progressTask=nil
        if let parent=window.sheetParent{parent.endSheet(window)}else{window.orderOut(nil)};onClosed?();onClosed=nil
    }
    func numberOfItems(in comboBox:NSComboBox)->Int{headers.count+1}
    func comboBox(_ comboBox:NSComboBox,objectValueForItemAt index:Int)->Any? {
        if index==0{return "取り込まない"};guard headers.indices.contains(index-1) else{return nil}
        let value=headers[index-1];return value.isEmpty ? "（空の列名）":String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
    }
    func comboBoxSelectionDidChange(_ notification:Notification){mappingChanged()}
    func numberOfRows(in tableView:NSTableView)->Int{results ? notes.count:rows.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard let key=tableColumn?.identifier.rawValue else{return nil};let text:String
        if results {guard notes.indices.contains(row) else{return nil};text=key=="_line" ? String(notes[row].0+2):key=="last_name" ? notes[row].1:""}
        else{guard rows.indices.contains(row) else{return nil};let value=rows[row];text=key=="_line" ? String(value.position+2):key=="_state" ? (value.valid ? "取込対象":"スキップ"):value.values[key] ?? ""}
        let label=NSTextField(labelWithString:text);label.lineBreakMode = .byTruncatingTail;label.toolTip=text;return label
    }
}
