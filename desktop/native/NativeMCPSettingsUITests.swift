import AppKit

private final class MCPUISecrets: NativeMCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var counts = (load: 0, save: 0, remove: 0)
    func load(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; counts.load += 1; return values[id] }
    func save(id: String, data: Data) throws { lock.lock(); defer { lock.unlock() }; counts.save += 1; guard values[id] == nil else { throw NativeMCPSettingsError.credentials }; values[id] = data }
    func remove(id: String) throws { lock.lock(); defer { lock.unlock() }; counts.remove += 1; values.removeValue(forKey: id) }
    var accesses: Int { lock.lock(); defer { lock.unlock() }; return counts.load + counts.save + counts.remove }
    func erase(_ id: String) { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}

@main enum NativeMCPSettingsUITests {
    static var checks = 0, last = "initial"
    static let resultLabel = "MCP設定の操作結果", portLabel = "MCPのポート番号", maximumLabel = "MCPの最大同時接続数", enabledTitle = "このMacからのMCP接続を有効にする"
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        last = label; guard try value() else { throw NativeDBError.message("FAIL " + label) }; checks += 1
    }
    static func reject(_ label: String, _ action: () throws -> Void) throws { var rejected = false; do { try action() } catch { rejected = true }; try check(rejected,label) }
    static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    static func field(_ label: String, _ window: NSWindow) throws -> NSTextField {
        guard let value = views(window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel() == label}) else { throw NativeDBError.message("field missing") }; return value
    }
    static func button(_ title: String, _ window: NSWindow) throws -> NSButton {
        guard let value = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title}) else { throw NativeDBError.message("button missing") }; return value
    }
    static func click(_ title: String, _ window: NSWindow) throws { let b = try button(title,window); try check(b.isEnabled,title+" enabled"); b.sendAction(b.action,to:b.target) }
    static func toggle(_ title: String, _ on: Bool, _ window: NSWindow) throws { let b = try button(title,window); b.state = on ? .on : .off; b.sendAction(b.action,to:b.target) }
    static func wait(_ label: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        last = label; throw NativeDBError.message("timeout")
    }
    static func ready(_ window: NSWindow) throws { try wait("ready") { try button("再読み込み",window).isEnabled } }
    static func async<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T,Error>?
        Task { @MainActor in do { result = .success(try await body()) } catch { result = .failure(error) } }
        try wait("async") { result != nil }; return try result!.get()
    }
    static func answerModal(_ title: String, action: () throws -> Void) throws {
        var found = false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            guard let modal = NSApp.modalWindow, let b = try? button(title,modal) else { NSApp.stopModal(withCode:.abort); return }
            found = true; b.performClick(nil)
        }
        try action(); try check(found,"actual dirty modal " + title)
    }
    static func layout(_ window: NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        let bounds = window.contentView!.bounds
        for item in views(window.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor}) {
            let rect = item.convert(item.bounds,to:window.contentView)
            try check(rect.width > 0 && rect.height > 0 && rect.minX >= -1 && rect.maxX <= bounds.width+1 && rect.minY >= -1 && rect.maxY <= bounds.height+1,"control fits " + (item.accessibilityLabel() ?? "label"))
        }
    }
    static func main() {
        do {
            let resources = URL(fileURLWithPath:CommandLine.arguments[1])
            if CommandLine.arguments.contains("--sdk-runtime") { try sdkRuntime(resources) }
            else if CommandLine.arguments.contains("--keychain") { try keychain() }
            else if CommandLine.arguments.count > 4, CommandLine.arguments[2] == "--qa-process" {
                let store = try NativeMCPQAServices(root:URL(fileURLWithPath:CommandLine.arguments[3])), id = CommandLine.arguments[4], bytes = Data(repeating:0x33,count:32)
                if CommandLine.arguments.count > 5 {
                    try check(try store.load(id:id) == bytes,"independent process reload")
                    try store.remove(id:id); try check(try store.load(id:id) == nil,"independent process cleanup")
                } else { try store.save(id:id,data:bytes); try check(true,"independent process save") }
                print("Native MCP QA process: \(checks) checks passed")
            } else { try run(resources) }
        } catch { let e = error as NSError; fputs("MCP settings verification failed after \(last): \(e.domain) code \(e.code)\n",stderr); exit(1) }
    }
    static func sdkRuntime(_ resources: URL) throws {
        let f = try NativeMCPAccountsFixture(resources:resources); defer { f.close() }
        let secrets = MCPUISecrets(), settings = NativeMCPSettingsStore(service:f.admin,secretStore:secrets)
        let probe = try NativeMCPHTTPServer { _ in .init(status:204) }
        let port = try async { try await probe.start().port! }; _ = try async { await probe.stop() }
        _ = try settings.save(expected:settings.snapshot(),enabled:true,port:port,maximumConnections:2)
        let runtime = NativeMCPRuntime(db:f.db,catalogURL:resources.appendingPathComponent("MCPToolCatalog.json"),secretStore:secrets,enrichmentStore:{_ in NativeAIQAServices()},enrichmentEnvironment:NativeAIEnvironment{_ in nil})
        func emit(_ value:[String:Any]) throws { print(String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)); fflush(stdout) }
        let state = try async { try await runtime.start() }
        try emit(["ready":state.endpoint!,"maximum":2,"tools":123,"tool":"crm_list_accounts","bearer":f.header("00000000-0000-4000-8000-000000000001")])
        while let line = readLine() {
            if line == "quit" { _ = try async { await runtime.stop() }; try emit(["stopped":true]); return }
            let value = try async { await runtime.snapshot() }; try emit(["connections":value.connections,"retained":value.retainedPeers,"rejected":value.rejected])
        }
        _ = try async { await runtime.stop() }
    }
    static func keychain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MCPKeychain-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = KeychainNativeMCPSecrets(databaseURL:root.appendingPathComponent("crm.sqlite"))
        let other = KeychainNativeMCPSecrets(databaseURL:root.appendingPathComponent("other.sqlite"))
        let id = UUID().uuidString.lowercased(), data = Data(repeating:0x5a,count:32)
        // Only this generated identity in this unique database namespace is
        // ever deleted; never enumerate or alter the user's existing items.
        defer { try? store.remove(id:id) }
        try check(try store.load(id:id) == nil,"new identity absent")
        try store.save(id:id,data:data)
        try check(try store.load(id:id) == data,"actual Keychain save/load")
        try reject("immutable duplicate rejected") { try store.save(id:id,data:Data(repeating:0x7a,count:32)) }
        try check(try store.load(id:id) == data,"duplicate retained original")
        try check(try other.load(id:id) == nil,"database namespace isolation")
        try reject("invalid ID rejected") { try store.save(id:"not-a-uuid",data:data) }
        try reject("invalid length rejected") { try store.save(id:UUID().uuidString.lowercased(),data:Data([1])) }
        try store.remove(id:id); try check(try store.load(id:id) == nil,"created key removed")
        try store.remove(id:id); try check(true,"idempotent removal")
        print("Native MCP real Keychain: \(checks) checks passed; unique temporary database namespace, one synthetic item, removed")
    }
    static func qaStore(_ root: URL) throws {
        let missing = root.appendingPathComponent("missing-marker")
        try FileManager.default.createDirectory(at:missing,withIntermediateDirectories:true)
        try reject("QA marker required") { _ = try NativeMCPQAServices(root:missing) }
        let normal = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NextCRMNative")
        try reject("normal app root rejected") { _ = try NativeMCPQAServices(root:normal) }
        let qa = root.appendingPathComponent("qa"); try FileManager.default.createDirectory(at:qa,withIntermediateDirectories:true)
        try Data("NextCRM isolated mail QA\n".utf8).write(to:qa.appendingPathComponent(".native-mail-test"))
        let store = try NativeMCPQAServices(root:qa), id = UUID().uuidString.lowercased(), key = Data(repeating:0x33,count:32)
        try store.save(id:id,data:key)
        try check(try NativeMCPQAServices(root:qa).load(id:id) == key,"QA restart preserves key")
        let permissions = try FileManager.default.attributesOfItem(atPath:qa.appendingPathComponent(".mcp-qa-secrets.json").path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600,"QA fixture private permissions")
        try reject("QA immutable reference") { try store.save(id:id,data:key) }
        try store.remove(id:id)
        try check(try NativeMCPQAServices(root:qa).load(id:id) == nil,"QA deletion persists")
    }
    static func run(_ resources: URL) throws {
        try check(Thread.isMainThread,"AppKit main thread")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let f = try NativeMCPAccountsFixture(resources:resources)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; f.close() }
        try qaStore(f.root)
        let secrets = MCPUISecrets(), settings = NativeMCPSettingsStore(service:f.admin,secretStore:secrets)
        let runtime = NativeMCPRuntime(db:f.db,catalogURL:resources.appendingPathComponent("MCPToolCatalog.json"),secretStore:secrets,enrichmentStore:{_ in NativeAIQAServices()},enrichmentEnvironment:NativeAIEnvironment{_ in nil})
        defer { _ = try? async { await runtime.stop() } }
        let disabled = try async { try await runtime.start() }
        try check(disabled.state == .disabled,"initial runtime disabled")
        let ui = NativeMCPSettingsWindow(settings:settings,runtime:runtime), window = ui.window
        ui.start(); try ready(window); try layout(window)
        try check(window.title == "MCP接続の設定","Japanese title")
        try check(try field(portLabel,window).stringValue == "53180" && field(maximumLabel,window).stringValue == "4","initial form")
        try check(secrets.accesses == 0,"initial UI no Keychain")
        try check(try !button("接続先をコピー",window).isEnabled && !button("署名キーを再作成する",window).isEnabled,"disabled controls")
        try check(ui.confirmDiscard(),"clean close allowed")
        try field(maximumLabel,window).stringValue = "1"; try click("保存して適用",window)
        try check(try field(resultLabel,window).stringValue.contains("2〜32") && settings.snapshot().revision == 0,"single SDK slot rejected by UI")
        try field(maximumLabel,window).stringValue = "4"
        try field(portLabel,window).stringValue = "0"; try click("保存して適用",window)
        try check(try field(resultLabel,window).stringValue.contains("1024") && settings.snapshot().revision == 0,"invalid form not saved")
        try answerModal("編集を続ける") { try click("再読み込み",window) }
        try check(try field(portLabel,window).stringValue == "0","dirty reload cancellation")
        try answerModal("破棄する") { try click("再読み込み",window) }; try ready(window)
        try check(try field(portLabel,window).stringValue == "53180","dirty reload discards")
        let probe = try NativeMCPHTTPServer { _ in .init(status:204) }
        let port = try async { try await probe.start().port! }; _ = try async { await probe.stop() }
        try field(portLabel,window).stringValue = String(port); try toggle(enabledTitle,true,window)
        try click("保存して適用",window)
        try check(try !button("閉じる",window).isEnabled && !ui.confirmDiscard(),"busy close rejected")
        try ready(window)
        let initial = try settings.snapshot()
        try check(initial.enabled && initial.port == port,"enabled state saved")
        try check(try field("MCPの接続先",window).stringValue == initial.endpoint && button("接続先をコピー",window).isEnabled,"running endpoint displayed")
        try check(try field("MCPの接続状態",window).stringValue.contains("接続受付中"),"running status")
        try layout(window)
        let stale = NativeMCPSettingsWindow(settings:settings,runtime:runtime); stale.start(); try ready(stale.window)
        try field(maximumLabel,window).stringValue = "3"; try click("保存して適用",window); try ready(window)
        let newest = try settings.snapshot()
        try field(maximumLabel,stale.window).stringValue = "7"; try click("保存して適用",stale.window); try ready(stale.window)
        try check(try settings.snapshot() == newest && !field(resultLabel,stale.window).stringValue.isEmpty,"stale UI revision conflict")
        try answerModal("破棄する") { try click("再読み込み",stale.window) }; try ready(stale.window)
        try check(try field(maximumLabel,stale.window).stringValue == "3","reload conflict recovery")
        let busyPort = try NativeMCPHTTPServer { _ in .init(status:204) }
        let occupied = try async { try await busyPort.start().port! }
        defer { _ = try? async { await busyPort.stop() } }
        try field(portLabel,window).stringValue = String(occupied); try click("保存して適用",window); try ready(window)
        try check(try settings.snapshot().port == occupied && settings.snapshot().enabled,"failed startup keeps saved config")
        try check(try field(resultLabel,window).stringValue.contains("設定は保存しました") && field("MCPの接続先",window).stringValue.isEmpty,"failed startup honest UI")
        try check(try field(resultLabel,window).stringValue.contains("指定したポートは別のアプリ"),"Japanese port conflict reason retained")
        try check(ui.confirmDiscard(),"failed startup setting is clean")
        _ = try async { await busyPort.stop() }
        try click("保存して適用",window); try ready(window)
        try check(try field("MCPの接続先",window).stringValue.contains(":\(occupied)/"),"fixed port conflict recovery")
        let beforeLost = try settings.snapshot(), previousID = beforeLost.credentialID!
        secrets.erase(previousID)
        try click("保存して適用",window); try ready(window)
        try check(try field(resultLabel,window).stringValue.contains("署名キー"),"missing secret visible")
        try toggle("署名キーを再作成する",true,window); try click("保存して適用",window); try ready(window)
        try check(try settings.snapshot().credentialID != previousID && field("MCPの接続状態",window).stringValue.contains("接続受付中"),"rotation recovers missing key")
        try toggle("署名キーを再作成する",true,window); try toggle(enabledTitle,false,window)
        try check(try button("署名キーを再作成する",window).state == .off && !button("署名キーを再作成する",window).isEnabled,"disable clears rotation")
        let accesses = secrets.accesses
        try click("保存して適用",window); try ready(window)
        try check(try !settings.snapshot().enabled && field("MCPの接続先",window).stringValue.isEmpty,"disable stops endpoint")
        try check(secrets.accesses == accesses,"disable no Keychain")
        let beforeDemotion = try settings.snapshot()
        try f.change("Users",id:f.admin.identity.id,values:["role":.text("user")])
        try toggle(enabledTitle,true,window); try click("保存して適用",window); try ready(window)
        try check(try NativeMCPSettingsStore.read(db:f.db) == beforeDemotion && !field(resultLabel,window).stringValue.isEmpty,"demoted admin cannot save")
        try answerModal("破棄する") { try click("再読み込み",window) }; try ready(window)
        try check(try !button("保存して適用",window).isEnabled && !field(portLabel,window).isEnabled,"permission loss disables editing")
        try f.change("Users",id:f.admin.identity.id,values:["role":.text("admin")])
        try click("再読み込み",window); try ready(window)
        try check(try button("保存して適用",window).isEnabled,"restored admin reload")
        let host = NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        host.beginSheet(window)
        try field(portLabel,window).stringValue = String(port)
        try answerModal("編集を続ける") { try click("閉じる",window) }
        try check(window.sheetParent === host,"dirty close canceled")
        try answerModal("破棄する") { try click("閉じる",window) }
        try wait("sheet closed") { window.sheetParent == nil }
        try check(try settings.snapshot() == beforeDemotion,"discard close preserves settings")
        try layout(stale.window)
        print("Native MCP settings UI/QA: \(checks) checks passed; actual AppKit panel and isolated SQLite/runtime, clipboard untouched")
    }
}
