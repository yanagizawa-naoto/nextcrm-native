import AppKit

@main enum CampaignAIUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    static func button(_ title: String, _ w: NSWindow) throws -> NSButton { guard let b = views(w.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeDBError.message("Missing " + title) }; return b }
    static func click(_ title: String, _ w: NSWindow) throws { let b = try button(title, w); _ = b.sendAction(b.action, to: b.target) }
    static func messages(_ w: NSWindow) -> String { views(w.contentView!).compactMap { $0 as? NSTextField }.map(\.stringValue).joined(separator: " | ") }
    static func wait(_ label: String, _ condition: () throws -> Bool) throws { let end = Date().addingTimeInterval(10); while Date() < end { if try condition() { return }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }; throw NativeDBError.message("Timeout: " + label) }
    static func main() { do { try CampaignTemplatesUITests.run(); try CampaignWorkflowUITests.run(); try run(); print("CampaignAIUITests: \(checks) checks passed") } catch { FileHandle.standardError.write(Data("CampaignAIUITests: \(error)\n".utf8)); exit(1) } }
    final class State: @unchecked Sendable {
        private let lock = NSLock(); private var value = "qa-key"
        var key: String { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); defer { lock.unlock() }; value = newValue } }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignAIUI-" + UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))), state = State()
        let keys = NativeAIKeys(service: service, store: NativeAIQAServices(), environment: .init(lookup: { $0 == "OPENAI_API_KEY" ? state.key : nil }))
        let html = "<table style=\"color:#225588\"><tr><td>{{company}}様😀</td></tr></table>"
        let ai = CampaignAIService(keys: keys, generate: { prompt, key in
            try? await Task.sleep(nanoseconds: 180_000_000) // Deliberately return even after cancellation to test the UI fence.
            if prompt == "失敗" { throw NativeAIError(message: "検証用エラー") }
            return .init(subject: "生成された件名😀", html: html)
        })
        let parent = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = try CampaignTemplateEditor(service: service, record: nil, ai: ai); parent.beginSheet(editor.window)
        editor.name.stringValue = "AIテンプレート"; editor.subject.stringValue = "手入力の件名"; editor.aiPrompt.stringValue = "案内"
        try click("AIで作成", editor.window); try check(!editor.aiGenerate.isEnabled && !(try button("保存", editor.window).isEnabled), "loading prevents duplicate requests/save")
        try wait("generated template") { editor.aiGenerate.isEnabled }
        try check(editor.subject.stringValue == "手入力の件名", "template generation preserves existing subject")
        let mode = views(editor.window.contentView!).compactMap { $0 as? NSSegmentedControl }.first!
        mode.selectedSegment = 1; _ = mode.sendAction(mode.action, to: mode.target)
        try check(editor.htmlEditor.string == html, "raw generated HTML/style/tag/emoji preserved")
        try check(try service.campaignTemplates().total == 0, "generation has not saved")
        editor.subject.stringValue = ""; try click("AIで作成", editor.window); try wait("empty subject fill") { editor.aiGenerate.isEnabled }
        try check(editor.subject.stringValue == "生成された件名😀", "template fills empty subject")
        try click("AIで作成", editor.window); editor.subject.stringValue = "編集中の件名"; editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor.subject))
        try wait("edited draft fence") { editor.aiGenerate.isEnabled }
        try check(editor.subject.stringValue == "編集中の件名" && messages(editor.window).contains("反映していません"), "inflight editing preserves draft")
        try click("AIで作成", editor.window); try click("作成を中止", editor.window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try check(editor.subject.stringValue == "編集中の件名" && messages(editor.window).contains("中止"), "late cancellation response ignored")
        editor.aiPrompt.stringValue = "失敗"; try click("AIで作成", editor.window); try wait("failed provider") { editor.aiGenerate.isEnabled }
        try check(editor.htmlEditor.string == html && messages(editor.window).contains("検証用エラー"), "error retains editable content")
        state.key = ""; editor.aiPrompt.stringValue = "案内"; try click("AIで作成", editor.window); try wait("missing key") { editor.aiGenerate.isEnabled }
        try check(messages(editor.window).contains("APIキーが未設定"), "Japanese missing key guidance")
        state.key = "qa-key"; try click("AIで作成", editor.window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05)); state.key = "qa-new-key"
        try wait("key replacement fence") { editor.aiGenerate.isEnabled }
        try check(!messages(editor.window).contains("下書きに反映しました") && editor.subject.stringValue == "編集中の件名", "changed key cannot apply")
        try click("保存", editor.window); try wait("template explicit save") { parent.attachedSheet == nil }
        let template = try service.campaignTemplate(service.campaignTemplates().rows[0].record["id"].string)
        try check(template["content_html"].string == html && template["subject_default"].string == "編集中の件名", "explicit save preserves full generated body")

        let campaign = try service.createCampaign(input: ["name": .text("AIキャンペーン")])
        let step = try CampaignStepEditor(service: service, campaign: campaign, original: nil, ai: ai); parent.beginSheet(step.window)
        step.editor.subject.stringValue = "変更前"; step.editor.aiPrompt.stringValue = "案内"; try click("AIで作成", step.window); try wait("campaign generation") { step.editor.aiGenerate.isEnabled }
        try check(step.editor.subject.stringValue == "生成された件名😀", "campaign generation replaces subject")
        try check(try service.campaignSteps(campaign["id"].string).total == 0 && service.campaignTemplates().total == 1, "campaign generation remains draft")
        step.window.contentView!.layoutSubtreeIfNeeded()
        for b in views(step.window.contentView!).compactMap({ $0 as? NSButton }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
            let rect = b.convert(b.bounds, to: step.window.contentView)
            try check(rect.minX >= -1 && rect.maxX <= step.window.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= step.window.contentView!.bounds.height+1, "campaign control fits: " + b.title)
        }
        try click("保存", step.window); try wait("campaign draft save") { parent.attachedSheet == nil }
        let saved = try service.campaignSteps(campaign["id"].string).rows[0]
        try check(saved["subject"].string == "生成された件名😀" && saved["order"] == .integer(0), "campaign first step persists")
        try check(try service.campaignTemplate(saved["template_id"].string)["content_html"].string == html, "campaign generated HTML persists")
        try check(try db.jobs(events: CampaignWorkflow.events).isEmpty, "generation/save creates no delivery jobs")
        let fresh = try service.campaign(campaign["id"].string)
        let edit = try CampaignStepEditor(service: service, campaign: fresh, original: saved, ai: ai); parent.beginSheet(edit.window)
        try click("テンプレートを選択…", edit.window); try wait("template picker") { edit.window.attachedSheet != nil }
        let picker = edit.window.attachedSheet!, table = views(picker.contentView!).compactMap { $0 as? NSTableView }.first!
        try wait("template choices") { table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); try click("選択", picker); try wait("chosen template") { edit.window.attachedSheet == nil }
        try check(try service.campaignTemplates().total == 2, "selecting template remains draft")
        try click("保存", edit.window); try wait("selected template save") { parent.attachedSheet == nil }
        try check(try service.campaignTemplates().total == 2, "unchanged selected template is reused")
    }
}
