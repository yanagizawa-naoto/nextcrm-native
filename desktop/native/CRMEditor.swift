import AppKit
import CoreText

/// Display-only form labels share one view; real controls retain native Japanese input and accessibility labels.
class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
    var labels: [(String,NSRect)] = []
    private static let font = NSFont.systemFont(ofSize:13)
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for (text,rect) in labels where rect.intersects(dirtyRect) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[.font:Self.font,NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String):true]))
            let width = CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
            context.saveGState(); context.clip(to:rect); context.translateBy(x:rect.maxX-width,y:rect.minY+15); context.scaleBy(x:1,y:-1)
            context.textMatrix = .identity; context.textPosition = .zero; context.setFillColor(NSColor.secondaryLabelColor.cgColor); CTLineDraw(line,context); context.restoreGState()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class CRMDateControl: NSView {
    private let enabled = NSButton(checkboxWithTitle: "設定", target: nil, action: nil)
    private let picker = NSDatePicker()
    init(value: SQLValue, includesTime: Bool, required: Bool, utc: Bool = false) {
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        enabled.state = value == .null && !required ? .off : .on; enabled.isEnabled = !required; enabled.target = self; enabled.action = #selector(changed)
        picker.datePickerStyle = .textFieldAndStepper; picker.datePickerElements = includesTime ? [.yearMonthDay,.hourMinute] : .yearMonthDay
        picker.locale = Locale(identifier: "ja_JP"); picker.timeZone = utc ? TimeZone(secondsFromGMT:0)! : .current
        let parser = ISO8601DateFormatter(); if let date = parser.date(from: value.string) { picker.dateValue = date }
        else { parser.formatOptions.insert(.withFractionalSeconds); picker.dateValue = parser.date(from: value.string) ?? Date() }
        enabled.frame = NSRect(x: 0, y: 4, width: 58, height: 24); picker.frame = NSRect(x: 66, y: 2, width: 250, height: 28)
        addSubview(enabled); addSubview(picker); changed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { picker.isEnabled = enabled.state == .on }
    var value: SQLValue { enabled.state == .on ? .text(ISO8601DateFormatter().string(from: picker.dateValue)) : .null }
    var draftValue: FormRawValue { .date(picker.dateValue,enabled.state == .on) }
    func restoreDraftValue(_ value: FormRawValue) { if case let .date(date,on) = value { picker.dateValue = date; enabled.state = on ? .on : .off; changed() } }
}

final class CRMReferenceControl: NSView {
    let model: String; private let service: CRMService
    private let label = NSTextField(labelWithString: "未設定")
    var selected: SQLValue; var choose: (() -> Void)?
    init(model: String, selected: SQLValue, service: CRMService) {
        self.model = model; self.selected = selected; self.service = service
        super.init(frame: NSRect(x: 0,y: 0,width: 500,height: 30))
        setAccessibilityElement(true); setAccessibilityRole(.group)
        label.stringValue = (try? service.referenceName(model, id: selected.string)) ?? "未設定"
        label.lineBreakMode = .byTruncatingTail; label.frame = NSRect(x:0,y:6,width:320,height:20); label.autoresizingMask = [.width]
        let button = NSButton(title: "選択…", target: self, action: #selector(open)); button.bezelStyle = .rounded; button.frame = NSRect(x:330,y:0,width:90,height:30); button.autoresizingMask = [.minXMargin]
        let clear = NSButton(title: "解除", target: self, action: #selector(reset)); clear.bezelStyle = .rounded; clear.frame = NSRect(x:420,y:0,width:70,height:30); clear.autoresizingMask = [.minXMargin]
        addSubview(label); addSubview(button); addSubview(clear)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setRecord(_ record: NativeRecord) { selected = record[model == "Currency" ? "code" : "id"]; label.stringValue = CRMModule.displayName(record) }
    func refreshLabel(service: CRMService) { label.stringValue = (try? service.referenceName(model,id:selected.string)) ?? "未設定" }
    @objc private func open() { choose?() }
    func clearSelection() { selected = .null; label.stringValue = "未設定" }
    @objc private func reset() { clearSelection() }
}

final class CRMReferencePicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect: NSRect(x:0,y:0,width:660,height:520), styleMask:[.titled], backing:.buffered, defer:false)
    private let model: String; private let service: CRMService; private let completion: (NativeRecord?) -> Void
    private let userRole: String?
    private let matching: RecordFilter
    private let search = NSSearchField(); private let table = NSTableView(); private let count = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private let choose = NSButton(title:"選択",target:nil,action:nil)
    private var rows: [NativeRecord] = []; private var offset = 0; private var total = 0
    private var pending: Task<Void, Never>?, generation = 0
    init(model: String, service: CRMService, userRole: String? = nil, matching: RecordFilter = .all, completion: @escaping (NativeRecord?) -> Void) {
        self.model = model; self.service = service; self.userRole = userRole; self.matching = matching; self.completion = completion; super.init()
        window.title = "関連先を選択"
        search.placeholderString = model == "crm_Accounts" ? "会社名で検索" : "名称・メールなどで検索"; search.setAccessibilityLabel("関連先を検索"); search.delegate = self
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 36; table.target = self; table.doubleAction = #selector(select)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.width = 600; table.addTableColumn(column)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        previous.target = self; previous.action = #selector(back); next.target = self; next.action = #selector(forward)
        let cancel = NSButton(title:"キャンセル",target:self,action:#selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        choose.target = self; choose.action = #selector(select); choose.keyEquivalent = "\r"; choose.isEnabled = false
        let footer = NSStackView(views:[count,NSView(),previous,next,cancel,choose]); footer.spacing = 8
        let stack = NSStackView(views:[search,scroll,footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),search.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350),footer.widthAnchor.constraint(equalTo:stack.widthAnchor)])
    }
    deinit { pending?.cancel() }
    func start() { load(); window.makeFirstResponder(search) }
    private func load() {
        pending?.cancel(); generation += 1
        if model != "crm_Accounts" {
            do { display(.success(try service.references(model, search: search.stringValue, offset: offset, userRole:userRole, matching:matching))) }
            catch { display(.failure(error)) }; return
        }
        // Full-name scans run off the main thread. Editing or closing cancels
        // the previous scan; stale rows cannot be selected while it is running.
        let version = generation, service = service, matching = matching, text = search.stringValue, page = offset
        rows = []; table.reloadData(); choose.isEnabled = false; previous.isEnabled = false; next.isEnabled = false; count.stringValue = "検索しています…"
        pending = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<(rows: [NativeRecord], total: Int), Error>
            do { result = .success(try service.references("crm_Accounts", search: text, offset: page, matching: matching)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == version else { return }
                self.pending = nil; self.display(result)
            }
        }
    }
    private func display(_ result: Result<(rows: [NativeRecord], total: Int), Error>) {
        switch result {
        case let .success(page): rows = page.rows; total = page.total; count.stringValue = "\(total)件"; previous.isEnabled = offset > 0; next.isEnabled = offset + 100 < total
        case let .failure(error): rows = []; total = 0; previous.isEnabled = false; next.isEnabled = false; count.stringValue = error.localizedDescription
        }
        table.reloadData(); choose.isEnabled = rows.indices.contains(table.selectedRow)
    }
    func controlTextDidChange(_ notification: Notification) { offset = 0; load() }
    @objc private func back() { offset = max(0,offset-100); load() }
    @objc private func forward() { offset += 100; load() }
    @objc private func select() {
        guard pending == nil, rows.indices.contains(table.selectedRow) else { return }; let selected = rows[table.selectedRow]
        do {
            if model == "crm_Accounts" {
                try service.authenticated()
                guard try !service.db.keysetPage(model, fields: [], filter: .every([service.scope(model), matching, .equal("id", selected["id"])]), limit: 1).isEmpty else { throw NativeDBError.message("取引先が見つからないか、表示する権限がありません。") }
            }
            window.sheetParent?.endSheet(window); completion(selected)
        } catch { display(.failure(error)) }
    }
    @objc private func cancel() { pending?.cancel(); pending = nil; generation += 1; window.sheetParent?.endSheet(window); completion(nil) }
    func tableViewSelectionDidChange(_ notification: Notification) { choose.isEnabled = pending == nil && rows.indices.contains(table.selectedRow) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("reference")
        let cell = tableView.makeView(withIdentifier:identifier,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = identifier
        cell.configure(columns:[NativeColumn(title:"名称",fraction:1)], values:[CRMModule.displayName(rows[row])]); return cell
    }
}
