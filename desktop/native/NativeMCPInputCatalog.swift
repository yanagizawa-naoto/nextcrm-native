import Foundation
import CoreFoundation

enum NativeMCPInputCatalogError: Error { case invalidCatalog, unknownTool }

/// Compiled from the project's original Zod schemas at build time. The compact
/// rule graph preserves wrapper/property/check order, defaults, and stripping
/// semantics that the discovery JSON Schema alone does not express.
final class NativeMCPInputCatalog {
    struct Issue {
        let path: [Any], message: String
        var json: [String: Any] { ["path": path, "message": message] }
        var description: String {
            guard !path.isEmpty else { return message }
            var result = ""
            for (index, part) in path.enumerated() {
                if index == 0 { result = String(describing: part) }
                else if let number = part as? Int { result += "[\(number)]" }
                else { result += ".\(part)" }
            }
            return message + " at " + result
        }
    }
    struct Outcome {
        let value: Any?, issues: [Issue], truncated: Bool
        var isValid: Bool { issues.isEmpty && !truncated }
        var message: String {
            let text = issues.map(\.description).joined(separator: "\n")
            return truncated ? text + "\nValidation stopped after \(issues.count) errors" : text
        }
        func toolMessage(_ name: String) -> String {
            "MCP error -32602: Input validation error: Invalid arguments for tool \(name): \(message)"
        }
    }
    private enum Kind: String { case object, optional, nullable, `default`, string, number, boolean, array, `enum`, any }
    private enum Check {
        case lower(Double, Bool), upper(Double, Bool), minimum(Int), maximum(Int), length(Int), integer
        case format(String, NSRegularExpression)
    }
    private struct Node {
        let kind: Kind, properties: [(String, Int, Bool)], inner: Int?, value: Any?, values: [String], checks: [Check], depth: Int
    }
    private final class Context {
        let limit: Int
        var issues: [Issue] = [], truncated = false
        init(limit: Int) { self.limit = limit }
        var full: Bool { issues.count >= limit }
        func add(_ message: String, at path: [Any]) {
            if full { truncated = true } else { issues.append(Issue(path: path, message: message)) }
        }
    }
    let tools: [[String: Any]], ruleCount: Int, regularExpressionCount: Int
    private let nodes: [Node], roots: [String: Int], maximumIssues: Int

    init(data: Data, maximumIssues: Int = 128) throws {
        guard (1...1024).contains(maximumIssues), data.count <= 2 * 1024 * 1024,
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.index(document["version"], maximum: 2) == 1,
              document["semantics"] as? [String: String] == ["stringLength": "codePoints", "objectUnknownFields": "strip", "regex": "ECMAScriptNoFlags"],
              let rawNodes = document["nodes"] as? [[String: Any]], !rawNodes.isEmpty, rawNodes.count <= 4096,
              let rawTools = document["tools"] as? [[String: Any]], !rawTools.isEmpty, rawTools.count <= 1024 else { throw NativeMCPInputCatalogError.invalidCatalog }
        var nodes: [Node] = [], regexes: [String: NSRegularExpression] = [:]
        for (index, raw) in rawNodes.enumerated() {
            guard let text = raw["type"] as? String, let kind = Kind(rawValue: text) else { throw NativeMCPInputCatalogError.invalidCatalog }
            var allowed: Set<String> = ["type", "checks"], properties: [(String, Int, Bool)] = [], inner: Int?, values: [String] = [], children: [Int] = []
            switch kind {
            case .object:
                allowed.insert("properties")
                guard let fields = raw["properties"] as? [[String: Any]], fields.count <= 1024 else { throw NativeMCPInputCatalogError.invalidCatalog }
                var names = Set<String>()
                for field in fields {
                    guard Set(field.keys) == ["name", "node", "optional"], let name = field["name"] as? String, !name.isEmpty,
                          let optional = Self.boolean(field["optional"]),
                          names.insert(name).inserted, let reference = Self.index(field["node"], maximum: index) else { throw NativeMCPInputCatalogError.invalidCatalog }
                    properties.append((name, reference, optional)); children.append(reference)
                }
            case .default:
                allowed.formUnion(["inner", "value"])
                guard raw["value"] != nil, let reference = Self.index(raw["inner"], maximum: index) else { throw NativeMCPInputCatalogError.invalidCatalog }
                inner = reference; children.append(reference)
            case .optional, .nullable, .array:
                allowed.insert("inner")
                guard let reference = Self.index(raw["inner"], maximum: index) else { throw NativeMCPInputCatalogError.invalidCatalog }
                inner = reference; children.append(reference)
            case .enum:
                allowed.insert("values")
                guard let options = raw["values"] as? [String], !options.isEmpty, Set(options).count == options.count else { throw NativeMCPInputCatalogError.invalidCatalog }
                values = options
            default: break
            }
            guard Set(raw.keys).isSubset(of: allowed) else { throw NativeMCPInputCatalogError.invalidCatalog }
            var checks: [Check] = []
            if raw["checks"] != nil {
                guard let definitions = raw["checks"] as? [[String: Any]], definitions.count <= 32 else { throw NativeMCPInputCatalogError.invalidCatalog }
                for definition in definitions {
                    let check = definition["kind"] as? String
                    switch check {
                    case "greater_than", "less_than":
                        guard kind == .number, Set(definition.keys) == ["kind", "value", "inclusive"],
                              let number = Self.number(definition["value"]), let boolean = Self.boolean(definition["inclusive"]) else { throw NativeMCPInputCatalogError.invalidCatalog }
                        checks.append(check == "greater_than" ? .lower(number, boolean) : .upper(number, boolean))
                    case "min_length", "max_length", "length_equals":
                        guard kind == .array || kind == .string, Set(definition.keys) == ["kind", "value"],
                              let length = Self.index(definition["value"], maximum: 10_000_001) else { throw NativeMCPInputCatalogError.invalidCatalog }
                        if check == "min_length" { checks.append(.minimum(length)) }
                        else if check == "max_length" { checks.append(.maximum(length)) }
                        else { checks.append(.length(length)) }
                    case "number_format":
                        guard kind == .number, Set(definition.keys) == ["kind", "format"], definition["format"] as? String == "safeint" else { throw NativeMCPInputCatalogError.invalidCatalog }
                        checks.append(.integer)
                    case "string_format":
                        guard kind == .string, Set(definition.keys) == ["kind", "format", "pattern"],
                              let format = definition["format"] as? String, ["uuid", "email", "datetime"].contains(format),
                              let pattern = definition["pattern"] as? String, pattern.hasPrefix("^"), pattern.hasSuffix("$"), pattern.utf8.count <= 8192 else { throw NativeMCPInputCatalogError.invalidCatalog }
                        if regexes[pattern] == nil {
                            // ECMAScript \d is ASCII and $ is absolute end when
                            // not multiline. ICU has different defaults here.
                            let nativePattern = String(pattern.dropLast()).replacingOccurrences(of: "\\d", with: "[0-9]") + "\\z"
                            regexes[pattern] = try NSRegularExpression(pattern: nativePattern)
                        }
                        checks.append(.format(format, regexes[pattern]!))
                    default: throw NativeMCPInputCatalogError.invalidCatalog
                    }
                }
            }
            let depth = (children.map { nodes[$0].depth }.max() ?? 0) + 1
            guard depth <= 64 else { throw NativeMCPInputCatalogError.invalidCatalog }
            nodes.append(Node(kind: kind, properties: properties, inner: inner, value: raw["value"], values: values, checks: checks, depth: depth))
        }
        var tools: [[String: Any]] = [], roots: [String: Int] = [:]
        for raw in rawTools {
            guard let name = raw["name"] as? String, !name.isEmpty, roots[name] == nil,
                  let root = Self.index(raw["schema"], maximum: nodes.count), nodes[root].kind == .object,
                  raw["inputSchema"] is [String: Any], raw["description"] is String else { throw NativeMCPInputCatalogError.invalidCatalog }
            roots[name] = root; var metadata = raw; metadata.removeValue(forKey: "schema"); tools.append(metadata)
        }
        self.nodes = nodes; self.roots = roots; self.tools = tools; self.maximumIssues = maximumIssues
        ruleCount = nodes.count; regularExpressionCount = regexes.count
    }

    func evaluate(tool: String, input: Any) throws -> Outcome {
        guard let root = roots[tool] else { throw NativeMCPInputCatalogError.unknownTool }
        let context = Context(limit: maximumIssues)
        let value = parse(root, value: input, path: [], context: context)
        return Outcome(value: context.issues.isEmpty && !context.truncated ? value : nil, issues: context.issues, truncated: context.truncated)
    }

    /// Place the real permission-scoped handler behind this boundary. Rejected
    /// input never reaches a tool effect; handlers receive normalized values.
    func dispatch(tool: String, arguments: [String: Any], id: Any, perform: NativeMCPProtocol.Call) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard roots[tool] != nil else { return NativeMCPProtocol.toolError("MCP error -32602: Tool \(tool) not found") }
        let outcome = try evaluate(tool: tool, input: arguments)
        guard outcome.isValid, let normalized = outcome.value as? [String: Any] else { return NativeMCPProtocol.toolError(outcome.toolMessage(tool)) }
        try Task.checkCancellation(); return try await perform(tool, normalized, id)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func index(_ value: Any?, maximum: Int) -> Int? {
        guard let number = number(value), number >= 0, number < Double(maximum), number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
    private static func received(_ value: Any?) -> String {
        guard let value else { return "undefined" }
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if boolean(value) != nil { return "boolean" }
        if value is NSNumber { return "number" }
        if value is [Any] { return "array" }
        return "object"
    }
    private static func numericText(_ number: Double) -> String {
        if number.rounded(.towardZero) == number, abs(number) < 1e18 { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), number) }
        return String(number)
    }
    private static func coercibleNumber(_ value: Any) -> Double {
        if value is NSNull { return 0 }
        if let boolean = boolean(value) { return boolean ? 1 : 0 }
        if let number = number(value) { return number }
        if let array = value as? [Any] {
            func jsString(_ value: Any) -> String {
                if value is NSNull { return "" }
                if let text = value as? String { return text }
                if let boolean = boolean(value) { return boolean ? "true" : "false" }
                if let number = number(value) { return numericText(number) }
                if let array = value as? [Any] { return array.map(jsString).joined(separator: ",") }
                return "[object Object]"
            }
            return coercibleNumber(array.map(jsString).joined(separator: ","))
        }
        guard let text = value as? String else { return .nan }
        let whitespace = CharacterSet(charactersIn: "\u{9}\u{B}\u{C}\u{20}\u{A0}\u{FEFF}\u{A}\u{D}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{202F}\u{205F}\u{3000}\u{2028}\u{2029}")
        let trimmed = text.trimmingCharacters(in: whitespace)
        if trimmed.isEmpty { return 0 }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        let lower = trimmed.lowercased()
        for (prefix, base) in [("0x", 16), ("0b", 2), ("0o", 8)] where lower.hasPrefix(prefix) {
            let digits = lower.dropFirst(2); guard !digits.isEmpty else { return .nan }
            var result = 0.0
            for scalar in digits.unicodeScalars {
                let code = scalar.value
                let digit = (48...57).contains(code) ? Int(code - 48) : (97...102).contains(code) ? Int(code - 97) + 10 : 100
                guard digit < base else { return .nan }; result = result * Double(base) + Double(digit)
            }
            return result
        }
        guard trimmed.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46, 69, 101].contains($0) }) else { return .nan }
        return Double(trimmed) ?? .nan
    }
    private func checkLength(_ check: Check, value: Any?, path: [Any], context: Context) {
        let raw: Any, origin: String, unit: String
        if let text = value as? String { raw = text.unicodeScalars.count; origin = "string"; unit = " characters" }
        else if let array = value as? [Any] { raw = array.count; origin = "array"; unit = " items" }
        else if let length = (value as? [String: Any])?["length"] { raw = length; origin = "unknown"; unit = "" }
        else { return }
        let count = Self.coercibleNumber(raw), small: Bool, big: Bool, constraint: String
        switch check {
        case .minimum(let value):
            small = !(count >= Double(value)); big = false; constraint = ">=\(value)"
        case .maximum(let value):
            small = false; big = !(count <= Double(value)); constraint = "<=\(value)"
        case .length(let value):
            big = count > Double(value); small = !big && Self.number(raw) != Double(value); constraint = "exactly \(value)"
        default: return
        }
        if small || big {
            context.add("Too \(small ? "small" : "big"): expected \(origin) to \(origin == "unknown" ? "be" : "have") \(constraint)\(unit)", at: path)
        }
    }
    private func parse(_ index: Int, value: Any?, path: [Any], context: Context) -> Any? {
        if context.full { context.truncated = true; return nil }
        let node = nodes[index]
        switch node.kind {
        case .optional:
            if value == nil {
                // Optional wrappers still allow inner defaults to produce data.
                let scratch = Context(limit: context.limit)
                return parse(node.inner!, value: nil, path: path, context: scratch)
            }
            return parse(node.inner!, value: value, path: path, context: context)
        case .nullable:
            if value is NSNull { return value }
            return parse(node.inner!, value: value, path: path, context: context)
        case .default:
            if value == nil { return node.value }
            return parse(node.inner!, value: value, path: path, context: context)
        case .any: return value
        case .enum:
            if let text = value as? String, node.values.contains(text) { return text }
            let options = node.values.map { "\"\($0)\"" }.joined(separator: "|")
            context.add(node.values.count == 1 ? "Invalid input: expected \(options)" : "Invalid option: expected one of \(options)", at: path)
            return nil
        default: break
        }
        func wrongType() -> Any? {
            context.add("Invalid input: expected \(node.kind.rawValue), received \(Self.received(value))", at: path)
            // Zod length checks have a `when` predicate independent of the
            // nominal schema type. Even invalid arrays/objects can add a size
            // diagnostic; they never become accepted values.
            for check in node.checks { checkLength(check, value: value, path: path, context: context) }
            return nil
        }
        var output: Any?
        switch node.kind {
        case .object:
            guard let object = value as? [String: Any] else { return wrongType() }
            var result: [String: Any] = [:]
            for (name, child, optional) in node.properties {
                if context.full { context.truncated = true; break }
                let previousIssues = context.issues.count
                if let parsed = parse(child, value: object[name], path: path + [name], context: context) { result[name] = parsed }
                else if !optional, context.issues.count == previousIssues {
                    context.add("Invalid input: expected nonoptional, received undefined", at: path + [name])
                }
            }
            return result
        case .array:
            guard let array = value as? [Any] else { return wrongType() }
            var result: [Any] = []; result.reserveCapacity(min(array.count, 1024))
            for (offset, child) in array.enumerated() {
                if context.full { context.truncated = true; break }
                result.append(parse(node.inner!, value: child, path: path + [offset], context: context) ?? NSNull())
            }
            output = result
        case .string:
            guard let text = value as? String else { return wrongType() }; output = text
        case .number:
            // The source server parses JSON numbers as JavaScript binary64.
            // Foundation may retain an NSDecimalNumber with extra digits;
            // validate and return the same binary64 value the source uses.
            guard let number = Self.number(value) else { return wrongType() }; output = number
        case .boolean:
            guard Self.boolean(value) != nil else { return wrongType() }; return value
        default: return nil
        }
        for check in node.checks {
            switch check {
            case .integer:
                let number = Self.number(value)!
                if number.rounded(.towardZero) != number {
                    context.add("Invalid input: expected int, received number", at: path); return output
                }
                if number > 9007199254740991 { context.add("Too big: expected int to be <=9007199254740991", at: path) }
                if number < -9007199254740991 { context.add("Too small: expected int to be >=-9007199254740991", at: path) }
            case .lower(let bound, let inclusive):
                let number = Self.number(value)!
                if inclusive ? number < bound : number <= bound { context.add("Too small: expected number to be \(inclusive ? ">=" : ">")\(Self.numericText(bound))", at: path) }
            case .upper(let bound, let inclusive):
                let number = Self.number(value)!
                if inclusive ? number > bound : number >= bound { context.add("Too big: expected number to be \(inclusive ? "<=" : "<")\(Self.numericText(bound))", at: path) }
            case .minimum, .maximum, .length: checkLength(check, value: value, path: path, context: context)
            case .format(let format, let regex):
                let text = value as! String
                if regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) == nil {
                    let description = format == "uuid" ? "UUID" : format == "email" ? "email address" : "ISO datetime"
                    context.add("Invalid \(description)", at: path)
                }
            }
        }
        return output
    }
}
