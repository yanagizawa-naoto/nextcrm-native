import AppKit

final class CRMCampaignsWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1080,height:700),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let table = NSTableView(); private let search = NSSearchField(); private let status = NSPopUpButton()
    private let readiness: () async throws -> Void
    private let campaignAI: CampaignAIService?
    private let allowsDelivery: Bool
    private let message = NSTextField(wrappingLabelWithString:""); private let info = NSTextField(labelWithString:"")
    private var buttons: [String:NSButton] = [:]; private var rows: [CampaignListRow] = []; private var offset = 0; private var total = 0
    private var busy = false; private var loading = false; private var generation = 0; private var pending: DispatchWorkItem?
    private var editor: CRMEditor?; private var detail: CRMCampaignWindow?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.campaigns"); private let memory = MemoryBudget()
    init(service: CRMService, readiness: (() async throws -> Void)? = nil, ai: CampaignAIService? = nil, allowsDelivery: Bool = true) throws {
        self.campaignAI = ai; self.allowsDelivery = allowsDelivery;
        self.service = service; self.readiness = readiness ?? {try await CampaignLaunchWindow.validateDefault(service:service)}; try service.authenticated(); super.init(); window.title = "キャンペーン"
        let heading = NSTextField(labelWithString:"キャンペーン"); heading.font = .systemFont(ofSize:22,weight:.semibold)
        search.placeholderString = "キャンペーンを検索"; search.delegate = self; search.setAccessibilityLabel("キャンペーンを検索")
        status.addItems(withTitles:["すべての状態"]+CampaignWorkflow.states.map(CampaignWorkflow.label)); status.target = self; status.action = #selector(filterChanged); status.setAccessibilityLabel("キャンペーンの状態")
        let filters = NSStackView(views:[search,status]); filters.spacing = 8; search.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let actions = NSStackView(views:[button("new","新規キャンペーン…",#selector(create)),button("open","詳細・配信手順…",#selector(openSelected)),button("delete","削除…",#selector(remove)),NSView(),button("refresh","再読み込み",#selector(refresh))]); actions.spacing = 8
        let header = LightweightTableCell(); header.configure(columns:columns,values:columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let col = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("campaigns")); col.width = 1020; table.addTableColumn(col); table.headerView = nil; table.rowHeight = 40; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected); table.setAccessibilityLabel("キャンペーンの一覧")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        message.maximumNumberOfLines = 3; message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        let root = NSStackView(views:[heading,filters,actions,header,scroll,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:350)])
        for v in [filters,actions,header,scroll,message,footer] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }; load()
    }
    private var columns: [NativeColumn] { [NativeColumn(title:"キャンペーン名",fraction:0.30),NativeColumn(title:"状態",fraction:0.14),NativeColumn(title:"手順数",fraction:0.08),NativeColumn(title:"初回の予約日時",fraction:0.23),NativeColumn(title:"作成者",fraction:0.25)] }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].record : nil }
    private func button(_ id: String,_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private func controls() {
        let ready = !loading && !busy; buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready; search.isEnabled = !busy; status.isEnabled = !busy
        buttons["new"]?.isEnabled = ready && ["admin","manager","user"].contains(service.identity.role)
        buttons["open"]?.isEnabled = ready && selected != nil; buttons["delete"]?.isEnabled = ready && selected != nil && selected?["status"] != .text("sending")
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
    }
    private func load(delay: Double = 0) {
        pending?.cancel(); generation += 1; let version = generation, start = offset, term = search.stringValue, state = status.indexOfSelectedItem > 0 ? CampaignWorkflow.states[status.indexOfSelectedItem-1] : nil
        loading = true; controls()
        let work = DispatchWorkItem { [weak self] in guard let self else { return }; let result = Result{try self.service.campaigns(search:term,status:state,offset:start)}; DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == version else { return }
            switch result { case let .success(page): if page.rows.isEmpty && start > 0 { self.offset = max(0,(max(0,page.total-1)/100)*100); self.load(); return }; self.rows = page.rows; self.total = page.total
            case let .failure(error): self.rows = []; self.total = 0; self.message.stringValue = error.localizedDescription }
            self.table.reloadData(); self.loading = false; self.controls(); self.memory.settle()
        } }; pending = work; queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    @objc private func create() {
        guard !loading && !busy, window.attachedSheet == nil else { return }
        do { var created: NativeRecord?; let e = try CRMEditor(module:.campaignHeader,record:nil,linkedTo:nil,service:service,saveTitle:"下書きを作成",onSave:{[service] input in created = try service.createCampaign(input:input) }); editor = e
            window.beginSheet(e.window) { [weak self] response in
                // AppKit invokes completion before detaching the old sheet.
                // Open the detail on the next turn, after attachedSheet clears.
                DispatchQueue.main.async { [weak self] in guard let self else { return }; self.editor = nil; if response == .OK, let created { self.open(created) }; self.load() }
            }
        } catch { message.stringValue = error.localizedDescription }
    }
    private func open(_ record: NativeRecord) {
        guard window.attachedSheet == nil else { return }
        do { let d = try CRMCampaignWindow(campaign:service.campaign(record["id"].string),service:service,readiness:readiness,ai:campaignAI,allowsDelivery:allowsDelivery); detail = d; window.beginSheet(d.window) { [weak self] _ in self?.detail = nil; self?.load() } }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc private func openSelected() { guard !loading && !busy, let selected else { return }; open(selected) }
    @objc private func remove() {
        guard !loading && !busy, let selected, window.attachedSheet == nil else { return }
        let a = NSAlert(); a.messageText = "キャンペーンを削除しますか？"; a.informativeText = selected["name"].string+"\n配信手順と送信履歴は保存したまま、通常の一覧から除外します。"; a.addButton(withTitle:"削除"); a.addButton(withTitle:"キャンセル")
        a.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.busy = true; self.controls(); self.queue.async { [weak self] in guard let self else { return }; let result = Result{try self.service.deleteCampaign(selected)}; DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false; if case let .failure(error) = result { self.message.stringValue = error.localizedDescription }; self.load() } } }
    }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && detail?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; pending?.cancel(); window.sheetParent?.endSheet(window) }
    @objc private func refresh() { load() }; @objc private func filterChanged() { offset = 0; load() }
    @objc private func previous() { offset = max(0,offset-100); load() }; @objc private func next() { if offset+100 < total { offset += 100; load() } }
    func controlTextDidChange(_ notification: Notification) { offset = 0; load(delay:0.18) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { v,_ in v.subviews.forEach{$0.needsDisplay = true} } }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? { guard rows.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("campaign-row"); let c = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); c.identifier = id; c.configure(columns:columns,values:rows[row].cells); return c }
}

final class CRMCampaignWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1100,height:780),styleMask:[.titled],backing:.buffered,defer:false)
    private var campaign: NativeRecord; private let service: CRMService
    private let readiness: () async throws -> Void
    private let campaignAI: CampaignAIService?
    private let allowsDelivery: Bool
    private var launchWindow: CampaignLaunchWindow?; private var dispatchWindow: CampaignDispatchWindow?
    private var updates: CampaignJobUpdates?; private var refreshNeeded = false
    private let heading = NSTextField(labelWithString:""); private let summary = NSTextField(wrappingLabelWithString:""); private let message = NSTextField(wrappingLabelWithString:""); private let info = NSTextField(labelWithString:"")
    private let mode = NSSegmentedControl(labels:["配信手順","対象リスト","送信先の確認"],trackingMode:.selectOne,target:nil,action:nil)
    private let table = NSTableView(); private let header = LightweightTableCell(); private var buttons: [String:NSButton] = [:]
    private var rows: [NativeRecord] = []; private var cells: [[String]] = []; private var offset = 0; private var total = 0; private var loading = false; private var busy = false; private var generation = 0
    private var editor: CRMEditor?; private var picker: CRMReferencePicker?
    private var deliveryWindow: CRMCampaignDeliveryWindow?; private var stepEditor: CampaignStepEditor?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.campaign-detail"); private let memory = MemoryBudget()
    init(campaign: NativeRecord, service: CRMService, readiness: (() async throws -> Void)? = nil, ai: CampaignAIService? = nil, allowsDelivery: Bool = true) throws {
        self.campaignAI = ai; self.allowsDelivery = allowsDelivery;
        self.campaign = campaign; self.service = service; self.readiness = readiness ?? {try await CampaignLaunchWindow.validateDefault(service:service)}; super.init(); window.title = "キャンペーンの詳細"; heading.font = .systemFont(ofSize:22,weight:.semibold); heading.lineBreakMode = .byTruncatingTail
        summary.maximumNumberOfLines = 2; summary.font = .systemFont(ofSize:12); summary.textColor = .secondaryLabelColor
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        let actions = NSStackView(views:[button("settings","基本情報…",#selector(settings)),button("add","手順を追加…",#selector(add)),button("edit","手順を編集…",#selector(editStep)),button("remove","手順を削除…",#selector(remove)),button("history","送信履歴…",#selector(history)),NSView(),button("refresh","再読み込み",#selector(refresh))]); actions.spacing = 8
        let delivery = NSStackView(views:[button("send","今すぐ送信…",#selector(sendNow)),button("schedule","日時を指定して予約…",#selector(schedule)),button("pause","一時停止…",#selector(pause)),button("resume","送信を再開…",#selector(resume)),NSView(),button("jobs","配信予約・処理履歴…",#selector(dispatchHistory))]); delivery.spacing = 8
        header.heightAnchor.constraint(equalToConstant:26).isActive = true
        let col = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("campaign-details")); col.width = 1040; table.addTableColumn(col); table.headerView = nil; table.rowHeight = 40; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(editStep); table.setAccessibilityLabel("キャンペーンの配信設定")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        let note = NSTextField(wrappingLabelWithString:"送信履歴で宛先ごとの結果を確認できます。予約日時にアプリが停止している場合は、次の起動・復帰後に処理します。"); note.font = .systemFont(ofSize:12); note.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 3; message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        let footer = NSStackView(views:[info,NSView(),button("previous","前へ",#selector(previous)),button("next","次へ",#selector(next)),button("close","閉じる",#selector(close))]); footer.spacing = 8; buttons["close"]?.keyEquivalent = "\u{1b}"
        let root = NSStackView(views:[heading,summary,delivery,mode,actions,header,scroll,message,note,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:340)])
        for v in [heading,summary,delivery,actions,header,scroll,message,note,footer] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        updates = CampaignJobUpdates(db:service.db) { [weak self] in self?.jobsChanged() }; load()
    }
    private var selected: NativeRecord? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    private var columns: [NativeColumn] {
        switch mode.selectedSegment {
        case 1: return [NativeColumn(title:"対象リスト名",fraction:0.70),NativeColumn(title:"状態",fraction:0.30)]
        case 2: return [NativeColumn(title:"氏名",fraction:0.25),NativeColumn(title:"会社",fraction:0.30),NativeColumn(title:"メールアドレス",fraction:0.45)]
        default: return [NativeColumn(title:"順番",fraction:0.06),NativeColumn(title:"件名",fraction:0.31),NativeColumn(title:"テンプレート",fraction:0.27),NativeColumn(title:"初回からの日数",fraction:0.14),NativeColumn(title:"送信先",fraction:0.22)]
        }
    }
    private func button(_ id: String,_ title: String,_ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; buttons[id] = b; return b }
    private func controls() {
        let ready = !loading && !busy, editable = campaign["status"] != .text("sending"), tab = mode.selectedSegment
        buttons.values.forEach{$0.isEnabled = ready}; table.isEnabled = ready; mode.isEnabled = !busy
        buttons["settings"]?.isEnabled = ready && editable
        for (id,action) in [("send",CampaignLaunchAction.sendNow),("schedule",.schedule),("resume",.resume)] { buttons[id]?.isEnabled = ready && allowsDelivery && service.identity.elevated && action.permits(campaign["status"].string) }
        buttons["pause"]?.isEnabled = ready && allowsDelivery && ["scheduled","sending"].contains(campaign["status"].string)
        buttons["history"]?.isEnabled = ready && allowsDelivery; buttons["jobs"]?.isEnabled = ready && allowsDelivery
        buttons["add"]?.title = tab == 1 ? "対象リストを追加…" : "手順を追加…"; buttons["add"]?.isHidden = tab == 2; buttons["add"]?.isEnabled = ready && editable && tab != 2
        buttons["edit"]?.isHidden = tab != 0; buttons["edit"]?.isEnabled = ready && editable && tab == 0 && selected != nil
        buttons["remove"]?.title = tab == 1 ? "関連付けを解除…" : "手順を削除…"; buttons["remove"]?.isHidden = tab == 2; buttons["remove"]?.isEnabled = ready && editable && tab != 2 && selected != nil && !(tab == 0 && selected?["order"] == .integer(0) && campaign["status"] != .text("draft"))
        buttons["previous"]?.isEnabled = ready && offset > 0; buttons["next"]?.isEnabled = ready && offset+100 < total
        info.stringValue = "\(total == 0 ? 0 : offset+1)–\(min(offset+rows.count,total)) ／ \(total)件"
    }
    private struct Snapshot { let campaign: NativeRecord; let rows: [NativeRecord]; let cells: [[String]]; let total: Int; let note: String }
    private func load() {
        refreshNeeded = false
        generation += 1; let version = generation, id = campaign["id"].string, start = offset, tab = mode.selectedSegment; loading = true; controls(); header.configure(columns:columns,values:columns.map(\.title),heading:true)
        queue.async { [weak self] in guard let self else { return }; let result = Result { try self.service.db.transaction { () -> Snapshot in
            let campaign = try self.service.campaign(id)
            if tab == 1 { let p = try self.service.campaignTargetLists(id,offset:start); return Snapshot(campaign:campaign,rows:p.rows,cells:p.rows.map{[$0["name"].string,$0["deletedAt"] == .null ? "有効" : "削除済み（配信対象外）"]},total:p.total,note:"複数のリストに含まれる同じメールアドレスは、初回配信時に1件へまとめます。") }
            if tab == 2 { let p = try self.service.campaignAudience(id,offset:start); return Snapshot(campaign:campaign,rows:p.rows,cells:p.rows.map{[CRMModule.displayName($0),$0["company"].string,$0["email"].string]},total:p.unique,note:"対象\(p.members)件 → メールアドレス\(p.unique)件。配信停止\(p.suppressed)件、アドレス未登録\(p.withoutEmail)件、同一アドレスの重複\(p.eligible-p.unique)件を除外。実際の配信時に再確認します。") }
            let p = try self.service.campaignSteps(id,offset:start); var names: [String:String] = [:]
            let cells = try p.rows.map { r -> [String] in let key = r["template_id"].string; if names[key] == nil { names[key] = try self.service.db.page("crm_campaign_templates",fields:["name"],equal:["id":r["template_id"]],includeDeleted:true,limit:1).rows.first?["name"].string ?? "（テンプレートなし）" }; return [r["order"].string,r["subject"].string,names[key]!,r["order"] == .integer(0) ? "初回" : r["delay_days"].string+"日後",r["send_to"] == .text("non_openers") ? "初回が未開封の送信先" : "すべての送信先"] }
            return Snapshot(campaign:campaign,rows:p.rows,cells:cells,total:p.total,note:"初回は順番0です。フォローアップの日数は初回配信から数えます。各手順の画面で本文を編集したり、AIで作成できます。")
        } }; DispatchQueue.main.async { [weak self] in guard let self, self.generation == version else { return }
            switch result { case let .success(p): if p.rows.isEmpty && start > 0 { self.offset = max(0,(max(0,p.total-1)/100)*100); self.load(); return }; self.campaign = p.campaign; self.rows = p.rows; self.cells = p.cells; self.total = p.total; self.heading.stringValue = p.campaign["name"].string; self.summary.stringValue = CampaignWorkflow.label(p.campaign["status"].string)+"　差出人："+(p.campaign["from_name"].string.isEmpty ? "未設定" : p.campaign["from_name"].string)+"　返信先："+(p.campaign["reply_to"].string.isEmpty ? "未設定" : p.campaign["reply_to"].string); self.message.stringValue = p.note
            case let .failure(e): self.rows = []; self.cells = []; self.total = 0; self.message.stringValue = e.localizedDescription }
            self.table.reloadData(); self.loading = false; self.controls(); self.memory.settle()
            if self.refreshNeeded && !self.busy && self.window.attachedSheet == nil { self.load() }
        } }
    }
    private func edit(_ module: CRMModule, record: NativeRecord?, title: String? = nil, save: @escaping ([String:SQLValue]) throws -> Void) {
        guard !busy && !loading, window.attachedSheet == nil else { return }
        do { let e = try CRMEditor(module:module,record:record,linkedTo:nil,service:service,windowTitle:title,saveTitle:"保存",onSave:save); editor = e; window.beginSheet(e.window) { [weak self] _ in self?.editor = nil; self?.load() } }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc private func settings() { let expected = campaign; edit(.campaignHeader,record:expected) { [service] input in _ = try service.saveCampaign(expected,input:input) } }
    @objc private func add() {
        guard !busy && !loading, window.attachedSheet == nil else { return }; let expected = campaign
        if mode.selectedSegment == 1 {
            let picker = CRMReferencePicker(model:"crm_TargetLists",service:service,matching:.not(.relation(model:"CampaignToTargetLists",local:"id",foreign:"target_list_id",matching:.equal("campaign_id",expected["id"])))) { [weak self] record in guard let self else { return }; self.picker = nil; if let record { self.perform { [service = self.service] in _ = try service.setCampaignTargetList(campaign:expected,listID:record["id"].string,enabled:true) } } }; self.picker = picker; picker.window.title = "配信対象リストを追加"; window.beginSheet(picker.window); picker.start(); return
        }
        guard mode.selectedSegment == 0 else { return }
        do { let id = expected["id"]; let last = try service.db.page("crm_campaign_steps",fields:["order"],equal:["campaign_id":id],sort:"order",descending:true,limit:1).rows.first; let maxOrder = Int64(last?["order"].string ?? "-1") ?? -1; guard maxOrder < Int64.max else { throw NativeDBError.message("順番の上限に達しました。") }
            openStep(nil, nextOrder: maxOrder+1)
        } catch { message.stringValue = error.localizedDescription }
    }
    private func openStep(_ record: NativeRecord?, nextOrder: Int64 = 0) {
        guard !busy && !loading, window.attachedSheet == nil else { return }
        do {
            let editor = try CampaignStepEditor(service: service, campaign: campaign, original: record, nextOrder: nextOrder, ai: campaignAI, allowsAI: allowsDelivery)
            stepEditor = editor; window.beginSheet(editor.window) { [weak self] _ in self?.stepEditor = nil; self?.load() }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func editStep() { guard mode.selectedSegment == 0, let selected else { return }; openStep(selected) }
    private func perform(_ work: @escaping () throws -> Void) {
        guard !busy && !loading else { return }; busy = true; controls()
        queue.async { [weak self] in let result = Result{try work()}; DispatchQueue.main.async { [weak self] in guard let self else { return }; self.busy = false; switch result { case .success:self.load(); case let .failure(e):self.message.stringValue = e.localizedDescription; self.controls() } } }
    }
    @objc private func remove() {
        guard !busy && !loading, let selected, mode.selectedSegment != 2, window.attachedSheet == nil else { return }; let expected = campaign, lists = mode.selectedSegment == 1
        let a = NSAlert(); a.messageText = lists ? "対象リストとの関連付けを解除しますか？" : "配信手順を削除しますか？"; a.informativeText = lists ? "対象リストと営業対象の情報は残ります。" : "この手順は元に戻せません。送信履歴がある手順は削除できません。"; a.addButton(withTitle:lists ? "解除" : "削除"); a.addButton(withTitle:"キャンセル")
        a.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in if lists { _ = try service.setCampaignTargetList(campaign:expected,listID:selected["id"].string,enabled:false) } else { _ = try service.deleteCampaignStep(campaign:expected,step:selected) } } }
    }
    @objc private func history() {
        guard allowsDelivery else { message.stringValue = "復元した配信履歴の操作は確認待ちです。"; return }
        guard !busy && !loading, window.attachedSheet == nil else { return }
        do { let controller = try CRMCampaignDeliveryWindow(service:service,campaignID:campaign["id"].string); deliveryWindow = controller; window.beginSheet(controller.window) { [weak self] _ in self?.deliveryWindow = nil; self?.load() } }
        catch { message.stringValue = error.localizedDescription }
    }
    private func jobsChanged() { if busy || loading || window.attachedSheet != nil { refreshNeeded = true } else { load() } }
    private func launch(_ action: CampaignLaunchAction) {
        guard allowsDelivery else { message.stringValue = "復元した配信は確認待ちです。下書き・配信手順の編集は利用できます。"; return }
        guard !busy && !loading, window.attachedSheet == nil else { return }
        let controller = CampaignLaunchWindow(service:service,campaign:campaign,action:action,readiness:readiness); launchWindow = controller
        window.beginSheet(controller.window) { [weak self] _ in self?.launchWindow = nil; self?.load() }
    }
    @objc private func sendNow() { launch(.sendNow) }
    @objc private func schedule() { launch(.schedule) }
    @objc private func resume() { launch(.resume) }
    @objc private func pause() {
        guard allowsDelivery else { message.stringValue = "復元した配信状態の操作は確認待ちです。"; return }
        guard !busy && !loading, window.attachedSheet == nil else { return }; let expected = campaign
        let alert = NSAlert(); alert.messageText = "キャンペーンを一時停止しますか？"; alert.informativeText = "未送信のメールとフォローアップを停止します。送信サービスへ渡したメールは取り消せません。"; alert.addButton(withTitle:"一時停止"); alert.addButton(withTitle:"戻る")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.perform { [service = self.service] in _ = try service.pauseCampaign(expected) } }
    }
    @objc private func dispatchHistory() {
        guard allowsDelivery else { message.stringValue = "復元した配信履歴の操作は確認待ちです。"; return }
        guard !busy && !loading, window.attachedSheet == nil else { return }
        do { let controller = try CampaignDispatchWindow(service:service,campaignID:campaign["id"].string); dispatchWindow = controller; window.beginSheet(controller.window) { [weak self] _ in self?.dispatchWindow = nil; self?.load() } }
        catch { message.stringValue = error.localizedDescription }
    }
    func confirmDiscard() -> Bool { !busy && editor?.confirmDiscard() != false && stepEditor?.confirmDiscard() != false && deliveryWindow?.confirmDiscard() != false && launchWindow?.confirmDiscard() != false && dispatchWindow?.confirmDiscard() != false }
    @objc private func close() { guard window.attachedSheet == nil, confirmDiscard() else { return }; generation += 1; window.sheetParent?.endSheet(window) }
    @objc private func modeChanged() { offset = 0; load() }; @objc private func refresh() { load() }
    @objc private func previous() { offset = max(0,offset-100); load() }; @objc private func next() { if offset+100 < total { offset += 100; load() } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { controls(); table.enumerateAvailableRowViews { v,_ in v.subviews.forEach{$0.needsDisplay = true} } }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? { guard cells.indices.contains(row) else { return nil }; let id = NSUserInterfaceItemIdentifier("campaign-detail-row"); let c = table.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); c.identifier = id; c.configure(columns:columns,values:cells[row]); return c }
}
