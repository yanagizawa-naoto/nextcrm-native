import AppKit
import QuickLookUI
import UniformTypeIdentifiers

private final class DocumentCancellation {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

final class CRMDocumentsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1100,height:720),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let parent: NativeRecord?; private let historyRoot: NativeRecord?
    private let table = NSTableView(); private let search = NSSearchField(); private let type = NSPopUpButton(); private let processing = NSPopUpButton()
    private let favourites = NSButton(checkboxWithTitle:"お気に入りのみ",target:nil,action:nil)
    private let message = NSTextField(wrappingLabelWithString:""); private let count = NSTextField(labelWithString:""); private let storage = NSTextField(labelWithString:"")
    private var buttons: [String:NSButton] = [:]; private var rows: [NativeRecord] = []; private var total = 0; private var offset = 0; private var generation = 0
    private(set) var busy = false; private var loading = false; private var authorized = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.documents"); private let memory = MemoryBudget()
    private var pending: DispatchWorkItem?; private var cancellation: DocumentCancellation?; private var importTask: Task<Void,Never>?
    private var editor: CRMEditor?; private var picker: CRMReferencePicker?; private var history: CRMDocumentsWindow?; private var preview: CRMDocumentPreviewWindow?
    private var bodyWindow: CRMDocumentTextWindow?; private var observer: NSObjectProtocol?
    private var focusedID: String?
    private let columns = [NativeColumn(title:"文書名",fraction:0.34),NativeColumn(title:"区分",fraction:0.16),NativeColumn(title:"形式",fraction:0.18),NativeColumn(title:"サイズ",fraction:0.12),NativeColumn(title:"版",fraction:0.06),NativeColumn(title:"処理",fraction:0.14)]
    init(service: CRMService, linkedTo: NativeRecord? = nil, versionsOf: NativeRecord? = nil, focusedDocumentID: String? = nil) throws {
        try service.authenticated()
        if let linkedTo { try service.assertAccess(linkedTo.model,id:linkedTo["id"].string) }
        if let versionsOf { _ = try service.documentVersions(versionsOf["id"].string) }
        if let focusedDocumentID { try service.assertAccess("Documents", id: focusedDocumentID) }
        self.service = service; parent = linkedTo; historyRoot = versionsOf; focusedID = focusedDocumentID; super.init()
        window.title = versionsOf != nil ? "文書の版履歴" : linkedTo != nil ? "関連文書" : "文書"
        let heading = NSTextField(labelWithString:window.title); heading.font = .systemFont(ofSize:22,weight:.semibold)
        let context = NSTextField(wrappingLabelWithString:(versionsOf ?? linkedTo).map(CRMModule.displayName) ?? "ファイルをこのMacに保存します。1ファイル64MiBまで取り込めます。")
        context.textColor = .secondaryLabelColor
        search.placeholderString = "文書を検索"; search.setAccessibilityLabel("文書を検索"); search.delegate = self; search.widthAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        type.addItems(withTitles:["区分すべて"]+CRMModule.documentTypes.map(\.1)); type.setAccessibilityLabel("文書の区分")
        processing.addItems(withTitles:["処理状態すべて"]+CRMModule.documentProcessing.map(\.1)); processing.setAccessibilityLabel("文書の処理状態")
        for popup in [type,processing] { popup.target = self; popup.action = #selector(filterChanged) }; favourites.target = self; favourites.action = #selector(filterChanged)
        let filters = NSStackView(views:[search,type,processing,favourites]); filters.spacing = 8; filters.isHidden = versionsOf != nil
        let imports = NSStackView(views:[button("import","ファイルを取り込む…",#selector(chooseFiles)),button("attach","既存の文書を関連付ける…",#selector(attachExisting)),button("stop","取り込みを中止",#selector(cancelImport)),button("all","すべての文書",#selector(clearFocus)),NSView(),storage]); imports.spacing = 8; imports.isHidden = versionsOf != nil
        buttons["attach"]?.isHidden = linkedTo == nil
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.allowsMultipleSelection = versionsOf == nil
        table.target = self; table.doubleAction = #selector(details); table.setAccessibilityLabel(versionsOf == nil ? "文書の一覧" : "文書の版履歴の一覧")
        let column = NSTableColumn(identifier:.init("document")); column.width = 1040; table.addTableColumn(column)
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let actions = NSStackView(views:[button("detail","詳細・編集…",#selector(details)),button("preview","プレビュー…",#selector(showPreview)),button("export","書き出す…",#selector(exportFile)),button("version","新しい版を追加…",#selector(chooseVersion)),button("history","版履歴…",#selector(showHistory)),NSView()]); actions.spacing = 8
        let changes = NSStackView(views:[button("type","区分を変更…",#selector(changeType)),button("account","取引先に関連付ける…",#selector(linkAccount)),button("unlink","関連付けを解除…",#selector(unlink)),button("delete","文書を削除…",#selector(deleteSelected)),button("retry","再処理",#selector(reprocess)),NSView()]); changes.spacing = 8
        let extraction = NSStackView(views:[button("text","抽出した本文…",#selector(showText)),button("summary","AI要約…",#selector(showSummary)),NSView()]); extraction.spacing = 8
        buttons["unlink"]?.isHidden = linkedTo == nil; changes.isHidden = versionsOf != nil; buttons["version"]?.isHidden = versionsOf != nil; buttons["history"]?.isHidden = versionsOf != nil
        let footer = NSStackView(views:[count,NSView(),button("refresh","再読み込み",#selector(refresh)),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        message.textColor = .secondaryLabelColor; message.setAccessibilityLabel("文書の操作結果")
        message.maximumNumberOfLines = 3; message.lineBreakMode = .byTruncatingTail
        let root = NSStackView(views:[heading,context,filters,imports,header,scroll,actions,extraction,changes,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:250)])
        for view in [context,filters,imports,header,scroll,actions,extraction,changes,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.service.db.url.path, !self.busy, self.window.attachedSheet == nil else { return }; self.reload(select:self.selected.first?["id"])
        }
        reload(select: focusedDocumentID.map(SQLValue.text))
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func button(_ id: String, _ title: String, _ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private var selected: [NativeRecord] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    private var link: DocumentLink? { parent.map { DocumentLink(model:$0.model,id:$0["id"].string) } }
    private var writable: Bool { historyRoot == nil && ["admin","manager","user"].contains(service.identity.role) }
    private func controls() {
        let ready = !busy && !loading && authorized; let one = selected.count == 1
        for button in buttons.values { button.isEnabled = ready }
        buttons["refresh"]?.isEnabled = !busy && !loading; buttons["close"]?.isEnabled = !busy
        for id in ["detail","preview","export","text","summary"] { buttons[id]?.isEnabled = ready && one }
        buttons["retry"]?.isEnabled = ready && one && writable
        for id in ["version","history"] { buttons[id]?.isEnabled = ready && one && (id == "history" || writable) }
        for id in ["type","account","unlink","delete"] { buttons[id]?.isEnabled = ready && writable && !selected.isEmpty }
        let parentWritable = parent.map { (try? service.assertAccess($0.model,id:$0["id"].string,write:true)) != nil } ?? true
        let associationWritable: Bool
        if let parent, parent.model == "Tasks" { associationWritable = (try? service.projectDocumentTask(parent["id"].string)) != nil } else { associationWritable = parentWritable }
        buttons["import"]?.isEnabled = ready && writable && parentWritable; buttons["attach"]?.isEnabled = ready && writable && associationWritable; buttons["unlink"]?.isEnabled = ready && writable && associationWritable && !selected.isEmpty
        buttons["stop"]?.isEnabled = busy && cancellation != nil; buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        buttons["all"]?.isHidden = focusedID == nil
        buttons["detail"]?.title = writable ? "詳細・編集…" : "詳細…"
        for control in [search,type,processing,favourites] as [NSControl] { control.isEnabled = ready }; table.isEnabled = ready
        count.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
        message.toolTip = message.stringValue
    }
    func reload(select id: SQLValue? = nil, delay: Double = 0) {
        pending?.cancel(); generation += 1; let version = generation; let start = offset
        let query = DocumentQuery(search:search.stringValue,systemType:type.indexOfSelectedItem > 0 ? CRMModule.documentTypes[type.indexOfSelectedItem-1].0 : nil,
            processing:processing.indexOfSelectedItem > 0 ? CRMModule.documentProcessing[processing.indexOfSelectedItem-1].0 : nil,favourites:favourites.state == .on,linkedTo:link,id:focusedID)
        loading = true; controls()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let result = Result { () -> ([NativeRecord],Int,Int64) in
                let page = try self.historyRoot.map { try self.service.documentVersions($0["id"].string,offset:start) } ?? self.service.documentPage(query,offset:start)
                return (page.rows,page.total,try self.service.documentStorageBytes())
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }; self.loading = false
                switch result {
                case let .success((rows,total,bytes)):
                    self.authorized = true
                    if rows.isEmpty && start > 0 { self.offset = max(0,((total-1)/100)*100); self.reload(select:id); return }
                    self.rows = rows; self.total = total; self.storage.stringValue = "文書の合計："+Self.byteCount(bytes); self.table.reloadData()
                    if let id, let i = rows.firstIndex(where:{$0["id"] == id}) { self.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
                case let .failure(error): self.authorized = false; self.rows = []; self.total = 0; self.table.reloadData(); self.message.stringValue = error.localizedDescription
                }
                self.controls()
            }
        }
        pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func background<T>(_ action: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { completion in queue.async { completion.resume(with:Result { try autoreleasepool(invoking:action) }) } }
    }
    private func perform(_ action: @escaping () throws -> Void, success: String = "保存しました。") {
        guard !busy else { return }; busy = true; controls()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await background(action); message.stringValue = success } catch { message.stringValue = error.localizedDescription }
            busy = false; reload(); memory.settle()
        }
    }
    @objc private func chooseFiles() { presentFilePicker(replacing:nil) }
    @objc private func chooseVersion() { guard selected.count == 1 else { return }; presentFilePicker(replacing:selected[0]) }
    private func presentFilePicker(replacing: NativeRecord?) {
        guard !busy, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = replacing == nil; panel.prompt = replacing == nil ? "取り込む" : "版を追加"
        panel.beginSheetModal(for:window) { [weak self] response in if response == .OK { self?.importFiles(panel.urls,replacing:replacing) } }
    }
    func importFiles(_ urls: [URL], replacing: NativeRecord? = nil) {
        guard !busy, !urls.isEmpty else { return }; if replacing == nil { focusedID = nil }; busy = true; let cancel = DocumentCancellation(); cancellation = cancel; controls()
        let parentLink = link; let service = service
        importTask = Task { @MainActor [weak self] in
            guard let self else { return }; var imported = 0; var skipped = 0; var failed = 0; var errors: [String] = []; var lastID: SQLValue?
            for (index,url) in urls.enumerated() {
                if cancel.isCancelled { break }; message.stringValue = "\(index+1) ／ \(urls.count)件目を取り込み中："+url.lastPathComponent
                do {
                    let staged = try await background { try service.stageDocument(url,cancelled:{cancel.isCancelled}) }
                    if cancel.isCancelled { staged.discard(); break }
                    if replacing == nil, let duplicate = try await background({ try service.duplicateDocument(hash:staged.sha256) }) {
                        let alert = NSAlert(); alert.messageText = "同じ内容の文書が見つかりました"; alert.informativeText = CRMModule.displayName(duplicate)+"\n別の文書として取り込みますか？"
                        alert.addButton(withTitle:"別の文書として取り込む"); alert.addButton(withTitle:"スキップ"); alert.addButton(withTitle:"取り込みを中止")
                        let choice: NSApplication.ModalResponse = await withCheckedContinuation { continuation in alert.beginSheetModal(for:self.window) { continuation.resume(returning:$0) } }
                        if choice != .alertFirstButtonReturn { staged.discard(); if choice == .alertThirdButtonReturn { cancel.cancel(); break }; skipped += 1; continue }
                    }
                    let saved = try await background { try service.commitDocument(staged,replacing:replacing,linkedTo:replacing == nil ? parentLink : nil) }
                    imported += 1; lastID = saved["id"]
                } catch { if cancel.isCancelled { break }; failed += 1; if errors.count < 3 { errors.append(url.lastPathComponent+"："+error.localizedDescription) } }
            }
            message.stringValue = "\(imported)件を取り込み、\(skipped)件をスキップしました。"+(cancel.isCancelled ? "取り込みを中止しました。" : "")+(failed > 0 ? "\n\(failed)件で問題がありました。\n"+errors.joined(separator:"\n") : "")
            cancellation = nil; importTask = nil; busy = false; offset = 0; reload(select:lastID); memory.settle()
        }
    }
    @objc private func cancelImport() { cancellation?.cancel(); message.stringValue = "現在のファイルの取り込みを中止しています…" }
    @objc private func details() {
        guard !busy, window.attachedSheet == nil, selected.count == 1 else { return }
        do {
            let record = try service.documentRecord(selected[0]["id"].string)
            let controller = try CRMEditor(module:.documents,record:record,linkedTo:nil,service:service,referenceFilters:["assigned_user":.any(["admin","manager","user"].map { .equal("role",.text($0)) })],readOnly:!writable,onSave:{ [service] values in _ = try service.updateDocument(record,changes:values) })
            editor = controller; window.beginSheet(controller.window) { [weak self] _ in self?.editor = nil; self?.reload(select:record["id"]); self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showHistory() {
        guard window.attachedSheet == nil, selected.count == 1 else { return }
        do { let controller = try CRMDocumentsWindow(service:service,versionsOf:selected[0]); history = controller; window.beginSheet(controller.window) { [weak self] _ in self?.history = nil; self?.memory.settle() } }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showText() { showBody(summary: false) }
    @objc private func showSummary() { showBody(summary: true) }
    private func showBody(summary: Bool) {
        guard !busy, window.attachedSheet == nil, selected.count == 1 else { return }
        do {
            let controller = try CRMDocumentTextWindow(service:service,document:selected[0],showSummary:summary); bodyWindow = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.bodyWindow = nil; self?.memory.settle() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func reprocess() {
        guard !busy, window.attachedSheet == nil, selected.count == 1 else { return }; let row = selected[0]
        perform({ try self.service.retryDocumentProcessing(row) },success:"文書の再処理を予約しました。")
    }
    @objc private func showPreview() {
        guard !busy, window.attachedSheet == nil, selected.count == 1 else { return }; let row = selected[0]; busy = true; controls()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await background { try self.service.documentFile(row["id"].string) }
                let controller = CRMDocumentPreviewWindow(url:url,title:row["document_name"].string); preview = controller
                window.beginSheet(controller.window) { [weak self] _ in self?.preview?.releasePreview(); self?.preview = nil; self?.memory.settle() }
            } catch { message.stringValue = error.localizedDescription }
            busy = false; controls()
        }
    }
    @objc private func exportFile() {
        guard !busy, window.attachedSheet == nil, selected.count == 1 else { return }; let row = selected[0]
        let panel = NSSavePanel(); panel.title = "文書を書き出す"; panel.nameFieldStringValue = row["document_name"].string
        if let contentType = UTType(mimeType:row["document_file_mimeType"].string), let ext = contentType.preferredFilenameExtension {
            panel.allowedContentTypes = [contentType]; panel.nameFieldStringValue = (row["document_name"].string as NSString).deletingPathExtension+"."+ext
        }
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.perform({ try self.service.exportDocument(row["id"].string,to:url,replace:true) },success:"文書を書き出しました。")
        }
    }
    @objc private func attachExisting() {
        guard !busy, !loading, let link, window.attachedSheet == nil else { return }
        do {
            let task = link.model == "Tasks" ? try service.projectDocumentTask(link.id) : nil
            let controller = CRMReferencePicker(model:"Documents",service:service,matching:.equal("parent_document_id",.null)) { [weak self] record in
                guard let self else { return }; self.picker = nil
                if let record { self.perform {
                    if let task { _ = try self.service.setProjectTaskDocumentLink(record,task:task,linked:true) }
                    else { try self.service.setDocumentLink(record,to:link,linked:true) }
                } }
            }
            picker = controller; window.beginSheet(controller.window); controller.start()
        } catch { message.stringValue = error.localizedDescription; controls() }
    }
    @objc private func linkAccount() {
        guard window.attachedSheet == nil, !selected.isEmpty else { return }; let rows = selected
        let controller = CRMReferencePicker(model:"crm_Accounts",service:service,matching:service.scope("crm_Accounts",write:true)) { [weak self] account in
            guard let self else { return }; self.picker = nil
            if let account { self.perform { try self.service.db.transaction { for row in rows { try self.service.setDocumentLink(row,to:DocumentLink(model:"crm_Accounts",id:account["id"].string),linked:true) } } } }
        }
        picker = controller; window.beginSheet(controller.window); controller.start()
    }
    @objc private func changeType() {
        guard window.attachedSheet == nil, !selected.isEmpty else { return }; let rows = selected; let alert = NSAlert(); alert.messageText = "\(rows.count)件の文書の区分を変更しますか？"
        let choice = NSPopUpButton(frame:NSRect(x:0,y:0,width:260,height:28)); choice.addItems(withTitles:CRMModule.documentTypes.map(\.1)); choice.setAccessibilityLabel("変更後の文書区分"); alert.accessoryView = choice
        alert.addButton(withTitle:"変更"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; let type = CRMModule.documentTypes[choice.indexOfSelectedItem].0; self.perform { try self.service.changeDocumentTypes(rows,systemType:type) } }
    }
    @objc private func unlink() {
        guard !busy, !loading, let link, window.attachedSheet == nil, !selected.isEmpty else { return }; let rows = selected
        do {
            let task = link.model == "Tasks" ? try service.projectDocumentTask(link.id) : nil
            confirm("\(rows.count)件の文書の関連付けを解除しますか？",details:"文書そのものは残ります。") { [service] in
                try service.db.transaction {
                    var currentTask = task
                    for row in rows {
                        if let expected = currentTask { currentTask = try service.setProjectTaskDocumentLink(row,task:expected,linked:false) }
                        else { try service.setDocumentLink(row,to:link,linked:false) }
                    }
                }
            }
        } catch { message.stringValue = error.localizedDescription; controls() }
    }
    @objc private func deleteSelected() {
        guard window.attachedSheet == nil, !selected.isEmpty else { return }; let rows = selected
        confirm("\(rows.count)件の文書を削除しますか？",details:"保存したすべての版と関連付けも削除されます。元の取り込み元ファイルは残ります。この操作は取り消せません。") { [service] in try service.deleteDocuments(rows) }
    }
    private func confirm(_ title: String, details: String, action: @escaping () throws -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = details; alert.addButton(withTitle:"実行"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in if response == .alertFirstButtonReturn { self?.perform(action) } }
    }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && history?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; pending?.cancel(); generation += 1; window.sheetParent?.endSheet(window) }
    @objc private func refresh() { reload() }
    @objc private func clearFocus() { focusedID = nil; offset = 0; reload() }
    @objc private func filterChanged() { focusedID = nil; offset = 0; reload() }
    @objc private func previous() { offset = max(0,offset-100); reload() }
    @objc private func next() { if offset+100 < total { offset += 100; reload() } }
    func controlTextDidChange(_ notification: Notification) { focusedID = nil; offset = 0; reload(delay:0.18) }
    func tableViewSelectionDidChange(_ notification: Notification) { controls() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    private static func byteCount(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount:value,countStyle:.file) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]; let id = NSUserInterfaceItemIdentifier("document-row")
        let cell = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        cell.configure(columns:columns,values:[item["document_name"].string,CRMModule.documentTypes.first { $0.0 == item["document_system_type"].string }?.1 ?? "未設定",item["document_file_mimeType"].string,Self.byteCount(Int64(item["size"].string) ?? 0),item["version"].string,CRMModule.documentProcessing.first { $0.0 == item["processing_status"].string }?.1 ?? "未設定"]); return cell
    }
}

private final class CRMDocumentPreviewWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:900,height:680),styleMask:[.titled],backing:.buffered,defer:false)
    private let preview = QLPreviewView(frame:.zero,style:.normal)!
    private var released = false
    init(url: URL, title: String) {
        super.init(); window.title = title; preview.autostarts = false; preview.shouldCloseWithWindow = false; preview.previewItem = url as NSURL
        preview.setAccessibilityLabel("文書のプレビュー")
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views:[NSView(),close]); let root = NSStackView(views:[preview,footer]); root.orientation = .vertical; root.spacing = 8; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root); NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:12),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-12),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:12),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-12),preview.widthAnchor.constraint(equalTo:root.widthAnchor),footer.widthAnchor.constraint(equalTo:root.widthAnchor)])
    }
    func releasePreview() { if !released { preview.close(); released = true } }
    deinit { releasePreview() }
    @objc private func close() { releasePreview(); window.sheetParent?.endSheet(window) }
}

final class CRMDocumentTextWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:900,height:680),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let id: String
    private let text = NSTextView(); private let info = NSTextField(wrappingLabelWithString:""); private let image = NSImageView()
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private let mode = NSSegmentedControl(labels:["本文","AI要約"],trackingMode:.selectOne,target:nil,action:nil)
    private var part = 0; private var total = 0
    init(service: CRMService, document: NativeRecord, showSummary: Bool = false) throws {
        self.service = service; id = document["id"].string; super.init(); _ = try service.documentTextMetadata(id)
        window.title = "抽出した本文"; text.isEditable = false; text.isRichText = false; text.font = .systemFont(ofSize:14); text.textContainerInset = NSSize(width:12,height:12)
        text.setAccessibilityLabel("文書の本文"); text.isVerticallyResizable = true; text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        info.maximumNumberOfLines = 4; info.lineBreakMode = .byTruncatingTail; info.setAccessibilityLabel("文書の処理情報")
        mode.selectedSegment = showSummary ? 1 : 0; mode.target = self; mode.action = #selector(changeMode); mode.setAccessibilityLabel("文書の表示内容")
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        image.imageScaling = .scaleProportionallyDown; image.setAccessibilityLabel("文書の縮小画像"); image.widthAnchor.constraint(equalToConstant:120).isActive = true; image.heightAnchor.constraint(equalToConstant:120).isActive = true
        let heading = NSStackView(views:[info,image]); heading.spacing = 12
        previous.target = self; previous.action = #selector(back); next.target = self; next.action = #selector(forward)
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.keyEquivalent = "\u{1b}"
        let refresh = NSButton(title:"再読み込み",target:self,action:#selector(refresh))
        let footer = NSStackView(views:[refresh,NSView(),previous,next,close]); footer.spacing = 8
        let root = NSStackView(views:[heading,mode,scroll,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350)])
        for view in [heading,scroll,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        load()
    }
    private func load() {
        do {
            let record = try service.documentTextMetadata(id)
            let page = try service.documentExtractedText(id,part:part,thumbnail:true); total = page.parts
            let summary = mode.selectedSegment == 1
            text.string = summary ? (record["summary"] == .null || record["summary"].string.isEmpty ? "AI要約はまだ作成されていません。AI連携の設定と、AI検索の処理画面を確認してください。" : record["summary"].string) : page.text
            text.setAccessibilityLabel(summary ? "文書のAI要約" : "文書の本文")
            text.scrollRangeToVisible(NSRange(location:0,length:0)); image.image = page.thumbnail.flatMap(NSImage.init(data:)); image.isHidden = image.image == nil
            let state = CRMModule.documentProcessing.first { $0.0 == record["processing_status"].string }?.1 ?? "未設定"
            let category = CRMModule.documentTypes.first { $0.0 == record["document_system_type"].string }?.1 ?? "未設定"
            info.stringValue = record["document_name"].string+" — "+state+" ／ "+category+"\n"+(summary ? "AIによる要約です。内容は原文と照合してください。" : page.ready ? (total == 0 ? "抽出した本文はありません。" : "本文 \(part+1) ／ \(total)（分割表示）") : "本文はまだ抽出されていません。")+"\n"+page.note+(record["processing_error"] == .null ? "" : "\n"+record["processing_error"].string)
            info.toolTip = info.stringValue; previous.isEnabled = !summary && part > 0; next.isEnabled = !summary && part+1 < total
        } catch { text.string = ""; image.image = nil; image.isHidden = true; info.stringValue = error.localizedDescription; previous.isEnabled = false; next.isEnabled = false }
    }
    @objc private func back() { part = max(0,part-1); load() }
    @objc private func forward() { if part+1 < total { part += 1; load() } }
    @objc private func changeMode() { load() }
    @objc private func refresh() { load() }
    @objc private func close() { text.string = ""; image.image = nil; window.sheetParent?.endSheet(window) }
}
