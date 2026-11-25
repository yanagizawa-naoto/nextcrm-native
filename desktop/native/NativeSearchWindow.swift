import AppKit

final class NativeSearchWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
    private let activities: NativeRestoreParentActivities
    private let activityOwner = UUID().uuidString
    private let engine: NativeSearchEngine
    private let query = NSSearchField(), kind = NSPopUpButton(), table = NSTableView()
    private let useAI = NSButton(checkboxWithTitle: "AI検索も使う", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "検索語を2文字以上で入力してください。"), detail = NSTextField(wrappingLabelWithString: "")
    private var searchButton: NSButton!, cancelButton: NSButton!, openButton: NSButton!
    private var result: NativeSearchResults?, rows: [NativeSearchHit] = [], generation = 0
    private var pending: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private(set) var selectedResult: NativeSearchHit?
    private let columns = [NativeColumn(title: "種類", fraction: 0.14), NativeColumn(title: "名称", fraction: 0.33), NativeColumn(title: "概要", fraction: 0.36), NativeColumn(title: "一致の種類", fraction: 0.17)]
    init(engine: NativeSearchEngine, activities:NativeRestoreParentActivities = .init()) throws {
        try engine.service.authenticated(); self.engine = engine;self.activities=activities; super.init(); window.title = engine.documentCandidates ? "文書を検索" : "横断検索"
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 22, weight: .semibold)
        let scopeHelp = engine.documentCandidates ? "文書名・要約を検索します。文字検索とAI検索で各5件まで表示します。" : "取引先・連絡先・リード・商談・プロジェクト・タスク・利用者・文書を、各種類10件まで表示します。"
        let aiHelp = engine.allowsAI ? "AI検索では検索語をOpenAIに送り、API利用料が発生します。未設定や接続失敗の場合は文字で検索します。" : "現在はこのMacに保存された文字で検索します。"
        let help = NSTextField(wrappingLabelWithString: scopeHelp + aiHelp)
        query.placeholderString = "検索語を入力してReturn"; query.setAccessibilityLabel(engine.documentCandidates ? "文書検索の検索語" : "横断検索の検索語"); query.delegate = self
        query.target = self; query.action = #selector(search); query.sendsWholeSearchString = true; query.sendsSearchStringImmediately = false
        useAI.state = engine.allowsAI ? .on:.off; useAI.isEnabled=engine.allowsAI; useAI.target = self; useAI.action = #selector(optionsChanged)
        kind.addItems(withTitles: engine.documentCandidates ? ["文書"] : ["すべての種類"] + NativeSearchKind.allCases.map(\.title)); kind.setAccessibilityLabel("検索結果の種類"); kind.target = self; kind.action = #selector(filterResults); kind.isEnabled = !engine.documentCandidates
        searchButton = button("検索", #selector(search)); cancelButton = button("検索を中止", #selector(cancelSearch)); cancelButton.isEnabled = false
        let controls = NSStackView(views: [query, useAI, searchButton, cancelButton]); controls.spacing = 10
        query.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filter = NSStackView(views: [kind, NSView()])
        let header = LightweightTableCell(); header.configure(columns: columns, values: columns.map(\.title), heading: true); header.heightAnchor.constraint(equalToConstant: 25).isActive = true
        let column = NSTableColumn(identifier: .init("result")); column.width = 950; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 36; table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(openSelected); table.setAccessibilityLabel(engine.documentCandidates ? "文書検索の結果" : "横断検索の結果")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        detail.maximumNumberOfLines = engine.documentCandidates ? 5 : 3; detail.lineBreakMode = .byTruncatingTail; detail.setAccessibilityLabel("検索結果の詳細")
        message.maximumNumberOfLines = 2; message.setAccessibilityLabel(engine.documentCandidates ? "文書検索の状態" : "横断検索の状態")
        openButton = button("選択した結果を開く", #selector(openSelected)); openButton.isEnabled = false
        let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [openButton, NSView(), close]); footer.spacing = 10
        InvoiceMailUI.layout(window, [title, help, controls, filter, header, scroll, detail, message, footer], spacing: 8)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.validateResults() }
    }
    deinit { pending?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func button(_ title: String, _ action: Selector) -> NSButton { InvoiceMailUI.button(title, target: self, action: action) }
    func start() { window.makeFirstResponder(query) }
    private var selected: NativeSearchHit? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func invalidate() {
        pending?.cancel(); pending = nil; generation += 1; result = nil; rows = []; table.reloadData(); selection()
        searchButton.isEnabled = true; cancelButton.isEnabled = false
    }
    func controlTextDidChange(_ notification: Notification) { invalidate(); message.textColor = .secondaryLabelColor; message.stringValue = "検索ボタンまたはReturnで検索します。" }
    @objc private func optionsChanged() { invalidate(); message.stringValue = "検索方法を変更しました。もう一度検索してください。" }
    @objc private func search() {
        guard !activities.isSealed else{return}
        invalidate(); let version = generation, text = NativeAIEnvironment.trim(query.stringValue), ai = useAI.state == .on, engine = engine
        do { try engine.service.authenticated(); try CRMService.validateGlobalQuery(text) }
        catch { show(error); return }
        message.textColor = .secondaryLabelColor; message.stringValue = "検索しています…"; searchButton.isEnabled = false; cancelButton.isEnabled = true
        pending = activities.spawn(owner:activityOwner,kind:.externalRead) { [weak self] in
            let response: Result<NativeSearchResults, Error>
            do { response = .success(try await engine.search(text, useAI: ai)) } catch { response = .failure(error) }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == version else { return }
                self.pending = nil; self.searchButton.isEnabled = true; self.cancelButton.isEnabled = false
                switch response {
                case let .success(results): self.result = results; self.filterResults()
                case let .failure(error): self.show(error)
                }
            }
        }
    }
    @objc private func cancelSearch() { invalidate(); message.stringValue = "検索を中止しました。" }
    private func validateResults() {
        do {
            try engine.service.authenticated()
            if let result {
                let hits = result.hits.filter { (try? engine.service.searchDestination($0)) != nil }
                self.result = NativeSearchResults(hits: hits, aiState: result.aiState); renderResults()
            }
        } catch { invalidate(); show(error) }
    }
    @objc private func filterResults() { validateResults() }
    private func renderResults() {
        let selectedKind = kind.indexOfSelectedItem > 0 ? NativeSearchKind.allCases[kind.indexOfSelectedItem - 1] : nil
        rows = result?.hits.filter { selectedKind == nil || $0.kind == selectedKind } ?? []
        table.reloadData(); selection(); message.textColor = .secondaryLabelColor
        message.stringValue = "\(rows.count)件。" + (result?.aiState.message ?? "")
    }
    private func show(_ error: Error) { message.textColor = .systemRed; message.stringValue = error.localizedDescription }
    private static func subtitle(_ hit: NativeSearchHit) -> String {
        if hit.kind == .tasks { return CRMModule.projectLabel(hit.subtitle) }
        if hit.kind == .opportunities, let field = CRMModule.find(hit.kind.model)?.fields.first(where: { $0.key == "status" }), case let .choice(choices) = field.kind { return choices.first { $0.0 == hit.subtitle }?.1 ?? hit.subtitle }
        return hit.subtitle
    }
    private func selection() {
        openButton.isEnabled = selected != nil
        detail.stringValue = selected.map { hit in
            var lines = [hit.title, Self.subtitle(hit)]
            if let type = hit.documentSystemType { lines.append("区分：" + (CRMModule.documentTypes.first { $0.0 == type }?.1 ?? "未設定")) }
            if let account = hit.documentAccountName { lines.append("取引先：" + account) }
            lines.append(hit.match.title); return lines.joined(separator: "\n")
        } ?? ""
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selection() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let hit = rows[row]
        let id = NSUserInterfaceItemIdentifier("searchResult")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        cell.configure(columns: columns, values: [hit.kind.title, hit.title, Self.subtitle(hit), hit.match.title]); return cell
    }
    @objc private func openSelected() {
        guard let hit = selected else { return }
        do { _ = try engine.service.searchDestination(hit); selectedResult = hit; pending?.cancel(); generation += 1; window.sheetParent?.endSheet(window, returnCode: .OK) }
        catch { invalidate(); show(error) }
    }
    @objc private func close() { invalidate(); window.sheetParent?.endSheet(window, returnCode: .cancel) }
    #if RESTORE_PARENT_TESTING
    func searchForTesting(_ text:String){query.stringValue=text;search()}
    func cancelForTesting(){cancelSearch()}
    var hasCurrentForTesting:Bool {pending != nil}
    #endif

}

extension CRMModule {
    static let searchUser = CRMModule(model: "Users", title: "利用者", singular: "利用者", entity: "user", nameFields: ["name", "email"], columns: [], fields: [
        EditorField("name", "氏名"), EditorField("email", "メール"), EditorField("username", "ユーザー名"),
        EditorField("role", "権限", .choice([("admin", "管理者"), ("manager", "マネージャー"), ("user", "利用者"), ("partner", "パートナー")])),
        EditorField("userStatus", "状態", .choice([("ACTIVE", "有効"), ("INACTIVE", "無効"), ("PENDING", "保留")])),
    ])
}
