import AppKit

@main enum CampaignWorkflowUITests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    static func button(_ title: String,_ window: NSWindow) throws -> NSButton { guard let b = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title && !$0.isHiddenOrHasHiddenAncestor}) else { throw NativeDBError.message("Missing button: "+title) }; return b }
    static func field(_ title: String,_ window: NSWindow) throws -> NSTextField { guard let f = views(window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.isEditable && $0.accessibilityLabel() == title}) else { throw NativeDBError.message("Missing field: "+title) }; return f }
    static func table(_ window: NSWindow) -> NSTableView { views(window.contentView!).compactMap{$0 as? NSTableView}.first! }
    static func wait(_ label: String,_ condition: () throws -> Bool) throws { let end = Date().addingTimeInterval(10); while Date() < end { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }; let state = NSApp.windows.filter{$0.contentView != nil}.map { w in w.title+" [sheet="+(w.attachedSheet?.title ?? "none")+"]: "+views(w.contentView!).compactMap{$0 as? NSTextField}.map(\.stringValue).joined(separator:" | ") }.joined(separator:"\n"); throw NativeDBError.message("Timed out: "+label+"\n"+state) }
    static func ready(_ w: NSWindow) throws { try wait("ready") { try button("再読み込み",w).isEnabled } }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignWorkflowUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql")), identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity)
        let template = try service.saveCampaignTemplate(nil,input:["name":.text("案内テンプレート"),"subject_default":.text("件名"),"content_html":.text("<p>本文</p>")])
        let list = try db.insert("crm_TargetLists",values:["name":.text("検証用の配信対象"),"created_by":.text(identity.id)],actor:identity.id)
        for n in 0..<3 { let target = try db.insert("crm_Targets",values:["last_name":.text("営業対象\(n)"),"email":.text(n == 2 ? "stop@example.invalid" : "same@example.invalid"),"do_not_email":.integer(n == 2 ? 1 : 0),"created_by":.text(identity.id)],actor:identity.id); _ = try db.insert("TargetsToTargetLists",values:["target_id":target["id"],"target_list_id":list["id"]],actor:identity.id) }
        let ui = try CRMCampaignsWindow(service:service); ui.window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); try ready(ui.window)
        try check(ui.window.title == "キャンペーン" && table(ui.window).numberOfRows == 0,"empty Japanese campaign list")
        try button("新規キャンペーン…",ui.window).performClick(nil); try wait("new form") { ui.window.attachedSheet != nil }
        let form = ui.window.attachedSheet!; form.contentView!.layoutSubtreeIfNeeded()
        try field("キャンペーン名",form).stringValue = "日本語キャンペーン😀"
        try field("差出人名",form).stringValue = "営業部"
        try field("返信先メールアドレス",form).stringValue = "reply@example.invalid"
        let ref = views(form.contentView!).compactMap{$0 as? CRMReferenceControl}.first!; ref.setRecord(template)
        try button("下書きを作成",form).performClick(nil); try wait("details after creation") { ui.window.attachedSheet != nil && ui.window.attachedSheet !== form }
        let detail = ui.window.attachedSheet!; try ready(detail)
        try check(detail.title == "キャンペーンの詳細" && table(detail).numberOfRows == 0,"opens new campaign detail")
        detail.contentView!.layoutSubtreeIfNeeded()
        for b in views(detail.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) { let rect = b.convert(b.bounds,to:detail.contentView); try check(rect.minX >= -1 && rect.maxX <= detail.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= detail.contentView!.bounds.height+1,"detail button fits: "+b.title) }
        try button("手順を追加…",detail).performClick(nil); try wait("step form") { detail.attachedSheet != nil }
        let stepForm = detail.attachedSheet!; stepForm.contentView!.layoutSubtreeIfNeeded()
        try check(try field("順番（初回は0）",stepForm).stringValue == "0","first step auto order0")
        try field("件名",stepForm).stringValue = "{{first_name}}様へのご案内😀"
        try button("保存",stepForm).performClick(nil); try wait("step saved") { detail.attachedSheet == nil }; try ready(detail)
        try check(table(detail).numberOfRows == 1,"first step persisted")
        let campaign = try service.campaigns(search:"日本語キャンペーン").rows[0].record, id = campaign["id"].string
        try check(try service.campaignSteps(id).rows[0]["template_id"] == template["id"],"default template retained")
        try button("手順を追加…",detail).performClick(nil); try wait("followup form") { detail.attachedSheet != nil }
        let followup = detail.attachedSheet!; followup.contentView!.layoutSubtreeIfNeeded(); try check(try field("順番（初回は0）",followup).stringValue == "1","followup order")
        try field("件名",followup).stringValue = "追伸のご案内"; try field("初回配信からの日数",followup).stringValue = "7"
        let choice = views(followup.contentView!).compactMap{$0 as? NSPopUpButton}.first!; choice.selectItem(at:1)
        try button("保存",followup).performClick(nil); try wait("followup saved") { detail.attachedSheet == nil }; try ready(detail)
        try check(try service.campaignSteps(id).rows[1]["delay_days"] == .integer(7) && service.campaignSteps(id).rows[1]["send_to"] == .text("non_openers"),"followup delay/recipient selection")
        let tabs = views(detail.contentView!).compactMap{$0 as? NSSegmentedControl}.first!
        func mode(_ value: Int) throws { tabs.selectedSegment = value; _ = tabs.sendAction(tabs.action,to:tabs.target); try ready(detail) }
        try mode(1); try button("対象リストを追加…",detail).performClick(nil); try wait("list picker") { detail.attachedSheet != nil }
        let picker = detail.attachedSheet!; try wait("picker rows") { table(picker).numberOfRows == 1 }; table(picker).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); try button("選択",picker).performClick(nil); try wait("picker closed") { detail.attachedSheet == nil }; try ready(detail)
        try check(table(detail).numberOfRows == 1 && (try service.campaignTargetLists(id).total) == 1,"audience list assigned")
        try mode(2); try check(table(detail).numberOfRows == 1,"deduplicated non-suppressed audience")
        try check(views(detail.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("配信停止1件") && $0.stringValue.contains("重複1件")},"audience summary explanations")
        try mode(0); table(detail).selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); try button("手順を編集…",detail).performClick(nil); try wait("edit step") { detail.attachedSheet != nil }
        let edit = detail.attachedSheet!; try field("件名",edit).stringValue = "更新された追伸"; try button("保存",edit).performClick(nil); try wait("edited") { detail.attachedSheet == nil }; try ready(detail)
        try check(try service.campaignSteps(id).rows[1]["subject"] == .text("更新された追伸"),"step edit")
        // performClick animates through AppKit's run loop, so a fast load can
        // finish before it returns. Use the same control's target/action to
        // inspect the immediate loading state before pumping completion events.
        let refresh = try button("再読み込み",detail)
        _ = refresh.sendAction(refresh.action,to:refresh.target)
        try check(!table(detail).isEnabled && !(try button("手順を追加…",detail).isEnabled),"loading gates mutations"); try ready(detail)
        try button("閉じる",detail).performClick(nil); try wait("detail closed") { ui.window.attachedSheet == nil }; try ready(ui.window)
        try check(table(ui.window).numberOfRows == 1,"parent list reloaded")
        let fresh = try service.campaign(id); try service.deleteCampaign(fresh); try button("再読み込み",ui.window).performClick(nil); try ready(ui.window); try check(table(ui.window).numberOfRows == 0,"soft deleted hidden")
        try check(try db.jobs(events:CampaignWorkflow.events).isEmpty,"draft UI creates no delivery jobs")
        print("CampaignWorkflowUITests: \(checks) checks passed")
    }
}
