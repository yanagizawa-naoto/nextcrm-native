import AppKit

final class CRMEditor: NSObject, NSTextFieldDelegate {
    let window: NSWindow
    private let service: CRMService; private let module: CRMModule; private let original: NativeRecord?; private let linkedTo: NativeRecord?
    private let saveOverride: (([String:SQLValue]) throws -> Void)?; private let readOnly: Bool
    private let draft: FormDraft; private let referenceFilters: [String:RecordFilter]
    private let scroll = NSScrollView(); private let content = CRMFormContentView(frame:NSRect(x:0,y:0,width:710,height:100))
    private let errorLabel = NSTextField(wrappingLabelWithString:"")
    private let cancelButton = NSButton(); private let saveButton = NSButton()
    private var protected = Set<String>(); private var frames: [NSRect] = []
    private var proxies: [CRMFormAccessibilityField] = []
    private var mounted: [Int:Input] = [:]
    private var textPool: [NSTextField] = []
    private var longInputs: [Int:DeferredTextInput] = [:]
    private var observer: NSObjectProtocol?; private var updating = false
    private var picker: CRMReferencePicker?; private var pickerIndex: Int?
    private var formStack: NSStackView!, accessory: NSView?, stopAccessory: (() -> Void)?
    private let virtualized = ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_FORM_MODE"] != "eager"
    private var lastStats = ""
    var saved: NativeRecord?
    private struct Input {
        let view: NSView; let read: () -> FormRawValue; let write: (FormRawValue) -> Void
    }
    init(module: CRMModule, record: NativeRecord?, linkedTo: NativeRecord?, service: CRMService, referenceFilters: [String:RecordFilter] = [:], readOnly: Bool = false, windowTitle: String? = nil, saveTitle: String? = nil, onSave: (([String:SQLValue]) throws -> Void)? = nil) throws {
        self.module = module; original = record; self.linkedTo = linkedTo; self.service = service; self.referenceFilters = referenceFilters
        saveOverride = onSave; self.readOnly = readOnly
        var input = try record?.values ?? service.db.initialValues(module.model)
        if record == nil {
            input["assigned_to"] = .text(service.identity.id)
            if module.model == "Boards" { input["visibility"] = .text("private") }
            if module.model == "Tasks" { input["user"] = .text(service.identity.id); input["priority"] = .text("normal") }
            if module.model == "crm_Accounts_Tasks" { input["user"] = .text(service.identity.id); input["priority"] = .text("medium"); input["dueDateAt"] = .null }
            if module.fields.contains(where: { $0.key == "currency" }) { input["currency"] = .text("JPY") }
            if module.model == "crm_Activities" { input["type"] = .text("note"); input["date"] = .text(ISO8601DateFormatter().string(from:Date())) }
        }
        draft = try FormDraft(module:module,schema:service.db.schema.model(module.model),input:input,isNew:record == nil)
        let formWindow = CRMFormWindow(contentRect:NSRect(x:0,y:0,width:760,height:710),styleMask:[.titled],backing:.buffered,defer:false)
        window = formWindow; super.init()
        if record != nil, let line = LineContext.forModel(module.model) { protected = line.totalField == nil ? ["productId","currency"] : ["productId","sku"] }
        if let record, let child = LineContext.childModel(module.model), let line = LineContext.forModel(child), let total = line.totalField,
           try service.db.page(child,fields:[],equal:[line.field:record["id"]]).total > 0 { protected.formUnion(["currency",total]) }
        window.title = windowTitle ?? ("\(module.singular)を"+(readOnly ? "表示" : record == nil ? "登録" : "編集"))
        let heading = NSTextField(labelWithString:window.title); heading.font = .systemFont(ofSize:22,weight:.semibold)
        let context = NSTextField(labelWithString:linkedTo.map { "関連先："+CRMModule.displayName($0)+(LineContext.forModel(module.model)?.totalField != nil ? "　通貨："+service.lineCurrency($0) : "") } ?? "必須項目には「＊」が付いています。")
        context.textColor = .secondaryLabelColor; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = content
        var y: CGFloat = 10
        for (index,field) in module.fields.enumerated() {
            let tall: Bool = { switch field.kind { case .multiline,.lines: return true; default: return false } }()
            let height: CGFloat = tall ? 90 : 38; let rect = NSRect(x:190,y:y+2,width:500,height:height-8); frames.append(rect)
            content.labels.append((field.label+(field.required ? " ＊" : ""),NSRect(x:0,y:y+7,width:174,height:24)))
            let proxy = CRMFormAccessibilityField(); proxy.content = content; proxy.label = field.label; proxy.rect = rect
            proxy.show = { [weak self] in self?.focusField(index) }; proxies.append(proxy); y += height+6
        }
        content.frame.size.height = y+10
        content.fields = { [weak self] in guard let self else { return [] }; return self.module.fields.indices.map { self.mounted[$0]?.view as Any? ?? self.proxies[$0] } }
        content.ready = { [weak self] in self?.updateVisible() }
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in self?.updateVisible() }
        formWindow.moveFocus = { [weak self] view,direction in self?.moveFocus(from:view,direction:direction) ?? false }
        formWindow.focusChanged = { [weak self] in self?.updateVisible() }
        errorLabel.font = .systemFont(ofSize:12); errorLabel.textColor = .systemRed
        cancelButton.title = readOnly ? "閉じる" : "キャンセル"; cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.bezelStyle = .rounded; cancelButton.keyEquivalent = "\u{1b}"
        saveButton.title = saveTitle ?? (onSave == nil ? "保存" : "編集内容に反映"); saveButton.target = self; saveButton.action = #selector(save); saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = .command; saveButton.isHidden = readOnly
        let buttons = NSStackView(views:[NSView(),cancelButton,saveButton]); buttons.spacing = 10
        let root = NSStackView(views:[heading,context,scroll,errorLabel,buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        formStack = root
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-18),scroll.widthAnchor.constraint(equalTo:root.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:470),buttons.widthAnchor.constraint(equalTo:root.widthAnchor),errorLabel.widthAnchor.constraint(equalTo:root.widthAnchor)])
        window.contentView!.layoutSubtreeIfNeeded(); updateVisible()
        window.initialFirstResponder = mounted[0].flatMap { focusable($0.view).first } ?? cancelButton
    }
    deinit { stopAccessory?(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func installAccessory(_ view: NSView, readOnlyAllowed: Bool = false, onClose: @escaping () -> Void) {
        guard (!readOnly || readOnlyAllowed), !view.isHidden else { return }
        let previousClose = stopAccessory
        stopAccessory = { previousClose?(); onClose() }
        if let previous = accessory {
            formStack.removeArrangedSubview(previous); previous.removeFromSuperview()
            let group = NSStackView(views: [previous, view]); group.orientation = .vertical; group.alignment = .leading; group.spacing = 6
            accessory = group; formStack.insertArrangedSubview(group, at: 2)
            group.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
            previous.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        } else { accessory = view; formStack.insertArrangedSubview(view, at: 2) }
        view.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        window.setContentSize(NSSize(width: 760, height: 790))
        window.contentView?.layoutSubtreeIfNeeded(); updateVisible()
    }
    func textValues() -> [String: String] {
        captureAll(); return draft.values.reduce(into: [:]) { result, pair in
            if case let .text(value) = pair.value { result[pair.key] = value }
        }
    }
    func applyTextValues(_ values: [String: String]) throws {
        guard !readOnly else { return }
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { throw NativeDBError.message("日本語の変換を確定してから、もう一度照会してください。") }
        try service.authenticated(); captureAll()
        for (key, value) in values where !protected.contains(key) { draft.setText(key, value) }
        for (index, input) in mounted { input.write(draft.values[module.fields[index].key]!) }
        errorLabel.stringValue = ""; NSAccessibility.post(element: content, notification: .valueChanged)
    }
    private func contains(_ root: NSView, _ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if let view = responder as? NSView, view === root || view.isDescendant(of:root) { return true }
        if let control = root as? NSControl, control.currentEditor() === responder { return true }
        return root.subviews.contains { contains($0,responder) }
    }
    private func activeIndex(_ view: NSView? = nil) -> Int? { mounted.first { contains($0.value.view,view ?? window.firstResponder) }?.key }
    private func capture(_ index: Int) { if let input = mounted[index] { draft.set(module.fields[index].key,input.read()) } }
    private func captureAll() { for index in mounted.keys { capture(index) }; for (index,input) in longInputs where mounted[index] == nil { draft.setText(module.fields[index].key,input.string) } }
    private func updateVisible() {
        guard !updating else { return }; updating = true; defer { updating = false }
        let visible = scroll.documentVisibleRect; let active = activeIndex()
        let desired = Set(frames.indices.filter { !virtualized || frames[$0].intersects(visible.insetBy(dx:0,dy:-44)) || $0 == active || $0 == pickerIndex })
        for index in Array(mounted.keys) where !desired.contains(index) { retire(index) }
        for index in desired.sorted() where mounted[index] == nil { mount(index) }
        if ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_FORM_DIAGNOSTICS"] == "1" {
            let stats = "FORM_STATS fields=\(module.fields.count) mounted=\(mounted.count) pooled=\(textPool.count) textEditors=\(longInputs.values.filter { $0.editor != nil }.count) mode=\(virtualized ? "virtual" : "eager")"
            if stats != lastStats { print(stats); fflush(stdout); lastStats = stats }
        }
    }
    private func retire(_ index: Int) {
        guard let input = mounted.removeValue(forKey:index) else { return }
        draft.set(module.fields[index].key,input.read()); input.view.removeFromSuperview()
        if let text = input.view as? NSTextField { text.delegate = nil; text.nextKeyView = nil; if textPool.count < 4 { text.stringValue = ""; textPool.append(text) } }
        if let text = input.view as? DeferredTextInput, text.editor == nil { longInputs.removeValue(forKey:index) }
    }
    private func mount(_ index: Int) {
        guard mounted[index] == nil else { return }; let field = module.fields[index]; let raw = draft.values[field.key]!
        let disabled = readOnly || protected.contains(field.key); let input: Input
        switch field.kind {
        case .toggle:
            let control = NSButton(checkboxWithTitle:field.label,target:nil,action:nil)
            if case let .flag(value) = raw { control.state = value ? .on : .off }
            control.isEnabled = !disabled
            input = Input(view:control,read:{ .flag(control.state == .on) },write:{ if case let .flag(value) = $0 { control.state = value ? .on : .off } })
        case .choice:
            let choices = draft.options[field.key] ?? []; let control = NSPopUpButton(); control.addItems(withTitles:choices.map(\.1)); control.isEnabled = !disabled
            if case let .choice(value) = raw, let index = choices.firstIndex(where: { $0.0 == value }) { control.selectItem(at:index) }
            input = Input(view:control,read:{ .choice(choices.indices.contains(control.indexOfSelectedItem) ? choices[control.indexOfSelectedItem].0 : "") },write:{ if case let .choice(value) = $0, let i = choices.firstIndex(where: { $0.0 == value }) { control.selectItem(at:i) } })
        case let .relation(model):
            let value: SQLValue = { if case let .reference(value) = raw { return value }; return .null }()
            let control = CRMReferenceControl(model:model,selected:value,service:service)
            control.choose = { [weak self] in self?.chooseReference(index) }
            if disabled { control.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = false } }
            input = Input(view:control,read:{ .reference(control.selected) },write:{ [weak self] raw in
                guard let self, case let .reference(value) = raw else { return }
                control.selected = value; control.refreshLabel(service:self.service)
            })
        case .date,.dateTime:
            let control = CRMDateControl(value:try! draft.normalized(field),includesTime:{ if case .dateTime = field.kind { return true }; return false }(),required:field.required,utc:["crm_PriceListRules","crm_Orders","Invoices","Invoice_Payments"].contains(module.model))
            control.restoreDraftValue(raw); if disabled { control.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = false } }
            input = Input(view:control,read:{ control.draftValue },write:{ control.restoreDraftValue($0) })
        case .multiline,.lines:
            let control = longInputs[index] ?? DeferredTextInput(value:raw.text,label:field.label,readOnly:disabled); longInputs[index] = control
            control.activated = { [weak self] in self?.updateVisible() }
            input = Input(view:control,read:{ .text(control.string) },write:{ control.string = $0.text })
        default:
            let control = textPool.popLast() ?? NSTextField(); control.stringValue = raw.text; control.delegate = self; control.tag = index; control.isEnabled = !disabled
            let numeric: Bool = { switch field.kind { case .number,.signedNumber: return true; default: return false } }(); control.placeholderString = numeric ? "例：10000" : nil
            input = Input(view:control,read:{ .text(control.stringValue) },write:{ control.stringValue = $0.text })
        }
        input.view.identifier = NSUserInterfaceItemIdentifier(field.key); input.view.setAccessibilityLabel(field.label); input.view.frame = frames[index]
        mounted[index] = input; content.addSubview(input.view)
        if !virtualized, let text = input.view as? DeferredTextInput { text.activate() }
    }
    private func chooseReference(_ index: Int) {
        guard picker == nil, !readOnly, !protected.contains(module.fields[index].key), case let .relation(model) = module.fields[index].kind else { return }
        let field = module.fields[index]; pickerIndex = index
        let matching = referenceFilters[field.key] ?? (field.key == "productId" && LineContext.forModel(module.model) != nil ? .equal("status",.text("ACTIVE")) : .all)
        let controller = CRMReferencePicker(model:model,service:service,matching:matching) { [weak self] selected in
            guard let self else { return }
            if let selected {
                self.draft.setReference(field.key,selected[model == "Currency" ? "code" : "id"])
                self.mounted[index]?.write(self.draft.values[field.key]!)
                if field.key == "productId" { self.selectedProduct(selected) }
            }
            self.picker = nil; self.pickerIndex = nil; self.updateVisible()
        }
        picker = controller; window.beginSheet(controller.window); controller.start()
    }
    private func selectedProduct(_ record: NativeRecord) {
        if module.model == "Invoice_LineItems" {
            captureAll(); draft.setText("description",record["name"].string)
            for (index,input) in mounted { input.write(draft.values[module.fields[index].key]!) }; return
        }
        guard original == nil, LineContext.forModel(module.model) != nil else { return }
        do {
            captureAll(); let product = try service.catalogRecord("crm_Products",record["id"])
            if module.model == "crm_AccountProducts" { draft.setReference("currency",product["currency"]) }
            else if let parent = linkedTo {
                draft.setText("name",product["name"].string); draft.setText("sku",product["sku"].string); draft.setText("unit_price","")
                for (key,value) in try service.productLineDraft(record["id"],parent:parent) { draft.setText(key,value.string) }
            }
            for (index,input) in mounted { input.write(draft.values[module.fields[index].key]!) }; errorLabel.stringValue = ""
        } catch { errorLabel.stringValue = error.localizedDescription }
    }
    private func focusable(_ view: NSView) -> [NSView] {
        if view.isHidden { return [] }
        if let deferred = view as? DeferredTextInput { return [deferred.editor ?? deferred] }
        if let control = view as? NSControl { return control.isEnabled && control.acceptsFirstResponder ? [control] : [] }
        return view.subviews.flatMap(focusable)
    }
    private func focusField(_ index: Int) {
        guard frames.indices.contains(index) else { return }; mount(index)
        content.scrollToVisible(frames[index].insetBy(dx:0,dy:-10)); updateVisible()
        if let input = mounted[index], let target = focusable(input.view).first { window.makeFirstResponder(target) }
        NSAccessibility.post(element:content,notification:.layoutChanged)
    }
    private func moveFocus(from view: NSView?, direction: Int) -> Bool {
        guard window.attachedSheet == nil else { return false }
        let current = activeIndex(view); let responder = view ?? window.firstResponder
        if let current, let input = mounted[current] {
            let stops = focusable(input.view)
            if let position = stops.firstIndex(where: { contains($0,responder) }), stops.indices.contains(position+direction) { return window.makeFirstResponder(stops[position+direction]) }
        }
        let footer = [cancelButton,saveButton].filter { !$0.isHidden }
        let header = accessory.map(focusable) ?? []
        if let position = header.firstIndex(where: { contains($0, responder) }) {
            if header.indices.contains(position + direction) { return window.makeFirstResponder(header[position + direction]) }
            if direction < 0 { return window.makeFirstResponder(footer.last) }
        }
        if direction > 0, let last = footer.last, contains(last, responder), let first = header.first { return window.makeFirstResponder(first) }
        if current == nil, let position = footer.firstIndex(where: { contains($0,responder) }), footer.indices.contains(position+direction) { return window.makeFirstResponder(footer[position+direction]) }
        let start = current.map { $0+direction } ?? (direction > 0 ? 0 : frames.count-1)
        var index = start
        while frames.indices.contains(index) {
            mount(index)
            if let input = mounted[index], let target = direction > 0 ? focusable(input.view).first : focusable(input.view).last {
                content.scrollToVisible(frames[index].insetBy(dx:0,dy:-10))
                let result = window.makeFirstResponder(target); updateVisible(); return result
            }
            index += direction
        }
        updateVisible(); return window.makeFirstResponder(direction > 0 ? footer.first : header.last ?? footer.last)
    }
    func controlTextDidEndEditing(_ notification: Notification) { DispatchQueue.main.async { [weak self] in self?.updateVisible() } }
    private func readValues() throws -> [String:SQLValue] { captureAll(); return try draft.normalized() }
    func confirmDiscard() -> Bool {
        if readOnly { return true }; window.makeFirstResponder(nil); captureAll(); if !draft.hasChanges { return true }
        let alert = NSAlert(); alert.messageText = "変更を保存せずに閉じますか？"; alert.informativeText = "編集中の内容は保存されません。"; alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"変更を破棄"); return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel() { if window.attachedSheet == nil && confirmDiscard() { stopAccessory?(); window.sheetParent?.endSheet(window,returnCode:.cancel) } }
    @objc private func save() {
        guard !readOnly, window.attachedSheet == nil else { return }; window.makeFirstResponder(nil)
        do { if let saveOverride { try saveOverride(readValues()) } else { saved = try service.save(module,original:original,input:readValues(),linkedTo:linkedTo) }; stopAccessory?(); window.sheetParent?.endSheet(window,returnCode:.OK) }
        catch {
            errorLabel.stringValue = error.localizedDescription
            if let index = module.fields.firstIndex(where: { (try? draft.normalized($0)) == nil }) { focusField(index) }
        }
    }
}
