import AppKit

final class CalendlySettingsWindow: NSObject,NSTextFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:920,height:740),styleMask:[.titled],backing:.buffered,defer:false)
    private let allowsProcessing:Bool
    private let service: CRMService, store: CalendlySecretStore, manager: CalendlySubscriptionManager
    private let allowLoopbackHTTP: Bool, relayRequest: CalendlyRelayClient.Request
    private let url = NSTextField(), auth = NSSecureTextField(), token = NSSecureTextField(), signing = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString:""), syncStatus = NSTextField(wrappingLabelWithString:""), message = NSTextField(wrappingLabelWithString:"")
    private let advanced = NSPopUpButton(frame:.zero,pullsDown:true)
    private var buttons = [String:NSButton](), menuItems = [String:NSMenuItem](), state = CalendlyControlState(), originalURL = ""
    private var busy = false, task: Task<Void,Never>?, observer: NSObjectProtocol?
    var onChanged: (() -> Void)?
    init(service: CRMService,store: CalendlySecretStore,allowLoopbackHTTP: Bool = false,apiRequest: @escaping CalendlyAPIClient.Request = CalendlyRelayClient.network,relayRequest: @escaping CalendlyRelayClient.Request = CalendlyRelayClient.network,allowsProcessing:Bool = true) throws {
        try service.requireCalendlyAdmin(); self.service = service; self.store = store; self.allowLoopbackHTTP = allowLoopbackHTTP; self.relayRequest = relayRequest; self.allowsProcessing = allowsProcessing
        manager = CalendlySubscriptionManager(service:service,store:store,allowLoopbackHTTP:allowLoopbackHTTP,apiRequest:apiRequest,relayRequest:relayRequest,validate:{try Self.validateSettingsOperation(service,allowsProcessing:allowsProcessing)})
        super.init(); window.title = "Calendlyの予約連携"
        let title = NSTextField(labelWithString:window.title); title.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"Calendlyの予約・取消をCRMに取り込みます。Macが休止中も通知を保存できる外部の受信窓口が必要です。アプリ起動中は1分ごとと、起動・復帰時に確認します。")
        url.placeholderString = "https://受信窓口のホスト名"; auth.placeholderString = "受信窓口の接続キー"
        token.placeholderString = "Calendlyの個人用アクセストークン"; signing.placeholderString = "未設定なら自動生成・保存済みなら空欄で維持"
        for field in [url,auth,token,signing] { field.delegate = self }
        let fields = [InvoiceMailUI.row("受信URL",url),InvoiceMailUI.row("接続キー",auth),InvoiceMailUI.row("APIトークン",token),InvoiceMailUI.row("署名キー",signing)]
        let note = NSTextField(wrappingLabelWithString:"認証情報はこのMacのキーチェーンに保存します。Calendlyでユーザー情報とWebhookの読み取り・書き込みを許可したトークンを使用してください。保存済みの秘密情報は表示せず、空欄なら維持します。")
        note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor
        let settings = NSStackView(views:[button("save","接続設定を保存",#selector(save)),button("token","APIトークンだけ更新",#selector(updateToken)),NSView()]); settings.spacing = 8
        status.setAccessibilityLabel("Calendlyの登録状況"); syncStatus.setAccessibilityLabel("Calendlyの取込状況"); message.setAccessibilityLabel("Calendly設定の結果")
        status.maximumNumberOfLines = 4; syncStatus.maximumNumberOfLines = 4; message.maximumNumberOfLines = 3
        let actions = NSStackView(views:[button("register","通知を登録",#selector(register)),button("unregister","通知登録を解除…",#selector(unregister)),button("resume","処理を再開",#selector(resume)),button("sync","今すぐ取り込む",#selector(synchronize))]); actions.spacing = 8
        advanced.addItem(withTitle:"その他の操作")
        for (key,title,action) in [("takeover","未完了の設定を引き継ぐ",#selector(takeOver)),("owner","自動取込の担当を引き継ぐ",#selector(takeOverSync)),("restart","受信キーの設定をやり直す",#selector(restartPreparation)),("cancel","作成前の設定処理を中止",#selector(cancelPreparation)),("review","未作成と確認して再試行…",#selector(review)),("remove","保存した接続設定を削除…",#selector(remove))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; advanced.menu!.addItem(item); menuItems[key] = item
        }
        advanced.menu?.autoenablesItems = false; advanced.setAccessibilityLabel("Calendlyのその他の操作")
        let advancedRow = NSStackView(views:[advanced,NSView()])
        let footer = NSStackView(views:[button("reload","再読み込み",#selector(reload)),NSView(),button("stop","接続確認を中止",#selector(stop)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        InvoiceMailUI.layout(window,[title,help]+fields+[note,settings,status,syncStatus,actions,advancedRow,message,NSView(),footer])
        try refresh(resetForm:true)
        observer = NotificationCenter.default.addObserver(forName:InvoiceJobRunner.didProcess,object:nil,queue:.main) { [weak self] note in
            guard let self, note.userInfo?["database"] as? String == self.service.db.url.path, !self.busy, self.window.attachedSheet == nil else { return }
            do { try self.refresh() } catch { self.show(error) }
        }
    }
    deinit { task?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func button(_ key: String,_ title: String,_ action: Selector) -> NSButton { let value = InvoiceMailUI.button(title,target:self,action:action); buttons[key] = value; return value }
    private var dirty: Bool { url.stringValue != originalURL || !auth.stringValue.isEmpty || !token.stringValue.isEmpty || !signing.stringValue.isEmpty }
    private func controlJob() throws -> NativeJob? { try CalendlyJobs.last(db:service.db,event:CalendlyJobs.subscription) }
    private func controls() {
        let available = !busy, noOperation = state.operation == nil, configured = state.credentialID != nil
        let job = try? controlJob(), working = ["pending","retry","running"].contains(job?.status ?? "") && job?.payload["operationID"] == state.operation?.id
        buttons.values.forEach{$0.isEnabled = available}; url.isEnabled = available && noOperation; auth.isEnabled = url.isEnabled; signing.isEnabled = url.isEnabled; token.isEnabled = available
        buttons["save"]?.isEnabled = available && noOperation
        buttons["token"]?.isEnabled = available && configured && url.stringValue == originalURL && auth.stringValue.isEmpty && signing.stringValue.isEmpty && !token.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        buttons["register"]?.isEnabled = available && configured && noOperation && !dirty
        buttons["unregister"]?.isEnabled = available && state.registration != nil && noOperation && !dirty
        buttons["resume"]?.isEnabled = available && !dirty && state.operation?.actorID == service.identity.id && job?.status != "running"
        buttons["sync"]?.isEnabled = allowsProcessing && available && !dirty && noOperation && state.registration?.actorID == service.identity.id
        buttons["stop"]?.isEnabled = busy; buttons["close"]?.isEnabled = !busy
        menuItems.values.forEach{$0.isEnabled = available && !dirty && !working}
        menuItems["takeover"]?.isEnabled = available && !dirty && !working && state.operation != nil && state.operation?.actorID != service.identity.id
        menuItems["owner"]?.isEnabled = allowsProcessing && available && !dirty && noOperation && state.registration != nil && state.registration?.actorID != service.identity.id
        menuItems["restart"]?.isEnabled = available && !dirty && !working && state.operation?.actorID == service.identity.id && [.configure,.ready].contains(state.operation?.phase)
        menuItems["cancel"]?.isEnabled = available && !dirty && !working && state.operation?.actorID == service.identity.id && state.operation?.mode == .subscribe && state.operation?.phase != .creating && (state.operation?.phase == .prepare || state.registration == nil)
        menuItems["review"]?.isEnabled = available && !dirty && !working && state.operation?.actorID == service.identity.id && state.operation?.phase == .creating
        menuItems["remove"]?.isEnabled = available && !dirty && configured && noOperation && state.registration == nil
    }
    func controlTextDidChange(_ obj: Notification) { controls() }
    private static func phase(_ value: CalendlyControlState.Operation.Phase) -> String { switch value { case .prepare:return "接続先の確認"; case .deleteOld:return "以前の通知登録を解除"; case .configure:return "受信キーの設定"; case .ready:return "通知登録の作成待ち"; case .creating:return "通知登録の結果確認" } }
    private static func jobTitle(_ job: NativeJob?) -> String { guard let job else { return "未実行" }; switch job.status { case "pending":return "実行待ち"; case "running":return "処理中"; case "retry":return "再試行待ち"; case "done":return "完了"; case "needs_review":return "結果の確認が必要"; case "cancelled":return "中止"; default:return "エラー・再開できます" } }
    private func refresh(resetForm: Bool = false) throws {
        state = try service.calendlyControl()
        if resetForm { originalURL = try CalendlyRelayBinding.load(db:service.db)?.publicURL ?? ""; url.stringValue = originalURL; auth.stringValue = ""; token.stringValue = ""; signing.stringValue = "" }
        let configured = state.credentialID != nil; auth.placeholderString = configured ? "保存済み・変更する場合だけ入力" : "受信窓口の接続キー"; token.placeholderString = configured ? "保存済み・変更する場合だけ入力" : "Calendlyの個人用アクセストークン"
        if let op = state.operation {
            let job = try controlJob(); status.stringValue = "通知設定："+Self.phase(op.phase)+"（"+Self.jobTitle(job)+"）"+(job?.lastError.map{"\n"+$0} ?? "")
        } else if let reg = state.registration {
            let owner = try reg.actorID.flatMap{try service.db.get("Users",key:["id":.text($0)])?["name"].string} ?? "管理者による引き継ぎが必要"
            status.stringValue = "通知登録：登録済み"+(reg.credentialID == state.credentialID ? "" : "・保存した設定で再登録してください")+"\n自動取込の担当："+owner
        } else { status.stringValue = configured ? "接続設定は保存済みです。「通知を登録」で予約通知の受信を開始します。" : "接続設定を保存してください。" }
        let job = try CalendlyJobs.last(db:service.db,event:CalendlyJobs.sync), stamp = try service.db.metadata("calendlyRelay.lastSyncedAt.v1")
        var last = "まだ取り込んでいません"
        if let stamp, let date = try? NativeCalendarEvents.date(stamp) { let f = DateFormatter(); f.locale = Locale(identifier:"ja_JP"); f.dateFormat = "yyyy/MM/dd HH:mm:ss"; last = f.string(from:date) }
        syncStatus.stringValue = "予約の取込："+Self.jobTitle(job)+"　最終確認："+last+(job?.lastError.map{"\n"+$0} ?? ""); controls()
    }
    private func show(_ error: Error) { message.textColor = .systemRed; message.stringValue = CalendlyJobWorker.message(error); controls() }
    private func run(_ success: String,resetForm: Bool = false,_ action: @escaping () async throws -> Void) {
        // NSAlert invokes its accepted completion while the sheet is detaching.
        // Modal input already gates the originating control; allow that confirmed
        // action to start here rather than silently dropping it.
        guard !busy else { return }; busy = true; message.stringValue = "処理しています…"; message.textColor = .secondaryLabelColor; controls()
        task = Task { @MainActor [weak self] in
            do { try await action(); guard let self else { return }; self.busy = false; self.task = nil; try self.refresh(resetForm:resetForm); self.message.textColor = .labelColor; self.message.stringValue = success; self.onChanged?() }
            catch { guard let self else { return }; self.busy = false; self.task = nil; try? self.refresh(); self.show(error) }
        }
    }
    func confirmDiscard() -> Bool { guard !busy, window.attachedSheet == nil else { return false }; return !dirty || InvoiceMailUI.discard("Calendly設定の変更を保存せずに閉じますか？") }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; window.sheetParent?.endSheet(window) }
    @objc private func stop() { task?.cancel() }
    @objc private func reload() { do { try refresh() } catch { show(error) } }
    @objc private func save() {
        let values = (url.stringValue,auth.stringValue,token.stringValue,signing.stringValue), service = service, store = store, allow = allowLoopbackHTTP, request = relayRequest
        run("接続設定を保存しました。",resetForm:true){try await service.saveCalendlySettings(publicURL:values.0,authKey:values.1,apiToken:values.2,signingKey:values.3,store:store,allowLoopbackHTTP:allow,request:request)}
    }
    private static func validateSettingsOperation(_ service:CRMService,allowsProcessing:Bool)throws {
        guard !allowsProcessing else{return}
        try service.requireCalendlyAdmin()
        try service.db.transaction {
            guard let operation=try service.calendlyControl().operation else{return}
            var offset=0
            while true {
                try Task.checkCancellation()
                let page=try service.db.jobs(events:[CalendlyJobs.subscription],offset:offset)
                if page.contains(where:{$0.payload["operationID"]==operation.id}) {
                    throw NativeDBError.message("この通知設定には既存の処理履歴があります。復元後の処理を確認してから再開してください。")
                }
                guard page.count==100 else{return};offset+=page.count
            }
        }
    }
    private func continueSubscription(_ manager:CalendlySubscriptionManager)async throws {
        if allowsProcessing {_ = try service.requestCalendlyJob(CalendlyJobs.subscription)}
        else {try Self.validateSettingsOperation(service,allowsProcessing:false);_ = try await manager.resume()}
    }
    @objc private func updateToken() {
        guard url.stringValue == originalURL, auth.stringValue.isEmpty, signing.stringValue.isEmpty else { show(NativeDBError.message("APIトークン以外の変更は「接続設定を保存」で保存してください。")); return }
        let value = token.stringValue, service = service, store = store, manager = manager
        run("APIトークンを更新しました。",resetForm:true){try service.replaceCalendlyAPIToken(value,store:store); if try service.calendlyControl().operation?.actorID == service.identity.id { try await self.continueSubscription(manager) } }
    }
    @objc private func register() { let manager = manager, service = service; run("通知登録の処理を開始しました。"){try await manager.begin(.subscribe); try await self.continueSubscription(manager)} }
    @objc private func unregister() { confirm("Calendlyの通知登録を解除しますか？","新しい予約通知の受信を止めます。取り込んだCRMの予定は残ります。",accept:"通知登録を解除") { [weak self] in guard let self else { return }; let manager = self.manager, service = self.service; self.run("通知登録の解除を開始しました。"){try await manager.begin(.unsubscribe); try await self.continueSubscription(manager)} } }
    @objc private func resume() {let manager=manager;run("通知設定の処理を進めました。"){try await self.continueSubscription(manager)}}
    @objc private func synchronize() { guard allowsProcessing else {show(NativeDBError.message("予定の取込は再開の確認待ちです。"));return}; do { _ = try service.requestCalendlyJob(CalendlyJobs.sync); try refresh(); onChanged?() } catch { show(error) } }
    @objc private func takeOver() { guard let id = state.operation?.id else { return }; let manager = manager, service = service; run("未完了の通知設定を引き継ぎました。"){try Self.validateSettingsOperation(service,allowsProcessing:self.allowsProcessing);try await manager.takeOverOperation(operationID:id); try await self.continueSubscription(manager)} }
    @objc private func takeOverSync() { guard allowsProcessing else {show(NativeDBError.message("予定の取込は再開の確認待ちです。"));return}; do { try service.takeOverCalendlySync(); _ = try service.requestCalendlyJob(CalendlyJobs.sync); try refresh(); onChanged?() } catch { show(error) } }
    @objc private func restartPreparation() { guard let id = state.operation?.id else { return }; let manager = manager, service = service; run("受信キーの設定をやり直しています。"){try await manager.restartReceiverPreparation(operationID:id); try await self.continueSubscription(manager)} }
    @objc private func cancelPreparation() { guard let id = state.operation?.id else { return }; let manager = manager; run("作成前の通知設定を中止しました。"){try await manager.cancelPreparation(operationID:id)} }
    @objc private func remove() { confirm("保存した接続設定を削除しますか？","このMacのキーチェーンから認証情報を削除します。受信済みの履歴と取込位置は残ります。",accept:"接続設定を削除") { [weak self] in guard let self else { return }; let service = self.service, store = self.store; self.run("接続設定を削除しました。",resetForm:true){try service.removeCalendlySettings(store:store)} } }
    private func confirm(_ title: String,_ detail: String,accept: String,action: @escaping () -> Void) {
        guard !busy, window.attachedSheet == nil else { return }; let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.addButton(withTitle:"キャンセル"); alert.addButton(withTitle:accept)
        alert.beginSheetModal(for:window){response in if response == .alertSecondButtonReturn { action() } }
    }
    @objc private func review() {
        guard !busy, let id = state.operation?.id, state.operation?.phase == .creating, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "Calendly側に通知登録がないことを確認しましたか？"; alert.informativeText = "作成要求が遅れて完了する可能性があります。Calendly側で未作成と確認した内容を記録してください。再度照合し、登録がなければ作成を再試行します。"
        let note = NSTextField(frame:NSRect(x:0,y:0,width:560,height:28)); note.placeholderString = "確認した内容"; note.setAccessibilityLabel("未作成の確認内容"); alert.accessoryView = note; alert.addButton(withTitle:"キャンセル"); alert.addButton(withTitle:"確認内容を記録して再試行")
        alert.beginSheetModal(for:window){[weak self] response in guard response == .alertSecondButtonReturn, let self else { return }; let manager = self.manager, service = self.service, text = note.stringValue
            self.run("確認内容を記録し、作成を再試行します。"){try await manager.confirmCreateNotApplied(operationID:id,note:text); try await self.continueSubscription(manager)}
        }
    }
}
