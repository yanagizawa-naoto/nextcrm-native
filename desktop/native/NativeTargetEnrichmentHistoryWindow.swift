import AppKit

final class NativeTargetEnrichmentHistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeTargetEnrichmentService, targetID: String?
    private let table = NSTableView(), detail = NativeEnrichmentUI.label(""), message = NativeEnrichmentUI.label(""), page = NSTextField(labelWithString: "")
    private var rows: [NativeTargetEnrichmentHistoryEntry] = [], offset = 0, total = 0, focus: String?, job: NativeJob?
    private var previous: NSButton!, next: NSButton!, retry: NSButton!, cancel: NSButton!, result: NSButton!
    private var observers: [NSObjectProtocol] = [], refreshWork: DispatchWorkItem?
    private var resultWindow: NativeTargetEnrichmentResultWindow?
    var onChanged: (() -> Void)?
    init(api: NativeTargetEnrichmentService, targetID: String? = nil, focusedID: String? = nil) throws {
        try api.service.authenticated(); self.api = api; self.targetID = targetID; focus = focusedID; super.init()
        window.title = targetID == nil ? "情報補完の履歴" : "この営業先の情報補完"
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openResult)
        let list = NativeEnrichmentUI.table(table, label: "情報補完の履歴一覧", columns: [("contact", "営業先", 180), ("status", "状態", 85), ("created", "開始日時", 160), ("fields", "調査項目", 290), ("actor", "実行者", 130)], height: 248)
        detail.setAccessibilityLabel("情報補完の進捗"); detail.maximumNumberOfLines = 3; detail.heightAnchor.constraint(equalToConstant: 56).isActive = true
        message.setAccessibilityLabel("情報補完の履歴操作結果"); message.maximumNumberOfLines = 2
        result = button("結果を確認…", #selector(openResult)); retry = button("再試行", #selector(retrySelected)); cancel = button("処理を取り消す", #selector(cancelSelected))
        previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward)); let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        NativeEnrichmentUI.layout(window, [NativeEnrichmentUI.label(window.title, title: true),
            NativeEnrichmentUI.label("確認用の調査は結果を選んで反映します。自動調査は営業先の空欄と担当者を更新します。この画面を閉じても処理は続きます。"), list, detail,
            NativeEnrichmentUI.row([result, retry, cancel]), message,
            NativeEnrichmentUI.row([button("再読み込み", #selector(reload)), NSView(), page, previous, next, close])])
        for name in [InvoiceJobRunner.didProcess, NativeDatabase.aiProgress] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, note.userInfo?["database"] as? String == self.api.db.url.path else { return }
                self.refreshWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.reload() }; self.refreshWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            })
        }
        try refresh()
    }
    deinit { refreshWork?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    private func button(_ title: String, _ action: Selector) -> NSButton { NativeEnrichmentUI.button(title, target: self, action: action) }
    private var selected: NativeTargetEnrichmentHistoryEntry? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func refresh() throws {
        let old = selected?.id ?? focus, values = try api.historyPage(targetID: targetID, offset: offset); total = values.total
        if values.rows.isEmpty && offset > 0 { offset = max(0, ((max(1, total) - 1) / 100) * 100); return try refresh() }
        rows = values.rows; table.reloadData()
        if let old, let index = rows.firstIndex(where: { $0.id == old }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        focus = nil; page.stringValue = "\(total == 0 ? 0 : offset + 1)–\(offset + rows.count) ／ \(total)件"
        previous.isEnabled = offset > 0; next.isEnabled = offset + rows.count < total; selection()
    }
    private func selection() {
        job = nil; result.isEnabled = false; retry.isEnabled = false; cancel.isEnabled = false
        guard let selected else { detail.stringValue = "確認する処理を選択してください。"; return }
        do {
            job = try api.readableJob(selected.id); result.isEnabled = selected.history["status"] == .text("COMPLETED")
            if let job {
                let own = job.payload["actorID"] == api.service.identity.id
                let internalUser = ["user", "manager", "admin"].contains(api.service.identity.role)
                retry.isEnabled = internalUser && own && ["failed", "retry"].contains(job.status)
                cancel.isEnabled = internalUser && (own || api.service.identity.elevated) && ["pending", "retry", "failed", "running"].contains(job.status)
            }
            let description = job?.lastError ?? job?.result["message"] ?? selected.history["error"].string
            let mode = NativeTargetEnrichmentPresentation.mode(job)
            let person = job.flatMap { $0.event == NativeTargetEnrichment.contactEvent ? " ／ 担当者：" + NativeTargetEnrichmentPresentation.contactName($0) : nil } ?? ""
            detail.stringValue = "\(CRMModule.displayName(selected.target))\(person)\n\(NativeEnrichmentPresentation.status(selected.history, job: job)) ／ \(mode)\n\(description)"
        } catch { detail.stringValue = ""; NativeEnrichmentUI.message(message, error) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor column: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row]
        switch column?.identifier.rawValue {
        case "contact": return CRMModule.displayName(item.target)
        case "status": return NativeEnrichmentPresentation.status(item.history)
        case "created": return NativeEnrichmentUI.date(item.history["createdAt"].string)
        case "actor": return item.actorName
        default: let fields = (try? NativeContactEnrichment.decode([String].self, item.history["fields"].string)) ?? []; return fields.map { NativeTargetEnrichmentPresentation.label($0) }.joined(separator: "、")
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selection() }
    @objc private func reload() { do { try refresh() } catch { rows = []; table.reloadData(); selection(); NativeEnrichmentUI.message(message, error) } }
    @objc private func retrySelected() { guard let job else { return }; do { try api.retry(job); try refresh(); message.textColor = .labelColor; message.stringValue = "再試行を予約しました。" } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func cancelSelected() { guard let job else { return }; do { try api.cancel(job); try refresh(); message.textColor = .labelColor; message.stringValue = "処理を取り消しました。" } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func openResult() {
        guard window.attachedSheet == nil, let selected, selected.history["status"] == .text("COMPLETED") else { return }
        do {
            let controller = try NativeTargetEnrichmentResultWindow(api: api, id: selected.id); resultWindow = controller
            controller.onChanged = { [weak self] in self?.onChanged?() }
            window.beginSheet(controller.window) { [weak self] _ in self?.resultWindow = nil; self?.reload() }
        } catch { NativeEnrichmentUI.message(message, error) }
    }
    @objc private func back() { offset = max(0, offset - 100); reload() }
    @objc private func forward() { offset += 100; reload() }
    @objc private func close() { NativeEnrichmentUI.close(window) }
}

final class NativeTargetEnrichmentResultWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
    private let api: NativeTargetEnrichmentService, preview: NativeTargetEnrichmentReading, writable: NativeTargetEnrichmentPreview?
    private let fields: [NativeEnrichmentField], names: [String]
    private let table = NSTableView(), evidence = NSTextView(), sources = NSPopUpButton(), message = NativeEnrichmentUI.label("")
    private var apply: NSButton!, open: NSButton!, copy: NSButton!, selected = Set<String>(), applied = false
    private var urls: [URL] = []
    private var contactsWindow: NativeTargetAcquiredContactsWindow?
    private let openURL: (URL) -> Void, copyValue: (String) -> Void
    var onChanged: (() -> Void)?
    init(api: NativeTargetEnrichmentService, id: String,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         copyValue: @escaping (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }) throws {
        self.api = api; self.openURL = openURL; self.copyValue = copyValue
        let write = try? api.preview(id), read = try api.resultForReading(id)
        writable = write; preview = read
        let job = try api.readableJob(id)
        fields = job.flatMap { try? NativeContactEnrichment.decode([NativeEnrichmentField].self, $0.payload["fields"] ?? "") } ?? []
        let requested = (try? NativeContactEnrichment.decode([String].self, read.history["fields"].string)) ?? []
        let ordered = requested.filter { read.result.enrichments[$0] != nil } + read.result.enrichments.keys.filter { !requested.contains($0) }.sorted()
        names = ordered
        if write != nil { selected = Set(ordered.filter { NativeTargetEnrichment.columns.contains($0) && read.result.enrichments[$0]?.value.truthy == true }) }
        super.init(); window.title = "情報補完の取得結果"
        table.dataSource = self; table.delegate = self
        let list = NativeEnrichmentUI.table(table, label: "現在値と取得結果の比較", columns: [("check", "反映", 45), ("field", "項目", 180), ("current", "現在の値", 245), ("value", "取得した値", 300), ("confidence", "確信度", 80)], height: 190)
        evidence.isEditable = false; evidence.isRichText = false; evidence.font = .systemFont(ofSize: 13); evidence.isVerticallyResizable = true; evidence.isHorizontallyResizable = false; evidence.textContainer?.widthTracksTextView = true
        evidence.setAccessibilityLabel("取得値と根拠の詳細")
        let scroll = NSScrollView(); scroll.documentView = evidence; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        sources.setAccessibilityLabel("根拠のURL"); sources.widthAnchor.constraint(equalToConstant: 560).isActive = true
        open = button("根拠をブラウザで開く", #selector(openSource)); copy = button("取得値をコピー", #selector(copySelected))
        apply = button("選択した項目を反映", #selector(applySelected)); let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        message.setAccessibilityLabel("情報補完の反映結果"); message.maximumNumberOfLines = 2
        let help = writable == nil ? preview.notice + (preview.isContact ? " この結果は閲覧のみです。反映状況は担当者一覧でも確認できます。" : " この結果は閲覧のみです。反映する場合は確認用の情報補完を実行してください。") : "チェックした項目で現在の値を置き換えます。行を選ぶと取得値と根拠を確認できます。"
        NativeEnrichmentUI.layout(window, [NativeEnrichmentUI.label(CRMModule.displayName(preview.target) + "の取得結果", title: true), NativeEnrichmentUI.label(help), list, scroll,
            NativeEnrichmentUI.row([sources, open]), NativeEnrichmentUI.row([copy, button("取得した担当者（\(preview.contacts.count)件）…", #selector(openContacts)), NSView()]), message, NativeEnrichmentUI.row([NSView(), close, apply])])
        if !names.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }; selection()
        if names.isEmpty { message.stringValue = preview.emptyMessage }
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NativeEnrichmentUI.button(title, target: self, action: action) }
    private func confidence(_ value: NativeEnrichmentResult) -> String { preview.missingConfidence.contains(value.field) ? "未提供" : "\(Int((value.confidence * 100).rounded()))%" }
    @objc private func openContacts() {
        guard window.attachedSheet == nil else { return }
        do {
            try requireAccess()
            let controller = NativeTargetAcquiredContactsWindow(contacts: preview.contacts, requireAccess: { [api, preview] in _ = try api.readTarget(preview.target["id"].string) })
            contactsWindow = controller; window.beginSheet(controller.window) { [weak self] _ in self?.contactsWindow = nil }
        } catch { NativeEnrichmentUI.message(message, error) }
    }
    private var current: NativeEnrichmentResult? { names.indices.contains(table.selectedRow) ? preview.result.enrichments[names[table.selectedRow]] : nil }
    private func requireAccess() throws { try api.service.assertAccess("crm_Targets", id: preview.target["id"].string) }
    private func selection() {
        urls = []; sources.removeAllItems(); evidence.string = ""; open.isEnabled = false; copy.isEnabled = false
        apply.isEnabled = writable != nil && !selected.isEmpty && !applied
        guard let current else { return }
        do {
            try requireAccess()
            let label = NativeTargetEnrichmentPresentation.label(current.field, fields: fields), previous = preview.mapped(current.field) ? preview.currentValue(current.field) : "任意項目・履歴のみ"
            var text = "\(label)\n現在の値：\(previous.isEmpty ? "未入力" : previous)\n取得した値：\(current.value.text)\n確信度：\(confidence(current))"
            for source in current.sourceContext ?? [] { text += "\n\n出典：\(source.url)\n\(source.snippet)" }
            if let corroboration = current.corroboration {
                text += "\n\n複数の出典の一致：\(corroboration.sources_agree ? "あり" : "なし")"
                for item in corroboration.evidence { text += "\n\n出典：\(item.source_url)\n取得値：\(item.value.text)\n引用：\(item.exact_text)" }
            }
            if let source = current.source, !(current.sourceContext ?? []).contains(where: { $0.url == source }) { text += "\n\n出典・補足：\(source)" }
            evidence.string = text; urls = NativeEnrichmentPresentation.sourceURLs(current); sources.addItems(withTitles: urls.map(\.absoluteString)); open.isEnabled = !urls.isEmpty; copy.isEnabled = true
        } catch { apply.isEnabled = false; NativeEnrichmentUI.message(message, error) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { names.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard names.indices.contains(row), let value = preview.result.enrichments[names[row]] else { return nil }; let key = names[row], mapped = preview.mapped(key)
        switch column?.identifier.rawValue {
        case "check": let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:))); check.tag = row; check.state = selected.contains(key) ? .on : .off; check.isEnabled = writable != nil && mapped && value.value.truthy && !applied; check.setAccessibilityLabel(NativeTargetEnrichmentPresentation.label(key, fields: fields) + "を反映"); return check
        case "field": return NativeEnrichmentUI.cell(NativeTargetEnrichmentPresentation.label(key, fields: fields))
        case "current": return NativeEnrichmentUI.cell(mapped ? preview.currentValue(key) : "任意項目・履歴のみ")
        case "confidence": return NativeEnrichmentUI.cell(confidence(value))
        default: return NativeEnrichmentUI.cell(value.value.text)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selection() }
    @objc private func toggle(_ button: NSButton) { guard names.indices.contains(button.tag) else { return }; let key = names[button.tag]; if button.state == .on { selected.insert(key) } else { selected.remove(key) }; selection() }
    @objc private func applySelected() {
        guard let writable, !applied else { return }
        do { let names = try api.apply(writable, selected: selected); applied = true; selected.removeAll(); table.reloadData(); selection(); message.textColor = .labelColor; message.stringValue = names.isEmpty ? "反映による変更はありません。" : "\(names.count)項目を反映しました。"; onChanged?() }
        catch { apply.isEnabled = false; message.textColor = .systemRed; message.stringValue = error.localizedDescription + " この画面を閉じて結果を開き直し、現在の値を確認してください。" }
    }
    @objc private func openSource() { do { try requireAccess(); guard urls.indices.contains(sources.indexOfSelectedItem) else { return }; openURL(urls[sources.indexOfSelectedItem]) } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func copySelected() { do { try requireAccess(); if let current { copyValue(current.value.text) } } catch { NativeEnrichmentUI.message(message, error) } }
    @objc private func close() { NativeEnrichmentUI.close(window) }
}
