import AppKit

enum NativeMailMailboxUITests {
    static var checks = 0
    final class Viewer:NativeMailHTMLViewing { var closed = false; func close() { closed = true } }
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws { guard try value() else { throw NativeDBError.message("Mailbox UI FAIL: "+name) }; checks += 1 }
    final class Receiver:NativeMailReceiving {
        var calls = 0
        func status(mailbox:String) async throws -> (validity:UInt32,next:UInt32) { throw NativeMailFailure.invalid("Unused fixture method") }
        func discover(mailbox:String,validity:UInt32,after:UInt32,through:UInt32,since:Date?) async throws -> NativeMailUIDSpool { throw NativeMailFailure.invalid("Unused fixture method") }
        func headers(mailbox:String,validity:UInt32,uids:[UInt32]) async throws -> [NativeMailIMAPHeader] { throw NativeMailFailure.invalid("Unused fixture method") }
        func body(mailbox:String,validity:UInt32,uid:UInt32) async throws -> NativeMailBody? { calls += 1; return .init(text:"取得した日本語本文 🌸") }
    }
    static func run(resources:URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailboxUI-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = NativeMailQAServices()
        let account = try service.createMailAccount(.init(label:"受信試験",username:"owner@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS)),password:"synthetic-only",store:store), accountID = account["id"].string
        var ids:[String] = []
        for i in 1...61 {
            let header = NativeMailIMAPHeader(uid:UInt32(i),seen:false,headers:try NativeMailMIME.headers(Data("Message-ID: <in-\(i)@example.test>\r\nFrom: 顧客 <customer@example.test>\r\nTo: owner@example.test\r\nSubject: 日本語の件名 \(i)\r\n\r\n".utf8)))
            let id = try service.importMailHeaders(account:account,folder:.inbox,uidValidity:77,headers:[header])[0]; ids.append(id)
            let row = try db.update(service.mailMessage(id),changes:["sentAt":.text(ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1_700_000_000+Double(i)*60)))],actor:service.identity.id)
            if i < 61 { _ = try service.saveMailBody(row,location:service.mailLocation(row)!,body:i == 60 ? .init(html:"<p>HTMLの本文 &amp; 日本語</p>") : .init(text:"保存済み本文 \(i)")) }
        }
        _ = try db.insert("Email",values:["emailAccountId":account["id"],"userId":.text(service.identity.id),"rfcMessageId":.text("<sent@example.test>"),"folder":.text("SENT"),"subject":.text("送信済みだけ"),"bodyText":.text("送信した本文"),"isRead":.integer(1)],actor:service.identity.id)
        _ = try service.setMailAccountActive(account,active:false)
        let receiver = Receiver(), worker = NativeMailContentWorker(db:db,store:store,makeClient:{_,_ in receiver})
        var htmlDocuments:[NativeMailHTMLDocument] = [], viewers:[Viewer] = []
        let controller = try NativeMailMailboxWindow(service:service,accountID:accountID,makeHTMLViewer:{ document,_ in
            htmlDocuments.append(document); let viewer = Viewer(); viewers.append(viewer); return viewer
        }), window = controller.window
        var workerFailure:Error?
        controller.onChanged = {
            Task { @MainActor in
                do { _ = try await worker.runNext(); NotificationCenter.default.post(name:InvoiceJobRunner.didProcess,object:nil,userInfo:["database":db.url.path]) }
                catch { workerFailure = error }
            }
        }
        func button(_ name:String) throws -> NSButton { try NativeMailAccountsUITests.button(name,window) }
        func click(_ name:String) throws {
            if name == "未読のみ" { try button(name).performClick(nil) }
            else { try NativeMailAccountsUITests.click(name,window) }
        }
        func wait(_ name:String,_ action:() throws -> Bool) throws { try NativeMailAccountsUITests.wait(name,action) }
        func ready() throws { try NativeMailAccountsUITests.ready(window) }
        let table = NativeMailAccountsUITests.table(window)
        func content() throws -> String { try NativeMailComposeHistoryUITests.text("選択したメールの本文",window).string }
        func field(_ name:String) throws -> NSTextField { try NativeMailAccountsUITests.field(name,window) }
        try ready(); try NativeMailAccountsUITests.layout(window)
        try check(table.numberOfRows == 50 && receiver.calls == 0,"list stays at fifty headers without body fetching")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try wait("foreground body arrives through worker and notification"){try content().contains("取得した日本語本文") && button("返信…").isEnabled}
        try check(try receiver.calls == 1 && workerFailure == nil && service.mailMessage(ids[60])["isRead"] == .integer(1),"opening while sync paused fetches only selected body and marks read")
        try check(try !button("HTMLで表示…").isEnabled,"plain mail does not launch HTML viewer")
        try click("返信…"); try check(window.attachedSheet?.title == "メールに返信","selected mailbox mail opens reply composer")
        try check(try NativeMailAccountsUITests.field("宛先（To）",window.attachedSheet!).stringValue == "customer@example.test" && NativeMailAccountsUITests.field("件名",window.attachedSheet!).stringValue == "Re: 日本語の件名 61","reply uses selected sender and subject")
        window.endSheet(window.attachedSheet!); try wait("reply closes"){window.attachedSheet == nil}; try ready()
        try wait("selected body available again"){try button("転送…").isEnabled}; try click("転送…")
        try check(try NativeMailAccountsUITests.field("宛先（To）",window.attachedSheet!).stringValue.isEmpty && NativeMailAccountsUITests.field("件名",window.attachedSheet!).stringValue == "Fwd: 日本語の件名 61","selected mailbox forwarding requires a new recipient")
        window.endSheet(window.attachedSheet!); try wait("forward closes"){window.attachedSheet == nil}; try ready()
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try wait("HTML-only native text view"){try content().contains("HTMLの本文 & 日本語")}
        try check(receiver.calls == 1,"cached HTML text view does not fetch again")
        try click("HTMLで表示…"); try wait("HTML viewer launched"){htmlDocuments.count == 1}
        try check(htmlDocuments[0].html == "<p>HTMLの本文 &amp; 日本語</p>" && htmlDocuments[0].subject == "日本語の件名 60","HTML viewer receives the selected original HTML and subject")
        try click("HTMLで表示…"); try wait("HTML viewer replaced"){viewers.count == 2}
        try check(viewers[0].closed && !viewers[1].closed,"only one HTML viewer stays open per mailbox")
        for index in [0,1,2,3] { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        try wait("rapid latest selection"){try content().contains("件名：日本語の件名 58") && content().contains("保存済み本文 58")}
        try check(try !content().contains("取得した日本語本文"),"rapid selection cannot display previous body")
        try check(viewers.allSatisfy{$0.closed},"changing selection closes HTML viewer")
        try click("次へ"); try ready(); try check(table.numberOfRows == 11 && !(try button("次へ")).isEnabled,"second page is bounded and ends at actual total")
        try click("前へ"); try ready()
        let search = try field("メールを検索")
        search.stringValue = "件名 60"; controller.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:search))
        try wait("subject search"){table.numberOfRows == 1}; try ready(); table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try wait("searched body"){try content().contains("HTMLの本文")}
        try check(try content().contains("件名：日本語の件名 60"),"Japanese search selects matching mail")
        try click("HTMLで表示…"); try wait("search HTML opened"){viewers.count == 3}
        _ = try db.update(service.mailMessage(ids[59]),changes:["subject":.text("日本語の件名 60（HTML更新）")],actor:service.identity.id)
        try click("HTMLで表示…")
        try wait("stale HTML launch rejected"){try button("HTMLで表示…").isEnabled && field("受信メールの操作結果").stringValue.contains("更新されています")}
        try check(viewers.count == 3,"stale selected body cannot launch a new viewer")
        try click("再読み込み"); try ready(); try wait("refreshed HTML body"){try button("HTMLで表示…").isEnabled}
        let closeViewer = Viewer()
        let closeController = try NativeMailMailboxWindow(service:service,accountID:accountID,makeHTMLViewer:{_,_ in closeViewer})
        try NativeMailAccountsUITests.ready(closeController.window)
        NativeMailAccountsUITests.table(closeController.window).selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        try wait("second window HTML ready"){try NativeMailAccountsUITests.button("HTMLで表示…",closeController.window).isEnabled}
        try NativeMailAccountsUITests.click("HTMLで表示…",closeController.window)
        try wait("second window HTML started"){try NativeMailAccountsUITests.field("受信メールの操作結果",closeController.window).stringValue.contains("別のウインドウ")}
        try NativeMailAccountsUITests.click("閉じる",closeController.window)
        try check(closeViewer.closed,"closing the mailbox terminates its HTML session")
        try click("このMacから削除…"); window.endSheet(window.attachedSheet!,returnCode:.alertSecondButtonReturn); try wait("delete cancelled"){window.attachedSheet == nil}; try ready()
        try check(try service.mailMessage(ids[59])["isDeleted"] == .integer(0),"canceling deletion preserves mail")
        try check(viewers[2].closed,"reload closes the previous HTML snapshot")
        try wait("delete ready before concurrent change"){try button("このMacから削除…").isEnabled}; try click("このMacから削除…")
        _ = try db.update(service.mailMessage(ids[59]),changes:["subject":.text("日本語の件名 60（更新）")],actor:service.identity.id)
        window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("stale deletion rejected and refreshed"){try button("このMacから削除…").isEnabled && content().contains("60（更新）")}
        try check(try service.mailMessage(ids[59])["isDeleted"] == .integer(0) && field("受信メールの操作結果").stringValue.contains("更新されています"),"concurrent change prevents deletion and error remains visible after body refresh")
        try wait("delete enabled"){try button("このMacから削除…").isEnabled}; try click("このMacから削除…"); window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("local deletion reflected"){try service.mailMessage(ids[59],includeDeleted:true)["isDeleted"] == .integer(1) && table.numberOfRows == 0}; try ready()
        try check(receiver.calls == 1,"local deletion never invokes an IMAP mutation")
        search.stringValue = ""; controller.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:search)); try wait("clear search"){table.numberOfRows == 50}; try ready()
        let allViews = NativeMailAccountsUITests.views(window.contentView!)
        let folder = allViews.compactMap{$0 as? NSPopUpButton}.first{$0.accessibilityLabel() == "メールのフォルダ"}!
        folder.selectItem(at:1); _ = folder.sendAction(folder.action,to:folder.target); try ready()
        try check(table.numberOfRows == 1,"sent folder excludes inbox mail")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); try wait("sent body"){try content().contains("送信した本文")}
        try click("未読のみ"); try ready(); try check(table.numberOfRows == 0,"unread filter excludes read sent messages")
        try click("未読のみ"); folder.selectItem(at:0); _ = folder.sendAction(folder.action,to:folder.target); try ready()
        try click("未読のみ"); try ready()
        try check(try service.mailMessages(accountID:accountID,folder:.inbox,unreadOnly:true).rows.allSatisfy{$0["isRead"] == .integer(0)} && table.numberOfRows == 50,"unread inbox is paginated across all matching mail")
        let reopened = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        try check(try reopened.get("Email",key:["id":.text(ids[60])])?["bodyText"] == .text("取得した日本語本文 🌸") && reopened.get("Email",key:["id":.text(ids[59])])?["isDeleted"] == .integer(1),"read/body/deletion survive reopening SQLite")
        try click("閉じる"); NotificationCenter.default.post(name:InvoiceJobRunner.didProcess,object:nil,userInfo:["database":db.url.path])
        try check(try content().isEmpty,"closed mailbox clears retained body and ignores notifications")
        print("NativeMailMailboxUITests: \(checks) checks passed; bounded mailbox/search/read/delete, paused foreground fetch, reply/forward, paging and persistence")
    }
}
