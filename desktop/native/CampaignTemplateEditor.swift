import AppKit

final class CampaignTemplateEditor: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    let window = NSPanel(contentRect:NSRect(x:0,y:0,width:1000,height:780),styleMask:[.titled],backing:.buffered,defer:false)
    let body = CampaignTextView(); let htmlEditor = NSTextView()
    private let templatePreview:CampaignTemplatePreview
    private var previewCloseObserver:NSObjectProtocol?
    let name = NSTextField(); let subject = NSTextField(); let descriptionField = NSTextView()
    private let service: CRMService; private let original: NativeRecord?
    private let ai: CampaignAIService?; private let aiContext: CampaignAIContext
    private let customSave: (([String: SQLValue]) throws -> (() throws -> Void))?
    private let extraView: NSView?
    var isSaving: Bool { busy }
    private let replaceSubject: Bool
    let aiPrompt = NSTextField(); let aiGenerate = NSButton(title:"AIで作成",target:nil,action:nil)
    private let aiCancel = NSButton(title:"作成を中止",target:nil,action:nil)
    private var aiTask: Task<Void, Never>?; private var aiGeneration = 0; private var draftRevision = 0; private var extraChanged = false
    private var storedHTML: String; private var storedJSON: String
    private var bodyChanged = false; private var richDirty = false; private var htmlDirty = false; private var setting = false; private var busy = false
    private let mode = NSSegmentedControl(labels:["本文を編集","HTMLを編集","プレビュー"],trackingMode:.selectOne,target:nil,action:nil)
    private let paragraph = NSPopUpButton(); private let scroll = NSScrollView(); private let message = NSTextField(wrappingLabelWithString:"")
    private let protectedInfo = NSTextField(wrappingLabelWithString:"")
    private let saveButton = NSButton(title:"保存",target:nil,action:nil); private let cancel = NSButton(title:"キャンセル",target:nil,action:nil)
    private var toolbar: [NSButton] = []; private var currentMode = 0
    private let queue = MemoryBudget.queue(label:"local.nextcrm.native.template-save")
    init(service: CRMService, record: NativeRecord?, ai: CampaignAIService? = nil, allowsAI: Bool = true,
         context: CampaignAIContext? = nil, extraView: NSView? = nil,
         title: String? = nil, onPrepareSave: (([String: SQLValue]) throws -> (() throws -> Void))? = nil,
         makePreviewViewer:@escaping CampaignTemplatePreview.Viewer = {try NativeMailHTMLSession(document:$0,onFailure:$1)}) throws {
        templatePreview=CampaignTemplatePreview(authorize:{try service.authenticated()},makeViewer:makePreviewViewer)
        self.service = service; original = record; storedHTML = record?["content_html"].string ?? ""; storedJSON = record?["content_json"].string ?? "{\"type\":\"doc\",\"content\":[{\"type\":\"paragraph\"}]}"
        self.ai = allowsAI ? (ai ?? CampaignAIService(keys: NativeAIKeys(service: service, store: KeychainNativeAISecrets(databaseURL: service.db.url)))) : nil
        aiContext = context ?? .template(record); customSave = onPrepareSave; self.extraView = extraView
        if case .step = context { replaceSubject = true } else { replaceSubject = false }
        super.init(); window.title = title ?? (record == nil ? "メールテンプレートを作成" : "メールテンプレートを編集")
        name.stringValue = record?["name"].string ?? ""; subject.stringValue = record?["subject_default"].string ?? ""; descriptionField.string = record?["description"].string ?? ""
        for (field,label) in [(name,"テンプレート名"),(subject,"件名")] { field.delegate = self; field.setAccessibilityLabel(label) }
        let heading = NSTextField(labelWithString:window.title); heading.font = .systemFont(ofSize:22,weight:.semibold)
        descriptionField.isRichText = false; descriptionField.allowsUndo = true; descriptionField.delegate = self; descriptionField.font = .systemFont(ofSize:13); descriptionField.setAccessibilityLabel("説明"); descriptionField.isHorizontallyResizable = false; descriptionField.autoresizingMask = [.width]; descriptionField.textContainer?.widthTracksTextView = true
        let descriptionScroll = NSScrollView(); descriptionScroll.hasVerticalScroller = true; descriptionScroll.borderType = .bezelBorder; descriptionScroll.documentView = descriptionField; descriptionScroll.heightAnchor.constraint(equalToConstant:56).isActive = true
        let grid = NSGridView(views:[[NSTextField(labelWithString:"テンプレート名＊"),name],[NSTextField(labelWithString:"件名＊"),subject],[NSTextField(labelWithString:"説明"),descriptionScroll]])
        grid.column(at:0).width = 120; grid.column(at:1).xPlacement = .fill; grid.rowSpacing = 8
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        paragraph.addItems(withTitles:["本文","見出し1","見出し2","見出し3","引用","コード"]); paragraph.target = self; paragraph.action = #selector(paragraphChanged); paragraph.setAccessibilityLabel("段落の書式")
        let styles = NSStackView(views:[button("太字",#selector(bold)),button("斜体",#selector(italic)),button("下線",#selector(underline)),button("取消線",#selector(strike)),paragraph,button("箇条書き",#selector(bullets)),button("番号付き",#selector(numbered)),button("リンク…",#selector(link)),button("リンク解除",#selector(unlink))]); styles.spacing = 6
        body.isRichText = true; body.importsGraphics = false; body.allowsUndo = true; body.delegate = self; body.setAccessibilityLabel("テンプレート本文")
        body.isAutomaticLinkDetectionEnabled = false; body.isAutomaticQuoteSubstitutionEnabled = false; body.isAutomaticDashSubstitutionEnabled = false; body.isAutomaticTextReplacementEnabled = false
        body.typingAttributes = CampaignRichText.attributes(CampaignTextBlock())
        htmlEditor.isRichText = false; htmlEditor.font = .monospacedSystemFont(ofSize:13,weight:.regular); htmlEditor.allowsUndo = true; htmlEditor.delegate = self; htmlEditor.setAccessibilityLabel("テンプレートのHTML")
        htmlEditor.isAutomaticQuoteSubstitutionEnabled = false; htmlEditor.isAutomaticDashSubstitutionEnabled = false; htmlEditor.isAutomaticTextReplacementEnabled = false
        for view in [body,htmlEditor] { view.isHorizontallyResizable = false; view.isVerticallyResizable = true; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainerInset = NSSize(width:14,height:14); view.backgroundColor = .textBackgroundColor }
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = body
        protectedInfo.font = .systemFont(ofSize:11); protectedInfo.textColor = .secondaryLabelColor; protectedInfo.maximumNumberOfLines = 2
        let hint = NSTextField(wrappingLabelWithString:"差し込み項目：{{first_name}} {{last_name}} {{email}} {{company}} {{position}}　プレビューは架空の値を表示します。")
        hint.font = .systemFont(ofSize:11); hint.textColor = .secondaryLabelColor
        message.font = .systemFont(ofSize:12); message.textColor = .systemRed; message.maximumNumberOfLines = 3
        aiPrompt.placeholderString = "作成したいメールの内容を入力…"; aiPrompt.setAccessibilityLabel("AIへの作成指示"); aiPrompt.delegate = self
        aiPrompt.setContentHuggingPriority(.defaultLow, for: .horizontal)
        aiGenerate.target = self; aiGenerate.action = #selector(generateWithAI); aiGenerate.bezelStyle = .rounded; aiGenerate.isEnabled = self.ai != nil; aiPrompt.isEnabled = self.ai != nil
        aiCancel.target = self; aiCancel.action = #selector(cancelAI); aiCancel.bezelStyle = .rounded; aiCancel.isHidden = true
        let aiRow = NSStackView(views: [aiPrompt, aiGenerate, aiCancel]); aiRow.spacing = 8
        let aiHint = NSTextField(wrappingLabelWithString: "指示をOpenAIへ送信して本文を作成します（API利用料が発生する場合があります）。確認・編集してから保存してください。")
        aiHint.font = .systemFont(ofSize:11); aiHint.textColor = .secondaryLabelColor
        saveButton.target = self; saveButton.action = #selector(save); saveButton.bezelStyle = .rounded; saveButton.keyEquivalent = "s"; saveButton.keyEquivalentModifierMask = [.command]
        cancel.target = self; cancel.action = #selector(close); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views:[NSView(),cancel,saveButton]); footer.spacing = 10
        let root = NSStackView(views:[heading] + (extraView.map{[$0]} ?? []) + [grid,aiRow,aiHint,mode,styles,scroll,protectedInfo,hint,message,footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 8; root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:20),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-20),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:20),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor,constant:-20),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220)])
        for v in [grid,aiRow,aiHint,styles,scroll,protectedInfo,hint,message,footer] + (extraView.map{[$0]} ?? []) { v.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        try loadRich(); window.initialFirstResponder = name
        previewCloseObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in self?.templatePreview.close()}
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { let b = NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; toolbar.append(b); return b }
    private func extraEnabled(_ enabled: Bool) {
        func visit(_ view: NSView) { (view as? NSControl)?.isEnabled = enabled; view.subviews.forEach(visit) }
        if let extraView { visit(extraView) }
    }
    private func loadRich() throws {
        let loaded = try CampaignRichText.load(storedHTML); setting = true; body.textStorage?.setAttributedString(loaded.text); setting = false; body.undoManager?.removeAllActions()
        protectedInfo.stringValue = loaded.protectedBlocks > 0 ? "表・画像・詳細な書式を含む\(loaded.protectedBlocks)か所のHTMLを保持しています。その内容を変更する場合は「HTMLを編集」を使います。プレビューでは表・画像・書式を別ウィンドウで確認できます。" : "Mac標準の文字編集です。外部画像やリンク先は自動で読み込みません。"
        richDirty = false; body.needsDisplay = true
    }
    private func synchronize() throws {
        if currentMode == 0 && richDirty { let encoded = try CampaignRichText.serialize(body.attributedString()); storedHTML = encoded.html; storedJSON = encoded.json; richDirty = false }
        if currentMode == 1 && htmlDirty { storedHTML = htmlEditor.string; let loaded = try CampaignRichText.load(storedHTML); storedJSON = try CampaignRichText.serialize(loaded.text).json; htmlDirty = false; try loadRich() }
    }
    @objc private func modeChanged() {
        do {
            try synchronize(); let requestedMode = mode.selectedSegment; setting = true
            if requestedMode != 2 {templatePreview.close()}
            switch requestedMode {
            case 1: htmlEditor.string = storedHTML; scroll.documentView = htmlEditor
            case 2:
                scroll.documentView = templatePreview.view
                templatePreview.show(html:storedHTML,subject:subject.stringValue)
            default: scroll.documentView = body
            }
            currentMode = requestedMode; setting = false; toolbar.forEach{$0.isEnabled = currentMode == 0}; paragraph.isEnabled = currentMode == 0; message.stringValue = ""
        } catch { setting = false; mode.selectedSegment = currentMode; message.stringValue = error.localizedDescription }
    }
    func textDidChange(_ notification: Notification) {
        guard !setting else { return }; draftRevision += 1; if notification.object as AnyObject? === body || notification.object as AnyObject? === htmlEditor { bodyChanged = true }
        if notification.object as AnyObject? === body { richDirty = true; body.needsDisplay = true }
        if notification.object as AnyObject? === htmlEditor { htmlDirty = true }
    }
    func controlTextDidChange(_ notification: Notification) { draftRevision += 1; if aiTask == nil { message.stringValue = "" } }
    deinit { aiTask?.cancel();if let previewCloseObserver {NotificationCenter.default.removeObserver(previewCloseObserver)};let preview=templatePreview;DispatchQueue.main.async{preview.close()} }
    @objc private func cancelAI() {
        aiGeneration += 1; aiTask?.cancel(); aiTask = nil; aiGenerate.isEnabled = !busy && ai != nil; aiCancel.isHidden = true; saveButton.isEnabled = !busy
        message.stringValue = "AIの作成を中止しました。編集中の内容は保持しています。"
    }
    @objc private func generateWithAI() {
        guard let ai else { message.stringValue="復元したAI接続は確認待ちです。本文の手動編集・保存は利用できます。"; return }
        guard !busy, aiTask == nil, window.attachedSheet == nil else { return }
        do { window.makeFirstResponder(nil); try synchronize(); try CampaignAIClient.validatePrompt(aiPrompt.stringValue) }
        catch { message.stringValue = error.localizedDescription; return }
        aiGeneration += 1; let generation = aiGeneration, revision = draftRevision, prompt = aiPrompt.stringValue
        let service = ai, context = aiContext
        aiGenerate.isEnabled = false; aiCancel.isHidden = false; saveButton.isEnabled = false; message.stringValue = "AIでメールを作成しています…"
        aiTask = Task { @MainActor [weak self] in
            let result: Result<CampaignAIResult, Error>
            do { result = .success(try await service.create(prompt: prompt, context: context)) }
            catch { result = .failure(error) }
            guard let self, self.aiGeneration == generation else { return }
            self.aiTask = nil; self.aiGenerate.isEnabled = self.ai != nil; self.aiCancel.isHidden = true; self.saveButton.isEnabled = true
            do {
                let generated = try result.get(); try Task.checkCancellation()
                self.window.makeFirstResponder(nil)
                guard self.draftRevision == revision else { self.message.stringValue = "作成中に編集内容が変わったため、AIの結果は反映していません。現在の内容を確認して再作成してください。"; return }
                try service.validate(context: context, choice: generated.choice)
                try self.replaceBody(generated.draft.html, subject: self.replaceSubject || self.subject.stringValue.isEmpty ? generated.draft.subject : self.subject.stringValue)
                self.message.stringValue = "AIの内容を下書きに反映しました。確認・編集してから保存してください。"
            } catch { self.message.stringValue = error is CancellationError ? "AIの作成を中止しました。" : error.localizedDescription }
        }
    }
    /// Used by both AI and the campaign's template picker. Parse first so a
    /// malformed result cannot partially replace the current draft.
    func replaceBody(_ html: String, subject: String, json: String? = nil) throws {
        guard !busy else { throw NativeDBError.conflict }
        let loaded = try CampaignRichText.load(html); let encoded = try json ?? CampaignRichText.serialize(loaded.text).json
        storedHTML = html; storedJSON = encoded; self.subject.stringValue = subject
        bodyChanged = true; richDirty = false; htmlDirty = false; draftRevision += 1
        try loadRich(); setting = true; htmlEditor.string = html; setting = false
        modeChanged()
    }
    func markDraftChanged() { extraChanged = true; draftRevision += 1 }
    private var dirty: Bool { extraChanged || bodyChanged || name.stringValue != (original?["name"].string ?? "") || subject.stringValue != (original?["subject_default"].string ?? "") || descriptionField.string != (original?["description"].string ?? "") }
    func confirmDiscard() -> Bool {
        guard !busy else { return false }; guard dirty else { if aiTask != nil { cancelAI() }; return true }
        let alert = NSAlert(); alert.messageText = "編集内容を破棄しますか？"; alert.informativeText = "保存していない変更があります。"; alert.addButton(withTitle:"編集を続ける"); alert.addButton(withTitle:"破棄する")
        let discard = alert.runModal() == .alertSecondButtonReturn; if discard, aiTask != nil { cancelAI() }; return discard
    }
    @objc private func close() { guard confirmDiscard() else { return };templatePreview.close(); window.sheetParent?.endSheet(window,returnCode:.cancel) }
    @objc private func save() {
        guard !busy, aiTask == nil else { return }
        do {
            window.makeFirstResponder(nil); try synchronize()
            var input: [String:SQLValue] = ["name":.text(name.stringValue),"subject_default":.text(subject.stringValue),"description":descriptionField.string.isEmpty ? .null : .text(descriptionField.string)]
            if original == nil || bodyChanged || customSave != nil { input["content_html"] = .text(storedHTML); input["content_json"] = .text(storedJSON) }
            let work = try customSave?(input) ?? { [service, original] in _ = try service.saveCampaignTemplate(original, input: input) }
            busy = true; saveButton.isEnabled = false; cancel.isEnabled = false; mode.isEnabled = false; [name,subject].forEach{$0.isEnabled = false}; descriptionField.isEditable = false; body.isEditable = false; htmlEditor.isEditable = false; toolbar.forEach{$0.isEnabled = false}; paragraph.isEnabled = false
            aiGenerate.isEnabled = false; aiPrompt.isEnabled = false; extraEnabled(false)
            queue.async { [weak self] in guard let self else { return }; let result = Result { try work() }; DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                self.aiGenerate.isEnabled = self.ai != nil; self.aiPrompt.isEnabled = self.ai != nil; self.extraEnabled(true)
                switch result { case .success: self.templatePreview.close();self.window.sheetParent?.endSheet(self.window,returnCode:.OK)
                case let .failure(error): self.message.stringValue = error.localizedDescription; self.saveButton.isEnabled = true; self.cancel.isEnabled = true; self.mode.isEnabled = true; [self.name,self.subject].forEach{$0.isEnabled = true}; self.descriptionField.isEditable = true; self.body.isEditable = true; self.htmlEditor.isEditable = true; self.toolbar.forEach{$0.isEnabled = self.currentMode == 0}; self.paragraph.isEnabled = self.currentMode == 0 }
            } }
        } catch { message.stringValue = error.localizedDescription }
    }
    private func replace(_ range: NSRange, with text: NSAttributedString) {
        guard let storage = body.textStorage else { return }; let previous = storage.attributedSubstring(from:range)
        body.undoManager?.registerUndo(withTarget:self) { target in target.replace(NSRange(location:range.location,length:text.length),with:previous) }
        storage.replaceCharacters(in:range,with:text); body.didChangeText(); body.setSelectedRange(NSRange(location:range.location,length:text.length)); body.needsDisplay = true
    }
    private func format(_ change: ([NSAttributedString.Key:Any]) -> [NSAttributedString.Key:Any]) {
        guard currentMode == 0, !busy else { return }; body.unmarkText(); let range = body.selectedRange()
        if range.length == 0 { body.typingAttributes = change(body.typingAttributes); window.makeFirstResponder(body); return }
        let text = NSMutableAttributedString(attributedString:body.attributedString().attributedSubstring(from:range))
        var protected = false
        text.enumerateAttributes(in:NSRange(location:0,length:text.length)) { a,r,_ in if CampaignTextBlock.read(a[CampaignTextBlock.key]).rawHTML != nil { protected = true }; text.setAttributes(change(a),range:r) }
        guard !protected else { message.stringValue = "保護された内容は「HTMLを編集」で変更できます。"; return }
        replace(range,with:text); window.makeFirstResponder(body)
    }
    @objc private func bold() { format { a in var a = a; let font = a[.font] as? NSFont ?? CampaignRichText.baseFont; let enabled = !(a[CampaignRichText.boldKey] as? Bool ?? NSFontManager.shared.traits(of:font).contains(.boldFontMask)); a[CampaignRichText.boldKey] = enabled; a[.font] = enabled ? NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) : NSFontManager.shared.convert(font,toNotHaveTrait:.boldFontMask); return a } }
    @objc private func italic() { format { a in var a = a; if a[.obliqueness] == nil { a[.obliqueness] = 0.18 } else { a.removeValue(forKey:.obliqueness) }; return a } }
    @objc private func underline() { format { a in var a = a; a[.underlineStyle] = ((a[.underlineStyle] as? NSNumber)?.intValue ?? 0) == 0 ? 1 : 0; return a } }
    @objc private func strike() { format { a in var a = a; a[.strikethroughStyle] = ((a[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) == 0 ? 1 : 0; return a } }
    @objc private func unlink() { format { a in var a = a; a.removeValue(forKey:.link); a[.foregroundColor] = NSColor.labelColor; return a } }
    @objc private func link() {
        guard body.selectedRange().length > 0 else { message.stringValue = "リンクにする文字を選択してください。"; return }
        let alert = NSAlert(); alert.messageText = "リンク先のURL"; alert.informativeText = "http・https・mailtoのURLを入力してください。"; let field = NSTextField(frame:NSRect(x:0,y:0,width:430,height:24)); field.setAccessibilityLabel("リンク先URL"); alert.accessoryView = field; alert.addButton(withTitle:"設定"); alert.addButton(withTitle:"キャンセル")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self, response == .alertFirstButtonReturn else { return }; guard let safe = CampaignRichText.safeLink(field.stringValue) else { self.message.stringValue = "リンク先のURLを確認してください。"; return }; self.format { a in var a = a; a[.link] = safe; a[.foregroundColor] = NSColor.linkColor; return a } }
    }
    private func blocks(_ change: (CampaignTextBlock, Int) -> CampaignTextBlock) {
        let selection = body.selectedRange(); let text = NSMutableAttributedString(attributedString:body.attributedString()); var n = 0
        for r in CampaignRichText.paragraphs(text) where selection.length == 0 ? (selection.location >= r.location && selection.location <= NSMaxRange(r)) : NSIntersectionRange(NSRange(location:r.location,length:max(1,r.length)),selection).length > 0 {
            guard r.location < text.length else { continue }; let old = CampaignTextBlock.read(text.attribute(CampaignTextBlock.key,at:r.location,effectiveRange:nil)); guard old.rawHTML == nil else { message.stringValue = "保護されたHTMLは書式変更できません。"; return }
            let next = change(old,n); n += 1; let full = NSRange(location:r.location,length:min(r.length+1,text.length-r.location)); text.addAttributes([CampaignTextBlock.key:next.encoded,.paragraphStyle:CampaignRichText.style(next)],range:full)
            text.enumerateAttribute(.font,in:full) { value,range,_ in let base = CampaignRichText.attributes(next)[.font] as! NSFont; let oldFont = value as? NSFont ?? base; let new = NSFontManager.shared.traits(of:oldFont).contains(.italicFontMask) ? NSFontManager.shared.convert(base,toHaveTrait:.italicFontMask) : base; let styled = text.attribute(CampaignRichText.boldKey,at:range.location,effectiveRange:nil) as? Bool == true ? NSFontManager.shared.convert(new,toHaveTrait:.boldFontMask) : new; text.addAttribute(.font,value:styled,range:range) }
        }
        replace(NSRange(location:0,length:body.attributedString().length),with:text); body.setSelectedRange(selection); window.makeFirstResponder(body)
    }
    @objc private func paragraphChanged() {
        let index = paragraph.indexOfSelectedItem
        blocks { b,_ in var b = b; b.tag = ["p","h1","h2","h3","p","pre"][index]; b.path.removeAll{$0.tag == "blockquote"}; if index == 4 { b.path.insert(CampaignContainer(tag:"blockquote",id:UUID().uuidString),at:0) }; return b }
    }
    private func list(_ tag: String) { let id = UUID().uuidString; blocks { b,_ in var b = b; let remove = b.path.contains{$0.tag == tag}; b.path.removeAll{["ul","ol","li"].contains($0.tag)}; if !remove { b.path += [CampaignContainer(tag:tag,id:id,start:tag == "ol" ? 1 : nil),CampaignContainer(tag:"li",id:UUID().uuidString)] }; return b } }
    @objc private func bullets() { list("ul") }; @objc private func numbered() { list("ol") }
}
