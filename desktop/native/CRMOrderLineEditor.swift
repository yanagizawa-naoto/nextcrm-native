import AppKit

final class CRMOrderLineEditor: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:740,height:440),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService; private let context: OrderPriceContext
    private let completion: (OrderLineInput,OrderLineQuote) throws -> Void
    private let product: CRMReferenceControl
    private let quantity = NSTextField(string:"1"); private let price = NSTextField(string:"")
    private let result = NSTextField(wrappingLabelWithString:"商品と数量を指定して価格を確認してください。")
    private let check = NSButton(title:"価格を確認",target:nil,action:nil)
    private let saveButton = NSButton(title:"明細に反映",target:nil,action:nil); private let cancelButton = NSButton(title:"キャンセル",target:nil,action:nil)
    private var picker: CRMReferencePicker?; private var busy = false
    private var initialValues: [String] = []
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.order-quote")
    init(service: CRMService, context: OrderPriceContext, initial: OrderDraftRow?, completion: @escaping (OrderLineInput,OrderLineQuote) throws -> Void) {
        self.service = service; self.context = context; self.completion = completion
        product = CRMReferenceControl(model:"crm_Products",selected:initial.map { .text($0.input.productID) } ?? .null,service:service)
        super.init(); window.title = initial == nil ? "受注明細を追加" : "受注明細を編集"
        quantity.stringValue = initial?.input.quantity ?? "1"; price.stringValue = initial?.input.unitPrice ?? ""
        product.choose = { [weak self] in
            guard let self, !self.busy, self.picker == nil else { return }
            let picker = CRMReferencePicker(model:"crm_Products",service:service,matching:.equal("status",.text("ACTIVE"))) { [weak self] record in
                guard let self else { return }; self.picker = nil; if let record { self.product.setRecord(record); self.calculate(save:false) }
            }; self.picker = picker; self.window.beginSheet(picker.window); picker.start()
        }
        let heading = NSTextField(labelWithString:window.title); heading.font = .systemFont(ofSize:21,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"単価を空欄にすると価格表に従います。保存・提出時に最新の価格で再計算します。数量は小数点以下4桁まで入力できます。")
        product.setAccessibilityLabel("受注の商品"); product.heightAnchor.constraint(equalToConstant:32).isActive = true
        quantity.setAccessibilityLabel("受注の数量"); price.setAccessibilityLabel("受注の指定単価"); price.placeholderString = "価格表に従う"
        var views: [NSView] = [heading,help]
        for (label,view) in [("商品",product as NSView),("数量",quantity as NSView),("指定単価（\(context.currency)）",price as NSView)] {
            let title = NSTextField(labelWithString:label); title.widthAnchor.constraint(equalToConstant:155).isActive = true
            let row = NSStackView(views:[title,view]); row.spacing = 12; view.widthAnchor.constraint(equalToConstant:500).isActive = true; views.append(row)
        }
        check.target = self; check.action = #selector(preview)
        let reset = NSButton(title:"価格表の単価に戻す",target:self,action:#selector(followList)); reset.bezelStyle = .rounded
        views.append(NSStackView(views:[check,reset])); views.append(result)
        result.setAccessibilityLabel("受注明細の計算結果"); result.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive = true
        saveButton.target = self; saveButton.action = #selector(save); saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = .command
        cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.keyEquivalent = "\u{1b}"
        for button in [check,saveButton,cancelButton] { button.bezelStyle = .rounded }
        let buttons = NSStackView(views:[NSView(),cancelButton,saveButton]); buttons.spacing = 12; views.append(buttons)
        let root = NSStackView(views:views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in [help,result,buttons] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        initialValues = [product.selected.string,quantity.stringValue,price.stringValue]
        if let initial { show(initial.quote) }
    }
    private func show(_ q: OrderLineQuote) {
        price.placeholderString = q.listPrice+" "+context.currency
        result.stringValue = "価格表の単価：\(q.listPrice) \(context.currency)　適用単価：\(q.unitPrice) \(context.currency)\n税率：\(q.vatRate)%　小計：\(q.lineSubtotal)　税額：\(q.lineVat)\n合計：\(q.lineTotal) \(context.currency)"+(q.belowList ? "\n価格表を下回っています。一般利用者の提出には承認が必要です。" : "")
    }
    private func calculate(save: Bool) {
        guard !busy, !product.selected.string.isEmpty else { result.stringValue = "商品を選択してください。"; return }
        func number(_ s: String) -> String { s.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:",",with:"") }
        let value = number(price.stringValue); let input = OrderLineInput(productID:product.selected.string,quantity:number(quantity.stringValue),unitPrice:value.isEmpty ? nil : value)
        busy = true; for b in [check,saveButton,cancelButton] { b.isEnabled = false }; quantity.isEnabled = false; price.isEnabled = false; product.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = false }; result.stringValue = "計算中…"
        queue.async { [weak self] in
            guard let self else { return }; let outcome = Result { try self.service.orderQuote(input,context:self.context) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false; for b in [self.check,self.saveButton,self.cancelButton] { b.isEnabled = true }; self.quantity.isEnabled = true; self.price.isEnabled = true; self.product.subviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = true }
                do { let q = try outcome.get(); self.show(q); if save { try self.completion(input,q); self.window.sheetParent?.endSheet(self.window) } }
                catch { self.result.stringValue = error.localizedDescription }
            }
        }
    }
    @objc private func preview() { calculate(save:false) }
    @objc private func followList() { if !busy { price.stringValue = ""; calculate(save:false) } }
    @objc private func save() { calculate(save:true) }
    func confirmDiscard() -> Bool {
        guard !busy else { return false }; window.makeFirstResponder(nil)
        if [product.selected.string,quantity.stringValue,price.stringValue] == initialValues { return true }
        let alert = NSAlert(); alert.messageText = "明細の変更を破棄しますか？"; alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"変更を破棄")
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func cancel() { if window.attachedSheet == nil && confirmDiscard() { window.sheetParent?.endSheet(window) } }
}
