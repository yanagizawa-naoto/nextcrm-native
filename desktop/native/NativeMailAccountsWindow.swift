import AppKit

enum NativeMailConnectionCheck {
    enum Kind { case inbox, smtp }
    typealias Probe = (NativeMailAccountSettings,NativeMailCredential,Kind) async throws -> [String]
    static func run(_ settings:NativeMailAccountSettings,_ credential:NativeMailCredential,_ kind:Kind) async throws -> [String] {
        try settings.validate(); try credential.validate()
        if let google=credential.google { try GoogleMailStoredGrant.validate(settings:settings,email:google.grant.email); guard google.grant.expiresAt>Date() else{throw GoogleMailFailure.reconnect} }
        switch kind {
        case .inbox: return try await NativeMailClient(endpoint:settings.imap,username:settings.username,password:credential.password,oauthBearer:credential.oauthBearer).folders()
        case .smtp:
            var request = NativeMailWireRequest(endpoint:settings.smtp,username:settings.username,password:credential.password,oauthBearer:credential.oauthBearer)
            request.smtpVerifyOnly = true; _ = try await NativeMailWire.perform(request); return []
        }
    }
}

final class NativeMailAccountEditor: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:790,height:595),styleMask:[.titled],backing:.buffered,defer:false)
    private let service:CRMService, store:NativeMailSecretStore, probe:NativeMailConnectionCheck.Probe
    private let expected:NativeRecord?
    private let label = NSTextField(), username = NSTextField(), password = NSSecureTextField()
    private let imapHost = NSTextField(), imapPort = NSTextField(), smtpHost = NSTextField(), smtpPort = NSTextField()
    private let imapTLS = NSPopUpButton(), smtpTLS = NSPopUpButton(), sentFolder = NSComboBox()
    private let selfSigned = NSButton(checkboxWithTitle:"自己署名のサーバー証明書を許可する",target:nil,action:nil)
    private let message = NSTextField(wrappingLabelWithString:"")
    private var buttons:[NSButton] = [], cancelCheck:NSButton!, initial:[String] = []
    private var task:Task<Void,Never>?, busy = false
    var onSaved:((NativeRecord) -> Void)?
    init(service:CRMService,store:NativeMailSecretStore,account:NativeRecord? = nil,probe:@escaping NativeMailConnectionCheck.Probe = NativeMailConnectionCheck.run) throws {
        try service.authenticated(); self.service = service; self.store = store; self.probe = probe
        let settings:NativeMailAccountSettings
        if let account { let live = try service.mailAccount(account["id"].string); guard live.revision == account.revision else { throw NativeDBError.conflict }; expected = live; settings = try service.mailSettings(live) }
        else { expected = nil; settings = .init(label:"",username:"",imap:.init(host:"",port:993,tls:.implicitTLS),smtp:.init(host:"",port:587,tls:.startTLS)) }
        super.init(); window.title = account == nil ? "メールアカウントを追加" : "メールアカウントを編集"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"メール事業者が案内するIMAP・SMTPの設定を入力してください。パスワードはこのMacのキーチェーンに保存します。アプリ専用パスワードが必要な場合は、そのパスワードを使います。")
        label.stringValue = settings.label; username.stringValue = settings.username
        password.placeholderString = account == nil ? "メールのパスワード" : "保存済み・変更する場合だけ入力"
        imapHost.stringValue = settings.imap.host; imapPort.stringValue = String(settings.imap.port)
        smtpHost.stringValue = settings.smtp.host; smtpPort.stringValue = String(settings.smtp.port)
        for popup in [imapTLS,smtpTLS] {
            for (name,mode) in [("SSL/TLS",NativeMailTLS.implicitTLS),("STARTTLS（必須）",.startTLS),("暗号化なし",.plain)] { popup.addItem(withTitle:name); popup.lastItem?.tag = mode.rawValue }
        }
        smtpTLS.addItem(withTitle:"STARTTLS（対応時）"); smtpTLS.lastItem?.tag = NativeMailTLS.automaticSMTP.rawValue
        imapTLS.selectItem(withTag:settings.imap.tls.rawValue); smtpTLS.selectItem(withTag:settings.smtp.tls.rawValue)
        sentFolder.stringValue = settings.sentFolder; sentFolder.completes = false; selfSigned.state = settings.imap.allowSelfSigned ? .on : .off
        let incoming = serverRow(host:imapHost,port:imapPort,tls:imapTLS,prefix:"IMAP"), outgoing = serverRow(host:smtpHost,port:smtpPort,tls:smtpTLS,prefix:"SMTP")
        let checks = NSStackView(views:[button("受信接続・フォルダを確認",#selector(checkInbox)),button("送信接続を確認",#selector(checkSMTP))]); checks.spacing = 12
        cancelCheck = InvoiceMailUI.button("接続確認を中止",target:self,action:#selector(cancel)); checks.addArrangedSubview(cancelCheck)
        let note = NSTextField(wrappingLabelWithString:"接続確認ではメールを送信しません。「暗号化なし」では認証情報を含む通信が暗号化されません。設定を保存すると、使用中のアカウントは同期の対象になります。")
        note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3; message.setAccessibilityLabel("メール接続の結果")
        let close = button("キャンセル",#selector(close)); close.keyEquivalent = "\u{1b}"
        let save = button("設定を保存",#selector(save)); save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let footer = NSStackView(views:[NSView(),close,save]); footer.spacing = 12
        InvoiceMailUI.layout(window,[title,help,row("表示名",label),row("利用者名",username),row("パスワード",password),row("受信（IMAP）",incoming),row("送信（SMTP）",outgoing),row("送信済みフォルダ",sentFolder),selfSigned,checks,note,message,footer])
        label.setAccessibilityLabel("メールの表示名"); username.setAccessibilityLabel("メールの利用者名"); password.setAccessibilityLabel("メールのパスワード")
        initial = fingerprint; controls()
    }
    deinit { task?.cancel() }
    private var inputs:[NSControl] { [label,username,password,imapHost,imapPort,smtpHost,smtpPort,imapTLS,smtpTLS,sentFolder,selfSigned] }
    private var fingerprint:[String] { [label.stringValue,username.stringValue,password.stringValue,imapHost.stringValue,imapPort.stringValue,smtpHost.stringValue,smtpPort.stringValue,String(imapTLS.selectedTag()),String(smtpTLS.selectedTag()),sentFolder.stringValue,String(selfSigned.state.rawValue)] }
    private func button(_ title:String,_ selector:Selector) -> NSButton { let result = InvoiceMailUI.button(title,target:self,action:selector); buttons.append(result); return result }
    private func row(_ label:String,_ control:NSView) -> NSStackView {
        let name = NSTextField(labelWithString:label); name.widthAnchor.constraint(equalToConstant:115).isActive = true
        control.setAccessibilityLabel(label); control.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let result = NSStackView(views:[name,control]); result.spacing = 12; return result
    }
    private func serverRow(host:NSTextField,port:NSTextField,tls:NSPopUpButton,prefix:String) -> NSStackView {
        host.placeholderString = prefix.lowercased()+".example.com"; host.setAccessibilityLabel(prefix+"サーバー")
        port.setAccessibilityLabel(prefix+"ポート"); port.widthAnchor.constraint(equalToConstant:65).isActive = true
        tls.setAccessibilityLabel(prefix+"暗号化"); tls.widthAnchor.constraint(equalToConstant:160).isActive = true
        host.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let result = NSStackView(views:[host,NSTextField(labelWithString:"ポート"),port,tls]); result.spacing = 8; return result
    }
    private func settings() throws -> NativeMailAccountSettings {
        guard let imapMode = NativeMailTLS(rawValue:imapTLS.selectedTag()), let smtpMode = NativeMailTLS(rawValue:smtpTLS.selectedTag()) else { throw NativeDBError.conflict }
        let value = NativeMailAccountSettings(label:label.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),username:username.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),imap:.init(host:imapHost.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),port:Int(imapPort.stringValue) ?? 0,tls:imapMode,allowSelfSigned:selfSigned.state == .on),smtp:.init(host:smtpHost.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),port:Int(smtpPort.stringValue) ?? 0,tls:smtpMode,allowSelfSigned:selfSigned.state == .on),sentFolder:sentFolder.stringValue)
        try value.validate(); return value
    }
    private func controls() { inputs.forEach{$0.isEnabled = !busy}; buttons.forEach{$0.isEnabled = !busy}; cancelCheck.isEnabled = busy }
    private func show(_ text:String,error:Bool = false) { message.stringValue = text; message.textColor = error ? .systemRed : .secondaryLabelColor }
    private func check(_ kind:NativeMailConnectionCheck.Kind) {
        guard !busy else { return }
        do {
            try service.authenticated(); let configuration = try settings(), credential:NativeMailCredential
            if password.stringValue.isEmpty, let expected { credential = try service.mailCredential(expected,store:store,interactive:true) }
            else { credential = NativeMailCredential(password:password.stringValue); try credential.validate() }
            busy = true; controls(); show("メールサーバーへの接続を確認しています…")
            let probe = probe
            task = Task { @MainActor [weak self] in
                do {
                    let folders = try await probe(configuration,credential,kind); try Task.checkCancellation()
                    guard let self else { return }; try self.service.authenticated()
                    if let expected = self.expected { guard try self.service.mailAccount(expected["id"].string).revision == expected.revision else { throw NativeDBError.conflict } }
                    if kind == .inbox { let selected = self.sentFolder.stringValue; self.sentFolder.removeAllItems(); self.sentFolder.addItems(withObjectValues:folders); self.sentFolder.stringValue = selected; self.show("受信サーバーに接続できました。送信済みフォルダを候補から選べます。") }
                    else { self.show("送信サーバーの認証を確認しました。メールは送信していません。") }
                } catch {
                    let cancelled = error is CancellationError || (error as? NativeMailFailure) == .cancelled
                    self?.show(cancelled ? "接続確認を中止しました。" : error.localizedDescription,error:!cancelled)
                }
                self?.task = nil; self?.busy = false; self?.controls()
            }
        } catch { show(error.localizedDescription,error:true) }
    }
    @objc private func checkInbox() { check(.inbox) }
    @objc private func checkSMTP() { check(.smtp) }
    @objc private func cancel() { task?.cancel() }
    @objc private func save() {
        guard !busy else { return }
        do {
            let row:NativeRecord, settings = try settings()
            if let expected { row = try service.updateMailAccount(expected,settings:settings,password:password.stringValue.isEmpty ? nil : password.stringValue,store:store) }
            else { row = try service.createMailAccount(settings,password:password.stringValue,store:store) }
            password.stringValue = ""; initial = fingerprint; onSaved?(row); window.sheetParent?.endSheet(window)
        } catch { show(error.localizedDescription,error:true) }
    }
    func confirmDiscard() -> Bool { !busy && (fingerprint == initial || InvoiceMailUI.discard("メールアカウントの変更を保存せずに閉じますか？")) }
    @objc private func close() { guard !busy && confirmDiscard() else { return }; window.sheetParent?.endSheet(window) }
}

final class NativeMailAccountsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    typealias Authorize = (GoogleCalendarClientSettings,String?) async throws -> GoogleMailGrant
    typealias GoogleClient = () throws -> GoogleCalendarClientSettings?
    static func bundledGoogleClient() throws -> GoogleCalendarClientSettings? {
        guard let client=try NativeDistributionConfiguration.googleClient() else{return nil}
        return try GoogleCalendarClientSettings(clientID:client.clientID,clientSecret:client.clientSecret).validated()
    }
    static func browser(client:GoogleCalendarClientSettings,loginHint:String?) async throws -> GoogleMailGrant {
        try await GoogleMailOAuth.browser(client:client,loginHint:loginHint,open:{url in
            try Task.checkCancellation()
            let opened=await MainActor.run{NSWorkspace.shared.open(url)}
            guard opened else{throw NativeDBError.message("Googleログインのブラウザを開けませんでした。")}
        })
    }
    private let googleClient:GoogleClient, authorize:Authorize
    private var authorization:Task<Void,Never>?

    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:681),styleMask:[.titled],backing:.buffered,defer:false)
    private let allowsProcessing:Bool
    private let service:CRMService, store:NativeMailSecretStore, probe:NativeMailConnectionCheck.Probe
    private let table = NSTableView(), info = NSTextField(labelWithString:""), message = NSTextField(wrappingLabelWithString:"")
    private let syncInfo = NSTextField(wrappingLabelWithString:"")
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.mail-accounts")
    private var rows:[NativeRecord] = [], jobs:[String:NativeJob] = [:], errors:[String:String] = [:], buttons:[String:NSButton] = [:]
    private var offset = 0, total = 0, generation = 0, loading = false
    private var observer:NSObjectProtocol?, editor:NativeMailAccountEditor?
    private var composer:NativeMailComposeWindow?, history:NativeMailHistoryWindow?, mailbox:NativeMailMailboxWindow?
    private let columns = [NativeColumn(title:"表示名",fraction:0.25),NativeColumn(title:"利用者名",fraction:0.34),NativeColumn(title:"状態",fraction:0.17),NativeColumn(title:"最終同期",fraction:0.24)]
    var onChanged:(() -> Void)?
    init(service:CRMService,store:NativeMailSecretStore,probe:@escaping NativeMailConnectionCheck.Probe = NativeMailConnectionCheck.run,allowsProcessing:Bool = true,googleClient:@escaping GoogleClient = NativeMailAccountsWindow.bundledGoogleClient,authorize:@escaping Authorize = NativeMailAccountsWindow.browser) throws {
        try service.authenticated(); self.service = service; self.store = store; self.probe = probe; self.allowsProcessing = allowsProcessing; self.googleClient=googleClient; self.authorize=authorize; super.init(); window.title = "メールアカウント"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"自分のメールアカウントを管理します。受信トレイと送信済みフォルダを、アプリ起動中は約15分ごとに同期します。初回は直近180日分を取り込みます。")
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let column = NSTableColumn(identifier:.init("mail-account")); column.width = 1000; table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38; table.delegate = self; table.dataSource = self; table.setAccessibilityLabel("自分のメールアカウント")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:230).isActive = true
        let actions = NSStackView(views:[button("add","アカウントを追加…",#selector(add)),button("edit","設定を編集…",#selector(edit)),button("active","同期を停止",#selector(toggle)),button("sync","今すぐ同期",#selector(synchronize)),button("delete","アカウントを削除…",#selector(remove))]); actions.spacing = 8
        let googleActions=NSStackView(views:[button("google","Googleでログイン…",#selector(signInGoogle)),button("googleReconnect","Googleを接続し直す…",#selector(reconnectGoogle)),button("googleCancel","Googleログインを中止",#selector(cancelGoogle)),NSView()]);googleActions.spacing=8
        let mailActions = NSStackView(views:[button("mailbox","メールを開く…",#selector(openMailbox)),button("compose","メールを作成…",#selector(compose)),button("history","送信履歴…",#selector(openHistory)),NSView()]); mailActions.spacing = 8
        message.maximumNumberOfLines = 3; message.setAccessibilityLabel("メール設定の結果"); syncInfo.maximumNumberOfLines = 3; syncInfo.setAccessibilityLabel("メールの同期状況")
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("reload","再読み込み",#selector(reload)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        InvoiceMailUI.layout(window,[title,help,googleActions,header,scroll,actions,mailActions,syncInfo,message,footer]); load()
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.service.db.url.path, self.window.attachedSheet == nil, self.authorization == nil else { return }; self.load()
        }
    }
    deinit { authorization?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func button(_ key:String,_ title:String,_ action:Selector) -> NSButton { let b = InvoiceMailUI.button(title,target:self,action:action); buttons[key] = b; return b }
    private var selected:NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private func controls() {
        let ready = !loading && authorization == nil && window.attachedSheet == nil; buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready
        buttons["googleCancel"]?.isEnabled = authorization != nil
        buttons["googleReconnect"]?.isEnabled = ready && selected != nil
        for key in ["edit","active","delete"] { buttons[key]?.isEnabled = ready && selected != nil }
        let active = selected?["isActive"] == .integer(1), job = selected.flatMap{jobs[$0["id"].string]}
        buttons["active"]?.title = active ? "同期を停止" : "同期を再開"
        buttons["sync"]?.isEnabled = ready && active && !["pending","running"].contains(job?.status ?? "")
        buttons["compose"]?.isEnabled = ready && selected != nil; buttons["history"]?.isEnabled = ready && selected != nil
        buttons["mailbox"]?.isEnabled = ready && selected != nil
        if !allowsProcessing { for key in ["sync","compose","history","mailbox"] {buttons[key]?.isEnabled=false} }
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
        if let selected { syncInfo.stringValue = (active ? Self.status(job) : "同期を停止中")+(errors[selected["id"].string].map{ "："+$0 } ?? "") }
        else { syncInfo.stringValue = "アカウントを選択すると同期状況を表示します。" }
    }
    private func load() {
        guard authorization == nil else{return}
        generation += 1; let version = generation, start = offset, selectedID = selected?["id"].string; loading = true; controls()
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { () -> (rows:[NativeRecord],total:Int,jobs:[String:NativeJob],errors:[String:String]) in
                let page = try self.service.mailAccounts(offset:start); var jobs:[String:NativeJob] = [:], errors:[String:String] = [:]
                for row in page.rows { let id = row["id"].string; jobs[id] = try self.service.mailSyncJob(id); if let error = try self.service.db.metadata(NativeMailJobs.error(id)), !error.isEmpty { errors[id] = error } }
                return (page.rows,page.total,jobs,errors)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                switch result {
                case let .success(page):
                    if page.rows.isEmpty && start > 0 { self.offset = max(0,(max(0,page.total-1)/100)*100); self.load(); return }
                    self.rows = page.rows; self.total = page.total; self.jobs = page.jobs; self.errors = page.errors
                case let .failure(error): self.rows = []; self.total = 0; self.jobs = [:]; self.errors = [:]; self.show(error.localizedDescription,error:true)
                }
                self.table.reloadData(); if let index = self.rows.firstIndex(where:{$0["id"].string == selectedID}) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
                self.loading = false; self.controls()
            }
        }
    }
    private func show(_ text:String,error:Bool = false) { message.stringValue = text; message.textColor = error ? .systemRed : .secondaryLabelColor }
    private func google(_ expected:NativeRecord?) {
        guard !loading,authorization == nil,window.attachedSheet == nil else{return}
        do {
            guard let client=try googleClient() else{throw GoogleMailFailure.unavailable}
            let ticket=try service.beginGoogleMailAuthorization(client:client,expected:expected)
            show("ブラウザでGoogleのメールへのアクセスを許可してください。パスワードやサーバー設定の入力は不要です。")
            authorization=Task { @MainActor [weak self] in
                guard let self else{return}
                defer{self.authorization=nil;self.load()}
                do {
                    let grant=try await self.authorize(ticket.client,ticket.expected?["username"].string)
                    try Task.checkCancellation()
                    guard try self.googleClient() == ticket.client else{throw NativeDBError.message("配布版のGoogleログイン設定が変更されました。もう一度ログインしてください。") }
                    let account=try self.service.completeGoogleMailAuthorization(ticket,grant:grant,store:self.store)
                    if self.allowsProcessing { _ = try self.service.requestMailSync(account);self.onChanged?() }
                    self.show(self.allowsProcessing ? "Googleメールを接続しました。同期を開始します。":"Googleメールの設定を保存しました。同期は再開の確認待ちです。")
                } catch {
                    if error is CancellationError { self.show("Googleログインを中止しました。") }
                    else if error is GoogleMailFailure || error is NativeDBError || error is NativeMailFailure {self.show(error.localizedDescription,error:true)}
                    else{self.show(GoogleMailFailure.temporary.localizedDescription,error:true)}
                }
            }
            controls()
        } catch{show(error.localizedDescription,error:true)}
    }
    @objc private func signInGoogle(){google(nil)}
    @objc private func reconnectGoogle(){guard let selected else{return};google(selected)}
    @objc private func cancelGoogle(){authorization?.cancel();show("Googleログインを中止しています…")}
    @MainActor func cancelAuthorizationAndDrain() async {let task=authorization;task?.cancel();await task?.value}
    private func openEditor(_ row:NativeRecord?) {
        guard !loading && authorization == nil && window.attachedSheet == nil else { return }
        do {
            let controller = try NativeMailAccountEditor(service:service,store:store,account:row,probe:probe); editor = controller
            controller.onSaved = { [weak self] saved in
                guard let self else { return }; self.show("メールアカウントを保存しました。")
                if self.allowsProcessing && saved["isActive"] == .integer(1) { do { _ = try self.service.requestMailSync(saved) } catch { self.show("設定は保存しましたが、同期を開始できませんでした。"+error.localizedDescription,error:true) } }
                self.onChanged?()
            }
            window.beginSheet(controller.window) { [weak self] _ in self?.editor = nil; self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true); load() }
    }
    @objc private func add() { openEditor(nil) }
    @objc private func edit() { if let selected { openEditor(selected) } }
    @objc private func compose() {
        guard allowsProcessing else { show("送信・同期の再開を確認してから操作してください。",error:true);return }
        guard !loading && authorization == nil && window.attachedSheet == nil, let selected else { return }
        do {
            let controller = try NativeMailComposeWindow(service:service,accountID:selected["id"].string); composer = controller
            controller.onQueued = { [weak self] _ in self?.show("送信待ちに追加しました。「送信履歴」で結果を確認できます。"); self?.onChanged?() }
            window.beginSheet(controller.window) { [weak self] _ in self?.composer = nil; self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true); load() }
    }
    @objc private func openMailbox() {
        guard allowsProcessing else { show("送信・同期の再開を確認してから操作してください。",error:true);return }
        guard !loading && authorization == nil && window.attachedSheet == nil, let selected else { return }
        do {
            let controller = try NativeMailMailboxWindow(service:service,accountID:selected["id"].string); mailbox = controller
            controller.onChanged = { [weak self] in self?.onChanged?() }
            window.beginSheet(controller.window) { [weak self] _ in self?.mailbox = nil; self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true); load() }
    }
    @objc private func openHistory() {
        guard allowsProcessing else { show("送信・同期の再開を確認してから操作してください。",error:true);return }
        guard !loading && authorization == nil && window.attachedSheet == nil, let selected else { return }
        do {
            let controller = try NativeMailHistoryWindow(service:service,accountID:selected["id"].string); history = controller
            controller.onChanged = { [weak self] in self?.onChanged?() }
            window.beginSheet(controller.window) { [weak self] _ in self?.history = nil; self?.load() }; controls()
        } catch { show(error.localizedDescription,error:true); load() }
    }
    @objc private func toggle() {
        guard !loading && authorization == nil && window.attachedSheet == nil, let selected else { return }
        do { let row = try service.setMailAccountActive(selected,active:selected["isActive"] != .integer(1)); if allowsProcessing && row["isActive"] == .integer(1) { _ = try service.requestMailSync(row) }; onChanged?(); show(row["isActive"] == .integer(1) ? (allowsProcessing ? "メールの同期を再開しました。":"設定を保存しました。同期は再開の確認待ちです。") : "メールの同期を停止しました。保存済みのメールは残ります。") }
        catch { show(error.localizedDescription,error:true) }; load()
    }
    @objc private func synchronize() {
        guard allowsProcessing else { show("送信・同期の再開を確認してから操作してください。",error:true);return }
        guard !loading && authorization == nil && window.attachedSheet == nil, let selected else { return }
        do { _ = try service.requestMailSync(selected); onChanged?(); show("メールの同期を受け付けました。") } catch { show(error.localizedDescription,error:true) }; load()
    }
    @objc private func remove() {
        guard !loading && authorization == nil && window.attachedSheet == nil, let selected else { return }
        let alert = NSAlert(); alert.messageText = "メールアカウントを削除しますか？"; alert.informativeText = selected["label"].string+" と、このMacに取り込んだメール・関連付け・送信待ちを削除します。メールサーバー上のメールは削除しません。"; alert.addButton(withTitle:"アカウントを削除"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] result in
            guard let self else { return }; if result == .alertFirstButtonReturn { do { try self.service.deleteMailAccount(selected,store:self.store); self.onChanged?(); self.show("メールアカウントを削除しました。") } catch { self.show(error.localizedDescription,error:true) } }; self.load()
        }; controls()
    }
    func confirmDiscard() -> Bool { authorization == nil && window.attachedSheet == nil && editor == nil && composer == nil && history == nil && mailbox == nil }
    @objc private func close() { guard confirmDiscard() else { return }; generation += 1; window.sheetParent?.endSheet(window) }
    @objc private func reload() { guard authorization == nil && window.attachedSheet == nil else { return }; load() }
    @objc private func previous() { guard authorization == nil && !loading else { return }; offset = max(0,offset-100); load() }
    @objc private func next() { guard authorization == nil && !loading && offset+100 < total else { return }; offset += 100; load() }
    private static func status(_ job:NativeJob?) -> String { switch job?.status { case "pending":return "同期待ち"; case "running":return "同期中"; case "retry":return "再試行待ち"; case "done":return "同期完了"; case "failed":return "同期エラー"; default:return "未同期" } }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification:Notification) { controls(); table.enumerateAvailableRowViews{row,_ in row.subviews.forEach{$0.needsDisplay = true}} }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let record = rows[row], identifier = NSUserInterfaceItemIdentifier("mail-account-row")
        let cell = table.makeView(withIdentifier:identifier,owner:self) as? LightweightTableCell ?? LightweightTableCell(); cell.identifier = identifier
        var last = "未同期"; if let date = try? NativeCalendarEvents.date(record["lastSyncedAt"].string) { let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm"; last = f.string(from:date) }
        cell.configure(columns:columns,values:[record["label"].string,record["username"].string,record["isActive"] == .integer(1) ? Self.status(jobs[record["id"].string]) : "停止中",last]); return cell
    }
}
