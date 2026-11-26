import AppKit

@main enum GoogleCalendarSettingsUITests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool,_ label: String) throws { guard try condition() else { throw NativeDBError.message("GoogleCalendarSettingsUI FAIL: "+label) }; checks += 1 }
    static func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    static func button(_ title: String,_ window: NSWindow) throws -> NSButton { guard let result = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title && !$0.isHiddenOrHasHiddenAncestor}) else { throw NativeDBError.message("Missing button: "+title) }; return result }
    static func click(_ title: String,_ window: NSWindow) throws { let b = try button(title,window); try check(b.isEnabled,"enabled before action: "+title); _ = b.sendAction(b.action,to:b.target) }
    static func field(_ label: String,_ window: NSWindow) throws -> NSTextField { guard let result = views(window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel() == label}) else { throw NativeDBError.message("Missing field: "+label) }; return result }
    static func table(_ window: NSWindow) -> NSTableView { views(window.contentView!).compactMap{$0 as? NSTableView}.first! }
    static func wait(_ label: String,_ condition: () throws -> Bool) throws { let deadline = Date().addingTimeInterval(10); while Date() < deadline { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }; throw NativeDBError.message("UI timed out: "+label) }
    static func ready(_ window: NSWindow) throws { try wait("loaded"){try button("再読み込み",window).isEnabled} }
    static func text(_ window: NSWindow) -> String { views(window.contentView!).compactMap{$0 as? NSTextField}.map(\.stringValue).joined(separator:" ") }
    static func layout(_ window: NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        for control in views(window.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor && !($0 is NSTableView)}) {
            let rect = control.convert(control.bounds,to:window.contentView), bounds = window.contentView!.bounds
            try check(rect.minX >= -1 && rect.maxX <= bounds.width+1 && rect.minY >= -1 && rect.maxY <= bounds.height+1,"control fits panel: "+(control.accessibilityLabel() ?? ""))
        }
    }
    final class Store: GoogleCalendarSecretStore {
        var values: [String:Data] = [:], failRemove = false
        func load(id: String,interactive: Bool) throws -> Data? { values[id] }
        func save(id: String,data: Data) throws { guard values[id] == nil else { throw NativeDBError.conflict }; values[id] = data }
        func remove(id: String) throws { guard !failRemove else { throw NativeDBError.message("検証用：キーチェーンから削除できませんでした。") }; values.removeValue(forKey:id) }
    }
    final class Authorization {
        var scope: GoogleCalendarScope = .readonly, email = "rep@example.invalid", delay = false, fail = false
        var requests: [(GoogleCalendarScope,String?)] = []
        func run(_ client: GoogleCalendarClientSettings,_ scope: GoogleCalendarScope,_ hint: String?) async throws -> GoogleCalendarGrant {
            let choice = await MainActor.run { self.requests.append((scope,hint)); return (self.scope,self.email,self.delay,self.fail) }
            if choice.2 { try await Task.sleep(nanoseconds:30_000_000_000) }
            if choice.3 { throw GoogleCalendarHTTPError(status:403,reason:"insufficientpermissions") }
            return .init(accountEmail:choice.1,accessToken:"ui-fake-access-token",refreshToken:"ui-fake-refresh-token",expiresAt:Date(timeIntervalSince1970:1_900_000_000),grantedScopes:choice.0.requested)
        }
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("GoogleCalendarSettingsUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        try check(Thread.isMainThread,"main thread UI harness"); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GoogleCalendarUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = Store(), auth = Authorization()
        let controller = try GoogleCalendarSettingsWindow(service:service,store:store,authorize:auth.run), window = controller.window
        window.setFrameOrigin(.init(x:-10000,y:-10000)); try ready(window)
        let client = try field("GoogleクライアントID",window), secret = try field("Googleクライアントシークレット",window), message = try field("カレンダー接続の結果",window)
        try check(window.title == "Googleカレンダーの接続" && table(window).numberOfRows == 0 && secret is NSSecureTextField,"Japanese empty panel with secure input")
        try check(!(try button("Google にログイン…",window)).isEnabled,"unconfigured login is unavailable")
        _ = controller.perform(NSSelectorFromString("connectRead"))
        try check(auth.requests.isEmpty && !message.stringValue.isEmpty,"missing client prevents authorization")
        try click("詳細設定（開発者向け）…",window)
        client.stringValue = "ui-desktop.apps.googleusercontent.com"; secret.stringValue = "ui-fake-client-secret"
        try click("アプリ設定を保存",window)
        try check(try service.googleCalendarClientReference()?.clientID == client.stringValue && secret.stringValue.isEmpty && controller.confirmDiscard(),"settings published and secret input cleared")
        var connected = 0; controller.onConnected = { connected += 1 }
        try click("予定の編集も許可してログイン…",window); try ready(window)
        let first = try service.googleCalendarConnections().rows[0]
        try check(auth.requests.last?.0 == .readwrite && first["scopeLevel"] == .text("readonly") && table(window).numberOfRows == 1 && connected == 1,"requested write stores actual readonly grant and refreshes list")
        try check(message.stringValue.contains("読み取り") && !text(window).contains("ui-fake-"),"result shows actual permission without secrets")
        table(window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        auth.scope = .readwrite
        try click("選択した接続を認証し直す…",window); try ready(window)
        var selected = try service.googleCalendarConnections().rows[0]
        try check(auth.requests.last?.1 == "rep@example.invalid" && selected["id"] == first["id"] && selected["scopeLevel"] == .text("readwrite"),"reauth keeps account identity and accepts actual grant")
        auth.delay = true
        try click("選択した接続を認証し直す…",window)
        try wait("authorization pending"){auth.requests.count == 3}
        try check(!controller.confirmDiscard() && !table(window).isEnabled && !(try button("アプリ設定を保存",window)).isEnabled && (try button("認証を中止",window)).isEnabled,"busy state protects edits and permits cancellation")
        try click("認証を中止",window); try ready(window)
        try check(try service.googleCalendarConnection(first["id"].string).revision == selected.revision && message.stringValue.contains("中止"),"cancel preserves prior connection")
        auth.delay = false; auth.fail = true
        try click("選択した接続を認証し直す…",window); try ready(window)
        try check(message.stringValue.contains("認証が無効") && connected == 2 && !text(window).contains("ui-fake-"),"sanitized error and no success callback")
        auth.fail = false
        try click("接続を削除…",window); try wait("delete confirmation"){window.attachedSheet != nil}
        window.endSheet(window.attachedSheet!,returnCode:.alertSecondButtonReturn); try wait("confirmation closes"){window.attachedSheet == nil}; try ready(window)
        try check(try service.googleCalendarConnections().total == 1,"cancelled delete keeps connection")
        store.failRemove = true
        try click("接続を削除…",window); try wait("delete retry confirmation"){window.attachedSheet != nil}; window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("delete error"){message.stringValue.contains("キーチェーンから削除")}; try ready(window)
        selected = try service.googleCalendarConnections().rows[0]
        try check(selected["isActive"] == .integer(0) && table(window).numberOfRows == 1,"failed Keychain removal stays visible and inactive")
        store.failRemove = false; table(window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try click("接続を削除…",window); try wait("delete final confirmation"){window.attachedSheet != nil}; window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("removed row"){table(window).numberOfRows == 0}; try ready(window)
        try check(try service.googleCalendarConnections().total == 0 && store.values.count == 1,"retry removes grant and retains shared client settings")
        let other = try db.insert("Users",values:["name":.text("他の利用者"),"email":.text("ui-other@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:service.identity.id)
        try db.transaction {
            for i in 0..<102 { _ = try db.insert("CalendarConnection",values:["userId":.text(service.identity.id),"provider":.text("google"),"accountEmail":.text("page-\(i)@example.invalid"),"scopeLevel":.text("readonly"),"isActive":.integer(1),"refreshTokenEncrypted":.text("opaque-test-reference")],actor:service.identity.id) }
            _ = try db.insert("CalendarConnection",values:["userId":other["id"],"provider":.text("google"),"accountEmail":.text("other@example.invalid"),"scopeLevel":.text("readonly"),"isActive":.integer(1),"refreshTokenEncrypted":.text("opaque-test-reference")],actor:service.identity.id)
        }
        try click("再読み込み",window); try ready(window)
        try check(table(window).numberOfRows == 100 && text(window).contains("102件") && !(try button("前へ",window)).isEnabled,"owner-only first page is bounded")
        try click("次へ",window); try ready(window)
        try check(table(window).numberOfRows == 2 && !(try button("次へ",window)).isEnabled,"bounded final page")
        try click("前へ",window); try ready(window); try layout(window)
        let own = CRMService(db:db,identity:.init(id:other["id"].string,role:"user",partnerAccountID:nil))
        let ordinary = try GoogleCalendarSettingsWindow(service:own,store:store,authorize:auth.run); ordinary.window.setFrameOrigin(.init(x:-10000,y:-10000)); try ready(ordinary.window)
        try check(table(ordinary.window).numberOfRows == 1 && !views(ordinary.window.contentView!).compactMap({$0 as? NSButton}).contains(where:{$0.title == "アプリ設定を保存"}),"ordinary user sees own connection and no shared settings controls")
        try layout(ordinary.window)
        let reopened = try GoogleCalendarSettingsWindow(service:service,store:store,authorize:auth.run); reopened.window.setFrameOrigin(.init(x:-10000,y:-10000)); try ready(reopened.window)
        try check(try field("GoogleクライアントID",reopened.window).stringValue == client.stringValue && field("Googleクライアントシークレット",reopened.window).stringValue.isEmpty,"reopened settings recover public client ID without rendering secret")
        try GoogleCalendarRuntimeUITests.run(resources)
        try GoogleCalendarPushUITests.run(resources)
        print("GoogleCalendarSettingsUITests: \(checks) checks passed; actual offscreen AppKit and runtime, fake authorization/transport/secrets, isolated SQLite")
    }
}
