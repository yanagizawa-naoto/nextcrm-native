import AppKit
import UniformTypeIdentifiers

final class CRMProductImportWindow: NSObject {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:630),styleMask:[.titled],backing:.buffered,defer:false)
    private let service: CRMService
    private var file: URL?
    private let fileName = NSTextField(labelWithString:"ファイルを選択してください。")
    private let encoding = NSPopUpButton()
    private let choose = NSButton(title:"CSVを選択…",target:nil,action:nil)
    private let template = NSButton(title:"ひな形を保存…",target:nil,action:nil)
    private let run = NSButton(title:"取り込む",target:nil,action:nil)
    private let closeButton = NSButton(title:"閉じる",target:nil,action:nil)
    private let output = NSTextView()
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.product-import")
    private var busy = false
    var imported = false
    init(service: CRMService) {
        self.service = service; super.init(); window.title = "商品CSVの取り込み"
        let heading = NSTextField(labelWithString:window.title); heading.font = .systemFont(ofSize:22,weight:.semibold)
        let help = NSTextField(wrappingLabelWithString:"一度に500行まで取り込めます。商品は下書きで登録されます。内容に問題がある行は飛ばし、結果に理由を表示します。列名はひな形を参照してください。")
        encoding.addItems(withTitles:ProductCSVEncoding.allCases.map(\.rawValue)); encoding.setAccessibilityLabel("CSVの文字コード"); encoding.target = self; encoding.action = #selector(encodingChanged)
        choose.target = self; choose.action = #selector(selectFile); template.target = self; template.action = #selector(saveTemplate)
        run.target = self; run.action = #selector(importFile); run.isEnabled = false
        closeButton.target = self; closeButton.action = #selector(close); closeButton.keyEquivalent = "\u{1b}"
        for button in [choose,template,run,closeButton] { button.bezelStyle = .rounded }
        fileName.lineBreakMode = .byTruncatingMiddle
        let tools = NSStackView(views:[choose,NSTextField(labelWithString:"文字コード"),encoding,NSView(),template]); tools.spacing = 12
        output.isEditable = false; output.isRichText = false; output.font = .systemFont(ofSize:13); output.setAccessibilityLabel("CSVの確認と取り込み結果")
        output.isVerticallyResizable = true; output.autoresizingMask = [.width]; output.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:340).isActive = true
        let buttons = NSStackView(views:[NSView(),run,closeButton]); buttons.spacing = 12
        let root = NSStackView(views:[heading,help,tools,fileName,scroll,buttons]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20)])
        for v in [help,tools,fileName,scroll,buttons] { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
    }
    private func setBusy(_ value: Bool) { busy = value; for b in [choose,template,closeButton] { b.isEnabled = !value }; encoding.isEnabled = !value; run.isEnabled = false }
    @objc private func selectFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText,.plainText]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for:window) { [weak self] response in guard let self, response == .OK, let url = panel.url else { return }; self.file = url; self.fileName.stringValue = url.lastPathComponent; self.preview() }
    }
    @objc private func encodingChanged() { preview() }
    private func preview() {
        guard !busy, let url = file else { return }; let mode = ProductCSVEncoding.allCases[encoding.indexOfSelectedItem]
        setBusy(true); output.string = "CSVを確認中…"
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { try self.service.previewProductsCSV(url:url,encoding:mode) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.setBusy(false)
                switch result {
                case let .success(preview):
                    self.run.isEnabled = preview.count > 0
                    self.output.string = "対象：\(preview.count)行\n先頭5行までを表示しています。\n\n" + preview.rows.enumerated().map { i,r in "\(i+1). \(r["name"] ?? "")\n商品コード：\(r["sku"] ?? "")　種類：\(r["type"] ?? "")\n単価：\(r["unit_price"] ?? "") \(r["currency"] ?? "")" }.joined(separator:"\n\n")
                case let .failure(error): self.output.string = error.localizedDescription
                }
            }
        }
    }
    @objc private func importFile() {
        guard !busy, run.isEnabled, let url = file else { return }; let mode = ProductCSVEncoding.allCases[encoding.indexOfSelectedItem]
        setBusy(true); output.string = "取り込み中…"
        queue.async { [weak self] in
            guard let self else { return }; let result = Result { try self.service.importProductsCSV(url:url,encoding:mode) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.setBusy(false)
                switch result {
                case let .success(result): self.imported = self.imported || result.imported > 0; self.output.string = "取り込み完了：\(result.imported)件\nスキップ：\(result.skipped)件\n\n" + result.errors.joined(separator:"\n")
                case let .failure(error): self.output.string = "取り込みを取り消しました。このファイルからは何も保存していません。\n\n"+error.localizedDescription
                }
            }
        }
    }
    @objc private func saveTemplate() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "商品取り込みひな形.csv"
        panel.beginSheetModal(for:window) { [weak self] response in guard let self, response == .OK, let url = panel.url else { return }; do { try CRMService.productCSVTemplate.write(to:url,atomically:true,encoding:.utf8) } catch { self.output.string = error.localizedDescription } }
    }
    @objc private func close() { if !busy { window.sheetParent?.endSheet(window) } }
    func confirmDiscard()->Bool {!busy && window.attachedSheet == nil}

    #if RESTORE_PARENT_TESTING
    func importForTesting(_ url:URL){file=url;run.isEnabled=true;importFile()}
    var busyForTesting:Bool {busy}
    #endif

}
