import AppKit

final class CRMAccountTasksWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1100,height:740),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let parent: NativeRecord?
    private let table = NSTableView(); private let search = NSSearchField()
    private let status = NSPopUpButton(); private let priority = NSPopUpButton(); private let sort = NSPopUpButton()
    private let mine = NSButton(checkboxWithTitle:"自分の担当のみ",target:nil,action:nil)
    private let message = NSTextField(wrappingLabelWithString:""); private let count = NSTextField(labelWithString:"")
    private var query = CRMTaskQuery(); private var rows: [CRMTaskSummary] = []; private var total = 0; private var offset = 0
    private var busy = false; private var loading = false; private var generation = 0; private var pending: DispatchWorkItem?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.crm-tasks"); private let memory = MemoryBudget()
    private var buttons: [String:NSButton] = [:]
    private var notifications: CRMInvoiceJobsWindow?
    private var editor: CRMEditor?; private var picker: CRMReferencePicker?; private var comments: CRMProjectCommentsWindow?; private var documents: CRMDocumentsWindow?
    init(service: CRMService, parent: NativeRecord? = nil) throws {
        self.service = service; self.parent = parent
        if let parent {
            guard ["crm_Accounts","crm_Opportunities"].contains(parent.model) else { throw NativeDBError.message("タスクの関連先が不正です。") }
            try service.assertAccess(parent.model,id:parent["id"].string)
            query.parent = CRMTaskParent(model:parent.model,id:parent["id"].string)
        } else { try service.authenticated() }
        super.init(); window.title = "CRMタスク"
        let heading = NSTextField(labelWithString:parent.map { CRMModule.displayName($0)+"のタスク" } ?? "CRMタスク"); heading.font = .systemFont(ofSize:23,weight:.semibold); heading.maximumNumberOfLines = 1; heading.lineBreakMode = .byTruncatingTail
        search.placeholderString = "タスク名・内容を検索"; search.setAccessibilityLabel("CRMタスクを検索"); search.delegate = self
        status.addItems(withTitles:["状態すべて"]+CRMModule.projectStates.map(\.1)); status.setAccessibilityLabel("CRMタスクの状態")
        priority.addItems(withTitles:["優先度すべて"]+CRMModule.crmTaskPriorities.map(\.1)); priority.setAccessibilityLabel("CRMタスクの優先度")
        sort.addItems(withTitles:CRMTaskSort.allCases.flatMap {["\($0.label)・昇順","\($0.label)・降順"]}); sort.selectItem(at:1); sort.setAccessibilityLabel("CRMタスクの並べ替え")
        for popup in [status,priority,sort] { popup.target = self; popup.action = #selector(filtersChanged) }
        mine.target = self; mine.action = #selector(filtersChanged)
        let filters = NSStackView(views:[status,priority,sort,mine,NSView()]); filters.spacing = 10
        let header = LightweightTableCell(); header.configure(columns:columns,values:CRMModule.crmTask.columns.map(\.label),heading:true); header.heightAnchor.constraint(equalToConstant:24).isActive = true
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 40; table.setAccessibilityLabel("CRMタスクの一覧"); table.target = self; table.doubleAction = #selector(details)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("crm-task")); column.width = 1040; table.addTableColumn(column)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let actions = NSStackView(views:[button("detail","詳細・編集…",#selector(details)),button("comments","コメント…",#selector(showComments)),button("documents","文書…",#selector(showDocuments)),button("done","完了にする",#selector(done)),button("active","未完了に戻す",#selector(active)),button("hold","保留にする",#selector(hold)),button("delete","削除…",#selector(deleteTask)),NSView()]); actions.spacing = 8
        let createAccount = button("newAccount",parent == nil ? "取引先にタスクを作成…" : "新規タスク…",#selector(newAccountTask))
        let createOpportunity = button("newOpportunity","商談にタスクを作成…",#selector(newOpportunityTask)); createOpportunity.isHidden = parent != nil
        let more = NSStackView(views:[createAccount,createOpportunity,NSView(),button("notifications","通知状況…",#selector(showNotifications)),button("refresh","再読み込み",#selector(refresh))]); more.spacing = 10
        message.font = .systemFont(ofSize:11); message.textColor = .secondaryLabelColor; message.maximumNumberOfLines = 3; message.lineBreakMode = .byTruncatingTail; message.setAccessibilityLabel("CRMタスクの操作結果")
        count.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        let close = button("close","閉じる",#selector(close)); close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views:[count,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),close]); footer.spacing = 10
        let root = NSStackView(views:[heading,search,filters,header,scroll,actions,more,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        controls(); reload()
    }
    private var columns: [NativeColumn] { CRMModule.crmTask.columns.map { NativeColumn(title:$0.label,fraction:$0.fraction) } }
    private var selected: CRMTaskSummary? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private func controls() {
        let ready = !busy && !loading
        for button in buttons.values { button.isEnabled = ready }
        for id in ["detail","comments","documents","notifications"] { buttons[id]?.isEnabled = ready && selected != nil }
        for id in ["done","active","hold"] { buttons[id]?.isEnabled = ready && selected?.canEdit == true }
        buttons["delete"]?.isEnabled = ready && selected?.canDelete == true
        if let parent { buttons["newAccount"]?.isEnabled = ready && (try? service.assertAccess(parent.model,id:parent["id"].string,write:true)) != nil }
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        count.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
        table.isEnabled = ready; search.isEnabled = !busy; mine.isEnabled = !busy
        for popup in [status,priority,sort] { popup.isEnabled = !busy }
    }
    private func reload(reset: Bool = false, delay: Double = 0, select: SQLValue? = nil) {
        if reset { offset = 0 }; pending?.cancel(); generation += 1; let version = generation; let query = query; let start = offset
        // Keep row actions disabled until their post-save revisions arrive.
        // Search remains usable so type-ahead can replace an in-flight load.
        loading = true; controls()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; let result = Result { try self.service.crmTaskPage(query,offset:start) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                switch result {
                case let .success(page):
                    if page.rows.isEmpty && start > 0 { self.offset = max(0,((page.total-1)/100)*100); self.reload(select:select); return }
                    self.rows = page.rows; self.total = page.total; self.table.reloadData()
                    if let select, let i = self.rows.firstIndex(where:{$0.record["id"] == select}) { self.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
                case let .failure(error): self.rows = []; self.total = 0; self.table.reloadData(); self.message.stringValue = error.localizedDescription
                }; self.loading = false; self.controls()
            }
        }; pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    @objc private func filtersChanged() {
        query.status = status.indexOfSelectedItem > 0 ? CRMModule.projectStates[status.indexOfSelectedItem-1].0 : nil
        query.priority = priority.indexOfSelectedItem > 0 ? CRMModule.crmTaskPriorities[priority.indexOfSelectedItem-1].0 : nil
        query.sort = CRMTaskSort.allCases[sort.indexOfSelectedItem/2]; query.descending = sort.indexOfSelectedItem%2 == 1
        query.assigneeID = mine.state == .on ? service.identity.id : nil; reload(reset:true)
    }
    func controlTextDidChange(_ notification: Notification) { query.search = search.stringValue; reload(reset:true,delay:0.18) }
    @objc private func refresh() { reload() }
    @objc private func previous() { offset = max(0,offset-100); reload() }
    @objc private func next() { if offset+100 < total { offset += 100; reload() } }
    private func perform(_ action: @escaping () throws -> Void) {
        guard !busy && !loading else { return }; busy = true; generation += 1; pending?.cancel(); controls(); let selectedID = selected?.record["id"]
        queue.async { [weak self] in
            let result = Result { try action() }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false
                switch result { case .success: self.message.stringValue = "保存しました。"; case let .failure(error): self.message.stringValue = error.localizedDescription }
                self.controls(); self.reload(select:selectedID); self.memory.settle()
            }
        }
    }
    private func edit(_ record: NativeRecord?, parent: CRMTaskParent? = nil, readOnly: Bool = false) {
        guard window.attachedSheet == nil else { return }
        do {
            let filter: RecordFilter = service.identity.role == "partner" ? .equal("id",.text(service.identity.id)) : .any(["admin","manager","user","partner"].map{.equal("role",.text($0))})
            let editor = try CRMEditor(module:.crmTask,record:record,linkedTo:nil,service:service,referenceFilters:["user":filter],readOnly:readOnly,saveTitle:record == nil ? "作成" : "保存",onSave:{ [service] input in _ = try service.saveCRMTask(parent:parent,original:record,input:input) }); self.editor = editor
            window.beginSheet(editor.window) { [weak self] _ in self?.editor = nil; self?.reload(); self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func details() { guard let selected else { return }; openTask(selected.record["id"].string) }
    func openTask(_ id: String) {
        do { let access = try service.crmTaskAccess(id); edit(access.task,readOnly:!access.canEdit) }
        catch { message.stringValue = error.localizedDescription; reload() }
    }
    private func create(in model: String) {
        guard window.attachedSheet == nil else { return }
        if let parent { edit(nil,parent:CRMTaskParent(model:parent.model,id:parent["id"].string)); return }
        let picker = CRMReferencePicker(model:model,service:service,matching:service.scope(model,write:true)) { [weak self] row in
            guard let self else { return }; self.picker = nil
            if let row { DispatchQueue.main.async { [weak self] in self?.edit(nil,parent:CRMTaskParent(model:model,id:row["id"].string)) } }
        }; self.picker = picker; picker.window.title = "タスクを作成する"+(model == "crm_Accounts" ? "取引先" : "商談"); window.beginSheet(picker.window); picker.start()
    }
    @objc private func newAccountTask() { create(in:"crm_Accounts") }
    @objc private func newOpportunityTask() { create(in:"crm_Opportunities") }
    private func setStatus(_ value: String) { guard let selected else { return }; perform { [service] in _ = try service.setCRMTaskStatus(selected.record,status:value) } }
    @objc private func done() { setStatus("COMPLETE") }; @objc private func active() { setStatus("ACTIVE") }; @objc private func hold() { setStatus("PENDING") }
    @objc private func showNotifications() {
        guard let selected,window.attachedSheet == nil else { return }
        do {
            let controller = try CRMInvoiceJobsWindow(service:service,invoice:selected.record); notifications = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.notifications = nil; self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showComments() {
        guard let selected, window.attachedSheet == nil else { return }
        do { let access = try service.crmTaskAccess(selected.record["id"].string); let controller = CRMProjectCommentsWindow(task:access.task,service:service); comments = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.comments = nil; self?.reload(); self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showDocuments() {
        guard let selected, window.attachedSheet == nil else { return }
        do { let controller = try CRMDocumentsWindow(service:service,linkedTo:service.crmTaskAccess(selected.record["id"].string).task); documents = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.documents = nil; self?.reload(); self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func deleteTask() {
        guard let selected, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "タスクを削除しますか？"; alert.informativeText = selected.record["title"].string+"\nコメントと文書への関連も削除されます。文書本体は残ります。この操作は元に戻せません。"; alert.addButton(withTitle:"削除"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in try service.deleteCRMTask(selected.record) } }
    }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && comments?.confirmDiscard() != false && documents?.confirmDiscard() != false && notifications?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil,confirmDiscard() else { return }; pending?.cancel(); generation += 1; window.sheetParent?.endSheet(window) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { view,_ in view.subviews.forEach{$0.needsDisplay = true} } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("crm-task-row")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id; cell.configure(columns:columns,values:rows[row].cells); return cell
    }
}
