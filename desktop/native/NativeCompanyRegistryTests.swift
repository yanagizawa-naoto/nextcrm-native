import Foundation

private final class RegistryFixture {
    let config: NativePluginRecord
    var requests: [NativePluginRecord] = [], logged = false
    init(_ config: NativePluginRecord) { self.config = config }
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var trace: NativePluginRecord = ["url": request.url!.absoluteString, "method": request.httpMethod ?? "GET", "headers": Dictionary(uniqueKeysWithValues: (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) })]
        if let body = request.httpBody { trace["body"] = try JSONSerialization.jsonObject(with: body) }
        requests.append(trace)
        if config["networkError"] as? Bool == true { throw NativePluginError(message: "offline fixture") }
        let body = config["invalidJSON"] as? Bool == true ? Data("{invalid".utf8) : try NativePluginJSON.data(config["reply"] ?? NSNull())
        return (body, HTTPURLResponse(url: request.url!, statusCode: config["status"] as? Int ?? 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
    func service() -> NativeCompanyRegistry {
        NativeCompanyRegistry(authenticate: { [self] in
            if config["authFailure"] as? Bool == true { throw NativePluginError(message: "Unauthenticated") }
        }, providers: { [self] in
            if config["disabled"] as? Bool == true { return [] }
            return [.init(countries: ["CZ"], lookup: { [self] number, _ in
                if config["contextFailure"] as? Bool == true { throw NativePluginError(message: "context unavailable") }
                return try await NativeAres.lookup(number, fetch: fetch)
            }, validateVat: { [self] value in
                if config["contextFailure"] as? Bool == true { throw NativePluginError(message: "context unavailable") }
                return try await NativeAres.validateVat(value, fetch: fetch)
            })]
        }, log: { [self] _ in logged = true })
    }
}

@main enum NativeCompanyRegistryTests {
    static func main() async throws {
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! NativePluginRecord
        let cases = document["cases"] as! [NativePluginRecord]
        var checks = 0
        func equal(_ actual: Any, _ expected: Any, _ label: String) throws {
            guard NativePluginJSON.equal(actual, expected) else { throw NativePluginError(message: label + "\nactual: " + (try NativePluginJSON.text(actual)) + "\nexpected: " + (try NativePluginJSON.text(expected))) }; checks += 1
        }
        for (index, item) in cases.enumerated() {
            let op = item["op"] as! String, input = item["input"]!, config = item["config"] as! NativePluginRecord
            let fixture = RegistryFixture(config), service = fixture.service()
            var result: Any
            do {
                switch op {
                case "normalize": result = NativeAres.normalizeIco(input as! String) as Any? ?? NSNull()
                case "map": result = try NativeAres.map(input, ico: "27082440")
                case "lookup": result = try await NativeAres.lookup(input as! String, fetch: fixture.fetch) as Any? ?? NSNull()
                case "vat": result = try await NativeAres.validateVat(input as! String, fetch: fixture.fetch)
                case "actionLookup":
                    let input = input as! NativePluginRecord
                    if let data = try await service.lookup(country: input["country"] as! String, number: input["number"] as! String) { result = ["data": data] }
                    else { result = ["error": "registryNotFound"] }
                case "actionVat": result = ["result": try await service.validateVat(input as! String).rawValue]
                case "countries": result = try service.countries()
                case "canValidate": result = try service.canValidateVat()
                default: fatalError("Unknown oracle operation")
                }
            } catch {
                // Both runtimes reject malformed JSON/null responses; their
                // internal exception class names are not user-facing contracts.
                if config["invalidJSON"] as? Bool == true { result = ["thrown": "SyntaxError"] }
                else if config["reply"] is NSNull { result = ["thrown": "TypeError"] }
                else { result = ["thrown": error.localizedDescription] }
            }
            try equal(result, item["result"]!, "case \(index) \(op) result")
            try equal(fixture.requests, item["requests"]!, "case \(index) \(op) HTTP")
            try equal(fixture.logged, item["logged"]!, "case \(index) \(op) error logging")
        }
        // Provider ordering, unique country discovery, and unsupported-country
        // VAT checks are action contracts beyond this single provider.
        var calls = [String]()
        let selection = NativeCompanyRegistry(authenticate: {}, providers: {
            [.init(countries: ["SK", "CZ"], lookup: { number, country in calls.append("first:" + number + ":" + country); return ["name": "first"] }),
             .init(countries: ["CZ", "DE"], lookup: { _, _ in calls.append("second"); return nil }, validateVat: { value in calls.append(value); return false }),
             .init(countries: ["CZ"], lookup: { _, _ in nil }, validateVat: { _ in calls.append("last"); return true })]
        })
        try equal(try selection.countries(), ["CZ", "DE", "SK"], "unique sorted countries")
        try equal(try selection.canValidateVat(), true, "VAT availability")
        try equal(try await selection.lookup(country: " cz ", number: " 19 ")!, ["name": "first"], "first matching provider")
        try equal(try await selection.validateVat("AT 12").rawValue, "invalid", "VAT is not restricted by company countries")
        try equal(calls, ["first:19:CZ", "AT12"], "selected provider alone called")
        var canceledFetches = 0
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeAres.lookup("19", fetch: { _ in canceledFetches += 1; throw CancellationError() })
        }
        do { _ = try await task.value; throw NativePluginError(message: "Cancellation was swallowed") }
        catch is CancellationError { checks += 1 }
        try equal(canceledFetches, 0, "canceled operation sends no HTTP")
        let canceled = NativeCompanyRegistry(authenticate: {}, providers: { [.init(countries: ["CZ"], lookup: { _, _ in throw CancellationError() }, validateVat: { _ in throw CancellationError() })] })
        do { _ = try await canceled.lookup(country: "CZ", number: "19"); throw NativePluginError(message: "Lookup cancellation was swallowed") }
        catch is CancellationError { checks += 1 }
        do { _ = try await canceled.validateVat("CZ19"); throw NativePluginError(message: "VAT cancellation was swallowed") }
        catch is CancellationError { checks += 1 }
        print("{\"cases\":\(cases.count),\"checks\":\(checks)}")
    }
}
