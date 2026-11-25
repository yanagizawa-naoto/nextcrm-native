import AppKit

enum GoogleCalendarPushUITests {
    typealias UI = GoogleCalendarSettingsUITests
    final class Transport {
        private let lock = NSLock()
        private var events: [String:[String:Any]] = [:], mutations: [String] = []
        var writes: [String] { lock.lock(); defer{lock.unlock()}; return mutations }
        func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) { try respond(request) }
        private func respond(_ request: URLRequest) throws -> (Data,HTTPURLResponse) {
            lock.lock(); defer{lock.unlock()}
            let method = request.httpMethod ?? "GET", id = request.url!.lastPathComponent
            var body: [String:Any] = [:], status = 200
            if method == "GET", id == "events" { body = ["items":[],"nextSyncToken":"push-ui-cursor"] }
            else if method == "GET" { if let event = events[id] { body = event } else { status = 404 } }
            else {
                let input = try request.httpBody.map{try JSONSerialization.jsonObject(with:$0) as! [String:Any]} ?? [:]
                if method == "POST" { body = input; let newID = input["id"] as! String; body["etag"] = "v1"; events[newID] = body }
                else if method == "PATCH" { guard let old = events[id], request.value(forHTTPHeaderField:"If-Match") == old["etag"] as? String else { throw NativeDBError.conflict }; body = old.merging(input){_,new in new}; body["etag"] = "v\(mutations.count+1)"; events[id] = body }
                else if method == "DELETE" { events.removeValue(forKey:id); status = 204 }
                else { throw NativeDBError.conflict }
                mutations.append(method)
            }
            return (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        }
    }
    static func run(_ resources: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GooglePushUI-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = UI.Store(), transport = Transport()
        try service.saveGoogleCalendarClient(clientID:"push-ui.apps.googleusercontent.com",clientSecret:"fake-secret",store:store)
        let ticket = try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readwrite,store:store)
        _ = try service.completeGoogleCalendarAuthorization(ticket,grant:.init(accountEmail:"push-ui@example.invalid",accessToken:"fake-access",refreshToken:"fake-refresh",expiresAt:Date().addingTimeInterval(3600),grantedScopes:GoogleCalendarScope.readwrite.requested),store:store)
        let runtime = GoogleCalendarRuntime(db:db,store:store,request:transport.send); defer{runtime.stop()}; runtime.resume()
        let module = CRMModule.all.first{$0.model == "crm_Activities"}!
        var activity = try service.save(module,original:nil,input:["title":.text("日本語のカレンダー反映"),"type":.text("meeting"),"date":.text(try NativeCalendarEvents.stamp(Date().addingTimeInterval(86400))),"status":.text("scheduled")])
        try UI.wait("runtime creates meeting"){try db.calendarOutboundMapping(activityID:activity["id"].string) != nil}
        try UI.check(transport.writes == ["POST"],"saving native CRM meeting automatically creates one remote event")
        activity = try service.save(module,original:activity,input:["title":.text("変更した日本語の会議")])
        try UI.wait("runtime patches meeting"){transport.writes.count == 2}
        try UI.wait("patch job completes"){try service.googleCalendarPushPage().rows.allSatisfy{$0.job.status == "done"}}
        activity = try service.save(module,original:activity,input:["status":.text("cancelled")])
        try UI.wait("runtime cancels meeting"){try db.calendarOutboundMapping(activityID:activity["id"].string)?["status"] == .text("cancelled")}
        try UI.check(transport.writes == ["POST","PATCH","DELETE"],"runtime handles native save update and cancellation")
        let settings = try GoogleCalendarSettingsWindow(service:service,store:store), window = settings.window
        window.setFrameOrigin(.init(x:-10000,y:-10000)); try UI.ready(window); try UI.click("Googleへの反映履歴…",window)
        try UI.wait("history sheet opens"){window.attachedSheet != nil}; let history = window.attachedSheet!; try UI.ready(history)
        try UI.check(history.title == "Googleへの予定の反映履歴" && UI.table(history).numberOfRows == 3 && !settings.confirmDiscard(),"settings opens owned Japanese history and respects attached sheet")
        UI.table(history).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try UI.wait("history detail loaded"){UI.views(history.contentView!).compactMap{$0 as? NSTextView}.contains{$0.string.contains("push-ui@example.invalid")}}
        try UI.check(!(try UI.button("結果を再確認・再試行",history)).isEnabled && !UI.text(history).contains("fake-access"),"completed job cannot retry and secrets are not rendered")
        try UI.layout(history); try UI.layout(window)
        runtime.stop(); RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        let retryID = try db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activity["id"].string,"operation":"upsert"]), retryLease = try db.claimCalendarOutboundJob()!
        try db.failJob(retryLease,message:"検証用の一時エラー",needsReview:true)
        try UI.click("再読み込み",history); try UI.ready(history); UI.table(history).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try UI.wait("retry control ready"){try UI.button("結果を再確認・再試行",history).isEnabled}
        try UI.click("結果を再確認・再試行",history); try UI.ready(history)
        try UI.check(try db.job(id:retryID)?.status == "pending","retry UI durably requeues original ID while runtime stopped")
        let restarted = GoogleCalendarRuntime(db:db,store:store,request:transport.send); defer{restarted.stop()}; restarted.resume()
        try UI.wait("restarted runtime handles retry"){try db.job(id:retryID)?.status == "done"}; restarted.stop(); RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        let reviewID = try db.enqueue(GoogleCalendarOutbound.event,payload:["activity_id":activity["id"].string,"operation":"upsert"]), reviewLease = try db.claimCalendarOutboundJob()!
        try db.recordJobResult(reviewLease,result:["requestOutcome":"unknown"]); try db.failJob(reviewLease,message:"検証用の結果未確定",needsReview:true)
        try UI.click("再読み込み",history); try UI.ready(history); UI.table(history).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try UI.wait("manual review control ready"){try UI.button("Googleで未反映と確認…",history).isEnabled}
        try UI.click("Googleで未反映と確認…",history); try UI.wait("review confirmation opens"){history.attachedSheet != nil}
        history.endSheet(history.attachedSheet!,returnCode:.alertSecondButtonReturn); try UI.wait("review cancel closes"){history.attachedSheet == nil}
        try UI.check(try db.job(id:reviewID)?.status == "needs_review","cancel leaves review hold intact")
        try UI.click("Googleで未反映と確認…",history); try UI.wait("review confirmation reopens"){history.attachedSheet != nil}
        let confirmation = history.attachedSheet!; try UI.field("未反映と確認した内容",confirmation).stringValue = "Googleで未反映を確認しました"
        history.endSheet(confirmation,returnCode:.alertFirstButtonReturn)
        try UI.wait("manual review recorded"){try db.job(id:reviewID)?.result["requestOutcome"] == "reviewedNotApplied"}; try UI.ready(history)
        let reviewed = try db.job(id:reviewID)!, followup = try db.job(id:reviewed.result["followUpJob"]!)!
        try UI.check(followup.status == "pending" && reviewed.result["reviewNote"] == "Googleで未反映を確認しました","Japanese review records note and one new durable job")
        try UI.check(transport.writes == ["POST","PATCH","DELETE"],"history review and retry of already cancelled event add no remote writes")
        try UI.click("閉じる",history); try UI.wait("history closes"){window.attachedSheet == nil}; try UI.ready(window)
        try UI.check(settings.confirmDiscard(),"history controller released and parent can close")
    }
}
