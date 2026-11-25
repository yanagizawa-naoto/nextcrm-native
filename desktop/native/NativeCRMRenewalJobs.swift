import Foundation

enum NativeCRMRenewalJobs {
    static let scanEvent = "crm.automation.renewals.scan", taskEvent = "crm.automation.renewals.task"
    static let events = [scanEvent, taskEvent]
    static let cursorKey = "crm.automation.renewals.next.v1"
    static let maximumAttempts = 5
    struct Environment {
        /// Legacy oracle input only. Native task bodies use typed local links.
        let appURL: String?
        let timeZone: TimeZone
        init(appURL: String?, timeZone: TimeZone = .current) { self.appURL = appURL; self.timeZone = timeZone }
    }
    static func nextScheduledDate(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        if date <= now { date = calendar.date(byAdding: .day, value: 1, to: date)! }
        while calendar.component(.weekday, from: date) != 2 { date = calendar.date(byAdding: .day, value: 1, to: date)! }
        return date
    }
    /// Source Monday 07:00 UTC. A sleeping Mac coalesces an overdue reservation
    /// into one current-window scan; it does not replay nonexistent weekly runs.
    @discardableResult static func enqueueDue(db: NativeDatabase, now: Date) throws -> Date {
        try db.transaction {
            try Task.checkCancellation()
            let stored = try db.metadata(cursorKey)
            if let stored, !stored.isEmpty {
                let due = try NativeCRMAutomationDates.parse(stored)
                if due > now { return due }
                let id = "crm-renewals-" + String(Int64(due.timeIntervalSince1970))
                if try db.job(id: id) == nil { try db.enqueue(scanEvent, payload: ["scheduledAt": stored], id: id, now: now) }
            }
            let next = nextScheduledDate(after: now)
            try db.setMetadata(cursorKey, value: NativeCRMAutomationDates.stamp(next)); return next
        }
    }
    /// A snapshot transaction reads at most 100 records per SQL query, then
    /// persists their frozen task inputs one by one. It never retains an array
    /// proportional to the total renewals. Scan cancellation/failure rolls back
    /// the complete snapshot; task effects are independent atomic durable steps.
    private static func snapshot(db: NativeDatabase, job: NativeJob, now: Date, environment: Environment,
                                 checkpoint: (String, Int) throws -> Void) throws -> Int {
        let settings = try NativeCRMAutomationSettings.load(db)
        let start = try NativeCRMAutomationDates.stamp(now)
        let end = try NativeCRMAutomationDates.stamp(now.addingTimeInterval(Double(settings.renewalWindowDays) * 86_400))
        var count = 0
        func add(_ input: NativeCRMAutomationTaskInput, model: String, id: String) throws {
            let body = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
            try db.enqueue(taskEvent, payload: ["scanId": job.id, "sourceModel": model, "sourceId": id, "input": body], now: now)
            count += 1; try checkpoint("snapshot", count); try Task.checkCancellation()
        }
        for model in ["crm_Contracts", "crm_AccountProducts"] {
            let contract = model == "crm_Contracts", field = contract ? "renewalReminderDate" : "renewal_date"
            var filter: [RecordFilter] = [.compareDate(field, .greaterOrEqual, start), .compareDate(field, .lessOrEqual, end)]
            if !contract { filter.append(.equal("status", .text("ACTIVE"))) }
            let fields = contract ? ["title", "account", "assigned_to", field] : ["accountId", "productId", field]
            var after: String?
            while true {
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                let rows = try db.keysetPage(model, fields: fields, after: after, filter: .every(filter), limit: 100)
                if rows.isEmpty { break }
                for row in rows {
                    let date = try NativeCRMAutomationDates.parse(row[field].string), stamp = try NativeCRMAutomationDates.stamp(date)
                    let cycle = String(stamp.prefix(10)), local = NativeCRMAutomationText.date(date, zone: environment.timeZone)
                    let input: NativeCRMAutomationTaskInput
                    if contract {
                        let link = try NativeCRMContractLink(contractID: row["id"].string).string
                        input = .init(title: "契約更新（\(cycle)）：\(row["title"].string)", content: "契約「\(row["title"].string)」の更新通知日は\(local)です。更新条件を取引先に確認してください。\n契約を開く：\n\(link)", accountID: row["account"] == .null ? nil : row["account"].string, opportunityID: nil, assigneeID: row["assigned_to"] == .null ? nil : row["assigned_to"].string, due: stamp, dedupAnyStatus: true, canonicalTitle: "Renewal \(cycle): contract \"\(row["title"].string)\"")
                    } else {
                        // Source joins do not hide soft-deleted accounts/products.
                        let account = try db.keysetPage("crm_Accounts", fields: ["name", "assigned_to"], filter: .equal("id", row["accountId"]), includeDeleted: true, limit: 1).first
                        let product = try db.keysetPage("crm_Products", fields: ["name"], filter: .equal("id", row["productId"]), includeDeleted: true, limit: 1).first
                        let productName = product.flatMap { $0["name"] == .null ? nil : $0["name"].string }
                        let name = productName ?? "商品", canonicalName = productName ?? "product"
                        let accountName = account.map { $0["name"] == .null ? row["accountId"].string : $0["name"].string } ?? row["accountId"].string
                        input = .init(title: "利用契約の更新（\(cycle)）：\(name) / \(accountName)", content: "「\(name)」の利用契約は\(local)に更新されます。取引先に更新予定を確認してください。", accountID: row["accountId"].string, opportunityID: nil, assigneeID: account.flatMap { $0["assigned_to"] == .null ? nil : $0["assigned_to"].string }, due: stamp, dedupAnyStatus: true, canonicalTitle: "Renewal \(cycle): \(canonicalName) @ \(accountName)")
                    }
                    try add(input, model: model, id: row["id"].string)
                }
                after = rows.last?["id"].string
            }
        }
        return count
    }
    @discardableResult static func runNext(db: NativeDatabase, environment: Environment,
                                          clock: () -> Date = Date.init,
                                          checkpoint: (String, Int) throws -> Void = { _, _ in }) throws -> Bool {
        try Task.checkCancellation()
        let now = clock()
        guard let job = try db.claimJob(events: events, now: now) else { return false }
        do {
            try db.transaction {
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                guard job.attempts <= maximumAttempts else { throw NativeDBError.message("更新通知の再試行回数を超えました。") }
                var result: [String: String]
                if job.event == scanEvent {
                    let count = try snapshot(db: db, job: job, now: now, environment: environment, checkpoint: checkpoint)
                    result = ["status": "snapshot", "items": String(count), "windowStartedAt": try NativeCRMAutomationDates.stamp(now)]
                } else {
                    guard let input = job.payload["input"] else { throw NativeDBError.message("更新通知の保存内容が不正です。") }
                    let value = try JSONDecoder().decode(NativeCRMAutomationTaskInput.self, from: Data(input.utf8))
                    let created = try NativeCRMAutomationTasks.create(value, db: db, now: now) {
                        _ = try db.requireJobLease(job); try checkpoint("task", 1)
                    }
                    result = ["status": created == nil ? "skipped" : "created"]
                    if let created { result["taskId"] = created }
                }
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                try db.finishJob(job, result: result, now: clock())
            }
            return true
        } catch {
            // A cancelled/failed atomic step remains recoverable. Never mark all
            // tasks done/cancelled or release another worker's reclaimed lease.
            if let current = try? db.requireJobLease(job) {
                try db.failJob(current, message: error is CancellationError ? "更新通知を中断しました。次回再開します。" : error.localizedDescription,
                               retryAt: job.attempts < maximumAttempts ? clock().addingTimeInterval(error is CancellationError ? 0 : 30) : nil)
            }
            if error is CancellationError { throw error }
            return true
        }
    }
}
