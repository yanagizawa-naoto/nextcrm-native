import AppKit

final class CRMProjectWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1120,height:740),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService
    private var project: NativeRecord; private var section: NativeRecord?
    private var editor: CRMEditor?; private var picker: CRMReferencePicker?; private var comments: CRMProjectCommentsWindow?
    private var notifications: CRMInvoiceJobsWindow?
    private var documents: CRMDocumentsWindow?
    private var kanban: CRMProjectKanbanWindow?
    private let heading = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private let sectionButton = NSButton(); private let watch = NSButton(); private let search = NSSearchField(); private let status = NSPopUpButton()
    private let table = NSTableView(); private let count = NSTextField(labelWithString:"")
    private var buttons: [String:NSButton] = [:]; private var rows: [CRMListRow] = []
    private var total = 0; private var offset = 0; private var generation = 0; private var busy = false; private var writable = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.projects"); private let memory = MemoryBudget()
    private var pending: DispatchWorkItem?
    var changed = false
    init(project: NativeRecord, service: CRMService) {
        self.project = project; self.service = service; super.init()
        window.title = "プロジェクト"; heading.font = .systemFont(ofSize:22,weight:.semibold)
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize:12)
        sectionButton.target = self; sectionButton.action = #selector(chooseSection); sectionButton.bezelStyle = .rounded
        watch.target = self; watch.action = #selector(toggleWatch); watch.bezelStyle = .rounded
        let projectActions = NSStackView(views:[button("settings","設定…",#selector(settings)),button("share","共有先を追加…",#selector(share)),button("unshare","共有を解除…",#selector(unshare)),watch,button("notifications","通知状況…",#selector(showNotifications)),button("documents","選択タスクの文書…",#selector(showDocuments)),NSView()])
        let sections = NSStackView(views:[sectionButton,button("newSection","セクションを追加…",#selector(newSection)),button("renameSection","名前を変更…",#selector(renameSection)),button("sectionUp","セクションを前へ",#selector(sectionUp)),button("sectionDown","セクションを後へ",#selector(sectionDown)),button("deleteSection","セクションを削除…",#selector(deleteSection)),NSView()])
        search.placeholderString = "タスクを検索"; search.setAccessibilityLabel("プロジェクトのタスクを検索"); search.delegate = self; search.setContentHuggingPriority(.defaultLow,for:.horizontal)
        status.addItems(withTitles:["すべての状態"]+CRMModule.projectStates.map(\.1)); status.target = self; status.action = #selector(filterChanged); status.setAccessibilityLabel("タスクの状態")
        let filters = NSStackView(views:[search,status,button("kanban","カンバン…",#selector(showKanban)),button("newTask","タスクを追加…",#selector(newTask))])
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.target = self; table.doubleAction = #selector(editTask); table.setAccessibilityLabel("プロジェクトのタスク")
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("tasks")); column.width = 1070; table.addTableColumn(column)
        let header = LightweightTableCell(); header.configure(columns:columns,values:CRMModule.projectTask.columns.map(\.label),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let taskActions = NSStackView(views:[button("edit","表示・編集…",#selector(editTask)),button("done","完了にする",#selector(complete)),button("active","未完了に戻す",#selector(reopen)),button("pending","保留にする",#selector(hold)),button("comments","コメント…",#selector(showComments)),button("move","移動…",#selector(move)),button("up","上へ",#selector(up)),button("down","下へ",#selector(down)),button("delete","削除…",#selector(deleteTask))])
        let footer = NSStackView(views:[count,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); buttons["close"]?.keyEquivalent = "\u{1b}"
        let root = NSStackView(views:[heading,projectActions,sections,filters,header,scroll,taskActions,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:340)])
        for view in [projectActions,sections,filters,header,scroll,taskActions,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        for stack in [projectActions,sections,filters,taskActions,footer] { stack.spacing = 8 }
        load()
    }
    private var columns: [NativeColumn] { CRMModule.projectTask.columns.map { NativeColumn(title:$0.label,fraction:$0.fraction) } }
    private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].record : nil }
    private func controls() {
        for b in buttons.values { b.isEnabled = !busy }
        for id in ["share","unshare","newSection"] { buttons[id]?.isEnabled = !busy && writable }
        buttons["settings"]?.title = writable ? "設定…" : "プロジェクトの詳細…"
        for id in ["renameSection","deleteSection","sectionUp","sectionDown","newTask"] { buttons[id]?.isEnabled = !busy && writable && section != nil }
        for id in ["move","up","down","delete"] { buttons[id]?.isEnabled = !busy && writable && selected != nil }
        for id in ["edit","comments"] { buttons[id]?.isEnabled = !busy && selected != nil }
        buttons["documents"]?.isEnabled = !busy && selected != nil
        let statusAllowed = writable || (service.identity.role == "user" && selected?["user"] == .text(service.identity.id))
        for id in ["done","active","pending"] { buttons[id]?.isEnabled = !busy && selected != nil && statusAllowed }
        buttons["previous"]?.isEnabled = !busy && offset > 0; buttons["next"]?.isEnabled = !busy && offset+100 < total
        sectionButton.isEnabled = !busy; watch.isEnabled = !busy; status.isEnabled = !busy; search.isEnabled = !busy; table.isEnabled = !busy
        count.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
    }
    private func load(delay: Double = 0, select: SQLValue? = nil) {
        pending?.cancel(); generation += 1; let version = generation; let original = project; let sectionID = section?["id"].string; let term = search.stringValue; let start = offset
        let state = status.indexOfSelectedItem > 0 ? CRMModule.projectStates[status.indexOfSelectedItem-1].0 : nil
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let project = try self.service.fullRecord(original)
                let section: NativeRecord?
                if let sectionID, let existing = try self.service.db.get("Sections",key:["id":.text(sectionID)]), existing["board"] == project["id"] { section = existing }
                else { section = try self.service.projectSections(project["id"].string).rows.first }
                let page = try section.map { try self.service.projectTasks(sectionID:$0["id"].string,search:term,status:state,offset:start) } ?? (rows:[],total:0)
                let watched = try self.service.projectIsWatched(project["id"].string)
                let writable = (try? self.service.assertAccess("Boards",id:project["id"].string,write:true)) != nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == version else { return }
                    self.project = project; self.section = section; self.writable = writable
                    if page.rows.isEmpty, start > 0 { self.offset = max(0,((page.total-1)/100)*100); self.load(select:select); return }
                    self.heading.stringValue = CRMModule.displayName(project); self.sectionButton.title = (section.map(CRMModule.displayName) ?? "セクションなし")+" ▾"
                    self.watch.title = watched ? "ウォッチ解除" : "ウォッチする"; self.rows = page.rows; self.total = page.total; self.table.reloadData()
                    if let select, let i = self.rows.firstIndex(where:{$0.record["id"] == select}) { self.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
                    self.controls()
                }
            } catch { DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }; self.rows = []; self.total = 0; self.writable = false; self.table.reloadData(); self.message.stringValue = error.localizedDescription; self.controls() } }
        }
        pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func perform(_ work: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; controls(); let selection = selected?["id"]
        queue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false
                switch result { case .success: self.changed = true; self.message.stringValue = "保存しました。"
                case let .failure(error): self.message.stringValue = error.localizedDescription }
                self.controls(); self.load(select:selection); self.memory.settle()
            }
        }
    }
    private func edit(_ module: CRMModule, record: NativeRecord?, readOnly: Bool = false, save: @escaping ([String:SQLValue]) throws -> Void) {
        guard window.attachedSheet == nil else { return }
        do {
            let controller = try CRMEditor(module:module,record:record,linkedTo:nil,service:service,referenceFilters:["user":.any(["admin","manager","user"].map { .equal("role",.text($0)) })],readOnly:readOnly,saveTitle:"保存",onSave:save); editor = controller
            window.beginSheet(controller.window) { [weak self] response in guard let self else { return }; self.editor = nil; if response == .OK { self.changed = true }; self.load(); self.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    private func choose(_ model: String, title: String, matching: RecordFilter, completion: @escaping (NativeRecord) -> Void) {
        guard window.attachedSheet == nil else { return }
        let p = CRMReferencePicker(model:model,service:service,matching:matching) { [weak self] record in guard let self else { return }; self.picker = nil; if let record { completion(record) }; self.memory.settle() }
        picker = p; p.window.title = title; window.beginSheet(p.window); p.start()
    }
    @objc private func settings() { let project = project; edit(.projects,record:project,readOnly:!writable) { [service] input in _ = try service.saveProject(original:project,input:input) } }
    @objc private func share() { let project = project; choose("Users",title:"共有先を追加",matching:.any(["admin","manager","user"].map { .equal("role",.text($0)) })) { [weak self] user in guard let self else { return }; self.perform { [service = self.service] in _ = try service.setProjectShared(project,userID:user["id"].string,shared:true) } } }
    @objc private func unshare() {
        do { let project = project; let ids = try JSONDecoder().decode([String].self,from:Data(project["sharedWith"].string.utf8)).filter { $0 != project["user"].string }
            choose("Users",title:"共有を解除する利用者",matching:.any(ids.map { .equal("id",.text($0)) })) { [weak self] user in guard let self else { return }; self.perform { [service = self.service] in _ = try service.setProjectShared(project,userID:user["id"].string,shared:false) } }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func toggleWatch() { let id = project["id"].string; perform { [service] in try service.watchProject(id,enabled: !service.projectIsWatched(id)) } }
    @objc private func chooseSection() { choose("Sections",title:"セクションを表示",matching:.equal("board",project["id"])) { [weak self] section in self?.section = section; self?.offset = 0; self?.load() } }
    @objc private func newSection() { let id = project["id"].string; edit(.projectSection,record:nil) { [weak self,service] input in let result = try service.saveProjectSection(boardID:id,original:nil,title:input["title"]?.string ?? ""); self?.section = result; self?.offset = 0 } }
    @objc private func renameSection() { guard let section else { return }; let id = project["id"].string; edit(.projectSection,record:section) { [service] input in _ = try service.saveProjectSection(boardID:id,original:section,title:input["title"]?.string ?? "") } }
    @objc private func newTask() { guard let section else { return }; offset = 0; edit(.projectTask,record:nil) { [service] input in _ = try service.saveProjectTask(sectionID:section["id"].string,original:nil,input:input) } }
    @objc private func editTask() { do { guard let selected else { return }; let task = try service.fullRecord(selected); edit(.projectTask,record:task,readOnly:!writable) { [service] input in _ = try service.saveProjectTask(sectionID:task["section"].string,original:task,input:input) } } catch { message.stringValue = error.localizedDescription } }
    private func changeStatus(_ value: String) { guard let task = selected else { return }; perform { [service] in _ = try service.setProjectTaskStatus(task,status:value) } }
    @objc private func complete() { changeStatus("COMPLETE") }; @objc private func reopen() { changeStatus("ACTIVE") }; @objc private func hold() { changeStatus("PENDING") }
    @objc private func move() { guard let task = selected else { return }; choose("Sections",title:"移動先のセクション",matching:.every([.equal("board",project["id"]),service.scope("Sections",write:true)])) { [weak self] section in guard let self else { return }; self.perform { [service = self.service] in _ = try service.moveProjectTask(task,to:section["id"].string) } } }
    private func reorder(_ record: NativeRecord?, _ direction: Int) { guard let record else { return }; perform { [service] in _ = try service.reorderProject(record,direction:direction) } }
    @objc private func up() { reorder(selected,-1) }; @objc private func down() { reorder(selected,1) }
    @objc private func sectionUp() { reorder(section,-1) }; @objc private func sectionDown() { reorder(section,1) }
    private func confirmDeletion(_ record: NativeRecord, section: Bool) {
        let alert = NSAlert(); alert.messageText = section ? "セクションと中のタスクを削除しますか？" : "タスクを削除しますか？"
        alert.informativeText = CRMModule.displayName(record)+"\nコメントと添付文書への関連も削除されます。文書本体は残ります。この操作は元に戻せません。"; alert.addButton(withTitle:"削除"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] result in guard let self, result == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in if section { try service.deleteProjectSection(record) } else { try service.deleteProjectTask(record) } } }
    }
    @objc private func deleteTask() { if let selected { confirmDeletion(selected,section:false) } }
    @objc private func deleteSection() { if let section { confirmDeletion(section,section:true) } }
    @objc private func showComments() { guard let selected, window.attachedSheet == nil else { return }; let c = CRMProjectCommentsWindow(task:selected,service:service); comments = c; window.beginSheet(c.window) { [weak self,weak c] _ in guard let self else { return }; self.changed = self.changed || c?.changed == true; self.comments = nil; self.load(); self.memory.settle() } }
    @objc private func showNotifications() {
        guard window.attachedSheet == nil else { return }
        do {
            let controller = try CRMInvoiceJobsWindow(service:service,invoice:project); notifications = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.notifications = nil }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showDocuments() {
        guard window.attachedSheet == nil, let selected else { return }
        do {
            let controller = try CRMDocumentsWindow(service:service,linkedTo:selected); documents = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.documents = nil; self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showKanban() {
        guard window.attachedSheet == nil else { return }
        let c = CRMProjectKanbanWindow(project:project,service:service); kanban = c
        window.beginSheet(c.window) { [weak self,weak c] _ in guard let self else { return }; self.changed = self.changed || c?.changed == true; self.kanban = nil; self.load(); self.memory.settle() }
    }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && comments?.confirmDiscard() != false && notifications?.confirmDiscard() != false && documents?.confirmDiscard() != false && kanban?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; pending?.cancel(); generation += 1; window.sheetParent?.endSheet(window) }
    @objc private func filterChanged() { offset = 0; load() }; @objc private func previous() { offset = max(0,offset-100); load() }; @objc private func next() { if offset+100 < total { offset += 100; load() } }
    func controlTextDidChange(_ notification: Notification) { offset = 0; load(delay:0.18) }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { view,_ in view.subviews.forEach { $0.needsDisplay = true } } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("project-task")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id; cell.configure(columns:columns,values:rows[row].cells); return cell
    }
}

final class CRMProjectCommentsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:820,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    private let task: NativeRecord; private let service: CRMService
    private let table = NSTableView(); private let body = NSTextView(); private let info = NSTextField(labelWithString:"")
    private let count = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private let add = NSButton(title:"コメントを追加…",target:nil,action:nil)
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private var editor: CRMEditor?; private var rows: [NativeRecord] = []; private var names: [String:String] = [:]; private var total = 0; private var offset = 0
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.project-comments"); private var generation = 0
    var changed = false
    init(task: NativeRecord, service: CRMService) {
        self.task = task; self.service = service; super.init(); window.title = "タスクのコメント"
        let heading = NSTextField(labelWithString:CRMModule.displayName(task)); heading.font = .systemFont(ofSize:20,weight:.semibold)
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.setAccessibilityLabel("タスクのコメント一覧")
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("comment")); column.width = 760; table.addTableColumn(column)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        body.isEditable = false; body.isRichText = false; body.font = .systemFont(ofSize:13); body.isVerticallyResizable = true; body.isHorizontallyResizable = false; body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true; body.setAccessibilityLabel("コメントの全文")
        let detail = NSScrollView(); detail.documentView = body; detail.hasVerticalScroller = true; detail.borderType = .bezelBorder
        add.target = self; add.action = #selector(addComment); previous.target = self; previous.action = #selector(back); next.target = self; next.action = #selector(forward)
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.keyEquivalent = "\u{1b}"
        for b in [add,previous,next,close] { b.bezelStyle = .rounded }
        let footer = NSStackView(views:[count,NSView(),previous,next,add,close]); footer.spacing = 8
        let root = NSStackView(views:[heading,scroll,info,detail,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:260),detail.heightAnchor.constraint(equalToConstant:180)])
        for view in [scroll,info,detail,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        load()
    }
    private func load() {
        generation += 1; let version = generation; let start = offset
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let page = try self.task.model == "crm_Accounts_Tasks" ? self.service.crmTaskComments(taskID:self.task["id"].string,offset:start) : self.service.projectComments(taskID:self.task["id"].string,offset:start)
                var names: [String:String] = [:]
                for row in page.rows where names[row["user"].string] == nil { names[row["user"].string] = try self.service.referenceName("Users",id:row["user"].string) }
                let writable = (try? self.service.assertAccess(self.task.model,id:self.task["id"].string,write:true)) != nil
                DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }; self.rows = page.rows; self.total = page.total; self.names = names; self.table.reloadData(); self.body.string = ""; self.info.stringValue = ""
                    self.count.stringValue = "\(page.total == 0 ? 0 : start+1)–\(min(start+page.rows.count,page.total)) ／ \(page.total)件"; self.previous.isEnabled = start > 0; self.next.isEnabled = start+100 < page.total; self.add.isEnabled = writable
                    if !self.rows.isEmpty { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
                }
            } catch { DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }; self.rows = []; self.table.reloadData(); self.body.string = ""; self.info.stringValue = ""; self.add.isEnabled = false; self.message.stringValue = error.localizedDescription } }
        }
    }
    @objc private func addComment() {
        guard window.attachedSheet == nil else { return }
        do { let editor = try CRMEditor(module:.projectComment,record:nil,linkedTo:nil,service:service,saveTitle:"投稿",onSave:{ [service,task] input in if task.model == "crm_Accounts_Tasks" { _ = try service.addCRMTaskComment(taskID:task["id"].string,comment:input["comment"]?.string ?? "") } else { _ = try service.addProjectComment(taskID:task["id"].string,comment:input["comment"]?.string ?? "") } }); self.editor = editor
            window.beginSheet(editor.window) { [weak self] result in guard let self else { return }; self.editor = nil; self.changed = self.changed || result == .OK; self.offset = 0; self.load() }
        } catch { message.stringValue = error.localizedDescription }
    }
    func confirmDiscard() -> Bool { editor?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; window.sheetParent?.endSheet(window) }
    @objc private func back() { offset = max(0,offset-100); load() }; @objc private func forward() { if offset+100 < total { offset += 100; load() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow) else { body.string = ""; info.stringValue = ""; return }
        let row = rows[table.selectedRow]; body.string = row["comment"].string
        let date = ISO8601DateFormatter().date(from:row["createdAt"].string)
        let format = DateFormatter(); format.locale = Locale(identifier:"ja_JP"); format.dateStyle = .medium; format.timeStyle = .short
        info.stringValue = (names[row["user"].string] ?? "")+"　"+(date.map(format.string) ?? row["createdAt"].string)
        table.enumerateAvailableRowViews { view,_ in view.subviews.forEach { $0.needsDisplay = true } }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]; let id = NSUserInterfaceItemIdentifier("project-comment")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        cell.configure(columns:[NativeColumn(title:"コメント",fraction:0.75),NativeColumn(title:"投稿者",fraction:0.25)],values:[String(item["comment"].string.prefix(200)).replacingOccurrences(of:"\n",with:" "),names[item["user"].string] ?? ""]); return cell
    }
}
