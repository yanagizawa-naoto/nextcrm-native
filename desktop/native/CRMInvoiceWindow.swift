import AppKit
import UniformTypeIdentifiers

private final class InvoicePanel: NSPanel {
    deinit {
        if ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_FORM_DIAGNOSTICS"] == "1" {
            FileHandle.standardError.write(Data("InvoicePanel released\n".utf8))
        }
    }
}

final class CRMInvoiceWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    deinit {
        if ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_FORM_DIAGNOSTICS"] == "1" {
            FileHandle.standardError.write(Data("InvoiceWindow released\n".utf8))
        }
    }
    let window: NSPanel = InvoicePanel(contentRect:NSRect(x:0,y:0,width:980,height:750),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let accountID: String
    private var invoice: NativeRecord?; private var draft: InvoiceDraftStore?; private var headers: [String:SQLValue] = [:]
    private var rows: [InvoiceDraftRow] = []; private var offset = 0; private var total = 0
    private var dirty = false; private var busy = false; private var loaded = false
    private var editor: CRMEditor?; private var records: CRMInvoiceRecordsWindow?
    private var mailCompose: CRMInvoiceMailComposeWindow?; private var jobsWindow: CRMInvoiceJobsWindow?
    private let mailStore: InvoiceMailCredentialStore?
    private let allowsMail: Bool
    private let allowsFXLookup: Bool
    private let fxRequest: (URLRequest) async throws -> (Data,URLResponse)
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.invoice-editor")
    private let heading = NSTextField(labelWithString:"請求書を読み込み中…")
    private let information = NSTextField(wrappingLabelWithString:""); private let totals = NSTextField(wrappingLabelWithString:"")
    private let message = NSTextField(wrappingLabelWithString:""); private let count = NSTextField(labelWithString:"")
    private let table = NSTableView()
    private let details = NSButton(title:"取引先・日付・振込先・備考…",target:nil,action:nil)
    private let payments = NSButton(title:"入金…",target:nil,action:nil); private let history = NSButton(title:"履歴…",target:nil,action:nil)
    private let refresh = NSButton(title:"再読み込み",target:nil,action:nil)
    private let add = NSButton(title:"明細を追加",target:nil,action:nil); private let edit = NSButton(title:"明細の詳細…",target:nil,action:nil); private let remove = NSButton(title:"明細を削除",target:nil,action:nil)
    private let up = NSButton(title:"上へ",target:nil,action:nil); private let down = NSButton(title:"下へ",target:nil,action:nil)
    private let previous = NSButton(title:"前へ",target:nil,action:nil); private let next = NSButton(title:"次へ",target:nil,action:nil)
    private let save = NSButton(title:"下書きを保存",target:nil,action:nil); private let issue = NSButton(title:"保存して発行…",target:nil,action:nil); private let closeButton = NSButton(title:"閉じる",target:nil,action:nil)
    private let actions = NSPopUpButton(frame:.zero,pullsDown:true)
    private static let columns = [NativeColumn(title:"品名・内容",fraction:0.36),NativeColumn(title:"数量",fraction:0.10),NativeColumn(title:"単価",fraction:0.16),NativeColumn(title:"値引率",fraction:0.09),NativeColumn(title:"税率",fraction:0.09),NativeColumn(title:"税込合計",fraction:0.20)]
    var saved: NativeRecord?
    private var editable: Bool { invoice.map { service.invoiceCan($0,"edit") } ?? true }
    init(service: CRMService, invoice: NativeRecord?, accountID: String, mailStore: InvoiceMailCredentialStore? = nil, allowsMail: Bool = true, allowsFXLookup: Bool = true, fxRequest: @escaping (URLRequest) async throws -> (Data,URLResponse) = { try await URLSession.shared.data(for:$0) }) {
        self.service = service; self.invoice = invoice; self.accountID = accountID; self.allowsMail = allowsMail; self.allowsFXLookup=allowsFXLookup; self.fxRequest=fxRequest; self.mailStore = allowsMail ? (mailStore ?? KeychainInvoiceMailCredentials(databaseURL:service.db.url)) : nil; super.init()
        window.title = "請求書"; heading.font = .systemFont(ofSize:22,weight:.semibold)
        information.font = .systemFont(ofSize:12); information.textColor = .secondaryLabelColor
        totals.font = .monospacedDigitSystemFont(ofSize:14,weight:.medium); message.font = .systemFont(ofSize:12); message.textColor = .secondaryLabelColor
        table.dataSource = self; table.delegate = self; table.headerView = nil; table.rowHeight = 38; table.style = .inset; table.target = self; table.doubleAction = #selector(editLine); table.setAccessibilityLabel("請求明細")
        let col = NSTableColumn(identifier:.init("line")); col.width = 920; table.addTableColumn(col)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let header = LightweightTableCell(); header.horizontalInset = 16; header.configure(columns:Self.columns,values:Self.columns.map(\.title),heading:true); header.heightAnchor.constraint(equalToConstant:24).isActive = true
        for (b,a) in [(details,#selector(showDetails)),(payments,#selector(showPayments)),(history,#selector(showHistory)),(refresh,#selector(reloadRequested)),(add,#selector(addLine)),(edit,#selector(editLine)),(remove,#selector(removeLine)),(up,#selector(moveLine(_:))),(down,#selector(moveLine(_:))),(previous,#selector(page(_:))),(next,#selector(page(_:))),(save,#selector(saveDraft)),(issue,#selector(issueRequested)),(closeButton,#selector(close))] { b.target = self; b.action = a; b.bezelStyle = .rounded }
        up.tag = -1; down.tag = 1; previous.tag = -1; next.tag = 1; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command; closeButton.keyEquivalent = "\u{1b}"
        actions.target = self; actions.action = #selector(action(_:)); actions.menu?.autoenablesItems = false
        let top = NSStackView(views:[details,payments,history,refresh,NSView(),actions]); top.spacing = 10
        let lines = NSStackView(views:[add,edit,remove,up,down,NSView(),count,previous,next]); lines.spacing = 8
        let footer = NSStackView(views:[NSView(),closeButton,save,issue]); footer.spacing = 12
        let root = NSStackView(views:[heading,information,top,header,scroll,lines,totals,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
        for view in [information,top,header,scroll,lines,totals,message,footer] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }; updateControls()
    }
    func start(note: String = "") {
        guard !busy else { return }; busy = true; updateControls(); let original = invoice
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.service.db.transaction { () -> (NativeRecord?,InvoiceDraftStore?,[String:SQLValue]) in
                let record = try original.map { try self.service.invoiceAccess($0) }
                if let record {
                    let stagedProbe = ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_DATA_DIR"] != nil && ProcessInfo.processInfo.environment["NEXTCRM_NATIVE_INVOICE_READER"] == "staged"
                    let draft = self.service.invoiceCan(record,"edit") || stagedProbe ? try self.service.makeInvoiceDraft(record) : nil
                    return (record,draft,record.values.filter { CRMService.invoiceHeaderKeys.contains($0.key) })
                }
                try self.service.assertAccess("crm_Accounts",id:self.accountID,write:true)
                let settings = try self.service.invoiceSettings(); var h: [String:SQLValue] = ["accountId":.text(self.accountID),"type":.text("INVOICE"),"currency":settings?["baseCurrency"] ?? .text("JPY"),"seriesId":settings?["defaultSeriesId"] ?? .null]
                for key in ["bankName","bankAccount","iban","swift"] { h[key] = settings?[key] ?? .null }
                if let days = settings?["defaultDueDays"].string, let n = Int(days) { var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!; h["dueDate"] = .text(ISO8601DateFormatter().string(from:calendar.date(byAdding:.day,value:n,to:InvoiceCalendar.today())!)) }
                return (nil,try InvoiceDraftStore(),h)
            } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do { let value = try result.get(); self.invoice = value.0; self.draft = value.1; self.headers = value.2; self.dirty = false; self.loaded = true; self.offset = 0; self.showHeader(); self.loadRows(note:note) }
                catch { self.message.stringValue = error.localizedDescription; self.updateControls() }
            }
        }
    }
    private func showHeader() {
        heading.stringValue = (invoice.map(CRMModule.displayName) ?? "新規請求書")+"　"+CRMModule.invoiceLabel(invoice?["status"].string ?? "DRAFT"); window.title = heading.stringValue
        let name = (try? service.referenceName("crm_Accounts",id:headers["accountId"]?.string ?? "")) ?? "未設定"
        let due = headers["dueDate"]?.string ?? ""
        information.stringValue = name+"　／　"+CRMModule.invoiceLabel(invoice?["type"].string ?? headers["type"]?.string ?? "INVOICE")+"　／　"+(headers["currency"]?.string ?? "JPY")+"\n発行日："+(invoice?["issueDate"].string.isEmpty == false ? String(invoice!["issueDate"].string.prefix(10)) : "未発行")+"　支払期限："+(due.isEmpty ? "発行時に設定" : String(due.prefix(10)))
        actions.removeAllItems(); actions.addItem(withTitle:"請求書の操作")
        if let invoice {
            for (label,key,enabled) in [("メールで送信…","email",allowsMail && service.invoiceCan(invoice,"email") && !invoice["pdfStorageKey"].string.isEmpty),("送信・PDFの処理状況…","jobs",service.invoiceCan(invoice,"read")),("PDFを開く","open",!invoice["pdfStorageKey"].string.isEmpty),("PDFを別名で保存…","export",!invoice["pdfStorageKey"].string.isEmpty),("PDFを作成・再作成","pdf",service.invoiceCan(invoice,"pdf") && !invoice["number"].string.isEmpty),("複製して下書きを作成…","duplicate",service.invoiceCan(invoice,"duplicate")),("下書きを取消…","cancel",service.invoiceCan(invoice,"cancel"))] { actions.addItem(withTitle:label); actions.lastItem?.representedObject = key; actions.lastItem?.isEnabled = enabled }
        }
    }
    private func loadRows(selected: String? = nil, note: String = "") {
        guard loaded else { return }; busy = true; updateControls(); let start = offset; let canEdit = editable; let draft = draft; let record = invoice
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { () -> ([InvoiceDraftRow],Int,Int,InvoiceMath.Total?) in
                guard let draft else {
                    guard let record else { throw NativeDBError.message("請求書を開き直してください。") }
                    let page = try self.service.invoiceDisplayPage(record,offset:start)
                    return (page.rows,page.total,page.offset,nil)
                }
                let total = try draft.count(); let offset = min(start,max(0,(max(1,total)-1)/100*100))
                return (try draft.page(offset:offset),total,offset,canEdit ? try draft.totals() : nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do {
                    let (rows,total,offset,sum) = try result.get(); self.rows = rows; self.total = total; self.offset = offset; self.table.reloadData()
                    if let selected, let i = rows.firstIndex(where: { $0.id == selected }) { self.table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false) }
                    self.count.stringValue = "\(total == 0 ? 0 : offset+1)–\(offset+rows.count) ／ \(total)件"
                    let subtotal = sum?.subtotal ?? self.invoice?["subtotal"].string ?? "0"; let vat = sum?.vatTotal ?? self.invoice?["vatTotal"].string ?? "0"; let grand = sum?.grandTotal ?? self.invoice?["grandTotal"].string ?? "0"
                    let discount = sum?.discountTotal ?? self.invoice?["discountTotal"].string ?? "0"
                    self.totals.stringValue = "小計：\(subtotal)　税額：\(vat)　合計：\(grand) \(self.headers["currency"]?.string ?? "")\n値引合計：\(discount)　入金済み：\(self.invoice?["paidTotal"].string ?? "0")　未入金：\(sum?.grandTotal ?? self.invoice?["balanceDue"].string ?? "0")"
                    self.message.stringValue = note.isEmpty ? (self.dirty ? "未保存の変更があります。" : self.editable ? "発行時に番号を付け、請求先と税率を確定します。" : self.invoice?["number"] == .null ? "取り消された請求書です。明細を変更・発行できません。" : "発行後の明細は変更できません。入金履歴とPDFを確認できます。") : note
                } catch { self.message.stringValue = error.localizedDescription }; self.updateControls()
            }
        }
    }
    private func updateControls() {
        let ready = loaded && !busy; let selected = rows.indices.contains(table.selectedRow)
        for b in [details,refresh,closeButton] { b.isEnabled = !busy }; details.isEnabled = ready
        for b in [add,save,issue] { b.isEnabled = ready && editable }; remove.isEnabled = ready && editable && selected; edit.isEnabled = ready && selected
        up.isEnabled = ready && editable && selected && offset+table.selectedRow > 0; down.isEnabled = ready && editable && selected && offset+table.selectedRow+1 < total
        previous.isEnabled = ready && offset > 0; next.isEnabled = ready && offset+100 < total; table.isEnabled = ready
        payments.isEnabled = ready && invoice != nil; history.isEnabled = payments.isEnabled; actions.isEnabled = payments.isEnabled
        save.isHidden = loaded && !editable; issue.isHidden = save.isHidden; issue.isEnabled = ready && editable && service.identity.role != "partner"
    }
    func confirmDiscard() -> Bool {
        guard !busy, editor?.confirmDiscard() != false, records?.confirmDiscard() != false, mailCompose?.confirmDiscard() != false, jobsWindow?.confirmDiscard() != false else { return false }; guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "請求書の変更を保存せずに閉じますか？"; alert.informativeText = "編集中の明細・日付・備考は保存されません。"; alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"変更を破棄"); return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func close() { if window.attachedSheet == nil && confirmDiscard() { window.sheetParent?.endSheet(window) } }
    @objc private func reloadRequested() { if window.attachedSheet == nil && confirmDiscard() { start() } }
    @objc private func showDetails() {
        guard !busy, loaded, window.attachedSheet == nil else { return }
        do {
            var values = invoice?.values ?? [:]; values.merge(headers) { _,n in n }
            let fields = CRMModule.invoices.fields.filter { invoice == nil || !editable || CRMService.invoiceHeaderKeys.contains($0.key) }
            let module = CRMModule(model:"Invoices",title:"請求書の詳細",singular:"請求書の詳細",entity:"invoice",nameFields:["number"],columns:[],fields:fields)
            let controller = try CRMEditor(module:module,record:.init(model:"Invoices",values:values,revision:invoice?.revision ?? 0),linkedTo:nil,service:service,referenceFilters:["accountId":service.scope("crm_Accounts",write:true),"seriesId":.equal("active",.integer(1))],readOnly:!editable,onSave:{ [weak self] input in
                guard let self else { return }; if input != self.headers { self.headers = input; self.dirty = true; self.showHeader(); self.message.stringValue = "詳細を変更しました。請求書を保存すると確定します。" }
            }); showEditor(controller)
        } catch { message.stringValue = error.localizedDescription }
    }
    private func showEditor(_ controller: CRMEditor) { editor = controller; window.beginSheet(controller.window) { [weak self] _ in self?.editor = nil } }
    @objc private func addLine() { if editable { openLine(nil) } }
    @objc private func editLine() { if rows.indices.contains(table.selectedRow) { openLine(rows[table.selectedRow]) } }
    private func openLine(_ row: InvoiceDraftRow?) {
        guard !busy, loaded, window.attachedSheet == nil else { return }
        do {
            var values = row.map { $0.quote.values($0.input,snapshot:!editable) } ?? ["quantity":.text("1"),"unitPrice":.text("0"),"discountPercent":.text("0"),"taxRateId":.null]
            if row == nil { values["taxRateId"] = try service.invoiceSettings()?["defaultTaxRateId"] ?? .null }
            var fields = CRMModule.invoiceLine.fields
            if !editable { fields += [EditorField("taxRateSnapshot","確定税率（%）",.number),EditorField("lineSubtotal","小計",.number),EditorField("lineVat","税額",.number),EditorField("lineTotal","合計",.number)] }
            let module = CRMModule(model:"Invoice_LineItems",title:"請求明細",singular:"請求明細",entity:"invoiceLine",nameFields:["description"],columns:[],fields:fields)
            let controller = try CRMEditor(module:module,record:.init(model:module.model,values:values,revision:0),linkedTo:nil,service:service,referenceFilters:["productId":.equal("status",.text("ACTIVE")),"taxRateId":.equal("active",.integer(1))],readOnly:!editable,onSave:{ [weak self] input in
                guard let self, let draft = self.draft else { return }; let record = NativeRecord(model:module.model,values:input,revision:0); let line = InvoiceLineInput.from(record)
                let quote = try self.service.invoiceQuote(line); let id = try draft.save(input:line,quote:quote,id:row?.id); self.dirty = true
                if row == nil { self.offset = max(0,((try draft.count())-1)/100*100) }; self.loadRows(selected:id)
            }); showEditor(controller)
        } catch { message.stringValue = error.localizedDescription }
    }
    @objc private func removeLine() { guard editable, !busy, let draft, rows.indices.contains(table.selectedRow) else { return }; do { try draft.remove(rows[table.selectedRow].id); dirty = true; loadRows() } catch { message.stringValue = error.localizedDescription } }
    @objc private func moveLine(_ sender: NSButton) { guard editable, !busy, let draft, rows.indices.contains(table.selectedRow) else { return }; let row = rows[table.selectedRow]; do { try draft.move(row.id,direction:sender.tag); dirty = true; offset = max(0,(offset+table.selectedRow+sender.tag)/100*100); loadRows(selected:row.id) } catch { message.stringValue = error.localizedDescription } }
    @objc private func page(_ sender: NSButton) { if !busy { offset = max(0,offset+sender.tag*100); loadRows() } }
    @objc private func saveDraft() { persistDraft(issue:false) }
    @objc private func issueRequested() {
        guard !busy, editable, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "請求書を保存して発行しますか？"; alert.informativeText = "番号・請求先・税率を確定し、発行後は明細を編集できなくなります。外貨の場合は為替レートを取得します。"; alert.addButton(withTitle:"保存して発行"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in if response == .alertFirstButtonReturn { self?.persistDraft(issue:true) } }
    }
    private func persistDraft(issue: Bool) {
        guard !busy, editable, loaded, let draft else { return }; busy = true; updateControls(); message.stringValue = "保存中…"; let original = invoice; let values = headers
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { try self.service.saveInvoice(original:original,header:values,lines:{ try draft.page(offset:$0).map(\.input) }) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                do { let saved = try result.get(); self.invoice = saved; self.saved = saved; self.dirty = false; if issue { self.issueSaved(saved) } else { self.start(note:"下書きを保存しました。") } }
                catch { self.message.stringValue = error.localizedDescription; self.updateControls() }
            }
        }
    }
    private func issueSaved(_ record: NativeRecord) {
        busy = true; updateControls(); message.stringValue = "発行の準備中…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let context = try self.service.invoiceFXContext(record)
                let fx = try await InvoiceFXClient.quote(currency:context.invoice["currency"].string,settings:context.settings,request:{ [self] request in
                    guard allowsFXLookup else{throw NativeDBError.message("復元した外貨レート接続は確認待ちです。同じ通貨での発行と下書きの保存は利用できます。")};return try await fxRequest(request)
                })
                self.queue.async { [weak self] in
                    guard let self else { return }; let result = Result { () -> (NativeRecord,String) in
                        var dates = record.values.filter { ["issueDate","taxableSupplyDate","dueDate"].contains($0.key) && $0.value != .null }
                        if dates["issueDate"] == nil { dates["issueDate"] = .text(ISO8601DateFormatter().string(from:InvoiceCalendar.today())) }; let issued = try self.service.issueInvoice(record,dates:dates,fx:fx,now:InvoiceCalendar.today())
                        do { return (try self.service.generateInvoicePDF(issued),"請求書を発行し、PDFを作成しました。") }
                        catch { return (issued,"請求書は発行済みです。PDFの作成は完了していません："+error.localizedDescription+" 「PDFを作成・再作成」から再実行できます。") }
                    }; self.finish(result)
                }
            } catch { self.finish(.success((record,"下書きは保存しました。発行できませんでした："+error.localizedDescription))) }
        }
    }
    private func finish(_ result: Result<(NativeRecord,String),Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.busy = false
            do { let (record,note) = try result.get(); self.invoice = record; self.saved = record; self.dirty = false; self.start(note:note) }
            catch { self.message.stringValue = error.localizedDescription; self.updateControls() }
        }
    }
    private func perform(note: String, _ work: @escaping () throws -> NativeRecord) { busy = true; updateControls(); message.stringValue = "処理中…"; queue.async { [weak self] in self?.finish(Result { (try work(),note) }) } }
    @objc private func action(_ sender: NSPopUpButton) {
        guard !busy, let invoice, window.attachedSheet == nil, let key = sender.selectedItem?.representedObject as? String else { return }
        do {
            if key == "email" {
                guard allowsMail, let mailStore else { message.stringValue = "復元したメール送信は確認待ちです。請求書の編集・PDF操作は利用できます。"; return }
                let controller = try CRMInvoiceMailComposeWindow(service:service,invoice:invoice,store:mailStore); mailCompose = controller
                window.beginSheet(controller.window) { [weak self,weak controller] _ in
                    guard let self else { return }; let queued = controller?.queuedID != nil; self.mailCompose = nil
                    self.start(note:queued ? "メールの送信を予約しました。「送信・PDFの処理状況」で結果を確認できます。" : "")
                }; return
            }
            if key == "jobs" {
                let controller = try CRMInvoiceJobsWindow(service:service,invoice:invoice); jobsWindow = controller
                window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.jobsWindow = nil; self.start() }; return
            }
            if key == "open" { guard NSWorkspace.shared.open(try service.invoicePDFURL(invoice)) else { throw NativeDBError.message("PDFを開けませんでした。") }; return }
            if key == "export" { try exportPDF(invoice); return }
            if key == "pdf" { perform(note:"PDFを作成しました。") { try self.service.generateInvoicePDF(invoice) }; return }
            guard confirmDiscard() else { return }
            let alert = NSAlert(); alert.messageText = key == "duplicate" ? "複製して新しい下書きを作成しますか？" : "この下書きを取り消しますか？"; alert.informativeText = key == "duplicate" ? "保存済みの内容から複製します。番号・入金・PDFは引き継ぎません。" : "取消後は編集・発行できません。"; alert.addButton(withTitle:key == "duplicate" ? "複製" : "下書きを取消"); alert.addButton(withTitle:"キャンセル")
            alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; self.perform(note:key == "duplicate" ? "複製した下書きを開いています。" : "下書きを取り消しました。") { key == "duplicate" ? try self.service.duplicateInvoice(invoice) : try self.service.cancelInvoice(invoice) } }
        } catch { message.stringValue = error.localizedDescription }
    }
    private func exportPDF(_ record: NativeRecord) throws {
        let source = try service.invoicePDFURL(record); let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = record["number"].string.replacingOccurrences(of:"/",with:"-")+".pdf"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            if destination.standardizedFileURL == source.standardizedFileURL { self.message.stringValue = "同じPDFが既に保存されています。"; return }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nextcrm-export-"+UUID().uuidString)
            do {
                defer { try? FileManager.default.removeItem(at:temporary) }; try FileManager.default.copyItem(at:source,to:temporary)
                if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:temporary) } else { try FileManager.default.moveItem(at:temporary,to:destination) }; self.message.stringValue = "PDFを保存しました："+destination.lastPathComponent
            } catch { self.message.stringValue = error.localizedDescription }
        }
    }
    @objc private func showPayments() {
        guard !busy, let invoice, window.attachedSheet == nil else { return }
        let canAdd = service.invoiceCan(invoice,"payment")
        let controller = CRMInvoiceRecordsWindow(service:service,module:.invoicePayments,searchable:false,initial:{ [weak self] in
            guard let self, let current = self.invoice else { throw NativeDBError.message("請求書を開き直してください。") }
            return NativeRecord(model:"Invoice_Payments",values:["amount":current["balanceDue"],"paidAt":.text(ISO8601DateFormatter().string(from:InvoiceCalendar.today())),"method":.text("Bank Transfer")],revision:0)
        },editExisting:false,fetch:{ [weak self] _,offset in guard let self, let current = self.invoice else { return ([],0) }; return try self.service.invoiceRows(current,model:"Invoice_Payments",offset:offset) },save:canAdd ? { [weak self] _,input in
            guard let self, let current = self.invoice else { return }; let parser = ISO8601DateFormatter(); guard let date = parser.date(from:input["paidAt"]?.string ?? "") else { throw NativeDBError.message("入金日を確認してください。") }
            let updated = try self.service.addInvoicePayment(current,amount:input["amount"]?.string ?? "",paidAt:date,method:input["method"]?.string ?? "",reference:input["reference"]?.string,note:input["note"]?.string); self.invoice = updated; self.saved = updated
        } : nil,remove:service.identity.role == "admin" ? { [weak self] payment in guard let self, let current = self.invoice else { return }; let updated = try self.service.deleteInvoicePayment(payment,invoice:current); self.invoice = updated; self.saved = updated } : nil)
        controller.canCreate = { [weak self] in guard let self, let current = self.invoice else { return false }; return self.service.invoiceCan(current,"payment") }
        showRecords(controller)
    }
    @objc private func showHistory() {
        guard !busy, let invoice, window.attachedSheet == nil else { return }
        showRecords(CRMInvoiceRecordsWindow(service:service,module:.invoiceActivity,searchable:false,fetch:{ [service] _,offset in try service.invoiceRows(invoice,model:"Invoice_Activity",offset:offset) }))
    }
    private func showRecords(_ controller: CRMInvoiceRecordsWindow) {
        records = controller; window.beginSheet(controller.window) { [weak self] _ in guard let self else { return }; self.records = nil; if !self.dirty { self.start() } }; controller.start()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }; let row = rows[row]; let id = NSUserInterfaceItemIdentifier("invoice-line")
        let view = tableView.makeView(withIdentifier:id,owner:self) as? LightweightTableCell ?? LightweightTableCell(); view.identifier = id
        view.configure(columns:Self.columns,values:[row.input.description,row.input.quantity,row.input.unitPrice,row.input.discountPercent+"%",row.quote.rate+"%",row.quote.amounts.lineTotal]); return view
    }
}
