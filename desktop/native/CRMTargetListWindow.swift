import AppKit

final class CRMTargetListWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let listID: String
    private let mode = NSPopUpButton(); private let search = NSSearchField(); private let table = NSTableView()
    private let count = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private let apply = NSButton(title:"選択した対象を解除",target:nil,action:nil)
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private let all = NSButton(title:"検索結果をすべて選択",target:nil,action:nil); private let clear = NSButton(title:"選択解除",target:nil,action:nil)
    private let close = NSButton(title:"閉じる",target:nil,action:nil)
    private var rows: [NativeRecord] = []; private var selectedIDs = Set<String>()
    private var offset = 0; private var total = 0; private var version = 0; private var applyingSelection = false; private var busy = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.target-list")
    private var pending: DispatchWorkItem?
    var changed = false
    init(list: NativeRecord, service: CRMService) {
        self.service = service; listID = list["id"].string; super.init()
        window.title = "対象リストのメンバー"
        let heading = NSTextField(labelWithString:CRMModule.displayName(list)); heading.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(labelWithString:"⌘キーで複数選択できます。リストから解除しても営業対象の情報は残ります。"); help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        mode.addItems(withTitles:["登録済み","追加候補"]); mode.target = self; mode.action = #selector(modeChanged); mode.setAccessibilityLabel("メンバーの表示")
        search.placeholderString = "氏名・会社名・メールで検索"; search.delegate = self; search.setAccessibilityLabel("対象リスト内を検索"); search.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let toolbar = NSStackView(views:[mode,search]); toolbar.spacing = 10
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.allowsMultipleSelection = true; table.setAccessibilityLabel("対象リストの営業対象")
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("targets")); column.width = 830; table.addTableColumn(column)
        let header = LightweightTableCell(); header.configure(columns:columns,values:["氏名","会社名","メール","配信"],heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        previous.target = self; previous.action = #selector(back); next.target = self; next.action = #selector(forward)
        all.target = self; all.action = #selector(selectAllMatching); clear.target = self; clear.action = #selector(clearSelection)
        apply.target = self; apply.action = #selector(applySelection); close.target = self; close.action = #selector(closeWindow); close.keyEquivalent = "\u{1b}"
        for button in [previous,next,all,clear,apply,close] { button.bezelStyle = .rounded }
        count.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular); message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        let paging = NSStackView(views:[count,NSView(),previous,next]); paging.spacing = 10
        let buttons = NSStackView(views:[all,clear,NSView(),apply,close]); buttons.spacing = 10
        let root = NSStackView(views:[heading,help,toolbar,header,scroll,paging,message,buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350)])
        for view in [toolbar,header,scroll,paging,message,buttons] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        load()
    }
    private var columns: [NativeColumn] { [NativeColumn(title:"氏名",fraction:0.23),NativeColumn(title:"会社名",fraction:0.25),NativeColumn(title:"メール",fraction:0.38),NativeColumn(title:"配信",fraction:0.14)] }
    private var candidates: Bool { mode.indexOfSelectedItem == 1 }
    private func controls() {
        count.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+100,total)) ／ \(total)件　\(selectedIDs.count)件選択"
        previous.isEnabled = !busy && offset > 0; next.isEnabled = !busy && offset+100 < total
        apply.title = candidates ? "選択した対象を追加" : "選択した対象を解除"; apply.isEnabled = !busy && !selectedIDs.isEmpty
        mode.isEnabled = !busy; search.isEnabled = !busy; table.isEnabled = !busy; close.isEnabled = !busy; all.isEnabled = !busy && total > 0; clear.isEnabled = !busy && !selectedIDs.isEmpty
    }
    private func load(delay: Double = 0) {
        pending?.cancel(); version += 1; let generation = version; let term = search.stringValue; let candidates = candidates; let offset = offset
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let page = try self.service.targetListPage(self.listID,candidates:candidates,search:term,offset:offset)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.version == generation else { return }
                    if page.rows.isEmpty, offset > 0 { self.offset = max(0,((page.total-1)/100)*100); self.load(); return }
                    self.rows = page.rows; self.total = page.total; self.refreshSelection(); self.controls()
                }
            } catch { DispatchQueue.main.async { [weak self] in guard let self, self.version == generation else { return }; self.rows = []; self.total = 0; self.refreshSelection(); self.message.stringValue = error.localizedDescription; self.controls() } }
        }
        pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func refreshSelection() {
        applyingSelection = true; defer { applyingSelection = false }
        table.reloadData(); table.selectRowIndexes(IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0]["id"].string) }),byExtendingSelection:false)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        for row in rows { selectedIDs.remove(row["id"].string) }
        for index in table.selectedRowIndexes where rows.indices.contains(index) { selectedIDs.insert(rows[index]["id"].string) }
        controls(); table.enumerateAvailableRowViews { view,_ in view.subviews.forEach { $0.needsDisplay = true } }
    }
    func controlTextDidChange(_ notification: Notification) { offset = 0; load(delay:0.18) }
    @objc private func modeChanged() { selectedIDs.removeAll(); offset = 0; search.stringValue = ""; message.stringValue = ""; controls(); load() }
    @objc private func back() { offset = max(0,offset-100); load() }
    @objc private func forward() { if offset+100 < total { offset += 100; load() } }
    @objc private func clearSelection() { selectedIDs.removeAll(); refreshSelection(); controls() }
    @objc private func selectAllMatching() {
        let term = search.stringValue; let candidates = candidates; busy = true; controls()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.service.allTargetListIDs(self.listID,candidates:candidates,search:term) }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false
                switch result { case let .success(ids): self.selectedIDs.formUnion(ids); self.refreshSelection()
                case let .failure(error): self.message.stringValue = error.localizedDescription }; self.controls()
            }
        }
    }
    @objc private func applySelection() {
        guard !selectedIDs.isEmpty else { return }; let ids = Array(selectedIDs); let adding = candidates; busy = true; controls()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { adding ? try self.service.addTargets(ids,to:self.listID) : try self.service.removeTargets(ids,from:self.listID) }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false
                switch result {
                case let .success(count): self.changed = self.changed || count > 0; self.selectedIDs.removeAll(); self.message.stringValue = "\(count)件を\(adding ? "追加" : "解除")しました。"; self.offset = 0
                case let .failure(error): self.message.stringValue = error.localizedDescription
                }; self.controls(); self.load()
            }
        }
    }
    @objc private func closeWindow() { guard !busy else { return }; pending?.cancel(); window.sheetParent?.endSheet(window) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row]; let id = NSUserInterfaceItemIdentifier("target-member")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        cell.configure(columns:columns,values:[CRMModule.displayName(record),record["company"].string,record["email"].string,record["do_not_email"] == .integer(1) ? "停止" : "許可"]); return cell
    }
    func confirmDiscard()->Bool {!busy && window.attachedSheet == nil}

    #if RESTORE_PARENT_TESTING
    func addForTesting(_ ids:[String]){mode.selectItem(at:1);selectedIDs=Set(ids);applySelection()}
    var busyForTesting:Bool {busy}
    #endif

}
