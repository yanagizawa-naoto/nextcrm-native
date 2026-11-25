import AppKit

/// Exercises the production controls without ordering a window onto the user's
/// desktop. Data is temporary, and this executable never creates a mail runtime.
@main enum ProjectNotificationUITests {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NativeDBError.message("FAIL: "+label) }; checks += 1
    }
    static func views(_ root: NSView) -> [NSView] { [root]+root.subviews.flatMap(views) }
    static func button(_ title: String, in window: NSWindow) throws -> NSButton {
        guard let button = views(window.contentView!).compactMap({ $0 as? NSButton }).first(where:{ $0.title == title }) else { throw NativeDBError.message("Missing button: "+title) }
        return button
    }
    static func table(_ window: NSWindow) throws -> NSTableView {
        guard let table = views(window.contentView!).compactMap({ $0 as? NSTableView }).first else { throw NativeDBError.message("Missing table") }; return table
    }
    static func text(_ window: NSWindow) -> String {
        views(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSTextView)?.string }.joined(separator:"\n")
    }
    static func click(_ title: String, in window: NSWindow) throws { try button(title,in:window).performClick(nil) }
    static func select(_ row: Int, in window: NSWindow) throws { try table(window).selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
    static func main() {
        do { try run() } catch { FileHandle.standardError.write(Data("ProjectNotificationUITests: \(error)\n".utf8)); exit(1) }
    }
    static func run() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath:CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-ProjectNotificationUI-"+UUID().uuidString)
        defer { NSApp.windows.forEach { $0.orderOut(nil) }; try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))
        let admin = CRMService(db:db,identity:identity)
        func user(_ name: String) throws -> CRMService {
            let row = try db.insert("Users",values:["name":.text(name),"email":.text(name+"@example.invalid"),"role":.text("user"),"userStatus":.text("ACTIVE")],actor:identity.id)
            return CRMService(db:db,identity:CRMIdentity(id:row["id"].string,role:"user",partnerAccountID:nil))
        }
        let recipient = try user("recipient"); let stranger = try user("stranger")
        let board = try admin.saveProject(original:nil,input:["title":.text("通知画面の検証"),"description":.text("架空のデータ"),"visibility":.text("public")])
        func task(_ title: String) throws -> NativeRecord {
            try admin.createProjectTaskInBoard(board["id"].string,input:["title":.text(title),"user":.text(recipient.identity.id),"content":.text("日本語の内容")])
        }
        try db.transaction { for i in 0..<101 { _ = try task("ページ検証 \(i)") } }
        let history = try CRMInvoiceJobsWindow(service:admin,invoice:board)
        try check(history.window.title == "プロジェクトの通知状況","Japanese project window title")
        try check(try table(history.window).numberOfRows == 100,"history first page is bounded to 100")
        try check(try button("次へ",in:history.window).isEnabled && !button("前へ",in:history.window).isEnabled,"first page navigation")
        try click("次へ",in:history.window)
        try check(try table(history.window).numberOfRows == 1 && text(history.window).contains("101–101件"),"next page retains exact row count")
        let oldest = try admin.projectBoardJobs(boardID:board["id"].string,offset:100)[0]
        try select(0,in:history.window)
        try check(try button("予約を取消",in:history.window).isEnabled && !button("再試行",in:history.window).isEnabled,"pending notification actions")
        try click("予約を取消",in:history.window)
        try check(try db.job(id:oldest.id)?.status == "cancelled" && text(history.window).contains("取消済み"),"cancel button persists and refreshes selected status")
        try click("前へ",in:history.window)
        try check(try table(history.window).numberOfRows == 100,"previous page restores first 100 rows")
        for row in try admin.projectBoardJobs(boardID:board["id"].string) { try admin.cancelProjectJob(row.id) }

        let work = try task("日本語の通知と再試行")
        let claim = try db.claimJob(events:CRMService.projectJobEvents)!
        try db.failJob(claim,message:"模擬の設定エラー")
        let taskHistory = try CRMInvoiceJobsWindow(service:admin,invoice:work)
        try check(taskHistory.window.title == "タスクの通知状況","Japanese task window title")
        try select(0,in:taskHistory.window)
        try check(try button("再試行",in:taskHistory.window).isEnabled && text(taskHistory.window).contains("模擬の設定エラー"),"failed task notice exposes retry and error")
        try click("再試行",in:taskHistory.window)
        try check(try db.job(id:claim.id)?.status == "pending" && !button("再試行",in:taskHistory.window).isEnabled,"retry button schedules exactly the existing job")
        let running = try db.claimJob(events:CRMService.projectJobEvents)!
        try db.recordJobResult(running,result:["to":"recipient@example.invalid","subject":"日本語の通知"])
        let delivery = try db.markJobDeliveryStarted(running)
        try db.failJob(delivery,message:"模擬の結果不明",needsReview:true)
        taskHistory.start(); try select(0,in:taskHistory.window)
        try check(try button("確認結果を記録…",in:taskHistory.window).isEnabled && !button("予約を取消",in:taskHistory.window).isEnabled,"ambiguous send offers review without cancellation")
        let reviewJob = try db.job(id:claim.id)!
        let review = CRMJobReviewWindow(service:admin,job:reviewJob)
        try check(text(review.window).contains("nextcrm/project/"+claim.id),"review displays project idempotency key")
        try check(text(review.window).contains("タスクの状態は変更しません。"),"review uses task-specific explanation")
        let outcome = views(review.window.contentView!).compactMap { $0 as? NSPopUpButton }.first!
        outcome.selectItem(at:2); NSApp.sendAction(outcome.action!,to:outcome.target,from:outcome)
        let note = views(review.window.contentView!).compactMap { $0 as? NSTextView }.first!
        note.string = "日本語の確認結果。\n模擬送信の結果は不明でした。"
        try click("記録して終了",in:review.window)
        try check(try db.job(id:claim.id)?.result["reviewOutcome"] == "unknown","review save button persists Japanese result")
        taskHistory.start(); try select(0,in:taskHistory.window)
        try check(text(taskHistory.window).contains("結果不明・終了") && text(taskHistory.window).contains(note.string),"history renders saved review and memo")
        try check(try !button("確認結果を記録…",in:taskHistory.window).isEnabled && !button("再試行",in:taskHistory.window).isEnabled,"resolved review is immutable in UI")

        let readerHistory = try CRMInvoiceJobsWindow(service:stranger,invoice:board)
        try check(try table(readerHistory.window).numberOfRows == 0,"unrelated reader sees no recipient history")
        let ownHistory = try CRMInvoiceJobsWindow(service:recipient,invoice:work)
        try check(try table(ownHistory.window).numberOfRows == 1,"recipient sees own task history")
        let recipientRow = try db.get("Users",key:["id":.text(recipient.identity.id)])!
        _ = try db.update(recipientRow,changes:["banned":.integer(1)],actor:identity.id)
        ownHistory.start()
        try check(try table(ownHistory.window).numberOfRows == 0 && !button("再試行",in:ownHistory.window).isEnabled,"revoked access clears history and actions")
        _ = try db.update(db.get("Users",key:["id":.text(recipient.identity.id)])!,changes:["banned":.integer(0)],actor:identity.id)
        try admin.deleteProjectTask(work); history.start()
        try check(try table(history.window).numberOfRows == 100,"project history survives task deletion")

        let project = CRMProjectWindow(project:board,service:admin)
        try check(try button("通知状況…",in:project.window).title == "通知状況…","project exposes notification history")
        let overview = CRMTaskOverviewWindow(service:admin,mine:false)
        try check(try button("通知状況…",in:overview.window).title == "通知状況…","task overview exposes notification history")
        let settings = try CRMInvoiceMailSettingsWindow(service:admin,store:UITestCredentials())
        try check(text(settings.window).contains("タスクの通知"),"shared settings explain task notifications")

        // Exercise the exact runtime and wake scheduler used by CRMApp. The
        // isolated marker forces the built-in fake transport and fake store.
        try "NextCRM isolated mail QA\n".write(to:root.appendingPathComponent(".native-mail-test"),atomically:true,encoding:.utf8)
        setenv("NEXTCRM_NATIVE_DATA_DIR",root.path,1); setenv("NEXTCRM_NATIVE_MAIL_TEST_MODE","success",1)
        let runtime = try InvoiceMailRuntime(db:db)
        let worker = runtime.projectWorker
        let runner = InvoiceJobRunner(db:db,events:CRMService.projectJobEvents,runNext:{ try await worker.runNext() })
        defer { runner.stop() }
        var runtimeError: Error?; runner.onError = { runtimeError = $0 }
        runner.kick()
        let warmupEnd = Date().addingTimeInterval(5)
        while runner.isRunning && Date() < warmupEnd { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        try check(!runner.isRunning && runner.nextWake == nil,"idle project runner schedules no polling")
        let automatic = try task("アプリの通知実行経路")
        let automaticJob = try admin.projectJobs(taskID:automatic["id"].string)[0]
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if try db.job(id:automaticJob.id)?.status == "done", !runner.isRunning { break }
            RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
        try check(runtime.isQA && runtimeError == nil && (try db.job(id:automaticJob.id))?.result["outcome"] == "sent","transaction notification wakes production project runtime")
        try check(try db.metadata("qaMailSend."+automaticJob.id) == "1","production fake transport invoked once")
        let send = try JSONSerialization.jsonObject(with:Data(db.metadata("qaMailSend.last")!.utf8)) as! [String:Any]
        try check(send["network"] as? Bool == false && (send["subject"] as? String)?.contains("アプリの通知実行経路") == true,"runtime uses Japanese template and isolated transport")
        try check(runner.nextWake == nil,"completed project runner releases wake timer")
        try check(NSApp.windows.allSatisfy { !$0.isVisible },"all production UI checks keep windows off screen")
        print("Project notification UI: \(checks) checks passed; offscreen controls, temporary data, no transport")
    }
}

private final class UITestCredentials: InvoiceMailCredentialStore {
    func load(interactive: Bool) throws -> InvoiceMailAccount? { nil }
    func save(_ account: InvoiceMailAccount) throws {}
    func remove() throws {}
}
