import AppKit

@main enum CampaignRelaySettingsUITests {
    static var checks = 0
    static let now = CampaignRelayClient.date("2026-11-14T10:00:00.125Z")!
    final class Store: CampaignRelayCredentialStore {
        var value: CampaignRelayCredentials?
        func load(interactive: Bool) throws -> CampaignRelayCredentials? { value }
        func save(_ value: CampaignRelayCredentials) throws { self.value = value }
        func remove() throws { value = nil }
    }
    final class Requests {
        private let lock = NSLock()
        private var blocked = false, paused = false
        private var continuation: CheckedContinuation<Void,Never>?
        func blockProbe(_ value: Bool) { lock.lock(); blocked = value; lock.unlock() }
        func pauseHealth(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
        var waiting: Bool { lock.lock(); defer { lock.unlock() }; return continuation != nil }
        private func flags() -> (Bool,Bool) { lock.lock(); defer { lock.unlock() }; return (blocked,paused) }
        func release() { lock.lock(); let c = continuation; continuation = nil; paused = false; lock.unlock(); c?.resume() }
        func request(_ r: URLRequest) async throws -> (Data,HTTPURLResponse) {
            if flags().0 && r.url!.path.hasSuffix("/api/campaigns/unsubscribe") { return (Data("not found".utf8),HTTPURLResponse(url:r.url!,statusCode:404,httpVersion:nil,headerFields:[:])!) }
            let response = try await CampaignRelayClient.network(r)
            if flags().1 && r.url!.path.hasSuffix("/health") { await withCheckedContinuation { c in lock.lock(); continuation = c; lock.unlock() } }
            return response
        }
    }
    static func views(_ v: NSView) -> [NSView] { [v]+v.subviews.flatMap(views) }
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL relay UI: "+label) }; checks += 1 }
    static func button(_ title: String,_ w: NSWindow) throws -> NSButton { guard let b = views(w.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title && !$0.isHiddenOrHasHiddenAncestor}) else { throw NativeDBError.message("Missing button: "+title) }; return b }
    static func field(_ label: String,_ w: NSWindow) throws -> NSTextField { guard let f = views(w.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel() == label && $0.isEditable}) else { throw NativeDBError.message("Missing field: "+label) }; return f }
    static func text(_ w: NSWindow) -> String { views(w.contentView!).compactMap{$0 as? NSTextField}.filter{!$0.isEditable}.map(\.stringValue).joined(separator:"\n") }
    static func wait(_ label: String,_ condition: () throws -> Bool) throws {
        let end = Date().addingTimeInterval(15)
        while Date() < end { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        throw NativeDBError.message("Timeout: "+label)
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("CampaignRelaySettingsUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RelayUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/env"); process.arguments = ["node",resources.appendingPathComponent("../campaign-relay/native-harness.cjs").standardizedFileURL.path,root.appendingPathComponent("receiver.sqlite").path]
        process.standardOutput = output; process.standardError = errors; try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var line = Data()
        while line.count < 4096, let b = try output.fileHandleForReading.read(upToCount:1), !b.isEmpty { line.append(b); if b[0] == 10 { break } }
        guard let json = try? JSONSerialization.jsonObject(with:line) as? [String:Any], let port = json["port"] as? Int else { throw NativeDBError.message("Local receiver failed to start") }
        let url = "http://127.0.0.1:\(port)/crm", store = Store(), requests = Requests(); defer { requests.release() }
        let ui = try CRMCampaignRelaySettingsWindow(service:service,store:store,allowLoopbackHTTP:true,request:requests.request,clock:{now})
        let host = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:800,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        host.beginSheet(ui.window); let panel = ui.window; panel.contentView!.layoutSubtreeIfNeeded()
        var saved = 0; ui.onSaved = { saved += 1 }
        try check(panel.title == "キャンペーンの受信窓口","Japanese window title")
        try check(try field("受信窓口の接続キー",panel) is NSSecureTextField,"secret input uses native secure field")
        try check(try !button("接続キーを削除…",panel).isEnabled,"no delete without saved key")
        try field("受信窓口の公開URL",panel).stringValue = url
        try field("メールのアプリ名",panel).stringValue = "日本語CRM😀"
        try field("受信窓口の接続キー",panel).stringValue = CampaignRelayQACredentials.key
        try button("接続を確認して保存",panel).performClick(nil)
        try wait("saved") { try button("接続を確認して保存",panel).isEnabled && store.value != nil }
        try check(saved == 1 && store.value?.appName == "日本語CRM😀" && store.value?.publicURL == url,"actual controls save through signed loopback connection")
        try check(try field("受信窓口の接続キー",panel).stringValue.isEmpty && field("受信窓口の接続キー",panel).placeholderString?.contains("保存済み") == true,"saved secret never rendered into field")
        try check(text(panel).contains("接続を確認して保存しました"),"Japanese success feedback")
        panel.contentView!.layoutSubtreeIfNeeded()
        for b in views(panel.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) {
            let rect = b.convert(b.bounds,to:panel.contentView)
            try check(rect.minX >= -1 && rect.maxX <= panel.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= panel.contentView!.bounds.height+1,"button fits: "+b.title)
        }
        try field("メールのアプリ名",panel).stringValue = "名称を変更"
        try button("接続を確認して保存",panel).performClick(nil)
        try wait("blank-key save") { try button("接続を確認して保存",panel).isEnabled && saved == 2 }
        try check(store.value?.appName == "名称を変更" && store.value?.authKey == CampaignRelayQACredentials.key,"blank secret preserves stored key")
        requests.blockProbe(true); try field("メールのアプリ名",panel).stringValue = "保存しない名称"
        try button("接続を確認して保存",panel).performClick(nil)
        try wait("blocked public route") { try button("接続を確認して保存",panel).isEnabled && text(panel).contains("認証できません") }
        try check(store.value?.appName == "名称を変更" && saved == 2,"failed public probe does not save UI settings")
        requests.blockProbe(false); requests.pauseHealth(true)
        try button("接続を確認して保存",panel).performClick(nil)
        try wait("pending request") { requests.waiting }
        try check(try !button("閉じる",panel).isEnabled && !field("受信窓口の公開URL",panel).isEnabled && !ui.confirmDiscard(),"busy connection gates editing and app close")
        try button("接続確認を中止",panel).performClick(nil); requests.release()
        try wait("cancelled") { try button("接続を確認して保存",panel).isEnabled && text(panel).contains("接続確認を中止しました") }
        try check(store.value?.appName == "名称を変更" && saved == 2,"cancelled connection does not save")
        try button("接続キーを削除…",panel).performClick(nil); try wait("remove confirmation") { panel.attachedSheet != nil }
        try button("キャンセル",panel.attachedSheet!).performClick(nil); try wait("cancel removal") { panel.attachedSheet == nil }
        try check(store.value != nil,"cancelled removal retains key")
        let binding = try CampaignRelayBinding.load(db:db)
        try button("接続キーを削除…",panel).performClick(nil); try wait("remove confirmation again") { panel.attachedSheet != nil }
        try button("接続キーを削除",panel.attachedSheet!).performClick(nil); try wait("removed") { panel.attachedSheet == nil && store.value == nil }
        try check(saved == 3 && (try CampaignRelayBinding.load(db:db)) == binding,"key removal preserves receiver binding and cursor")
        try check(try !button("接続キーを削除…",panel).isEnabled && field("受信窓口の接続キー",panel).stringValue.isEmpty,"removed key UI state")
        try button("閉じる",panel).performClick(nil); try wait("closed") { host.attachedSheet == nil }
        let user = try db.get("Users",key:["id":.text(identity.id)])!
        _ = try db.update(user,changes:["role":.text("user")],actor:identity.id)
        do { _ = try CRMCampaignRelaySettingsWindow(service:service,store:store); throw NativeDBError.message("FAIL nonadmin UI opened") }
        catch { guard !error.localizedDescription.contains("FAIL nonadmin") else { throw error }; checks += 1 }
        print("CampaignRelaySettingsUITests: \(checks) checks passed; offscreen production controls, real loopback receiver, fake credential store")
    }
}
