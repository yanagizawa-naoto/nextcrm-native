import AppKit

final class CRMCampaignDeliveryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1080,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let campaignID: String
    private let table = NSTableView(); private let search = NSSearchField(); private let filter = NSPopUpButton()
    private let detail = NSTextView(); private let message = NSTextField(wrappingLabelWithString:""); private let info = NSTextField(labelWithString:"")
    private let syncInfo = NSTextField(wrappingLabelWithString:"")
    private var updates: CampaignJobUpdates?; private var refreshNeeded = false
    private var buttons: [String:NSButton] = [:]; private var rows: [CampaignDeliveryRow] = []
    private var offset = 0; private var total = 0; private var generation = 0; private var loading = false; private var busy = false
    private var pending: DispatchWorkItem?; private var reviewer: CRMJobReviewWindow?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.campaign-history"); private let memory = MemoryBudget()
    private static let states = ["queued","sending","sent","delivered","bounced","failed"]
    private static let names = ["queued":"送信待ち","sending":"送信中","sent":"受付済み","delivered":"到着確認済み","bounced":"不達","failed":"失敗・確認終了"]
    private let columns = [NativeColumn(title:"宛先",fraction:0.32),NativeColumn(title:"送信結果",fraction:0.20),NativeColumn(title:"処理状態",fraction:0.16),NativeColumn(title:"受付確認日時",fraction:0.18),NativeColumn(title:"開封",fraction:0.14)]
    init(service: CRMService, campaignID: String) throws {
        self.service = service; self.campaignID = campaignID; let campaign = try service.campaign(campaignID); super.init()
        window.title = "キャンペーンの送信履歴"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let name = NSTextField(labelWithString:campaign["name"].string); name.lineBreakMode = .byTruncatingTail
        search.placeholderString = "宛先を検索"; search.setAccessibilityLabel("送信履歴を検索"); search.delegate = self
        filter.addItems(withTitles:["すべての送信結果"]+Self.states.map{Self.names[$0]!}); filter.setAccessibilityLabel("送信履歴の状態"); filter.target = self; filter.action = #selector(filterChanged)
        let filters = NSStackView(views:[search,filter,button("sync","配信結果を同期",#selector(synchronize)),button("refresh","再読み込み",#selector(refresh))]); filters.spacing = 8; search.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("deliveries")); column.width = 1020; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("メール送信先の履歴")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        detail.setAccessibilityLabel("選択したメールの送信記録"); let details = InvoiceMailUI.textScroll(detail,height:170,editable:false)
        let actions = NSStackView(views:[button("retry","選択したメールを再試行",#selector(retry)),button("cancel","送信を取り消す…",#selector(cancel)),button("review","送信結果を確認…",#selector(review)),NSView()]); actions.spacing = 8
        message.font = .systemFont(ofSize:12); message.maximumNumberOfLines = 2; message.textColor = .secondaryLabelColor
        syncInfo.font = .systemFont(ofSize:12); syncInfo.maximumNumberOfLines = 2; syncInfo.textColor = .secondaryLabelColor; syncInfo.setAccessibilityLabel("配信結果の同期状況")
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        let root = NSStackView(views:[title,name,filters,syncInfo,header,scroll,actions,details,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200)])
        for view in [name,filters,syncInfo,header,scroll,actions,details,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        updates = CampaignJobUpdates(db:service.db) { [weak self] in guard let self else { return }; if self.loading || self.busy || self.window.attachedSheet != nil { self.refreshNeeded = true } else { self.load(delay:0.1) } }
        load()
    }
    private func button(_ id: String,_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private var selected: CampaignDeliveryRow? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private static func date(_ value: String?) -> String {
        guard let value, let date = CampaignWorkflow.date(.text(value)) else { return "—" }
        let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm:ss"; return f.string(from:date)
    }
    private static func result(_ row: CampaignDeliveryRow) -> String {
        if let outcome = row.job?.result["reviewOutcome"] { return ["accepted":"受付確認済み","notSent":"未送信確認済み","unknown":"結果不明・終了"][outcome] ?? "不明" }
        if row.job?.result["cancelledBy"] != nil { return "取消済み" }
        return names[row.send["status"].string] ?? "不明"
    }
    private static func jobStatus(_ job: NativeJob?) -> String {
        guard let job else { return "過去の記録" }
        if job.result["outcome"] == "skipped" { return "送信対象外" }
        return ["pending":"待機中","running":"実行中","retry":"再試行待ち","needs_review":"結果確認が必要","failed":"エラー","done":"終了","cancelled":"取消済み"][job.status] ?? "不明"
    }
    private func controls() {
        let ready = !loading && !busy; buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready; search.isEnabled = !busy; filter.isEnabled = !busy
        buttons["sync"]?.isEnabled = ready && service.identity.elevated
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
        let job = selected?.job, manage = ready && job.map{(try? service.campaignMailJobAccess($0.id)) == $0} == true
        let inWindow = job?.deliveryStartedAt.map { Date() >= $0 && Date().timeIntervalSince($0) < 23*3600 } ?? true
        buttons["retry"]?.isEnabled = manage && ["failed","retry"].contains(job?.status ?? "") && job?.result["relayProviderIDHint"] == nil && (job?.result["providerID"] != nil || inWindow)
        buttons["cancel"]?.isEnabled = manage && ["pending","retry","failed"].contains(job?.status ?? "") && job?.deliveryStartedAt == nil && job?.result["providerID"] == nil && job?.result["relayProviderIDHint"] == nil
        buttons["review"]?.isEnabled = manage && job?.canReviewMail == true
        guard let row = selected else { detail.string = "メールを選択すると、送信結果と確認記録を表示します。"; return }
        var lines = ["宛先："+row.send["email"].string,"送信結果："+Self.result(row),"配達状態："+(Self.names[row.send["status"].string] ?? "不明"),"処理状態："+Self.jobStatus(job)]
        for (label,key) in [("件名","subject"),("差出人","from"),("受付ID","providerID"),("受信窓口に残る未確認の受付ID","relayProviderIDHint"),("確認した内容","reviewNote"),("確認した利用者","reviewerName")] { if let text = job?.result[key], !text.isEmpty { lines.append(label+"："+text) } }
        for (label,key) in [("受付確認","sent_at"),("開封","opened_at"),("クリック","clicked_at"),("配信停止","unsubscribed_at")] { lines.append(label+"："+Self.date(row.send[key] == .null ? nil : row.send[key].string)) }
        if let job {
            lines.append("送信サービスの処理ID：campaign-send/"+job.id); lines.append("試行回数：\(job.attempts)")
            if let stamp = job.result["reviewedAt"] { lines.append("確認記録日時："+Self.date(stamp)) }
            if let stamp = job.nextRunAt { lines.append("次回の試行："+Self.date(stamp)) }
            for error in [job.lastError,job.result["reviewPreviousError"],row.send["error_message"] == .null ? nil : row.send["error_message"].string].compactMap({$0}) { lines.append(error) }
        }
        detail.string = lines.joined(separator:"\n")
    }
    private func load(delay: Double = 0) {
        refreshNeeded = false
        pending?.cancel(); generation += 1; let version = generation, start = offset, term = search.stringValue, status = filter.indexOfSelectedItem == 0 ? nil : Self.states[filter.indexOfSelectedItem-1], selection = selected?.send["id"].string
        loading = true; controls()
        let work = DispatchWorkItem { [weak self] in guard let self else { return }; let result = Result{try self.service.campaignDeliveries(self.campaignID,search:term,status:status,offset:start)}
            let sync = Result{try self.service.campaignSynchronizationStatus(self.campaignID)}
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }
                switch result {
                case let .success(page):
                    if page.rows.isEmpty && start > 0 { self.offset = max(0,(max(0,page.total-1)/100)*100); self.load(); return }
                    self.rows = page.rows; self.total = page.total
                case let .failure(error): self.rows = []; self.total = 0; self.message.stringValue = error.localizedDescription
                }
                switch sync {
                case let .success(state):
                    let status = state.configured ? (["pending":"待機中","running":"同期中","retry":"再試行待ち","failed":"同期失敗","done":"同期完了"][state.latest?.status ?? ""] ?? "未同期") : "受信窓口が未設定"
                    self.syncInfo.stringValue = "受信窓口の同期："+status+"　最終同期："+Self.date(state.lastSuccess)
                    if let error = state.latest?.lastError { self.syncInfo.stringValue += "\n"+error }
                case let .failure(error): self.syncInfo.stringValue = error.localizedDescription
                }
                self.table.reloadData()
                if let index = self.rows.firstIndex(where:{$0.send["id"].string == selection}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) } else { self.table.deselectAll(nil) }
                self.loading = false; self.controls(); self.memory.settle()
                if self.refreshNeeded && !self.busy && self.window.attachedSheet == nil { self.load(delay:0.1) }
            }
        }; pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func perform(_ work: @escaping () throws -> Void) {
        guard !busy && !loading else { return }; busy = true; controls()
        queue.async { [weak self] in let result = Result{try work()}; DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false; if case let .failure(error) = result { self.message.stringValue = error.localizedDescription }; self.load() } }
    }
    @objc private func retry() { guard !busy && !loading, window.attachedSheet == nil, let job = selected?.job else { return }; perform { [service] in try service.retryCampaignMailJob(job) } }
    @objc private func synchronize() { guard !busy && !loading, window.attachedSheet == nil else { return }; perform { [service,campaignID] in try service.synchronizeCampaignResults(campaignID) } }
    @objc private func cancel() {
        guard !busy && !loading, window.attachedSheet == nil, let row = selected, let job = row.job else { return }
        let alert = NSAlert(); alert.messageText = "この宛先への送信を取り消しますか？"; alert.informativeText = row.send["email"].string+"\nキャンペーンを再開しても、このメールは送信しません。"; alert.addButton(withTitle:"送信を取り消す"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in try service.cancelCampaignMailJob(job) } }
    }
    @objc private func review() {
        guard !busy && !loading, window.attachedSheet == nil, let job = selected?.job, job.canReviewMail else { return }
        let controller = CRMJobReviewWindow(service:service,job:job); reviewer = controller
        window.beginSheet(controller.window) { [weak self] _ in self?.reviewer = nil; self?.load() }
    }
    func confirmDiscard() -> Bool { !busy && reviewer?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; pending?.cancel(); window.sheetParent?.endSheet(window) }
    func controlTextDidChange(_ notification: Notification) { offset = 0; load(delay:0.15) }
    @objc private func filterChanged() { offset = 0; load() }
    @objc private func refresh() { guard !busy && window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard !loading && !busy else { return }; offset = max(0,offset-100); load() }
    @objc private func next() { guard !loading && !busy, offset+100 < total else { return }; offset += 100; load() }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { row,_ in row.subviews.forEach{$0.needsDisplay = true} } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row], id = NSUserInterfaceItemIdentifier("campaign-delivery-row")
        let cell = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        cell.configure(columns:columns,values:[item.send["email"].string,Self.result(item),Self.jobStatus(item.job),Self.date(item.send["sent_at"].string),item.send["opened_at"] == .null ? "未確認" : "開封確認済み"]); return cell
    }
}
