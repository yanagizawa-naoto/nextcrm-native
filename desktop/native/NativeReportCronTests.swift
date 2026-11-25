import Foundation

@main enum NativeReportCronTests {
    static func main()async {do{try await run()}catch{FileHandle.standardError.write(Data("Report cron: \(error)\n".utf8));exit(1)}}
    static func run()async throws {
        var checks=0
        let iso=ISO8601DateFormatter()
        func test(_ expression:String,_ after:String,_ expected:String?,zone:String="Asia/Tokyo")throws {
            let result=try NativeReportCron(expression).next(after:iso.date(from:after)!,timeZone:TimeZone(identifier:zone)!)
            guard result.map(iso.string)==expected else {throw NativeReportCronError("\(expression): \(String(describing:result.map(iso.string))) != \(String(describing:expected))")};checks+=1
        }
        try test("0 9 * * *","2026-11-19T00:00:00Z","2026-11-20T00:00:00Z")
        try test("0 9 * * *","2026-11-18T23:59:59Z","2026-11-19T00:00:00Z")
        try test("0 9 * * 1","2026-11-19T01:00:00Z","2026-11-23T00:00:00Z")
        try test("0 9 * * 5","2026-11-19T01:00:00Z","2026-11-20T00:00:00Z")
        try test("0 9 1 * *","2026-11-19T01:00:00Z","2026-12-01T00:00:00Z")
        try test("*/15 9-17 * * MON-FRI","2026-11-20T08:59:00Z","2026-11-23T00:00:00Z")
        try test("5,35 9,17 * * *","2026-11-19T00:06:00Z","2026-11-19T00:35:00Z")
        try test("20/15 9 * * *","2026-11-19T00:36:00Z","2026-11-19T00:50:00Z")
        try test("0 9 * JAN,MAR 7","2026-11-19T00:00:00Z","2027-01-03T00:00:00Z")
        try test("0 9 31 * MON","2026-11-19T00:00:00Z","2026-11-23T00:00:00Z")
        try test("0 9 */2 * MON","2026-11-23T00:00:00Z","2026-12-07T00:00:00Z")
        try test("0 9 31 APR *","2026-11-19T00:00:00Z",nil)
        try test("0 0 29 FEB *","2096-02-29T00:00:00Z","2104-02-29T00:00:00Z",zone:"UTC")
        try test("0 0 1 * *","2026-12-31T23:59:59Z","2027-01-01T00:00:00Z",zone:"UTC")
        // DST gap is skipped; the repeated hour is emitted once, at its first occurrence.
        try test("30 2 * * *","2026-03-08T00:00:00Z","2026-03-09T06:30:00Z",zone:"America/New_York")
        try test("0 0 * * *","2018-11-04T03:00:00Z","2018-11-05T02:00:00Z",zone:"America/Sao_Paulo")
        try test("30 1 * * *","2026-11-01T04:00:00Z","2026-11-01T05:30:00Z",zone:"America/New_York")
        try test("30 1 * * *","2026-11-01T05:30:00Z","2026-11-02T06:30:00Z",zone:"America/New_York")
        try test("* * * * *","2026-11-01T05:59:00Z","2026-11-01T07:00:00Z",zone:"America/New_York")
        try test("0 9 * * 0-7","2026-11-19T00:00:00Z","2026-11-20T00:00:00Z")
        try test("*/999 9 * * *","2026-11-18T23:00:00Z","2026-11-19T00:00:00Z")
        for invalid in ["","* * * *","* * * * * *","60 9 * * *","0 24 * * *","0 9 0 * *","0 9 * 13 *","0 9 * * 8","*/0 * * * *","*/-1 * * * *","1,,2 9 * * *","1- 9 * * *","9-1 * * * *","0 9 * * MON-SUN","0 9 * * L","0 9 1W * *","0 9 * * 1#2","０ 9 * * *","0\n9 * * * *",String(repeating:" ",count:513)+"0 9 * * *"] {
            var rejected=false
            do{_ = try NativeReportCron(invalid)}catch is NativeReportCronError{rejected=true}
            guard rejected else{throw NativeReportCronError("Invalid expression accepted: "+invalid)};checks+=1
        }
        let cron=try NativeReportCron("0 9 31 APR *"),task=Task.detached{try Task.checkCancellation();return try cron.next(after:iso.date(from:"2026-11-19T00:00:00Z")!,timeZone:TimeZone(identifier:"UTC")!)}
        task.cancel();do{_ = try await task.value;throw NativeReportCronError("Cancellation ignored")}catch is CancellationError{checks+=1}
        print("{\"suite\":\"NativeReportCron\",\"checks\":\(checks)}")
    }
}
