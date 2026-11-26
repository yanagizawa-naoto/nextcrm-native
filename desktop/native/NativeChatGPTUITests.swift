import AppKit
#if CHATGPT_INTEGRATED_TEST
@testable import DistributionLoginCore
#endif

private final class ChatGPTUIVault: NativeChatGPTCredentialStore, @unchecked Sendable {
    private var data: Data; private let lock = NSLock()
    init(_ value: NativeChatGPTEnvelope) throws { data = try JSONEncoder().encode(value) }
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func replace(_ value: Data, expected: Data?) throws { lock.lock(); defer { lock.unlock() }; guard data == expected else { throw NativeChatGPTError.invalid("CAS") }; data = value }
}
private actor ChatGPTUIProvider {
    var calls = 0, fail = false, cancelled = false
    func setFailure(_ value: Bool) { fail = value }
    func request(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard req.url == NativeChatGPTInference.modelsEndpoint else { throw NativeChatGPTError.invalid("unexpected network") }
        return (Data("{\"models\":[{\"slug\":\"model-b\",\"display_name\":\"日本語モデル\",\"visibility\":\"list\"}]}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func stream(_ req: URLRequest) async throws -> String {
        calls += 1
        if fail { throw NativeChatGPTError(message: "ChatGPTプランの利用上限です。", status: 429, code: "subscription_sharing_usage_limit_exceeded") }
        return "日本語の合成要約です。"
    }
}

@main @MainActor enum NativeChatGPTUITests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw NativeChatGPTError.invalid("FAIL: "+label) }; checks += 1 }
    static func reject(_ name: String, _ work: () async throws -> Void) async throws { do { try await work() } catch { checks += 1; return }; throw NativeChatGPTError.invalid("ACCEPTED: "+name) }
    static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    static func button(_ title: String, _ controller: NativeChatGPTSettingsWindow) throws -> NSButton {
        guard let b = views(controller.window.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else { throw NativeChatGPTError.invalid("missing "+title) }; return b
    }
    static func ready(_ controller: NativeChatGPTSettingsWindow) async throws {
        for _ in 0..<200 { if controller.confirmDiscard() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw NativeChatGPTError.invalid("UI task did not drain")
    }
    static func envelope() -> NativeChatGPTEnvelope {
        let identity = NativeChatGPTIdentity(issuer: NativeChatGPTOAuth.issuer, subject: "ui-subject", clientID: "oaiapp_ui", email: "ui@example.invalid", emailVerified: true)
        let tokens = NativeChatGPTTokens(access: "synthetic-access", refresh: nil, idToken: "synthetic-id-token", scopes: ["chatgpt.tokens.use.direct", "resource.invoke"], expiresAt: Date().addingTimeInterval(3600), earliestRefreshAt: nil)
        let account = NativeChatGPTRegistration(id: "00000000-0000-0000-0000-000000000001", identity: identity, tokens: tokens, model: "model-b", backgroundConsent: false, welcomed: true)
        return .init(accounts: [account], selected: account.id, useChatGPT: true)
    }
    static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let provider = ChatGPTUIProvider(), vault = try ChatGPTUIVault(envelope())
        let session = NativeChatGPTSession(store: vault, authorize: {}, request: { try await provider.request($0) }, stream: { try await provider.stream($0) })
        let controller = NativeChatGPTSettingsWindow(session: session, openBrowser: { _ in throw NativeChatGPTError.invalid("test must not open browser") })
        defer { controller.window.orderOut(nil) }
        controller.start(); try await ready(controller); controller.window.contentView!.layoutSubtreeIfNeeded()
        try check(controller.window.title == "ChatGPT接続と文章作成", "Japanese title")
        try check(controller.window.contentView is NSScrollView, "bounded scrollable settings")
        let viewport = controller.window.contentView as! NSScrollView, document = (controller.window.contentView as! NSScrollView).documentView!
        try check(controller.window.contentView!.bounds.height == 740 && document.bounds.height >= viewport.contentView.bounds.height && viewport.hasVerticalScroller, "740pt panel scrolls instead of clipping")
        for control in views(document).compactMap({ $0 as? NSControl }) {
            let frame = control.convert(control.bounds, to: document)
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.maxX <= document.bounds.width+1 && frame.minY >= -1 && frame.maxY <= document.bounds.height+1, "control inside scroll document")
        }
        if CommandLine.arguments.count > 3 {
            let target = URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("chatgpt-settings.png")
            if let rep = controller.window.contentView!.bitmapImageRepForCachingDisplay(in: controller.window.contentView!.bounds) {
                controller.window.contentView!.cacheDisplay(in: controller.window.contentView!.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: target)
            }
        }
        let all = views(controller.window.contentView!)
        for label in ["Continue with ChatGPT", "選択したアカウントに再接続", "サインアウト", "ChatGPTプランを使用", "APIキー方式を使用", "利用状況を管理 ↗", "要約する", "文章を作成", "処理を中止", "閉じる"] { try check(try button(label, controller).isEnabled, "enabled action "+label) }
        guard let input = all.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "ChatGPTへの文章または指示" }),
              let output = all.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "ChatGPTの生成結果" }) else { throw NativeChatGPTError.invalid("text controls") }
        try check(input.isEditable && !output.isEditable, "input and readonly result")
        try check(all.compactMap { $0 as? NSPopUpButton }.contains { $0.titleOfSelectedItem == "日本語モデル" }, "saved account model shown")
        try check(all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Using ChatGPT plan") }, "plan usage visible")
        input.string = "営業記録の合成文章です。"
        try button("要約する", controller).performClick(nil); try await ready(controller)
        let summaryCalls = await provider.calls
        try check(output.string == "日本語の合成要約です。" && summaryCalls == 1, "actual summary button routes through signed-in session")
        await provider.setFailure(true)
        try button("文章を作成", controller).performClick(nil); try await ready(controller)
        try check(output.string.isEmpty && all.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("利用上限") }, "usage failure is visible without stale output")
        try button("APIキー方式を使用", controller).performClick(nil); try await ready(controller)
        let before = await provider.calls
        try button("要約する", controller).performClick(nil); try await ready(controller)
        try check(await provider.calls == before, "settings tool does not secretly use different billing path")
        await controller.cancelAndDrain(); try check(input.string.isEmpty && output.string.isEmpty, "close erases transient text")
        await session.stopAndDrain()
        #if CHATGPT_INTEGRATED_TEST
        let hub = NativeConnectionsWindow(mailAllowed: true, calendarAllowed: true, aiAllowed: true)
        hub.window.contentView!.layoutSubtreeIfNeeded()
        for control in views(hub.window.contentView!).compactMap({ $0 as? NSControl }) {
            let frame = control.convert(control.bounds, to: hub.window.contentView!)
            try check(frame.width > 0 && frame.height > 0 && frame.minX >= -1 && frame.maxX <= hub.window.contentView!.bounds.width+1 && frame.minY >= -1 && frame.maxY <= hub.window.contentView!.bounds.height+1, "connection hub control in bounds")
        }
        if CommandLine.arguments.count > 3 {
            // An unordered AppKit window has no compositor background. Pin the
            // drawing appearance and supply that background for this test image.
            let view = hub.window.contentView!, appearance = NSAppearance(named: .aqua)!
            hub.window.appearance = appearance; view.appearance = appearance
            var png: Data?
            appearance.performAsCurrentDrawingAppearance {
                hub.window.backgroundColor = .windowBackgroundColor
                view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                view.layoutSubtreeIfNeeded(); view.needsDisplay = true; view.displayIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    png = rep.representation(using: .png, properties: [:])
                }
            }
            guard let png else { throw NativeChatGPTError.invalid("connection hub test image") }
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("connection-hub.png"))
        }
        hub.window.orderOut(nil)
        try await campaign()
        #endif
        print("NativeChatGPT UI and routing: \(checks) checks passed")
    }
    #if CHATGPT_INTEGRATED_TEST
    private final class APIStore: NativeAISecretStore {
        func load(id: String, interactive: Bool) throws -> Data? { nil }
        func save(id: String, data: Data) throws { throw NativeDBError.conflict }
        func remove(id: String) throws { throw NativeDBError.conflict }
    }
    static func campaign() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("NextCRM-ChatGPT-Routing-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db: db, identity: try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma")))
        let keys = NativeAIKeys(service: service, store: APIStore(), environment: .init(lookup: { _ in "synthetic-api-key" }))
        let vault = try ChatGPTUIVault(envelope()), provider = ChatGPTUIProvider()
        var apiCalls = 0, chatCalls = 0
        let session = NativeChatGPTSession(store: vault, authorize: { try service.authenticated() }, request: { try await provider.request($0) }, stream: { _ in chatCalls += 1; return "{\"subject\":\"合成の件名\",\"html\":\"<p>日本語の本文</p>\"}" })
        var ai = CampaignAIService(keys: keys, chatGPT: session); ai.generate = { _,_ in apiCalls += 1; return .init(subject: "API", html: "<p>API</p>") }
        let generated = try await ai.create(prompt: "案内メール", context: .template(nil))
        try check(generated.draft.subject == "合成の件名" && generated.chatGPTReceipt != nil && chatCalls == 1 && apiCalls == 0, "existing campaign flow uses selected ChatGPT session")
        try await ai.validate(context: .template(nil), result: generated); checks += 1
        try await session.useAPIKey()
        try await reject("stale campaign choice rejected") { try await ai.validate(context: .template(nil), result: generated) }
        let apiResult = try await ai.create(prompt: "案内メール", context: .template(nil))
        try check(apiResult.chatGPTReceipt == nil && apiCalls == 1 && chatCalls == 1, "explicit API selection preserves fallback")
        try await session.useChatGPTPlan()
        let failing = NativeChatGPTSession(store: vault, authorize: { try service.authenticated() }, request: { try await provider.request($0) }, stream: { _ in throw NativeChatGPTError(message: "limit", status: 429) })
        var denied = CampaignAIService(keys: keys, chatGPT: failing); denied.generate = { _,_ in apiCalls += 1; return .init(subject: "wrong", html: "wrong") }
        try await reject("ChatGPT error does not fall through to API") { _ = try await denied.create(prompt: "案内メール", context: .template(nil)) }
        try check(apiCalls == 1, "API billing unchanged on ChatGPT failure")
        await session.stopAndDrain(); await failing.stopAndDrain()
    }
    #endif
}
