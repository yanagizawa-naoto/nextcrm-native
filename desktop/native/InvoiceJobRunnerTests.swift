import Foundation

extension InvoiceMailTests {
    static func runnerTests(service: CRMService, invoice: NativeRecord) async throws {
        let db = service.db
        let event = "test.schedule"
        try check(try db.nextJobDate(events:[event]) == nil,"no wake when there is no scheduled work")
        let id = try db.enqueue(event,payload:[:]); let now = Date(timeIntervalSince1970:1_800_000_000.25)
        try check(try db.nextJobDate(events:[event],now:now) == now,"pending job wakes immediately")
        let running = try db.claimJob(events:[event],now:now,leaseSeconds:20)!
        try check(abs(try db.nextJobDate(events:[event])!.timeIntervalSince(now)-20) < 0.01,"running lease schedules recovery")
        try db.failJob(running,message:"wait",retryAt:now.addingTimeInterval(60))
        try check(abs(try db.nextJobDate(events:[event])!.timeIntervalSince(now)-60) < 1.01,"retry schedules due time")
        try db.cancelJob(id:id)
        try check(try db.nextJobDate(events:[event]) == nil,"cancel removes scheduled wake")
        func queue() throws -> String { try service.queueInvoiceEmail(service.invoiceAccess(invoice),from:"billing@example.invalid",to:"scheduler@example.invalid",subject:"自動実行の検証",message:"架空のメール",now:Date()) }
        let queued = try queue(); var calls = 0
        let worker = InvoiceJobWorker(db:db,apiKey:{ "scheduler-fake-key" },request:{ query,_ in
            calls += 1; let status = calls == 1 ? 503 : 200
            let body = try JSONSerialization.data(withJSONObject:status == 200 ? ["id":UUID().uuidString] : ["name":"fake_error"])
            return (body,HTTPURLResponse(url:query.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
        })
        let runner = await MainActor.run { InvoiceJobRunner(db:db,worker:worker) }
        await MainActor.run { runner.kick() }
        func waitFor(_ id: String, _ status: String, seconds: Double = 12) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if try db.job(id:id)?.status == status { return }; try await Task.sleep(nanoseconds:25_000_000) }
            throw NativeDBError.message("FAIL waiting for scheduled job "+status)
        }
        try await waitFor(queued,"retry")
        try await Task.sleep(nanoseconds:100_000_000)
        let scheduled = await MainActor.run { runner.nextWake != nil }
        try check(scheduled,"runner schedules retry without manual refresh")
        try await waitFor(queued,"done")
        try await Task.sleep(nanoseconds:100_000_000)
        let idle = await MainActor.run { !runner.isRunning && runner.nextWake == nil }
        try check(idle && calls == 2,"retry completes and idle runner has no timer")
        let notified = try queue()
        try await waitFor(notified,"done")
        try check(calls == 3,"new enqueue wakes idle runner via notification")
        await MainActor.run { runner.stop() }
        let stopped = try queue(); try await Task.sleep(nanoseconds:150_000_000)
        try check(try db.job(id:stopped)?.status == "pending","stopped runner leaves work for next app launch")
        try service.cancelInvoiceJob(stopped)
    }
}
