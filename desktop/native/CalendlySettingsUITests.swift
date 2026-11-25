import AppKit

@main enum CalendlySettingsUITests {
    typealias Fixture = CalendlySubscriptionTests.Fixture
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("CalendlyUI FAIL: "+label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    static func button(_ title: String,_ window: NSWindow) throws -> NSButton { guard let b = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title && !$0.isHiddenOrHasHiddenAncestor}) else { throw NativeDBError.message("Missing button: "+title) }; return b }
    static func click(_ title: String,_ window: NSWindow) throws { let b = try button(title,window); try check(b.isEnabled,"enabled action: "+title); _ = b.sendAction(b.action,to:b.target) }
    static func field(_ title: String,_ window: NSWindow) throws -> NSTextField { guard let f = views(window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel() == title}) else { throw NativeDBError.message("Missing field: "+title) }; return f }
    static func wait(_ label: String,_ body: () throws -> Bool) throws { let deadline = Date().addingTimeInterval(15); while Date() < deadline { if try body() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }; throw NativeDBError.message("UI timeout: "+label) }
    static func ready(_ window: NSWindow) throws { try wait("settings ready"){try button("再読み込み",window).isEnabled} }
    static func layout(_ window: NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        for view in views(window.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor}) {
            let frame = view.convert(view.bounds,to:window.contentView), bounds = window.contentView!.bounds
            try check(frame.minX >= -1 && frame.minY >= -1 && frame.maxX <= bounds.width+1 && frame.maxY <= bounds.height+1,"control fits panel: "+(view.accessibilityLabel() ?? ""))
        }
    }
    static func advanced(_ title: String,_ window: NSWindow) throws {
        let popup = views(window.contentView!).compactMap{$0 as? NSPopUpButton}.first!
        guard let item = popup.menu?.items.first(where:{$0.title == title}), let action = item.action else { throw NativeDBError.conflict }
        try check(item.isEnabled,"enabled recovery action: "+title); NSApp.sendAction(action,to:item.target,from:popup)
    }
    final class Transport {
        private let lock = NSLock(); private var countValue = 0, failed = false
        var count: Int { lock.lock(); defer{lock.unlock()}; return countValue }
        func fail(_ value: Bool) { lock.lock(); defer{lock.unlock()}; failed = value }
        private func snapshot() -> Bool { lock.lock(); defer{lock.unlock()}; countValue += 1; return failed }
        func request(_ req: URLRequest) async throws -> (Data,HTTPURLResponse) { if snapshot() { throw URLError(.networkConnectionLost) }; return try await CalendlyRelayClient.network(req) }
    }
    static func panel(_ f: Fixture,_ transport: Transport) throws -> CalendlySettingsWindow {
        let controller = try CalendlySettingsWindow(service:f.service,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:transport.request)
        controller.window.setFrameOrigin(.init(x:-10000,y:-10000)); return controller
    }
    static func save(_ f: Fixture,_ controller: CalendlySettingsWindow) throws {
        let window = controller.window
        try field("受信URL",window).stringValue = f.server.url.absoluteString
        try field("接続キー",window).stringValue = CalendlyRelayTests.authKey
        try field("APIトークン",window).stringValue = "fixture-api-token"
        try field("署名キー",window).stringValue = "native-calendly-fixture-key"
        controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        try click("接続設定を保存",window); try ready(window)
        try check(try f.state().credentialID != nil && field("APIトークン",window).stringValue.isEmpty && field("接続キー",window).stringValue.isEmpty && field("署名キー",window).stringValue.isEmpty,"saved settings clear every secret entry")
    }
    static func lifecycle(_ resources: URL) throws {
        let f = try Fixture(resources), transport = Transport()
        let runtime = CalendlyRuntime(db:f.db,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:transport.request,interval:0.25); defer{runtime.stop()}
        runtime.resume(); try wait("empty runtime settles"){!runtime.isScanning && !runtime.isRunning}
        try check(runtime.nextScan == nil && transport.count == 0,"no settings means no polling timer or network")
        let panel = try panel(f,transport), window = panel.window; panel.onChanged = {runtime.resume()}
        try check(window.title == "Calendlyの予約連携" && (try field("APIトークン",window)) is NSSecureTextField,"Japanese panel uses secure token field")
        try layout(window); try click("接続設定を保存",window); try ready(window)
        try check(try f.state().credentialID == nil && !field("Calendly設定の結果",window).stringValue.isEmpty,"missing credentials show validation without publication")
        try save(f,panel); try check(panel.confirmDiscard(),"saved settings have no unsaved secrets")
        let beforeToken = try f.state().credentialID
        try field("APIトークン",window).stringValue = "fixture-api-token"; try field("受信URL",window).stringValue += "/unsaved"
        panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        try check(try !button("APIトークンだけ更新",window).isEnabled,"token-only update cannot discard unrelated unsaved form edits")
        try field("受信URL",window).stringValue = f.server.url.absoluteString; panel.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        try click("APIトークンだけ更新",window); try ready(window)
        try check(try f.state().credentialID != beforeToken && field("APIトークン",window).stringValue.isEmpty && panel.confirmDiscard(),"token-only UI update publishes new credential reference and clears input")
        try click("通知を登録",window); try ready(window)
        try wait("subscription and initial sync finish"){try f.state().registration != nil && f.state().operation == nil && CalendlyJobs.last(db:f.db,event:CalendlyJobs.sync)?.status == "done"}
        try wait("registration visible"){try field("Calendlyの登録状況",window).stringValue.contains("登録済み")}
        try layout(window); try check(f.provider.createCount == 1,"UI creates exactly one provider subscription")
        _ = try f.server.command(["action":"seed","count":1])
        try wait("periodic import runs"){try f.db.page("crm_Activities",fields:[]).total == 1 && CalendlyJobs.last(db:f.db,event:CalendlyJobs.sync)?.status == "done"}
        try wait("periodic timer armed"){runtime.nextScan != nil}; runtime.stop(); try wait("runtime stopped"){!runtime.isRunning && !runtime.isScanning}
        let stopped = transport.count; RunLoop.current.run(until:Date().addingTimeInterval(0.4))
        try check(transport.count == stopped && runtime.nextScan == nil,"stop cancels periodic work")
        let queued = try f.service.requestCalendlyJob(CalendlyJobs.sync); RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        try check(try f.db.job(id:queued)?.status == "pending" && transport.count == stopped,"stopped runner leaves request durable")
        let restarted = CalendlyRuntime(db:f.db,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:transport.request,interval:60); defer{restarted.stop()}; panel.onChanged = {restarted.resume()}; restarted.resume()
        try wait("restart processes queued import"){try f.db.job(id:queued)?.status == "done"}
        try check(try f.db.page("crm_Activities",fields:[]).total == 1,"runtime restart preserves single CRM meeting")
        transport.fail(true); try click("今すぐ取り込む",window)
        try wait("retry status shown"){try field("Calendlyの取込状況",window).stringValue.contains("再試行待ち")}
        let retry = try CalendlyJobs.last(db:f.db,event:CalendlyJobs.sync)!; transport.fail(false); try click("今すぐ取り込む",window)
        try wait("manual retry completes"){try f.db.job(id:retry.id)?.status == "done"}
        try check(try f.db.job(id:retry.id)?.attempts == 2,"Japanese retry action preserves same durable job")
        try click("通知登録を解除…",window); try wait("unsubscribe sheet"){window.attachedSheet != nil}; try click("キャンセル",window.attachedSheet!)
        try wait("cancelled sheet closes"){window.attachedSheet == nil}; try check(try f.state().registration != nil,"unsubscribe cancellation leaves active registration")
        try click("通知登録を解除…",window); try wait("unsubscribe confirmation"){window.attachedSheet != nil}; try click("通知登録を解除",window.attachedSheet!)
        try wait("unsubscribe done"){try f.state().registration == nil && f.state().operation == nil}; try ready(window)
        try wait("no timer after unsubscribe"){restarted.nextScan == nil && !restarted.isScanning}
        try check(try f.db.page("crm_Activities",fields:[]).total == 1 && f.provider.rows.isEmpty,"unsubscribe preserves CRM meetings")
        try advanced("保存した接続設定を削除…",window); try wait("remove confirmation"){window.attachedSheet != nil}; try click("接続設定を削除",window.attachedSheet!)
        try wait("secret removal done"){try f.state().credentialID == nil}; try ready(window)
        try check(f.store.items.isEmpty,"settings removal clears isolated secret store")
    }
    static func review(_ resources: URL) throws {
        let f = try Fixture(resources), transport = Transport(); f.provider.loseBeforeCreate = true
        let runtime = CalendlyRuntime(db:f.db,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:transport.request); defer{runtime.stop()}
        let panel = try panel(f,transport), window = panel.window; panel.onChanged = {runtime.resume()}; try save(f,panel); try click("通知を登録",window)
        try wait("unknown request retry"){try CalendlyJobs.last(db:f.db,event:CalendlyJobs.subscription)?.status == "retry"}; try ready(window)
        try wait("resume button reflects completed attempt"){try button("処理を再開",window).isEnabled}
        try click("処理を再開",window); try wait("review held"){try CalendlyJobs.last(db:f.db,event:CalendlyJobs.subscription)?.status == "needs_review"}
        try wait("review status visible"){try field("Calendlyの登録状況",window).stringValue.contains("結果の確認が必要")}
        try check(f.provider.createCount == 1,"unknown UI operation does not automatically recreate")
        try advanced("未作成と確認して再試行…",window); try wait("review sheet"){window.attachedSheet != nil}; try click("確認内容を記録して再試行",window.attachedSheet!)
        try wait("blank review rejected"){try window.attachedSheet == nil && field("Calendly設定の結果",window).stringValue.contains("入力してください")}
        try check(try f.state().operation?.phase == .creating,"blank review cannot reset uncertain result")
        try advanced("未作成と確認して再試行…",window); try wait("second review sheet"){window.attachedSheet != nil}; try field("未作成の確認内容",window.attachedSheet!).stringValue = "Calendlyで通知登録がないことを確認しました。"
        try click("確認内容を記録して再試行",window.attachedSheet!)
        try wait("reviewed create finishes"){try f.state().registration != nil && f.state().operation == nil}
        try check(f.provider.createCount == 2 && f.provider.rows.count == 1,"explicit review permits one new registration")
        try ready(window); try layout(window)
    }
    static func immediateWake(_ resources: URL) throws {
        let f = try Fixture(resources), transport = Transport()
        let runtime = CalendlyRuntime(db:f.db,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:transport.request,interval:3600); defer{runtime.stop()}
        let panel = try panel(f,transport); panel.onChanged = {runtime.resume()}; try save(f,panel); try click("通知を登録",panel.window)
        try wait("initial import settled before wake test"){try f.state().registration != nil && !runtime.isRunning && !runtime.isScanning && CalendlyJobs.last(db:f.db,event:CalendlyJobs.sync)?.status == "done"}
        _ = try f.server.command(["action":"seed","count":1]); runtime.resume()
        try wait("wake ignores recent successful scan timestamp"){try f.db.page("crm_Activities",fields:[]).total == 1 && !runtime.isRunning && !runtime.isScanning}
        try check(try f.db.page("crm_Activities",fields:[]).total == 1,"application activation immediately fetches new notices inside periodic interval")
        let count = transport.count; RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        try check(count == transport.count,"job completion observer does not force an endless sync loop")
        runtime.stop(); _ = try f.server.command(["action":"seed","count":1])
        let restarted = CalendlyRuntime(db:f.db,store:f.store,allowLoopbackHTTP:true,apiRequest:f.provider.request,relayRequest:transport.request,interval:3600); defer{restarted.stop()}; restarted.resume()
        try wait("new runtime immediately fetches while no job was pending"){try f.db.page("crm_Activities",fields:[]).total == 2 && !restarted.isRunning && !restarted.isScanning}
        try check(try f.db.page("crm_Activities",fields:[]).total == 2,"startup fetches offline receipts even immediately after previous successful sync")
    }
    static func main() {
        do { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); let resources = URL(fileURLWithPath:CommandLine.arguments[1]); defer{NSApp.windows.forEach{$0.orderOut(nil)}}; try lifecycle(resources); try review(resources); try immediateWake(resources); print("CalendlySettingsUITests: \(checks) checks passed; actual AppKit controls, native jobs, restart, timer and review") }
        catch { FileHandle.standardError.write(Data("CalendlySettingsUITests: \(error)\n".utf8)); exit(1) }
    }
}
