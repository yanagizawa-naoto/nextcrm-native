import AppKit

final class NativeMailReviewWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:435),styleMask:[.titled],backing:.buffered,defer:false)
    private let service:CRMService, job:NativeJob
    private let outcome = NSPopUpButton(), hint = NSTextField(wrappingLabelWithString:""), message = NSTextField(wrappingLabelWithString:"")
    private var saved = false
    init(service:CRMService,job:NativeJob) throws {
        self.service = service; self.job = job
        let current = try service.mailSendJob(job.id); guard current == job && current.status == "needs_review" else { throw NativeDBError.conflict }
        let summary = try service.mailSendSummary(current)
        super.init(); window.title = "送信結果を確認"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"メール事業者の送信済みフォルダなどで、このメールが送信されたか確認してください。結果が不明な間は、自動で再送しません。")
        let context = NSTextView(); context.setAccessibilityLabel("確認するメール")
        let preview = InvoiceMailUI.textScroll(context,height:110,editable:false)
        context.string = "宛先："+summary.to.joined(separator:", ")+"\n件名："+summary.subject+"\n差出人："+summary.from+"\nMessage-ID："+summary.messageID
        outcome.addItems(withTitles:["未確認（変更しない）","送信済みを確認","未送信を確認"]); outcome.setAccessibilityLabel("メールの確認結果"); outcome.target = self; outcome.action = #selector(selectionChanged)
        hint.font = .systemFont(ofSize:12); hint.textColor = .secondaryLabelColor; message.textColor = .systemRed; message.setAccessibilityLabel("送信結果の記録状況")
        let close = InvoiceMailUI.button("キャンセル",target:self,action:#selector(close)); close.keyEquivalent = "\u{1b}"
        let save = InvoiceMailUI.button("確認結果を記録",target:self,action:#selector(save))
        let footer = NSStackView(views:[NSView(),close,save]); footer.spacing = 12
        InvoiceMailUI.layout(window,[title,help,preview,outcome,hint,message,footer]); selectionChanged()
    }
    @objc private func selectionChanged() {
        switch outcome.indexOfSelectedItem {
        case 1:hint.stringValue = "このMacの送信済みフォルダへの保存を再開します。この操作でメールを再送することはありません。"
        case 2:hint.stringValue = "未送信として記録します。再送する場合は、送信履歴から別途「再試行」を選んでください。"
        default:hint.stringValue = "確認待ちの状態を保ちます。送信済みかどうか分かるまで、同じ内容の新規送信は控えてください。"
        }
    }
    func confirmDiscard() -> Bool { saved || outcome.indexOfSelectedItem == 0 || InvoiceMailUI.discard("送信結果の選択を保存せずに閉じますか？") }
    @objc private func close() { guard confirmDiscard() else { return }; window.sheetParent?.endSheet(window) }
    @objc private func save() {
        do { if outcome.indexOfSelectedItem > 0 { try service.reviewMailSend(job,sent:outcome.indexOfSelectedItem == 1) }; saved = true; window.sheetParent?.endSheet(window) }
        catch { message.stringValue = error.localizedDescription }
    }
}

final class NativeMailHistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1080,height:690),styleMask:[.titled],backing:.buffered,defer:false)
    private let service:CRMService, accountID:String
    private let table = NSTableView(), detail = NSTextView(), message = NSTextField(wrappingLabelWithString:""), info = NSTextField(labelWithString:"")
    private var rows:[NativeJob] = [], summaries:[String:NativeMailSendPreview] = [:], buttons:[String:NSButton] = [:]
    private var offset = 0, generation = 0, detailGeneration = 0, loading = false, closed = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.mail-history")
    private var observer:NSObjectProtocol?, review:NativeMailReviewWindow?
    private var detailCancellation:NativeMailCancellation?
    private var showingDetailError = false
    private let columns = [NativeColumn(title:"件名",fraction:0.38),NativeColumn(title:"宛先",fraction:0.27),NativeColumn(title:"状態",fraction:0.15),NativeColumn(title:"作成日時",fraction:0.20)]
    var onChanged:(() -> Void)?
    init(service:CRMService,accountID:String) throws {
        self.service = service; self.accountID = accountID; let account = try service.mailAccount(accountID); super.init(); window.title = "送信履歴"
        let title = NSTextField(labelWithString:window.title+" — "+account["label"].string); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"このMacから送信を受け付けたメールです。「送信済み」はメールサーバーでの受付を示し、相手への到着を保証するものではありません。")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("mail-history")); column.width = 1040; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 34; table.dataSource = self; table.delegate = self; table.setAccessibilityLabel("通常メールの送信履歴")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:210).isActive = true
        let preview = InvoiceMailUI.textScroll(detail,height:185,editable:false); detail.setAccessibilityLabel("選択した送信メールの詳細")
        message.maximumNumberOfLines = 3; message.setAccessibilityLabel("送信履歴の操作結果")
        let actions = NSStackView(views:[button("retry","再試行",#selector(retry)),button("review","送信結果を確認…",#selector(openReview)),button("cancel","送信待ちを取り消す…",#selector(cancel)),NSView()]); actions.spacing = 10
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("reload","再読み込み",#selector(reload)),button("close","閉じる",#selector(close))]); footer.spacing = 10; buttons["close"]?.keyEquivalent = "\u{1b}"
        InvoiceMailUI.layout(window,[title,help,header,scroll,preview,actions,message,footer]); load()
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.service.db.url.path, self.window.attachedSheet == nil else { return }; self.load()
        }
    }
    deinit { detailCancellation?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private var selected:NativeJob? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func button(_ key:String,_ title:String,_ action:Selector) -> NSButton { let b = InvoiceMailUI.button(title,target:self,action:action); buttons[key] = b; return b }
    private func show(_ text:String,error:Bool = false) { showingDetailError = false; message.stringValue = text; message.textColor = error ? .systemRed : .secondaryLabelColor }
    private func controls() {
        let ready = !loading && window.attachedSheet == nil, job = selected
        buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready
        buttons["retry"]?.isEnabled = ready && ["failed","retry"].contains(job?.status ?? "") && (job?.deliveryStartedAt == nil || job?.result["smtpAccepted"] == "true")
        buttons["retry"]?.title = job?.result["smtpAccepted"] == "true" ? "保存を再試行" : "再試行"
        buttons["review"]?.isEnabled = ready && job?.status == "needs_review"
        buttons["cancel"]?.isEnabled = ready && ["pending","retry","failed"].contains(job?.status ?? "") && job?.deliveryStartedAt == nil
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && rows.count == 50
        buttons["close"]?.isEnabled = window.attachedSheet == nil
        info.stringValue = rows.isEmpty ? "送信履歴はありません" : "\(offset+1)–\(offset+rows.count)件"
    }
    private func load(detailRetries:Int = 2) {
        guard !closed else { return }
        // A refresh invalidates the old detail immediately, before its queued
        // result can report a conflict caused by the worker's own update.
        detailCancellation?.cancel(); detailCancellation = nil; detailGeneration += 1
        generation += 1; let version = generation, start = offset, selectedID = selected?.id; loading = true; controls()
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { try self.service.db.transaction { () -> ([NativeJob],[String:NativeMailSendPreview]) in
                let rows = try self.service.mailSendJobs(self.accountID,offset:start); var summaries:[String:NativeMailSendPreview] = [:]
                for job in rows { summaries[job.id] = try self.service.mailSendPreview(job) }; return (rows,summaries)
            } }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == version else { return }
                switch result {
                case let .success((rows,summaries)):
                    if rows.isEmpty && start > 0 { self.offset = max(0,start-50); self.load(); return }
                    self.rows = rows; self.summaries = summaries
                case let .failure(error):self.rows = []; self.summaries = [:]; self.show(error.localizedDescription,error:true)
                }
                self.table.reloadData(); if let index = self.rows.firstIndex(where:{$0.id == selectedID}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
                self.loading = false; self.controls(); self.loadDetail(retries:detailRetries)
            }
        }
    }
    private func loadDetail(retries:Int = 2) {
        detailCancellation?.cancel(); detailCancellation = nil
        detailGeneration += 1; let version = detailGeneration
        guard !loading, let job = selected else { detail.string = "メールを選択すると内容を表示します。"; return }
        let cancellation = NativeMailCancellation(); detailCancellation = cancellation
        detail.string = "宛先と本文を読み込んでいます…"
        queue.async { [weak self] in
            guard let self, !cancellation.isCancelled else { return }; let result = Result { () -> String in
                let summary = try self.service.mailSendSummary(job)
                guard !cancellation.isCancelled else { throw CancellationError() }
                let context = "状態："+Self.status(job)+"\n差出人："+summary.from+"\n宛先："+summary.to.joined(separator:", ")+"\nCc："+summary.cc.joined(separator:", ")+"\nBcc："+summary.bcc.joined(separator:", ")+"\n件名："+summary.subject+"\nMessage-ID："+summary.messageID+"\n"+(job.lastError.map{$0+"\n"} ?? "")
                let body = try self.service.mailSendBody(job)
                return context+"\n"+(body ?? "本文は保持されていません。")
            }
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.detailGeneration == version else { return }
                switch result {
                case let .success(body):
                    self.detail.string = body
                    if self.showingDetailError { self.show("") }
                case let .failure(error):
                    // The list and the lazy body have separate snapshots. A
                    // normal delivery transition between them is retried with
                    // fresh headers, with a bound if updates never settle.
                    if case NativeDBError.conflict = error, retries > 0 { self.load(detailRetries:retries-1) }
                    else { self.detail.string = "内容を再読み込みしてください。"; self.show(error.localizedDescription,error:true); self.showingDetailError = true }
                }
            }
        }
    }
    @objc private func retry() {
        guard !loading && window.attachedSheet == nil, let job = selected else { return }
        do { try service.retryMailSend(job); onChanged?(); show(job.result["smtpAccepted"] == "true" ? "送信済みへの保存を再試行します。" : "再試行を受け付けました。") } catch { show(error.localizedDescription,error:true) }; load()
    }
    @objc private func openReview() {
        guard !loading && window.attachedSheet == nil, let job = selected else { return }
        do { let controller = try NativeMailReviewWindow(service:service,job:job); review = controller
            window.beginSheet(controller.window) { [weak self] _ in self?.review = nil; self?.onChanged?(); self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true); load() }
    }
    @objc private func cancel() {
        guard !loading && window.attachedSheet == nil, let job = selected else { return }
        let alert = NSAlert(); alert.messageText = "送信待ちのメールを取り消しますか？"; alert.informativeText = "この送信内容は再試行できなくなります。送信する場合は新しく作成してください。"; alert.addButton(withTitle:"送信を取り消す"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] result in
            guard let self else { return }; if result == .alertFirstButtonReturn { do { try self.service.cancelMailSend(job); self.onChanged?(); self.show("送信待ちを取り消しました。") } catch { self.show(error.localizedDescription,error:true) } }; self.load()
        }; controls()
    }
    func confirmDiscard() -> Bool { window.attachedSheet == nil && review == nil }
    @objc private func close() { guard confirmDiscard() else { return }; closed = true; generation += 1; detailGeneration += 1; detailCancellation?.cancel(); detail.string = ""; window.sheetParent?.endSheet(window) }
    @objc private func reload() { guard window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard !loading else { return }; offset = max(0,offset-50); load() }
    @objc private func next() { guard !loading && rows.count == 50 else { return }; offset += 50; load() }
    static func status(_ job:NativeJob) -> String {
        if job.result["smtpAccepted"] == "true" && job.status != "done" { return "送信済みを保存中" }
        switch job.status { case "pending":return "送信待ち"; case "running":return "送信中"; case "retry":return "再試行待ち"; case "failed":return "送信エラー"; case "needs_review":return "結果の確認が必要"; case "done":return "送信済み"; case "cancelled":return "取消済み"; default:return "確認が必要" }
    }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification:Notification) { controls(); loadDetail(); table.enumerateAvailableRowViews{row,_ in row.subviews.forEach{$0.needsDisplay = true}} }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard rows.indices.contains(row), let summary = summaries[rows[row].id] else { return nil }; let job = rows[row], identifier = NSUserInterfaceItemIdentifier("mail-history-row")
        let cell = table.makeView(withIdentifier:identifier,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = identifier
        cell.configure(columns:columns,values:[summary.subject.isEmpty ? "（件名なし）" : summary.subject,summary.recipientsText,Self.status(job),NativeMailText.date(job.createdAt)]); return cell
    }
}
