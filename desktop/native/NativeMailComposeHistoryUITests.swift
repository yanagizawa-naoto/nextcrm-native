import AppKit

enum NativeMailComposeHistoryUITests {
    static var checks = 0
    static func check(_ value:@autoclosure () throws -> Bool,_ name:String) throws { guard try value() else { throw NativeDBError.message("Mail compose/history UI FAIL: "+name) }; checks += 1 }
    static func rejects(_ name:String,_ action:() throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("Unexpected success: "+name) }
    static func field(_ name:String,_ window:NSWindow) throws -> NSTextField { try NativeMailAccountsUITests.field(name,window) }
    static func click(_ name:String,_ window:NSWindow) throws { try NativeMailAccountsUITests.click(name,window) }
    static func wait(_ name:String,_ condition:() throws -> Bool) throws { try NativeMailAccountsUITests.wait(name,condition) }
    static func ready(_ window:NSWindow) throws { try NativeMailAccountsUITests.ready(window) }
    static func table(_ window:NSWindow) -> NSTableView { NativeMailAccountsUITests.table(window) }
    static func button(_ name:String,_ window:NSWindow) throws -> NSButton { try NativeMailAccountsUITests.button(name,window) }
    static func text(_ name:String,_ window:NSWindow) throws -> NSTextView {
        guard let value = NativeMailAccountsUITests.views(window.contentView!).compactMap({$0 as? NSTextView}).first(where:{$0.accessibilityLabel() == name}) else { throw NativeDBError.conflict }; return value
    }
    static func fill(_ controller:NativeMailComposeWindow) throws {
        try field("宛先（To）",controller.window).stringValue = "\"営業部, 東京\" <one@example.test>, two@example.test"
        try field("Cc",controller.window).stringValue = "copy@example.test"
        try field("Bcc",controller.window).stringValue = "private@example.test"
        try field("件名",controller.window).stringValue = "日本語の作成試験"
        try text("メール本文",controller.window).string = "こんにちは\n本文です。"
    }
    static func run(resources:URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-MailComposeUI-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = NativeMailQAServices()
        let settings = NativeMailAccountSettings(label:"送信試験",username:"owner@example.test",imap:.init(host:"imap.example.test",port:993,tls:.implicitTLS),smtp:.init(host:"smtp.example.test",port:587,tls:.startTLS))
        var account = try service.createMailAccount(settings,password:"synthetic-only",store:store); let accountID = account["id"].string
        let composer = try NativeMailComposeWindow(service:service,accountID:accountID)
        try NativeMailAccountsUITests.layout(composer.window)
        try check(composer.confirmDiscard() && composer.window.title == "メールを作成","clean Japanese composer")
        try click("送信",composer.window); try wait("invalid send settled"){try button("送信",composer.window).isEnabled}
        try check(try service.mailSendJobs(accountID).isEmpty && !field("メール作成の結果",composer.window).stringValue.isEmpty,"invalid recipient does not queue")
        try fill(composer)
        try field("Cc",composer.window).stringValue = "copy@example.test, invalid-address"
        try click("送信",composer.window); try wait("invalid mixed list settled"){try button("送信",composer.window).isEnabled}
        try check(try service.mailSendJobs(accountID).isEmpty && !field("メール作成の結果",composer.window).stringValue.isEmpty,"real controls do not silently drop invalid Cc")
        try field("Cc",composer.window).stringValue = "copy@example.test"
        // A normal background sync updates the account's revision. It must not
        // invalidate a draft when sender/SMTP are unchanged.
        account = try db.update(account,changes:["lastSyncedAt":.text(ISO8601DateFormatter().string(from:Date()))],actor:service.identity.id)
        try click("送信",composer.window); try wait("queued"){composer.queuedID != nil}
        let queued = try service.mailSendJob(composer.queuedID!), summary = try service.mailSendSummary(queued)
        try check(summary.to == ["one@example.test","two@example.test"] && summary.cc == ["copy@example.test"] && summary.bcc == ["private@example.test"],"To/Cc/Bcc captured by real controls")
        try check(summary.toAddresses?.first?.name == "営業部, 東京","quoted display-name comma survives actual composer")
        try check(try service.mailSendBody(queued) == "こんにちは\r\n本文です。" && composer.confirmDiscard(),"Japanese body persisted before closing")
        _ = (try button("送信",composer.window)).sendAction(NSSelectorFromString("send"),to:composer)
        try check(try service.mailSendJobs(accountID).count == 1,"double activation cannot queue twice")
        let other = try db.insert("Users",values:["email":.text("other@example.test"),"name":.text("別の管理者"),"role":.text("admin"),"userStatus":.text("ACTIVE")],actor:"fixture")
        let stranger = CRMService(db:db,identity:.init(id:other["id"].string,role:"admin",partnerAccountID:nil))
        try rejects("another admin cannot read selected send body") { _ = try stranger.mailSendBody(queued) }
        let history = try NativeMailHistoryWindow(service:service,accountID:accountID); try ready(history.window); try NativeMailAccountsUITests.layout(history.window)
        try check(table(history.window).numberOfRows == 1,"queued mail visible in history")
        table(history.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try wait("selected body loaded"){try text("選択した送信メールの詳細",history.window).string.contains("こんにちは")}
        try check(try text("選択した送信メールの詳細",history.window).string.contains("private@example.test"),"owner sees Bcc in selected detail")
        try click("送信待ちを取り消す…",history.window)
        history.window.endSheet(history.window.attachedSheet!,returnCode:.alertSecondButtonReturn); try wait("cancel dialog closed"){history.window.attachedSheet == nil}; try ready(history.window)
        try check(try service.mailSendJob(queued.id).status == "pending","canceling confirmation preserves queued mail")
        try click("送信待ちを取り消す…",history.window)
        history.window.endSheet(history.window.attachedSheet!,returnCode:.alertFirstButtonReturn); try wait("send cancelled"){try service.mailSendJob(queued.id).status == "cancelled"}; try ready(history.window)
        try check(try service.mailSendBody(service.mailSendJob(queued.id)) == nil,"cancel releases prepared body")
        try rejects("stale selected job body") { _ = try service.mailSendBody(queued) }
        func queue(_ subject:String) throws -> String { try service.queueMailSend(account:service.mailAccount(accountID),draft:.init(to:["to@example.test"],subject:subject,body:"確認用本文")) }
        func uncertain(_ subject:String) throws -> String {
            let id = try queue(subject), claimed = try db.claimJob(events:[NativeMailDelivery.event])!
            try check(claimed.id == id,"fixture claims intended job")
            let started = try db.markJobDeliveryStarted(claimed); try db.failJob(started,message:"結果不明",needsReview:true); return id
        }
        func selectNewest() throws { try click("再読み込み",history.window); try ready(history.window); table(history.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
        func choose(_ index:Int,_ window:NSWindow) throws {
            guard let popup = NativeMailAccountsUITests.views(window.contentView!).compactMap({$0 as? NSPopUpButton}).first(where:{$0.accessibilityLabel() == "メールの確認結果"}) else { throw NativeDBError.conflict }
            popup.selectItem(at:index); _ = popup.sendAction(popup.action,to:popup.target)
        }
        var sends = 0
        let worker = NativeMailSendWorker(db:db,store:store,send:{ _ in await MainActor.run { sends += 1 } })
        func runWorker() throws {
            var outcome:Result<Bool,Error>?
            Task { @MainActor in do { outcome = .success(try await worker.runNext()) } catch { outcome = .failure(error) } }
            try wait("mail worker"){outcome != nil}; _ = try outcome!.get()
        }
        let unknownID = try uncertain("送信結果不明の試験"); try selectNewest()
        try check(!(try button("再試行",history.window)).isEnabled && !(try button("送信待ちを取り消す…",history.window)).isEnabled,"uncertain send prevents retry and cancellation")
        try click("送信結果を確認…",history.window); try NativeMailAccountsUITests.layout(history.window.attachedSheet!)
        try click("確認結果を記録",history.window.attachedSheet!); try wait("unknown review closes"){history.window.attachedSheet == nil}; try ready(history.window)
        try check(try service.mailSendJob(unknownID).status == "needs_review","unknown review leaves job unchanged")
        try click("送信結果を確認…",history.window); try choose(2,history.window.attachedSheet!); try click("確認結果を記録",history.window.attachedSheet!)
        try wait("not-sent review closes"){history.window.attachedSheet == nil}; try ready(history.window)
        try check(try service.mailSendJob(unknownID).status == "failed" && sends == 0,"not-sent review does not send automatically")
        try click("再試行",history.window); try ready(history.window); try runWorker(); try selectNewest()
        let delivered = try service.mailSendJob(unknownID)
        try check(delivered.status == "done" && sends == 1,"explicit retry submits exactly once")
        try check(try service.mailSendBody(delivered) == "確認用本文","completed history reads local sent copy after MIME release")
        let acceptedID = try uncertain("送信済みを確認する試験"); try selectNewest()
        try click("送信結果を確認…",history.window); try choose(1,history.window.attachedSheet!); try click("確認結果を記録",history.window.attachedSheet!)
        try wait("accepted review closes"){history.window.attachedSheet == nil}; try ready(history.window)
        try runWorker()
        try check(try service.mailSendJob(acceptedID).status == "done" && sends == 1,"accepted review only records locally")
        // Saving an already accepted message remains possible after pausing the
        // account; this cannot cause another SMTP transaction.
        let localID = try queue("送信済み保存の再試行"), claimed = try db.claimJob(events:[NativeMailDelivery.event])!, started = try db.markJobDeliveryStarted(claimed)
        try db.recordJobResult(started,result:["smtpAccepted":"true","acceptedAt":ISO8601DateFormatter().string(from:Date())])
        try db.failJob(started,message:"保存失敗",retryAt:Date().addingTimeInterval(600))
        account = try service.setMailAccountActive(service.mailAccount(accountID),active:false); try selectNewest()
        try click("保存を再試行",history.window); try ready(history.window); try runWorker()
        try check(try service.mailSendJob(localID).status == "done" && sends == 1,"paused account still reconciles accepted mail without sending")
        let pausedComposer = try NativeMailComposeWindow(service:service,accountID:accountID); try fill(pausedComposer)
        try click("送信",pausedComposer.window); try wait("paused account send queued"){pausedComposer.queuedID != nil}; try runWorker()
        try check(try service.mailSendJob(pausedComposer.queuedID!).status == "done" && sends == 2,"pausing automatic sync does not disable explicit sending, matching original")
        account = try service.setMailAccountActive(service.mailAccount(accountID),active:true)
        let changed = try NativeMailComposeWindow(service:service,accountID:accountID); try fill(changed)
        var settings2 = settings; settings2.smtp.host = "changed.example.test"
        account = try service.updateMailAccount(account,settings:settings2,password:nil,store:store)
        try click("送信",changed.window); try wait("sender change rejected"){try button("送信",changed.window).isEnabled}
        try check(try changed.queuedID == nil && field("メール作成の結果",changed.window).stringValue.contains("送信元"),"changed SMTP endpoint cannot silently redirect an open draft")
        account = try service.updateMailAccount(account,settings:settings,password:nil,store:store)
        let source = try db.insert("Email",values:["emailAccountId":account["id"],"userId":.text(service.identity.id),"rfcMessageId":.text("<source@example.test>"),"folder":.text("INBOX"),"subject":.text("元の件名"),"fromEmail":.text("customer@example.test"),"bodyText":.text("元の日本語本文")],actor:service.identity.id)
        let reply = try NativeMailComposeWindow(service:service,accountID:accountID,mode:.reply,sourceID:source["id"].string)
        try check(try field("宛先（To）",reply.window).stringValue == "customer@example.test" && field("件名",reply.window).stringValue == "Re: 元の件名" && text("メール本文",reply.window).string.contains("--- 元のメール ---\n元の日本語本文"),"reply recipient, subject and Japanese quotation")
        try click("送信",reply.window); try wait("reply queued"){reply.queuedID != nil}
        let replyJob = try service.mailSendJob(reply.queuedID!), mime = try NativeMailDelivery.payload(db:db,job:replyJob).1, headers = try NativeMailMIME.headers(Data(mime.prefix{ $0 != 0 }))
        try check(headers["in-reply-to"] == "<source@example.test>" && headers["references"] == "<source@example.test>","reply thread headers from actual compose action")
        try service.cancelMailSend(replyJob)
        let forward = try NativeMailComposeWindow(service:service,accountID:accountID,mode:.forward,sourceID:source["id"].string)
        try check(try field("宛先（To）",forward.window).stringValue.isEmpty && field("件名",forward.window).stringValue == "Fwd: 元の件名" && text("メール本文",forward.window).string.contains("元の日本語本文"),"forward has new recipient and original body")
        try field("宛先（To）",forward.window).stringValue = "forward@example.test"; try click("送信",forward.window); try wait("forward queued"){forward.queuedID != nil}
        let forwardJob = try service.mailSendJob(forward.queuedID!), forwardMIME = try NativeMailDelivery.payload(db:db,job:forwardJob).1
        try check(try NativeMailMIME.headers(forwardMIME)["in-reply-to"].isEmpty,"forward does not add reply thread header")
        try service.cancelMailSend(forwardJob)
        let quoted = try NativeMailText.quote(html:"<!doctype html><html><head><style>secret-css</style></head><body><p>日本語 &amp; 絵文字😀</p><script>secret-script</script><p>次の段落<br>改行</p><table><tr><td>左</td><td>右</td></tr></table><img src='https://example.test/tracker'></body></html>")
        try check(quoted.contains("日本語 & 絵文字😀") && quoted.contains("次の段落\n改行") && quoted.contains("左\t右") && !quoted.contains("secret-") && !quoted.contains("tracker"),"HTML quotation preserves Japanese text/table separation and strips executable content")
        let html = try db.update(source,changes:["bodyText":.null,"bodyHtml":.text("<p>HTMLだけの日本語</p>")],actor:service.identity.id)
        let htmlReply = try NativeMailComposeWindow(service:service,accountID:accountID,mode:.reply,sourceID:html["id"].string)
        try check(try text("メール本文",htmlReply.window).string.contains("HTMLだけの日本語"),"HTML-only reply keeps a text quotation")
        let unloaded = try db.update(html,changes:["bodyHtml":.null],actor:service.identity.id)
        try rejects("unloaded source must finish body fetch before reply") { _ = try NativeMailComposeWindow(service:service,accountID:accountID,mode:.reply,sourceID:unloaded["id"].string) }
        // A worker can finish between the header query and the selected-body
        // query, without its completion notification having reached the UI yet.
        let changedID = try queue("履歴の読み込み中に状態が変わる試験"); try selectNewest()
        table(history.window).deselectAll(nil)
        let changedJob = try db.claimJob(events:[NativeMailDelivery.event])!
        try check(changedJob.id == changedID,"concurrent fixture claims intended job")
        try db.failJob(db.markJobDeliveryStarted(changedJob),message:"結果不明",needsReview:true)
        table(history.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try wait("selected body refreshes after a concurrent worker update") {
            let body = try text("選択した送信メールの詳細",history.window).string
            return body.contains("状態：結果の確認が必要") && body.contains("確認用本文")
        }
        try check(try !field("送信履歴の操作結果",history.window).stringValue.contains("更新されています") && button("送信結果を確認…",history.window).isEnabled,"worker updates refresh the selected body and controls without a stale error")
        for i in 0..<52 { _ = try queue("履歴ページ \(i)") }
        try selectNewest(); try check(table(history.window).numberOfRows == 50,"history holds at most fifty rows")
        let wanted = try service.mailSendSummary(service.mailSendJobs(accountID)[2]).subject
        for index in [0,1,0,2] { table(history.window).selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        try wait("latest selected detail"){try text("選択した送信メールの詳細",history.window).string.contains(wanted) && text("選択した送信メールの詳細",history.window).string.contains("確認用本文")}
        try check(try text("選択した送信メールの詳細",history.window).string.contains("件名："+wanted),"rapid selection cannot show a stale body")
        try click("次へ",history.window); try ready(history.window); try check(table(history.window).numberOfRows > 0 && table(history.window).numberOfRows < 50 && !(try button("次へ",history.window)).isEnabled,"history second page bounded and end detected")
        try click("前へ",history.window); try ready(history.window)
        let bulk = try NativeMailComposeWindow(service:service,accountID:accountID)
        let bulkAddresses = (0..<1501).map{"person\($0)@example.test"}, bulkBody = String(repeating:"日本語の本文です。\n",count:10_000)
        try field("宛先（To）",bulk.window).stringValue = bulkAddresses.joined(separator:", ")
        try field("件名",bulk.window).stringValue = "多数の宛先と大きな本文"
        try text("メール本文",bulk.window).string = bulkBody
        try NativeMailAccountsUITests.layout(bulk.window)
        try click("送信",bulk.window); try wait("bulk message queued"){bulk.queuedID != nil}
        let bulkJob = try service.mailSendJob(bulk.queuedID!)
        try check(try service.mailSendSummary(bulkJob).to == bulkAddresses,"actual composer retains all1501 recipients")
        try check(try service.mailSendBody(bulkJob) == bulkBody.replacingOccurrences(of:"\n",with:"\r\n"),"actual composer retains larger Japanese body across batch boundaries")
        let longName = try NativeMailComposeWindow(service:service,accountID:accountID)
        try field("宛先（To）",longName.window).stringValue = String(repeating:"a",count:4097)+" <person@example.test>"
        try field("件名",longName.window).stringValue = "表示名の確認"
        try click("送信",longName.window); try wait("display-name validation settled"){try button("送信",longName.window).isEnabled}
        try check(try longName.queuedID == nil && field("メール作成の結果",longName.window).stringValue.contains("表示名"),"Japanese validation identifies display name rather than subject")
        print("NativeMailComposeHistoryUITests: \(checks) checks passed; compose/reply/forward, immutable send, protected body, uncertainty review, retry/cancel and paging")
    }
}
