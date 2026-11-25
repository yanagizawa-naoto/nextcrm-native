import AppKit

/// A single native drawing surface; only the currently selected result page is
/// retained. Exact names and values remain available in the accessible table.
final class NativeReportChart: NSView {
    var rows: [NativeReportRow] = []
    var section: NativeReportSection?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame:frame); setAccessibilityElement(true); setAccessibilityRole(.image) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(_ rows: [NativeReportRow], section: NativeReportSection?, width: CGFloat) {
        self.rows = rows; self.section = section
        frame.size = NSSize(width:max(width,section?.chart == "pie" ? width : CGFloat(rows.count)*62+70),height:210)
        setAccessibilityLabel((section?.title ?? "グラフ")+"。詳しい値は下の集計結果表で確認できます。")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        guard let section, !rows.isEmpty else { return }
        let values = rows.map { Double($0.value).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        let secondary = rows.map { $0.secondary.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        func text(_ value: String, _ rect: NSRect, color: NSColor = .secondaryLabelColor, size: CGFloat = 10, alignment: NSTextAlignment = .left) {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment=alignment
            (value as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color,.paragraphStyle:style])
        }
        if section.chart == "pie" {
            let total = values.reduce(0,+); guard total > 0, total.isFinite else { return }
            let center = NSPoint(x:bounds.midX,y:94), radius:CGFloat = 76
            var angle:CGFloat = -90
            for (i,value) in values.enumerated() where value > 0 {
                let end = angle+CGFloat(value/total)*360, path = NSBezierPath()
                path.move(to:center); path.appendArc(withCenter:center,radius:radius,startAngle:angle,endAngle:end,clockwise:false); path.close()
                NSColor(calibratedHue:(CGFloat(i)*0.173).truncatingRemainder(dividingBy:1),saturation:0.62,brightness:0.82,alpha:1).setFill(); path.fill(); angle=end
                NSRect(x:center.x+110,y:25+CGFloat(i)*30,width:12,height:12).fill()
                text(NativeReportPresentation.label(rows[i].name,section:section.id)+"  "+NativeReportPresentation.number(rows[i].value),NSRect(x:center.x+130,y:22+CGFloat(i)*30,width:max(0,bounds.width-center.x-140),height:20),color:.labelColor,size:12)
            }
            text("合計 "+NativeReportPresentation.number(String(total)),NSRect(x:bounds.midX-90,y:182,width:180,height:20),size:12)
            return
        }
        let maxValue = max(1,(values+secondary).max() ?? 1), minValue = min(0,(values+secondary).min() ?? 0)
        let range = maxValue-minValue, left:CGFloat = 60, top:CGFloat = 18, height:CGFloat = 145
        let step = (bounds.width-left-12)/CGFloat(max(1,rows.count))
        func y(_ value: Double) -> CGFloat { top+height-CGFloat((value-minValue)/range)*height }
        let axis=NSBezierPath();axis.move(to:NSPoint(x:left,y:y(0)));axis.line(to:NSPoint(x:bounds.width-8,y:y(0)));NSColor.separatorColor.setStroke();axis.stroke()
        text(NativeReportPresentation.number(String(maxValue)),NSRect(x:4,y:top-6,width:54,height:20))
        text(NativeReportPresentation.number(String(minValue)),NSRect(x:4,y:top+height-8,width:54,height:20))
        let line=NSBezierPath(),area=NSBezierPath()
        for (i,row) in rows.enumerated() {
            let x=left+CGFloat(i)*step+step/2, point=NSPoint(x:x,y:y(values[i]))
            if section.chart == "area" {
                if i==0 {line.move(to:point);area.move(to:NSPoint(x:x,y:y(0)))} else {line.line(to:point)}
                area.line(to:point)
                if i==rows.count-1 {area.line(to:NSPoint(x:x,y:y(0)));area.close()}
            } else {
                let width=max(2,min(36,step-10)), paired=section.secondaryTitle != nil
                NSColor.systemBlue.setFill();NSRect(x:x-width/2,y:min(y(0),point.y),width:paired ? width/2 : width,height:max(1,abs(y(0)-point.y))).fill()
                if paired {NSColor.systemTeal.setFill();NSRect(x:x,y:min(y(0),y(secondary[i])),width:width/2,height:max(1,abs(y(0)-y(secondary[i])))).fill()}
            }
            text(NativeReportPresentation.label(row.name,section:section.id),NSRect(x:x-step/2+3,y:174,width:step-6,height:18),alignment:.center)
        }
        if section.chart == "area" {
            NSColor.systemBlue.withAlphaComponent(0.12).setFill();area.fill();NSColor.systemBlue.setStroke();line.lineWidth=2;line.stroke()
            // A one-month period still needs a visible mark; a path containing
            // only move(to:) has neither a stroke nor a filled area.
            NSColor.systemBlue.setFill()
            for (i,value) in values.enumerated() {NSBezierPath(ovalIn:NSRect(x:left+CGFloat(i)*step+step/2-3,y:y(value)-3,width:6,height:6)).fill()}
        }
        if let second=section.secondaryTitle {text("青：作成　緑："+second,NSRect(x:left,y:194,width:300,height:16))}
    }
}

final class NativeReportsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let activities:NativeRestoreParentActivities
    private let activityOwner=UUID().uuidString
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1060,height:850),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService, categories: [NativeReportCategory]
    private let category = NSPopUpButton(), preset = NSPopUpButton(), currency = NSPopUpButton(), section = NSPopUpButton(), sorting = NSPopUpButton()
    private let from = NSDatePicker(), to = NSDatePicker(), table = NSTableView(), chart = NativeReportChart(frame:.zero), chartScroll = NSScrollView()
    private let metrics = NSStackView(), header = LightweightTableCell(), message = NSTextField(wrappingLabelWithString:""), count = NSTextField(labelWithString:"")
    private let resultScroll=NSScrollView(),selectors=NSStackView(),savedName=NSTextField(labelWithString:"")
    private var configurationsWindow:NativeReportConfigurationsWindow?,saveConfigurationButton:NSButton!,openConfigurationsButton:NSButton!,csvButton:NSButton!,pdfButton:NSButton!
    private var schedulesWindow:NativeReportSchedulesWindow?,schedulesButton:NSButton!
    var onReviewReport:NativeReportSchedulesWindow.Review?
    private let allowsDelivery:Bool
    private let exportDialog:NativeReportExportDialog.Present
    private var exporting=false,pageTotal=0
    private var savedParameters:[String:String]=[:],loadedPeriod:NativeReportFilters?
    private var refreshButton: NSButton!, cancelButton: NSButton!, previous: NSButton!, next: NSButton!
    private var snapshot: NativeReportSnapshot?, rows: [NativeReportRow] = [], task: Task<Void,Never>?, generation = 0, offset = 0
    private var observer: NSObjectProtocol?
    private var columns: [NativeColumn] = []
    init(service: CRMService,activities:NativeRestoreParentActivities = .init(),exportDialog:@escaping NativeReportExportDialog.Present = NativeReportExportDialog.show,allowsDelivery:Bool=true) throws {
        try service.authenticated(); self.service = service;self.activities=activities
        self.exportDialog=exportDialog;self.allowsDelivery=allowsDelivery
        categories = NativeReportCategory.allCases.filter { $0 != .users || service.identity.elevated }
        super.init(); window.title = "レポート"
        let title = NSTextField(labelWithString:"レポート"); title.font = .systemFont(ofSize:22,weight:.semibold)
        category.addItems(withTitles:categories.map(\.title)); category.setAccessibilityLabel("レポートの種類"); category.target=self;category.action = #selector(rebuild)
        preset.addItems(withTitles:["過去7日","過去30日","過去90日","今年","すべて（2020年以降）","期間を指定"]);preset.selectItem(at:1);preset.target=self;preset.action = #selector(presetChanged);preset.setAccessibilityLabel("集計期間")
        for (picker,label) in [(from,"集計の開始日"),(to,"集計の終了日")] {picker.datePickerStyle = .textFieldAndStepper;picker.datePickerElements = .yearMonthDay;picker.locale=Locale(identifier:"ja_JP");picker.setAccessibilityLabel(label);picker.target=self;picker.action = #selector(datesChanged)}
        currency.addItems(withTitles:["JPY","USD","EUR","CZK","GBP"]);currency.setAccessibilityLabel("レポートの表示通貨");currency.target=self;currency.action = #selector(rebuild)
        refreshButton=button("再集計",#selector(rebuild));cancelButton=button("集計を中止",#selector(cancel));cancelButton.isEnabled=false
        let filters=NSStackView(views:[category,preset,from,NSTextField(labelWithString:"〜"),to,currency,refreshButton,cancelButton]);filters.spacing=8
        saveConfigurationButton=button("条件を保存…",#selector(saveConfiguration));savedName.lineBreakMode = .byTruncatingTail;savedName.setAccessibilityLabel("読み込んだレポート条件")
        openConfigurationsButton=button("保存した条件…",#selector(openConfigurations));csvButton=button("CSV出力…",#selector(exportCSV));pdfButton=button("PDF出力…",#selector(exportPDF))
        schedulesButton=button("定期送信…",#selector(openSchedules));schedulesButton.isEnabled=allowsDelivery
        let savedControls=NSStackView(views:[saveConfigurationButton,openConfigurationsButton,schedulesButton,csvButton,pdfButton,savedName,NSView()]);savedControls.spacing=8
        metrics.orientation = .vertical;metrics.alignment = .leading;metrics.spacing=8
        section.target=self;section.action = #selector(sectionChanged);section.setAccessibilityLabel("集計項目")
        sorting.addItems(withTitles:["標準順","値の大きい順","値の小さい順","名前順"]);sorting.setAccessibilityLabel("集計結果の並び順");sorting.target=self;sorting.action = #selector(sectionChanged)
        for view in [section,sorting,NSView()] {selectors.addArrangedSubview(view)};selectors.spacing=10
        chartScroll.documentView=chart;chartScroll.hasHorizontalScroller=true;chartScroll.autohidesScrollers=true;chartScroll.heightAnchor.constraint(equalToConstant:230).isActive=true
        let column=NSTableColumn(identifier:.init("report"));column.width=1000;table.addTableColumn(column);table.headerView=nil;table.rowHeight=31;table.delegate=self;table.dataSource=self;table.setAccessibilityLabel("レポートの集計結果")
        resultScroll.documentView=table;resultScroll.hasVerticalScroller=true;resultScroll.autohidesScrollers=true;resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true
        header.heightAnchor.constraint(equalToConstant:25).isActive=true
        previous=button("前の100件",#selector(previousPage));next=button("次の100件",#selector(nextPage))
        let footer=NSStackView(views:[previous,count,next,NSView(),button("閉じる",#selector(close))]);footer.spacing=10
        message.maximumNumberOfLines=3;message.setAccessibilityLabel("レポートの状態")
        let views:[NSView]=[title,filters,savedControls,metrics,selectors,chartScroll,header,resultScroll,message,footer]
        let root=NSStackView(views:views);root.orientation = .vertical;root.alignment = .leading;root.spacing=9;root.translatesAutoresizingMaskIntoConstraints=false
        let content=window.contentView!;content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:content.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20)])
        for view in views {view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true}
        observer=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:window,queue:.main) { [weak self] _ in self?.validate() }
        setPreset();clear()
    }
    deinit {task?.cancel();if let observer {NotificationCenter.default.removeObserver(observer)}}
    private func button(_ title: String,_ selector: Selector) -> NSButton {let button=NSButton(title:title,target:self,action:selector);button.bezelStyle = .rounded;return button}
    func start() { rebuild() }
    private var selectedCategory: NativeReportCategory {categories[max(0,category.indexOfSelectedItem)]}
    private func period() throws -> NativeReportFilters {
        if let loadedPeriod {return loadedPeriod}
        let calendar=Calendar.current,first=calendar.startOfDay(for:from.dateValue),last=calendar.startOfDay(for:to.dateValue)
        guard let following=calendar.date(byAdding:.day,value:1,to:last) else {throw NativeDBError.conflict}
        return try NativeReportFilters(from:first,to:following.addingTimeInterval(-0.001))
    }
    private func setPreset() {
        let calendar=Calendar.current,now=Date();to.dateValue=now
        switch preset.indexOfSelectedItem {
        case 0,1,2:from.dateValue=calendar.date(byAdding:.day,value:-[7,30,90][preset.indexOfSelectedItem],to:now)!
        case 3:from.dateValue=calendar.date(from:calendar.dateComponents([.year],from:now))!
        case 4:from.dateValue=calendar.date(from:DateComponents(year:2020,month:1,day:1))!
        default:break
        }
    }
    @objc private func presetChanged() {if preset.indexOfSelectedItem != 5 {loadedPeriod=nil;savedName.stringValue="";setPreset();rebuild()}}
    @objc private func datesChanged() {loadedPeriod=nil;savedName.stringValue="";preset.selectItem(at:5);rebuild()}
    private func clear() {
        rows=[];table.reloadData();snapshot=nil;section.removeAllItems();previous.isEnabled=false;next.isEnabled=false;count.stringValue="";pageTotal=0;csvButton.isEnabled=false;pdfButton.isEnabled=false
        for view in metrics.arrangedSubviews {metrics.removeArrangedSubview(view);view.removeFromSuperview()}
        chart.show([],section:nil,width:chartScroll.contentSize.width)
    }
    private func invalidate() {task?.cancel();task=nil;generation+=1;clear();setExporting(false);refreshButton.isEnabled=true;cancelButton.isEnabled=false}
    @objc private func rebuild() {
        guard !activities.isSealed else{return}
        invalidate();offset=0
        let filters:NativeReportFilters
        do {filters=try period()} catch {show(error);return}
        let kind=selectedCategory,money=currency.titleOfSelectedItem ?? "JPY",engine=NativeReports(service:service),version=generation
        currency.isEnabled = kind == .sales || kind == .overview
        saveConfigurationButton.isEnabled = kind != .overview
        refreshButton.isEnabled=false;cancelButton.isEnabled=true;message.textColor = .secondaryLabelColor;message.stringValue="集計しています…"
        task=activities.spawn(owner:activityOwner,kind:.readOnly) { [weak self] in
            let result=Result {try engine.build(kind,filters:filters,currency:money)}
            guard !Task.isCancelled else {return}
            await MainActor.run { [weak self] in
                guard let self,self.generation==version else{return};self.task=nil;self.refreshButton.isEnabled=true;self.cancelButton.isEnabled=false
                switch result {
                case let .success(snapshot):
                    self.snapshot=snapshot;self.section.addItems(withTitles:snapshot.sections.map(\.title));self.renderMetrics(snapshot);self.loadPage()
                case let .failure(error):self.show(error)
                }
            }
        }
    }
    private func renderMetrics(_ snapshot: NativeReportSnapshot) {
        let overview=snapshot.category == .overview
        selectors.isHidden=overview;header.isHidden=overview;resultScroll.isHidden=overview
        chartScroll.isHidden=overview
        previous.isHidden=overview;next.isHidden=overview;count.isHidden=overview
        for start in stride(from:0,to:snapshot.metrics.count,by:5) {
            let line=NSStackView();line.distribution = .fillEqually;line.spacing=12
            for (i,metric) in snapshot.metrics.enumerated() where i>=start && i<start+5 {
                let label=NSTextField(labelWithString:metric.title),value=NSTextField(labelWithString:NativeReportPresentation.number(metric.value)+(metric.unit.isEmpty ? "" : " "+metric.unit))
                label.font = .systemFont(ofSize:12);value.font = .systemFont(ofSize:20,weight:.semibold);value.lineBreakMode = .byTruncatingMiddle;value.toolTip=value.stringValue
                let change=NSTextField(labelWithString:metric.changePercent.map{"前期比 "+($0>0 ? "+" : "")+String($0)+"%"} ?? "")
                change.font = .systemFont(ofSize:11);change.textColor = .secondaryLabelColor
                let views:[NSView]=[label,value,change]
                let card=NSStackView(views:views);card.orientation = .vertical;card.alignment = .leading;card.spacing=3
                if metric.destination != nil {let open=button("詳細を見る",#selector(drilldown(_:)));open.tag=i;card.addArrangedSubview(open)}
                line.addArrangedSubview(card)
            }
            metrics.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:metrics.widthAnchor).isActive=true
        }
        window.setContentSize(NSSize(width:1060,height:overview ? 480 : 850))
    }
    @objc private func drilldown(_ button: NSButton) {
        guard let snapshot,snapshot.metrics.indices.contains(button.tag),let target=snapshot.metrics[button.tag].destination,let index=categories.firstIndex(of:target) else{return}
        do {try snapshot.requireCurrent();category.selectItem(at:index);rebuild()} catch {invalidate();show(error)}
    }
    @objc private func sectionChanged() {offset=0;loadPage()}
    @objc private func previousPage() {offset=max(0,offset-100);loadPage()}
    @objc private func nextPage() {offset+=100;loadPage()}
    private func loadPage() {
        guard !activities.isSealed else{return}
        task?.cancel();generation+=1;let version=generation
        csvButton.isEnabled=false;pdfButton.isEnabled=false
        guard let snapshot else{return}
        do {try snapshot.requireCurrent()} catch {invalidate();show(error);return}
        if snapshot.sections.isEmpty {rows=[];table.reloadData();section.isEnabled=false;sorting.isEnabled=false;chartScroll.isHidden=true;message.stringValue="表示期間の指標と、同じ長さの前期間からの変化です。"+rateWarning(snapshot);return}
        section.isEnabled=true;sorting.isEnabled=true
        let item=snapshot.sections[max(0,section.indexOfSelectedItem)],position=offset,sort=sorting.indexOfSelectedItem
        rows=[];table.reloadData();previous.isEnabled=false;next.isEnabled=false;message.stringValue="集計結果を読み込んでいます…"
        task=activities.spawn(owner:activityOwner,kind:.readOnly) { [weak self] in
            let result=Result {try snapshot.page(item.id,offset:position,sort:sort==0 ? "original" : sort==3 ? "label" : "value",ascending:sort != 1)}
            guard !Task.isCancelled else{return}
            await MainActor.run { [weak self] in
                guard let self,self.generation==version else{return};self.task=nil
                switch result {
                case let .success(page):
                    self.pageTotal=page.total;self.csvButton.isEnabled=true;self.pdfButton.isEnabled=true
                    self.rows=page.rows;self.columns=[NativeColumn(title:"項目",fraction:item.secondaryTitle == nil ? 0.75 : 0.6),NativeColumn(title:item.secondaryTitle == nil ? "値" : "作成",fraction:item.secondaryTitle == nil ? 0.25 : 0.2)]
                    if let title=item.secondaryTitle {self.columns.append(NativeColumn(title:title,fraction:0.2))}
                    self.header.configure(columns:self.columns,values:self.columns.map(\.title),heading:true);self.table.reloadData()
                    self.previous.isEnabled=position>0;self.next.isEnabled=position+page.rows.count<page.total
                    self.count.stringValue="\(page.total==0 ? 0 : position+1)〜\(position+page.rows.count) ／ \(page.total)件"
                    self.chartScroll.isHidden=item.chart == "table";self.chart.show(page.rows,section:item,width:self.chartScroll.contentSize.width)
                    self.message.textColor = .secondaryLabelColor
                    self.message.stringValue=(page.total==0 ? "この期間に該当するデータはありません。" : "表とグラフは同じ100件単位で表示します。")+self.rateWarning(snapshot)
                case let .failure(error):self.invalidate();self.show(error)
                }
            }
        }
    }
    private func rateWarning(_ snapshot: NativeReportSnapshot) -> String {snapshot.missingRateCount>0 ? " 換算レートがない商談が\(snapshot.missingRateCount)件あり、元の金額を含めています。" : ""}
    private func setExporting(_ value:Bool) {
        exporting=value
        for control in [category,preset,from,to,sorting,section] as [NSControl] {control.isEnabled = !value}
        currency.isEnabled = !value && (selectedCategory == .sales || selectedCategory == .overview)
        saveConfigurationButton.isEnabled = !value && selectedCategory != .overview;openConfigurationsButton.isEnabled = !value
        schedulesButton.isEnabled = !value && allowsDelivery
        refreshButton.isEnabled = !value;cancelButton.isEnabled=value;cancelButton.title=value ? "出力を中止" : "集計を中止"
        csvButton.isEnabled = !value && snapshot != nil && selectedCategory != .overview;pdfButton.isEnabled=csvButton.isEnabled
        previous.isEnabled = !value && offset>0;next.isEnabled = !value && offset+rows.count<pageTotal
    }
    @objc private func openSchedules(){
        guard allowsDelivery else {message.stringValue="復元した定期送信は確認待ちです。集計・条件保存・CSV/PDF出力は利用できます。";return}
        guard !exporting,window.attachedSheet==nil else{return}
        do {let controller=try NativeReportSchedulesWindow(store:.init(service:service),activities:activities);controller.onReview=onReviewReport;schedulesWindow=controller
            window.beginSheet(controller.window){[weak self] _ in self?.schedulesWindow=nil;self?.rebuild()};controller.start()
        }catch{show(error)}
    }
    @objc private func exportCSV(){export(.csv)}
    @objc private func exportPDF(){export(.pdf)}
    private func export(_ format:NativeReportExportFormat) {
        guard !activities.isSealed else{return}
        guard !exporting,window.attachedSheet==nil,let snapshot,selectedCategory != .overview else{return}
        do{try snapshot.requireCurrent()}catch{invalidate();show(error);return}
        exportDialog(window,snapshot,format){[weak self] choice in
            guard let self,!self.activities.isSealed,let choice else{return}
            self.task?.cancel();self.generation+=1;let version=self.generation;self.setExporting(true);self.message.textColor = .secondaryLabelColor;self.message.stringValue="レポートを書き出しています…"
            self.task=self.activities.spawn(owner:self.activityOwner,kind:.acceptedWrite){[weak self] in
                let result=Result{try NativeReportExport.write(snapshot,section:choice.sectionID,format:format,to:choice.url)}
                guard !Task.isCancelled else{return}
                await MainActor.run{[weak self] in guard let self,self.generation==version else{return};self.task=nil
                    switch result{case let .success(count):self.setExporting(false);self.message.stringValue="\(count)件を保存しました："+choice.url.lastPathComponent
                    case let .failure(error):self.invalidate();self.show(error)}
                }
            }
        }
    }
    @objc private func openConfigurations() {
        guard window.attachedSheet==nil else{return}
        do {
            let controller=try NativeReportConfigurationsWindow(store:NativeReportConfigurations(service:service),category:selectedCategory == .overview ? nil : selectedCategory,activities:activities);configurationsWindow=controller
            window.beginSheet(controller.window){[weak self,weak controller] _ in
                guard let self else{return};self.configurationsWindow=nil
                if let config=controller?.selected {self.applyConfiguration(config)} else if controller?.didModify == true {self.rebuild()}
            }
            controller.start()
        }catch{show(error)}
    }
    private func applyConfiguration(_ config:NativeReportConfiguration) {
        do {
            guard let index=categories.firstIndex(of:config.category) else{throw NativeDBError.message("このレポートの種類を表示する権限がありません。")}
            let period=try config.filters.period(),money=try config.filters.currency
            loadedPeriod=period;savedParameters=config.filters.parameters;category.selectItem(at:index);from.dateValue=period.from;to.dateValue=period.to;preset.selectItem(at:5)
            if currency.indexOfItem(withTitle:money)<0 {currency.addItem(withTitle:money)};currency.selectItem(withTitle:money)
            savedName.stringValue="保存条件："+String(config.name.prefix(256));rebuild()
        }catch{invalidate();show(error)}
    }
    @objc private func saveConfiguration() {
        guard !activities.isSealed else{return}
        guard selectedCategory != .overview,window.attachedSheet==nil else{return}
        let filters:NativeReportSavedFilters
        do {filters=try NativeReportSavedFilters(period:period(),currency:currency.titleOfSelectedItem ?? "JPY",retaining:savedParameters)}catch{show(error);return}
        let kind=selectedCategory,store=NativeReportConfigurations(service:service),alert=NSAlert();alert.messageText="レポートの条件を保存"
        let name=NSTextField(frame:NSRect(x:0,y:34,width:420,height:26));name.placeholderString="レポート名";name.setAccessibilityLabel("保存するレポート名")
        let shared=NSButton(checkboxWithTitle:"他の利用者と条件を共有",target:nil,action:nil);shared.frame=NSRect(x:0,y:0,width:420,height:26)
        let accessory=NSView(frame:NSRect(x:0,y:0,width:420,height:64));accessory.addSubview(name);accessory.addSubview(shared);alert.accessoryView=accessory;alert.addButton(withTitle:"保存");alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window){[weak self] response in
            guard let self,!self.activities.isSealed,response == .alertFirstButtonReturn else{return};let title=name.stringValue,share=shared.state == .on
            self.persistConfiguration(title:title,shared:share,filters:filters,kind:kind)
        }
        alert.window.makeFirstResponder(name)
    }
    private func persistConfiguration(title:String,shared:Bool,filters:NativeReportSavedFilters,kind:NativeReportCategory) {
        guard !activities.isSealed,activities.pendingWrites(owner:activityOwner)==0 else{return}
        let store=NativeReportConfigurations(service:service)
        task?.cancel();generation+=1;let version=generation;saveConfigurationButton.isEnabled=false;message.stringValue="条件を保存しています…"
        task=activities.spawn(owner:activityOwner,kind:.acceptedWrite){[weak self] in
            let result=Result{try store.save(name:title,category:kind,filters:filters,shared:shared)}
            await MainActor.run{[weak self] in guard let self,self.generation==version else{return};self.task=nil
                switch result{case let .success(config):self.savedName.stringValue="保存条件："+config.name;self.rebuild()
                case let .failure(error):self.saveConfigurationButton.isEnabled=true;self.show(error)}
            }
        }
    }
    #if RESTORE_PARENT_TESTING
    func saveConfigurationForTesting(_ title:String)throws {
        let filters=try NativeReportSavedFilters(period:period(),currency:"JPY")
        persistConfiguration(title:title,shared:false,filters:filters,kind:.sales)
    }
    func cancelCurrentForTesting(){cancel()}
    var hasCurrentForTesting:Bool {task != nil}
    #endif
    private func validate() {guard let snapshot else{return};do{try snapshot.requireCurrent()}catch{invalidate();show(error)}}
    private func show(_ error: Error) {message.textColor = .systemRed;message.stringValue=error.localizedDescription}
    @objc private func cancel() {let wasExport=exporting;invalidate();message.stringValue=wasExport ? "出力を中止しました。" : "集計を中止しました。"}
    func confirmDiscard()->Bool {activities.pendingWrites(owner:activityOwner)==0 && window.attachedSheet==nil && schedulesWindow?.confirmDiscard() != false && configurationsWindow?.confirmDiscard() != false}
    @objc private func close() {guard window.attachedSheet==nil,confirmDiscard() else{return};invalidate();window.sheetParent?.endSheet(window);window.orderOut(nil)}
    func numberOfRows(in tableView: NSTableView) -> Int {rows.count}
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row),let snapshot,snapshot.sections.indices.contains(section.indexOfSelectedItem) else{return nil}
        let item=rows[row],kind=snapshot.sections[section.indexOfSelectedItem],id=NSUserInterfaceItemIdentifier("reportRow")
        let cell=tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell();cell.identifier=id
        var values=[NativeReportPresentation.label(item.name,section:kind.id)+(item.truncated ? "…" : ""),NativeReportPresentation.number(item.value)]
        if let secondary=item.secondary {values.append(NativeReportPresentation.number(secondary))}
        cell.configure(columns:columns,values:values);return cell
    }
}
