import AppKit

/// Shared bounded list used once by the task browser and twice by the dashboard.
/// Native editors and their text engines exist only while a detail sheet is open.
final class CRMProjectTaskPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let view = NSStackView()
    weak var host: NSWindow?
    var query: ProjectTaskQuery
    var onChanged: (() -> Void)?
    private let service: CRMService; private let heading = NSTextField(labelWithString:"")
    private let search = NSSearchField(); private let status = NSPopUpButton(); private let priority = NSPopUpButton(); private let sort = NSPopUpButton()
    private let table = NSTableView(); private let count = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private var buttons: [String:NSButton] = [:]; private var rows: [ProjectTaskSummary] = []; private var offset = 0; private var total = 0; private var generation = 0
    private(set) var busy = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.task-pane"); private let memory = MemoryBudget(); private var pending: DispatchWorkItem?
    private var editor: CRMEditor?; private var picker: CRMReferencePicker?; private var comments: CRMProjectCommentsWindow?; private var project: CRMProjectWindow?
    private var notifications: CRMInvoiceJobsWindow?
    private var documents: CRMDocumentsWindow?
    init(title: String, query: ProjectTaskQuery, service: CRMService) {
        self.query = query; self.service = service; super.init()
        heading.stringValue = title; heading.font = .systemFont(ofSize:19,weight:.semibold)
        search.placeholderString = "タスクを検索"; search.setAccessibilityLabel(title+"を検索"); search.delegate = self
        status.addItems(withTitles:["状態すべて"]+CRMModule.projectStates.map(\.1)); status.setAccessibilityLabel(title+"の状態")
        priority.addItems(withTitles:["優先度すべて"]+CRMModule.projectPriorities.map(\.1)); priority.setAccessibilityLabel(title+"の優先度")
        sort.addItems(withTitles:ProjectTaskSort.allCases.flatMap { [$0.label+"・昇順",$0.label+"・降順"] }); sort.selectItem(at:(ProjectTaskSort.allCases.firstIndex(of:query.sort) ?? 0)*2+(query.descending ? 1 : 0)); sort.setAccessibilityLabel(title+"の並べ替え")
        for popup in [status,priority,sort] { popup.target = self; popup.action = #selector(filtersChanged) }
        let filters = NSStackView(views:[status,priority,sort,NSView()]); filters.spacing = 8
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.target = self; table.doubleAction = #selector(details); table.setAccessibilityLabel(title+"の一覧"); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("tasks")); column.width = 560; table.addTableColumn(column)
        let header = LightweightTableCell(); header.configure(columns:columns,values:CRMModule.projectTask.columns.map(\.label),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let actions = NSStackView(views:[button("detail","詳細・編集…",#selector(details)),button("done","完了",#selector(done)),button("active","未完了",#selector(active)),button("hold","保留",#selector(hold)),button("comments","コメント…",#selector(showComments)),NSView()]); actions.spacing = 8
        let more = NSStackView(views:[button("new","新規タスク…",#selector(newTask)),button("project","プロジェクト…",#selector(openProject)),button("delete","削除…",#selector(deleteTask)),button("notifications","通知状況…",#selector(showNotifications)),button("documents","文書…",#selector(showDocuments)),NSView(),button("refresh","更新",#selector(refresh))]); more.spacing = 8
        let footer = NSStackView(views:[count,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next))]); footer.spacing = 8
        message.font = .systemFont(ofSize:11); message.textColor = .secondaryLabelColor; count.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 10
        for child in [heading,search,filters,header,scroll,actions,more,message,footer] { view.addArrangedSubview(child); child.widthAnchor.constraint(equalTo:view.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:290).isActive = true
        controls()
    }
    private var columns: [NativeColumn] { CRMModule.projectTask.columns.map { NativeColumn(title:$0.label,fraction:$0.fraction) } }
    private var selected: ProjectTaskSummary? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func button(_ id: String, _ title: String, _ selector: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:selector); b.bezelStyle = .rounded; buttons[id] = b; return b }
    func rename(_ title: String) {
        heading.stringValue = title
        search.setAccessibilityLabel(title+"を検索"); status.setAccessibilityLabel(title+"の状態")
        priority.setAccessibilityLabel(title+"の優先度"); sort.setAccessibilityLabel(title+"の並べ替え")
        table.setAccessibilityLabel(title+"の一覧")
    }
    private func controls() {
        for b in buttons.values { b.isEnabled = !busy }
        buttons["detail"]?.isEnabled = !busy && selected != nil
        buttons["notifications"]?.isEnabled = !busy && selected != nil
        buttons["documents"]?.isEnabled = !busy && selected?.canReadComments == true
        buttons["delete"]?.isEnabled = !busy && selected?.canEdit == true
        buttons["comments"]?.isEnabled = !busy && selected?.canReadComments == true
        buttons["project"]?.isEnabled = !busy && selected?.boardID != nil
        for key in ["done","active","hold"] { buttons[key]?.isEnabled = !busy && selected?.canChangeStatus == true }
        buttons["previous"]?.isEnabled = !busy && offset > 0; buttons["next"]?.isEnabled = !busy && offset+100 < total
        count.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
        for popup in [status,priority,sort] { popup.isEnabled = !busy }; search.isEnabled = !busy; table.isEnabled = !busy
    }
    func reload(reset: Bool = false, delay: Double = 0, select: SQLValue? = nil) {
        if reset { offset = 0 }; pending?.cancel(); generation += 1
        let version = generation; let query = query; let start = offset
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let result = Result { try self.service.projectTaskPage(query,offset:start) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                switch result {
                case let .success(page):
                    if page.rows.isEmpty, start > 0 { self.offset = max(0,((page.total-1)/100)*100); self.reload(select:select); return }
                    self.rows = page.rows; self.total = page.total; self.table.reloadData()
                    if let select, let i = self.rows.firstIndex(where:{$0.record["id"] == select}) { self.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
                case let .failure(error): self.rows = []; self.total = 0; self.table.reloadData(); self.message.stringValue = error.localizedDescription
                }; self.controls()
            }
        }
        pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    @objc private func filtersChanged() {
        query.statuses = status.indexOfSelectedItem > 0 ? [CRMModule.projectStates[status.indexOfSelectedItem-1].0] : []
        query.priorities = priority.indexOfSelectedItem > 0 ? [CRMModule.projectPriorities[priority.indexOfSelectedItem-1].0] : []
        query.sort = ProjectTaskSort.allCases[sort.indexOfSelectedItem/2]; query.descending = sort.indexOfSelectedItem%2 == 1
        reload(reset:true)
    }
    func controlTextDidChange(_ notification: Notification) { query.search = search.stringValue; reload(reset:true,delay:0.18) }
    @objc private func previous() { offset = max(0,offset-100); reload() }; @objc private func next() { if offset+100 < total { offset += 100; reload() } }
    @objc private func refresh() { if let onChanged { onChanged() } else { reload() } }
    private func perform(_ action: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; controls(); let id = selected?.record["id"]
        queue.async { [weak self] in
            let result = Result { try action() }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false
                switch result { case .success: self.message.stringValue = "保存しました。"; self.onChanged?()
                case let .failure(error): self.message.stringValue = error.localizedDescription }
                self.controls(); self.reload(select:id); self.memory.settle()
            }
        }
    }
    private func edit(record: NativeRecord?, boardID: String? = nil, readOnly: Bool = false) {
        guard let host, host.attachedSheet == nil else { return }
        do {
            let editor = try CRMEditor(module:.projectTask,record:record,linkedTo:nil,service:service,referenceFilters:["user":.any(["admin","manager","user"].map { .equal("role",.text($0)) })],readOnly:readOnly,saveTitle:"保存",onSave:{ [service] input in
                if let record { _ = try service.saveProjectTask(sectionID:record["section"].string,original:record,input:input) }
                else if let boardID { _ = try service.createProjectTaskInBoard(boardID,input:input) }
                else { throw NativeDBError.message("作成先のプロジェクトを選択してください。") }
            }); self.editor = editor
            host.beginSheet(editor.window) { [weak self] response in guard let self else { return }; self.editor = nil; if response == .OK { self.onChanged?() }; self.reload(); self.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func details() {
        guard let selected else { return }
        openTask(selected.record["id"].string)
    }
    func openTask(_ id: String) {
        do { let current = try service.projectTaskOverview(id); edit(record:current.task,readOnly:!current.canEdit) }
        catch { message.stringValue = error.localizedDescription; reload() }
    }
    @objc private func showNotifications() {
        guard let selected, let host, host.attachedSheet == nil else { return }
        do {
            let controller = try CRMInvoiceJobsWindow(service:service,invoice:selected.record); notifications = controller
            host.beginSheet(controller.window) { [weak self] _ in self?.notifications = nil; self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showDocuments() {
        guard let selected, let host, host.attachedSheet == nil else { return }
        do {
            let controller = try CRMDocumentsWindow(service:service,linkedTo:selected.record); documents = controller
            host.beginSheet(controller.window) { [weak self] _ in self?.documents = nil; self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func newTask() {
        guard let host, host.attachedSheet == nil else { return }
        let picker = CRMReferencePicker(model:"Boards",service:service,matching:service.scope("Boards",write:true)) { [weak self] board in
            guard let self else { return }; self.picker = nil
            if let board { DispatchQueue.main.async { [weak self] in self?.edit(record:nil,boardID:board["id"].string) } }
        }; self.picker = picker; picker.window.title = "タスクを作成するプロジェクト"; host.beginSheet(picker.window); picker.start()
    }
    private func setStatus(_ status: String) { guard let selected else { return }; perform { [service] in _ = try service.setProjectTaskStatus(selected.record,status:status) } }
    @objc private func done() { setStatus("COMPLETE") }; @objc private func active() { setStatus("ACTIVE") }; @objc private func hold() { setStatus("PENDING") }
    @objc private func deleteTask() {
        guard let selected, let host, host.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "タスクを削除しますか？"; alert.informativeText = selected.record["title"].string+"\nコメントと文書への関連も削除されます。文書本体は残ります。この操作は元に戻せません。"; alert.addButton(withTitle:"削除"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:host) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in try service.deleteProjectTask(selected.record) } }
    }
    @objc private func showComments() {
        guard let selected, let host, host.attachedSheet == nil else { return }
        do {
            let current = try service.projectTaskOverview(selected.record["id"].string)
            guard current.canReadComments else { throw NativeDBError.message("コメントを表示する権限がありません。") }
            let comments = CRMProjectCommentsWindow(task:current.task,service:service); self.comments = comments
            host.beginSheet(comments.window) { [weak self] _ in guard let self else { return }; self.comments = nil; self.onChanged?(); self.reload(); self.memory.settle() }
        } catch { message.stringValue = error.localizedDescription; reload() }
    }
    @objc private func openProject() {
        guard let selected, let host, host.attachedSheet == nil else { return }
        do {
            guard let board = try service.projectTaskOverview(selected.record["id"].string).board else { throw NativeDBError.message("プロジェクトを表示する権限がありません。") }
            let project = CRMProjectWindow(project:board,service:service); self.project = project
            host.beginSheet(project.window) { [weak self] _ in guard let self else { return }; self.project = nil; self.onChanged?(); self.reload(); self.memory.settle() }
        } catch { message.stringValue = error.localizedDescription; reload() }
    }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && comments?.confirmDiscard() != false && project?.confirmDiscard() != false && notifications?.confirmDiscard() != false && documents?.confirmDiscard() != false }
    func stop() { pending?.cancel(); generation += 1 }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { view,_ in view.subviews.forEach { $0.needsDisplay = true } } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("task-overview")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id; cell.configure(columns:columns,values:rows[row].cells); return cell
    }
}

final class CRMTaskOverviewWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1120,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let pane: CRMProjectTaskPane
    private let mode = NSPopUpButton(); private let due = NSPopUpButton(); private let assignee = NSButton(title:"担当者を選択…",target:nil,action:nil)
    private var assignedID: String; private var picker: CRMReferencePicker?
    init(service: CRMService, mine: Bool) {
        self.service = service; assignedID = service.identity.id; pane = CRMProjectTaskPane(title:mine ? "自分の担当タスク" : "閲覧できるタスク",query:ProjectTaskQuery(scope:mine ? .assigned(service.identity.id) : .readable),service:service); super.init()
        window.title = "プロジェクトのタスク"; pane.host = window
        mode.addItems(withTitles:["閲覧できるタスク","担当タスク"]); mode.selectItem(at:mine ? 1 : 0); mode.target = self; mode.action = #selector(modeChanged); mode.setAccessibilityLabel("タスクの表示範囲")
        due.addItems(withTitles:ProjectTaskDue.allCases.map(\.label)); due.target = self; due.action = #selector(modeChanged); due.setAccessibilityLabel("期限で絞り込み")
        assignee.target = self; assignee.action = #selector(chooseAssignee); assignee.bezelStyle = .rounded; assignee.isHidden = !service.identity.elevated
        let scope = NSStackView(views:[mode,due,assignee,NSView()]); scope.spacing = 10
        let help = NSTextField(wrappingLabelWithString:"担当タスクでは自分の担当分を表示します。管理者は担当者を選べます。7日未満の一覧には、本日すでに期限を過ぎた未完了タスクも含まれます。"); help.font = .systemFont(ofSize:11); help.textColor = .secondaryLabelColor
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views:[NSView(),close]); layoutWindow(window,views:[scope,help,pane.view,footer])
        pane.reload()
    }
    @objc private func modeChanged() { pane.query.scope = mode.indexOfSelectedItem == 0 ? .readable : .assigned(assignedID); pane.query.due = ProjectTaskDue.allCases[due.indexOfSelectedItem]; pane.rename(mode.indexOfSelectedItem == 0 ? "閲覧できるタスク" : assignedID == service.identity.id ? "自分の担当タスク" : "選択した利用者の担当タスク"); pane.reload(reset:true) }
    @objc private func chooseAssignee() {
        guard window.attachedSheet == nil else { return }
        let picker = CRMReferencePicker(model:"Users",service:service,matching:.any(["admin","manager","user"].map { .equal("role",.text($0)) })) { [weak self] user in guard let self else { return }; self.picker = nil; if let user { self.assignedID = user["id"].string; self.assignee.title = CRMModule.displayName(user); self.mode.selectItem(at:1); self.modeChanged() } }
        self.picker = picker; picker.window.title = "担当タスクを表示する利用者"; window.beginSheet(picker.window); picker.start()
    }
    func confirmDiscard() -> Bool { pane.confirmDiscard() }
    func openTask(_ id: String) { pane.openTask(id) }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; pane.stop(); window.sheetParent?.endSheet(window) }
}

final class CRMProjectDashboardWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1220,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let overdue: CRMProjectTaskPane; private let week: CRMProjectTaskPane
    private let help = NSTextField(wrappingLabelWithString:"")
    init(service: CRMService) {
        self.service = service
        overdue = CRMProjectTaskPane(title:"期限超過",query:ProjectTaskQuery(scope:.deadlines,due:.overdue,sort:.dueDateAt,descending:false),service:service)
        week = CRMProjectTaskPane(title:"本日から7日未満",query:ProjectTaskQuery(scope:.deadlines,due:.week,sort:.dueDateAt,descending:false),service:service)
        super.init(); window.title = "プロジェクトのダッシュボード"; overdue.host = window; week.host = window
        let heading = NSTextField(labelWithString:"プロジェクトのダッシュボード"); heading.font = .systemFont(ofSize:23,weight:.semibold)
        help.font = .systemFont(ofSize:11); help.textColor = .secondaryLabelColor
        let columns = NSStackView(views:[overdue.view,week.view]); columns.alignment = .top; columns.distribution = .fillEqually; columns.spacing = 24
        overdue.view.heightAnchor.constraint(equalTo:columns.heightAnchor).isActive = true; week.view.heightAnchor.constraint(equalTo:columns.heightAnchor).isActive = true
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.keyEquivalent = "\u{1b}"; close.bezelStyle = .rounded
        let footer = NSStackView(views:[NSView(),close]); layoutWindow(window,views:[heading,help,columns,footer])
        overdue.onChanged = { [weak self] in self?.reload() }; week.onChanged = { [weak self] in self?.reload() }; reload()
    }
    private func reload() {
        let range = ProjectDeadlineRange(now:Date(),timeZone:.current); let format = DateFormatter(); format.locale = Locale(identifier:"ja_JP"); format.dateFormat = "M月d日"
        help.stringValue = (service.identity.elevated ? "全利用者の担当分。" : "自分の担当分。")+"完了済みは表示しません。右側は\(format.string(from:range.start))の開始後から\(format.string(from:range.end))の開始前まで。本日分は両方に表示される場合があります。"
        overdue.reload(); week.reload()
    }
    func confirmDiscard() -> Bool { overdue.confirmDiscard() && week.confirmDiscard() }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; overdue.stop(); week.stop(); window.sheetParent?.endSheet(window) }
}

private func layoutWindow(_ window: NSWindow, views: [NSView]) {
    let root = NSStackView(views:views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
    window.contentView!.addSubview(root)
    NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
    for view in views { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
}
