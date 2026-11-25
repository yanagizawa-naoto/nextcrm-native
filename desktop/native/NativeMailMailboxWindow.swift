import AppKit

/// Header pages never contain message bodies. Only the current selection owns a
/// decoded body, and queued selections are cancellable before they read SQLite.
final class NativeMailMailboxWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1100,height:760),styleMask:[.titled],backing:.buffered,defer:false)
    private let service:CRMService, context:NativeMailListScope
    private let table = NSTableView(), body = NSTextView(), search = NSSearchField(), folder = NSPopUpButton()
    private let unread = NSButton(checkboxWithTitle:"未読のみ",target:nil,action:nil)
    private let message = NSTextField(wrappingLabelWithString:""), info = NSTextField(labelWithString:"")
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.mailbox")
    private var rows:[NativeRecord] = [], buttons:[String:NSButton] = [:], selectedMessage:NativeRecord?
    private var offset = 0, total = 0, generation = 0, detailGeneration = 0, loading = false, detailLoading = false, bodyLoaded = false, closed = false
    private var listCancellation:NativeMailCancellation?, detailCancellation:NativeMailCancellation?, searchWork:DispatchWorkItem?
    private var observer:NSObjectProtocol?, composer:NativeMailComposeWindow?, history:NativeMailHistoryWindow?
    private var htmlViewer:NativeMailHTMLViewing?
    private let makeHTMLViewer:(NativeMailHTMLDocument,@escaping () -> Void) throws -> NativeMailHTMLViewing
    private var showingDetailMessage = false
    private var columns:[NativeColumn] {
        context.isCRM ? [NativeColumn(title:"状態",fraction:0.06),NativeColumn(title:"フォルダ",fraction:0.09),NativeColumn(title:"差出人",fraction:0.22),NativeColumn(title:"件名",fraction:0.41),NativeColumn(title:"日時",fraction:0.22)] : [NativeColumn(title:"状態",fraction:0.07),NativeColumn(title:"差出人",fraction:0.24),NativeColumn(title:"件名",fraction:0.47),NativeColumn(title:"日時",fraction:0.22)]
    }
    var onChanged:(() -> Void)?
    convenience init(service:CRMService,accountID:String,makeHTMLViewer:@escaping (NativeMailHTMLDocument,@escaping () -> Void) throws -> NativeMailHTMLViewing = { try NativeMailHTMLSession(document:$0,onFailure:$1) }) throws {
        try self.init(service:service,context:.account(accountID),makeHTMLViewer:makeHTMLViewer)
    }
    init(service:CRMService,context:NativeMailListScope,makeHTMLViewer:@escaping (NativeMailHTMLDocument,@escaping () -> Void) throws -> NativeMailHTMLViewing = { try NativeMailHTMLSession(document:$0,onFailure:$1) }) throws {
        self.service = service; self.context = context; self.makeHTMLViewer = makeHTMLViewer; let heading = try service.mailListTitle(context)
        super.init(); window.title = heading
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        title.lineBreakMode = .byTruncatingTail; title.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        folder.addItems(withTitles:(context.isCRM ? ["すべてのフォルダ"] : [])+["受信トレイ","送信済み"]); folder.setAccessibilityLabel("メールのフォルダ"); folder.target = self; folder.action = #selector(filterChanged)
        unread.target = self; unread.action = #selector(filterChanged)
        search.placeholderString = "件名・差出人を検索（3文字以上）"; search.setAccessibilityLabel("メールを検索"); search.delegate = self; search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant:320).isActive = true
        let filters = NSStackView(views:[folder,unread,search,button("compose","メールを作成…",#selector(compose)),button("history","送信履歴…",#selector(openHistory))]); filters.spacing = 10
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("mailbox")); column.width = 1060; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 34; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("メールの一覧")
        let list = NSScrollView(); list.hasVerticalScroller = true; list.documentView = table; list.heightAnchor.constraint(greaterThanOrEqualToConstant:210).isActive = true
        let preview = InvoiceMailUI.textScroll(body,height:240,editable:false); body.setAccessibilityLabel("選択したメールの本文")
        let actions = NSStackView(views:[button("reply","返信…",#selector(reply)),button("forward","転送…",#selector(forward)),button("html","HTMLで表示…",#selector(openHTML)),button("body","本文を取得",#selector(fetchBody)),button("delete","このMacから削除…",#selector(remove)),NSView()]); actions.spacing = 10
        message.maximumNumberOfLines = 3; message.setAccessibilityLabel("受信メールの操作結果")
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("reload","再読み込み",#selector(reload)),button("close","閉じる",#selector(close))]); footer.spacing = 10; buttons["close"]?.keyEquivalent = "\u{1b}"
        InvoiceMailUI.layout(window,[title,filters,header,list,preview,actions,message,footer]); load()
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, !self.closed, note.userInfo?["database"] as? String == self.service.db.url.path, self.window.attachedSheet == nil else { return }; self.load()
        }
    }
    deinit { htmlViewer?.close(); listCancellation?.cancel(); detailCancellation?.cancel(); searchWork?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private var selected:NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var selectedAccountID:String? { context.accountID ?? selectedMessage?["emailAccountId"].string }
    private func button(_ key:String,_ title:String,_ action:Selector) -> NSButton { let value = InvoiceMailUI.button(title,target:self,action:action); buttons[key] = value; return value }
    private func show(_ value:String,error:Bool = false) { showingDetailMessage = false; message.stringValue = value; message.textColor = error ? .systemRed : .secondaryLabelColor }
    private func controls() {
        let available = !closed && window.attachedSheet == nil, ready = available && !loading
        buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready
        folder.isEnabled = available; unread.isEnabled = available; search.isEnabled = available
        for key in ["reply","forward"] { buttons[key]?.isEnabled = ready && !detailLoading && bodyLoaded && selectedMessage != nil }
        buttons["html"]?.isEnabled = ready && !detailLoading && bodyLoaded && !(selectedMessage?["bodyHtml"].string ?? "").isEmpty
        buttons["body"]?.isEnabled = ready && !detailLoading && !bodyLoaded && selectedMessage != nil
        buttons["delete"]?.isEnabled = ready && !detailLoading && selectedMessage != nil
        for key in ["compose","history"] { buttons[key]?.isEnabled = ready && selectedAccountID != nil && (!context.isCRM || !detailLoading) }
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+50 < total
        buttons["close"]?.isEnabled = available
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"+(total == 10_000 ? "（最大表示件数）" : "")
    }
    private func invalidateDetail() { htmlViewer?.close(); htmlViewer = nil; detailCancellation?.cancel(); detailCancellation = nil; detailGeneration += 1; selectedMessage = nil; bodyLoaded = false; detailLoading = false }
    private func load() {
        guard !closed else { return }; listCancellation?.cancel(); let cancellation = NativeMailCancellation(); listCancellation = cancellation
        invalidateDetail(); generation += 1; let version = generation, start = offset, selectedID = selected?["id"].string
        let index = folder.indexOfSelectedItem-(context.isCRM ? 1 : 0)
        let chosen:NativeMailFolder? = index < 0 ? nil : index == 1 ? .sent : .inbox, query = search.stringValue, onlyUnread = unread.state == .on
        loading = true; controls()
        queue.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            let result = Result { try self.service.mailMessages(in:self.context,folder:chosen,offset:start,search:query,unreadOnly:onlyUnread) }
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == version else { return }
                switch result {
                case let .success(page):
                    if page.rows.isEmpty && start > 0 { self.offset = max(0,((max(0,page.total-1))/50)*50); self.load(); return }
                    self.rows = page.rows; self.total = page.total
                case let .failure(error):self.rows = []; self.total = 0; self.show(error.localizedDescription,error:true)
                }
                self.table.reloadData(); if let index = self.rows.firstIndex(where:{$0["id"].string == selectedID}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
                self.loading = false; self.controls(); self.loadDetail(request:false)
            }
        }
    }
    private func loadDetail(request:Bool) {
        invalidateDetail(); let version = detailGeneration
        guard !loading, let id = selected?["id"].string else { body.string = "メールを選択すると本文を表示します。"; controls(); return }
        if request || showingDetailMessage { show("") }
        let cancellation = NativeMailCancellation(); detailCancellation = cancellation; detailLoading = true; body.string = "本文を読み込んでいます…"; controls()
        queue.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }
            let result = Result { () -> (NativeRecord,Bool,NativeJob?,String,String) in
                let data = try self.service.db.transaction { () -> (NativeRecord,Bool,NativeJob?) in
                    let original = try self.service.mailMessage(id,in:self.context)
                    let row = try self.service.markMailRead(original), loaded = try self.service.mailBodyIsLoaded(row)
                    if request && !loaded { _ = try self.service.requestMailBody(row) }
                    return (row,loaded,try self.service.mailBodyJob(id))
                }
                let text = data.0["bodyText"] != .null ? data.0["bodyText"].string : try NativeMailText.quote(html:data.0["bodyHtml"].string)
                let account = try self.service.mailAccount(data.0["emailAccountId"].string)
                return (data.0,data.1,data.2,text,account["label"].string+" <"+account["username"].string+">")
            }
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.detailGeneration == version else { return }; self.detailLoading = false
                switch result {
                case let .success((row,loaded,job,text,account)):
                    self.selectedMessage = row; self.bodyLoaded = loaded
                    if let index = self.rows.firstIndex(where:{$0["id"] == row["id"]}) { var values = self.rows[index].values; values["isRead"] = .integer(1); self.rows[index] = NativeRecord(model:"Email",values:values,revision:row.revision); self.table.reloadData(forRowIndexes:IndexSet(integer:index),columnIndexes:IndexSet(integer:0)) }
                    let header = "件名："+(row["subject"].string.isEmpty ? "（件名なし）" : row["subject"].string)+"\n差出人："+row["fromName"].string+" <"+row["fromEmail"].string+">\n宛先："+NativeMailText.addresses(row["toRecipients"])+"\nCc："+NativeMailText.addresses(row["ccRecipients"])+"\n日時："+NativeMailText.date(row["sentAt"].string)+(self.context.isCRM ? "\nメールアカウント："+account : "")+"\n\n"
                    let waiting = ["pending","running","retry"].contains(job?.status ?? "")
                    let fallback = waiting ? "本文を取得しています…" : (job?.result["missing"] == "true" ? "メールサーバー上に本文が見つかりません。" : "本文を取得できていません。「本文を取得」で再試行できます。")
                    self.body.string = header+(loaded ? (text.isEmpty ? "（本文なし）" : text) : fallback)
                    if self.message.stringValue.isEmpty || self.showingDetailMessage {
                        self.show(loaded ? (row["bodyHtml"] != .null ? "テキストで表示しています。「HTMLで表示」で画像や表の配置を確認できます。" : "") : (job?.lastError ?? ""),error:!loaded && job?.lastError != nil); self.showingDetailMessage = true
                    }
                    self.controls(); if ["pending","running"].contains(job?.status ?? "") { self.buttons["body"]?.isEnabled = false }; if request && waiting { self.onChanged?() }
                case let .failure(error):self.body.string = "メールを読み込めませんでした。"; self.show(error.localizedDescription,error:true); self.showingDetailMessage = true; self.controls()
                }
            }
        }
    }
    func controlTextDidChange(_ obj:Notification) {
        guard obj.object as? NSSearchField === search else { return }; searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.filterChanged() }; searchWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    @objc private func filterChanged() { guard window.attachedSheet == nil else { return }; offset = 0; table.deselectAll(nil); show(""); load() }
    private func openComposer(_ mode:NativeMailComposeMode) {
        guard !loading && window.attachedSheet == nil, let accountID = selectedAccountID, mode == .new || (!detailLoading && bodyLoaded && selectedMessage != nil) else { return }
        do {
            if context.isCRM, let row = selectedMessage { _ = try service.mailMessage(row["id"].string,in:context) }
            let controller = try NativeMailComposeWindow(service:service,accountID:accountID,mode:mode,sourceID:mode == .new ? nil : selectedMessage?["id"].string); composer = controller
            controller.onQueued = { [weak self] _ in self?.show("送信待ちに追加しました。「送信履歴」で確認できます。"); self?.onChanged?() }
            window.beginSheet(controller.window) { [weak self] _ in self?.composer = nil; self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true) }
    }
    @objc private func compose() { openComposer(.new) }
    @objc private func reply() { openComposer(.reply) }
    @objc private func forward() { openComposer(.forward) }
    @objc private func fetchBody() { guard !loading && !detailLoading && window.attachedSheet == nil else { return }; loadDetail(request:true) }
    @objc private func openHTML() {
        guard !closed && !loading && !detailLoading && bodyLoaded && window.attachedSheet == nil, let snapshot = selectedMessage, !snapshot["bodyHtml"].string.isEmpty else { return }
        let version = detailGeneration; detailLoading = true; controls()
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () -> NativeMailHTMLDocument in
                let current = try self.service.mailMessage(snapshot["id"].string,in:self.context)
                guard current.revision == snapshot.revision else { throw NativeDBError.conflict }
                return try NativeMailHTMLDocument(subject:current["subject"].string,html:current["bodyHtml"].string)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.detailGeneration == version else { return }
                self.detailLoading = false
                do {
                    let document = try result.get(); self.htmlViewer?.close(); self.htmlViewer = nil
                    self.htmlViewer = try self.makeHTMLViewer(document) { [weak self] in
                        guard let self, !self.closed, self.detailGeneration == version else { return }
                        self.show(NativeMailHTMLError.unavailable.localizedDescription,error:true)
                    }
                    self.show("HTMLメールを別のウインドウで開きました。")
                } catch { self.show(error.localizedDescription,error:true) }
                self.controls()
            }
        }
    }
    @objc private func openHistory() {
        guard !loading && window.attachedSheet == nil, let accountID = selectedAccountID else { return }
        do {
            if context.isCRM, let row = selectedMessage { _ = try service.mailMessage(row["id"].string,in:context) }
            let controller = try NativeMailHistoryWindow(service:service,accountID:accountID); history = controller; controller.onChanged = { [weak self] in self?.onChanged?() }
            window.beginSheet(controller.window) { [weak self] _ in self?.history = nil; self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true) }
    }
    @objc private func remove() {
        guard !loading && !detailLoading && window.attachedSheet == nil, let row = selectedMessage else { return }
        let alert = NSAlert(); alert.messageText = "このメールをこのMacから削除しますか？"; alert.informativeText = "メールサーバー上のメールは削除しません。このMacの一覧には再同期しても表示されなくなります。"; alert.addButton(withTitle:"削除"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return }; if response == .alertFirstButtonReturn { do { try self.service.db.transaction { _ = try self.service.mailMessage(row["id"].string,in:self.context); try self.service.deleteMailMessage(row) }; self.show("メールを削除しました。") } catch { self.show(error.localizedDescription,error:true) } }; self.load()
        }; controls()
    }
    func confirmDiscard() -> Bool { window.attachedSheet == nil && composer == nil && history == nil }
    @objc private func close() { guard confirmDiscard() else { return }; closed = true; generation += 1; listCancellation?.cancel(); searchWork?.cancel(); invalidateDetail(); body.string = ""; window.sheetParent?.endSheet(window) }
    @objc private func reload() { guard window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard !loading else { return }; offset = max(0,offset-50); table.deselectAll(nil); load() }
    @objc private func next() { guard !loading && offset+50 < total else { return }; offset += 50; table.deselectAll(nil); load() }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification:Notification) { controls(); loadDetail(request:true); table.enumerateAvailableRowViews{row,_ in row.subviews.forEach{$0.needsDisplay = true}} }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row], identifier = NSUserInterfaceItemIdentifier("mailbox-row")
        let cell = table.makeView(withIdentifier:identifier,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = identifier
        let state = [record["isRead"] == .integer(1) ? "既読" : "未読"]+(context.isCRM ? [record["folder"] == .text("SENT") ? "送信済み" : "受信"] : [])
        cell.configure(columns:columns,values:state+[record["fromName"].string.isEmpty ? record["fromEmail"].string : record["fromName"].string,record["subject"].string.isEmpty ? "（件名なし）" : record["subject"].string,NativeMailText.date(record["sentAt"].string)]); return cell
    }
}
