import Foundation

/// Request-scoped browser authority; never shared between concurrent tools.
enum NativeMCPRequestContext {
    @TaskLocal static var cookie: String? = nil
}
import CoreFoundation

enum NativeMCPFailure: Error {
    case notFound, forbidden, unauthorized, conflict(String), validation(String), external(String), rule(String), internalError
    case reportSessionUnauthenticated, reportSessionForbidden
    var payload: [String: String] {
        switch self {
        case .notFound: return ["error": "NOT_FOUND", "code": "NOT_FOUND"]
        case .forbidden: return ["error": "FORBIDDEN", "code": "FORBIDDEN"]
        case .unauthorized: return ["error": "Unauthorized", "code": "UNAUTHORIZED"]
        case .conflict(let text): return ["error": "CONFLICT: " + text, "code": "INVALID_REQUEST"]
        case .validation(let text): return ["error": "VALIDATION_ERROR: " + text, "code": "INVALID_PARAMS"]
        case .external(let text): return ["error": "EXTERNAL_ERROR: " + text, "code": "INTERNAL_ERROR"]
        case .rule(let text): return ["error": text, "code": "RULE_REJECTED"]
        case .internalError: return ["error": "Internal tool error", "code": "INTERNAL_ERROR"]
        case .reportSessionUnauthenticated: return ["error": "Unauthenticated", "code": "INTERNAL_ERROR"]
        case .reportSessionForbidden: return ["error": "操作する権限がありません", "code": "INTERNAL_ERROR"]
        }
    }
}

enum NativeMCPWire {
    private static let utcPattern = try! NSRegularExpression(pattern: #"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?Z\z"#)
    /// JavaScript Date uses a proleptic Gregorian calendar. Foundation's
    /// ISO8601DateFormatter can rewrite year zero and pre-1582 dates; retain
    /// valid UTC components directly and truncate to JS millisecond precision.
    static func canonicalUTC(_ text: String) -> String? {
        guard let match = utcPattern.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return nil }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        guard let yearText = part(1), let monthText = part(2), let dayText = part(3), let hourText = part(4), let minuteText = part(5),
              let year = Int(yearText), let month = Int(monthText), let day = Int(dayText), let hour = Int(hourText), let minute = Int(minuteText),
              let second = Int(part(6) ?? "00"), (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let leap = year % 400 == 0 || year % 4 == 0 && year % 100 != 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        let fraction = String((part(7) ?? "").prefix(3))
        return yearText + "-" + monthText + "-" + dayText + "T" + hourText + ":" + minuteText + ":" + (part(6) ?? "00") + "." + fraction + String(repeating: "0", count: 3 - fraction.count) + "Z"
    }
    /// Prisma Decimal.toJSON formatting for the plain decimal strings stored by
    /// NativeDatabase. String arithmetic preserves every digit and negative zero.
    static func decimal(_ text: String) throws -> String {
        let negative = text.hasPrefix("-"), sign = negative ? "-" : ""
        let parts = text.dropFirst(negative ? 1 : 0).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { throw NativeMCPFailure.internalError }
        let integer = parts[0].drop(while: { $0 == "0" }), fraction = parts.count == 2 ? parts[1] : ""
        let exponent: Int, significant: Substring
        if integer.isEmpty {
            let nonzero = fraction.drop(while: { $0 == "0" })
            if nonzero.isEmpty { return sign + "0" }
            exponent = -(fraction.count - nonzero.count) - 1; significant = nonzero
        } else { exponent = integer.count - 1; significant = Substring(String(integer) + fraction) }
        let digits = String(significant.reversed().drop(while: { $0 == "0" }).reversed())
        if exponent <= -7 || exponent >= 21 {
            let tail = digits.dropFirst()
            return sign + String(digits.first!) + (tail.isEmpty ? "" : "." + tail) + "e" + (exponent >= 0 ? "+" : "") + String(exponent)
        }
        let point = exponent + 1
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
        let index = digits.index(digits.startIndex, offsetBy: point)
        return sign + digits[..<index] + "." + digits[index...]
    }
    static func response(_ value: Any, failed: Bool = false) throws -> [String: Any] {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: bytes, as: UTF8.self)]]]
        if failed { result["isError"] = true }; return result
    }
    static func integer(_ value: Any?, range: ClosedRange<Int>) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue, number.doubleValue >= Double(range.lowerBound),
              number.doubleValue <= Double(range.upperBound) else { throw NativeMCPFailure.internalError }
        return number.intValue
    }
    static func record(_ record: NativeRecord, schema: NativeSchema) throws -> [String: Any] {
        let model = try schema.model(record.model)
        return try Dictionary(uniqueKeysWithValues: model.fields.map { ($0.name, try value(record[$0.name], field: $0)) })
    }
    static func value(_ value: SQLValue, field: NativeSchema.Field) throws -> Any {
        if value == .null { return NSNull() }
        if field.array || field.type == "Json" { return try JSONSerialization.jsonObject(with: Data(value.string.utf8), options: [.fragmentsAllowed]) }
        switch field.type {
        case "Boolean": return value == .integer(1)
        case "BigInt": return value.string
        case "Decimal": return try decimal(value.string)
        case "DateTime":
            if let canonical = canonicalUTC(value.string) { return canonical }
            guard let date = NativeAPITokens.date(value) else { throw NativeMCPFailure.internalError }
            return NativeAPITokens.timestamp(date)
        case "Int":
            guard case let .integer(number) = value else { throw NativeMCPFailure.internalError }; return number
        case "Float":
            if case let .real(number) = value { return number }
            if case let .integer(number) = value { return Double(number) }
            throw NativeMCPFailure.internalError
        default:
            guard case let .text(text) = value else { throw NativeMCPFailure.internalError }; return text
        }
    }
}

/// Registered operations alone are advertised. The app must call requireFull
/// before enabling this runtime; partial registries are for staged tests only.
final class NativeMCPRequestRouter {
    typealias Handler = (NativeAPISession, [String: Any]) async throws -> Any
    private let catalog: NativeMCPInputCatalog, db: NativeDatabase, clock: () -> Date
    private let handlers: [String: Handler], protocolLayer: NativeMCPProtocol
    let missingTools: Set<String>
    init(catalog: NativeMCPInputCatalog, db: NativeDatabase, handlers: [String: Handler], requireFull: Bool = true, clock: @escaping () -> Date = Date.init) throws {
        let all = Set(catalog.tools.compactMap { $0["name"] as? String }), registered = Set(handlers.keys)
        guard registered.isSubset(of: all) else { throw NativeMCPInputCatalogError.invalidCatalog }
        missingTools = all.subtracting(registered)
        guard !requireFull || missingTools.isEmpty else { throw NativeMCPInputCatalogError.invalidCatalog }
        self.catalog = catalog; self.db = db; self.handlers = handlers; self.clock = clock
        protocolLayer = try NativeMCPProtocol(tools: catalog.tools.filter { registered.contains($0["name"] as! String) }) { _, _, _ in throw NativeMCPFailure.unauthorized }
    }
    func handle(_ request: NativeMCPHTTPRequest) async -> NativeMCPHTTPResponse {
        let header = request.headers.first { $0.key.lowercased() == "authorization" }?.value
        let cookie = request.headers.first { $0.key.lowercased() == "cookie" }?.value
        let session: NativeAPISession?
        if let header, header.hasPrefix("Bearer ") { session = try? NativeAPITokens.prepareSession(String(header.dropFirst(7)), db: db, clock: clock) }
        else { session = nil }
        // This closure retains a token digest, not the bearer header. Discovery
        // has no credential side effect; each effect resolves current authority.
        return await protocolLayer.handle(request, dispatch: { [self, session] name, input, id in
            try await catalog.dispatch(tool: name, arguments: input, id: id) { name, arguments, _ in
                do {
                    try Task.checkCancellation()
                    guard let session, let handler = self.handlers[name] else { throw NativeMCPFailure.unauthorized }
                    try session.withAccess { _ in }
                    // SSE dispatch is lazy, so establish the context here,
                    // when the handler runs, rather than around handle().
                    let result = try await NativeMCPRequestContext.$cookie.withValue(cookie) {
                        try await handler(session, arguments)
                    }
                    try Task.checkCancellation(); return try NativeMCPWire.response(result)
                } catch is CancellationError { throw CancellationError() }
                catch let failure as NativeMCPFailure { return try NativeMCPWire.response(failure.payload, failed: true) }
                catch is NativeAPITokenError { return try NativeMCPWire.response(NativeMCPFailure.unauthorized.payload, failed: true) }
                catch { return try NativeMCPWire.response(NativeMCPFailure.internalError.payload, failed: true) }
            }
        })
    }
}
