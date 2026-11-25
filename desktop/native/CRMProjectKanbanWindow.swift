import AppKit
import CoreText

private struct KanbanDrag: Codable {
    let token: String
    let task: String
    let revision: Int64
    let boardRevision: Int64
}

/// Card text is drawn by one reusable view per visible row, with native table
/// selection, keyboard focus and an accessible label for the whole card.
final class CRMKanbanCard: NSTableCellView {
    private var lines: [CTLine] = []
    private var label = ""
    override var isFlipped: Bool { true }
    func configure(_ row: CRMListRow) {
        let v = row.cells
        let title = v[0].isEmpty ? "無題" : v[0]
        let strings = [title,"担当："+v[1],"期限："+(v[2].isEmpty ? "未設定" : v[2]),v[3]+" ・ "+v[4]]
        label = strings.joined(separator:"、")
        lines = strings.enumerated().map { i,s in CTLineCreateWithAttributedString(NSAttributedString(string:s,attributes:[.font:NSFont.systemFont(ofSize:i == 0 ? 13 : 11,weight:i == 0 ? .semibold : .regular),NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true])) }
        toolTip = label; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let selected = (superview as? NSTableRowView)?.isSelected == true
        let emphasized = (superview as? NSTableRowView)?.isEmphasized == true
        let color: NSColor = selected && emphasized ? .alternateSelectedControlTextColor : .labelColor
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string:"…",attributes:[.font:NSFont.systemFont(ofSize:12),NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]))
        for (i,line) in lines.enumerated() {
            let r = NSRect(x:10,y:8+CGFloat(i)*19,width:max(0,bounds.width-20),height:20)
            c.saveGState(); c.clip(to:r); c.translateBy(x:r.minX,y:r.maxY-4); c.scaleBy(x:1,y:-1); c.textMatrix = .identity; c.textPosition = .zero; c.setFillColor(color.cgColor)
            CTLineDraw(CTLineCreateTruncatedLine(line,Double(r.width),.end,ellipsis) ?? line,c); c.restoreGState()
        }
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView { let row = table.row(for:self); guard row >= 0 else { return false }; table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.window?.makeFirstResponder(table); return true }
            ancestor = view.superview
        }
        return false
    }
}

final class CRMKanbanColumn: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let pasteboardType = NSPasteboard.PasteboardType("local.nextcrm.native.project-task")
    let view = NSStackView(); let table = NSTableView()
    let heading = NSTextField(labelWithString:""); let count = NSTextField(labelWithString:"")
    let add = NSButton(title:"タスクを追加",target:nil,action:nil)
    let details = NSButton(title:"詳細入力…",target:nil,action:nil)
    let rename = NSButton(title:"列名を変更…",target:nil,action:nil)
    let previous = NSButton(title:"前の100件",target:nil,action:nil); let next = NSButton(title:"次の100件",target:nil,action:nil)
    weak var owner: CRMProjectKanbanWindow?
    var data: ProjectKanbanColumn?
    init(owner: CRMProjectKanbanWindow) {
        self.owner = owner; super.init()
        heading.font = .systemFont(ofSize:16,weight:.semibold); heading.lineBreakMode = .byTruncatingTail
        count.font = .systemFont(ofSize:11); count.textColor = .secondaryLabelColor
        for (b,action) in [(add,#selector(newTask)),(details,#selector(newDetailedTask)),(rename,#selector(renameSection)),(previous,#selector(previousPage)),(next,#selector(nextPage))] { b.target = self; b.action = action; b.bezelStyle = .rounded }
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 94; table.intercellSpacing = NSSize(width:0,height:6); table.target = self; table.doubleAction = #selector(openTask)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("card")); column.width = 340; table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.registerForDraggedTypes([Self.pasteboardType]); table.setDraggingSourceOperationMask(.move,forLocal:true); table.setDraggingSourceOperationMask([],forLocal:false)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        let actions = NSStackView(views:[add,details,rename,NSView()]); let footer = NSStackView(views:[previous,NSView(),next])
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8
        for v in [heading,actions,scroll,count,footer] { view.addArrangedSubview(v); v.widthAnchor.constraint(equalTo:view.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350).isActive = true
    }
    func render(_ data: ProjectKanbanColumn?, writable: Bool, busy: Bool) {
        self.data = data; view.isHidden = data == nil
        heading.stringValue = data?["title"] ?? ""
        heading.toolTip = heading.stringValue; table.setAccessibilityLabel(heading.stringValue+"のタスク")
        table.reloadData(); controls(writable:writable,busy:busy)
    }
    func controls(writable: Bool, busy: Bool) {
        add.isEnabled = !busy && writable && data != nil; rename.isEnabled = add.isEnabled; details.isEnabled = add.isEnabled; table.isEnabled = !busy
        let total = data?.total ?? 0, offset = data?.offset ?? 0, n = data?.rows.count ?? 0
        count.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(total,offset+n)) ／ \(total)件"
        previous.isEnabled = !busy && offset > 0; next.isEnabled = !busy && offset+100 < total
    }
    @objc private func newTask() { if let data { owner?.quickAddTask(in:data.section) } }
    @objc private func newDetailedTask() { if let data { owner?.editTask(nil,in:data.section) } }
    @objc private func renameSection() { if let data { owner?.renameSection(data.section) } }
    @objc private func previousPage() { if let data { owner?.taskPage(data.section["id"].string,offset:max(0,data.offset-100)) } }
    @objc private func nextPage() { if let data { owner?.taskPage(data.section["id"].string,offset:data.offset+100) } }
    @objc private func openTask() { owner?.openSelected() }
    func numberOfRows(in tableView: NSTableView) -> Int { data?.rows.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) { owner?.select(self); table.enumerateAvailableRowViews { view,_ in view.subviews.forEach { $0.needsDisplay = true } } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let data, data.rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("kanban-card")
        let cell = table.makeView(withIdentifier:id,owner:self) as? CRMKanbanCard ?? CRMKanbanCard(); cell.identifier = id; cell.configure(data.rows[row]); return cell
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let data, data.rows.indices.contains(row), let payload = owner?.dragPayload(data.rows[row].record) else { return nil }
        let item = NSPasteboardItem(); item.setData(payload,forType:Self.pasteboardType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let payload = info.draggingPasteboard.data(forType:Self.pasteboardType), owner?.canDrop(payload,in:self,row:row) == true else { return [] }
        table.setDropRow(row,dropOperation:.above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let payload = info.draggingPasteboard.data(forType:Self.pasteboardType) else { return false }
        return owner?.drop(payload,in:self,row:row) ?? false
    }
}

private extension ProjectKanbanColumn { subscript(_ field: String) -> String { section[field].string } }

final class CRMProjectKanbanWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1160,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let boardID: String
    private let token = UUID().uuidString; private var snapshot: ProjectKanbanPage?
    private let heading = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private let count = NSTextField(labelWithString:""); private var buttons: [String:NSButton] = [:]
    private(set) var columns: [CRMKanbanColumn] = []
    private var editor: CRMEditor?; private var picker: CRMReferencePicker?; private var comments: CRMProjectCommentsWindow?; private var documents: CRMDocumentsWindow?
    private var busy = false; private var generation = 0; private var sectionOffset = 0; private var taskOffsets: [String:Int] = [:]; private var changingSelection = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.kanban"); private let memory = MemoryBudget()
    var changed = false
    init(project: NativeRecord, service: CRMService) {
        self.service = service; boardID = project["id"].string; super.init()
        window.title = "プロジェクトのカンバン"; heading.font = .systemFont(ofSize:22,weight:.semibold); message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        let navigation = NSStackView(views:[heading,NSView(),button("refresh","再読み込み",#selector(refresh)),button("newSection","列を追加…",#selector(newSection))])
        columns = (0..<3).map { _ in CRMKanbanColumn(owner:self) }
        let board = NSStackView(views:columns.map(\.view)); board.distribution = .fillEqually; board.alignment = .top; board.spacing = 14
        for c in columns { c.view.heightAnchor.constraint(equalTo:board.heightAnchor).isActive = true }
        let actions = NSStackView(views:[button("edit","表示・編集…",#selector(openSelected)),button("done","完了にする",#selector(complete)),button("active","未完了に戻す",#selector(reopen)),button("pending","保留にする",#selector(hold)),button("comments","コメント…",#selector(showComments)),button("documents","文書…",#selector(showDocuments)),button("move","移動…",#selector(move)),button("up","上へ",#selector(up)),button("down","下へ",#selector(down)),button("delete","削除…",#selector(deleteTask))]); actions.spacing = 6
        let help = NSTextField(wrappingLabelWithString:"カードをドラッグして並べ替え・列間移動できます。キーボードではカードを選び「上へ」「下へ」「移動…」を使えます。")
        help.font = .systemFont(ofSize:11); help.textColor = .secondaryLabelColor
        let footer = NSStackView(views:[count,NSView(),button("previous","前の3列",#selector(previous)),button("next","次の3列",#selector(next)),button("close","閉じる",#selector(close))]); buttons["close"]?.keyEquivalent = "\u{1b}"
        let root = NSStackView(views:[navigation,help,board,actions,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),board.heightAnchor.constraint(greaterThanOrEqualToConstant:470)])
        for v in [navigation,help,board,actions,message,footer] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        load()
    }
    private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private var selected: (task:NativeRecord,section:NativeRecord)? {
        for c in columns { if let data = c.data, data.rows.indices.contains(c.table.selectedRow) { return (data.rows[c.table.selectedRow].record,data.section) } }; return nil
    }
    func select(_ source: CRMKanbanColumn) {
        guard !changingSelection else { return }; changingSelection = true
        if source.table.selectedRow >= 0 { for c in columns where c !== source { c.table.deselectAll(nil) } }
        changingSelection = false; controls()
    }
    private func controls() {
        let writable = snapshot?.writable == true
        for b in buttons.values { b.isEnabled = !busy }
        buttons["newSection"]?.isEnabled = !busy && writable
        for id in ["edit","comments","documents"] { buttons[id]?.isEnabled = !busy && selected != nil }
        for id in ["move","up","down","delete"] { buttons[id]?.isEnabled = !busy && writable && selected != nil }
        let canStatus = writable || (service.identity.role == "user" && selected?.task["user"] == .text(service.identity.id))
        for id in ["done","active","pending"] { buttons[id]?.isEnabled = !busy && canStatus && selected != nil }
        buttons["previous"]?.isEnabled = !busy && sectionOffset > 0; buttons["next"]?.isEnabled = !busy && sectionOffset+3 < (snapshot?.totalSections ?? 0)
        for c in columns { c.controls(writable:writable,busy:busy) }
    }
    private func load(select: SQLValue? = nil) {
        generation += 1; let version = generation, offset = sectionOffset, offsets = taskOffsets; busy = true; controls()
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { try self.service.projectKanban(self.boardID,sectionOffset:offset,taskOffsets:offsets) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }; self.busy = false; self.changingSelection = true
                switch result {
                case let .success(page):
                    self.snapshot = page; self.sectionOffset = page.sectionOffset; self.heading.stringValue = page.project["title"].string
                    self.taskOffsets = Dictionary(uniqueKeysWithValues:page.columns.map { ($0.section["id"].string,$0.offset) })
                    for (i,c) in self.columns.enumerated() { c.render(page.columns.indices.contains(i) ? page.columns[i] : nil,writable:page.writable,busy:false); c.table.deselectAll(nil); if let select, let row = c.data?.rows.firstIndex(where:{$0.record["id"] == select}) { c.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) } }
                    self.count.stringValue = "\(page.totalSections == 0 ? 0 : page.sectionOffset+1)–\(page.sectionOffset+page.columns.count) ／ \(page.totalSections)列"
                case let .failure(error):
                    self.snapshot = nil; self.taskOffsets = [:]; self.count.stringValue = "表示できません"; self.message.stringValue = error.localizedDescription
                    self.columns.forEach { $0.render(nil,writable:false,busy:false) }
                }
                self.changingSelection = false; self.controls(); self.memory.settle()
            }
        }
    }
    private func perform(select: SQLValue? = nil, _ work: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; controls()
        queue.async { [weak self] in let result = Result { try work() }; DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.busy = false
            switch result { case .success: self.changed = true; self.message.stringValue = "保存しました。"; case let .failure(error): self.message.stringValue = error.localizedDescription }
            self.load(select:select)
        } }
    }
    func taskPage(_ id: String, offset: Int) { guard !busy else { return }; taskOffsets[id] = offset; load() }
    func dragPayload(_ task: NativeRecord) -> Data? {
        guard !busy, window.attachedSheet == nil, let snapshot, snapshot.writable else { return nil }
        return try? JSONEncoder().encode(KanbanDrag(token:token,task:task["id"].string,revision:task.revision,boardRevision:snapshot.project.revision))
    }
    private func draggedTask(_ payload: Data) -> NativeRecord? {
        guard payload.count < 2048, let d = try? JSONDecoder().decode(KanbanDrag.self,from:payload), d.token == token, d.boardRevision == snapshot?.project.revision else { return nil }
        return columns.compactMap(\.data).flatMap(\.rows).first { $0.record["id"].string == d.task && $0.record.revision == d.revision }?.record
    }
    func canDrop(_ payload: Data, in column: CRMKanbanColumn, row: Int) -> Bool {
        !busy && window.attachedSheet == nil && snapshot?.writable == true && columns.contains(where:{$0 === column}) && row >= 0 && row <= (column.data?.rows.count ?? -1) && draggedTask(payload) != nil
    }
    @discardableResult func drop(_ payload: Data, in column: CRMKanbanColumn, row: Int) -> Bool {
        guard canDrop(payload,in:column,row:row), let task = draggedTask(payload), let data = column.data, let snapshot else { return false }
        let anchor = row < data.rows.count ? data.rows[row].record : data.following
        perform(select:task["id"]) { [service] in _ = try service.placeProjectTask(task,in:data.section["id"].string,before:anchor,board:snapshot.project) }; return true
    }
    private func edit(_ module: CRMModule, record: NativeRecord?, readOnly: Bool = false, save: @escaping ([String:SQLValue]) throws -> Void) {
        guard !busy, window.attachedSheet == nil else { return }
        do { let c = try CRMEditor(module:module,record:record,linkedTo:nil,service:service,referenceFilters:["user":.any(["admin","manager","user"].map{.equal("role",.text($0))})],readOnly:readOnly,saveTitle:"保存",onSave:save); editor = c
            window.beginSheet(c.window) { [weak self] response in guard let self else { return }; self.editor = nil; if response == .OK { self.changed = true }; self.load(select:record?["id"]) }
        } catch { message.stringValue = error.localizedDescription }
    }
    func quickAddTask(in section: NativeRecord) {
        guard !busy, window.attachedSheet == nil, snapshot?.writable == true else { return }
        perform { [service,boardID] in _ = try service.quickAddProjectTask(boardID:boardID,section:section) }
    }
    func editTask(_ record: NativeRecord?, in section: NativeRecord) {
        do {
            let access = try record.map { try service.projectTaskOverview($0["id"].string) }
            edit(.projectTask,record:access?.task,readOnly:access.map{!$0.canEdit} ?? false) { [service] input in _ = try service.saveProjectTask(sectionID:section["id"].string,original:access?.task,input:input) }
        } catch { message.stringValue = error.localizedDescription }
    }
    func renameSection(_ section: NativeRecord) { edit(.projectSection,record:section) { [service,boardID] input in _ = try service.saveProjectSection(boardID:boardID,original:section,title:input["title"]?.string ?? "") } }
    @objc private func newSection() { edit(.projectSection,record:nil) { [service,boardID] input in _ = try service.saveProjectSection(boardID:boardID,original:nil,title:input["title"]?.string ?? "") } }
    @objc func openSelected() { if let selected { editTask(selected.task,in:selected.section) } }
    private func setStatus(_ status: String) { guard let selected else { return }; perform(select:selected.task["id"]) { [service] in _ = try service.setProjectTaskStatus(selected.task,status:status) } }
    @objc private func complete() { setStatus("COMPLETE") }; @objc private func reopen() { setStatus("ACTIVE") }; @objc private func hold() { setStatus("PENDING") }
    private func reorder(_ direction: Int) { guard let selected else { return }; perform(select:selected.task["id"]) { [service] in _ = try service.reorderProject(selected.task,direction:direction) } }
    @objc private func up() { reorder(-1) }; @objc private func down() { reorder(1) }
    @objc private func move() {
        guard let selected, !busy, window.attachedSheet == nil else { return }
        let p = CRMReferencePicker(model:"Sections",service:service,matching:.every([.equal("board",.text(boardID)),service.scope("Sections",write:true)])) { [weak self] destination in guard let self else { return }; self.picker = nil; if let destination { self.perform { [service = self.service] in _ = try service.moveProjectTask(selected.task,to:destination["id"].string) } } }
        picker = p; p.window.title = "移動先の列"; window.beginSheet(p.window); p.start()
    }
    @objc private func showComments() {
        guard let selected, window.attachedSheet == nil else { return }; let c = CRMProjectCommentsWindow(task:selected.task,service:service); comments = c
        window.beginSheet(c.window) { [weak self,weak c] _ in guard let self else { return }; self.changed = self.changed || c?.changed == true; self.comments = nil; self.load(select:selected.task["id"]) }
    }
    @objc private func showDocuments() {
        guard let selected, window.attachedSheet == nil else { return }; do { let c = try CRMDocumentsWindow(service:service,linkedTo:selected.task); documents = c; window.beginSheet(c.window) { [weak self] _ in self?.documents = nil; self?.load(select:selected.task["id"]) } } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func deleteTask() {
        guard let selected, window.attachedSheet == nil else { return }
        let a = NSAlert(); a.messageText = "タスクを削除しますか？"; a.informativeText = CRMModule.displayName(selected.task)+"\nコメントと文書への関連も削除されます。文書本体は残ります。この操作は元に戻せません。"; a.addButton(withTitle:"削除"); a.addButton(withTitle:"キャンセル")
        a.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in try service.deleteProjectTask(selected.task) } }
    }
    @objc private func refresh() { guard !busy else { return }; message.stringValue = ""; load(select:selected?.task["id"]) }
    @objc private func previous() { guard !busy else { return }; sectionOffset = max(0,sectionOffset-3); taskOffsets = [:]; load() }
    @objc private func next() { guard !busy else { return }; sectionOffset += 3; taskOffsets = [:]; load() }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && comments?.confirmDiscard() != false && documents?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; window.sheetParent?.endSheet(window) }
}
