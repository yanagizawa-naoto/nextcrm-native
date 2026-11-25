import AppKit

enum GoogleCalendarRuntimeUITests {
    typealias UI = GoogleCalendarSettingsUITests
    final class Transport {
        private let lock = NSLock(); private var total = 0, fail = false
        var count: Int { lock.lock(); defer{lock.unlock()}; return total }
        func setFailure(_ value: Bool) { lock.lock(); defer{lock.unlock()}; fail = value }
        func send(_ request: URLRequest) async throws -> (Data,HTTPURLResponse) {
            let state: (Int,Bool) = snapshot()
            let body: [String:Any] = state.1 ? ["error":["errors":[["reason":"rateLimitExceeded"]]]] : ["items":[["id":"runtime-meeting","summary":"日本語の同期予定","start":["dateTime":"2027-01-15T10:00:00.000Z"],"attendees":[["email":"client@external.invalid"]]]],"nextSyncToken":"runtime-\(state.0)"]
            return (try JSONSerialization.data(withJSONObject:body),HTTPURLResponse(url:request.url!,statusCode:state.1 ? 429 : 200,httpVersion:nil,headerFields:nil)!)
        }
        private func snapshot() -> (Int,Bool) { lock.lock(); defer{lock.unlock()}; total += 1; return (total,fail) }
    }
    static func run(_ resources: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-GoogleRuntimeUI-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let db = try NativeDatabase(url:root.appendingPathComponent("crm.sqlite"),schemaURL:resources.appendingPathComponent("schema.json"),sqlURL:resources.appendingPathComponent("schema.sql"))
        let service = CRMService(db:db,identity:try CRMService.bootstrap(db,resources:resources.appendingPathComponent("../../prisma"))), store = UI.Store(), transport = Transport()
        let runtime = GoogleCalendarRuntime(db:db,store:store,request:transport.send,interval:0.3); defer{runtime.stop()}
        runtime.resume(); try UI.wait("empty calendar runtime finishes scan"){!runtime.isScanning}
        try UI.check(runtime.nextScan == nil && transport.count == 0,"no connections means no periodic scan or transport")
        try service.saveGoogleCalendarClient(clientID:"runtime-test.apps.googleusercontent.com",clientSecret:"fake-runtime-secret",store:store)
        let ticket = try service.beginGoogleCalendarAuthorization(expected:nil,requested:.readonly,store:store)
        let connection = try service.completeGoogleCalendarAuthorization(ticket,grant:.init(accountEmail:"rep@example.invalid",accessToken:"fake-runtime-access",refreshToken:"fake-runtime-refresh",expiresAt:Date().addingTimeInterval(3600),grantedScopes:GoogleCalendarScope.read),store:store)
        _ = try db.insert("crm_Targets",values:["last_name":.text("予定の顧客"),"email":.text("client@external.invalid")],actor:service.identity.id)
        let panel = try GoogleCalendarSettingsWindow(service:service,store:store,authorize:{_,_,_ in throw NativeDBError.conflict}); let window = panel.window
        window.setFrameOrigin(.init(x:-10000,y:-10000)); try UI.ready(window); UI.table(window).selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try UI.click("選択した接続を同期",window)
        try UI.wait("manual calendar sync done"){try service.googleCalendarSyncJob(connection["id"].string)?.status == "done"}; try UI.ready(window)
        try UI.wait("UI reflects successful sync"){try UI.field("選択したカレンダーの同期状況",window).stringValue.contains("同期完了")}
        try UI.check(try db.page("crm_CalendarEvents",fields:[]).total == 1 && transport.count == 1,"actual runner imports manual sync and updates Japanese UI")
        try UI.layout(window)
        runtime.resume(); try UI.wait("periodic sync scheduled"){!runtime.isScanning && runtime.nextScan != nil}
        try UI.wait("periodic sync fires"){try transport.count >= 2 && service.googleCalendarSyncJob(connection["id"].string)?.status == "done"}
        runtime.stop(); let stoppedCount = transport.count; RunLoop.current.run(until:Date().addingTimeInterval(0.5))
        try UI.check(runtime.nextScan == nil && transport.count == stoppedCount,"stop cancels recurring scan and does not poll")
        let queued = try service.requestGoogleCalendarSync(service.googleCalendarConnection(connection["id"].string)); RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        try UI.check(try db.job(id:queued)?.status == "pending" && transport.count == stoppedCount,"stopped runner leaves new job durably queued")
        let restarted = GoogleCalendarRuntime(db:db,store:store,request:transport.send); defer{restarted.stop()}; restarted.resume()
        try UI.wait("restart resumes durable job"){try db.job(id:queued)?.status == "done"}
        // DB completion precedes the runner's MainActor didProcess notification.
        // Let that notification start the window reload before ready() observes it.
        try UI.wait("restart runner and notification settled"){!restarted.isRunning && !restarted.isScanning}
        try UI.check(try db.page("crm_CalendarEvents",fields:[]).total == 1 && transport.count > stoppedCount,"runtime restart resumes without duplicate CRM activity")
        try UI.ready(window); try UI.wait("manual sync enabled"){try UI.button("選択した接続を同期",window).isEnabled}
        transport.setFailure(true); try UI.click("選択した接続を同期",window)
        try UI.wait("temporary failure shown"){try UI.field("選択したカレンダーの同期状況",window).stringValue.contains("再試行待ち")}; try UI.ready(window)
        let retry = try service.googleCalendarSyncJob(connection["id"].string)!
        try UI.check(try service.googleCalendarConnection(connection["id"].string)["isActive"] == .integer(1) && retry.status == "retry","rate limit leaves connection active and displays retry")
        transport.setFailure(false); try UI.click("選択した接続を同期",window)
        try UI.wait("manual retry done"){try db.job(id:retry.id)?.status == "done"}
        try UI.check(try db.job(id:retry.id)?.attempts == 2 && service.googleCalendarSyncJob(connection["id"].string)?.id == retry.id,"UI manual retry preserves job identity")
        try service.disconnectGoogleCalendar(service.googleCalendarConnection(connection["id"].string),store:store)
        restarted.resume(); try UI.wait("removed last connection stops timer"){!restarted.isScanning}
        try UI.check(restarted.nextScan == nil,"no periodic timer after last connection removed")
    }
}
