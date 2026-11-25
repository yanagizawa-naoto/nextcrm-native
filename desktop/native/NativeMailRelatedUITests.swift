import AppKit

enum NativeMailRelatedUITests {
    static var checks = 0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws { guard try value() else { throw NativeDBError.message("Related mail UI FAIL: "+name) }; checks += 1 }
    static func run(resources:URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-RelatedMailUI-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = NativeMailQAServices()
        func account(_ name:String) throws -> NativeRecord { try service.createMailAccount(.init(label:name,username:name+"@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS)),password:"synthetic",store:store) }
        let first = try account("first"), second = try account("second")
        var parent = try db.insert("crm_Accounts",values:["v":.integer(0),"name":.text("日本語の取引先")],actor:service.identity.id)
        let contact = try db.insert("crm_Contacts",values:["first_name":.text("花子"),"last_name":.text("山田")],actor:service.identity.id)
        var ids:[String] = []
        for i in 0..<52 {
            let chosen = i%2 == 0 ? first : second
            let row = try db.insert("Email",values:["emailAccountId":chosen["id"],"userId":.text(service.identity.id),"rfcMessageId":.text("<ui-\(i)@example.test>"),"folder":.text(i == 0 ? "SENT" : "INBOX"),"subject":.text("日本語の関連メール \(i)"),"fromEmail":.text("customer@example.test"),"bodyHtml":.text("<p>関連する本文 \(i)</p>"),"sentAt":.text(ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1_700_000_000+Double(i))))],actor:service.identity.id)
            ids.append(row["id"].string)
            _ = try db.insert("EmailsToAccounts",values:["emailId":row["id"],"accountId":parent["id"]],actor:service.identity.id)
            if i == 51 { _ = try db.insert("EmailsToContacts",values:["emailId":row["id"],"contactId":contact["id"]],actor:service.identity.id) }
        }
        _ = try service.setMailAccountActive(second,active:false)
        var documents:[NativeMailHTMLDocument] = []
        let controller = try NativeMailMailboxWindow(service:service,context:.crm(model:parent.model,id:parent["id"].string),makeHTMLViewer:{doc,_ in documents.append(doc); return NativeMailMailboxUITests.Viewer() }), window = controller.window
        func button(_ name:String) throws -> NSButton { try NativeMailAccountsUITests.button(name,window) }
        func click(_ name:String) throws { try NativeMailAccountsUITests.click(name,window) }
        func ready() throws { try NativeMailAccountsUITests.ready(window) }
        func wait(_ name:String,_ predicate:() throws -> Bool) throws { try NativeMailAccountsUITests.wait(name,predicate) }
        func body() throws -> String { try NativeMailComposeHistoryUITests.text("選択したメールの本文",window).string }
        let table = NativeMailAccountsUITests.table(window)
        let folder = NativeMailAccountsUITests.views(window.contentView!).compactMap{$0 as? NSPopUpButton}.first{$0.accessibilityLabel() == "メールのフォルダ"}!
        try ready(); try NativeMailAccountsUITests.layout(window)
        try check(window.title.contains("日本語の取引先") && table.numberOfRows == 50 && folder.titleOfSelectedItem == "すべてのフォルダ","related view shows parent, all folders, fifty headers")
        try check(try !button("メールを作成…").isEnabled && !button("送信履歴…").isEnabled,"no ambiguous account action before selection")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try wait("related body"){try body().contains("関連する本文 51") && button("返信…").isEnabled}
        try check(try body().contains("second <second@example.test>") && service.mailMessage(ids[51])["isRead"] == .integer(1),"related mail displays actual paused account and persists read")
        try click("HTMLで表示…"); try wait("related HTML"){documents.count == 1}
        try check(documents[0].html == "<p>関連する本文 51</p>","related HTML uses selected original body")
        try click("返信…"); try check(window.attachedSheet?.title == "メールに返信","related reply sheet opens")
        try check(try NativeMailAccountsUITests.field("宛先（To）",window.attachedSheet!).stringValue == "customer@example.test","related reply uses correct source")
        try check(NativeMailAccountsUITests.views(window.attachedSheet!.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("差出人：second@example.test")},"reply sends from the selected account")
        window.endSheet(window.attachedSheet!); try wait("reply close"){window.attachedSheet == nil}; try ready()
        try wait("history ready"){try button("送信履歴…").isEnabled}; try click("送信履歴…")
        try check(NativeMailAccountsUITests.views(window.attachedSheet!.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("second")},"history uses selected account instead of another linked account")
        window.endSheet(window.attachedSheet!); try wait("history close"){window.attachedSheet == nil}; try ready()
        try click("次へ"); try ready(); try check(table.numberOfRows == 2,"related second page has remaining headers")
        folder.selectItem(at:2); _ = folder.sendAction(folder.action,to:folder.target); try ready()
        try check(table.numberOfRows == 1,"sent-only related filter")
        folder.selectItem(at:0); _ = folder.sendAction(folder.action,to:folder.target); try ready()
        let search = try NativeMailAccountsUITests.field("メールを検索",window); search.stringValue = "関連メール 51"; controller.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:search))
        try wait("related search"){table.numberOfRows == 1}; table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try wait("searched related body"){try button("このMacから削除…").isEnabled}
        try click("このMacから削除…")
        let link = try db.get("EmailsToAccounts",key:["emailId":.text(ids[51]),"accountId":parent["id"]])!; try db.remove(link,actor:service.identity.id)
        window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try wait("unlink during confirmation"){window.attachedSheet == nil && table.numberOfRows == 0}; try ready()
        try check(try service.mailMessage(ids[51])["isDeleted"] == .integer(0),"changed CRM association prevents confirmed deletion")
        let contacts = try NativeMailMailboxWindow(service:service,context:.crm(model:contact.model,id:contact["id"].string))
        try NativeMailAccountsUITests.ready(contacts.window)
        try check(NativeMailAccountsUITests.table(contacts.window).numberOfRows == 1 && contacts.window.title.contains("山田"),"contact related window remains independently accessible")
        try NativeMailAccountsUITests.click("閉じる",contacts.window)
        parent = try db.setDeleted(parent,deleted:true,actor:service.identity.id)
        search.stringValue = ""; controller.controlTextDidChange(Notification(name:NSText.didChangeNotification,object:search))
        try wait("deleted parent access error"){try NativeMailAccountsUITests.field("受信メールの操作結果",window).stringValue.contains("権限")}; try ready()
        try check(table.numberOfRows == 0 && !(try button("返信…")).isEnabled,"revoked parent access clears list and selection")
        try click("閉じる")
        print("NativeMailRelatedUITests: \(checks) checks passed; Japanese CRM-related paging, selected account actions, filters, HTML and fresh association protection")
    }
}
