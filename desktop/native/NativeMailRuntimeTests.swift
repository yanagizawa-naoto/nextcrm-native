import Foundation

@MainActor enum NativeMailRuntimeTests {
    static func run(resources: URL) async throws -> Int {
        var checks = 0
        func check(_ condition:Bool,_ name:String) throws { guard condition else { throw NativeDBError.message("NativeMailRuntimeTests: "+name) }; checks += 1 }
        func until(_ name:String,_ condition:() throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while try !condition() { guard Date() < deadline else { throw NativeDBError.message("NativeMailRuntimeTests timeout: "+name) }; try await Task.sleep(nanoseconds:20_000_000) }
        }
        do {
            let f = try MailSyncFixture(resources:resources)
            f.receiver.messages = ["INBOX":[1,2],"送信済み":[]]
            try check(try NativeMailSchedule.enqueueDue(db:f.db,now:f.now) == 1,"active account schedules initial sync")
            let id = try f.service.mailSyncJob(f.accountID)!.id, generation = try f.db.metadata(NativeMailJobs.generation(f.accountID))
            _ = try NativeMailSchedule.enqueueDue(db:f.db,now:f.now)
            try check(try f.service.mailSyncJob(f.accountID)?.id == id && f.db.metadata(NativeMailJobs.generation(f.accountID)) == generation,"periodic scan does not multiply pending or running work")
            _ = try await f.worker().runNext()
            _ = try NativeMailSchedule.enqueueDue(db:f.db,now:f.now.addingTimeInterval(899))
            try check(try f.service.mailSyncJob(f.accountID)?.id == id,"sync is not due before fifteen minutes")
            _ = try NativeMailSchedule.enqueueDue(db:f.db,now:f.now.addingTimeInterval(900))
            try check(try f.service.mailSyncJob(f.accountID)?.id != id,"sync becomes due at fifteen minutes")
        }
        do {
            let f = try MailSyncFixture(resources:resources); f.now = Date()
            f.receiver.messages = ["INBOX":[1,2],"送信済み":[]]
            _ = try f.service.setMailAccountActive(f.account(),active:false)
            var sends = 0, failures = 0
            let runtime = NativeMailRuntime(db:f.db,store:f.secrets,makeClient:{_,_ in f.receiver},send:{_ in await MainActor.run { sends += 1 }},recoverTemporary:{})
            runtime.onError = { _ in failures += 1 }; runtime.resume()
            try await until("inactive idle") { !runtime.isScanning && !runtime.isRunning }
            try check(runtime.nextScan == nil && f.receiver.searches.isEmpty,"no scan timer or network for zero eligible accounts")
            _ = try f.service.setMailAccountActive(f.account(),active:true); runtime.resume()
            try await until("startup sync and link") { try f.account()["lastSyncedAt"] != .null && !runtime.isScanning && !runtime.isRunning }
            try check(try f.rows() == 2 && f.db.jobs(events:[NativeMailJobs.link]).allSatisfy{$0.status == "done"},"actual runners consume initial sync and CRM-link jobs")
            try check(runtime.nextScan != nil,"active account retains one periodic scan")
            let draft = NativeMailDraft(to:["customer@example.test"],subject:"ランタイム",body:"本文")
            let id = try f.service.queueMailSend(account:f.account(),draft:draft)
            try await until("send wake") { try f.db.job(id:id)?.status == "done" && !runtime.isRunning }
            try check(sends == 1,"database job notification wakes SMTP runner")
            runtime.stop(); let pending = try f.service.queueMailSend(account:f.account(),draft:draft)
            try await Task.sleep(nanoseconds:150_000_000)
            try check(try f.db.job(id:pending)?.status == "pending" && sends == 1 && runtime.nextScan == nil,"stop leaves pending jobs durable and removes scan")
            let restarted = NativeMailRuntime(db:f.second,store:f.secrets,makeClient:{_,_ in f.receiver},send:{_ in await MainActor.run { sends += 1 }},recoverTemporary:{})
            restarted.onError = { _ in failures += 1 }; restarted.resume()
            try await until("restart send") { try f.db.job(id:pending)?.status == "done" && !restarted.isScanning && !restarted.isRunning }
            try check(sends == 2,"new runtime on second connection recovers pending mail")
            _ = try f.service.setMailAccountActive(f.account(),active:false); restarted.resume()
            try await until("last account disabled") { !restarted.isScanning && !restarted.isRunning }
            try check(restarted.nextScan == nil && failures == 0,"last account deactivation removes periodic work")
            restarted.stop()
        }
        do {
            let f = try MailSyncFixture(resources:resources); f.now = Date(); f.receiver.messages = ["INBOX":[],"送信済み":[]]
            var attempted = false
            let runtime = NativeMailRuntime(db:f.db,store:f.secrets,makeClient:{_,_ in f.receiver},send:{_ in
                await MainActor.run { attempted = true }; try await Task.sleep(nanoseconds:10_000_000_000)
            },recoverTemporary:{})
            runtime.resume(); try await until("empty initial sync") { try f.account()["lastSyncedAt"] != .null && !runtime.isRunning && !runtime.isScanning }
            let id = try f.service.queueMailSend(account:f.account(),draft:.init(to:["customer@example.test"],subject:"中断",body:"本文"))
            try await until("sending") { attempted }; runtime.stop()
            try await until("cancelled sender") { try f.db.job(id:id)?.status == "needs_review" && !runtime.isRunning }
            try check(try f.db.job(id:id)?.deliveryStartedAt != nil,"runtime cancellation preserves uncertain SMTP review")
        }
        print("NativeMailRuntimeTests: \(checks) checks passed; actual wake-only runners, cadence, startup, stop and restart")
        return checks
    }
}
