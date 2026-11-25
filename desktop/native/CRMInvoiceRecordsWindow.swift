import AppKit

/// Bounded pages for invoice settings, payments and activity. Mutations use domain services.
final class CRMInvoiceRecordsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:850,height:640),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let module: CRMModule
    private let fetch: (String,Int) throws -> (rows:[NativeRecord],total:Int)
    private let save: ((NativeRecord?,[String:SQLValue]) throws -> Void)?
    private let remove: ((NativeRecord) throws -> Void)?
    private let initial: (() throws -> NativeRecord)?; private let editExisting: Bool
    var canCreate: (() -> Bool)?
    private let search = NSSearchField(); private let table = NSTableView()
    private let count = NSTextField(labelWithString:""); private let message = NSTextField(wrappingLabelWithString:"")
    private let add = NSButton(title:"追加…",target:nil,action:nil); private let edit = NSButton(title:"詳細…",target:nil,action:nil); private let delete = NSButton(title:"削除",target:nil,action:nil)
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private var rows: [NativeRecord] = []; private var cells: [[String]] = []; private var offset = 0; private var total = 0
    private var editor: CRMEditor?
    init(service: CRMService, module: CRMModule, searchable: Bool = true, initial: (() throws -> NativeRecord)? = nil, editExisting: Bool = true, fetch: @escaping (String,Int) throws -> (rows:[NativeRecord],total:Int), save: ((NativeRecord?,[String:SQLValue]) throws -> Void)? = nil, remove: ((NativeRecord) throws -> Void)? = nil) {
        self.service = service; self.module = module; self.fetch = fetch; self.save = save; self.remove = remove; self.initial = initial; self.editExisting = editExisting
        super.init(); window.title = module.title
        let title = NSTextField(labelWithString:module.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        search.placeholderString = "検索"; search.setAccessibilityLabel(module.title+"を検索"); search.delegate = self; search.isHidden = !searchable
        let header = LightweightTableCell(); header.configure(columns:columns,values:module.columns.map(\.label),heading:true); header.heightAnchor.constraint(equalToConstant:24).isActive = true; header.horizontalInset = 16
        table.headerView = nil; table.dataSource = self; table.delegate = self; table.rowHeight = 36; table.style = .inset; table.target = self; table.doubleAction = #selector(openSelected); table.setAccessibilityLabel(module.title)
        let col = NSTableColumn(identifier:.init("row")); col.width = 790; table.addTableColumn(col)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        for (b,action) in [(add,#selector(create)),(edit,#selector(openSelected)),(delete,#selector(deleteSelected)),(previous,#selector(page(_:))),(next,#selector(page(_:)))] { b.target = self; b.action = action; b.bezelStyle = .rounded }
        previous.tag = -1; next.tag = 1; add.isHidden = save == nil; delete.isHidden = remove == nil
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views:[add,edit,delete,NSView(),count,previous,next,close]); buttons.spacing = 10
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize:12)
        let root = NSStackView(views:[title,search,header,scroll,message,buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350)])
        for view in [search,header,scroll,message,buttons] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
    }
    private var columns: [NativeColumn] { module.columns.map { .init(title:$0.label,fraction:$0.fraction) } }
    func start() {
        do {
            var page = try fetch(search.stringValue,offset)
            if page.rows.isEmpty && offset > 0 { offset = max(0,(max(1,page.total)-1)/100*100); page = try fetch(search.stringValue,offset) }
            rows = page.rows; total = page.total
            cells = try rows.map { row in try module.columns.map { col in
                if let target = col.relation { return try service.referenceName(target,id:row[col.fields[0]].string) }
                return col.fields.map { key in
                    let value = row[key]; if value == .null { return "—" }
                    if key == "active" { return value == .integer(1) ? "有効" : "無効" }
                    if key == "paidAt" { return String(value.string.prefix(10)).replacingOccurrences(of:"-",with:"/") }
                    if key == "createdAt" { let f = DateFormatter(); f.locale = .init(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"; let p = ISO8601DateFormatter(); return p.date(from:value.string).map(f.string) ?? value.string }
                    return CRMModule.invoiceLabel(value.string)
                }.joined(separator:" ")
            } }
            table.reloadData(); count.stringValue = "\(total == 0 ? 0 : offset+1)–\(offset+rows.count) ／ \(total)件"; previous.isEnabled = offset > 0; next.isEnabled = offset+100 < total; add.isEnabled = canCreate?() ?? (save != nil); message.stringValue = ""; updateSelection()
        } catch { message.stringValue = error.localizedDescription }
    }
    func confirmDiscard() -> Bool { editor?.confirmDiscard() != false }
    @objc private func close() { if window.attachedSheet == nil && confirmDiscard() { window.sheetParent?.endSheet(window) } }
    func controlTextDidChange(_ notification: Notification) { offset = 0; start() }
    @objc private func page(_ sender: NSButton) { offset = max(0,offset+sender.tag*100); start() }
    @objc private func create() { if save != nil && canCreate?() != false { open(nil) } }
    @objc private func openSelected() { if rows.indices.contains(table.selectedRow) { open(rows[table.selectedRow]) } }
    private func open(_ record: NativeRecord?) {
        guard editor == nil, window.attachedSheet == nil else { return }
        do {
            let readOnly = record != nil && (save == nil || !editExisting)
            var shown = try record ?? initial?()
            if let record, module.model == "Invoice_Activity", let meta = try? JSONDecoder().decode([String:String].self,from:Data(record["meta"].string.utf8)) {
                var values = record.values
                let labels = ["to":"宛先","subject":"件名","providerID":"送信サービスの受付ID","jobID":"処理ID","amount":"金額","method":"入金方法","sourceInvoiceId":"複製元","paymentId":"削除した入金ID"]
                values["meta"] = .text(meta.keys.sorted().map { key in (labels[key] ?? key)+"："+CRMModule.invoiceLabel(meta[key]!) }.joined(separator:"\n"))
                shown = NativeRecord(model:record.model,values:values,revision:record.revision)
            }
            let controller = try CRMEditor(module:module,record:shown,linkedTo:nil,service:service,readOnly:readOnly,windowTitle:module.singular+(readOnly ? "を表示" : record == nil ? "を登録" : "を編集"),saveTitle:record == nil ? "登録" : "保存",onSave:readOnly ? nil : { [weak self] input in guard let self, let save = self.save else { return }; try save(record,input) })
            editor = controller; window.beginSheet(controller.window) { [weak self] _ in self?.editor = nil; self?.start() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func deleteSelected() {
        guard window.attachedSheet == nil, let remove, rows.indices.contains(table.selectedRow) else { return }; let record = rows[table.selectedRow]
        let alert = NSAlert(); alert.messageText = module.singular+"を削除しますか？"; alert.informativeText = module.model == "Invoice_Payments" ? "入金を削除して請求書の残高を再計算します。この操作は元に戻せません。" : "使用中の設定は削除できません。削除すると元に戻せません。"; alert.addButton(withTitle:"削除"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; do { try remove(record); self.start() } catch { self.message.stringValue = error.localizedDescription } }
    }
    private func updateSelection() { let selected = rows.indices.contains(table.selectedRow); edit.isEnabled = selected; delete.isEnabled = selected }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard cells.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("invoice-record")
        let view = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); view.identifier = id; view.configure(columns:columns,values:cells[row]); return view
    }
}
