import AppKit

final class GoogleCalendarSettingsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    typealias Authorize = (GoogleCalendarClientSettings,GoogleCalendarScope,String?) async throws -> GoogleCalendarGrant
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:730),styleMask:[.titled],backing:.buffered,defer:false)
    private let allowsProcessing:Bool
    private let distributionClient: () throws -> NativeDistributionConfiguration.GoogleClient?
    private let configurationInfo = NSTextField(wrappingLabelWithString:"")
    private var advanced: NSStackView?, clientAvailable = false
    private let service: CRMService; private let store: GoogleCalendarSecretStore; private let authorize: Authorize
    private let clientID = NSTextField(), clientSecret = NSSecureTextField(), message = NSTextField(wrappingLabelWithString:"")
    private let info = NSTextField(labelWithString:""), table = NSTableView()
    private let syncInfo = NSTextField(wrappingLabelWithString:"")
    private var jobs: [String:NativeJob] = [:], observer: NSObjectProtocol?
    private var savedClientID = "", rows: [NativeRecord] = [], buttons: [String:NSButton] = [:]
    private var offset = 0, total = 0, generation = 0
    private var busy = false, loading = false
    private var task: Task<Void,Never>?
    private var pushHistory: GoogleCalendarPushWindow?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.calendar-settings")
    private let columns = [NativeColumn(title:"Googleアカウント",fraction:0.37),NativeColumn(title:"許可された権限",fraction:0.23),NativeColumn(title:"接続状態",fraction:0.17),NativeColumn(title:"最終同期",fraction:0.23)]
    var onConnected: (() -> Void)?
    static func browser(client: GoogleCalendarClientSettings, scope: GoogleCalendarScope, hint: String?) async throws -> GoogleCalendarGrant {
        try await GoogleCalendarBrowserAuthorization.run(client:client,scope:scope,loginHint:hint,open:{ url in
            try await MainActor.run { guard NSWorkspace.shared.open(url) else { throw NativeDBError.message("Google認証のブラウザを開けませんでした。") } }
        })
    }
    init(service: CRMService, store: GoogleCalendarSecretStore, authorize: @escaping Authorize = GoogleCalendarSettingsWindow.browser,allowsProcessing:Bool = true, distributionClient: @escaping () throws -> NativeDistributionConfiguration.GoogleClient? = { try NativeDistributionConfiguration.googleClient() }) throws {
        try service.authenticated(); self.service = service; self.store = store; self.authorize = authorize; self.allowsProcessing = allowsProcessing; self.distributionClient = distributionClient
        let reference = try service.googleCalendarClientReference(); savedClientID = reference?.clientID ?? ""
        super.init(); window.title = "Googleカレンダーの接続"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"Googleアカウントごとに、カレンダーへのアクセスを設定します。認証は通常のブラウザで行い、認証情報はこのMacのキーチェーンに保存します。")
        clientID.stringValue = savedClientID; clientID.placeholderString = "デスクトップアプリ用クライアントID"; clientID.setAccessibilityLabel("GoogleクライアントID")
        clientSecret.placeholderString = reference == nil ? "クライアントシークレット（発行されている場合）" : "保存済み・変更する場合だけ入力"; clientSecret.setAccessibilityLabel("Googleクライアントシークレット")
        let appHelp = NSTextField(wrappingLabelWithString:"自分でビルドする場合や別のOAuthアプリを使う場合だけ設定します。Google Cloudの「デスクトップアプリ」用クライアントが必要です。保存済みの詳細設定は、配布版の設定より優先されます。")
        appHelp.font = .systemFont(ofSize:12); appHelp.textColor = .secondaryLabelColor
        let saveRow = NSStackView(views:[NSView(),button("save","アプリ設定を保存",#selector(saveClient))])
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("calendar-connection")); column.width = 1000; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("自分のGoogleカレンダー接続")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        let connect = NSStackView(views:[button("read","Google にログイン…",#selector(connectRead)),button("write","予定の編集も許可してログイン…",#selector(connectWrite)),button("reauth","選択した接続を認証し直す…",#selector(reauth)),button("disconnect","接続を削除…",#selector(disconnect))]); connect.spacing = 8
        let note = NSTextField(wrappingLabelWithString:"認証し直すときは現在の権限を要求し、Googleが実際に許可した権限を保存します。接続を削除しても、取り込んだCRMの活動は残ります。")
        note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3; message.setAccessibilityLabel("カレンダー接続の結果")
        let footer = NSStackView(views:[info,NSView(),button("cancel","認証を中止",#selector(cancelAuthorization)),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("reload","再読み込み",#selector(reload)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        var content: [NSView] = [title,help]
        configurationInfo.setAccessibilityLabel("Googleログインの利用状況"); configurationInfo.textColor = .secondaryLabelColor
        content.append(configurationInfo)
        if service.identity.role == "admin" {
            let details = NSStackView(views:[appHelp,InvoiceMailUI.row("クライアントID",clientID),InvoiceMailUI.row("シークレット",clientSecret),saveRow])
            details.orientation = .vertical; details.alignment = .leading; details.spacing = 8; details.isHidden = true; advanced = details
            for row in details.views { row.widthAnchor.constraint(equalTo:details.widthAnchor).isActive = true }
            content += [button("advanced","詳細設定（開発者向け）…",#selector(toggleAdvanced)),details]
        }
        syncInfo.maximumNumberOfLines = 3; syncInfo.setAccessibilityLabel("選択したカレンダーの同期状況"); syncInfo.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let syncRow = NSStackView(views:[button("sync","選択した接続を同期",#selector(synchronize)),button("pushHistory","Googleへの反映履歴…",#selector(openPushHistory)),syncInfo]); syncRow.spacing = 12
        content += [header,scroll,connect,syncRow,note,message,footer]; InvoiceMailUI.layout(window,content)
        clientID.setAccessibilityLabel("GoogleクライアントID"); clientSecret.setAccessibilityLabel("Googleクライアントシークレット"); refreshClientReadiness(); load()
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] notification in
            guard let self, notification.userInfo?["database"] as? String == self.service.db.url.path, !self.busy, self.window.attachedSheet == nil else { return }; self.load()
        }
    }
    deinit { task?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func button(_ key: String,_ title: String,_ action: Selector) -> NSButton { let b = InvoiceMailUI.button(title,target:self,action:action); buttons[key] = b; return b }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func controls() {
        let ready = !busy && !loading
        buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready; clientID.isEnabled = ready; clientSecret.isEnabled = ready
        buttons["read"]?.isEnabled = ready && clientAvailable; buttons["write"]?.isEnabled = ready && clientAvailable
        buttons["cancel"]?.isEnabled = busy; buttons["reauth"]?.isEnabled = ready && clientAvailable && selected != nil; buttons["disconnect"]?.isEnabled = ready && selected != nil
        let job = selected.flatMap{jobs[$0["id"].string]}
        buttons["pushHistory"]?.isEnabled = allowsProcessing && ready
        buttons["sync"]?.isEnabled = allowsProcessing && ready && selected?["isActive"] == .integer(1) && !["running","pending"].contains(job?.status ?? "")
        if let selected { syncInfo.stringValue = Self.syncTitle(job)+((selected["lastSyncError"].string.isEmpty) ? "" : "："+selected["lastSyncError"].string) }
        else { syncInfo.stringValue = "予定を取り込む接続を選択してください。アプリ起動中は約15分ごとに同期します。" }
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
    }
    private func load() {
        generation += 1; let version = generation, start = offset, selectedID = selected?["id"].string; loading = true; controls()
        queue.async { [weak self] in guard let self else { return }; let result = Result { () -> (rows:[NativeRecord],total:Int,jobs:[String:NativeJob]) in
            let page = try self.service.googleCalendarConnections(offset:start); var jobs: [String:NativeJob] = [:]
            for row in page.rows { if let job = try self.service.googleCalendarSyncJob(row["id"].string) { jobs[row["id"].string] = job } }
            return (page.rows,page.total,jobs)
        }
            DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }
                switch result {
                case let .success(page):if page.rows.isEmpty && start > 0 { self.offset = max(0,((max(0,page.total-1))/100)*100); self.load(); return }; self.rows = page.rows; self.total = page.total; self.jobs = page.jobs
                case let .failure(error):self.rows = []; self.total = 0; self.jobs = [:]; self.show(error.localizedDescription,error:true)
                }
                self.table.reloadData(); if let index = self.rows.firstIndex(where:{$0["id"].string == selectedID}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }; self.loading = false; self.refreshClientReadiness(); self.controls()
            }
        }
    }
    private func refreshClientReadiness() {
        do {
            if try service.googleCalendarClientReference() != nil {
                clientAvailable = true; configurationInfo.stringValue = "詳細設定に保存したGoogleアプリを使用します。ログイン後にカレンダーを接続します。"
            } else if try distributionClient() != nil {
                clientAvailable = true; configurationInfo.stringValue = "Google にログインしてカレンダーを接続します。通常は読み取りのみで利用できます。"
            } else {
                clientAvailable = false; configurationInfo.stringValue = "この配布版ではGoogleログインをまだ利用できません。アプリの配布元に確認してください。"
            }
        } catch { clientAvailable = false; configurationInfo.stringValue = error.localizedDescription }
    }
    @objc private func toggleAdvanced() {
        guard !busy && !loading, service.identity.role == "admin", let advanced else { return }
        advanced.isHidden.toggle(); buttons["advanced"]?.title = advanced.isHidden ? "詳細設定（開発者向け）…" : "詳細設定を閉じる"
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func show(_ text: String,error: Bool = false) { message.stringValue = text; message.textColor = error ? .systemRed : .secondaryLabelColor }
    @objc private func saveClient() {
        guard !busy && !loading else { return }
        do { try service.saveGoogleCalendarClient(clientID:clientID.stringValue,clientSecret:clientSecret.stringValue,store:store); savedClientID = clientID.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); clientID.stringValue = savedClientID; clientSecret.stringValue = ""; clientSecret.placeholderString = "保存済み・変更する場合だけ入力"; show("Googleのアプリ設定を保存しました。"); refreshClientReadiness(); controls() }
        catch { show(error.localizedDescription,error:true) }
    }
    private func connect(scope: GoogleCalendarScope, expected: NativeRecord?) {
        guard !busy && !loading else { return }
        do {
            let ticket = try service.beginGoogleCalendarAuthorization(expected:expected,requested:scope,store:store,distributionClient:distributionClient)
            busy = true; show("ブラウザでGoogleへのアクセスを許可してください。完了すると、この画面に接続を表示します。"); controls()
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { try? self.service.cancelGoogleCalendarAuthorization(ticket); self.task = nil; self.busy = false; self.load() }
                do {
                    let grant = try await self.authorize(ticket.client,ticket.requested,ticket.expected?["accountEmail"].string)
                    try Task.checkCancellation()
                    let row = try self.service.completeGoogleCalendarAuthorization(ticket,grant:grant,store:self.store)
                    self.show(row["accountEmail"].string+" を接続しました。（"+grant.scope.title+"）"); self.onConnected?()
                } catch { self.show(error is CancellationError ? "認証を中止しました。接続は変更していません。" : error.localizedDescription,error:!(error is CancellationError)) }
            }
        } catch { show(error.localizedDescription,error:true) }
    }
    @objc private func connectRead() { connect(scope:.readonly,expected:nil) }
    @objc private func connectWrite() { connect(scope:.readwrite,expected:nil) }
    @objc private func reauth() { guard let selected else { return }; connect(scope:GoogleCalendarScope(rawValue:selected["scopeLevel"].string) ?? .readonly,expected:selected) }
    @objc private func cancelAuthorization() { task?.cancel() }
    @objc private func openPushHistory() {
        guard allowsProcessing else {show("カレンダーの同期は再開の確認待ちです。",error:true);return}
        guard !busy && !loading, window.attachedSheet == nil else { return }
        do {
            let history = try GoogleCalendarPushWindow(service:service); pushHistory = history
            window.beginSheet(history.window) { [weak self] _ in self?.pushHistory = nil; self?.load() }
        } catch { show(error.localizedDescription,error:true) }
    }
    @objc private func synchronize() {
        guard allowsProcessing else {show("カレンダーの同期は再開の確認待ちです。",error:true);return}
        guard !busy && !loading, window.attachedSheet == nil, let selected else { return }
        do { _ = try service.requestGoogleCalendarSync(selected); show("カレンダーの同期を受け付けました。"); load() }
        catch { show(error.localizedDescription,error:true); load() }
    }
    private static func syncTitle(_ job: NativeJob?) -> String {
        switch job?.status { case "pending":return "同期待ち"; case "running":return "同期中"; case "retry":return "再試行待ち"; case "done":return "同期完了"; case "failed":return "同期エラー"; default:return "未同期" }
    }
    @objc private func disconnect() {
        guard !busy && !loading, window.attachedSheet == nil, let row = selected else { return }
        let alert = NSAlert(); alert.messageText = "Googleカレンダーの接続を削除しますか？"; alert.informativeText = row["accountEmail"].string+" の同期を停止し、このMacに保存した認証情報を削除します。CRMの活動は残ります。"; alert.addButton(withTitle:"接続を削除"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; do { try self.service.disconnectGoogleCalendar(row,store:self.store); self.show("カレンダーの接続を削除しました。") } catch { self.show(error.localizedDescription,error:true) }; self.load() }
    }
    func confirmDiscard() -> Bool { !busy && window.attachedSheet == nil && ((clientID.stringValue == savedClientID && clientSecret.stringValue.isEmpty) || InvoiceMailUI.discard("Googleのアプリ設定の変更を保存せずに閉じますか？")) }
    @objc private func close() { guard window.attachedSheet == nil else { return }; if busy { task?.cancel(); return }; guard confirmDiscard() else { return }; generation += 1; window.sheetParent?.endSheet(window) }
    @objc private func reload() { guard !busy, window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard !busy && !loading else { return }; offset = max(0,offset-100); load() }
    @objc private func next() { guard !busy && !loading && offset+100 < total else { return }; offset += 100; load() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews{row,_ in row.subviews.forEach{$0.needsDisplay = true}} }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row], id = NSUserInterfaceItemIdentifier("google-calendar-row")
        let cell = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        var last = "未同期"; if let date = try? NativeCalendarEvents.date(record["lastSyncedAt"].string) { let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"; last = f.string(from:date) }
        cell.configure(columns:columns,values:[record["accountEmail"].string,GoogleCalendarScope(rawValue:record["scopeLevel"].string)?.title ?? "確認が必要",record["isActive"] == .integer(1) ? Self.syncTitle(jobs[record["id"].string]) : "再接続が必要",last]); return cell
    }
}
