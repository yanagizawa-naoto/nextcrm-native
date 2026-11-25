import AppKit

final class CRMPriceCheckWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:620),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService
    private let product: CRMReferenceControl; private let list: CRMReferenceControl; private let account: CRMReferenceControl
    private let quantity = NSTextField(string:"1")
    private let date = CRMDateControl(value:.text(ISO8601DateFormatter().string(from:Date())),includesTime:false,required:true,utc:true)
    private let output = NSTextView(); private let calculate = NSButton(title:"価格を計算",target:nil,action:nil)
    private var picker: CRMReferencePicker?
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.price")
    init(service: CRMService, productID: SQLValue = .null, listID: SQLValue = .null) {
        self.service = service
        product = CRMReferenceControl(model:"crm_Products",selected:productID,service:service)
        list = CRMReferenceControl(model:"crm_PriceLists",selected:listID,service:service)
        account = CRMReferenceControl(model:"crm_Accounts",selected:.null,service:service)
        super.init(); window.title = "価格の確認"
        let heading = NSTextField(labelWithString:"価格の確認"); heading.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"数量と適用日に合うルールを使って単価を計算します。価格表が未設定の場合は商品の販売単価を使います。")
        var views: [NSView] = [heading,help]
        for (label,control) in [("商品",product),("価格表",list),("取引先",account)] {
            control.setAccessibilityLabel(label); control.heightAnchor.constraint(equalToConstant:32).isActive = true
            control.choose = { [weak self,weak control] in
                guard let self, let control, self.picker == nil else { return }
                let picker = CRMReferencePicker(model:control.model,service:service) { [weak self,weak control] record in
                    if let record { control?.setRecord(record) }; self?.picker = nil
                }; self.picker = picker; self.window.beginSheet(picker.window); picker.start()
            }
            let row = NSStackView(views:[NSTextField(labelWithString:label),control]); row.spacing = 12; control.widthAnchor.constraint(equalToConstant:580).isActive = true; views.append(row)
        }
        let resolve = NSButton(title:"取引先の価格表を適用（未設定なら標準価格表）",target:self,action:#selector(resolveList)); resolve.bezelStyle = .rounded; views.append(resolve)
        quantity.setAccessibilityLabel("計算する数量"); quantity.widthAnchor.constraint(equalToConstant:140).isActive = true
        date.widthAnchor.constraint(equalToConstant:330).isActive = true; date.heightAnchor.constraint(equalToConstant:32).isActive = true
        let inputs = NSStackView(views:[NSTextField(labelWithString:"数量"),quantity,NSTextField(labelWithString:"適用日（UTC）"),date]); inputs.spacing = 10; views.append(inputs)
        output.isEditable = false; output.isRichText = false; output.font = .systemFont(ofSize:14); output.setAccessibilityLabel("価格計算の結果"); output.string = "商品を選択して「価格を計算」を押してください。"
        output.isVerticallyResizable = true; output.autoresizingMask = [.width]; output.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:210).isActive = true; views.append(scroll)
        calculate.target = self; calculate.action = #selector(check); calculate.bezelStyle = .rounded
        let close = NSButton(title:"閉じる",target:self,action:#selector(close)); close.bezelStyle = .rounded; close.keyEquivalent = "\u{1b}"
        views.append(NSStackView(views:[NSView(),calculate,close]))
        let root = NSStackView(views:views); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for view in [help,scroll,views.last!] { view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
    }
    @objc private func resolveList() {
        do {
            if let id = try service.resolvedPriceList(accountID:account.selected == .null ? nil : account.selected.string) { list.setRecord(try service.catalogRecord("crm_PriceLists",.text(id))) }
            else { list.selected = .null; list.clearSelection() }
            output.string = "価格表を適用しました。「価格を計算」で確認できます。"
        } catch { output.string = error.localizedDescription }
    }
    @objc private func check() {
        window.makeFirstResponder(nil)
        let productID = product.selected.string; let listID = list.selected == .null ? nil : list.selected.string
        let quantity = quantity.stringValue; let date = date.value.string
        guard !productID.isEmpty else { output.string = "商品を選択してください。"; return }
        calculate.isEnabled = false; output.string = "計算中…"
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.service.checkedPrice(productID:productID,listID:listID,quantity:quantity,date:date) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.calculate.isEnabled = true
                switch result {
                case let .success(r):
                    let labels = ["fallback":"商品単価を使用","fixed":"固定単価","base":"基準価格","percentage":"割引後","discount":"割引後","round":"丸め後","surcharge":"加算後","minMargin":"下限適用後","maxMargin":"上限適用後"]
                    self.output.string = "商品：\((try? self.service.referenceName("crm_Products",id:productID)) ?? "")\n数量：\(quantity)　適用日：\(date.prefix(10))\n適用単価：\(r.price) \(r.currency)\n通常単価：\(r.listPrice) \(r.currency)\n\n" + r.steps.map { "\(labels[$0.label] ?? $0.label)：\($0.value)" }.joined(separator:"\n")
                case let .failure(error): self.output.string = error.localizedDescription
                }
            }
        }
    }
    @objc private func close() { window.sheetParent?.endSheet(window) }
}
