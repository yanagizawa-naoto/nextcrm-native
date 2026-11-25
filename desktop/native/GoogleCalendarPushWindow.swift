import AppKit

final class GoogleCalendarPushWindow: NSObject,NSTableViewDataSource,NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:650),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService, queue = MemoryBudget.queue(label:"local.nextcrm.native.calendar-push-history")
    private let table = NSTableView(), info = NSTextField(labelWithString:""), message = NSTextField(wrappingLabelWithString:""), detail = NSTextView()
    private var rows: [(job:NativeJob,title:String)] = [], buttons: [String:NSButton] = [:], selectedJob: NativeJob?
    private var offset = 0, total = 0, generation = 0, detailGeneration = 0, loading = false, detailLoading = false
    private var observer: NSObjectProtocol?
    private let columns = [NativeColumn(title:"予定",fraction:0.34),NativeColumn(title:"操作",fraction:0.14),NativeColumn(title:"状態",fraction:0.17),NativeColumn(title:"試行",fraction:0.08),NativeColumn(title:"登録日時",fraction:0.27)]
    init(service: CRMService) throws {
        try service.authenticated(); self.service = service; super.init(); window.title = "Googleへの予定の反映履歴"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"自分が作成した会議をGoogleへ反映した処理です。読み書きで接続したアカウントを使い、作成・変更・取消を参加者へ通知します。反映結果が未確定の処理は、結果を再確認してから次の変更を進めます。")
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("push")); column.width = 1000; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("Googleへの反映処理")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        detail.setAccessibilityLabel("選択した反映処理の詳細")
        let actions = NSStackView(views:[button("retry","結果を再確認・再試行",#selector(retry)),button("review","Googleで未反映と確認…",#selector(review))]); actions.spacing = 12
        message.maximumNumberOfLines = 2; message.setAccessibilityLabel("Google反映履歴の操作結果")
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("reload","再読み込み",#selector(reload)),button("close","閉じる",#selector(close))]); footer.spacing = 12; buttons["close"]?.keyEquivalent = "\u{1b}"
        InvoiceMailUI.layout(window,[title,help,header,scroll,InvoiceMailUI.textScroll(detail,height:110,editable:false),actions,message,footer])
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in guard let self, note.userInfo?["database"] as? String == self.service.db.url.path, self.window.attachedSheet == nil else { return }; self.load() }
        load()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func button(_ key: String,_ title: String,_ action: Selector) -> NSButton { let b = InvoiceMailUI.button(title,target:self,action:action); buttons[key] = b; return b }
    private func controls() {
        buttons.values.forEach{$0.isEnabled = !loading}; table.isEnabled = !loading
        buttons["previous"]?.isEnabled = !loading && offset > 0; buttons["next"]?.isEnabled = !loading && offset+100 < total
        let canRetry = !loading && !detailLoading && ["failed","retry","needs_review"].contains(selectedJob?.status ?? "")
        buttons["retry"]?.isEnabled = canRetry; buttons["review"]?.isEnabled = canRetry && ["unknown","rejected"].contains(selectedJob?.result["requestOutcome"] ?? "")
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(total,offset+rows.count)) ／ \(total)件"
    }
    private func load() {
        let selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].job.id : nil
        generation += 1; let version = generation, start = offset; loading = true; controls()
        queue.async { [weak self] in guard let self else { return }; let result = Result{try self.service.googleCalendarPushPage(offset:start)}
            DispatchQueue.main.async { [weak self] in guard let self, version == self.generation else { return }
                switch result { case let .success(page):
                    if page.rows.isEmpty && start > 0 { self.offset = max(0,((max(0,page.total-1))/100)*100); self.load(); return }
                    self.rows = page.rows; self.total = page.total
                case let .failure(error):self.rows = []; self.total = 0; self.message.stringValue = error.localizedDescription }
                self.table.reloadData(); if let index = self.rows.firstIndex(where:{$0.job.id == selectedID}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }; self.loading = false; self.loadDetail(); self.controls()
            }
        }
    }
    private func loadDetail() {
        detailGeneration += 1; let version = detailGeneration; selectedJob = nil; detail.string = ""
        guard rows.indices.contains(table.selectedRow) else { detailLoading = false; controls(); return }
        let id = rows[table.selectedRow].job.id; detailLoading = true; controls()
        queue.async { [weak self] in guard let self else { return }; let result = Result{try self.service.googleCalendarPushJob(id)}
            DispatchQueue.main.async { [weak self] in guard let self, version == self.detailGeneration else { return }; self.detailLoading = false
                switch result { case let .success(job):self.selectedJob = job
                    var lines = ["状態："+Self.status(job.status),"処理ID："+job.id]
                    if let json = job.result["plan"], let plan = try? JSONDecoder().decode(GoogleCalendarPushPlan.self,from:Data(json.utf8)) { lines += ["Googleアカウント："+plan.accountEmail,"Googleの予定ID："+plan.eventID,"操作："+Self.operation(plan.action)] }
                    if let reason = job.result["reason"], !reason.isEmpty { lines.append("結果："+Self.reason(reason)) }
                    if let error = job.lastError { lines.append(error) }
                    if let note = job.result["reviewNote"] { lines.append("未反映の確認記録："+note) }
                    self.detail.string = lines.joined(separator:"\n")
                case let .failure(error):self.detail.string = error.localizedDescription }; self.controls()
            }
        }
    }
    private static func status(_ status: String) -> String { ["pending":"待機中","running":"反映中","retry":"再試行待ち","needs_review":"結果の確認が必要","failed":"エラー","done":"処理済み","cancelled":"取消済み"][status] ?? "確認が必要" }
    private static func operation(_ action: String) -> String { ["insert":"作成","patch":"更新","delete":"取消","cancel":"取消","upsert":"作成・更新"][action] ?? "反映" }
    private static func reason(_ reason: String) -> String { ["not-found":"予定が見つかりません","not-a-meeting":"会議以外の活動です","calendly-owned":"予約サービスが管理する予定です","no-write-connection":"書き込みできる接続がありません","never-pushed":"Googleに作成していない予定です","no-date":"日時がありません","already-completed":"完了した予定です","in-the-past":"過去の予定です","not-organizer":"他の人が主催する予定です","connection-mismatch":"元のGoogleアカウントへの接続がありません","manually-not-applied":"未反映と確認し、新しい処理を登録しました"][reason] ?? "反映対象外です" }
    @objc private func retry() {
        guard !loading, !detailLoading, let job = selectedJob, window.attachedSheet == nil else { return }
        do { try service.retryGoogleCalendarPush(job); message.stringValue = "結果の再確認・再試行を受け付けました。" } catch { message.stringValue = error.localizedDescription }; load()
    }
    @objc private func review() {
        guard !loading, !detailLoading, let job = selectedJob, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "Googleで未反映と確認しましたか？"
        alert.informativeText = "対象のGoogleアカウントと予定を確認した場合だけ実行してください。現在のCRMの内容を新しい処理として反映します。すでに反映済みの場合、予定や通知が重複する可能性があります。\n"+detail.string
        let note = NSTextField(frame:NSRect(x:0,y:0,width:460,height:60)); note.placeholderString = "Googleで未反映と確認した内容"; note.setAccessibilityLabel("未反映と確認した内容"); alert.accessoryView = note
        alert.addButton(withTitle:"未反映と記録してやり直す"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }
            do { _ = try self.service.reviewGoogleCalendarPushNotApplied(job,note:note.stringValue); self.message.stringValue = "未反映の確認を記録し、新しい反映処理を登録しました。" } catch { self.message.stringValue = error.localizedDescription }; self.load()
        }
    }
    func confirmDiscard() -> Bool { window.attachedSheet == nil }
    @objc private func close() { guard confirmDiscard() else { return }; generation += 1; detailGeneration += 1; window.sheetParent?.endSheet(window) }
    @objc private func reload() { guard window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard !loading else { return }; offset = max(0,offset-100); load() }
    @objc private func next() { guard !loading, offset+100 < total else { return }; offset += 100; load() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { loadDetail() }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let item = rows[row], id = NSUserInterfaceItemIdentifier("push-row")
        let cell = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = id
        var date = item.job.createdAt; if let parsed = try? NativeCalendarEvents.date(date) { let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"; date = f.string(from:parsed) }
        cell.configure(columns:columns,values:[item.title,Self.operation(item.job.result["did"].flatMap{$0.isEmpty ? nil : $0} ?? item.job.payload["operation"] ?? ""),Self.status(item.job.status),String(item.job.attempts),date]); return cell
    }
}
