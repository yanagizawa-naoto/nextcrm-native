import AppKit

enum InvoiceMailUI {
    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title:title,target:target,action:action); b.bezelStyle = .rounded; return b
    }
    static func row(_ label: String, _ control: NSView) -> NSStackView {
        let name = NSTextField(labelWithString:label); name.widthAnchor.constraint(equalToConstant:90).isActive = true
        control.setAccessibilityLabel(label); control.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let row = NSStackView(views:[name,control]); row.spacing = 12; return row
    }
    static func layout(_ window: NSWindow, _ views: [NSView], spacing: CGFloat = 14) {
        let root = NSStackView(views:views); root.orientation = .vertical; root.alignment = .leading; root.spacing = spacing; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in views { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
    }
    static func textScroll(_ text: NSTextView, height: CGFloat, editable: Bool = true) -> NSScrollView {
        text.frame = NSRect(x:0,y:0,width:650,height:height); text.isRichText = false; text.isEditable = editable; text.isSelectable = true
        text.font = .systemFont(ofSize:13); text.allowsUndo = editable; text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width:650,height:CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant:height).isActive = true; return scroll
    }
    static func discard(_ message: String) -> Bool {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"変更を破棄")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

final class CRMInvoiceMailSettingsWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:740,height:365),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let store: InvoiceMailCredentialStore
    private let sender = NSTextField(); private let key = NSSecureTextField()
    private let message = NSTextField(wrappingLabelWithString:"")
    private var originalFrom: String
    var onSaved: (() -> Void)?
    init(service: CRMService, store: InvoiceMailCredentialStore) throws {
        try service.authenticated(); guard service.identity.role == "admin" else { throw NativeDBError.message("メール送信の設定は管理者が変更してください。") }
        self.service = service; self.store = store
        let existing = try store.load(interactive:true); originalFrom = existing?.from ?? ""
        super.init(); window.title = "メール送信の設定"; sender.stringValue = originalFrom
        key.placeholderString = existing == nil ? "ResendのAPIキー" : "保存済み・変更する場合だけ入力"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"請求書メール・受注の承認通知・タスクの通知に共通の設定です。送信サービスはResendです。認証済みドメインのメールアドレスと、メール送信権限のあるAPIキーを設定してください。キーはこのMacのキーチェーンに保存します。")
        let note = NSTextField(wrappingLabelWithString:"送信準備済みメールの宛先・本文・差出人は変更されません。送信開始後にAPIキーを変えたメールは、重複送信を避けるため自動再試行を停止します。")
        note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize:12); message.textColor = .systemRed
        let cancel = InvoiceMailUI.button("キャンセル",target:self,action:#selector(close)); cancel.keyEquivalent = "\u{1b}"
        let save = InvoiceMailUI.button("設定を保存",target:self,action:#selector(save)); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let remove = InvoiceMailUI.button("保存した設定を削除…",target:self,action:#selector(remove)); remove.isEnabled = existing != nil
        let buttons = NSStackView(views:[remove,NSView(),cancel,save]); buttons.spacing = 12
        InvoiceMailUI.layout(window,[title,help,InvoiceMailUI.row("差出人",sender),InvoiceMailUI.row("APIキー",key),note,message,buttons])
    }
    func confirmDiscard() -> Bool { (sender.stringValue == originalFrom && key.stringValue.isEmpty) || InvoiceMailUI.discard("メール設定の変更を保存せずに閉じますか？") }
    @objc private func close() { if window.attachedSheet == nil && confirmDiscard() { window.sheetParent?.endSheet(window) } }
    @objc private func save() {
        do { try service.saveInvoiceMailSettings(from:sender.stringValue,apiKey:key.stringValue,store:store); key.stringValue = ""; originalFrom = sender.stringValue; onSaved?(); window.sheetParent?.endSheet(window) }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc private func remove() {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "保存したメール設定を削除しますか？"; alert.informativeText = "再設定するまでメールを送信できません。予約済みのメールと送信履歴は残ります。"; alert.addButton(withTitle:"設定を削除"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do { try self.service.removeInvoiceMailSettings(store:self.store); self.key.stringValue = ""; self.sender.stringValue = ""; self.originalFrom = ""; self.onSaved?(); self.window.sheetParent?.endSheet(self.window) }
            catch { self.message.stringValue = error.localizedDescription }
        }
    }
}

final class CRMInvoiceMailComposeWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:780,height:570),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let invoice: NativeRecord; private let from: String
    private let to = NSTextField(); private let subject = NSTextField(); private let body = NSTextView()
    private let message = NSTextField(wrappingLabelWithString:"")
    private var send: NSButton!; private var cancel: NSButton!; private var busy = false
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.invoice-mail-prepare")
    private var initial: [String] = []
    private(set) var queuedID: String?
    init(service: CRMService, invoice: NativeRecord, store: InvoiceMailCredentialStore) throws {
        self.service = service; self.invoice = try service.invoiceAccess(invoice,action:"email")
        _ = try service.invoicePDFURL(self.invoice)
        guard let sender = try service.invoiceMailSender(store:store) else { throw NativeDBError.message("管理者が「NextCRM Native → メール送信の設定」で差出人とAPIキーを設定してください。") }
        from = sender
        let defaults = try service.invoiceEmailDefaults(self.invoice)
        super.init(); window.title = "請求書をメールで送信"; to.stringValue = defaults.to; subject.stringValue = defaults.subject; body.string = defaults.message
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let attachment = NSTextField(wrappingLabelWithString:"添付：請求書 \(invoice["number"].string).pdf\n送信後は「送信・PDFの処理状況」で結果を確認できます。アプリを閉じても予約は残り、次回起動時に再開します。")
        attachment.font = .systemFont(ofSize:12); attachment.textColor = .secondaryLabelColor
        body.setAccessibilityLabel("メール本文")
        let scroll = InvoiceMailUI.textScroll(body,height:235)
        cancel = InvoiceMailUI.button("キャンセル",target:self,action:#selector(close)); cancel.keyEquivalent = "\u{1b}"
        send = InvoiceMailUI.button("送信",target:self,action:#selector(sendRequested)); send.keyEquivalent = "\r"; send.keyEquivalentModifierMask = .command
        let buttons = NSStackView(views:[NSView(),cancel,send]); buttons.spacing = 12; message.textColor = .systemRed
        InvoiceMailUI.layout(window,[title,InvoiceMailUI.row("差出人",NSTextField(labelWithString:sender)),InvoiceMailUI.row("宛先",to),InvoiceMailUI.row("件名",subject),NSTextField(labelWithString:"本文"),scroll,attachment,message,buttons])
        initial = values
    }
    private var values: [String] { [to.stringValue,subject.stringValue,body.string] }
    func confirmDiscard() -> Bool { !busy && (queuedID != nil || values == initial || InvoiceMailUI.discard("作成中のメールを送信せずに閉じますか？")) }
    @objc private func close() { if confirmDiscard() { window.sheetParent?.endSheet(window) } }
    @objc private func sendRequested() {
        guard !busy else { return }; window.makeFirstResponder(nil)
        busy = true; send.isEnabled = false; cancel.isEnabled = false; to.isEnabled = false; subject.isEnabled = false; body.isEditable = false; message.stringValue = "送信内容を保存しています…"
        let values = values; let service = service; let invoice = invoice; let from = from
        queue.async { [weak self] in
            let result = Result { try autoreleasepool { try service.queueInvoiceEmail(service.invoiceAccess(invoice),from:from,to:values[0],subject:values[1],message:values[2]) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do { self.queuedID = try result.get(); self.window.sheetParent?.endSheet(self.window) }
                catch { self.message.stringValue = error.localizedDescription; self.send.isEnabled = true; self.cancel.isEnabled = true; self.to.isEnabled = true; self.subject.isEnabled = true; self.body.isEditable = true }
            }
        }
    }
}

final class CRMInvoiceJobsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let invoice: NativeRecord
    private var isOrder: Bool { invoice.model == "crm_Orders" }
    private var isLead: Bool { invoice.model == "crm_Leads" }
    private var isCRMTask: Bool { invoice.model == "crm_Accounts_Tasks" }
    private var isProject: Bool { ["Tasks","Boards","crm_Accounts_Tasks"].contains(invoice.model) }
    private func loadJobs() throws -> [NativeJob] {
        switch invoice.model {
        case "crm_Leads": return try service.leadJobs(leadID:invoice["id"].string,offset:offset)
        case "crm_Accounts_Tasks": return try service.crmTaskJobs(taskID:invoice["id"].string,offset:offset)
        case "Tasks": return try service.projectJobs(taskID:invoice["id"].string,offset:offset)
        case "Boards": return try service.projectBoardJobs(boardID:invoice["id"].string,offset:offset)
        case "crm_Orders": return try service.orderJobs(invoice,offset:offset)
        default: return try service.invoiceJobs(invoice,offset:offset)
        }
    }
    convenience init(service: CRMService, order: NativeRecord) throws { try self.init(service:service,invoice:order) }
    private let table = NSTableView(); private let detail = NSTextView(); private let message = NSTextField(wrappingLabelWithString:"")
    private let count = NSTextField(labelWithString:"")
    private var retry: NSButton!; private var cancel: NSButton!; private var review: NSButton!; private var previous: NSButton!; private var next: NSButton!
    private var reviewWindow: CRMJobReviewWindow?
    private var rows: [NativeJob] = []; private var offset = 0; private var observer: NSObjectProtocol?
    private static let columns = [NativeColumn(title:"日時",fraction:0.23),NativeColumn(title:"処理",fraction:0.12),NativeColumn(title:"状態",fraction:0.18),NativeColumn(title:"宛先",fraction:0.35),NativeColumn(title:"試行回数",fraction:0.12)]
    private static let statusNames = ["pending":"待機中","running":"実行中","retry":"再試行待ち","done":"完了","failed":"失敗","needs_review":"結果の確認が必要","cancelled":"取消済み"]
    init(service: CRMService, invoice: NativeRecord) throws {
        self.service = service; self.invoice = invoice
        super.init(); _ = try loadJobs()
        window.title = isLead ? "見込み客の担当通知" : isProject ? (invoice.model != "Boards" ? "タスクの通知状況" : "プロジェクトの通知状況") : isOrder ? "受注の通知状況" : "送信・PDFの処理状況"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:isLead || isProject ? "通知の「完了」は送信サービスが受け付けた状態です。担当者・閲覧権限・宛先の変更などで「送信対象外」になる場合があります。結果が不明な通知はResendで確認し、「確認結果を記録…」で履歴に残せます。" : isOrder ? "通知の「完了」は送信サービスが受け付けた状態です。処理済みの承認依頼や閲覧権限のない宛先は「送信対象外」になります。「結果の確認が必要」はResendで確認し、「確認結果を記録…」で履歴に残せます。" : "メールの「完了」は送信サービスが受け付けた状態です。宛先への到着を保証するものではありません。結果が不明なメールはResendで確認し、「確認結果を記録…」で履歴に残せます。")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor
        let header = LightweightTableCell(); header.horizontalInset = 16; header.configure(columns:Self.columns,values:Self.columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:24).isActive = true
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 36; table.style = .inset; table.setAccessibilityLabel(isLead ? "見込み客の担当通知履歴" : isProject ? "タスクの通知履歴" : isOrder ? "受注の承認通知" : "請求書の送信・PDF処理")
        let column = NSTableColumn(identifier:.init("job")); column.width = 840; table.addTableColumn(column)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200).isActive = true
        detail.setAccessibilityLabel("選択した処理の詳細"); let details = InvoiceMailUI.textScroll(detail,height:125,editable:false)
        retry = InvoiceMailUI.button("再試行",target:self,action:#selector(retrySelected)); cancel = InvoiceMailUI.button("予約を取消",target:self,action:#selector(cancelSelected))
        review = InvoiceMailUI.button("確認結果を記録…",target:self,action:#selector(reviewSelected))
        previous = InvoiceMailUI.button("前へ",target:self,action:#selector(page(_:))); previous.tag = -1
        next = InvoiceMailUI.button("次へ",target:self,action:#selector(page(_:))); next.tag = 1
        let reload = InvoiceMailUI.button("再読み込み",target:self,action:#selector(start)); let close = InvoiceMailUI.button("閉じる",target:self,action:#selector(close)); close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views:[retry,cancel,review,reload,NSView(),count,previous,next,close]); buttons.spacing = 10; message.textColor = .systemRed
        InvoiceMailUI.layout(window,[title,help,header,scroll,details,message,buttons])
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.service.db.url.path else { return }; self.start()
        }
        start()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    @objc func start() {
        let selected = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        do {
            rows = try loadJobs()
            if rows.isEmpty && offset > 0 { offset = max(0,offset-100); rows = try loadJobs() }
            table.reloadData(); count.stringValue = rows.isEmpty ? "0件" : "\(offset+1)–\(offset+rows.count)件"
            previous.isEnabled = offset > 0; next.isEnabled = rows.count == 100; message.stringValue = ""
            if let selected, let i = rows.firstIndex(where: { $0.id == selected }) { table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
            updateSelection()
        } catch { rows = []; table.reloadData(); detail.string = ""; count.stringValue = "0件"; previous.isEnabled = false; next.isEnabled = false; message.stringValue = error.localizedDescription; updateSelection() }
    }
    @objc private func page(_ button: NSButton) { offset = max(0,offset+button.tag*100); start() }
    func confirmDiscard() -> Bool { reviewWindow?.confirmDiscard() != false }
    @objc private func close() { if window.attachedSheet == nil { window.sheetParent?.endSheet(window) } }
    private func selected() -> NativeJob? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    @objc private func retrySelected() { guard let row = selected() else { return }; do { if isLead { try service.retryLeadJob(row.id) } else if isCRMTask { try service.retryCRMTaskJob(row.id) } else if isProject { try service.retryProjectJob(row.id) } else if isOrder { try service.retryOrderJob(row.id) } else { try service.retryInvoiceJob(row.id) }; start() } catch { message.stringValue = error.localizedDescription } }
    @objc private func cancelSelected() { guard let row = selected() else { return }; do { if isLead { try service.cancelLeadJob(row.id) } else if isCRMTask { try service.cancelCRMTaskJob(row.id) } else if isProject { try service.cancelProjectJob(row.id) } else if isOrder { try service.cancelOrderJob(row.id) } else { try service.cancelInvoiceJob(row.id) }; start() } catch { message.stringValue = error.localizedDescription } }
    @objc private func reviewSelected() {
        guard window.attachedSheet == nil, let row = selected(), row.canReviewMail else { return }
        let controller = CRMJobReviewWindow(service:service,job:row); reviewWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in self?.reviewWindow = nil; self?.start() }
    }
    private func updateSelection() {
        guard let job = selected() else { retry.isEnabled = false; cancel.isEnabled = false; review.isEnabled = false; detail.string = ""; return }
        let canManage = isLead ? (try? service.leadJobAccess(job.id)) != nil : isCRMTask ? (try? service.crmTaskJobAccess(job.id)) != nil : isProject ? (try? service.projectJobAccess(job.id)) != nil : true
        review.isEnabled = job.canReviewMail && (isProject || isLead ? canManage : service.identity.elevated || job.payload[isOrder ? "recipientId" : "actorId"] == service.identity.id)
        let inWindow = job.deliveryStartedAt.map { Date() >= $0 && Date().timeIntervalSince($0) < 23*3600 } ?? true
        retry.isEnabled = canManage && ["failed","retry"].contains(job.status) && (job.result["providerID"] != nil || inWindow)
        cancel.isEnabled = canManage && ["pending","retry","failed"].contains(job.status) && job.deliveryStartedAt == nil
        var fields = ["状態："+(Self.status(job)),"試行回数：\(job.attempts)"]
        for (label,key) in [("差出人","from"),("宛先","to"),("件名","subject")] { if let value = job.result[key] ?? job.payload[key] ?? (key == "to" ? job.payload["recipientEmail"] : nil) { fields.append(label+"："+value) } }
        if let due = job.nextRunAt { fields.append("再試行予定："+Self.date(due)) }
        if let id = job.result["providerID"] { fields.append("送信サービスの受付ID："+id) }
        if let raw = job.result["reviewOutcome"], let outcome = MailReviewOutcome(rawValue:raw) {
            fields.append("確認結果："+outcome.label)
            if let stamp = job.result["reviewedAt"] { fields.append("記録日時："+Self.date(stamp)) }
            if let actor = job.result["reviewerName"] ?? job.result["reviewedBy"] { fields.append("記録した利用者："+actor) }
            if let note = job.result["reviewNote"] { fields.append("確認した内容："+note) }
            if let prior = job.result["reviewPreviousError"] { fields.append("確認前のエラー："+prior) }
        }
        if let reason = job.result["reason"] { fields.append(reason) }; if let error = job.lastError { fields.append(error) }; detail.string = fields.joined(separator:"\n")
    }
    private static func status(_ job: NativeJob) -> String {
        if job.status == "done" {
            if job.result["outcome"] == "skipped" { return "送信対象外" }
            if job.result["reviewOutcome"] == "accepted" { return "受付確認済み" }
            if job.result["reviewOutcome"] == "notSent" { return "未送信確認済み" }
            if job.result["reviewOutcome"] == "unknown" { return "結果不明・終了" }
        }
        return statusNames[job.status] ?? "不明"
    }
    private static func date(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); var parsed = parser.date(from:value)
        if parsed == nil { parser.formatOptions.insert(.withFractionalSeconds); parsed = parser.date(from:value) }
        guard let date = parsed else { return value }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"ja_JP"); formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"; return formatter.string(from:date)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let job = rows[row]; let id = NSUserInterfaceItemIdentifier("invoice-job")
        let view = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); view.identifier = id
        let event = [NativeMCPLeads.assignedEvent:"担当割当","invoice.pdf_requested":"PDF作成","orders.approval_requested":"承認依頼","orders.approval_decided":"承認結果","crm.task_assigned":"CRMタスクの担当割当","crm.task_watched":"取引先の新規タスク","projects.task_assigned":"担当割当","projects.task_updated":"タスク更新","projects.task_commented":"コメント"][job.event] ?? "メール送信"
        view.configure(columns:Self.columns,values:[Self.date(job.createdAt),event,Self.status(job),job.result["to"] ?? job.payload["to"] ?? job.payload["recipientEmail"] ?? "—",String(job.attempts)]); return view
    }
}
