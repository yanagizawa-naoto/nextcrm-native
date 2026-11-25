import AppKit

final class CampaignDispatchWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:720),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let campaignID: String
    private let table = NSTableView(); private let detail = NSTextView(); private let message = NSTextField(wrappingLabelWithString:""); private let info = NSTextField(labelWithString:"")
    private var buttons: [String:NSButton] = [:]; private var rows: [NativeJob] = []; private var offset = 0; private var total = 0
    private var busy = false; private var loading = false; private var refreshNeeded = false; private var generation = 0
    private var updates: CampaignJobUpdates?
    private var activeRunToken: String?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.campaign-dispatch-history"); private let memory = MemoryBudget()
    private let columns = [NativeColumn(title:"登録日時",fraction:0.24),NativeColumn(title:"処理",fraction:0.20),NativeColumn(title:"状態",fraction:0.18),NativeColumn(title:"実行・再試行予定",fraction:0.26),NativeColumn(title:"試行回数",fraction:0.12)]
    init(service: CRMService, campaignID: String) throws {
        self.service = service; self.campaignID = campaignID; let campaign = try service.campaign(campaignID); super.init(); window.title = "配信予約・処理履歴"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let name = NSTextField(labelWithString:campaign["name"].string); name.lineBreakMode = .byTruncatingTail
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("campaign-dispatch")); column.width = 980; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("配信予約と処理の一覧")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        detail.setAccessibilityLabel("配信予約の処理状況"); let details = InvoiceMailUI.textScroll(detail,height:150,editable:false)
        let actions = NSStackView(views:[button("retry","選択した処理を再試行",#selector(retry)),button("cancel","予約を取り消して全体停止…",#selector(cancel)),NSView(),button("refresh","再読み込み",#selector(refresh))]); actions.spacing = 8
        message.maximumNumberOfLines = 3; message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        let help = NSTextField(wrappingLabelWithString:"ここには初回配信とフォローアップの予約を表示します。宛先ごとの結果は「送信履歴」で確認できます。予約の取消は、準備済みの未送信メールを含めてキャンペーン全体を一時停止します。"); help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        let root = NSStackView(views:[title,name,header,scroll,actions,details,help,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200)])
        for view in [name,header,scroll,actions,details,help,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        updates = CampaignJobUpdates(db:service.db) { [weak self] in guard let self else { return }; if self.busy || self.loading || self.window.attachedSheet != nil { self.refreshNeeded = true } else { self.load() } }; load()
    }
    private func button(_ id: String,_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private var selected: NativeJob? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private static func date(_ value: String?) -> String { guard let value, let date = CampaignWorkflow.date(.text(value)) else { return "—" }; let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm:ss"; return f.string(from:date) }
    private static func name(_ job: NativeJob) -> String { [CampaignWorkflow.sendEvent:"初回配信",CampaignWorkflow.scheduleEvent:"初回の日時予約",CampaignWorkflow.followUpEvent:"フォローアップ"][job.event] ?? "配信処理" }
    private func inactive(_ job: NativeJob) -> Bool { ["pending","retry","failed"].contains(job.status) && (activeRunToken == nil || job.payload["runToken"] != activeRunToken) }
    private func state(_ job: NativeJob) -> String { if inactive(job) || job.result["outcome"] == "skipped" { return "変更・停止により対象外" }; return ["pending":"待機中","running":"実行中","retry":"再試行待ち","failed":"エラー","done":"処理済み","cancelled":"取消済み"][job.status] ?? "確認が必要" }
    private func nextDate(_ job: NativeJob) -> String { inactive(job) ? "—" : Self.date(job.nextRunAt) }
    private func controls() {
        let ready = !busy && !loading; buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready
        let job = selected, manage = ready && job.map{!inactive($0) && (try? service.campaignDispatchJobAccess($0.id)) == $0} == true
        buttons["retry"]?.isEnabled = manage && ["retry","failed"].contains(job?.status ?? "")
        buttons["cancel"]?.isEnabled = manage && ["pending","retry","failed"].contains(job?.status ?? "")
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
        guard let job else { detail.string = "処理を選択すると進行状況とエラーを表示します。"; return }
        var lines = ["処理："+Self.name(job),"状態："+state(job),"登録日時："+Self.date(job.createdAt),"実行・再試行予定："+nextDate(job),"試行回数：\(job.attempts)"]
        if inactive(job) { lines.append("停止・再開・再予約によって無効になった処理です。この予約からメールを送信することはありません。") }
        if let count = job.result["recipients"] { lines.append("抽出した宛先："+count+"件") }
        if let count = job.result["materialized"] { lines.append("送信予約を準備した宛先："+count+"件") }
        if let count = job.result["followups"] { lines.append("登録したフォローアップ："+count+"件") }
        if let reason = job.result["reason"] { lines.append(reason) }; if let error = job.lastError { lines.append(error) }
        detail.string = lines.joined(separator:"\n")
    }
    private func load() {
        refreshNeeded = false; generation += 1; let version = generation, start = offset, selection = selected?.id; loading = true; controls()
        queue.async { [weak self] in guard let self else { return }; let result = Result{try self.service.campaignDispatchJobs(self.campaignID,offset:start)}
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }
                switch result {
                case let .success(page): if page.rows.isEmpty && start > 0 { self.offset = max(0,(max(0,page.total-1)/100)*100); self.load(); return }; self.rows = page.rows; self.total = page.total; self.activeRunToken = page.activeRunToken
                case let .failure(error): self.rows = []; self.total = 0; self.activeRunToken = nil; self.message.stringValue = error.localizedDescription
                }
                self.table.reloadData(); if let index = self.rows.firstIndex(where:{$0.id == selection}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) } else { self.table.deselectAll(nil) }
                self.loading = false; self.controls(); self.memory.settle()
                if self.refreshNeeded && !self.busy && self.window.attachedSheet == nil { self.load() }
            }
        }
    }
    private func perform(_ operation: @escaping () throws -> Void) {
        guard !busy && !loading else { return }; busy = true; controls()
        queue.async { [weak self] in let result = Result{try operation()}; DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false; if case let .failure(error) = result { self.message.stringValue = error.localizedDescription }; self.load() } }
    }
    @objc private func retry() { guard !busy && !loading, window.attachedSheet == nil, let job = selected else { return }; perform { [service] in try service.retryCampaignDispatchJob(job) } }
    @objc private func cancel() {
        guard !busy && !loading, window.attachedSheet == nil, let job = selected else { return }
        let alert = NSAlert(); alert.messageText = "予約を取り消し、キャンペーン全体を停止しますか？"; alert.informativeText = "準備済みの未送信メールと、その後のフォローアップも停止します。送信サービスへ渡したメールは取り消せません。"; alert.addButton(withTitle:"予約を取り消して全体停止"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self else { return }; if response == .alertFirstButtonReturn { self.perform { [service = self.service] in try service.cancelCampaignDispatchJobAndPause(job) } } else if self.refreshNeeded { self.load() } }
    }
    func confirmDiscard() -> Bool { !busy }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; updates = nil; window.sheetParent?.endSheet(window) }
    @objc private func refresh() { guard !busy, window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard !busy && !loading else { return }; offset = max(0,offset-100); load() }
    @objc private func next() { guard !busy && !loading, offset+100 < total else { return }; offset += 100; load() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews{row,_ in row.subviews.forEach{$0.needsDisplay = true}} }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? { guard rows.indices.contains(row) else { return nil }; let job = rows[row], id = NSUserInterfaceItemIdentifier("dispatch-job-row"); let cell = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id; cell.configure(columns:columns,values:[Self.date(job.createdAt),Self.name(job),state(job),nextDate(job),String(job.attempts)]); return cell }
}
