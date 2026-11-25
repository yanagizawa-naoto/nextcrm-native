import AppKit

enum CampaignOperationsUITests {
    typealias UI = CampaignDeliveryUITests
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool,_ label: String) throws { guard try value() else { throw NativeDBError.message("CampaignOperationsUI FAIL: "+label) }; checks += 1 }
    final class Probe {
        enum Mode { case ready, unavailable, delayed }
        let lock = NSLock(); private var mode = Mode.ready; private var calls = 0
        func set(_ value: Mode) { lock.lock(); defer { lock.unlock() }; mode = value }
        func begin() -> Mode { lock.lock(); defer { lock.unlock() }; calls += 1; return mode }
        func validate() async throws { switch begin() { case .ready:return; case .unavailable:throw NativeDBError.message("テスト用：接続設定を確認してください。"); case .delayed:try await Task.sleep(nanoseconds:2_000_000_000); try Task.checkCancellation() } }
    }
    static func text(_ label: String,_ window: NSWindow) -> NSTextField { UI.views(window.contentView!).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel() == label}! }
    static func launchReady(_ window: NSWindow,_ button: String) throws { try UI.wait("launch summary"){try UI.button(button,window).isEnabled} }
    static func run(_ resources: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-CampaignOperationsUI-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let identity = try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma")), service = CRMService(db:db,identity:identity), probe = Probe()
        let template = try service.saveCampaignTemplate(nil,input:["name":.text("予約の案内"),"subject_default":.text("ご案内"),"content_html":.text("<p>日本語のお知らせ</p>")])
        let target = try db.insert("crm_Targets",values:["last_name":.text("山田"),"email":.text("operations@example.invalid"),"created_by":.text(identity.id)],actor:identity.id)
        let list = try db.insert("crm_TargetLists",values:["name":.text("確認用"),"created_by":.text(identity.id)],actor:identity.id)
        _ = try db.insert("TargetsToTargetLists",values:["target_id":target["id"],"target_list_id":list["id"]],actor:identity.id)
        let campaign = try service.createCampaign(input:["name":.text("日本語の予約操作😀")],targetListIDs:[list["id"].string],steps:[.init(order:0,templateID:template["id"].string,subject:"初回の案内"),.init(order:1,templateID:template["id"].string,subject:"後日の案内",delayDays:1)])
        let id = campaign["id"].string
        let parent = try CRMCampaignWindow(campaign:campaign,service:service,readiness:{try await probe.validate()}); parent.window.setFrameOrigin(.init(x:-10000,y:-10000)); defer { parent.window.orderOut(nil) }; try UI.ready(parent.window)
        parent.window.contentView!.layoutSubtreeIfNeeded()
        for b in UI.views(parent.window.contentView!).compactMap({$0 as? NSButton}).filter({!$0.isHiddenOrHasHiddenAncestor}) { let rect = b.convert(b.bounds,to:parent.window.contentView); try check(rect.minX >= -1 && rect.maxX <= parent.window.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= parent.window.contentView!.bounds.height+1,"campaign action fits: "+b.title) }
        try check(try UI.button("今すぐ送信…",parent.window).isEnabled && UI.button("日時を指定して予約…",parent.window).isEnabled && !UI.button("送信を再開…",parent.window).isEnabled,"draft action gating")
        try UI.click("日時を指定して予約…",parent.window); try UI.wait("schedule panel"){parent.window.attachedSheet != nil}; let schedule = parent.window.attachedSheet!; try launchReady(schedule,"日時を指定して予約")
        try check(text("送信前の対象件数",schedule).stringValue.contains("対象候補：1件") && text("送信前の対象件数",schedule).stringValue.contains("配信手順：2件"),"Japanese review summarizes audience and sequence")
        let picker = UI.views(schedule.contentView!).compactMap{$0 as? NSDatePicker}.first!
        picker.dateValue = Date().addingTimeInterval(-60); try UI.click("日時を指定して予約",schedule)
        try UI.wait("past date rejected"){text("送信登録の結果",schedule).stringValue.contains("現在より後")}
        try check(try service.campaign(id)["status"] == .text("draft") && db.campaignJobCount(id,events:CampaignWorkflow.dispatchEvents) == 0,"past date queues no work")
        picker.dateValue = Date().addingTimeInterval(3600); let due = picker.dateValue
        schedule.contentView!.layoutSubtreeIfNeeded()
        for control in UI.views(schedule.contentView!).compactMap({$0 as? NSControl}).filter({!$0.isHiddenOrHasHiddenAncestor}) { let rect = control.convert(control.bounds,to:schedule.contentView); try check(rect.minX >= -1 && rect.maxX <= schedule.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= schedule.contentView!.bounds.height+1,"schedule control fits") }
        try UI.click("日時を指定して予約",schedule); try UI.wait("schedule committed"){try parent.window.attachedSheet == nil && service.campaign(id)["status"] == .text("scheduled")}; try UI.ready(parent.window)
        try check(try abs(CampaignWorkflow.date(service.campaign(id)["scheduled_at"])!.timeIntervalSince(due)) < 0.002,"native date picker stores requested instant")
        let dispatch = CampaignDispatchWorker(db:db)
        var ranEarly = true; try UI.worker { ranEarly = try await dispatch.runNext(); return ranEarly }
        try check(!ranEarly && (try db.page("crm_campaign_sends",fields:[]).total) == 0,"future schedule does not send early")
        try UI.wait("pause enabled"){try UI.button("一時停止…",parent.window).isEnabled}; try UI.click("一時停止…",parent.window); try UI.wait("pause confirmation"){parent.window.attachedSheet != nil}
        try UI.click("一時停止",parent.window.attachedSheet!); try UI.wait("paused"){try service.campaign(id)["status"] == .text("paused")}; try UI.ready(parent.window)
        try UI.wait("resume enabled"){try UI.button("送信を再開…",parent.window).isEnabled}; try UI.click("送信を再開…",parent.window); try UI.wait("resume panel"){parent.window.attachedSheet != nil}; let resume = parent.window.attachedSheet!; try launchReady(resume,"送信を再開")
        probe.set(.unavailable); try UI.click("送信を再開",resume); try UI.wait("readiness error visible"){text("送信登録の結果",resume).stringValue.contains("接続設定を確認")}
        try check(try service.campaign(id)["status"] == .text("paused") && db.campaignJobCount(id,events:CampaignWorkflow.dispatchEvents) == 1,"failed readiness leaves one old schedule only")
        probe.set(.delayed); try UI.click("送信を再開",resume); try UI.click("確認を中止",resume); try UI.wait("readiness cancelled"){text("送信登録の結果",resume).stringValue.contains("確認を中止しました")}
        try check(try service.campaign(id)["status"] == .text("paused") && db.campaignJobCount(id,events:CampaignWorkflow.dispatchEvents) == 1,"cancelled readiness queues no work")
        probe.set(.ready); try UI.click("送信を再開",resume); try UI.wait("resume committed"){try parent.window.attachedSheet == nil && service.campaign(id)["status"] == .text("sending")}
        let provider = UUID().uuidString.lowercased(); var outbound = 0
        let mail = CampaignMailWorker(db:db,account:{.init(from:"sender@example.invalid",apiKey:"fake-key")},configuration:{try .init(publicURL:"https://example.invalid")},endpointReady:{_,_ in},request:{ request,_ in outbound += 1; return (try JSONSerialization.data(withJSONObject:["id":provider]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!) })
        let dispatchRunner = InvoiceJobRunner(db:db,events:CampaignWorkflow.dispatchEvents,runNext:{try await dispatch.runNext()}), mailRunner = InvoiceJobRunner(db:db,events:[CampaignWorkflow.sendStepEvent],runNext:{try await mail.runNext()})
        var stopped = false
        defer { if !stopped { DispatchQueue.main.async { dispatchRunner.stop(); mailRunner.stop() } } }
        DispatchQueue.main.async { dispatchRunner.kick(); mailRunner.kick() }
        try UI.wait("actual runners complete initial send"){try service.campaign(id)["status"] == .text("sent")}
        try UI.wait("detail refreshes after runner"){UI.views(parent.window.contentView!).compactMap{$0 as? NSTextField}.contains{$0.stringValue.contains("初回配信処理済み")}}
        try check(outbound == 1,"launch through actual runners sends one fake mail")
        try UI.ready(parent.window); try UI.click("送信履歴…",parent.window); try UI.wait("recipient history"){parent.window.attachedSheet != nil}; let history = parent.window.attachedSheet!; try UI.ready(history)
        try check(text("配信結果の同期状況",history).stringValue.contains("受信窓口が未設定"),"unconfigured receiver state is visible")
        let client = try CampaignRelayBinding.clientID(db:db); try CampaignRelayBinding(publicURL:"https://example.invalid/",clientID:client,instanceID:UUID().uuidString.lowercased(),cursor:0).save(db:db)
        // The UI test uses a fake receiver job; signed transport and the actual
        // sync worker are exercised by the separate real-loopback backend suite.
        let syncRunner = InvoiceJobRunner(db:db,events:[CampaignRelayJobs.event],runNext:{
            guard let job = try db.claimJob(events:[CampaignRelayJobs.event]) else { return false }
            _ = try db.receiveCampaignEvent(id:"ui-delivered",providerID:provider,kind:"email.delivered",bodySHA256:String(repeating:"d",count:64))
            try db.transaction { try db.setMetadata(CampaignRelayJobs.lastSuccess,value:CampaignWorkflow.stamp(Date())); try db.finishJob(job,result:["applied":"1"]) }; return true
        })
        defer { DispatchQueue.main.async { syncRunner.stop() } }
        try UI.click("配信結果を同期",history)
        try UI.wait("sync completion visible"){text("配信結果の同期状況",history).stringValue.contains("同期完了")}
        UI.table(history).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let detail = UI.views(history.contentView!).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel() == "選択したメールの送信記録"}!
        try UI.wait("delivery refreshed"){detail.string.contains("到着確認済み")}
        try check(outbound == 1,"explicit sync refresh does not resend mail")
        try UI.click("閉じる",history); try UI.wait("recipient history closes"){parent.window.attachedSheet == nil}; try UI.ready(parent.window)
        try UI.click("配信予約・処理履歴…",parent.window); try UI.wait("dispatch history"){parent.window.attachedSheet != nil}; let jobs = parent.window.attachedSheet!; try UI.ready(jobs)
        let page = try service.campaignDispatchJobs(id); let row = page.rows.firstIndex{$0.event == CampaignWorkflow.followUpEvent}!
        let oldSchedule = page.rows.firstIndex{$0.event == CampaignWorkflow.scheduleEvent}!
        UI.table(jobs).selectRowIndexes(IndexSet(integer:oldSchedule),byExtendingSelection:false)
        let dispatchDetail = UI.views(jobs.contentView!).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel() == "配信予約の処理状況"}!
        try check(dispatchDetail.string.contains("変更・停止により対象外") && dispatchDetail.string.contains("実行・再試行予定：—"),"superseded reservation is visibly inactive with no future send time")
        try check(try !UI.button("予約を取り消して全体停止…",jobs).isEnabled && !UI.button("選択した処理を再試行",jobs).isEnabled,"superseded reservation cannot stop the current run")
        UI.table(jobs).selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        try check(UI.table(jobs).numberOfRows == 3,"dispatch history excludes recipient jobs")
        try UI.click("予約を取り消して全体停止…",jobs); try UI.wait("whole-campaign stop confirmation"){jobs.attachedSheet != nil}; try UI.click("予約を取り消して全体停止",jobs.attachedSheet!)
        try UI.wait("followup cancelled"){try service.campaign(id)["status"] == .text("paused") && db.job(id:page.rows[row].id)?.status == "cancelled"}
        try check(outbound == 1,"cancelling future followup leaves earlier mail intact")
        try UI.ready(jobs); try UI.click("閉じる",jobs); try UI.wait("dispatch history closes"){parent.window.attachedSheet == nil}
        DispatchQueue.main.async { dispatchRunner.stop(); mailRunner.stop(); syncRunner.stop(); stopped = true }
        try UI.wait("runners stopped"){stopped}
        let retryDraft = try service.createCampaign(input:["name":.text("予約の再試行")],steps:[.init(order:0,templateID:template["id"].string,subject:"再試行")]), retryCampaign = try service.sendCampaignNow(retryDraft)
        let claimed = try db.claimJob(events:CampaignWorkflow.dispatchEvents)!
        try db.failJob(claimed,message:"テスト用の中断")
        let retryUI = try CampaignDispatchWindow(service:service,campaignID:retryCampaign["id"].string); defer { retryUI.window.orderOut(nil) }; try UI.ready(retryUI.window); UI.table(retryUI.window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try UI.click("選択した処理を再試行",retryUI.window); try UI.wait("dispatch retry queued"){try db.job(id:claimed.id)?.status == "pending"}
        try check(try db.campaignJobCount(retryCampaign["id"].string,events:CampaignWorkflow.dispatchEvents) == 1,"dispatch retry keeps the original command")
        print("CampaignOperationsUITests: \(checks) checks passed; Japanese launch/schedule/pause/resume/cancel, actual dispatch+mail runners and fake receiver UI refresh")
    }
}
