import AppKit

final class CRMTemplatesWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let campaignAI: CampaignAIService?
    private let allowsAI: Bool; private let table = NSTableView(); private let search = NSSearchField()
    private let trash = NSButton(checkboxWithTitle:"削除済みを表示",target:nil,action:nil)
    private let info = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private var buttons: [String:NSButton] = [:]; private var rows: [CampaignTemplateRow] = []; private var offset = 0; private var total = 0
    private var loading = false; private var busy = false; private var generation = 0; private var pending: DispatchWorkItem?
    private var editor: CampaignTemplateEditor?; private let queue = MemoryBudget.queue(label:"local.nextcrm.native.templates"); private let memory = MemoryBudget()
    init(service: CRMService, ai: CampaignAIService? = nil, allowsAI: Bool = true) throws {
        self.campaignAI = ai; self.allowsAI=allowsAI;
        self.service = service; try service.authenticated(); super.init(); window.title = "メールテンプレート"
        let heading = NSTextField(labelWithString:"メールテンプレート"); heading.font = .systemFont(ofSize:22,weight:.semibold)
        search.placeholderString = "テンプレートを検索"; search.delegate = self; search.setAccessibilityLabel("メールテンプレートを検索")
        trash.target = self; trash.action = #selector(filterChanged); trash.isHidden = service.identity.role != "admin"
        let actions = NSStackView(views:[button("new","新規テンプレート…",#selector(create)),button("edit","編集…",#selector(edit)),button("delete","削除…",#selector(remove)),button("restore","復元",#selector(restore)),trash,NSView(),button("refresh","再読み込み",#selector(refresh))]); actions.spacing = 8
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("templates")); column.width = 990; table.addTableColumn(column); table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 40; table.target = self; table.doubleAction = #selector(edit); table.setAccessibilityLabel("メールテンプレートの一覧")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); footer.spacing = 10; buttons["close"]?.keyEquivalent = "\u{1b}"
        message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor; message.maximumNumberOfLines = 3
        let root = NSStackView(views:[heading,search,actions,header,scroll,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:360)])
        for v in [search,actions,header,scroll,message,footer] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }; load()
    }
    private var columns: [NativeColumn] { [NativeColumn(title:"テンプレート名",fraction:0.3),NativeColumn(title:"件名",fraction:0.34),NativeColumn(title:"作成者",fraction:0.18),NativeColumn(title:"更新日",fraction:0.18)] }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].record : nil }
    private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private func controls() {
        let ready = !busy && !loading
        buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready; search.isEnabled = !busy; trash.isEnabled = !busy
        buttons["new"]?.isEnabled = ready && ["admin","manager","user"].contains(service.identity.role)
        for id in ["edit","delete"] { buttons[id]?.isEnabled = ready && selected != nil && trash.state != .on }
        buttons["restore"]?.isHidden = trash.state != .on; buttons["restore"]?.isEnabled = ready && selected != nil && service.identity.role == "admin"
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(total,offset+rows.count)) ／ \(total)件"
    }
    private func load(delay: Double = 0) {
        pending?.cancel(); generation += 1; let version = generation, start = offset; let term = search.stringValue, deleted = trash.state == .on; loading = true; controls()
        let work = DispatchWorkItem { [weak self] in guard let self else { return }; let result = Result { try self.service.campaignTemplates(search:term,offset:start,trash:deleted) }; DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == version else { return }
            switch result { case let .success(page): if page.rows.isEmpty && start > 0 { self.offset = max(0,(max(0,page.total-1)/100)*100); self.load(); return }; self.rows = page.rows; self.total = page.total
            case let .failure(error): self.rows = []; self.total = 0; self.message.stringValue = error.localizedDescription }
            self.table.reloadData(); self.loading = false; self.controls(); self.memory.settle()
        } }; pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func open(_ record: NativeRecord?) {
        guard !busy, !loading, window.attachedSheet == nil else { return }
        do { let full = try record.map{try service.campaignTemplate($0["id"].string)}; let e = try CampaignTemplateEditor(service:service,record:full,ai:campaignAI,allowsAI:allowsAI); editor = e; window.beginSheet(e.window) { [weak self] _ in self?.editor = nil; self?.load() } }
        catch { message.stringValue = error.localizedDescription; load() }
    }
    @objc private func create() { open(nil) }; @objc private func edit() { if trash.state != .on, let selected { open(selected) } }
    private func perform(_ work: @escaping () throws -> Void) {
        guard !busy && !loading else { return }; busy = true; controls(); queue.async { [weak self] in let result = Result { try work() }; DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false; switch result { case .success:self.message.stringValue = "保存しました。"; case let .failure(error):self.message.stringValue = error.localizedDescription }; self.load() } }
    }
    @objc private func remove() {
        guard let selected, window.attachedSheet == nil else { return }; let a = NSAlert(); a.messageText = "テンプレートを削除しますか？"; a.informativeText = selected["name"].string+"\n管理者は削除済みの一覧から復元できます。"; a.addButton(withTitle:"削除"); a.addButton(withTitle:"キャンセル")
        a.beginSheetModal(for:window) { [weak self] result in guard let self, result == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in try service.deleteCampaignTemplate(selected) } }
    }
    @objc private func restore() { guard let selected else { return }; perform { [service] in try service.restoreCampaignTemplate(selected) } }
    @objc private func refresh() { load() }; @objc private func filterChanged() { offset = 0; load() }
    @objc private func previous() { offset = max(0,offset-100); load() }; @objc private func next() { if offset+100 < total { offset += 100; load() } }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; pending?.cancel(); window.sheetParent?.endSheet(window) }
    func controlTextDidChange(_ notification: Notification) { offset = 0; load(delay:0.18) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { view,_ in view.subviews.forEach{$0.needsDisplay = true} } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { guard rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("template"); let cell = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id; cell.configure(columns:columns,values:rows[row].cells); return cell }
}
