import AppKit

@main enum NativePluginPresentationTests {
    static var checks = 0
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("{\"checks\":\(checks),\"exit\":0}"); exit(0) }
            catch { print(try! NativePluginJSON.text(["checks": checks, "error": error.localizedDescription])); exit(1) }
        }; app.run()
    }
    @MainActor static func check(_ value: Bool, _ name: String) throws { checks += 1; if !value { throw NativePluginError(message: name) } }
    @MainActor static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    @MainActor static func button(_ window: NSWindow, _ title: String) -> NSButton { views(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }! }
    @MainActor static func settle(_ window: NSWindow) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !button(window, "再読み込み").isEnabled && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(button(window, "再読み込み").isEnabled, "presentation load finishes")
    }
    @MainActor static func run() async throws {
        var allowed = true, empty = false, opened: NativePluginPresentation.RecordTarget?
        let presentation = NativePluginPresentation(title: "連携の状況：検証用", sections: [
            .init(title: "同期の概要", columns: ["項目", "状態"], rows: [[.init("受注の送信"), .init("一時停止")]]),
            .init(title: "担当者が必要な取引先", columns: ["取引先", "関連する取引先"], rows: [[.init("日本語の会社", record: .init(model: "crm_Accounts", id: "account-qa")), .init("別の会社", record: .init(model: "crm_Accounts", id: "account-other"))]]),
            .init(title: "外部リンク", columns: ["内容"], rows: [[.init("利用できない形式", url: URL(string: "javascript:alert(1)"))]])
        ])
        let controller = NativePluginPresentationWindow(title: "連携の状況", authorize: {
            if !allowed { throw NativePluginError(message: "この利用者では操作できません。") }
        }, load: { empty ? nil : presentation })
        controller.onOpenRecord = { opened = $0 }; controller.start(); try await settle(controller.window)
        let all = views(controller.window.contentView!), table = all.compactMap { $0 as? NSTableView }.first!, picker = all.compactMap { $0 as? NSPopUpButton }.first!
        try check(picker.itemTitles == ["同期の概要", "担当者が必要な取引先", "外部リンク"], "Japanese section choices")
        try check(table.numberOfRows == 1 && table.tableColumns.map(\.title) == ["項目", "状態"], "section table displays the right columns and rows")
        try check(!button(controller.window, "情報を開く").isEnabled, "no selected link is disabled")
        picker.selectItem(at: 1); NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try check(button(controller.window, "情報を開く").isEnabled, "internal record is navigable")
        button(controller.window, "情報を開く").performClick(nil)
        try check(opened?.model == "crm_Accounts" && opened?.id == "account-qa", "record navigation preserves model and identifier")
        let destination = views(controller.window.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0 !== picker }!
        try check(!destination.isHidden && destination.itemTitles == ["日本語の会社", "別の会社"], "all record destinations in one row are selectable")
        destination.selectItem(at: 1); button(controller.window, "情報を開く").performClick(nil)
        try check(opened?.id == "account-other", "secondary record link is reachable")
        controller.onOpenRecord = { _ in throw NativePluginError(message: "移動先の表示権限がありません。") }
        button(controller.window, "情報を開く").performClick(nil)
        try check(views(controller.window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "移動先の表示権限がありません。" }, "destination errors remain in the current sheet")
        controller.onOpenRecord = { opened = $0 }
        opened = nil; allowed = false; button(controller.window, "情報を開く").performClick(nil)
        try check(opened == nil, "record navigation rechecks current authority")
        allowed = true; picker.selectItem(at: 2); NSApp.sendAction(picker.action!, to: picker.target, from: picker)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try check(!button(controller.window, "情報を開く").isEnabled, "non-HTTP external links cannot be opened")
        try check(destination.isHidden, "destination choices clear on section change")
        button(controller.window, "再読み込み").performClick(nil); try await settle(controller.window)
        try check(picker.titleOfSelectedItem == "外部リンク", "reload retains current section")
        allowed = false; button(controller.window, "再読み込み").performClick(nil); try await settle(controller.window)
        try check(table.numberOfRows == 0 && picker.numberOfItems == 0, "lost authority clears previously loaded records")
        try check(!button(controller.window, "コピー").isEnabled && !button(controller.window, "情報を開く").isEnabled, "failed load disables record actions")
        allowed = true; empty = true; button(controller.window, "再読み込み").performClick(nil); try await settle(controller.window)
        try check(table.numberOfRows == 0 && table.tableColumns.isEmpty, "unavailable plugin has no stale columns or rows")
        button(controller.window, "閉じる").performClick(nil)
    }
}
