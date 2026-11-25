import AppKit

@main enum NativeMailAccountsUITests {
    static var checks = 0
    static func check(_ condition:@autoclosure () throws -> Bool,_ label:String) throws { guard try condition() else { throw NativeDBError.message("Mail UI FAIL: "+label) }; checks += 1 }
    static func views(_ view:NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    static func button(_ title:String,_ window:NSWindow) throws -> NSButton { guard let b = views(window.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == title}) else { throw NativeDBError.message("Missing button "+title) }; return b }
    static func click(_ title:String,_ window:NSWindow) throws { let b = try button(title,window); try check(b.isEnabled,"enabled: "+title); _ = b.sendAction(b.action,to:b.target) }
    static func field(_ label:String,_ window:NSWindow) throws -> NSTextField { guard let f = views(window.contentView!).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel() == label}) else { throw NativeDBError.message("Missing field "+label) }; return f }
    static func table(_ window:NSWindow) -> NSTableView { views(window.contentView!).compactMap{$0 as? NSTableView}.first! }
    static func wait(_ name:String,_ condition:() throws -> Bool) throws { let deadline = Date().addingTimeInterval(10); while Date() < deadline { if try condition() { return }; RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }; throw NativeDBError.message("Timed out: "+name) }
    static func ready(_ window:NSWindow) throws { try wait("mail account list"){try button("再読み込み",window).isEnabled} }
    static func layout(_ window:NSWindow) throws {
        window.contentView!.layoutSubtreeIfNeeded()
        for control in views(window.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor && !($0 is NSTableView)}) {
            let rect = control.convert(control.bounds,to:window.contentView), bounds = window.contentView!.bounds
            try check(rect.width > 0 && rect.height > 0 && rect.minX >= -1 && rect.maxX <= bounds.width+1 && rect.minY >= -1 && rect.maxY <= bounds.height+1,"control fits panel: "+(control.accessibilityLabel() ?? ""))
        }
    }
    final class Probe {
        var calls:[(NativeMailAccountSettings,NativeMailCredential,NativeMailConnectionCheck.Kind)] = [], delay = false, fail = false
        func run(_ settings:NativeMailAccountSettings,_ credential:NativeMailCredential,_ kind:NativeMailConnectionCheck.Kind) async throws -> [String] {
            let choice = await MainActor.run { self.calls.append((settings,credential,kind)); return (self.delay,self.fail) }
            if choice.0 { try await Task.sleep(nanoseconds:30_000_000_000) }
            if choice.1 { throw NativeMailFailure.transport(code:67,uploaded:false) }
            return kind == .inbox ? ["INBOX","送信済み","Sent"] : []
        }
    }
    static func fill(_ window:NSWindow) throws {
        for (name,text) in [("メールの表示名","仕事のメール"),("メールの利用者名","owner@example.test"),("メールのパスワード","synthetic-ui-only"),("IMAPサーバー","imap.example.test"),("SMTPサーバー","smtp.example.test")] { try field(name,window).stringValue = text }
    }
    static func main() { do { try run() } catch { FileHandle.standardError.write(Data("NativeMailAccountsUITests: \(error)\n".utf8)); exit(1) } }
    static func run() throws {
        try check(Thread.isMainThread,"main thread"); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1]), root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach{$0.orderOut(nil)}; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = NativeMailQAServices(), probe = Probe()
        let list = try NativeMailAccountsWindow(service:service,store:store,probe:probe.run); try ready(list.window)
        try check(table(list.window).numberOfRows == 0 && list.window.title == "メールアカウント","Japanese empty list")
        try layout(list.window)
        let editor = try NativeMailAccountEditor(service:service,store:store,probe:probe.run), window = editor.window
        try layout(window); try check(try field("メールのパスワード",window) is NSSecureTextField,"secure password field")
        try click("設定を保存",window)
        try check(try service.mailAccounts().total == 0 && !field("メール接続の結果",window).stringValue.isEmpty,"invalid settings do not save")
        try fill(window); let sent = try field("送信済みフォルダ",window) as! NSComboBox; sent.stringValue = "送信済み"
        try click("受信接続・フォルダを確認",window)
        try wait("receive probe"){try button("設定を保存",window).isEnabled}
        try check(sent.numberOfItems == 3 && sent.stringValue == "送信済み" && probe.calls.last?.2 == .inbox,"folder discovery preserves selection")
        try click("送信接続を確認",window); try wait("SMTP probe"){try button("設定を保存",window).isEnabled}
        try check(try probe.calls.last?.2 == .smtp && field("メール接続の結果",window).stringValue.contains("送信していません") && service.mailAccounts().total == 0,"test-only connection does not save an account")
        probe.delay = true; try click("送信接続を確認",window); try wait("probe started"){probe.calls.count == 3}
        try check(!editor.confirmDiscard() && !(try button("設定を保存",window)).isEnabled && !(try field("SMTPサーバー",window)).isEnabled,"pending probe prevents edits and closing")
        try click("接続確認を中止",window); try wait("probe cancelled"){try button("設定を保存",window).isEnabled}; probe.delay = false
        try check(try field("メール接続の結果",window).stringValue.contains("中止"),"cancelled probe shown in Japanese")
        probe.fail = true; try click("送信接続を確認",window); try wait("probe error"){try button("設定を保存",window).isEnabled}; probe.fail = false
        try check(try field("メール接続の結果",window).stringValue.contains("パスワード"),"classified authentication failure")
        var saved:NativeRecord?; editor.onSaved = { saved = $0 }; try click("設定を保存",window)
        var account = saved!
        try check(try service.mailSettings(account).sentFolder == "送信済み" && field("メールのパスワード",window).stringValue.isEmpty && editor.confirmDiscard(),"creation saves settings and clears password")
        let edit = try NativeMailAccountEditor(service:service,store:store,account:account,probe:probe.run)
        try check(try field("メールのパスワード",edit.window).stringValue.isEmpty,"existing password never populated")
        try field("メールの表示名",edit.window).stringValue = "変更した名前"
        try click("送信接続を確認",edit.window); try wait("saved credential probe"){try button("設定を保存",edit.window).isEnabled}
        try check(probe.calls.last?.1.password == "synthetic-ui-only","probe uses stored password when input blank")
        edit.onSaved = { saved = $0 }; try click("設定を保存",edit.window); account = saved!
        try check(try service.mailSettings(account).label == "変更した名前" && service.mailCredential(account,store:store).password == "synthetic-ui-only","edit preserves secret")
        let stale = try NativeMailAccountEditor(service:service,store:store,account:account,probe:probe.run)
        _ = try db.update(account,changes:["label":.text("他の操作で変更")],actor:service.identity.id)
        try click("送信接続を確認",stale.window)
        try check(try !field("メール接続の結果",stale.window).stringValue.isEmpty && button("設定を保存",stale.window).isEnabled,"stale credential snapshot rejected before probe")
        try click("設定を保存",stale.window)
        try check(try service.mailAccount(account["id"].string)["label"] == .text("他の操作で変更"),"stale editor cannot overwrite")
        try click("再読み込み",list.window); try ready(list.window); table(list.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try click("同期を停止",list.window); try ready(list.window)
        try check(try service.mailAccount(account["id"].string)["isActive"] == .integer(0) && !button("今すぐ同期",list.window).isEnabled,"pause keeps account and disables manual sync")
        try click("同期を再開",list.window); try ready(list.window)
        try check(try service.mailSyncJob(account["id"].string)?.status == "pending","resume enqueues persistent synchronization")
        try check(!(try button("今すぐ同期",list.window)).isEnabled,"duplicate pending manual sync disabled")
        try click("設定を編集…",list.window); try check(list.window.attachedSheet != nil && !list.confirmDiscard(),"nested edit sheet prevents parent closing")
        try click("キャンセル",list.window.attachedSheet!); try wait("editor dismissed"){list.window.attachedSheet == nil}; try ready(list.window)
        try click("アカウントを削除…",list.window); try check(list.window.attachedSheet != nil,"delete needs explicit dialog")
        list.window.endSheet(list.window.attachedSheet!,returnCode:.alertSecondButtonReturn); try wait("delete cancelled"){list.window.attachedSheet == nil}; try ready(list.window)
        try check(try service.mailAccounts().total == 1,"cancel delete preserves account")
        try click("アカウントを削除…",list.window); list.window.endSheet(list.window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("delete done"){try service.mailAccounts().total == 0}; try ready(list.window)
        try check(table(list.window).numberOfRows == 0,"confirmed account deletion refreshes list")
        let settings = NativeMailAccountSettings(label:"ページ試験",username:"page@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS))
        for _ in 0..<101 { _ = try service.createMailAccount(settings,password:"synthetic-only",store:store) }
        try click("再読み込み",list.window); try ready(list.window)
        try check(table(list.window).numberOfRows == 100 && (try button("次へ",list.window)).isEnabled,"account list bounded at 100 rows")
        try click("次へ",list.window); try ready(list.window); try check(table(list.window).numberOfRows == 1,"second account page")
        table(list.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try click("アカウントを削除…",list.window); list.window.endSheet(list.window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("last row removed"){try service.mailAccounts().total == 100}; try ready(list.window)
        try check(table(list.window).numberOfRows == 100 && !(try button("前へ",list.window)).isEnabled,"empty last page returns to preceding page")
        try layout(list.window)
        print("NativeMailAccountsUITests: \(checks) checks passed; actual AppKit controls, Japanese layout, connection/cancel, secure edit, stale protection, sync, delete and bounded pages")
        try NativeMailComposeHistoryUITests.run(resources:resources)
        try NativeMailMailboxUITests.run(resources:resources)
        try NativeMailRelatedUITests.run(resources:resources)
    }
}
