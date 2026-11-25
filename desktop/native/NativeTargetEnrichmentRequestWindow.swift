import AppKit

final class NativeTargetEnrichmentRequestWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSPanel
    private let api: NativeTargetEnrichmentService, targetID: String?
    private let fieldsTable = NSTableView(), targetsTable = NSTableView(), search = NSSearchField(), scenario = NSPopUpButton(), mode = NSPopUpButton()
    private let summary = NSTextField(labelWithString: ""), page = NSTextField(labelWithString: ""), message = NativeEnrichmentUI.label(""), help = NativeEnrichmentUI.label("")
    private let force = NSButton(checkboxWithTitle: "過去7日以内の取得済み対象も調べ直す", target: nil, action: nil)
    private var fields: [NativeEnrichmentField] = [], selectedFields = Set<String>(), targets: [NativeRecord] = [], selectedTargets = Set<String>(), offset = 0, total = 0
    private var previous: NSButton!, next: NSButton!, start: NSButton!
    private(set) var requestedIDs: [String] = []
    var onSettings: ((NSWindow) -> Void)?
    init(api: NativeTargetEnrichmentService, targetID: String? = nil) throws {
        try api.internalAccess(); self.api = api; self.targetID = targetID
        let record = try targetID.map(api.target)
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 690), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(); window.title = targetID == nil ? "営業先の一括情報補完" : "営業先の情報補完"
        scenario.addItems(withTitles: ["本人の情報", "会社の情報"]); scenario.selectItem(at: record?.values["email"]?.string.isEmpty == false ? 0 : 1)
        scenario.setAccessibilityLabel("営業先の調査対象"); scenario.target = self; scenario.action = #selector(changeScenario)
        mode.addItems(withTitles: ["確認してから反映", "空欄へ自動反映"]); mode.selectItem(at: targetID == nil ? 1 : 0); mode.isEnabled = targetID != nil
        mode.setAccessibilityLabel("営業先の情報反映方法"); mode.target = self; mode.action = #selector(changeMode)
        fieldsTable.dataSource = self; fieldsTable.delegate = self; targetsTable.dataSource = self; targetsTable.delegate = self
        var views: [NSView] = [NativeEnrichmentUI.label(window.title, title: true)]
        if let record { views.append(NativeEnrichmentUI.label(CRMModule.displayName(record) + "  " + record["company"].string + "  " + record["email"].string)) }
        views += [NativeEnrichmentUI.row([scenario, mode, NSView()]), help]
        let fieldColumn = NativeEnrichmentUI.column([NativeEnrichmentUI.label("調べる項目"), NativeEnrichmentUI.table(fieldsTable, label: "営業先の補完項目", columns: [("check", "選択", 40), ("name", "項目", 170), ("description", "調査内容", targetID == nil ? 260 : 710)], height: 300)])
        if targetID == nil {
            search.placeholderString = "氏名・会社名・メールで検索"; search.setAccessibilityLabel("補完する営業先を検索"); search.target = self; search.action = #selector(findTargets)
            previous = button("前へ", #selector(back)); next = button("次へ", #selector(forward))
            let targetColumn = NativeEnrichmentUI.column([search, NativeEnrichmentUI.table(targetsTable, label: "補完する営業先", columns: [("check", "選択", 40), ("name", "氏名", 120), ("company", "会社名", 120), ("email", "メール", 140)], height: 230),
                NativeEnrichmentUI.row([page, NSView(), previous, next]), NativeEnrichmentUI.row([button("このページを選択", #selector(selectPage)), button("営業先の選択を解除", #selector(clearTargets))])])
            targetColumn.widthAnchor.constraint(equalToConstant: 452).isActive = true
            let row = NativeEnrichmentUI.row([targetColumn, fieldColumn]); row.alignment = .top; row.distribution = .fill; views.append(row)
        } else { views.append(fieldColumn) }
        summary.setAccessibilityLabel("営業先情報補完の選択件数"); message.setAccessibilityLabel("営業先情報補完の予約結果"); message.maximumNumberOfLines = 2
        help.maximumNumberOfLines = 3; force.setAccessibilityLabel(force.title)
        start = button("情報補完を開始", #selector(begin)); let close = button("閉じる", #selector(close)); close.keyEquivalent = "\u{1b}"
        views += [force, summary, message, NativeEnrichmentUI.row([button("AI連携の設定…", #selector(settings)), NSView(), close, start])]
        NativeEnrichmentUI.layout(window, views); resetFields()
        if targetID == nil { try loadTargets() }; selection()
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NativeEnrichmentUI.button(title, target: self, action: action) }
    private var chosenScenario: NativeTargetEnrichment.Scenario { scenario.indexOfSelectedItem == 0 ? .personal : .company }
    private var chosenMode: NativeTargetEnrichment.Mode { targetID == nil ? .bulk : mode.indexOfSelectedItem == 0 ? .review : .automatic }
    private func resetFields() {
        let personal = chosenScenario == .personal
        let names = personal ? NativeTargetEnrichment.personalNames : NativeTargetEnrichment.companyNames + ["social_x", "social_instagram", "social_facebook"]
        fields = NativeTargetEnrichment.fields(names, scenario: chosenScenario)
        selectedFields = Set(personal ? NativeTargetEnrichment.personalDefaults : chosenMode == .review ? NativeTargetEnrichment.companyDefaults : NativeTargetEnrichment.automaticNames)
        fieldsTable.reloadData(); selection()
    }
    private func selection() {
        force.isEnabled = chosenMode != .review
        help.stringValue = chosenMode == .review
            ? "取得後に現在の値と比較し、反映する項目を選べます。OpenAIとFirecrawlに氏名・メール・会社情報と調査項目を送り、API利用料が発生します。"
            : "最大100件を選択できます。取得した営業先情報は空欄に反映し、見つかった担当者を追加・更新します。AnthropicとE2Bに調査情報を送り、API・実行環境の利用料が発生します。"
        summary.stringValue = "営業先 \(targetID == nil ? selectedTargets.count : 1)件 ／ 調査項目 \(selectedFields.count)件"
        start.isEnabled = requestedIDs.isEmpty && !selectedFields.isEmpty && (targetID != nil || !selectedTargets.isEmpty)
    }
    private func loadTargets() throws {
        let value = try api.targetsPage(search: search.stringValue, offset: offset); total = value.total
        if value.rows.isEmpty && offset > 0 { offset = max(0, ((max(1, total) - 1) / 100) * 100); return try loadTargets() }
        targets = value.rows; targetsTable.reloadData(); page.stringValue = "\(total == 0 ? 0 : offset + 1)–\(offset + targets.count) ／ \(total)件"
        previous.isEnabled = offset > 0; next.isEnabled = offset + targets.count < total
    }
    private func reloadTargets() { do { try loadTargets() } catch { targets = []; targetsTable.reloadData(); NativeEnrichmentUI.message(message, error) } }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === fieldsTable ? fields.count : targets.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let field = tableView === fieldsTable; guard row >= 0, row < (field ? fields.count : targets.count) else { return nil }
        if column?.identifier.rawValue == "check" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: field ? #selector(toggleField(_:)) : #selector(toggleTarget(_:))); button.tag = row
            button.state = (field ? selectedFields.contains(fields[row].name) : selectedTargets.contains(targets[row]["id"].string)) ? .on : .off
            button.setAccessibilityLabel((field ? fields[row].displayName : CRMModule.displayName(targets[row])) + "を選択"); return button
        }
        if field { return NativeEnrichmentUI.cell(column?.identifier.rawValue == "name" ? fields[row].displayName : fields[row].description) }
        return NativeEnrichmentUI.cell(column?.identifier.rawValue == "name" ? CRMModule.displayName(targets[row]) : targets[row][column?.identifier.rawValue ?? "email"].string)
    }
    @objc private func toggleField(_ button: NSButton) { guard fields.indices.contains(button.tag) else { return }; let key = fields[button.tag].name; if button.state == .on { selectedFields.insert(key) } else { selectedFields.remove(key) }; selection() }
    @objc private func toggleTarget(_ button: NSButton) {
        guard targets.indices.contains(button.tag) else { return }; let id = targets[button.tag]["id"].string
        if button.state == .on && selectedTargets.count >= 100 { button.state = .off; NativeEnrichmentUI.message(message, NativeAIError(message: "一度に選択できる営業先は100件までです。")); return }
        if button.state == .on { selectedTargets.insert(id) } else { selectedTargets.remove(id) }; selection()
    }
    @objc private func selectPage() { let ids = Set(targets.map { $0["id"].string }); guard selectedTargets.union(ids).count <= 100 else { NativeEnrichmentUI.message(message, NativeAIError(message: "選択済みの営業先と合わせて100件を超えます。選択を解除するか個別に選んでください。")); return }; selectedTargets.formUnion(ids); targetsTable.reloadData(); selection() }
    @objc private func clearTargets() { selectedTargets.removeAll(); targetsTable.reloadData(); selection() }
    @objc private func changeScenario() { resetFields() }
    @objc private func changeMode() { if chosenMode == .automatic { scenario.selectItem(at: 1) }; resetFields() }
    @objc private func findTargets() { offset = 0; reloadTargets() }
    @objc private func back() { offset = max(0, offset - 100); reloadTargets() }
    @objc private func forward() { offset += 100; reloadTargets() }
    @objc private func settings() { onSettings?(window) }
    @objc private func begin() {
        guard requestedIDs.isEmpty else { return }
        do { requestedIDs = try api.request(targetIDs: targetID.map { [$0] } ?? selectedTargets.sorted(), fields: fields.filter { selectedFields.contains($0.name) }, mode: chosenMode, force: chosenMode != .review && force.state == .on); selection(); NativeEnrichmentUI.close(window) }
        catch { NativeEnrichmentUI.message(message, error) }
    }
    @objc private func close() { NativeEnrichmentUI.close(window) }
}
