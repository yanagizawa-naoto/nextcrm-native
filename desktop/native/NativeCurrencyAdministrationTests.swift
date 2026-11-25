import Foundation
import SQLite3

@main enum NativeCurrencyAdministrationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw NativeDBError.message("FAIL: " + label) }; checks += 1 }
    static func rejects(_ label: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NativeDBError.message("FAIL: accepted " + label) }
    struct Currency: Decodable { let code: String, name: String, symbol: String; let isEnabled: Bool, isDefault: Bool; let updatedAt: String? }
    struct Rate: Decodable { let from: String, to: String, rate: String, source: String; let effectiveDate: String?, updatedAt: String? }
    struct Args: Decodable { let code: String?, name: String?, symbol: String?, rate: String?, fromCurrency: String?, toCurrency: String?; let enabled: Bool? }
    struct Snapshot: Decodable { let currencies: [Currency], rates: [Rate]; let settings: [String: String] }
    struct Outcome: Decodable { let skipped: Bool?, updated: Int?, ratesCount: Int? }
    struct Expected: Decodable {
        let error: String?, snapshot: Snapshot, calls: [String]
        let result: Outcome?
        enum CodingKeys: String, CodingKey { case error, snapshot, calls, result }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self); error = try c.decodeIfPresent(String.self, forKey: .error)
            snapshot = try c.decode(Snapshot.self, forKey: .snapshot); calls = try c.decode([String].self, forKey: .calls)
            result = try? c.decode(Outcome.self, forKey: .result)
        }
    }
    struct Case: Decodable { let label: String, operation: String, role: String, ecb: String; let args: Args; let currencies: [Currency], rates: [Rate]; let expected: Expected; let xml: String?, httpStatus: Int?, failure: String? }
    struct Reference: Decodable { struct Fixed: Decodable { let input: String, expected: String }; let old: String, now: String; let cases: [Case], fixed: [Fixed] }
    static func category(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("管理者") || text.contains("この利用者") { return "denied" }
        if text.contains("変換した") { return "length" }
        if text.contains("3文字") || text.contains("1〜") || text.contains("0より") { return "input" }
        if text.contains("UNIQUE") { return "unique" }
        if text.contains("FOREIGN KEY") { return "fk" }
        if text.contains("見つかりません") { return "missing" }
        if text.contains("範囲を超え") { return "numeric" }
        if text.contains("fixture-setting") { return "injected" }
        if text.contains("HTTP") { return "http" }
        return text
    }
    static func main() async {
        do {
            let resources = URL(fileURLWithPath: CommandLine.arguments[1])
            let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: resources.appendingPathComponent("build/admin-currency-reference.json")))
            for item in reference.fixed { try check(NativeOdooMap.fixed(NativeOdooMap.number(item.input), digits: 8) == item.expected, "source exact toFixed(8): " + item.input) }
            for item in reference.cases { try await run(item, reference: reference, resources: resources) }
            try await guards(resources: resources)
            try await applicationQA(resources: resources)
            print("{\"checks\":\(checks),\"cases\":\(reference.cases.count),\"exit\":0}")
        } catch { fputs("After \(checks) checks: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func open(_ root: URL, resources: URL) throws -> NativeDatabase { try NativeDatabase(url: root.appendingPathComponent("crm.sqlite"), schemaURL: resources.appendingPathComponent("schema.json"), sqlURL: resources.appendingPathComponent("schema.sql")) }
    static func applicationQA(resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Currency-AppQA-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try open(root, resources: resources), service = try service(db)
        let api = NativeCurrencyAdministration(service: service)
        for code in ["EUR", "USD", "JPY", "CZK"] {
            _ = try api.create(code: code, name: code, symbol: code)
        }
        try api.setECBEnabled(true, expected: api.settings())
        let id = try api.requestECBUpdate()
        let ran = try await NativeCurrencyAdministrationJobs.runNext(db: db, transport: NativeCurrencyAdministrationQA.fetch)
        try check(ran, "application QA worker claimed request")
        let job = try db.job(id: id)
        try check(job?.status == "done", "application QA update finished")
        try check(job?.result["updated"] == "12", "application QA writes direct inverse and cross rates")
        try check(job?.result["ratesCount"] == "3", "application QA parser accepts actual fixture")
        let rates = try api.rates()
        try check(rates.total == 12, "application QA persists all twelve pairs")
        let yen = try NativeCurrencyAdministration.rate(from: "EUR", to: "JPY", db: db)
        try check(yen?["rate"].string == "160", "application QA preserves known synthetic EUR JPY value")
        try check(yen?["source"] == .text("ECB"), "application QA records ECB source")
        do {
            _ = try await NativeCurrencyAdministrationQA.fetch(URLRequest(url: URL(string: "https://example.invalid/")!))
            throw NativeDBError.message("FAIL: QA adapter accepted unrelated host")
        } catch {
            try check(error.localizedDescription.contains("検証用のECB接続先が不正"), "application QA rejects unrelated host without network")
        }
    }
    static func service(_ db: NativeDatabase, role: String = "admin") throws -> CRMService {
        let row = try db.insert("Users", values: ["name": .text("通貨テスト"), "email": .text("currency-fixture@example.invalid"), "role": .text(role), "userStatus": .text("ACTIVE")], actor: "fixture")
        return CRMService(db: db, identity: .init(id: row["id"].string, role: role, partnerAccountID: nil))
    }
    static func execute(_ db: NativeDatabase, _ sql: String) throws {
        var connection: OpaquePointer?; guard sqlite3_open(db.url.path, &connection) == SQLITE_OK, let connection else { throw NativeDBError.message("fixture SQL") }
        defer { sqlite3_close(connection) }; guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw NativeDBError.message(String(cString: sqlite3_errmsg(connection))) }
    }
    static func run(_ item: Case, reference: Reference, resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Currency-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try open(root, resources: resources), service = try service(db, role: item.role)
        let now = ISO8601DateFormatter().date(from: reference.now.replacingOccurrences(of: ".000", with: ""))!
        let api = NativeCurrencyAdministration(service: service, clock: { now })
        for value in item.currencies {
            _ = try db.insert("Currency", values: ["code": .text(value.code), "name": .text(value.name), "symbol": .text(value.symbol), "isEnabled": .integer(value.isEnabled ? 1 : 0), "isDefault": .integer(value.isDefault ? 1 : 0), "createdAt": .text(reference.old), "updatedAt": .text(reference.old)], actor: "fixture")
        }
        for value in item.rates {
            _ = try db.insert("ExchangeRate", values: ["fromCurrency": .text(value.from), "toCurrency": .text(value.to), "rate": .text(value.rate), "source": .text(value.source), "effectiveDate": .text(reference.old), "updatedAt": .text(reference.old)], actor: "fixture")
        }
        try NativeCurrencyAdministration.setting("ecb_auto_update", value: item.ecb, db: db, actor: "fixture")
        try NativeCurrencyAdministration.setting("default_currency", value: "JPY", db: db, actor: "fixture")
        if item.failure == "setting" { try execute(db, "CREATE TRIGGER fixture_fail BEFORE UPDATE ON crm_SystemSettings WHEN OLD.key='default_currency' BEGIN SELECT RAISE(ABORT,'fixture-setting'); END") }
        var calls: [String] = [], error: String?, result: NativeCurrencyAdministrationECB.Result?
        do {
            let a = item.args
            switch item.operation {
            case "getCurrencies": _ = try api.currencies()
            case "getExchangeRatesAdmin": _ = try api.rates()
            case "createCurrency": _ = try api.create(code: a.code ?? "", name: a.name ?? "", symbol: a.symbol ?? "")
            case "toggleCurrency": try api.setEnabled(code: a.code ?? "", enabled: a.enabled ?? false)
            case "setDefaultCurrency": try api.setDefault(code: a.code ?? "")
            case "updateExchangeRate": _ = try api.saveRate(from: a.fromCurrency ?? "", to: a.toCurrency ?? "", input: a.rate ?? "")
            case "getEcbAutoUpdate": _ = try api.settings()
            case "setEcbAutoUpdate": try api.setECBEnabled(a.enabled ?? false)
            default:
                result = try await NativeCurrencyAdministrationECB.synchronize(db: db, transport: { request in
                    calls.append(request.url!.absoluteString)
                    try check(request.timeoutInterval == 30 && request.httpMethod == "GET", item.label + " request contract")
                    return (Data((item.xml ?? "").utf8), HTTPURLResponse(url: request.url!, statusCode: item.httpStatus ?? 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
                }, clock: { now })
            }
        } catch let caught { error = category(caught) }
        let expectedError = item.expected.error?.hasPrefix("ECB fetch failed") == true ? "http" : item.expected.error
        try check(error == expectedError, item.label + " outcome \(error ?? "success") vs \(expectedError ?? "success")")
        try check(calls == item.expected.calls, item.label + " fixed endpoint/disabled transport")
        if let actual = result, let expected = item.expected.result {
            try check(actual.skipped == (expected.skipped ?? false), item.label + " skipped")
            try check(actual.updated == (expected.updated ?? 0) && actual.ratesCount == (expected.ratesCount ?? 0), item.label + " update/result counts")
        }
        let expected = item.expected.snapshot
        try check(try db.page("Currency", fields: [], limit: 1).total == expected.currencies.count, item.label + " currency count")
        for value in expected.currencies {
            guard let actual = try db.get("Currency", key: ["code": .text(value.code)]) else { throw NativeDBError.message("FAIL: \(item.label) missing currency \(value.code)") }
            try check(actual["name"] == .text(value.name) && actual["symbol"] == .text(value.symbol), item.label + " display fields")
            try check(actual["isEnabled"] == .integer(value.isEnabled ? 1 : 0) && actual["isDefault"] == .integer(value.isDefault ? 1 : 0), item.label + " flags")
            try check((actual["updatedAt"] == .text(reference.old) ? "original" : "changed") == value.updatedAt, item.label + " currency timestamp")
        }
        try check(try db.page("ExchangeRate", fields: [], limit: 1).total == expected.rates.count, item.label + " pair count/partial commits")
        for value in expected.rates {
            guard let actual = try NativeCurrencyAdministration.rate(from: value.from, to: value.to, db: db) else { throw NativeDBError.message("FAIL: \(item.label) missing rate") }
            let expectedDecimal = Decimal(string: value.rate, locale: Locale(identifier: "en_US_POSIX"))!
            try check(try PriceDecimal.parse(actual["rate"].string) == expectedDecimal, item.label + " numeric(18,8)")
            try check(actual["source"] == .text(value.source), item.label + " source/manual policy")
            try check(actual["effectiveDate"] == .text(value.effectiveDate!), item.label + " effective date is fetch/edit time")
            try check((actual["updatedAt"] == .text(reference.old) ? "original" : "changed") == value.updatedAt, item.label + " rate update timestamp")
        }
        for (key, value) in expected.settings { try check(try db.get("crm_SystemSettings", key: ["key": .text(key)])?["value"] == .text(value), item.label + " settings atomicity") }
        let reopened = try open(root, resources: resources)
        try check(try reopened.page("ExchangeRate", fields: [], limit: 1).total == expected.rates.count, item.label + " reopen")
    }
    static func guards(resources: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextCRM-Currency-Guards-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try open(root, resources: resources), service = try service(db), api = NativeCurrencyAdministration(service: service)
        let eur = try api.create(code: "EUR", name: "ユーロ", symbol: "€")
        let usd = try api.create(code: "USD", name: "米ドル", symbol: "$")
        try api.setDefault(code: "EUR", expectedRevision: eur.revision)
        try rejects("default UI disable blocked") { try api.setEnabled(code: "EUR", enabled: false, protectDefault: true) }
        try rejects("stale currency editor") { try api.setEnabled(code: "USD", enabled: false, expectedRevision: usd.revision) }
        let before = try api.settings(); try api.setECBEnabled(true, expected: before)
        try rejects("stale ECB toggle") { try api.setECBEnabled(false, expected: before) }
        let rate = try NativeCurrencyAdministration.upsertRate(from: "EUR", to: "USD", value: 1.2, source: "ECB", db: db, actor: "fixture", at: Date())
        try rejects("automatic ECB UI edit blocked") { _ = try api.saveRate(from: "EUR", to: "USD", input: "1.5", expected: rate, protectAutomatic: true) }
        var failed = false
        do {
            _ = try await NativeCurrencyAdministrationECB.synchronize(db: db, transport: { request in
                try api.setECBEnabled(false)
                return (Data("currency='USD' rate='1.8'".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        } catch { failed = true }
        try check(failed && (try NativeCurrencyAdministration.rate(from: "EUR", to: "USD", db: db))?["rate"] == rate["rate"], "disable during await blocks publication")
        try api.setECBEnabled(true)
        let now = ISO8601DateFormatter().date(from: "2026-11-20T16:00:00Z")!
        let due = try NativeCurrencyAdministrationJobs.enqueueDue(db: db, now: now)!
        try check(due == now.addingTimeInterval(3600), "Friday UTC17 schedule")
        let next = try NativeCurrencyAdministrationJobs.enqueueDue(db: db, now: due)!
        try check(next.timeIntervalSince(due) == 3 * 86400, "weekend skipped")
        _ = try NativeCurrencyAdministrationJobs.enqueueDue(db: db, now: due)
        try check(try api.updateJobs().count == 1, "persistent schedule cursor dedupe")
        let reopened = try open(root, resources: resources)
        var requests = 0
        let transport: NativeCurrencyAdministrationECB.Transport = { request in requests += 1; return (Data("currency='USD' rate='1.25'".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        let worked = try await NativeCurrencyAdministrationJobs.runNext(db: reopened, transport: transport, clock: { due })
        try check(worked, "persisted job runs after reopen")
        try check(requests == 1 && api.updateJobs().first?.status == "done", "worker completed with fake transport")
        let retryID = try api.requestECBUpdate()
        let failedJob = try db.claimJob(events: [NativeCurrencyAdministrationJobs.event])!
        try check(failedJob.id == retryID, "retry fixture claims requested job")
        try db.failJob(failedJob, message: "fixture")
        let failedSnapshot = try db.job(id: retryID)!
        try api.retryUpdate(failedSnapshot)
        try check(try db.job(id: retryID)?.status == "cancelled", "manual retry retires old attempt")
        let replacement = try api.updateJobs().first { $0.status == "pending" }!
        try check(replacement.id != retryID && replacement.attempts == 0, "manual retry has new attempt budget")
        try api.cancelUpdate(replacement)
        let manual = try api.requestECBUpdate(); try api.cancelUpdate(api.updateJobs().first { $0.id == manual }!)
        try check(try db.job(id: manual)?.status == "cancelled", "pending cancellation")
        var tick = Date()
        let expiring = try api.requestECBUpdate(), beforeExpiry = try NativeCurrencyAdministration.rate(from: "EUR", to: "USD", db: db)!
        _ = try await NativeCurrencyAdministrationJobs.runNext(db: db, transport: { request in
            tick = tick.addingTimeInterval(301)
            return (Data("currency='USD' rate='9.5'".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, clock: { tick })
        try check(try NativeCurrencyAdministration.rate(from: "EUR", to: "USD", db: db)?.revision == beforeExpiry.revision, "expired lease blocks HTTP publication")
        try api.cancelUpdate(db.job(id: expiring)!)
        let runtime = NativeCurrencyAdministrationRuntime(db: db, transport: transport)
        await runtime.start()
        let runtimeID = try api.requestECBUpdate()
        for _ in 0..<200 {
            if try db.job(id: runtimeID)?.status == "done" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await runtime.stop()
        try check(try db.job(id: runtimeID)?.status == "done", "application runtime start/wake/drain/stop")
        let requestsBeforeRevocation = requests
        let revoked = try api.requestECBUpdate()
        let admin = try db.get("Users", key: ["id": .text(service.identity.id)])!
        _ = try db.update(admin, changes: ["role": .text("user")], actor: service.identity.id)
        _ = try await NativeCurrencyAdministrationJobs.runNext(db: db, transport: transport)
        try check(requests == requestsBeforeRevocation && (try db.job(id: revoked))?.status == "retry", "queued manual actor freshly authorized")
        try rejects("revoked administrator") { _ = try api.currencies() }
    }
}
