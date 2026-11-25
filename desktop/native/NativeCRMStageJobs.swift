import Foundation

enum NativeCRMStageJobs {
    static let transitionEvent = "crm/opportunity.stage-changed", touchEvent = "crm.automation.stage.touch"
    static let events = [transitionEvent, touchEvent]
    struct State: Codable {
        let recordID: String, stageEventID: String, kind: String, entry: String
        let settings: NativeCRMAutomationSettings
        var index: Int
    }
    private static func reserve(_ state: State, db: NativeDatabase, now: Date) throws {
        guard let touch = try NativeCRMStageSchedule.touch(kind: state.kind, index: state.index, entry: NativeCRMAutomationDates.parse(state.entry), settings: state.settings) else { return }
        let due = try NativeCRMAutomationDates.parse(touch.due)
        try db.enqueue(touchEvent, payload: ["record_id": state.recordID, "stageEventID": state.stageEventID,
            "state": String(decoding: try JSONEncoder().encode(state), as: UTF8.self)], now: now, runAt: max(now, due))
    }
    @discardableResult static func runNext(db: NativeDatabase, clock: () -> Date = Date.init,
                                          checkpoint: (String) throws -> Void = { _ in }) throws -> Bool {
        try Task.checkCancellation(); let now = clock()
        // Transition admission takes precedence over due touches. The persisted
        // producer head is still rechecked under the write transaction, closing
        // the race with a freshly committed same-kind / same-second transition.
        guard let job = try db.claimJob(events: [transitionEvent], now: now) ?? db.claimJob(events: [touchEvent], now: now) else { return false }
        do {
            try db.transaction {
                try Task.checkCancellation(); _ = try db.requireJobLease(job)
                guard job.attempts <= 5, let record = job.payload["record_id"], UUID(uuidString: record) != nil else { throw NativeDBError.message("営業フォローの処理内容を確認できません。") }
                let head = try db.opportunityStageEventHead(recordID: record)
                var result: [String: String]
                if job.event == transitionEvent {
                    guard head == job.id else { try db.finishJob(job, result: ["status": "superseded"], now: now); return }
                    let stageID = job.payload["to_stage"] ?? ""
                    let stage = try db.keysetPage("crm_Opportunities_Sales_Stages", fields: ["stage_kind"], filter: .equal("id", .text(stageID)), includeDeleted: true, limit: 1).first
                    let kind = stage?["stage_kind"].string ?? ""
                    if ["qualified", "care"].contains(kind) {
                        guard let entry = try db.opportunityStageEventTimestamp(recordID: record, eventID: job.id) else { try db.finishJob(job, result: ["status": "superseded"], now: now); return }
                        let state = try State(recordID: record, stageEventID: job.id, kind: kind, entry: entry, settings: NativeCRMAutomationSettings.load(db), index: 0)
                        try reserve(state, db: db, now: now)
                        result = ["status": "scheduled", "kind": kind, "touches": String(try NativeCRMStageSchedule.count(kind: kind, settings: state.settings))]
                    } else { result = ["status": "skipped", "reason": "not-qualified-or-care"] }
                } else {
                    guard let encoded = job.payload["state"] else { throw NativeDBError.message("営業フォローの予約が不正です。") }
                    var state = try JSONDecoder().decode(State.self, from: Data(encoded.utf8))
                    try NativeCRMStageSchedule.validate(state.settings)
                    guard state.recordID == record, state.stageEventID == job.payload["stageEventID"], ["qualified", "care"].contains(state.kind),
                          let touch = try NativeCRMStageSchedule.touch(kind: state.kind, index: state.index, entry: NativeCRMAutomationDates.parse(state.entry), settings: state.settings) else { throw NativeDBError.message("営業フォローの予約が一致しません。") }
                    guard head == state.stageEventID else { try db.finishJob(job, result: ["status": "superseded"], now: now); return }
                    // Original findUnique intentionally includes soft-deleted
                    // opportunities. Its status/stage/assignee rules are kept;
                    // the existing mail worker separately protects live access.
                    let opp = try db.keysetPage("crm_Opportunities", fields: ["status", "sales_stage", "account", "assigned_to", "name"], filter: .equal("id", .text(record)), includeDeleted: true, limit: 1).first
                    var created: String?
                    if let opp, opp["status"] == .text("ACTIVE"),
                       let stage = try db.keysetPage("crm_Opportunities_Sales_Stages", fields: ["stage_kind"], filter: .equal("id", opp["sales_stage"]), includeDeleted: true, limit: 1).first,
                       stage["stage_kind"] == .text(state.kind) {
                        let name = opp["name"] == .null ? record : opp["name"].string
                        let localized = NativeCRMStageText.render(kind: state.kind, index: state.index, settings: state.settings, name: name)
                        let input = NativeCRMAutomationTaskInput(title: localized.title, content: localized.content,
                            accountID: opp["account"] == .null ? nil : opp["account"].string, opportunityID: record,
                            assigneeID: opp["assigned_to"] == .null ? nil : opp["assigned_to"].string,
                            due: touch.due, dedupAnyStatus: false, canonicalTitle: touch.title)
                        created = try NativeCRMAutomationTasks.create(input, db: db, now: now) {
                            _ = try db.requireJobLease(job)
                            guard try db.opportunityStageEventHead(recordID: record) == state.stageEventID else { throw NativeDBError.conflict }
                            try checkpoint("task")
                        }
                    }
                    result = ["status": created == nil ? "skipped" : "created", "index": String(state.index)]
                    if let created { result["taskId"] = created }
                    state.index += 1
                    try reserve(state, db: db, now: now)
                }
                try checkpoint("commit"); try Task.checkCancellation(); _ = try db.requireJobLease(job)
                try db.finishJob(job, result: result, now: clock())
            }
            return true
        } catch {
            if let current = try? db.requireJobLease(job) { try db.failJob(current, message: error is CancellationError ? "営業フォローを中断しました。次回再開します。" : error.localizedDescription,
                retryAt: job.attempts < 5 ? clock().addingTimeInterval(error is CancellationError ? 0 : 30) : nil) }
            if error is CancellationError { throw error }; return true
        }
    }
}
