import Foundation

struct NativePluginSettingsField {
    enum Kind: String { case string, number, boolean, enumeration = "enum" }
    let key: String, kind: Kind
    var required = true
    var defaultValue: Any? = nil
    var options: [String]? = nil
    var validate: (Any) -> Bool = { _ in true }
    func accepts(_ value: Any) -> Bool {
        let typed: Bool
        switch kind {
        case .string: typed = value is String
        case .number: typed = NativePluginJSON.number(value) != nil
        case .boolean: typed = NativePluginJSON.boolean(value) != nil
        case .enumeration: typed = (value as? String).map { options?.contains($0) == true } ?? false
        }
        return typed && validate(value)
    }
    var description: NativePluginRecord {
        var value: NativePluginRecord = ["key": key, "kind": kind.rawValue, "required": required && defaultValue == nil]
        if let defaultValue { value["defaultValue"] = defaultValue }
        if let options { value["options"] = options }
        return value
    }
}

struct NativePluginSettingsSchema {
    var fields: [NativePluginSettingsField] = []
    func parse(_ value: Any) throws -> NativePluginRecord {
        guard let input = value as? NativePluginRecord else { throw NativePluginError(message: "Expected settings object") }
        var output: NativePluginRecord = [:]
        for field in fields {
            if let value = input[field.key] {
                guard field.accepts(value) else { throw NativePluginError(message: "Invalid setting: " + field.key) }
                output[field.key] = value
            } else if let value = field.defaultValue { output[field.key] = value }
            else if field.required { throw NativePluginError(message: "Required setting missing: " + field.key) }
        }
        return output
    }
    func stored(_ value: Any?, warn: (String, NativePluginRecord) -> Void) -> NativePluginRecord {
        let input = value as? NativePluginRecord ?? [:]
        var output: NativePluginRecord = [:], invalid: [String] = [], missing: [String] = []
        for field in fields {
            if let value = input[field.key], field.accepts(value) { output[field.key] = value; continue }
            if let fallback = field.defaultValue { output[field.key] = fallback }
            else if input[field.key] == nil && field.required { missing.append(field.key) }
            if input[field.key] != nil { invalid.append(field.key) }
        }
        if !invalid.isEmpty { warn("Stored settings invalid; using defaults for: " + invalid.joined(separator: ", "), ["fields": invalid]) }
        if !missing.isEmpty { warn("Required settings missing: " + missing.joined(separator: ", "), ["fields": missing]) }
        return output
    }
    var description: [NativePluginRecord] { fields.map(\.description) }
    static func integer(_ key: String, _ value: Int, minimum: Int, maximum: Int? = nil) -> NativePluginSettingsField {
        .init(key: key, kind: .number, defaultValue: value, validate: { input in
            guard let n = NativePluginJSON.number(input) else { return false }
            return n.rounded(.towardZero) == n && abs(n) <= 9_007_199_254_740_991 && n >= Double(minimum) && (maximum == nil || n <= Double(maximum!))
        })
    }
    static func string(_ key: String, _ value: String? = nil, validate: @escaping (String) -> Bool = { _ in true }) -> NativePluginSettingsField {
        .init(key: key, kind: .string, defaultValue: value, validate: { ($0 as? String).map(validate) ?? false })
    }
    static func boolean(_ key: String, _ value: Bool) -> NativePluginSettingsField { .init(key: key, kind: .boolean, defaultValue: value) }
    static let accountProtection = Self(fields: [
        integer("protectionDays",90,minimum:1), integer("contactDays",30,minimum:1),
        string("contactTypes","visit,meeting",validate: { !$0.split(separator:",",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:NativeAccountProtectionState.jsWhitespace) }.filter { ["call","meeting","note","email","visit"].contains($0) }.isEmpty }),
        integer("warnDays",7,minimum:1), string("defaultCountry","CZ",validate: { $0.unicodeScalars.count == 2 }), boolean("requireNumber",false), integer("orderMonths",12,minimum:0)
    ])
    static func connector(oxo: Bool) -> Self {
        var fields: [NativePluginSettingsField] = [string("url",validate: { $0.range(of:#"^https:\/\/[^\s/]+"#,options:.regularExpression) != nil })]
        if !oxo { fields.append(string("database",validate: { !$0.isEmpty })) }
        fields += [integer("syncMinutes",15,minimum:5,maximum:1440), string("defaultCountry","CZ",validate: { $0.unicodeScalars.count == 2 })]
        if oxo { fields.append(string("currency","CZK",validate: { $0.range(of:#"^[A-Z]{3}$"#,options:.regularExpression) != nil })) }
        fields += [boolean("dryRun",true), string("priceLists",""), boolean("sendOrders",false)]
        if !oxo { fields.append(boolean("fillOwners",true)) }
        fields.append(string("timeZone","UTC",validate: { NativePluginJSON.timeZoneOffset($0,at:Date(timeIntervalSince1970:0)) != nil }))
        return Self(fields:fields)
    }
    static func connectorSecrets(oxo: Bool) -> Self {
        Self(fields:[string("apiKey",validate: { oxo ? $0.range(of:#"^oxo_[A-Za-z0-9_-]{40}$"#,options:.regularExpression) != nil : !$0.isEmpty })])
    }
}
