import AppKit

/// A working copy lives on disk until Save/Submit commits the complete order atomically.
final class CRMOrderWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:960,height:740),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let accountID: String
    private var order: NativeRecord?; private var draft: OrderDraftStore?
    private var context = OrderPriceContext(listID:nil,currency:"JPY")
    private var headers: [String:SQLValue] = [:]
    private var rows: [OrderDraftRow] = []; private var offset = 0; private var total = 0
    private var dirty = false; private var busy = false; private var loaded = false
    var onShowNotifications: ((NativeRecord,NSWindow) throws -> Void)?
    var pluginMenu: ((NativeRecord,NSWindow) -> NSMenu?)?
    var linkForOrder: ((NativeRecord) throws -> String)?
    private var headerEditor: CRMEditor?; private var lineEditor: CRMOrderLineEditor?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.order-editor")
    private let heading = NSTextField(labelWithString:"受注を読み込み中…")
    private let information = NSTextField(wrappingLabelWithString:"")
    private let address = NSTextField(wrappingLabelWithString:"")
    private let totalsLabel = NSTextField(wrappingLabelWithString:"")
    private let message = NSTextField(wrappingLabelWithString:"")
    private let table = NSTableView(); private let count = NSTextField(labelWithString:"")
    private let add = NSButton(title:"明細を追加",target:nil,action:nil)
    private let edit = NSButton(title:"明細を編集",target:nil,action:nil)
    private let remove = NSButton(title:"明細を削除",target:nil,action:nil)
    private let up = NSButton(title:"上へ",target:nil,action:nil); private let down = NSButton(title:"下へ",target:nil,action:nil)
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private let details = NSButton(title:"送付先・連絡先・メモ…",target:nil,action:nil)
    private let notifications = NSButton(title:"通知状況…",target:nil,action:nil)
    private let pluginInfo = NSPopUpButton(frame: .zero, pullsDown: true)
    private let history = NSButton(title:"履歴…",target:nil,action:nil)
    private let refresh = NSButton(title:"再読み込み",target:nil,action:nil)
    private let saveButton = NSButton(title:"下書きを保存",target:nil,action:nil)
    private let submitButton = NSButton(title:"保存して提出",target:nil,action:nil)
    private let closeButton = NSButton(title:"閉じる",target:nil,action:nil)
    private let actions = NSPopUpButton(frame:.zero,pullsDown:true)
    private static let columns = [NativeColumn(title:"商品・サービス",fraction:0.31),NativeColumn(title:"数量",fraction:0.09),NativeColumn(title:"価格表単価",fraction:0.15),NativeColumn(title:"適用単価",fraction:0.17),NativeColumn(title:"税率",fraction:0.08),NativeColumn(title:"税込合計",fraction:0.20)]
    var saved: NativeRecord?
    private var editable: Bool { order.map { service.orderCan($0,"edit") } ?? (service.identity.role != "partner") }
    init(service: CRMService, order: NativeRecord?, accountID: String) {
        self.service = service; self.order = order; self.accountID = accountID
        super.init(); window.title = "受注"; heading.font = .systemFont(ofSize:22,weight:.semibold)
        information.textColor = .secondaryLabelColor; information.font = .systemFont(ofSize:12)
        address.font = .systemFont(ofSize:12); address.maximumNumberOfLines = 3
        totalsLabel.font = .monospacedDigitSystemFont(ofSize:14,weight:.medium)
        message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.style = .inset
        table.target = self; table.doubleAction = #selector(editLine); table.setAccessibilityLabel("受注明細")
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("line")); column.width = 900; table.addTableColumn(column)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let header = LightweightTableCell(); header.horizontalInset = 16; header.configure(columns:Self.columns,values:Self.columns.map(\.title),heading:true)
        header.heightAnchor.constraint(equalToConstant:24).isActive = true
        for (button,selector) in [(add,#selector(addLine)),(edit,#selector(editLine)),(remove,#selector(removeLine)),(up,#selector(moveLine(_:))),(down,#selector(moveLine(_:))),(previous,#selector(page(_:))),(next,#selector(page(_:))),(details,#selector(showDetails)),(history,#selector(showHistory)),(notifications,#selector(showNotifications)),(refresh,#selector(reloadRequested)),(saveButton,#selector(saveDraft)),(submitButton,#selector(submit)),(closeButton,#selector(close))] {
            button.target = self; button.action = selector; button.bezelStyle = .rounded
        }
        up.tag = -1; down.tag = 1; previous.tag = -1; next.tag = 1
        saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = .command; closeButton.keyEquivalent = "\u{1b}"
        actions.target = self; actions.action = #selector(changeState(_:)); actions.menu?.autoenablesItems = false
        pluginInfo.setAccessibilityLabel("受注の連携情報"); pluginInfo.isHidden = true
        let top = NSStackView(views:[details,history,notifications,pluginInfo,refresh,NSView(),actions]); top.spacing = 10
        let lineActions = NSStackView(views:[add,edit,remove,up,down,NSView(),count,previous,next]); lineActions.spacing = 8
        let footer = NSStackView(views:[NSView(),closeButton,saveButton,submitButton]); footer.spacing = 12
        let views: [NSView] = [heading,information,address,top,header,scroll,lineActions,totalsLabel,message,footer]
        let root = NSStackView(views:views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:260)])
        for view in views { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        updateControls()
    }
    private struct Snapshot {
        let order: NativeRecord?; let draft: OrderDraftStore; let context: OrderPriceContext
        let headers: [String:SQLValue]; let information: String
    }
    func start() {
        guard !busy else { return }; busy = true; loaded = false; updateControls(); message.stringValue = "読み込み中…"
        let original = order
        queue.async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.service.db.transaction { () -> Snapshot in
                let current = try original.map { try self.service.orderAccess($0) }
                if current == nil { try self.service.assertAccess("crm_Accounts",id:self.accountID,write:true) }
                guard let account = try self.service.db.get("crm_Accounts",key:["id":.text(self.accountID)]) else { throw NativeDBError.message("取引先が見つかりません。") }
                let context = try current.map(self.service.orderContext) ?? self.service.orderContext(accountID:self.accountID)
                let draft = try current.map { try self.service.makeOrderDraft($0) } ?? OrderDraftStore()
                let headers = current.map { row in Dictionary(uniqueKeysWithValues:CRMService.orderHeaderKeys.map { ($0,row[$0]) }) } ?? self.service.orderShipping(account)
                let list = try context.listID.map { try self.service.referenceName("crm_PriceLists",id:$0) } ?? "商品の販売単価"
                let owner = try self.service.referenceName("Users",id:(current?["ownerId"] ?? account["assigned_to"]).string)
                let date = current.map { String($0["orderDate"].string.prefix(10)) } ?? "保存時に確定"
                return Snapshot(order:current,draft:draft,context:context,headers:headers,information:"取引先：\(CRMModule.displayName(account))　担当者：\(owner)\n価格表：\(list)　通貨：\(context.currency)　受注日：\(date)")
            } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do {
                    let value = try outcome.get(); self.order = value.order; self.draft = value.draft; self.context = value.context; self.headers = value.headers
                    self.information.stringValue = value.information; self.dirty = false; self.loaded = true; self.offset = 0
                    self.heading.stringValue = (value.order?["number"].string ?? "新規受注")+"　"+(OrderWorkflow.labels[value.order?["status"].string ?? "DRAFT"] ?? "")
                    self.window.title = self.heading.stringValue; self.showHeader(); self.configureActions(); self.loadRows()
                } catch { self.message.stringValue = error.localizedDescription; self.updateControls() }
            }
        }
    }
    private func showHeader() {
        let shipping = ["shipping_postal_code","shipping_state","shipping_city","shipping_street","shipping_country"].map { headers[$0]?.string ?? "" }.filter { !$0.isEmpty }.joined(separator:" ")
        let contact = (try? service.referenceName("crm_Contacts",id:headers["contactId"]?.string ?? "")) ?? "未設定"
        let note = String((headers["note"]?.string ?? "").prefix(160)).replacingOccurrences(of:"\n",with:" ")
        let date = headers["requestedDeliveryDate"]?.string ?? ""
        address.stringValue = "送付先：\(shipping.isEmpty ? "未設定" : shipping)\n連絡先：\(contact)　納品希望日：\(date.isEmpty ? "未設定" : String(date.prefix(10)))"+(note.isEmpty ? "" : "\nメモ："+note)
    }
    private func loadRows(selected: String? = nil) {
        guard let draft else { return }; busy = true; updateControls(); let position = offset
        queue.async { [weak self] in
            let result = Result { () -> ([OrderDraftRow],OrderTotals,Int) in
                let total = try draft.count(); let offset = min(position,max(0,(max(1,total)-1)/100*100))
                return (try draft.page(offset:offset),try draft.totals(),offset)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do {
                    let (rows,totals,offset) = try result.get(); self.rows = rows; self.total = totals.count; self.offset = offset; self.table.reloadData()
                    if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { self.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
                    let amounts = try totals.values()
                    self.count.stringValue = "\(totals.count == 0 ? 0 : offset+1)–\(offset+rows.count) ／ \(totals.count)件"
                    self.totalsLabel.stringValue = "小計：\(amounts["subtotal"]!.string)　税額：\(amounts["vatTotal"]!.string)　合計：\(amounts["grandTotal"]!.string) \(self.context.currency)\n価格表からの値引額：\(totals.discount) \(self.context.currency)"
                    self.message.stringValue = self.editable ? (self.dirty ? "未保存の変更があります。" : "")+"保存・提出時に最新の価格で再計算します。"+(totals.belowList && self.service.identity.role == "user" ? " 価格表を下回るため承認が必要です。" : "") : self.readOnlyMessage()
                    if self.editable, let note = self.order?["approvalNote"].string, !note.isEmpty { self.message.stringValue += "\n承認・却下のメモ："+String(note.prefix(200))+(note.count > 200 ? "（全文は履歴で確認）" : "") }
                } catch { self.message.stringValue = error.localizedDescription }
                self.updateControls()
            }
        }
    }
    private func readOnlyMessage() -> String {
        guard let order else { return "" }
        let note = order["approvalNote"].string
        return (order["source"] == .text("EXTERNAL") ? "外部で管理されている受注です。" : "この受注は現在、明細を編集できません。")+(note.isEmpty ? "" : " 承認・却下のメモ："+String(note.prefix(300)))
    }
    private func updateControls() {
        let available = loaded && !busy; let canEdit = available && editable; let selected = rows.indices.contains(table.selectedRow)
        for b in [add,saveButton,submitButton] { b.isEnabled = canEdit }
        for b in [edit,remove] { b.isEnabled = canEdit && selected }
        up.isEnabled = canEdit && selected && offset+table.selectedRow > 0; down.isEnabled = canEdit && selected && offset+table.selectedRow+1 < total
        previous.isEnabled = available && offset > 0; next.isEnabled = available && offset+100 < total
        notifications.isEnabled = available && order != nil && onShowNotifications != nil; details.isEnabled = available; history.isEnabled = available && order != nil; actions.isEnabled = available && actions.numberOfItems > 1
        let menu = order.flatMap { pluginMenu?($0, window) }; pluginInfo.menu = menu; pluginInfo.isHidden = menu == nil; pluginInfo.isEnabled = available && menu != nil
        refresh.isEnabled = !busy; closeButton.isEnabled = !busy; table.isEnabled = available
        saveButton.isHidden = loaded && !editable; submitButton.isHidden = loaded && !editable
    }
    private func configureActions() {
        actions.removeAllItems(); actions.addItem(withTitle:"受注の操作")
        guard let order else { return }
        for action in ["approve","reject","withdraw","reopen","cancel","retry"] where service.orderCan(order,action) {
            actions.addItem(withTitle:OrderWorkflow.actionLabels[action]!); actions.lastItem?.representedObject = action
        }
        if service.orderCan(order,"advance") { for status in OrderWorkflow.next(order["status"].string) { actions.addItem(withTitle:OrderWorkflow.labels[status]!+"に進める"); actions.lastItem?.representedObject = "advance:"+status } }
        if linkForOrder != nil {
            if actions.numberOfItems > 1 { actions.menu?.addItem(.separator()) }
            actions.addItem(withTitle:"この受注のリンクをコピー"); actions.lastItem?.representedObject = "copyLink"
        }
    }
    func confirmDiscard() -> Bool {
        guard !busy else { return false }
        if headerEditor?.confirmDiscard() == false || lineEditor?.confirmDiscard() == false { return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "受注の変更を保存せずに閉じますか？"; alert.informativeText = "編集中の明細・送付先・メモは保存されません。"
        alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"変更を破棄"); return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func close() { if window.attachedSheet == nil && confirmDiscard() { window.sheetParent?.endSheet(window) } }
    @objc private func reloadRequested() { if window.attachedSheet == nil && confirmDiscard() { start() } }
    @objc private func showDetails() {
        guard !busy, loaded, window.attachedSheet == nil else { return }
        do {
            var values = order?.values ?? [:]; values.merge(headers) { _,n in n }
            let record = NativeRecord(model:"crm_Orders",values:values,revision:order?.revision ?? 0)
            let fields = CRMModule.orders.fields.filter { editable ? CRMService.orderHeaderKeys.contains($0.key) : true }.map { field in field.key == "note" || field.key == "approvalNote" ? EditorField(field.key,field.label,.multiline) : field }
            let module = CRMModule(model:"crm_Orders",title:"受注の詳細",singular:"受注の詳細",entity:"order",nameFields:["number"],columns:[],fields:fields)
            let controller = try CRMEditor(module:module,record:record,linkedTo:nil,service:service,referenceFilters:["contactId":.equal("accountsIDs",.text(accountID))],readOnly:!editable,onSave:{ [weak self] input in
                guard let self else { return }; let normalized = try self.service.orderHeaders(input,accountID:self.accountID)
                if normalized != self.headers { self.headers = normalized; self.dirty = true; self.showHeader(); self.message.stringValue = "送付先・連絡先・メモを変更しました。受注を保存すると確定します。" }
            })
            headerEditor = controller; window.beginSheet(controller.window) { [weak self] _ in self?.headerEditor = nil }
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func addLine() { openLine(nil) }
    @objc private func editLine() { if rows.indices.contains(table.selectedRow) { openLine(rows[table.selectedRow]) } }
    private func openLine(_ row: OrderDraftRow?) {
        guard editable, loaded, !busy, window.attachedSheet == nil, let draft else { return }
        let controller = CRMOrderLineEditor(service:service,context:context,initial:row) { [weak self] input,quote in
            guard let self else { return }; let id = try draft.save(input:input,quote:quote,id:row?.id); self.dirty = true
            if row == nil { self.offset = max(0,((try draft.count())-1)/100*100) }; self.loadRows(selected:id)
        }
        lineEditor = controller; window.beginSheet(controller.window) { [weak self] _ in self?.lineEditor = nil }
    }
    @objc private func removeLine() {
        guard editable, !busy, let draft, rows.indices.contains(table.selectedRow) else { return }
        do { try draft.remove(rows[table.selectedRow].id); dirty = true; loadRows() } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func moveLine(_ sender: NSButton) {
        guard editable, !busy, let draft, rows.indices.contains(table.selectedRow) else { return }
        let row = rows[table.selectedRow]; let destination = offset+table.selectedRow+sender.tag
        do { try draft.move(row.id,direction:sender.tag); dirty = true; offset = max(0,destination/100*100); loadRows(selected:row.id) } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func page(_ sender: NSButton) { guard !busy else { return }; offset = max(0,offset+sender.tag*100); loadRows() }
    @objc private func saveDraft() { save(submit:false) }
    @objc private func submit() {
        guard editable, !busy, loaded, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "受注を保存して提出しますか？"; alert.informativeText = "最新の価格で再計算し、一般利用者の値引受注は承認待ちになります。"
        alert.addButton(withTitle:"保存して提出"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in if response == .alertFirstButtonReturn { self?.save(submit:true) } }
    }
    private func save(submit: Bool) {
        guard editable, !busy, loaded, let draft else { return }
        let original = order; let values = headers
        perform { try self.service.saveOrder(original:original,accountID:self.accountID,header:values,lines:{ try draft.page(offset:$0).map(\.input) },submit:submit) }
    }
    private func perform(_ work: @escaping () throws -> NativeRecord) {
        busy = true; updateControls(); message.stringValue = "保存中…"
        queue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do { let order = try result.get(); self.order = order; self.saved = order; self.dirty = false; self.start() }
                catch { self.message.stringValue = error.localizedDescription; self.updateControls() }
            }
        }
    }
    @objc private func changeState(_ sender: NSPopUpButton) {
        guard !busy, let order, window.attachedSheet == nil, let key = sender.selectedItem?.representedObject as? String else { return }
        if key == "copyLink" {
            do { if let link = try linkForOrder?(order) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link,forType:.string); message.stringValue = "受注のリンクをコピーしました。" } }
            catch { message.stringValue = error.localizedDescription }
            return
        }
        let parts = key.split(separator:":").map(String.init); let action = parts[0]; let to = parts.count == 2 ? parts[1] : nil
        let alert = NSAlert(); alert.messageText = sender.selectedItem!.title+"？"
        alert.informativeText = action == "reject" ? "却下理由を入力してください。受注は下書きに戻ります。" : action == "approve" ? "承認メモは任意です。" : action == "cancel" ? "受注は取消済みになり、元の状態には戻せません。" : action == "retry" ? "状態を手配待ちに戻します。外部への連携処理は現在準備中です。" : "受注の状態を変更します。"
        let note = NSTextField(frame:NSRect(x:0,y:0,width:460,height:26)); note.setAccessibilityLabel("承認・却下のメモ")
        if ["approve","reject"].contains(action) { alert.accessoryView = note }
        alert.addButton(withTitle:"実行"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if action == "reject" && note.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { self.message.stringValue = "却下理由を入力してください。"; return }
            let text = note.stringValue; self.perform { try self.service.changeOrder(order,action:action,to:to,note:text) }
        }
    }
    @objc private func showNotifications() {
        guard let order, !busy, window.attachedSheet == nil else { return }
        do { try onShowNotifications?(order,window) } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func showHistory() {
        guard let order, !busy, window.attachedSheet == nil else { return }
        do {
            let text = NSTextView(frame:NSRect(x:0,y:0,width:700,height:360)); text.isEditable = false; text.isRichText = false; text.font = .systemFont(ofSize:12); text.string = try service.historyText(order); text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:700,height:360)); scroll.documentView = text; scroll.hasVerticalScroller = true
            let alert = NSAlert(); alert.messageText = "受注の変更履歴"; alert.accessoryView = scroll; alert.addButton(withTitle:"閉じる"); alert.beginSheetModal(for:window)
        } catch { message.stringValue = error.localizedDescription }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let q = rows[row].quote; let id = NSUserInterfaceItemIdentifier("order-line")
        let view = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); view.identifier = id
        view.configure(columns:Self.columns,values:[q.productName,q.quantity,q.listPrice,q.unitPrice+(q.unitPriceOverridden ? "（指定）" : ""),q.vatRate+"%",q.lineTotal]); return view
    }
}
