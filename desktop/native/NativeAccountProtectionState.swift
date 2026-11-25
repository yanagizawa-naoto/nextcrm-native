import Foundation

enum NativeAccountProtectionState {
    static let day: TimeInterval = 86_400
    static let jsWhitespace = CharacterSet(charactersIn:"\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
    static func countryCode(_ raw: Any?,fallback: String) -> String {
        let value=(raw as? String ?? "").trimmingCharacters(in:jsWhitespace),fallback=fallback.uppercased()
        if value.isEmpty { return fallback }
        if value.range(of:#"^[A-Za-z]{2}$"#,options:.regularExpression) != nil { let upper=value.uppercased();return NativeAccountProtectionRegions.codes.contains(upper) ? upper:fallback }
        return NativeAccountProtectionRegions.names[value.lowercased()] ?? fallback
    }
    static func numberKey(_ account: NativePluginRecord,defaultCountry: String) -> String? {
        let raw=String(String.UnicodeScalarView((account["company_id"] as? String ?? "").unicodeScalars.filter { !jsWhitespace.contains($0) })).uppercased()
        guard !raw.isEmpty else { return nil }
        let country=countryCode(account["billing_country"],fallback:defaultCountry)
        let digits=country == "CZ" && raw.range(of:#"^[0-9]{1,8}$"#,options:.regularExpression) != nil
        return country+":"+(digits ? String(repeating:"0",count:8-raw.count)+raw:raw)
    }
    static func contactTypes(_ value: String) -> [String] {
        let valid=value.components(separatedBy:",").map { $0.trimmingCharacters(in:jsWhitespace) }.filter { ["call","meeting","note","email","visit"].contains($0) }
        return valid.isEmpty ? ["visit","meeting"]:valid
    }
    static func newRegistration(key:String,ownerId:String,at:Date,settings:NativePluginRecord) throws -> NativePluginRecord {
        let protect=NativePluginJSON.number(settings["protectionDays"]) ?? 90,contact=NativePluginJSON.number(settings["contactDays"]) ?? 30
        guard abs(at.timeIntervalSince1970+protect*day)<=8_640_000_000_000,abs(at.timeIntervalSince1970+min(protect,contact)*day)<=8_640_000_000_000 else { throw NativePluginError(message:"Invalid time value") }
        let until=NativePluginJSON.stamp(at.addingTimeInterval(protect*day))
        return ["key":key,"ownerId":ownerId,"registeredAt":NativePluginJSON.stamp(at),"contactDeadline":NativePluginJSON.stamp(at.addingTimeInterval(min(protect,contact)*day)),"protectedUntil":until,"baseUntil":until]
    }
    static func addMonths(_ day:String,_ months:Int) throws -> String {
        let values=day.prefix(10).split(separator:"-").compactMap { Int($0) }
        guard values.count == 3 else { throw NativePluginError(message:"Invalid time value") }
        let y=(0...99).contains(values[0]) ? values[0]+1900:values[0]
        let total=y*12+values[1]-1+months,year=Int(floor(Double(total)/12)),month=total-year*12+1
        let first=NativePluginJSON.days(year:year,month:month,day:1)
        let next=NativePluginJSON.days(year:month == 12 ? year+1:year,month:month == 12 ? 1:month+1,day:1)
        let seconds=Double(first+min(values[2],next-first)-1)*Self.day
        guard abs(seconds)<=8_640_000_000_000 else { throw NativePluginError(message:"Invalid time value") }
        return NativePluginJSON.stamp(Date(timeIntervalSince1970:seconds))
    }
    static func withOrders(_ reg:NativePluginRecord,last:String?,months:Int) throws -> NativePluginRecord {
        var next=reg;let base=reg["baseUntil"] as? String ?? reg["protectedUntil"] as? String ?? ""
        let order = try last.flatMap { months > 0 ? try addMonths($0,months):nil }
        next["baseUntil"]=base;next["protectedUntil"]=order.map { $0 > base ? $0:base } ?? base
        next["lastOrderAt"]=last
        if !NativePluginJSON.truthy(next["contactAt"]),let last,last >= String((reg["registeredAt"] as? String ?? "").prefix(10)) || (order.map { $0 > base } ?? false) { next["contactAt"]=last+"T00:00:00.000Z" }
        return next
    }
    static func dueDay(_ reg:NativePluginRecord) -> String {
        let deadline=reg["contactDeadline"] as? String ?? "",until=reg["protectedUntil"] as? String ?? ""
        return String((!NativePluginJSON.truthy(reg["contactAt"]) && deadline < until ? deadline:until).prefix(10))
    }
    static func evaluate(_ reg:NativePluginRecord,now:Date) throws -> String {
        if let until=reg["protectedUntil"] as? String,now >= (try NativePluginJSON.date(until)) { return "expired" }
        if !NativePluginJSON.truthy(reg["contactAt"]),let deadline=reg["contactDeadline"] as? String,now >= (try NativePluginJSON.date(deadline)) { return "check-contact" }
        return "keep"
    }
    static func summarize(hasKey:Bool,reg:NativePluginRecord?,contactAt:String?) -> NativePluginRecord {
        guard hasKey else { return ["kind":"noNumber"] };guard let reg else { return ["kind":"free"] }
        let deadline=reg["contactDeadline"] as? String ?? "",until=reg["protectedUntil"] as? String ?? ""
        return contactAt == nil && deadline < until ? ["kind":"contactNeeded","date":deadline]:["kind":"protected","date":until]
    }
    static func formatDay(_ iso:String,locale:String) throws -> String {
        let date=try NativePluginJSON.date(iso),civil=NativePluginJSON.civilDay(Int(floor(date.timeIntervalSince1970/day)))
        let month: String
        switch locale {
        case "cz": return "\(civil.day). \(civil.month). \(civil.year)"
        case "de": month=["Jan.","Feb.","März","Apr.","Mai","Juni","Juli","Aug.","Sept.","Okt.","Nov.","Dez."][civil.month-1];return "\(civil.day). \(month) \(civil.year)"
        case "uk": month=["січ.","лют.","бер.","квіт.","трав.","черв.","лип.","серп.","вер.","жовт.","лист.","груд."][civil.month-1];return "\(civil.day) \(month) \(civil.year) р."
        default: month=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sept","Oct","Nov","Dec"][civil.month-1];return "\(civil.day) \(month) \(civil.year)"
        }
    }
}
