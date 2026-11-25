import Foundation
import CoreFoundation

typealias NativePluginRecord = [String: Any]
protocol NativePluginHTTPStatusText { var statusText:String { get } }
enum NativePluginExecutionScope {
    @TaskLocal static var validate: ((String) throws -> Void)? = nil
    static func check(_ pluginId:String) throws { try Task.checkCancellation();try validate?(pluginId) }
}

enum NativePluginEntity: String, CaseIterable, Codable {
    case account, contact, lead, opportunity, order
    var model: String { switch self { case .account: return "crm_Accounts"; case .contact: return "crm_Contacts"; case .lead: return "crm_Leads"; case .opportunity: return "crm_Opportunities"; case .order: return "crm_Orders" } }
    init?(model: String) { guard let value = Self.allCases.first(where: { $0.model == model }) else { return nil }; self = value }
}

struct NativePluginActor: Codable, Equatable {
    enum Kind: String, Codable { case user, token, system, plugin }
    let type: Kind
    var userId: String? = nil, role: String? = nil, pluginId: String? = nil
    static let system = Self(type: .system)
    static func plugin(_ id: String) -> Self { .init(type: .plugin, pluginId: id) }
    var auditID: String { userId ?? pluginId.map { "plugin:" + $0 } ?? "system" }
    var representative: Bool { (type == .user || type == .token) && role == "user" }
}

struct NativePluginRuleInput {
    enum Operation: String, Codable { case beforeCreate, beforeUpdate, beforeDelete }
    let entity: NativePluginEntity, operation: Operation
    let recordId: String?
    var data: NativePluginRecord
    let existing: NativePluginRecord?
}

enum NativePluginRuleResult {
    case allow
    case reject(messageKey: String, params: NativePluginRecord? = nil)
    case modify(NativePluginRecord)
}

struct NativePluginAfterInput: Codable {
    enum Operation: String, Codable { case created, updated, deleted }
    let entity: NativePluginEntity, operation: Operation, recordId: String
    var actor: NativePluginActor? = nil
    var changed: [String]? = nil
}

struct NativePluginRuleError: Error, LocalizedError {
    let pluginId: String?, messageKey: String
    var params: NativePluginRecord? = nil
    var translated: String? = nil
    var errorDescription: String? { translated ?? "Rejected by plugin rule \(pluginId ?? "core"):\(messageKey)" }
}

struct NativePluginError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func permission(_ plugin: String, _ permission: String) -> Self { .init(message: "Plugin \(plugin) lacks permission \(permission)") }
}

struct NativePluginStoreError:Error,LocalizedError {
    let message:String
    var errorDescription:String? { message }
}

enum NativePluginJSON {
    private struct Decoded:Decodable {
        let value:Any
        init(from decoder:Decoder) throws {
            let container=try decoder.singleValueContainer()
            if container.decodeNil() { value=NSNull() }
            else if let boolean=try? container.decode(Bool.self) { value=boolean }
            else if let string=try? container.decode(String.self) { value=string }
            else if let number=try? container.decode(Double.self) { value=NSNumber(value:number) }
            else if let array=try? container.decode([Decoded].self) { value=array.map(\.value) }
            else { value=try container.decode([String:Decoded].self).mapValues(\.value) }
        }
    }
    static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    static func text(_ value: Any) throws -> String { String(decoding: try data(value), as: UTF8.self) }
    // JSONSerialization on this macOS loses a leading U+FEFF inside string
    // values. JSONDecoder preserves it and decodes numbers as JS binary64.
    static func parse(_ value: String) throws -> Any { try JSONDecoder().decode(Decoded.self,from:Data(value.utf8)).value }
    static func record(_ value: String) throws -> NativePluginRecord {
        guard let object = try parse(value) as? NativePluginRecord else { throw NativePluginError(message: "Expected a JSON object") }; return object
    }
    static func equal(_ a: Any?, _ b: Any?) -> Bool { (try? data(a ?? NSNull())) == (try? data(b ?? NSNull())) }
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }; return number.boolValue
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number is NSDecimalNumber ? Double(number.stringValue) ?? number.doubleValue : number.doubleValue
        return value.isFinite ? value:nil
    }
    static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String { return !text.isEmpty }
        if let number = value as? NSNumber { return number.doubleValue != 0 && !number.doubleValue.isNaN }
        return true
    }
    static func string(_ value: Any?) -> String {
        guard let value else { return "undefined" }
        if value is NSNull { return "null" }
        if let text = value as? String { return text }
        if let boolean = boolean(value) { return boolean ? "true" : "false" }
        if let number = value as? NSNumber { return numberString(number is NSDecimalNumber ? Double(number.stringValue) ?? number.doubleValue:number.doubleValue) }
        if let array = value as? [Any] { return array.map { $0 is NSNull ? "" : string($0) }.joined(separator: ",") }
        return "[object Object]"
    }
    static func numberString(_ value: Double) -> String {
        if value.isNaN { return "NaN" };if value == .infinity { return "Infinity" };if value == -.infinity { return "-Infinity" }
        if value == 0 { return "0" }
        let text=String(value)
        if abs(value) >= 1e-6 && abs(value) < 1e21 {
            let parts=text.lowercased().split(separator:"e"),mantissa=String(parts[0]),negative=mantissa.hasPrefix("-"),unsigned=negative ? String(mantissa.dropFirst()):mantissa
            let pieces=unsigned.split(separator:".",omittingEmptySubsequences:false)
            var digits=pieces.joined(),point=pieces[0].count+(parts.count>1 ? Int(parts[1]) ?? 0:0)
            while digits.hasSuffix("0"),digits.count>1 { digits.removeLast() }
            let expanded:String
            if point<=0 { expanded="0."+String(repeating:"0",count:-point)+digits }
            else if point>=digits.count { expanded=digits+String(repeating:"0",count:point-digits.count) }
            else { let index=digits.index(digits.startIndex,offsetBy:point);expanded=String(digits[..<index])+"."+String(digits[index...]) }
            return (negative ? "-":"")+expanded
        }
        return text.replacingOccurrences(of:".0e",with:"e").replacingOccurrences(of:"e-0",with:"e-").replacingOccurrences(of:"e+0",with:"e+")
    }
    private static let zoneNames=Dictionary(TimeZone.knownTimeZoneIdentifiers.map { ($0.lowercased(),$0) },uniquingKeysWith: { first,_ in first })
    private static let zoneAliases=["utc":"UTC","gmt":"UTC","uct":"UTC","universal":"UTC","zulu":"UTC","greenwich":"UTC","jst":"Asia/Tokyo","japan":"Asia/Tokyo","est":"America/Panama","mst":"America/Phoenix","hst":"Pacific/Honolulu","cst":"America/Chicago","pst":"America/Los_Angeles","cet":"Europe/Brussels","eet":"Europe/Athens","wet":"Europe/Lisbon","us/eastern":"America/New_York","us/central":"America/Chicago","us/mountain":"America/Denver","us/pacific":"America/Los_Angeles","us/alaska":"America/Anchorage","us/hawaii":"Pacific/Honolulu","us/arizona":"America/Phoenix","us/east-indiana":"America/Indiana/Indianapolis","us/michigan":"America/Detroit","us/samoa":"Pacific/Pago_Pago","gb":"Europe/London","gb-eire":"Europe/London"]
    /// Intl also accepts fixed offsets up to 23:59; Foundation TimeZone stops
    /// at 18 hours, so consumers use seconds instead of a TimeZone instance.
    static func timeZoneOffset(_ value:String,at date:Date) -> Int? {
        guard value==value.trimmingCharacters(in:.whitespacesAndNewlines),!value.isEmpty,value.lowercased() != "factory" else { return nil }
        if value.range(of:#"^[+-][0-9]{2}(?::?[0-9]{2})?$"#,options:.regularExpression) != nil {
            let digits=value.dropFirst().replacingOccurrences(of:":",with:"")
            let hours=Int(digits.prefix(2))!,minutes=digits.count==4 ? Int(digits.suffix(2))!:0
            guard hours<24,minutes<60 else { return nil };return (hours*3600+minutes*60)*(value.first=="-" ? -1:1)
        }
        if !value.contains("/"),(value.contains("+") || value.contains("-")),value.lowercased() != "gb-eire" { return nil }
        let name=zoneAliases[value.lowercased()] ?? zoneNames[value.lowercased()] ?? value
        guard let zone=TimeZone(identifier:name) else { return nil };return zone.secondsFromGMT(for:date)
    }
    static func stamp(_ date: Date) -> String {
        guard date.timeIntervalSince1970.isFinite,abs(date.timeIntervalSince1970)<=8_640_000_000_000 else { return "Invalid Date" }
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded()), day = Int(floor(Double(ms)/86_400_000))
        let time = Int(ms - Int64(day)*86_400_000), civil = civilDay(day)
        let year = (0...9999).contains(civil.year) ? String(format:"%04d",civil.year) : String(format:"%+07d",civil.year)
        return year + String(format:"-%02d-%02dT%02d:%02d:%02d.%03dZ",civil.month,civil.day,time/3_600_000,(time/60_000)%60,(time/1000)%60,time%1000)
    }
    // Proleptic Gregorian arithmetic avoids Foundation's pre-1582 cutover.
    static func days(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1:0), era = (y >= 0 ? y:y-399)/400, yoe = y-era*400
        let doy = (153*(month+(month > 2 ? -3:9))+2)/5+day-1
        return era*146097+yoe*365+yoe/4-yoe/100+doy-719468
    }
    static func civilDay(_ days: Int) -> (year:Int,month:Int,day:Int) {
        let z=days+719468,era=(z >= 0 ? z:z-146096)/146097,doe=z-era*146097
        let yoe=(doe-doe/1460+doe/36524-doe/146096)/365, y=yoe+era*400
        let doy=doe-(365*yoe+yoe/4-yoe/100),mp=(5*doy+2)/153,d=doy-(153*mp+2)/5+1,m=mp+(mp<10 ? 3:-9)
        return (y+(m<=2 ? 1:0),m,d)
    }
    static func date(_ value: String) throws -> Date {
        if let regex = try? NSRegularExpression(pattern:#"^([+-]?[0-9]{4,6})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?(Z|[+-][0-9]{2}:[0-9]{2}))?$"#),let match=regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) {
            func field(_ i:Int)->String { Range(match.range(at:i),in:value).map { String(value[$0]) } ?? "" }
            let y=Int(field(1))!,m=Int(field(2))!,d=Int(field(3))!,h=Int(field(4)) ?? 0,n=Int(field(5)) ?? 0,s=Int(field(6)) ?? 0
            if (1...12).contains(m),(1...31).contains(d),(0...24).contains(h),(0...59).contains(n),(0...59).contains(s) {
                let fraction=Int(String((field(7)+"000").prefix(3))) ?? 0,zone=field(8)
                var offset=0
                if zone.count == 6 { let parts=zone.dropFirst().split(separator:":").compactMap { Int($0) };offset=(parts[0]*60+parts[1])*(zone.first == "-" ? -1:1) }
                let milliseconds=Double(days(year:y,month:m,day:d))*86_400_000+Double(h*3_600_000+n*60_000+s*1000+fraction-offset*60_000)
                return Date(timeIntervalSince1970:milliseconds/1000)
            }
        }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return date }
        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, let date = formatter.date(from: value + "T00:00:00Z") { return date }
        throw NativePluginError(message: "Invalid time value")
    }
}

enum NativePluginSDK {
    static let version = "0.2.6"
    static let permissions: Set<String> = ["accounts:read", "accounts:write", "contacts:read", "contacts:write", "leads:read", "leads:write", "opportunities:read", "opportunities:write", "orders:read", "orders:write", "activities:read", "users:read", "products:read", "products:write", "priceLists:read", "priceLists:write", "notify", "http"]
    static let internalRoles = ["user", "manager", "admin"]
    static func parseVersion(_ value: String) throws -> [Double] {
        guard value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { throw NativePluginError(message: "Invalid version: " + value) }
        return value.split(separator: ".").map { Double($0) ?? .infinity }
    }
    static func compareVersions(_ a: String, _ b: String) throws -> Int {
        for (a, b) in try zip(parseVersion(a), parseVersion(b)) { if a > b { return 1 }; if a < b { return -1 } }; return 0
    }
    static func satisfies(_ range: String, version: String = version) throws -> Bool {
        guard range.hasPrefix("^") else { return false }
        let required = String(range.dropFirst()), r = try parseVersion(required), v = try parseVersion(version)
        guard try compareVersions(version, required) >= 0 else { return false }
        if r[0] > 0 { return v[0] == r[0] }
        if r[1] > 0 { return v[0] == 0 && v[1] == r[1] }
        return v[0] == 0 && v[1] == 0 && v[2] == r[2]
    }
    static func validate(id: String, version: String, sdk: String, permissions: [String]) throws {
        guard id.range(of: #"^[a-z][a-z0-9-]{1,48}$"#, options: .regularExpression) != nil else { throw NativePluginError(message: "Invalid plugin id: " + id) }
        _ = try parseVersion(version)
        guard sdk.hasPrefix("^") else { throw NativePluginError(message: "sdk must be a caret range, e.g. ^0.2.0") }
        _ = try parseVersion(String(sdk.dropFirst()))
        for permission in permissions where !Self.permissions.contains(permission) { throw NativePluginError(message: "Unknown permission: " + permission) }
    }
}
