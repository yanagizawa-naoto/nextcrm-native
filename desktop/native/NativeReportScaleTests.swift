import Foundation
import SQLite3

/// Observe the real SQLite statement, not a delay before calling the query.
private final class ReportQueryObservation {
    private let condition = NSCondition()
    private(set) var startedAt: Date?
    private var finished = false
    func observe(_ event: UInt32) {
        condition.lock(); defer { condition.unlock() }
        if event == UInt32(SQLITE_TRACE_STMT) { startedAt = Date() }
        if event == UInt32(SQLITE_TRACE_PROFILE) { finished = true }
        condition.broadcast()
    }
    func waitForStart() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(10)
        while startedAt == nil { if !condition.wait(until: deadline) { return false } }
        return true
    }
    var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return startedAt != nil && !finished }
}

@main enum NativeReportScaleTests {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("NativeReportScaleTests: \(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Report-Scale-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql"))
        _ = try CRMService.bootstrap(db, resources: resources.appendingPathComponent("../../prisma"))
        // Test-only observation of the private handle avoids adding production
        // hooks or replacing the aggregation/progress-handler implementation.
        guard let property = Mirror(reflecting: db).children.first(where: { $0.label == "connection" })?.value,
              let stored = property as? Optional<OpaquePointer>, let connection = stored else {
            throw NativeDBError.message("SQLite trace handle unavailable")
        }
        func sql(_ text: String) throws {
            guard sqlite3_exec(connection, text, nil, nil, nil) == SQLITE_OK else {
                throw NativeDBError.message(String(cString: sqlite3_errmsg(connection)))
            }
        }
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1
        }
        let count = 120_000
        // A local synthetic database only. Leading whitespace exercises the
        // original parseInt-compatible numeric scan without retaining all rows.
        try sql("""
        BEGIN;
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<\(count))
        INSERT INTO crm_Accounts(id,__v,case_study_candidate,case_study_approved,name,annual_revenue,createdAt)
        SELECT printf('%08x-0000-4000-8000-%012x',x,x),0,0,0,printf('顧客-%06d',x),
               replace(hex(zeroblob(256)),'0',' ') || CAST(x AS TEXT),'2026-11-01T00:00:00.000Z'
        FROM n;
        COMMIT;
        """)
        try check(try db.page("crm_Accounts", fields: [], limit: 1).total == count, "large fixture count")
        let token = try db.createReportWorkspace(); defer { db.removeReportWorkspace(token) }
        let baselineStart = Date()
        try db.aggregateReport(token, section: "baseline", recipe: "topByRevenue", filter: .all)
        let baselineMS = Date().timeIntervalSince(baselineStart) * 1000
        let first = try db.reportPage(token, section: "baseline")
        try check(first.total == 10 && first.rows.count == 10, "top ten stays bounded for 120000 source rows")
        try check(first.rows.first?["label"] == .text("顧客-120000") && Double(first.rows.first?["value"]?.string ?? "") == Double(count), "large numeric aggregation correctness: \(String(describing: first.rows.first))")

        let observation = ReportQueryObservation()
        let trace: @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { event, context, statement, _ in
            guard let context, let statement, let text = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
            let query = String(cString: text)
            if query.hasPrefix("INSERT INTO temp.") && query.contains("crm_Accounts") {
                Unmanaged<ReportQueryObservation>.fromOpaque(context).takeUnretainedValue().observe(event)
            }
            return 0
        }
        guard sqlite3_trace_v2(connection, UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE), trace, Unmanaged.passUnretained(observation).toOpaque()) == SQLITE_OK else { throw NativeDBError.conflict }
        defer { sqlite3_trace_v2(connection, 0, nil, nil) }
        let task = Task.detached { try db.aggregateReport(token, section: "cancelled", recipe: "topByRevenue", filter: .all) }
        let observed = await Task.detached { observation.waitForStart() }.value
        guard observed else { task.cancel(); _ = try? await task.value; throw NativeDBError.message("FAIL: real aggregation did not start") }
        try await Task.sleep(nanoseconds: 10_000_000)
        let runningBeforeCancel = observation.isRunning
        let cancelledAt = Date(); task.cancel()
        do { try await task.value; throw NativeDBError.message("FAIL: query finished without cancellation") }
        catch is CancellationError { checks += 1 }
        let cancelMS = Date().timeIntervalSince(cancelledAt) * 1000
        try check(runningBeforeCancel, "cancellation happened after SQLite statement began and before it finished")
        try check(cancelMS < 2000, "in-flight aggregation cancellation promptly returns")
        try check(try db.reportPage(token, section: "cancelled").total == 0, "interrupted insert leaves no partial report rows")
        try check(try db.reportPage(token, section: "baseline").total == 10, "existing snapshot survives cancelled insert")
        try check(try db.page("crm_Accounts", fields: [], limit: 1).total == count, "source database usable and intact after cancellation")
        try db.aggregateReport(token, section: "recovered", recipe: "topByRevenue", filter: .all)
        let recovered = try db.reportPage(token, section: "recovered")
        try check(recovered.rows.map { [$0["label"], $0["value"]] } == first.rows.map { [$0["label"], $0["value"]] }, "subsequent aggregation remains correct")
        let bytes = (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let result: [String: Any] = ["suite": "NativeReportScale", "checks": checks, "sourceAccounts": count, "baselineMilliseconds": baselineMS, "cancelMilliseconds": cancelMS, "observedSQLiteInFlight": runningBeforeCancel, "temporaryDatabaseBytes": bytes, "temporaryFixtureRemovedOnExit": true, "fullAppMemoryMeasured": false]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }
}
